-- Answering the CLI's own tool prompt with the diff review's decision.
--
-- The CLI renders a "Tool Approval" prompt for every tool call, including the
-- one behind a proposed diff (the diff preview is that prompt's formatter).
-- Nothing is written to disk until that prompt is approved, so the diff
-- decision has to reach it: accepting approves the tool, rejecting cancels it.
-- Without this the user reviews the diff in Neovim and is then asked the same
-- question again in the terminal — and a rejected diff would still be applied.
--
-- There is no protocol message for approving a tool call (PROTOCOL.md has
-- none, and `apply_change` only fires an unused callback in the CLI), so the
-- only input channel to the CLI is the terminal job. Mechanism:
--
--   * The prompt is an ink SelectInput: Enter picks the highlighted row,
--     Escape cancels the call outright (components/tool-confirmation.js).
--   * The conversation loop suspends until it is answered, so the terminal
--     emits no output while the decision is pending.
--   * The prompt always renders within one screenful (WINDOW lines), so its
--     title is in the terminal's last lines once the output settles.
--
-- A watcher polls the terminal tail. When the right prompt is on screen and
-- the buffer has been quiet for quiet_ms (nobody is navigating it — moving the
-- selection redraws and resets the quiet window), it sends the keystroke.
-- Anything else - no prompt, prompt for another tool, wrong decision - sends
-- nothing.
--
-- Escape is sent only when the prompt is confirmed on screen: outside a
-- decision prompt Escape cancels the whole generation, so a stray keystroke
-- here would abort unrelated work.
local log = require("nanocoder.log")
local terminal = require("nanocoder.terminal")

local M = {}

---Compact-mode window height of the CLI TUI. The prompt, once rendered, sits
---at the bottom of the screen, so only the tail matters.
local WINDOW = 50

---Poll interval and settle window (ms).
local POLL_MS = 100
local QUIET_MS = 300

---How long to keep watching after a decision before giving up (ms).
local TIMEOUT_MS = 10000

---Title of the CLI's tool approval prompt (components/tool-confirmation.js).
local PROMPT_TITLE = "Tool Approval"

---Part of the "Yes" option label, short enough to survive label truncation.
local YES_OPTION = "Yes, execute"

---Keystrokes that answer the prompt, as (text, submit) for terminal.send_text.
---Enter picks the highlighted row, so it is only right for the approve side.
---Escape cancels the call and sends no trailing Enter, which would otherwise
---submit an empty chat message once the prompt is gone.
local ANSWER = {
  approve = { text = "", submit = true },
  reject = { text = "\27", submit = false },
}

---Pending watch state, one at a time. A newer schedule replaces the old one.
---@type table|nil
local pending

---Stop watching and clear the timer.
local function stop_watch()
  if not pending then
    return
  end
  if pending.timer then
    pcall(function()
      pending.timer:stop()
      pending.timer:close()
    end)
  end
  pending = nil
end

---Text tail of the terminal buffer the watch is attached to.
---@param buf integer
---@return string|nil tail nil when the buffer is gone
local function tail_text(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local first = math.max(1, line_count - WINDOW + 1)
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, -1, false)
  -- Strip trailing spaces Ink pads rows with, so labels match after wrapping.
  return (table.concat(lines, "\n"):gsub(" +\n", "\n"))
end

---True when the prompt is on screen for `tool_name` and `action` can be sent.
---@param tail string
---@param tool_name string|nil only answer the prompt for this tool when given
---@param action string "approve" | "reject"
---@return boolean
local function prompt_ready(tail, tool_name, action)
  if tail:find(PROMPT_TITLE, 1, true) == nil then
    return false
  end
  if tool_name and tail:find('tool "' .. tool_name .. '"', 1, true) == nil then
    -- A different tool's prompt: its decision is not ours to make.
    return false
  end
  for line in tail:gmatch("[^\n]+") do
    local at = line:find(YES_OPTION, 1, true)
    if at then
      if action ~= "approve" then
        -- Escape cancels whatever row is highlighted.
        return true
      end
      -- Enter picks the highlighted row, so "Yes" has to be the one.
      return line:sub(1, at - 1):find(">", 1, true) ~= nil
    end
  end
  return false
end

---Send the keystroke that answers the prompt in `action`'s direction.
---@param action string "approve" | "reject"
local function answer(action)
  local key = ANSWER[action]
  if terminal.send_text(key.text, key.submit) then
    log.info("auto-" .. action .. "d the tool call behind the diff")
  else
    log.warn("could not reach the terminal to " .. action .. " the tool call")
  end
end

---Build watch state for a terminal buffer.
---@param buf integer
---@param opts table|nil
---@return table|nil state nil when the buffer is gone
local function new_state(buf, opts)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  opts = opts or {}
  -- `opts.now` lets tests pin the clock instead of racing the real one.
  local now = opts.now or (vim.uv or vim.loop).now()
  return {
    buf = buf,
    tool_name = opts.tool_name,
    action = opts.action or "approve",
    quiet_ms = opts.quiet_ms or QUIET_MS,
    deadline = now + (opts.timeout_ms or TIMEOUT_MS),
    last_tail = tail_text(buf) or "",
    last_change = now,
  }
end

---One watch step.
---@param p table watch state
---@param now integer monotonic ms
---@return string status "approved" | "rejected" | "waiting" | "stopped"
local function step(p, now)
  local tail = tail_text(p.buf)
  if tail == nil then
    return "stopped"
  end
  if tail ~= p.last_tail then
    p.last_tail = tail
    p.last_change = now
  end
  if prompt_ready(tail, p.tool_name, p.action) and now - p.last_change >= p.quiet_ms then
    answer(p.action)
    return p.action == "approve" and "approved" or "rejected"
  end
  return now < p.deadline and "waiting" or "stopped"
end

---Attach a watcher to a terminal buffer without starting a timer.
---Exposed for tests; `schedule` is the production entry point.
---@param buf integer|nil
---@param opts table|nil { action?, tool_name?, quiet_ms?, timeout_ms?, now? }
---@return table|nil watch drives one step via `watch.step(now)`
function M.attach(buf, opts)
  local state = new_state(buf, opts)
  if not state then
    return nil
  end
  return {
    step = function(now)
      return step(state, now or (vim.uv or vim.loop).now())
    end,
  }
end

---Wait for the CLI's tool prompt and answer it with the diff's decision.
---@param buf integer|nil terminal buffer
---@param opts table|nil { action?, tool_name?, quiet_ms?, poll_ms?, timeout_ms? }
---@return boolean scheduled
function M.schedule(buf, opts)
  stop_watch()
  local state = new_state(buf, opts)
  if not state then
    log.debug("tool prompt watch: no terminal buffer to watch")
    return false
  end
  local uv = vim.uv or vim.loop
  local poll_ms = (opts and opts.poll_ms) or POLL_MS
  state.timer = uv.new_timer()
  state.timer:start(poll_ms, poll_ms, vim.schedule_wrap(function()
    if pending == state and step(state, uv.now()) ~= "waiting" then
      stop_watch()
    end
  end))
  pending = state
  log.debug("watching terminal for the tool prompt (" .. state.action .. ")")
  return true
end

---Cancel any pending watch.
function M.cancel()
  stop_watch()
end

---True while a watch is running (used by tests).
---@return boolean
function M.is_watching()
  return pending ~= nil
end

---The action the running watch will send, or nil (used by tests).
---@return string|nil action "approve" | "reject"
function M.watch_action()
  return pending and pending.action or nil
end

return M
