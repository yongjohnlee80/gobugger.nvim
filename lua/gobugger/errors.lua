-- Error capture for dap sessions that die before they initialize.
--
-- When `<leader>dm` / `<leader>dt` fail to start (build error, missing
-- delve, adapter misconfig, etc.), the user used to have to dig through
-- `~/.cache/nvim/dap.log` to see why. This module listens for stderr /
-- console output between `launch|attach` and `event_terminated|exited`,
-- and when the session exits without ever emitting `event_initialized`,
-- surfaces the captured output as a single ERROR notification.
--
-- The full buffered text stays available via `M.last()` and can be
-- popped into a scratch buffer with `M.open_last()` for scrolling /
-- copy-paste. The notify preview is truncated so the popup stays
-- readable; the scratch buffer has everything.
--
-- Idempotent: listener keys are namespaced so repeat setup() calls just
-- replace the existing registrations.

local M = {}

-- Per-session accumulators. Reset on every launch/attach.
local err_lines = {}
local initialized = false
-- Last *failed* session's captured output. Cleared on next failed start.
local last_failure = nil

local function append(chunk)
  if type(chunk) ~= "string" or chunk == "" then return end
  -- DAP output events carry arbitrary chunk boundaries; just accumulate
  -- as-is and split on newlines when we render.
  table.insert(err_lines, chunk)
end

local function flush_if_failed(reason_prefix)
  if initialized then return end
  if #err_lines == 0 then return end

  last_failure = {
    text = table.concat(err_lines),
    at = os.date("%H:%M:%S"),
  }

  local full = last_failure.text
  local preview = full
  local trailer = ""
  if #full > 600 then
    preview = full:sub(1, 600)
    trailer = "\n\n...(truncated; :Gobugger last-error for full output)"
  end

  vim.schedule(function()
    vim.notify(
      ("[gobugger] %s\n\n%s%s"):format(reason_prefix, preview, trailer),
      vim.log.levels.ERROR
    )
  end)
end

function M.setup()
  local ok, dap = pcall(require, "dap")
  if not ok then return end

  local key = "gobugger-errors"

  -- Reset on each session start.
  dap.listeners.before.launch[key] = function()
    err_lines = {}
    initialized = false
  end
  dap.listeners.before.attach[key] = function()
    err_lines = {}
    initialized = false
  end

  -- Mark as successfully initialized so terminate/exit don't count as failure.
  dap.listeners.after.event_initialized[key] = function()
    initialized = true
  end

  -- Capture stderr + console stream. (stdout is the DAP protocol channel
  -- and gets parsed by nvim-dap, not emitted as output events. Build
  -- errors from delve show up on stderr.)
  dap.listeners.after.event_output[key] = function(_, body)
    if not body or initialized then return end
    local cat = body.category or ""
    if cat == "stderr" or cat == "console" or cat == "important" then
      append(body.output)
    end
  end

  -- If the adapter exits or the session terminates before it ever
  -- signalled `initialized`, treat the buffered output as the failure
  -- reason and notify.
  dap.listeners.after.event_terminated[key] = function()
    flush_if_failed("debug session failed to start")
  end
  dap.listeners.after.event_exited[key] = function(_, body)
    local code = body and body.exitCode or "?"
    flush_if_failed(("adapter exited with code %s before initializing"):format(tostring(code)))
  end
end

--- Full text of the last failed-start capture, or nil if none yet.
---@return string?
function M.last()
  return last_failure and last_failure.text or nil
end

--- Open the last captured failure text in a scratch buffer for
--- scrolling / copy-paste. No-op (with a notify) when nothing captured.
function M.open_last()
  local txt = M.last()
  if not txt or txt == "" then
    vim.notify("[gobugger] no captured error output yet", vim.log.levels.INFO)
    return
  end

  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(txt, "\n", { plain = true }))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "log"
  pcall(vim.api.nvim_buf_set_name, buf, ("gobugger://last-error-%s"):format(last_failure.at))
end

return M
