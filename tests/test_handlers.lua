-- Diagnostics collection and the CLI -> editor handlers (open_file etc).
local client = require("nanocoder.client")
local diagnostics = require("nanocoder.diagnostics")
local handlers = require("nanocoder.handlers")
local protocol = require("nanocoder.protocol")

test("diagnostics collect maps vim.diagnostic to protocol shape", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "/tmp/diag-collect.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1", "local y = 2" })
  vim.api.nvim_set_current_buf(buf)

  vim.diagnostic.set(vim.api.nvim_create_namespace("nanocoder_test_diag"), buf, {
    { lnum = 0, col = 6, message = "unused", severity = vim.diagnostic.severity.WARN, source = "test" },
    { lnum = 1, col = 6, message = "unused2", severity = vim.diagnostic.severity.ERROR, source = "test" },
  })

  local diags = diagnostics.collect("/tmp/diag-collect.lua")
  eq(2, #diags)
  eq("/tmp/diag-collect.lua", diags[1].filePath)
  eq("warning", diags[1].severity)
  eq("error", diags[2].severity)
  eq(0, diags[1].line)

  vim.diagnostic.reset(vim.api.nvim_create_namespace("nanocoder_test_diag"), buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("diagnostics respond sends a diagnostics_response", function()
  handlers.setup()
  diagnostics.setup()
  local sent = {}
  client.send = function(msg)
    sent[#sent + 1] = msg
    return true
  end

  eq(true, diagnostics.respond({ type = "diagnostics_request" }))
  eq(1, #sent)
  eq("diagnostics_response", sent[1].type)
  eq("table", type(sent[1].diagnostics))
end)

test("open_file handler opens the requested file", function()
  handlers.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("local answer = 42\nreturn answer\n")
  f:close()

  client._receive_raw(vim.json.encode({ type = "open_file", filePath = tmp }))
  eq(tmp, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p"))
  eq(2, vim.api.nvim_buf_line_count(0))
end)

test("tool_call and assistant_message handlers are safe to dispatch", function()
  handlers.setup()
  client._receive_raw(vim.json.encode({
    type = "tool_call",
    id = "t1",
    toolName = "write_file",
    toolArgs = {},
    status = "pending",
  }))
  client._receive_raw(vim.json.encode({
    type = "assistant_message",
    content = "done",
    isGenerating = false,
  }))
  ok(true)
end)

test("diagnostics_request routed through the dispatch pipeline", function()
  handlers.setup()
  diagnostics.setup()
  local sent = {}
  client.send = function(msg)
    sent[#sent + 1] = msg
    return true
  end
  client._receive_raw(vim.json.encode({ type = "diagnostics_request" }))
  eq(1, #sent)
  eq("diagnostics_response", sent[1].type)
end)
