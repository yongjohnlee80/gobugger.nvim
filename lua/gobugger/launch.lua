-- launch.json lifecycle: find, parse (JSONC + trailing commas), normalize
-- into a dap-ready config, pick with a per-mode session cache, scaffold
-- new entries, and write pretty.
--
-- This file does no dap calls directly -- run.lua feeds the normalized
-- config to dap-go / dap.run. Keeping the two concerns separate means
-- `load()` can be called from anywhere (e.g. doctor) without side effects.

local config = require("gobugger.config")
local git = require("gobugger.git")
local buffers = require("gobugger.buffers")

local M = {}

local uv = vim.uv or vim.loop

local function notify(msg, level)
  local opts = {}
  if config.options.notify_title then opts.title = config.options.notify_title end
  vim.notify(msg, level or vim.log.levels.INFO, opts)
end

-- File-level parse cache keyed by (path, mtime). Holds the RAW parsed
-- table so different modes can filter it on demand without re-reading.
local cache = nil  -- { path, mtime, parsed }

-- Remembered pick per mode ("test" / "debug"). Cleared on reload or
-- :Gobugger pick. Survives edits to launch.json as long as the same name
-- still exists in the new file.
local session_pick = {}

local function global_cwd()
  return uv.cwd() or vim.fn.getcwd(-1, -1)
end

-- ===== Substitution =====
-- `${workspaceFolder}` is the only VSCode variable we resolve; it expands
-- to the *current* cwd at load time, so the same launch.json entry works
-- from any worktree that picks it up via the upward walk.

local function sub_workspace(v)
  if type(v) ~= "string" then return v end
  return (v:gsub("%${workspaceFolder}", global_cwd()))
end

local function sub_path(v)
  if type(v) ~= "string" then return v end
  return vim.fn.expand(sub_workspace(v))
end

-- ===== envFile parsing =====
-- Supports `KEY=VAL`, quoted values (stripped), leading `export `. Does
-- NOT handle escape sequences, mid-line comments, or multi-line values.

local function parse_envfile(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local out = {}
  for line in f:lines() do
    local s = line:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" and s:sub(1, 1) ~= "#" then
      s = s:gsub("^export%s+", "")
      local key, val = s:match("^([%a_][%w_%-%.]*)%s*=%s*(.*)$")
      if key then
        local q = val:sub(1, 1)
        if (q == '"' or q == "'") and #val >= 2 and val:sub(-1) == q then
          val = val:sub(2, -2)
        end
        out[key] = val
      end
    end
  end
  f:close()
  return out, nil
end

-- ===== JSONC stripping =====
-- VSCode's launch.json accepts `//` and `/* */` comments plus trailing
-- commas. We strip them before vim.json.decode chokes.

local function strip_json_comments(s)
  local out, i, n = {}, 1, #s
  local in_string, escape = false, false
  while i <= n do
    local c = s:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if escape then
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      local nl = s:find("\n", i + 2, true)
      i = nl or (n + 1)
    elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
      local close = s:find("*/", i + 2, true)
      i = close and (close + 2) or (n + 1)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function parse_launchjs(content)
  content = strip_json_comments(content)
  content = content:gsub(",(%s*[%]}])", "%1")
  local ok, data = pcall(vim.json.decode, content)
  if not ok then return nil, tostring(data) end
  return data, nil
end

-- ===== Path resolution (upward walk) =====
-- Start at cwd, check each level for launch.json, stop at the first
-- `.bare/` or `.git/` directory (project boundary). Gitfiles (linked
-- worktrees' `.git` FILE) are transparent, so a shared launch.json at
-- the project root is picked up from every worktree.

local function resolve_path(override)
  if override and override ~= "" then
    return vim.fn.fnamemodify(override, ":p")
  end
  local launch_paths = config.options.launch_paths
  local cur = global_cwd()
  local seen = {}
  while cur and cur ~= "" and not seen[cur] do
    seen[cur] = true
    for _, rel in ipairs(launch_paths) do
      local p = cur .. "/" .. rel
      if vim.fn.filereadable(p) == 1 then return p end
    end
    if vim.fn.isdirectory(cur .. "/.bare") == 1 then break end
    if vim.fn.isdirectory(cur .. "/.git") == 1 then break end
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

-- Build a set of known dap_type strings from the languages table so
-- filter_configs accepts configs for any registered language. Go's
-- dap_type is "go"; Rust would be "rust_analyzer" / "codelldb" etc.
local function known_dap_types()
  local set = {}
  for _, lc in pairs(config.options.languages or {}) do
    if lc.dap_type then set[lc.dap_type] = true end
  end
  return set
end

local function filter_configs(parsed, mode)
  if type(parsed) ~= "table" or type(parsed.configurations) ~= "table" then
    return {}
  end
  local types = known_dap_types()
  local out = {}
  for _, c in ipairs(parsed.configurations) do
    if types[c.type] and c.mode == mode then
      table.insert(out, c)
    end
  end
  return out
end

-- ===== Normalize =====
-- Translate a raw launch.json entry into a full dap-ready config.
-- Identity fields carried verbatim; path fields get ${workspaceFolder} +
-- shell substitution; buildFlags/env values get only ${workspaceFolder}
-- (so literal `$` in passwords / hashes survives).

local function normalize(raw)
  local out = {}
  out.name    = raw.name
  out.type    = raw.type
  out.request = raw.request
  out.mode    = raw.mode

  for _, k in ipairs({ "program", "cwd", "output" }) do
    if type(raw[k]) == "string" and raw[k] ~= "" then
      out[k] = sub_path(raw[k])
    end
  end

  if type(raw.args) == "table" then
    out.args = {}
    for _, a in ipairs(raw.args) do
      table.insert(out.args, sub_path(a))
    end
  end

  if type(raw.buildFlags) == "string" and raw.buildFlags ~= "" then
    out.buildFlags = sub_workspace(raw.buildFlags)
  end

  local merged = {}
  if type(raw.envFile) == "string" and raw.envFile ~= "" then
    local path = sub_path(raw.envFile)
    local parsed, err = parse_envfile(path)
    if parsed then
      for k, v in pairs(parsed) do merged[k] = v end
    else
      notify("envFile " .. tostring(err), vim.log.levels.WARN)
    end
  end
  if type(raw.env) == "table" then
    local xform = config.options.expand_env_values and sub_path or sub_workspace
    for k, v in pairs(raw.env) do merged[k] = xform(v) end
  end
  if next(merged) then out.env = merged end

  return out
end

local function mtime_of(path)
  local s = uv.fs_stat(path)
  return s and s.mtime and s.mtime.sec or nil
end

-- ===== File loading =====

local function ensure_parsed(override_path)
  local path = resolve_path(override_path)
  if not path then
    notify(
      "no launch.json found (searched " ..
      table.concat(config.options.launch_paths, ", ") .. " via upward walk)",
      vim.log.levels.WARN
    )
    cache = { path = nil, mtime = nil, parsed = nil }
    return false
  end

  local mtime = mtime_of(path)
  if cache and cache.path == path and cache.mtime == mtime
      and cache.parsed and not override_path then
    return true
  end

  local f = io.open(path, "r")
  if not f then
    notify("could not read " .. path, vim.log.levels.ERROR)
    cache = { path = path, mtime = mtime, parsed = nil }
    return false
  end
  local content = f:read("*a")
  f:close()

  local parsed, err = parse_launchjs(content)
  if not parsed then
    notify("parse failed: " .. tostring(err), vim.log.levels.ERROR)
    cache = { path = path, mtime = mtime, parsed = nil }
    return false
  end

  cache = { path = path, mtime = mtime, parsed = parsed }
  return true
end

-- Resolution cascade: config_name → session_pick → single-match → prompt.
-- On success, calls back with (cfg, nil). On failure, (nil, reason) where
-- reason is "no_matches" (no configs for this mode) or "cancelled" (the
-- user dismissed the picker). Callers use the reason to decide whether
-- to fall through to an adapter default or bail silently.
local function resolve(mode, callback)
  local matches = filter_configs(cache and cache.parsed or {}, mode)
  if #matches == 0 then
    callback(nil, "no_matches")
    return
  end

  local pinned = config.options.config_name or session_pick[mode]
  if pinned then
    for _, c in ipairs(matches) do
      if c.name == pinned then callback(normalize(c)); return end
    end
    if session_pick[mode] then session_pick[mode] = nil end
  end

  if #matches == 1 then
    callback(normalize(matches[1]))
    return
  end

  vim.ui.select(matches, {
    prompt = ("Pick a %s config:"):format(mode),
    format_item = function(c) return c.name end,
  }, function(choice)
    if not choice then callback(nil, "cancelled"); return end
    session_pick[mode] = choice.name
    notify(("picked '%s' (cached for this session; :Gobugger pick to reset)")
      :format(choice.name))
    callback(normalize(choice))
  end)
end

--- Async load. Callback fires with `(cfg, reason)`:
---   * `(cfg, nil)`        -- success: cfg is dap-ready
---   * `(nil, "no_launch_json")` -- no launch.json found via upward walk
---   * `(nil, "no_matches")`     -- launch.json exists but no configs for mode
---   * `(nil, "cancelled")`      -- user dismissed the picker
---   * `(nil, "parse_error")`    -- launch.json failed to parse (notify fired)
---@param override_path string?
---@param callback fun(config: table?, reason: string?)
---@param mode string?  "test" (default) or "debug"
function M.load(override_path, callback, mode)
  if not ensure_parsed(override_path) then
    callback(nil, "no_launch_json")
    return
  end
  resolve(mode or "test", callback)
end

--- Drop the file cache + all session picks and re-read from disk. Intended
--- to run after editing launch.json.
function M.reload(override_path)
  cache = nil
  session_pick = {}
  M.load(override_path, function() end, "test")
end

--- Clear the session pick for one mode (default "test"). Doesn't touch
--- the file cache -- just forces the next load() to prompt again.
function M.clear_pick(mode)
  session_pick[mode or "test"] = nil
  notify(("cleared session pick (%s)"):format(mode or "test"))
end

-- ===== Scaffolder =====
-- Interactive: write a new launch.json entry derived from the current
-- buffer. Works for any language registered in config.options.languages.

-- VSCode's conventional field order. Keys here render in this order;
-- unknowns fall to the end sorted alphabetically.
local JSON_FIELD_PRIORITY = {
  "version", "configurations",
  "name", "type", "request", "mode",
  "program", "cwd", "args", "env", "envFile",
  "buildFlags", "output",
}

local function cmp_keys(a, b)
  local idx = {}
  for i, k in ipairs(JSON_FIELD_PRIORITY) do idx[k] = i end
  local ia, ib = idx[a], idx[b]
  if ia and ib then return ia < ib end
  if ia then return true end
  if ib then return false end
  return a < b
end

local function encode_pretty(value, indent)
  indent = indent or ""
  local next_indent = indent .. "  "
  if type(value) == "table" then
    if vim.islist(value) then
      if #value == 0 then return "[]" end
      local parts = {}
      for _, v in ipairs(value) do
        table.insert(parts, next_indent .. encode_pretty(v, next_indent))
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end
    local keys = {}
    for k in pairs(value) do
      if type(k) == "string" then table.insert(keys, k) end
    end
    if #keys == 0 then return "{}" end
    table.sort(keys, cmp_keys)
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts,
        next_indent .. vim.json.encode(k) .. ": " ..
        encode_pretty(value[k], next_indent))
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  elseif type(value) == "string" then
    return vim.json.encode(value)
  elseif type(value) == "number" or type(value) == "boolean" then
    return tostring(value)
  end
  return "null"
end

-- Read the existing launch.json from .vscode/ or project root, or return
-- a fresh scaffold. We deliberately don't use the main parse cache here
-- so the scaffolder doesn't race with an in-flight reload.
local function load_or_new_launch(root)
  local fresh = { version = "0.2.0", configurations = {} }
  for _, rel in ipairs({ ".vscode/launch.json", "launch.json" }) do
    local path = root .. "/" .. rel
    if vim.fn.filereadable(path) == 1 then
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local parsed = parse_launchjs(content)
        if parsed then
          if type(parsed.configurations) ~= "table" then
            parsed.configurations = {}
          end
          return parsed
        end
      end
    end
  end
  return fresh
end

local function persist_launch(root, data)
  local vscode_dir = root .. "/.vscode"
  vim.fn.mkdir(vscode_dir, "p")
  local path = vscode_dir .. "/launch.json"
  local f, err = io.open(path, "w")
  if not f then
    notify("could not write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  f:write(encode_pretty(data) .. "\n")
  f:close()
  cache = nil
  session_pick = {}
  notify("wrote " .. path)
  return true
end

-- Per-language scaffolder hook. Loads lang/<name>.lua lazily and returns
-- its module (or nil if missing). Used to derive a suggested config name.
local function lang_module(cfg)
  local name = nil
  for key, lc in pairs(config.options.languages or {}) do
    if lc == cfg then name = key; break end
  end
  if not name then return nil end
  local ok, mod = pcall(require, "gobugger.lang." .. name)
  return ok and mod or nil
end

--- Scaffold a new launch.json entry derived from the current buffer.
--- `mode` is "test" or "debug"; the rest is filled via prompts. Writes
--- the entry to `<project-root>/.vscode/launch.json`, creating the
--- directory if necessary. Replaces any existing entry with the same
--- `name`; otherwise appends.
---@param mode string
function M.create_entry(mode)
  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local ft = vim.bo[bufnr].filetype
  local where = ("[buf %d, ft=%s, path=%s]"):format(
    bufnr, ft == "" and "<none>" or ft,
    file_path == "" and "<unnamed>" or file_path
  )

  local lang = config.lang_for_ft(ft)
  if not lang then
    notify(("no gobugger language for filetype '%s' %s"):format(ft, where),
      vim.log.levels.ERROR)
    return
  end
  if file_path == "" then
    notify("buffer has no file on disk " .. where, vim.log.levels.ERROR)
    return
  end

  local cwd = global_cwd()
  local root = git.project_root(cwd)
  if not root then
    notify("no project root (.bare/ or .git/) found walking up from cwd",
      vim.log.levels.ERROR)
    return
  end

  local pkg_dir = vim.fn.fnamemodify(file_path, ":p:h")
  local program_ref = "${workspaceFolder}"
  if pkg_dir:sub(1, #cwd) == cwd and #pkg_dir > #cwd then
    program_ref = "${workspaceFolder}/" .. pkg_dir:sub(#cwd + 2)
  end

  local lang_mod = lang_module(lang)
  local suggested = lang_mod and lang_mod.suggest_name
      and lang_mod.suggest_name(pkg_dir, mode)
    or ("Debug %s (%s)"):format(
      mode == "test" and "Test" or "Main",
      vim.fn.fnamemodify(pkg_dir, ":t")
    )

  local function finish(entry)
    local existing = load_or_new_launch(root)
    local replaced = false
    for i, c in ipairs(existing.configurations) do
      if c.name == entry.name then
        existing.configurations[i] = entry
        replaced = true
        break
      end
    end
    if not replaced then table.insert(existing.configurations, entry) end
    if persist_launch(root, existing) then
      notify(("%s entry '%s' (mode=%s, program=%s)"):format(
        replaced and "replaced" or "added", entry.name, mode, entry.program))
    end
  end

  vim.ui.input({ prompt = "Config name: ", default = suggested }, function(name)
    if not name or vim.trim(name) == "" then return end
    name = vim.trim(name)

    local entry = {
      name    = name,
      type    = lang.dap_type,
      request = "launch",
      mode    = mode,
      program = program_ref,
    }

    local function prompt_env()
      vim.ui.input({
        prompt = "env inline (KEY=VAL;KEY=VAL, blank = none): ",
      }, function(env_str)
        if env_str == nil then return end
        if env_str ~= "" then
          local parsed = buffers.parse_inline_env(env_str)
          if next(parsed) then entry.env = parsed end
        end
        vim.ui.input({ prompt = "envFile path (blank = none): " }, function(envfile)
          if envfile == nil then return end
          if envfile ~= "" then entry.envFile = envfile end
          vim.ui.input({
            prompt = "buildFlags (blank = none): ",
            default = lang.default_build_flags or "",
          }, function(build_flags)
            if build_flags == nil then return end
            if build_flags ~= "" then entry.buildFlags = build_flags end
            finish(entry)
          end)
        end)
      end)
    end

    -- Tests don't prompt for args -- dap-go.debug_test() inserts
    -- `-test.run ^TestName$` from the cursor at runtime, so pinning
    -- args here would fight that.
    if mode == "debug" then
      vim.ui.input({
        prompt = "Program args (space-separated, blank = none): ",
      }, function(args_str)
        if args_str == nil then return end
        if args_str ~= "" then entry.args = buffers.split_args(args_str) end
        prompt_env()
      end)
    else
      prompt_env()
    end
  end)
end

-- ===== Doctor / Fix =====

function M.doctor()
  local cwd = global_cwd()
  local lines = { "gobugger doctor", "───────────────" }
  local add = function(k, v) lines[#lines + 1] = ("%-18s %s"):format(k .. ":", v) end

  local lj = resolve_path(nil)
  add("launch.json", lj or "<not found via upward walk>")

  local root = git.project_root(cwd)
  local root_marker = "<none>"
  if root then
    if vim.fn.isdirectory(root .. "/.bare") == 1 then
      root_marker = ".bare/"
    elseif vim.fn.isdirectory(root .. "/.git") == 1 then
      root_marker = git.is_bare(root .. "/.git")
        and ".git/ (bare)" or ".git/ (regular repo)"
    end
  end
  add("project root", root and (root .. "  [" .. root_marker .. "]") or "<not found>")
  add("cwd", cwd)

  local cwd_git = cwd .. "/.git"
  local git_kind = "<absent>"
  if vim.fn.isdirectory(cwd_git) == 1 then
    git_kind = "directory"
  elseif vim.fn.filereadable(cwd_git) == 1 then
    local target, exists = git.parse_gitfile(cwd_git)
    if target then
      git_kind = ("gitfile → %s  [%s]"):format(target, exists and "OK" or "MISSING")
    else
      git_kind = "gitfile (unparseable)"
    end
  end
  add("cwd .git", git_kind)

  local ok, code, msg = git.status_check(cwd)
  add("git status", ok and "OK" or ("exit %d -- %s"):format(code, msg))

  local common = git.common_dir(cwd)
  add("git common dir", common or "<not in a git repo>")

  local mod = git.module_root_go(cwd)
  add("go module root",
    mod and (mod .. "  [go.mod present]") or "<no go.mod found>")

  if lj and ensure_parsed(nil) and cache and cache.parsed then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Configs:"
    for _, m in ipairs({ "test", "debug" }) do
      local matches = filter_configs(cache.parsed, m)
      local header = ("  mode=%-5s (%d):"):format(m, #matches)
      if #matches == 0 then
        lines[#lines + 1] = header .. " <none>"
      else
        for i, c in ipairs(matches) do
          local marker = session_pick[m] == c.name and "  [session pick]" or ""
          lines[#lines + 1] = (i == 1 and header or "                   ")
            .. " " .. (c.name or "<unnamed>") .. marker
        end
      end
    end
  end

  notify(table.concat(lines, "\n"))
end

function M.fix_worktree()
  local cwd = global_cwd()
  local common = git.common_dir(cwd)
  if not common then
    notify("not inside a git repo (cwd=" .. cwd .. "); cannot repair",
      vim.log.levels.ERROR)
    return
  end
  local ok, out = git.worktree_repair(common)
  if not ok then
    notify("git worktree repair failed:\n" .. out, vim.log.levels.ERROR)
    return
  end
  local trimmed = vim.trim(out)
  notify("git worktree repair @ " .. common ..
    (trimmed ~= "" and ("\n" .. trimmed) or ""))
end

return M
