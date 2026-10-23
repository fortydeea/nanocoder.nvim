-- Context assembly, file adds, tree-path parsing, and prompt sending.
local config = require("nanocoder.config")
local context = require("nanocoder.context")
local protocol = require("nanocoder.protocol")
local client = require("nanocoder.client")

-- Capture what would be sent to the companion.
local sent = {}
local function capture()
  sent = {}
  client.send = function(msg)
    sent[#sent + 1] = msg
    return true
  end
end

test("prompt_context includes file, cursor, and selection", function()
  capture()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two", "line three" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-test.lua")
  vim.api.nvim_set_current_buf(buf)

  local ctx = context.prompt_context({ start_line = 0, end_line = 1 })
  eq("/tmp/ctx-test.lua", ctx.filePath)
  eq("ctx-test.lua", ctx.fileName)
  eq("line one\nline two", ctx.selection)
  eq(0, ctx.startLine)
  eq(1, ctx.endLine)
  eq("number", type(ctx.cursorPosition.line))

  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("prompt_context omits selection when no range given", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-nosel.lua")
  vim.api.nvim_set_current_buf(buf)
  local ctx = context.prompt_context({})
  eq(nil, ctx.selection)
  eq(nil, ctx.startLine)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("prompt_context is empty for unnamed buffers", function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  local ctx = context.prompt_context({})
  eq(nil, ctx.filePath)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("send_prompt builds a protocol message with context", function()
  capture()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-send.lua")
  vim.api.nvim_set_current_buf(buf)

  eq(true, context.send_prompt("fix this", { start_line = 0, end_line = 1 }))
  eq(1, #sent)
  eq("send_prompt", sent[1].type)
  eq("fix this", sent[1].prompt)
  eq("alpha\nbeta", sent[1].context.selection)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("add_file sends context and active_editor messages", function()
  capture()
  context.clear()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y", "z" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-add.lua")
  vim.api.nvim_set_current_buf(buf)

  eq(true, context.add_file("/tmp/ctx-add.lua", 0, 1))
  eq(2, #sent)
  eq("context", sent[1].type)
  eq("active_editor", sent[2].type)
  ok(vim.tbl_contains(sent[1].openFiles, "/tmp/ctx-add.lua"), "openFiles should list the added file")
  eq("/tmp/ctx-add.lua", sent[2].filePath)
  eq("x\ny", sent[2].selection)

  vim.api.nvim_buf_delete(buf, { force = true })
  context.clear()
end)

test("add_file accumulates multiple files in openFiles", function()
  capture()
  context.clear()
  context.add_file("/tmp/a.lua") -- sends context + active_editor
  context.add_file("/tmp/b.lua") -- sends context + active_editor
  eq(4, #sent)
  local last_context = sent[3]
  eq("context", last_context.type)
  eq(2, #last_context.openFiles)
  context.clear()
end)

test("path_from_tree_line: absolute paths", function()
  eq("/home/me/proj/src/main.lua", context.path_from_tree_line("  /home/me/proj/src/main.lua"))
end)

test("path_from_tree_line: netrw-style entries", function()
  eq(vim.fn.fnamemodify("./lua/nanocoder/init.lua", ":p"),
    context.path_from_tree_line("rw-r--r--  1 me  staff  1234  Jan  1 00:00 ./lua/nanocoder/init.lua"))
end)

test("path_from_tree_line: no path yields nil", function()
  eq(nil, context.path_from_tree_line("just some text"))
  eq(nil, context.path_from_tree_line(""))
end)

test("send_selection sends the marked range", function()
  capture()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "sel one", "sel two" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-vis.lua")
  vim.api.nvim_set_current_buf(buf)
  vim.fn.setpos("'<", { buf, 1, 1, 0 })
  vim.fn.setpos("'>", { buf, 2, 1, 0 })

  eq(true, context.send_selection())
  eq(1, #sent)
  ok(sent[1].prompt:find("sel one", 1, true), "prompt should contain the selection")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("send_selection uses an explicit range when given", function()
  capture()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aaa", "bbb", "ccc" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-exprange.lua")
  vim.api.nvim_set_current_buf(buf)

  eq(true, context.send_selection(1, 2))
  eq(1, #sent)
  ok(sent[1].prompt:find("bbb", 1, true), "prompt should contain line 2")
  ok(sent[1].prompt:find("ccc", 1, true), "prompt should contain line 3")
  ok(not sent[1].prompt:find("aaa", 1, true), "prompt should not contain line 1")
  eq(1, sent[1].context.startLine)
  eq(2, sent[1].context.endLine)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("send_selection reads the live visual selection (marks still unset)", function()
  capture()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3", "l4" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-live.lua")
  vim.api.nvim_set_current_buf(buf)

  -- Map a Lua callback in visual mode, like <cmd>NanocoderSend<cr> would run.
  -- Marks '</'> are NOT set yet at that point; the live range is the truth.
  local results = {}
  vim.keymap.set("v", "gS", function()
    results[#results + 1] = context.send_selection()
  end, { buffer = buf })
  local keys = vim.api.nvim_replace_termcodes("jVjgS", true, false, true)
  vim.api.nvim_feedkeys(keys, "x", false)

  eq({ true }, results)
  -- Ignore active_editor pushes from the context autocmds.
  local prompts = {}
  for _, msg in ipairs(sent) do
    if msg.type == "send_prompt" then
      prompts[#prompts + 1] = msg
    end
  end
  eq(1, #prompts)
  ok(prompts[1].prompt:find("l2", 1, true), "prompt should contain selection start")
  ok(prompts[1].prompt:find("l3", 1, true), "prompt should contain selection end")
  ok(not prompts[1].prompt:find("l1", 1, true), "prompt should not contain unselected line")
  eq(1, prompts[1].context.startLine)
  eq(2, prompts[1].context.endLine)
  vim.keymap.del("v", "gS", { buffer = buf })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("send_selection warns and returns false with no selection", function()
  capture()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "only" })
  vim.api.nvim_buf_set_name(buf, "/tmp/ctx-nosel2.lua")
  vim.api.nvim_set_current_buf(buf)
  vim.fn.setpos("'<", { 0, 0, 0, 0 })
  vim.fn.setpos("'>", { 0, 0, 0, 0 })

  eq(false, context.send_selection())
  eq(0, #sent)
  vim.api.nvim_buf_delete(buf, { force = true })
end)
