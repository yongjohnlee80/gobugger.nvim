-- Small buffer-adjacent helpers: argument splitting and inline env parsing
-- used by the scaffolder prompts. Kept here so the launch-json module stays
-- focused on its own lifecycle.

local M = {}

--- Naive space-split honoring simple double-quoted tokens. Strips the
--- surrounding quotes. Does not handle escaped quotes, single quotes, or
--- backticks -- complex args should be edited directly in launch.json.
---@param s string
---@return string[]
function M.split_args(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    while i <= n and s:sub(i, i):match("%s") do i = i + 1 end
    if i > n then break end
    local c = s:sub(i, i)
    if c == '"' then
      local close = s:find('"', i + 1, true)
      if close then
        table.insert(out, s:sub(i + 1, close - 1))
        i = close + 1
      else
        table.insert(out, s:sub(i + 1))
        break
      end
    else
      local start = i
      while i <= n and not s:sub(i, i):match("%s") do i = i + 1 end
      table.insert(out, s:sub(start, i - 1))
    end
  end
  return out
end

--- Parse `KEY=VAL;KEY=VAL` into a table. Semicolon-separated so it fits
--- on a single-line prompt. Whitespace around keys and around `=` is
--- trimmed; values pass through verbatim (literal `$`, quotes, `=` after
--- the first one all survive).
---@param s string
---@return table<string, string>
function M.parse_inline_env(s)
  local out = {}
  for pair in s:gmatch("[^;]+") do
    pair = vim.trim(pair)
    if pair ~= "" then
      local k, v = pair:match("^([^=]+)=(.*)$")
      if k then out[vim.trim(k)] = v end
    end
  end
  return out
end

return M
