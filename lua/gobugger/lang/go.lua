-- Go-specific knobs for the scaffolder. Mirror the shape of this file
-- when adding another language -- the `lang` table returned here ends up
-- on the per-buffer language path in launch.lua.

local M = {}

M.filetype = "go"
M.dap_type = "go"

-- Suggested name for a new launch.json entry. The scaffolder calls this
-- to pre-fill the name prompt with something recognisable.
---@param pkg_dir string  Absolute path to the package directory.
---@param mode string     "test" or "debug".
---@return string
function M.suggest_name(pkg_dir, mode)
  local pkg = vim.fn.fnamemodify(pkg_dir, ":t")
  local kind = mode == "test" and "Test" or "Main"
  return ("Go: Debug %s (%s)"):format(kind, pkg)
end

return M
