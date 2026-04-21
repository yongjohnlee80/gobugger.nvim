-- UI injection: sign glyphs, dap-view wiring, and the winfixbuf guard
-- that keeps DAP's jump_to_frame from exploding against pinned windows.
--
-- Called once from init.setup(); idempotent so re-sourcing doesn't
-- double-register listeners (they're keyed by name).

local config = require("gobugger.config")

local M = {}

local function setup_signs()
  local glyphs = config.options.sign_glyphs
  if not glyphs then return end
  for name, opts in pairs(glyphs) do
    vim.fn.sign_define(name, opts)
  end
end

-- When DAP hits a breakpoint it calls nvim_win_set_buf on the current
-- window to show the source. If that window has `winfixbuf` set
-- (neo-tree, dap-view panel, help buffers, etc.) the set-buf fails with
-- E1513 and the whole jump_to_frame chain explodes.
--
-- Before event_stopped fires jump_to_frame, bounce focus to a regular
-- editing window. If no such window exists on the current tab, open one
-- so DAP has somewhere to land.
local function setup_winfixbuf_guard()
  local dap_ok, dap = pcall(require, "dap")
  if not dap_ok then return end

  dap.listeners.before.event_stopped["gobugger-avoid-winfixbuf"] = function()
    if not vim.wo.winfixbuf then return end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if not vim.wo[win].winfixbuf and vim.bo[buf].buftype == "" then
        vim.api.nvim_set_current_win(win)
        return
      end
    end
    vim.cmd("topleft new")
  end
end

-- Wire up dap-view: setup with either the bundled opinionated layout or
-- user-supplied opts, then auto-open on session start + auto-close on
-- exit. Listener keys are namespaced so repeat calls idempotently replace.
local function setup_dap_view()
  local ui_opt = config.options.ui
  if ui_opt == false then return end

  local dap_ok, dap = pcall(require, "dap")
  local dv_ok, dv = pcall(require, "dap-view")
  if not (dap_ok and dv_ok) then
    vim.notify(
      "[gobugger] ui is enabled but nvim-dap and/or nvim-dap-view aren't installed",
      vim.log.levels.WARN
    )
    return
  end

  local dv_opts
  if type(ui_opt) == "table" then
    dv_opts = ui_opt
  else
    -- "dap-view" sentinel (or any truthy non-table) → opinionated defaults.
    dv_opts = {
      winbar = {
        show = true,
        sections = {
          "watches", "scopes", "exceptions",
          "breakpoints", "threads", "repl",
        },
        default_section = "scopes",
      },
      windows = {
        size = 12,
        terminal = { position = "right" },
      },
    }
  end

  dv.setup(dv_opts)

  dap.listeners.before.attach["gobugger-dap-view"]           = function() dv.open() end
  dap.listeners.before.launch["gobugger-dap-view"]           = function() dv.open() end
  dap.listeners.before.event_terminated["gobugger-dap-view"] = function() dv.close() end
  dap.listeners.before.event_exited["gobugger-dap-view"]     = function() dv.close() end
end

function M.setup()
  setup_signs()
  setup_dap_view()
  setup_winfixbuf_guard()
end

return M
