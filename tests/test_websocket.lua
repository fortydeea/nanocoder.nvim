-- WebSocket handshake and frame codec tests (RFC 6455).
local ws = require("nanocoder.websocket")

test("handshake accept: RFC 6455 example", function()
  -- The canonical example from RFC 6455 §1.3 / §4.2.2.
  eq("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", ws.compute_accept("dGhlIHNhbXBsZSBub25jZQ=="))
end)

test("build_request: correct headers, no Origin, bearer token", function()
  local req = ws.build_request("dGhlIHNhbXBsZSBub25jZQ==", "127.0.0.1", 51820, "abc123")
  ok(req:match("^GET / HTTP/1%.1\r\n"), "request line")
  ok(req:find("Host: 127.0.0.1:51820", 1, true), "host header")
  ok(req:find("Upgrade: websocket", 1, true), "upgrade header")
  ok(req:find("Connection: Upgrade", 1, true), "connection header")
  ok(req:find("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", 1, true), "key header")
  ok(req:find("Sec-WebSocket-Version: 13", 1, true), "version header")
  ok(req:find("Authorization: Bearer abc123", 1, true), "auth header")
  ok(not req:find("Origin", 1, true), "must not set Origin")
  ok(req:sub(-4) == "\r\n\r\n", "ends with blank line")
end)

test("parse_response: accepts valid 101 response", function()
  local key = "dGhlIHNhbXBsZSBub25jZQ=="
  local raw = table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    "\r\n",
  }, "\r\n")
  local ok, err = ws.parse_response(raw, key)
  eq(true, ok)
  eq(nil, err)
end)

test("parse_response: rejects wrong accept value", function()
  local raw = table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: bogus=",
    "\r\n",
  }, "\r\n")
  local res, err = ws.parse_response(raw, "dGhlIHNhbXBsZSBub25jZQ==")
  eq(nil, res)
  ok(err:match("Accept mismatch"), err)
end)

test("parse_response: rejects non-101 status", function()
  local res, err = ws.parse_response("HTTP/1.1 401 Unauthorized\r\n\r\n", "key")
  eq(nil, res)
  ok(err:match("HTTP 401"), err)
end)

test("parse_response: rejects missing accept header", function()
  local res, err = ws.parse_response("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n", "key")
  eq(nil, res)
  ok(err:match("missing Sec%-WebSocket%-Accept"), err)
end)

test("frame roundtrip: small payload, masked", function()
  local payload = "hello world"
  local frame = ws.encode_frame(ws.OP_TEXT, payload)
  ok(frame:byte(2) >= 0x80, "client frames must be masked")
  local parser = ws.new_parser()
  local events = parser.feed(frame)
  eq(1, #events)
  eq("message", events[1].kind)
  eq(ws.OP_TEXT, events[1].opcode)
  eq(payload, events[1].payload)
end)

test("frame roundtrip: 126-length path (16-bit extended)", function()
  local payload = string.rep("x", 300)
  local frame = ws.encode_frame(ws.OP_TEXT, payload)
  local parser = ws.new_parser()
  local events = parser.feed(frame)
  eq(payload, events[1].payload)
end)

test("frame roundtrip: 127-length path (64-bit extended)", function()
  local payload = string.rep("y", 70000)
  local frame = ws.encode_frame(ws.OP_TEXT, payload)
  local parser = ws.new_parser()
  local events = parser.feed(frame)
  eq(1, #events)
  eq(payload, events[1].payload)
end)

test("frame roundtrip: unmasked server frames parse too", function()
  local payload = "from server"
  local frame = ws.encode_frame(ws.OP_TEXT, payload, { mask = false })
  local parser = ws.new_parser()
  local events = parser.feed(frame)
  eq(payload, events[1].payload)
end)

test("apply_mask is its own inverse", function()
  local key = string.char(0x37, 0xfa, 0x21, 0x3d)
  local payload = "mask me please"
  eq(payload, ws.apply_mask(ws.apply_mask(payload, key), key))
end)

test("parser handles byte-by-byte incremental feed", function()
  local payload = "an incremental message with some length to it"
  local frame = ws.encode_frame(ws.OP_TEXT, payload)
  local parser = ws.new_parser()
  local collected = {}
  for i = 1, #frame do
    local events = parser.feed(frame:sub(i, i))
    for _, e in ipairs(events) do
      collected[#collected + 1] = e
    end
  end
  eq(1, #collected)
  eq(payload, collected[1].payload)
end)

test("fragmented message reassembles (text + continuation)", function()
  local part1 = "Hello, "
  local part2 = "fragments!"
  local f1 = ws.encode_frame(ws.OP_TEXT, part1, { fin = false })
  local f2 = ws.encode_frame(ws.OP_CONTINUATION, part2, { fin = true })
  local parser = ws.new_parser()
  local events = parser.feed(f1 .. f2)
  eq(1, #events)
  eq("message", events[1].kind)
  eq(ws.OP_TEXT, events[1].opcode)
  eq(part1 .. part2, events[1].payload)
end)

test("control frame interleaved between fragments", function()
  local f1 = ws.encode_frame(ws.OP_TEXT, "aaa", { fin = false })
  local ping = ws.encode_frame(ws.OP_PING, "ping!")
  local f2 = ws.encode_frame(ws.OP_CONTINUATION, "bbb", { fin = true })
  local parser = ws.new_parser()
  local events = parser.feed(f1 .. ping .. f2)
  eq(2, #events)
  eq("ping", events[1].kind)
  eq("ping!", events[1].payload)
  eq("message", events[2].kind)
  eq("aaabbb", events[2].payload)
end)

test("close frame reports code and reason", function()
  local frame = ws.encode_frame(ws.OP_CLOSE, ws.close_payload(1001, "going away"))
  local parser = ws.new_parser()
  local events = parser.feed(frame)
  eq(1, #events)
  eq("close", events[1].kind)
  eq(1001, events[1].code)
  eq("going away", events[1].reason)
end)

test("close frame without payload", function()
  local frame = ws.encode_frame(ws.OP_CLOSE, "")
  local parser = ws.new_parser()
  local events = parser.feed(frame)
  eq("close", events[1].kind)
  eq(nil, events[1].code)
end)

test("errors on continuation without start", function()
  local frame = ws.encode_frame(ws.OP_CONTINUATION, "orphan")
  local parser = ws.new_parser()
  local events = parser.feed(frame)
  eq("error", events[1].kind)
  ok(events[1].err:match("continuation frame without start"), events[1].err)
end)

test("errors on data frame during fragmented message", function()
  local f1 = ws.encode_frame(ws.OP_TEXT, "aaa", { fin = false })
  local f2 = ws.encode_frame(ws.OP_TEXT, "bbb", { fin = true })
  local parser = ws.new_parser()
  local events = parser.feed(f1 .. f2)
  eq("error", events[1].kind)
end)

test("errors on oversized message", function()
  local parser = ws.new_parser()
  parser.max_message_size = 10
  local frame = ws.encode_frame(ws.OP_TEXT, string.rep("z", 64))
  local ok = pcall(function()
    parser.feed(frame)
  end)
  eq(false, ok, "oversized frame must raise")
end)

test("close_payload encodes code big-endian", function()
  local p = ws.close_payload(1000, "")
  eq(2, #p)
  eq(1000, p:byte(1) * 256 + p:byte(2))
end)

test("close_payload includes reason text", function()
  local p = ws.close_payload(1001, "bye")
  eq(5, #p)
  eq("bye", p:sub(3))
end)

test("generate_key is valid base64 of 16 bytes", function()
  local key = ws.generate_key()
  eq(24, #key)
  ok(key:match("^[%w%+/=]+$"), "key should be base64")
end)
