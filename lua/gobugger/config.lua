-- Defaults + setup merge. Nothing here depends on other gobugger modules;
-- keeping it free of requires lets other files pull in config without
-- creating cycles.

local M = {}

M.defaults = {
  -- Title on vim.notify calls. Set to `false` to omit.
  notify_title = "gobugger",

  -- Paths searched (in order) for launch.json. The resolver walks upward
  -- from cwd checking these at each level.
  launch_paths = { ".vscode/launch.json", "launch.json" },

  -- Hard pin: when set, skip the picker and always use the config with
  -- this `name`. Applies across modes.
  config_name = nil,

  -- If true, `vim.fn.expand()` runs on inline env values too. Default
  -- false so literal `$` in values (passwords, bcrypt hashes, cron exprs)
  -- survives.
  expand_env_values = false,

  -- Workspace-rooted LSP servers that need a stop+restart when cwd
  -- switches so their `root_dir` re-resolves against the new worktree.
  -- This plugin doesn't switch cwd; the hook is exposed for users who
  -- integrate with a worktree-switcher (e.g. worktree.nvim).
  lsp_servers_to_restart = {},

  -- Directory name for the bare repo in worktree setups. Used by the
  -- project-root walk. Two conventions in the wild: ".bare" (default)
  -- and ".git" (bare lives directly in .git/).
  bare_dir = ".bare",

  -- UI to inject on setup:
  --   "dap-view"   -- bundled opinionated layout (default)
  --   false        -- no UI wiring; you handle it yourself
  --   <table>      -- passed through as dap-view opts
  ui = "dap-view",

  -- DAP sign column glyphs. Set to `false` to skip sign wiring.
  sign_glyphs = {
    DapBreakpoint          = { text = "●", texthl = "DiagnosticError", linehl = "", numhl = "" },
    DapBreakpointCondition = { text = "◆", texthl = "DiagnosticError", linehl = "", numhl = "" },
    DapBreakpointRejected  = { text = "○", texthl = "DiagnosticWarn",  linehl = "", numhl = "" },
    DapLogPoint            = { text = "◆", texthl = "DiagnosticInfo",  linehl = "", numhl = "" },
    DapStopped             = { text = "▶", texthl = "DiagnosticWarn",  linehl = "Visual", numhl = "" },
  },

  -- Per-language settings. Go is first-class; other languages go here
  -- once their adapters + scaffolder hooks are written.
  --   filetype              -- nvim filetype string (buffer-level match)
  --   dap_type              -- DAP adapter name used in `type` field
  --   default_build_flags   -- pre-filled into the scaffolder buildFlags prompt
  languages = {
    go = {
      filetype = "go",
      dap_type = "go",
      default_build_flags = "-buildvcs=false",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

-- Look up the language config for a filetype. Returns nil when the
-- filetype isn't one we know about (caller decides what to do).
function M.lang_for_ft(ft)
  for _, cfg in pairs(M.options.languages or {}) do
    if cfg.filetype == ft then return cfg end
  end
  return nil
end

return M
