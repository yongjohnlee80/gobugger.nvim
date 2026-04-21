-- Git / worktree helpers. Pure shell wrappers + a gitfile parser. None of
-- these touch DAP or launch.json; they're consumed by doctor / fix and
-- the project-root walk.

local M = {}

local function run(args)
  return vim.system(args, { text = true }):wait()
end

--- Absolute path to the repo's common dir (bare or `.git/`). Works in any
--- worktree. nil when `path` isn't inside a git repo.
---@param path string
---@return string?
function M.common_dir(path)
  local res = run({
    "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir",
  })
  if res.code ~= 0 then return nil end
  local out = (res.stdout or ""):gsub("%s+$", "")
  return out ~= "" and out or nil
end

--- Parse a `.git` gitfile and return `(resolved_gitdir, exists_on_disk)`.
--- `(nil, nil)` when the file isn't a parseable gitfile.
---@param path string
---@return string?, boolean?
function M.parse_gitfile(path)
  local f = io.open(path, "r")
  if not f then return nil, nil end
  local content = f:read("*a") or ""
  f:close()
  local gitdir = content:match("^gitdir:%s*(.-)%s*$")
  if not gitdir then return nil, nil end
  if not gitdir:match("^/") then
    gitdir = vim.fn.fnamemodify(path, ":h") .. "/" .. gitdir
  end
  return gitdir, vim.fn.isdirectory(gitdir) == 1
end

--- Walk up from `start` looking for `go.mod`. Returns the module root dir
--- or nil if not inside a Go module.
---@param start string
---@return string?
function M.module_root_go(start)
  local cur = start
  local seen = {}
  while cur and cur ~= "" and not seen[cur] do
    seen[cur] = true
    if vim.fn.filereadable(cur .. "/go.mod") == 1 then return cur end
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

--- Walk up from `start` looking for a project boundary (`.bare/` or
--- `.git/` directory). Returns the dir on success, nil otherwise. Gitfiles
--- (linked worktrees) are transparent to this walk -- only a `.git/` as a
--- directory is treated as a boundary, which correctly picks up the bare
--- in worktree layouts without getting distracted by child worktrees.
---@param start string
---@return string?
function M.project_root(start)
  local cur = start
  local seen = {}
  while cur and cur ~= "" and not seen[cur] do
    seen[cur] = true
    if vim.fn.isdirectory(cur .. "/.bare") == 1 then return cur end
    if vim.fn.isdirectory(cur .. "/.git") == 1 then return cur end
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

--- `git status --porcelain` at `path`. Returns (ok, exit_code, first_err_line).
--- Used by the doctor to surface exactly why git is unhappy here.
---@param path string
---@return boolean, integer, string?
function M.status_check(path)
  local res = run({ "git", "-C", path, "status", "--porcelain" })
  if res.code == 0 then return true, 0, nil end
  local stderr = res.stderr or ""
  return false, res.code, stderr:match("([^\n]+)") or "(no stderr)"
end

--- `git -C <common> worktree repair`. Fixes stale gitfile pointers across
--- all linked worktrees of the bare. Returns (ok, combined_output).
---@param common_dir string
---@return boolean, string
function M.worktree_repair(common_dir)
  local res = run({ "git", "-C", common_dir, "worktree", "repair" })
  return res.code == 0, (res.stdout or "") .. (res.stderr or "")
end

--- True if the given `.git/` directory is a bare repo (`core.bare=true`).
--- Lets the doctor distinguish regular-repo `.git/` from bare-repo `.git/`.
---@param git_dir string
---@return boolean
function M.is_bare(git_dir)
  local res = run({ "git", "-C", git_dir, "rev-parse", "--is-bare-repository" })
  if res.code ~= 0 then return false end
  return vim.trim(res.stdout or "") == "true"
end

return M
