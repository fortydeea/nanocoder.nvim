-- Companion wire protocol message types (nanocoder `--vscode`, protocolVersion 1.0.0).
-- Builders for outbound messages and validation for inbound ones. The message
-- shapes are verified against nanocoder's source/vscode/protocol.ts.
local compat = require("nanocoder.compat")

local M = {}

---Protocol version this implementation speaks.
M.PROTOCOL_VERSION = "1.0.0"

-- Outbound (Neovim -> CLI) message types.
M.T_SEND_PROMPT = "send_prompt"
M.T_APPLY_CHANGE = "apply_change"
M.T_REJECT_CHANGE = "reject_change"
M.T_GET_STATUS = "get_status"
M.T_CONTEXT = "context"
M.T_DIAGNOSTICS_RESPONSE = "diagnostics_response"
M.T_ACTIVE_EDITOR = "active_editor"

-- Inbound (CLI -> Neovim) message types.
M.T_CONNECTION_ACK = "connection_ack"
M.T_STATUS = "status"
M.T_FILE_CHANGE = "file_change"
M.T_TOOL_CALL = "tool_call"
M.T_ASSISTANT_MESSAGE = "assistant_message"
M.T_DIAGNOSTICS_REQUEST = "diagnostics_request"
M.T_CLOSE_DIFF = "close_diff"
M.T_OPEN_FILE = "open_file"

-- Tool-call status values (from protocol.ts).
M.TOOL_STATUSES = {
  pending = true,
  executing = true,
  completed = true,
  rejected = true,
}

-- Diagnostic severities (from protocol.ts DiagnosticInfo).
M.SEVERITIES = {
  error = true,
  warning = true,
  info = true,
  hint = true,
}

---Build a send_prompt message.
---@param prompt string
---@param context table|nil { filePath?, selection?, fileName?, startLine?, endLine?, cursorPosition? }
---@return table
function M.send_prompt(prompt, context)
  local msg = { type = M.T_SEND_PROMPT, prompt = prompt }
  if context and next(context) ~= nil then
    msg.context = context
  end
  return msg
end

---Build an apply_change message.
---@param id string file_change id
---@return table
function M.apply_change(id)
  return { type = M.T_APPLY_CHANGE, id = id }
end

---Build a reject_change message.
---@param id string
---@return table
function M.reject_change(id)
  return { type = M.T_REJECT_CHANGE, id = id }
end

---Build a get_status request.
---@return table
function M.get_status()
  return { type = M.T_GET_STATUS }
end

---Build a context message (workspace state pushed to the CLI).
---@param ctx table { workspaceFolder?, openFiles?, activeFile?, diagnostics? }
---@return table
function M.context(ctx)
  local msg = { type = M.T_CONTEXT }
  for k, v in pairs(ctx or {}) do
    msg[k] = v
  end
  return msg
end

---Build a diagnostics_response message.
---@param diagnostics table[] list of DiagnosticInfo
---@return table
function M.diagnostics_response(diagnostics)
  return { type = M.T_DIAGNOSTICS_RESPONSE, diagnostics = diagnostics or {} }
end

---Build an active_editor message. Fields are cleared (omitted) when no text
---editor is active; `selection` is populated only for a non-empty selection.
---@param state table|nil { filePath?, fileName?, selection?, startLine?, endLine? }
---@return table
function M.active_editor(state)
  local msg = { type = M.T_ACTIVE_EDITOR }
  for k, v in pairs(state or {}) do
    if v ~= nil then
      msg[k] = v
    end
  end
  return msg
end

---Encode any message table to a JSON string.
---@param msg table
---@return string
function M.encode(msg)
  return compat.json_encode(msg)
end

---Decode and validate an inbound message.
---@param data string JSON text from the CLI
---@return table|nil msg, string|nil err
function M.decode(data)
  local ok, parsed = pcall(compat.json_decode, data)
  if not ok then
    return nil, "invalid JSON: " .. tostring(parsed)
  end
  -- A JSON array decodes to a sequential Lua table; a message must be an object.
  if type(parsed) ~= "table" or (#parsed > 0 and compat.is_list(parsed)) then
    return nil, "message is not a JSON object"
  end
  if type(parsed.type) ~= "string" then
    return nil, "message missing string `type`"
  end
  return parsed
end

---Validate an inbound message against its type's required fields.
---Returns nil when valid, or an error string.
---@param msg table decoded message
---@return string|nil err
function M.validate(msg)
  local t = msg.type
  if t == M.T_CONNECTION_ACK then
    if type(msg.protocolVersion) ~= "string" then
      return "connection_ack missing protocolVersion"
    end
  elseif t == M.T_STATUS then
    if type(msg.connected) ~= "boolean" then
      return "status missing boolean `connected`"
    end
  elseif t == M.T_FILE_CHANGE then
    for _, field in ipairs({ "id", "filePath", "originalContent", "newContent" }) do
      if type(msg[field]) ~= "string" then
        return "file_change missing string `" .. field .. "`"
      end
    end
  elseif t == M.T_TOOL_CALL then
    if type(msg.id) ~= "string" or type(msg.toolName) ~= "string" then
      return "tool_call missing id/toolName"
    end
    if msg.status ~= nil and not M.TOOL_STATUSES[msg.status] then
      return "tool_call has unknown status `" .. tostring(msg.status) .. "`"
    end
  elseif t == M.T_ASSISTANT_MESSAGE then
    if type(msg.content) ~= "string" then
      return "assistant_message missing string `content`"
    end
  elseif t == M.T_CLOSE_DIFF then
    if type(msg.id) ~= "string" then
      return "close_diff missing string `id`"
    end
  elseif t == M.T_OPEN_FILE then
    if type(msg.filePath) ~= "string" then
      return "open_file missing string `filePath`"
    end
  elseif t == M.T_DIAGNOSTICS_REQUEST then
    -- filePath is optional (all files when omitted).
  else
    return "unknown message type `" .. t .. "`"
  end
  return nil
end

---Convert vim.diagnostic records into protocol DiagnosticInfo entries.
---@param diagnostics table[] output of vim.diagnostic.get()
---@param bufnr integer buffer the diagnostics belong to
---@return table[]
function M.diagnostics_from_vim(diagnostics, bufnr)
  local out = {}
  local fname = vim.api.nvim_buf_get_name(bufnr)
  local severity_map = {
    [vim.diagnostic.severity.ERROR] = "error",
    [vim.diagnostic.severity.WARN] = "warning",
    [vim.diagnostic.severity.INFO] = "info",
    [vim.diagnostic.severity.HINT] = "hint",
  }
  for _, d in ipairs(diagnostics) do
    out[#out + 1] = {
      filePath = fname,
      -- protocol.ts line/character are 0-based, matching vim.diagnostic lnum/col.
      line = d.lnum or 0,
      character = d.col or 0,
      message = d.message or "",
      severity = severity_map[d.severity] or "info",
      source = d.source,
    }
  end
  return out
end

return M
