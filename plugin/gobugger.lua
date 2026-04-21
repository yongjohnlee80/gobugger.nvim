-- gobugger.nvim -- plugin entry. Registers :Gobugger with subcommand
-- completion and dispatches to the public API. User config + keymaps
-- live in the user's `setup(opts)` and optional `default_keymaps()` call.

if vim.g.loaded_gobugger == 1 then return end
vim.g.loaded_gobugger = 1

local SUBCOMMANDS = {
  run       = function(_)       require("gobugger").run_debug() end,
  test      = function(_)       require("gobugger").run_test() end,
  ["run-last"] = function(_)    require("gobugger").run_last() end,
  new       = function(args)
    local target = args[1] or "debug"
    if target == "test" then
      require("gobugger").new_test()
    elseif target == "main" or target == "debug" then
      require("gobugger").new_debug()
    else
      vim.notify("[gobugger] :Gobugger new { main | test }", vim.log.levels.ERROR)
    end
  end,
  doctor    = function(_)       require("gobugger").doctor() end,
  fix       = function(_)       require("gobugger").fix_worktree() end,
  reload    = function(_)       require("gobugger").reload() end,
  pick      = function(args)    require("gobugger").clear_pick(args[1]) end,
}

vim.api.nvim_create_user_command("Gobugger", function(cmd)
  local tokens = vim.split(cmd.args, "%s+", { trimempty = true })
  if #tokens == 0 then
    vim.notify(
      "[gobugger] :Gobugger { run | test | run-last | new | doctor | fix | reload | pick }",
      vim.log.levels.ERROR
    )
    return
  end
  local sub = tokens[1]
  local rest = {}
  for i = 2, #tokens do table.insert(rest, tokens[i]) end

  local fn = SUBCOMMANDS[sub]
  if not fn then
    vim.notify("[gobugger] unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
    return
  end
  fn(rest)
end, {
  nargs = "+",
  complete = function(arglead, cmdline, _)
    local tokens = vim.split(cmdline, "%s+", { trimempty = true })
    local on_first = #tokens <= 1 or (#tokens == 2 and not cmdline:match("%s$"))

    local function filter(list)
      return vim.tbl_filter(function(x) return vim.startswith(x, arglead) end, list)
    end

    if on_first then
      return filter({
        "run", "test", "run-last", "new",
        "doctor", "fix", "reload", "pick",
      })
    end
    if tokens[2] == "new" then return filter({ "main", "test" }) end
    if tokens[2] == "pick" then return filter({ "test", "debug" }) end
    return {}
  end,
  desc = "gobugger: run | test | run-last | new | doctor | fix | reload | pick",
})
