-- gobugger.nvim -- opinionated Go debugger built on nvim-dap + nvim-dap-go
-- + nvim-dap-view, with launch.json-driven configs, worktree-aware
-- resolution, delve integration, and a scaffolder + doctor for when
-- things go sideways.
--
-- Go is first-class; the per-language table in config leaves room for
-- Rust / Python / etc. once their scaffolder hooks are written.
--
-- Public API:
--   require("gobugger").setup(opts)
--   require("gobugger").run_test()      -- pick + run a mode=test config
--   require("gobugger").run_debug()     -- pick + run a mode=debug config
--   require("gobugger").run_last()      -- dap.run_last()
--   require("gobugger").new_test()      -- scaffold a new mode=test entry
--   require("gobugger").new_debug()     -- scaffold a new mode=debug entry
--   require("gobugger").reload()        -- clear caches + session picks
--   require("gobugger").clear_pick(mode?)
--   require("gobugger").doctor()
--   require("gobugger").fix_worktree()
--   require("gobugger").default_keymaps()

local config = require("gobugger.config")

local M = {}

--- Initialize gobugger. Merges user opts over defaults, wires sign
--- glyphs, dap-view, and the winfixbuf guard.
---@param opts table?
function M.setup(opts)
  config.setup(opts)
  require("gobugger.ui").setup()
end

-- Lazy module accessors keep require() off the hot path during setup()
-- and let reload-without-restart work cleanly.
local function launch() return require("gobugger.launch") end
local function run() return require("gobugger.run") end

function M.run_test(path)    run().run_test(path) end
function M.run_debug(path)   run().run_debug(path) end
function M.run_last()        run().run_last() end
function M.new_test()        launch().create_entry("test") end
function M.new_debug()       launch().create_entry("debug") end
function M.reload(path)      launch().reload(path) end
function M.clear_pick(mode)  launch().clear_pick(mode) end
function M.doctor()          launch().doctor() end
function M.fix_worktree()    launch().fix_worktree() end

--- Register an opinionated keymap set under `<leader>d*` + the standard
--- F-keys. Call this after `setup()` if you don't want to write every
--- binding yourself. Override individual maps afterwards with
--- `vim.keymap.set` (your call wins since it runs last).
---
--- Only the bindings whose target plugin is loadable are registered --
--- missing dap-view / dap-go silently skip their maps.
function M.default_keymaps()
  local dap_ok, dap = pcall(require, "dap")
  local dv_ok, dv = pcall(require, "dap-view")
  local dg_ok, dg = pcall(require, "dap-go")
  local set = vim.keymap.set

  if dap_ok then
    set("n", "<F9>",        dap.continue,           { desc = "Debug: Continue / Start" })
    set("n", "<F8>",        dap.step_over,          { desc = "Debug: Step Over" })
    set("n", "<F7>",        dap.step_into,          { desc = "Debug: Step Into" })
    set("n", "<F10>",       dap.step_out,           { desc = "Debug: Step Out" })
    set("n", "<leader>db",  dap.toggle_breakpoint,  { desc = "Debug: Toggle Breakpoint" })
    set("n", "<leader>dB",  function()
      dap.set_breakpoint(vim.fn.input("Breakpoint condition: "))
    end, { desc = "Debug: Conditional Breakpoint" })
    set("n", "<leader>dC",  dap.clear_breakpoints,  { desc = "Debug: Clear Breakpoints" })
    set("n", "<leader>dc",  dap.continue,           { desc = "Debug: Continue / Start" })
    set("n", "<leader>dr",  dap.run_last,           { desc = "Debug: Run Last" })
    set("n", "<leader>dq",  dap.terminate,          { desc = "Debug: Terminate" })
    set("n", "<leader>dR",  dap.restart,            { desc = "Debug: Restart" })
  end

  if dv_ok then
    set("n",         "<leader>dv", dv.toggle,    { desc = "Debug: Toggle View" })
    set({ "n", "v" }, "<leader>dw", dv.add_expr, { desc = "Debug: Watch Expr (add)" })
    set({ "n", "v" }, "<leader>de", dv.eval,     { desc = "Debug: Evaluate" })
  end

  if dg_ok then
    set("n", "<leader>da", dg.attach,
      { desc = "Debug: Attach to Process (delve)" })
  end

  -- launch.json-driven flows. These don't need their target plugin to
  -- exist at keymap-registration time -- the call sites pcall-require on
  -- invocation, so the maps are safe to bind eagerly.
  set("n", "<leader>dt", function() M.run_test() end,
    { desc = "Debug: Test (+launch.json)" })
  set("n", "<leader>dm", function() M.run_debug() end,
    { desc = "Debug: Main (+launch.json)" })
  set("n", "<leader>dM", function() M.new_debug() end,
    { desc = "Debug: New Main entry (+launch.json)" })
  set("n", "<leader>dN", function() M.new_test() end,
    { desc = "Debug: New Test entry (+launch.json)" })
  set("n", "<leader>dT", function() M.run_last() end,
    { desc = "Debug: Run Last" })
  set("n", "<leader>dL", function() M.reload() end,
    { desc = "Debug: Reload launch.json + clear picks" })
  set("n", "<leader>dD", function() M.doctor() end,
    { desc = "Debug: Doctor" })
  set("n", "<leader>dF", function() M.fix_worktree() end,
    { desc = "Debug: Fix worktree (git worktree repair)" })
end

return M
