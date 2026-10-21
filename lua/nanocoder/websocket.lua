-- Pure-Lua WebSocket client protocol pieces (RFC 6455).
-- Handshake builder/verifier plus frame encode/decode with fragmentation
-- reassembly, ping/pong, and close handling. Transport I/O lives in
-- client.lua; everything here operates on byte strings so it is unit-testable.
local compat = require("nanocoder.compat")
local sha1 = require("nanocoder.sha1")

local M = {}

-- Opcodes (RFC 6455 §5.2).
M.OP_CONTINUATION = 0x0
M.OP_TEXT = 0x1
M.OP_BINARY = 0x2
M.OP_CLOSE = 0x8
M.OP_PING = 0x9
M.OP_PONG = 0xA

-- Cap on a single reassembled message. Large diffs arrive fragmented and must
-- survive, but a runaway stream must error instead of exhausting memory.
M.max_message_size = 16 * 1024 * 1024

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

---Generate `Sec-WebSocket-Key`: 16 random bytes, base64-encoded.
---@return string key
function M.generate_key()
  return compat.base64_encode(compat.uv.random(16))
end

---Compute `Sec-WebSocket-Accept` for a client key.
---@param key string the client's Sec-WebSocket-Key value
---@return string accept
function M.compute_accept(key)
  return compat.base64_encode(sha1.digest_raw(key .. WS_GUID))
end

---Build the HTTP/1.1 upgrade request. Never sets `Origin`: the nanocoder
---companion rejects any request carrying one.
---@param key string
---@param host string
---@param port number
---@param token string bearer token for the Authorization header
---@return string request
function M.build_request(key, host, port, token)
  return table.concat({
    "GET / HTTP/1.1",
    "Host: " .. host .. ":" .. tostring(port),
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "Authorization: Bearer " .. token,
    "\r\n",
  }, "\r\n")
end

---Parse and verify the server's upgrade response.
---@param raw string the response head including the terminating CRLFCRLF
---@param key string the Sec-WebSocket-Key that was sent
---@return boolean|nil ok, string|nil err, table|nil headers
function M.parse_response(raw, key)
  local head, rest = raw:match("^(.-)\r\n\r\n(.*)$")
  if not head then
    return nil, "incomplete handshake response"
  end
  local status = head:match("^(HTTP/%d%.%d%s+(%d%d%d)%s+[^\r\n]*)")
  local code = head:match("^HTTP/%d%.%d%s+(%d%d%d)")
  if not code then
    return nil, "malformed handshake status line"
  end
  if code ~= "101" then
    return nil, "handshake refused: HTTP " .. code
  end
  local headers = {}
  for line in (head:gsub("^[^\r\n]*\r\n", "") .. "\r\n"):gmatch("(.-)\r\n") do
    local name, value = line:match("^([^:]+):%s*(.*)$")
    if name then
      headers[name:lower()] = value
    end
  end
  local accept = headers["sec-websocket-accept"]
  if not accept then
    return nil, "handshake response missing Sec-WebSocket-Accept"
  end
  if accept ~= M.compute_accept(key) then
    return nil, "Sec-WebSocket-Accept mismatch"
  end
  if (headers["upgrade"] or ""):lower() ~= "websocket" then
    return nil, "handshake response missing Upgrade: websocket"
  end
  return true, nil, headers, rest
end

---Encode one frame. Client-to-server frames are always masked (RFC 6455 §5.3).
---@param opcode number one of M.OP_*
---@param payload string
---@param opts table|nil { fin = boolean (default true), mask = boolean (default true) }
---@return string frame
function M.encode_frame(opcode, payload, opts)
  opts = opts or {}
  local fin = opts.fin
  if fin == nil then
    fin = true
  end
  local mask = opts.mask
  if mask == nil then
    mask = true
  end

  local b1 = (fin and 0x80 or 0) + (opcode % 0x10)
  local len = #payload
  local out = { string.char(b1) }

  local mask_bit = mask and 0x80 or 0
  if len < 126 then
    out[#out + 1] = string.char(mask_bit + len)
  elseif len < 65536 then
    out[#out + 1] = string.char(mask_bit + 126)
    out[#out + 1] = string.char(math.floor(len / 256) % 256, len % 256)
  else
    out[#out + 1] = string.char(mask_bit + 127)
    -- 64-bit big-endian length. Messages are capped at max_message_size
    -- (well under 2^32), so the high 4 bytes are always zero.
    out[#out + 1] = string.char(0, 0, 0, 0,
      math.floor(len / 16777216) % 256,
      math.floor(len / 65536) % 256,
      math.floor(len / 256) % 256,
      len % 256)
  end

  if mask then
    local key = compat.uv.random(4)
    out[#out + 1] = key
    out[#out + 1] = M.apply_mask(payload, key)
  else
    out[#out + 1] = payload
  end

  return table.concat(out)
end

-- 256x256 byte XOR lookup table (no bit library available).
local XOR_BYTE = {}
do
  for a = 0, 255 do
    local row = {}
    for b = 0, 255 do
      local x, p, aa, bb = 0, 1, a, b
      for _ = 1, 8 do
        if (aa % 2) ~= (bb % 2) then
          x = x + p
        end
        aa = math.floor(aa / 2)
        bb = math.floor(bb / 2)
        p = p * 2
      end
      row[b] = x
    end
    XOR_BYTE[a] = row
  end
end

---XOR payload bytes with a 4-byte masking key (RFC 6455 §5.3).
---Applying the mask twice is the identity, so the same routine unmaskes.
---@param payload string
---@param key string 4 raw bytes
---@return string masked
function M.apply_mask(payload, key)
  local k1, k2, k3, k4 = key:byte(1, 4)
  local out = {}
  for i = 1, #payload do
    local b = payload:byte(i)
    local m = (i - 1) % 4
    local k = m == 0 and k1 or (m == 1 and k2 or (m == 2 and k3 or k4))
    out[i] = string.char(XOR_BYTE[b][k])
  end
  return table.concat(out)
end

---Incremental frame parser. Feed raw TCP bytes; receive complete messages.
---Handles fragmentation (opcode 0 continuation), control frames (which may
---be interleaved between fragments), and unmasking.
---@return table parser
function M.new_parser()
  local self = {
    buf = "",
    -- Fragmented message under construction.
    frag_opcode = nil,
    frag_parts = {},
    frag_len = 0,
    max_message_size = M.max_message_size,
  }

  ---Feed bytes; returns a list of events:
  ---  { kind = "message", opcode = number, payload = string }
  ---  { kind = "close", code = number|nil, reason = string }
  ---  { kind = "ping", payload = string }
  ---  { kind = "pong", payload = string }
  ---  { kind = "error", err = string }
  ---and the number of bytes consumed from the input.
  ---@param data string
  ---@return table[] events, number consumed
  function self.feed(data)
    self.buf = self.buf .. data
    local events = {}
    local consumed_total = 0

    while true do
      local frame, consumed, err = self._read_one()
      if err then
        events[#events + 1] = { kind = "error", err = err }
        return events, consumed_total
      end
      if not frame then
        break -- need more bytes
      end
      consumed_total = consumed_total + consumed
      self.buf = self.buf:sub(consumed + 1)

      local fin = frame.fin
      local op = frame.opcode

      if op == M.OP_CLOSE then
        local code, reason
        if #frame.payload >= 2 then
          local b1, b2 = frame.payload:byte(1, 2)
          code = b1 * 256 + b2
          reason = frame.payload:sub(3)
        end
        events[#events + 1] = { kind = "close", code = code, reason = reason }
        return events, consumed_total
      elseif op == M.OP_PING then
        events[#events + 1] = { kind = "ping", payload = frame.payload }
      elseif op == M.OP_PONG then
        events[#events + 1] = { kind = "pong", payload = frame.payload }
      elseif op == M.OP_TEXT or op == M.OP_BINARY then
        if self.frag_opcode then
          events[#events + 1] = { kind = "error", err = "new data frame during fragmented message" }
          return events, consumed_total
        end
        if fin then
          self._check_size(#frame.payload)
          events[#events + 1] = { kind = "message", opcode = op, payload = frame.payload }
        else
          self.frag_opcode = op
          self.frag_parts = { frame.payload }
          self.frag_len = #frame.payload
        end
      elseif op == M.OP_CONTINUATION then
        if not self.frag_opcode then
          events[#events + 1] = { kind = "error", err = "continuation frame without start" }
          return events, consumed_total
        end
        self.frag_parts[#self.frag_parts + 1] = frame.payload
        self.frag_len = self.frag_len + #frame.payload
        self._check_size(self.frag_len)
        if fin then
          local opcode = self.frag_opcode
          self.frag_opcode = nil
          local payload = table.concat(self.frag_parts)
          self.frag_parts = {}
          self.frag_len = 0
          events[#events + 1] = { kind = "message", opcode = opcode, payload = payload }
        end
      else
        events[#events + 1] = { kind = "error", err = "unknown opcode " .. tostring(op) }
        return events, consumed_total
      end
    end

    return events, consumed_total
  end

  function self._check_size(n)
    if n > self.max_message_size then
      error("message exceeds size cap")
    end
  end

  ---Try to parse one frame from self.buf.
  ---@return table|nil frame, number consumed, string|nil err
  function self._read_one()
    local buf = self.buf
    local n = #buf
    if n < 2 then
      return nil, 0
    end

    local b1, b2 = buf:byte(1, 2)
    local fin = (b1 >= 0x80)
    local opcode = b1 % 0x10
    local masked = (b2 >= 0x80)
    local len = b2 % 0x80

    local off = 2
    if len == 126 then
      if n < 4 then
        return nil, 0
      end
      local l1, l2 = buf:byte(3, 4)
      len = l1 * 256 + l2
      off = 4
    elseif len == 127 then
      if n < 10 then
        return nil, 0
      end
      len = 0
      for i = 3, 10 do
        len = len * 256 + buf:byte(i)
        if len > 2 ^ 53 then
          return nil, 0, "frame length exceeds safe integer range"
        end
      end
      off = 10
    end

    local mask_key
    if masked then
      if n < off + 4 then
        return nil, 0
      end
      mask_key = buf:sub(off + 1, off + 4)
      off = off + 4
    end

    if n < off + len then
      return nil, 0 -- payload not complete yet
    end

    local payload = buf:sub(off + 1, off + len)
    if mask_key then
      payload = M.apply_mask(payload, mask_key)
    end

    return { fin = fin, opcode = opcode, payload = payload }, off + len
  end

  return self
end

---Build a close frame payload (status code + reason).
---@param code number|nil default 1000 (normal closure)
---@param reason string|nil
---@return string payload
function M.close_payload(code, reason)
  code = code or 1000
  reason = reason or ""
  return string.char(math.floor(code / 256) % 256, code % 256) .. reason
end

return M
