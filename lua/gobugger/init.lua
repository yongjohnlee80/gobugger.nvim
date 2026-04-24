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
--   require("gobugger").run_test()          -- pick + run a mode=test config
--   require("gobugger").run_debug()         -- pick + run a mode=debug config
--   require("gobugger").run_last()          -- dap.run_last()
--   require("gobugger").attach_remote(port?)-- connect to a pre-running dlv server
--   require("gobugger").new_test()          -- scaffold a new mode=test entry
--   require("gobugger").new_debug()         -- scaffold a new mode=debug entry
--   require("gobugger").reload()            -- clear caches + session picks
--   require("gobugger").clear_pick(mode?)
--   require("gobugger").doctor()
--   require("gobugger").fix_worktree()
--   require("gobugger").last_error()        -- open last failed-start stderr in a scratch buffer
--   require("gobugger").default_keymaps()

local config = require("gobugger.config")

local M = {}

--- Initialize gobugger. Merges user opts over defaults, wires sign
--- glyphs, dap-view, and the winfixbuf guard.
---@param opts table?
function M.setup(opts)
  config.setup(opts)
  require("gobugger.ui").setup()
  require("gobugger.errors").setup()

  -- nvim-dap-go registers its default `dap.configurations.go` entries
  -- ("Debug", "Attach", "Debug test", ...) from inside its setup(). If
  -- the user hasn't called it themselves, gobugger's <leader>da (which
  -- runs the "Attach" config) would find nothing to run. Idempotent,
  -- so calling unconditionally is safe.
  local dg_ok, dg = pcall(require, "dap-go")
  if dg_ok and type(dg.setup) == "function" then
    pcall(dg.setup)
  end
end

-- Lazy module accessors keep require() off the hot path during setup()
-- and let reload-without-restart work cleanly.
local function launch() return require("gobugger.launch") end
local function run() return require("gobugger.run") end

function M.run_test(path)    run().run_test(path) end
function M.run_debug(path)   run().run_debug(path) end
function M.run_last()        run().run_last() end

--- Connect to a pre-running `dlv --headless --listen=:PORT` server.
---
--- Complements M.default_keymaps's <leader>da (PID-picker local attach),
--- which always spawns a fresh dlv. attach_remote is for when dlv was
--- started externally — typical flows:
---   * `/run <app> --dlv` (auto-attaches dlv headless on 2345..2355)
---   * manual `sudo dlv attach <pid> --headless --listen=:2345` (Linux
---     with ptrace_scope=1 can't attach from inside nvim, so you run
---     dlv as root in a separate terminal and connect from nvim)
---   * dlv on a remote host (change host via a config opt later)
---
--- Registers `dap.adapters.go_attach` as a pure server adapter — no
--- `executable`, so nvim-dap just TCP-connects. This matters because
--- nvim-dap-go's default `go` adapter ALWAYS spawns `dlv dap -l :port`
--- even for mode="remote", which races against the existing dlv on
--- the target port. The race accidentally resolves the right way on
--- macOS and the wrong way on Linux — go_attach sidesteps it entirely.
---
---@param port number? dlv listen port; prompts if nil (default 2345)
function M.attach_remote(port)
  local dap = require("dap")
  if not dap.adapters.go_attach then
    dap.adapters.go_attach = function(cb, cfg)
      cb({ type = "server", host = cfg.host or "127.0.0.1", port = cfg.port or 2345 })
    end
  end

  if port == nil then
    local input = vim.fn.input("dlv server port: ", "2345")
    port = tonumber(input)
    if not port then
      vim.notify("gobugger.attach_remote: invalid port", vim.log.levels.WARN)
      return
    end
  end

  dap.run({
    type = "go_attach",
    name = ("Attach remote :%d"):format(port),
    mode = "remote",
    request = "attach",
    host = "127.0.0.1",
    port = port,
    -- dlv's --api-version=2 DAP bridge returns an error for
    -- setExceptionBreakpoints; passing an empty list skips the
    -- request and suppresses the harmless warning at attach time.
    exceptionBreakpoints = {},
  })
end

function M.new_test()        launch().create_entry("test") end
function M.new_debug()       launch().create_entry("debug") end
function M.reload(path)      launch().reload(path) end
function M.clear_pick(mode)  launch().clear_pick(mode) end
function M.doctor()          launch().doctor() end
function M.fix_worktree()    launch().fix_worktree() end
function M.last_error()      require("gobugger.errors").open_last() end

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
  -- dap-go only gates whether <leader>da is wired (it runs the Attach
  -- config out of dap.configurations.go, not a dap-go module method).
  local dg_ok = pcall(require, "dap-go")

  -- Lazy bootstrap order isn't guaranteed to fully init every dap module
  -- before our config() runs -- some deps can land as bare requires with
  -- methods not yet attached. Skip any binding whose target is nil
  -- instead of crashing the whole default_keymaps pass.
  local function bind(mode, lhs, rhs, desc)
    if type(rhs) ~= "function" and type(rhs) ~= "string" then return end
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
  end

  if dap_ok then
    bind("n", "<F9>",       dap.continue,          "Debug: Continue / Start")
    bind("n", "<F8>",       dap.step_over,         "Debug: Step Over")
    bind("n", "<F7>",       dap.step_into,         "Debug: Step Into")
    bind("n", "<F10>",      dap.step_out,          "Debug: Step Out")
    bind("n", "<leader>db", dap.toggle_breakpoint, "Debug: Toggle Breakpoint")
    bind("n", "<leader>dB", dap.set_breakpoint and function()
      dap.set_breakpoint(vim.fn.input("Breakpoint condition: "))
    end, "Debug: Conditional Breakpoint")
    bind("n", "<leader>dC", dap.clear_breakpoints, "Debug: Clear Breakpoints")
    bind("n", "<leader>dc", dap.continue,          "Debug: Continue / Start")
    bind("n", "<leader>dr", dap.run_last,          "Debug: Run Last")
    bind("n", "<leader>dq", dap.terminate,         "Debug: Terminate")
    bind("n", "<leader>dR", dap.restart,           "Debug: Restart")
  end

  if dv_ok then
    bind("n",         "<leader>dv", dv.toggle,   "Debug: Toggle View")
    bind({ "n", "v" }, "<leader>dw", dv.add_expr, "Debug: Watch Expr (add)")
    bind({ "n", "v" }, "<leader>de", dv.eval,     "Debug: Evaluate")
  end

  if dg_ok then
    -- nvim-dap-go doesn't expose an `attach` function; instead it
    -- registers a config named "Attach" in `dap.configurations.go`
    -- (processId = filtered_pick_process — opens a PID picker). Run
    -- that config directly so <leader>da goes straight into the PID
    -- picker instead of the full `dap.continue()` config list.
    bind("n", "<leader>da", function()
      for _, cfg in ipairs((dap_ok and dap.configurations.go) or {}) do
        if cfg.name == "Attach" then
          dap.run(cfg)
          return
        end
      end
      vim.notify(
        "[gobugger] no 'Attach' config found in dap.configurations.go — " ..
        "is dap-go.setup() running?",
        vim.log.levels.WARN
      )
    end, "Debug: Attach to Process (delve)")
  end

  -- <leader>dA: connect to a pre-running `dlv --headless --listen=:PORT`
  -- server. Complements <leader>da, which spawns a fresh dlv and picks
  -- a PID locally — that flow can't reach a dlv that was started
  -- externally (CLI, `/run <app> --dlv`, a remote box). Goes through
  -- M.attach_remote() which registers a pure connect-only adapter so
  -- nvim-dap doesn't try to spawn its own dlv.
  if dap_ok then
    bind("n", "<leader>dA", function() M.attach_remote() end, "Debug: Attach to remote dlv server")
  end

  -- launch.json-driven flows. These don't need their target plugin to
  -- exist at keymap-registration time -- the call sites pcall-require on
  -- invocation, so the maps are safe to bind eagerly.
  bind("n", "<leader>dt", function() M.run_test() end,    "Debug: Test (+launch.json)")
  bind("n", "<leader>dm", function() M.run_debug() end,   "Debug: Main (+launch.json)")
  bind("n", "<leader>dM", function() M.new_debug() end,   "Debug: New Main entry (+launch.json)")
  bind("n", "<leader>dN", function() M.new_test() end,    "Debug: New Test entry (+launch.json)")
  -- "Run last" lives on <leader>dr (bound above, `dap.run_last()`). It
  -- replays whatever the last dap session was — test or debug — which is
  -- the standard nvim-dap convention. No separate gobugger binding here.
  bind("n", "<leader>dL", function() M.reload() end,      "Debug: Reload launch.json + clear picks")
  bind("n", "<leader>dD", function() M.doctor() end,      "Debug: Doctor")
  bind("n", "<leader>dE", function() M.last_error() end,  "Debug: Open last failed-start error in scratch buffer")
  bind("n", "<leader>dF", function() M.fix_worktree() end, "Debug: Fix worktree (git worktree repair)")
end

return M
