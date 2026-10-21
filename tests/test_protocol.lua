-- Protocol message builders and inbound validation.
local protocol = require("nanocoder.protocol")

test("send_prompt includes context only when present", function()
  local bare = protocol.send_prompt("hi")
  eq("send_prompt", bare.type)
  eq("hi", bare.prompt)
  eq(nil, bare.context)

  local with_ctx = protocol.send_prompt("hi", { filePath = "/a/b.lua", startLine = 3, endLine = 7 })
  eq("/a/b.lua", with_ctx.context.filePath)
  eq(3, with_ctx.context.startLine)
end)

test("change messages carry the id", function()
  eq({ type = "apply_change", id = "abc" }, protocol.apply_change("abc"))
  eq({ type = "reject_change", id = "abc" }, protocol.reject_change("abc"))
end)

test("active_editor drops nil fields", function()
  local msg = protocol.active_editor({ filePath = "/f.lua", fileName = "f.lua", selection = nil })
  eq("/f.lua", msg.filePath)
  eq("f.lua", msg.fileName)
  eq(nil, msg.selection)
end)

test("decode: rejects invalid JSON and non-objects", function()
  local msg, err = protocol.decode("{ nope")
  eq(nil, msg)
  ok(err:match("invalid JSON"), err)

  msg, err = protocol.decode("[1,2]")
  eq(nil, msg)
  ok(err:match("not a JSON object"), err)
end)

test("decode: rejects messages without a type", function()
  local msg, err = protocol.decode('{"content":"x"}')
  eq(nil, msg)
  ok(err:match("missing string"), err)
end)

test("validate: connection_ack requires protocolVersion", function()
  eq(nil, protocol.validate({ type = "connection_ack", protocolVersion = "1.0.0", cliVersion = "1.2.3" }))
  ok(protocol.validate({ type = "connection_ack" }):match("protocolVersion"))
end)

test("validate: status requires connected boolean", function()
  eq(nil, protocol.validate({ type = "status", connected = true, model = "m" }))
  ok(protocol.validate({ type = "status", model = "m" }):match("connected"))
end)

test("validate: file_change requires content fields", function()
  eq(nil, protocol.validate({
    type = "file_change",
    id = "1",
    filePath = "/f",
    originalContent = "a",
    newContent = "b",
    toolName = "write_file",
    toolArgs = {},
  }))
  ok(protocol.validate({ type = "file_change", id = "1" }):match("filePath"))
end)

test("validate: tool_call status enum", function()
  eq(nil, protocol.validate({ type = "tool_call", id = "1", toolName = "t", status = "pending" }))
  ok(protocol.validate({ type = "tool_call", id = "1", toolName = "t", status = "weird" }):match("unknown status"))
end)

test("validate: assistant_message, close_diff, open_file", function()
  eq(nil, protocol.validate({ type = "assistant_message", content = "x", isGenerating = false }))
  ok(protocol.validate({ type = "assistant_message" }):match("content"))
  eq(nil, protocol.validate({ type = "close_diff", id = "1" }))
  ok(protocol.validate({ type = "close_diff" }):match("id"))
  eq(nil, protocol.validate({ type = "open_file", filePath = "/f" }))
  ok(protocol.validate({ type = "open_file" }):match("filePath"))
end)

test("validate: diagnostics_request allows empty params", function()
  eq(nil, protocol.validate({ type = "diagnostics_request" }))
  eq(nil, protocol.validate({ type = "diagnostics_request", filePath = "/f" }))
end)

test("validate: unknown type is rejected", function()
  ok(protocol.validate({ type = "bogus" }):match("unknown message type"))
end)

test("encode: produces decodable JSON", function()
  local encoded = protocol.encode(protocol.get_status())
  local decoded, err = protocol.decode(encoded)
  eq(nil, err)
  eq("get_status", decoded.type)
end)

test("diagnostics_from_vim maps severities", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/tmp/diag-test.lua")
  local diags = {
    { lnum = 2, col = 4, message = "boom", severity = vim.diagnostic.severity.ERROR, source = "luacheck" },
    { lnum = 5, col = 0, message = "meh", severity = vim.diagnostic.severity.WARN },
    { lnum = 6, col = 1, message = "info", severity = vim.diagnostic.severity.INFO },
    { lnum = 7, col = 2, message = "hint", severity = vim.diagnostic.severity.HINT },
  }
  local out = protocol.diagnostics_from_vim(diags, buf)
  eq(4, #out)
  eq("error", out[1].severity)
  eq(2, out[1].line)
  eq(4, out[1].character)
  eq("luacheck", out[1].source)
  eq("warning", out[2].severity)
  eq("info", out[3].severity)
  eq("hint", out[4].severity)
  eq("/tmp/diag-test.lua", out[1].filePath)
  vim.api.nvim_buf_delete(buf, { force = true })
end)
