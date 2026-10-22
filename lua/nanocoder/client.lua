-- Companion WebSocket client connection lifecycle.
-- Reads discovery info, dials 127.0.0.1, completes the RFC 6455 handshake,
-- then dispatches protocol messages to registered handlers.
local compat = require("nanocoder.compat")
local config = require("nanocoder.config")
local discovery = require("nanocoder.discovery")
local log = require("nanocoder.log")
local protocol = require("nanocoder.protocol")
local ws = require("nanocoder.websocket")

local uv = compat.uv

local M = {}

-- Connection state.
local state = {
  sock = nil,
  parser = nil,
  connected = false,
  handshaking = false,
  info = nil, -- {port, token, ...}
  reconnect_attempts = 0,
  reconnect_timer = nil,
  stopping = false,
  -- Set after reset(): while true, connect churn is expected (the freshly
  -- launched CLI may not be listening yet) and stays out of vim.notify.
  grace = false,
}

-- Message handlers, keyed by protocol message type.
local handlers = {}

-- Defined below; declared here so M._receive_raw captures the local.
local dispatch_message

---Register a handler for an inbound message type.
---@param msg_type string one of protocol.T_*
---@param fn fun(msg: table)
function M.on(msg_type, fn)
  handlers[msg_type] = fn
end

---Register a fallback handler for messages with no dedicated handler.
---@param fn fun(msg: table, err: string|nil)
function M.on_unhandled(fn)
  M._unhandled = fn
end

---Register a callback for connection state changes.
---@param fn fun(connected: boolean, reason: string|nil)
function M.on_connection(fn)
  M._on_connection = fn
end

---@return boolean
function M.is_connected()
  return state.connected
end

---Best-effort description of the last-known connection target.
---@return table|nil
function M.get_info()
  return state.info
end

---Send a protocol message (as JSON text frame) to the connected CLI.
---@param msg table built by protocol.*
---@return boolean sent
function M.send(msg)
  if not state.connected or not state.sock then
    log.debug("send skipped (not connected): " .. tostring(msg and msg.type))
    return false
  end
  local payload = protocol.encode(msg)
  local frame = ws.encode_frame(ws.OP_TEXT, payload)
  local ok, err = pcall(function()
    state.sock:write(frame)
  end)
  if not ok then
    log.warn("failed to send " .. tostring(msg.type) .. ": " .. tostring(err))
    return false
  end
  return true
end

---Send a raw protocol builder result by type. Convenience for callers.
---@param builder fun(): table
---@return boolean
function M.send_built(builder)
  local ok, msg = pcall(builder)
  if not ok then
    log.error("message build failed: " .. tostring(msg))
    return false
  end
  return M.send(msg)
end

---Feed a raw WebSocket text payload into the dispatch pipeline.
---Test seam: exercises decode/validate/handler lookup without a socket.
---@param payload string JSON text
function M._receive_raw(payload)
  dispatch_message(payload)
end

local function set_connected(value, reason)
  if state.connected == value then
    return
  end
  state.connected = value
  if M._on_connection then
    pcall(M._on_connection, value, reason)
  end
end

local function cleanup_socket()
  if state.sock then
    pcall(function()
      state.sock:read_stop()
      state.sock:close()
    end)
    state.sock = nil
  end
  state.parser = nil
  state.handshaking = false
  set_connected(false)
end

local function handle_ws_event(event)
  if event.kind == "message" then
    dispatch_message(event.payload)
  elseif event.kind == "ping" then
    if state.sock then
      pcall(function()
        state.sock:write(ws.encode_frame(ws.OP_PONG, event.payload))
      end)
    end
  elseif event.kind == "close" then
    log.debug("server closed connection: code=" .. tostring(event.code))
    cleanup_socket()
  elseif event.kind == "error" then
    log.warn("websocket protocol error: " .. tostring(event.err))
    cleanup_socket()
  end
end

dispatch_message = function(payload)
  local msg, err = protocol.decode(payload)
  if not msg then
    log.warn("discarding undecodable message: " .. tostring(err))
    return
  end
  local verr = protocol.validate(msg)
  if verr then
    log.warn("discarding invalid message (" .. msg.type .. "): " .. verr)
    return
  end

  local handler = handlers[msg.type]
  if handler then
    local ok, herr = pcall(handler, msg)
    if not ok then
      log.error("handler for " .. msg.type .. " failed: " .. tostring(herr))
    end
    return
  end
  if M._unhandled then
    pcall(M._unhandled, msg)
  end
end

---Schedule a reconnect at a fixed interval.
local function schedule_reconnect()
  if state.stopping then
    return
  end
  local cfg = config.get()
  if not (cfg and cfg.auto_connect) then
    return
  end
  state.reconnect_attempts = state.reconnect_attempts + 1
  if state.reconnect_attempts > 10 then
    log.warn("giving up on reconnecting after " .. state.reconnect_attempts .. " attempts")
    return
  end
  local delay = 5000
  log.debug(string.format("reconnecting in %dms (attempt %d)", delay, state.reconnect_attempts))
  if state.reconnect_timer then
    state.reconnect_timer:stop()
  end
  local timer = uv.new_timer()
  state.reconnect_timer = timer
  timer:start(delay, 0, function()
    timer:stop()
    timer:close()
    state.reconnect_timer = nil
    vim.schedule(function()
      M.connect()
    end)
  end)
end

---Dial the companion and complete the WebSocket handshake.
---@param info table|nil {port, token}; resolved from config/discovery when nil
---@return boolean started
function M.connect(info)
  state.stopping = false
  info = info or discovery.resolve(config.get())
  if not info then
    log.debug("no companion discovery info available yet")
    schedule_reconnect()
    return false
  end
  state.info = info

  if state.sock then
    cleanup_socket()
  end

  local sock = uv.new_tcp()
  state.sock = sock
  state.handshaking = true
  state.parser = ws.new_parser()

  -- Callbacks may fire after a later connect() replaced state.sock (e.g. a
  -- relaunch); only the socket they were created for may touch shared state.
  local function current()
    return state.sock == sock
  end

  local key = ws.generate_key()
  local host = "127.0.0.1"

  sock:connect(host, info.port, function(connect_err)
    if not current() then
      return
    end
    if connect_err then
      local msg = "connect failed on " .. host .. ":" .. tostring(info.port) .. ": " .. connect_err
      if state.grace then
        log.debug(msg)
      else
        log.warn(msg)
      end
      vim.schedule(function()
        if not current() then
          return
        end
        cleanup_socket()
        schedule_reconnect()
      end)
      return
    end

    local request = ws.build_request(key, host, info.port, info.token)
    sock:write(request)

    local buffer = ""
    sock:read_start(function(read_err, chunk)
      if not current() then
        return
      end
      if read_err then
        local msg = "socket read error: " .. tostring(read_err)
        if state.grace then
          log.debug(msg)
        else
          log.warn(msg)
        end
        vim.schedule(function()
          if not current() then
            return
          end
          cleanup_socket()
          schedule_reconnect()
        end)
        return
      end
      if not chunk then -- EOF
        log.debug("companion closed the socket")
        vim.schedule(function()
          if not current() then
            return
          end
          cleanup_socket()
          schedule_reconnect()
        end)
        return
      end

      if state.handshaking then
        buffer = buffer .. chunk
        local head, rest = buffer:match("^(.-)\r\n\r\n(.*)$")
        if not head then
          if #buffer > 32768 then
            log.warn("handshake response too large")
            vim.schedule(cleanup_socket)
          end
          return
        end
        local ok, herr, _, leftover = ws.parse_response(buffer, key)
        if not ok then
          log.warn("handshake failed: " .. tostring(herr))
          vim.schedule(function()
            cleanup_socket()
          end)
          return
        end
        state.handshaking = false
        state.reconnect_attempts = 0
        state.grace = false
        set_connected(true)
        log.info("connected to nanocoder companion (port " .. tostring(info.port) .. ")")

        if leftover and #leftover > 0 then
          vim.schedule(function()
            if not current() then
              return
            end
            local events = state.parser.feed(leftover)
            for _, e in ipairs(events) do
              handle_ws_event(e)
            end
          end)
        end
        return
      end

      local events = state.parser.feed(chunk)
      vim.schedule(function()
        if not current() then
          return
        end
        for _, e in ipairs(events) do
          handle_ws_event(e)
        end
      end)
    end)
  end)

  return true
end

---Disconnect and stop reconnecting.
function M.disconnect()
  state.stopping = true
  if state.reconnect_timer then
    state.reconnect_timer:stop()
    pcall(function()
      state.reconnect_timer:close()
    end)
    state.reconnect_timer = nil
  end
  cleanup_socket()
  log.info("disconnected from nanocoder companion")
end

---Reset the reconnect budget after a manual (re)start. Enters the grace window:
---connect churn right after a relaunch is expected and stays out of vim.notify
---until a handshake succeeds (see the connect callback).
function M.reset()
  state.reconnect_attempts = 0
  state.stopping = false
  state.grace = true
end

return M
