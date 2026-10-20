-- Handlers for inbound CLI -> Neovim messages beyond the transport core:
-- open_file (open in the editor), tool_call (log/notify), assistant_message
-- (log). The diff lifecycle (file_change / close_diff) lives in diff.lua.
local client = require("nanocoder.client")
local log = require("nanocoder.log")
local protocol = require("nanocoder.protocol")

local M = {}

---Open a file the CLI requested. Currently opens in the current window;
---Stage 4 may add range selection when startText/endText appear.
---@param msg table { filePath }
local function handle_open_file(msg)
  local path = msg.filePath
  if not path or path == "" then
    log.warn("open_file: empty filePath")
    return
  end
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    log.warn("open_file failed: " .. tostring(err))
    return
  end
  log.info("opened file requested by CLI: " .. path)
end

---Tool calls are announced for visibility. The TUI remains authoritative for
---approvals, so we only log/notify rather than gate anything.
---@param msg table { id, toolName, status, result? }
local function handle_tool_call(msg)
  local status = msg.status or "pending"
  if status == "pending" then
    log.debug("tool_call pending: " .. tostring(msg.toolName))
  elseif status == "completed" then
    log.debug("tool_call completed: " .. tostring(msg.toolName))
  elseif status == "rejected" then
    log.debug("tool_call rejected: " .. tostring(msg.toolName))
  end
end

---Assistant text is surfaced as a notification only when a turn finishes;
---streaming content stays in the terminal TUI.
---@param msg table { content, isGenerating }
local function handle_assistant_message(msg)
  if msg.isGenerating then
    return
  end
  log.debug("assistant_message (" .. #msg.content .. " chars)")
end

---Register the CLI -> Neovim handlers.
function M.setup()
  client.on(protocol.T_OPEN_FILE, handle_open_file)
  client.on(protocol.T_TOOL_CALL, handle_tool_call)
  client.on(protocol.T_ASSISTANT_MESSAGE, handle_assistant_message)
  log.debug("CLI -> editor handlers registered")
end

return M
