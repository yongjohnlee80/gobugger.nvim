-- Thin dispatchers from launch.json → DAP. Two main flows:
--
--   run_test(path?)   → pick a mode=test  config, hand to dap-go.debug_test
--   run_debug(path?)  → pick a mode=debug config, hand to dap.run
--
-- launch.lua does the heavy lifting (resolve, parse, pick, cache); this
-- file stays boring on purpose.

local launch = require("gobugger.launch")
local config = require("gobugger.config")

local M = {}

local function notify(msg, level)
  local opts = {}
  if config.options.notify_title then opts.title = config.options.notify_title end
  vim.notify(msg, level or vim.log.levels.INFO, opts)
end

-- Open nvim-dap-view before a session starts. The before.launch /
-- before.attach listeners registered in ui.lua also fire on every dap
-- session, but invoking explicitly here makes the open deterministic
-- even if a user overrides those listeners, and it gets the panel on
-- screen a beat earlier so the REPL / scopes panels render as the
-- adapter initializes.
-- Respects `ui = false` in setup opts so users who disable dap-view
-- wiring don't get it forced open.
local function open_view()
  if config.options.ui == false then return end
  local ok, dv = pcall(require, "dap-view")
  if ok then pcall(dv.open) end
end

--- Debug the test under the cursor, with launch.json env/buildFlags merged
--- in when a matching `mode=test` config exists. When none does (no
--- launch.json, no matches), falls through to dap-go's defaults -- runs
--- the test under the cursor with no buildFlags / env overrides. User
--- cancellation of the picker is respected (no fall-through).
---
--- Test selection (`-test.run ^TestName$`) is always driven by
--- nvim-dap-go at runtime from the cursor position.
function M.run_test(override_path)
  local ok, dap_go = pcall(require, "dap-go")
  if not ok then
    notify("require('dap-go') failed — install nvim-dap-go", vim.log.levels.ERROR)
    return
  end
  launch.load(override_path, function(cfg, reason)
    if reason == "cancelled" or reason == "parse_error" then return end
    open_view()
    if cfg and next(cfg) then
      dap_go.debug_test(cfg)
    else
      -- no_launch_json or no_matches → dap-go defaults
      dap_go.debug_test()
    end
  end, "test")
end

--- Launch a main-program debug session from a mode=debug config. Hands
--- the fully-normalized config to dap.run -- program, args, env, etc.
--- come straight from launch.json. No fall-through: without a config,
--- dap.run has nothing to launch.
function M.run_debug(override_path)
  local ok, dap = pcall(require, "dap")
  if not ok then
    notify("require('dap') failed — install nvim-dap", vim.log.levels.ERROR)
    return
  end
  launch.load(override_path, function(cfg, reason)
    if reason == "cancelled" or reason == "parse_error" then return end
    if not cfg or not next(cfg) then
      if reason == "no_launch_json" then
        notify(
          "no launch.json found -- create a mode=debug entry first (<leader>dM)",
          vim.log.levels.WARN
        )
      else
        notify(
          "no mode=debug configs in launch.json -- scaffold one with <leader>dM",
          vim.log.levels.WARN
        )
      end
      return
    end
    open_view()
    dap.run(cfg)
  end, "debug")
end

--- Thin wrapper around `dap.run_last()`. Here for symmetry with the
--- other `:Gobugger` subcommands so users don't need to bind dap APIs
--- directly for the common flows.
function M.run_last()
  local ok, dap = pcall(require, "dap")
  if not ok then
    notify("require('dap') failed", vim.log.levels.ERROR)
    return
  end
  open_view()
  dap.run_last()
end

return M
