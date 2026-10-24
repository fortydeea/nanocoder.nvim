-- Answering the CLI's tool prompt with the diff's decision (approve.lua),
-- and the diff wiring that arms it. Clock is pinned through opts.now so the
-- settle window is tested without racing the real one.
local approve = require("nanocoder.approve")
local client = require("nanocoder.client")
local config = require("nanocoder.config")
local diff = require("nanocoder.diff")
local terminal = require("nanocoder.terminal")

---Build a scratch buffer standing in for the CLI terminal.
---@param lines string[]
---@return integer buf
local function term_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

---What the CLI's tool prompt looks like once rendered (TitledBox title plus
---the select input rows).
local PROMPT = {
  "Tool Approval",
  "Tool Call Preview",
  "Do you want to execute tool \"string_replace\"?",
  "  > ✓ Yes, execute this tool",
  "    ✗ No, cancel execution",
  "Press Escape to cancel",
}

-- Stub the terminal output channel and record keystrokes.
local sent = {}
local function capture()
  sent = {}
  terminal.send_text = function(text, submit)
    sent[#sent + 1] = { text = text, submit = submit }
    return true
  end
  client.send = function()
    return true
  end
end

---First captured keystroke, or nil.
local function first_key()
  return sent[1]
end

test("approve watch sends Enter once the prompt is visible and settled", function()
  capture()
  local buf = term_buf(PROMPT)
  local watch = approve.attach(buf, { quiet_ms = 300, now = 0 })
  ok(watch, "attach should build a watch")
  eq("approved", watch.step(1000))
  eq(1, #sent)
  eq("", first_key().text)
  eq(true, first_key().submit)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("approve watch waits while the prompt is not on screen", function()
  capture()
  local buf = term_buf({ "still working on it", "..." })
  local watch = approve.attach(buf, { quiet_ms = 300, now = 0 })
  eq("waiting", watch.step(1000))
  eq(0, #sent)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("approve watch never answers when the selection moved to No", function()
  capture()
  local buf = term_buf({
    "Tool Approval",
    "Do you want to execute tool \"string_replace\"?",
    "    ✓ Yes, execute this tool",
    "  > ✗ No, cancel execution",
  })
  local watch = approve.attach(buf, { quiet_ms = 300, now = 0 })
  eq("waiting", watch.step(1000))
  eq(0, #sent)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("approve watch waits out a fresh redraw before answering", function()
  capture()
  local buf = term_buf(PROMPT)
  local watch = approve.attach(buf, { quiet_ms = 300, now = 0 })
  -- The prompt is on screen but just rendered: not yet settled.
  eq("waiting", watch.step(200))
  eq(0, #sent)
  -- A redraw (the user moving the selection to No) resets the settle window
  -- and, while "No" is selected, is never answered at all.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Tool Approval",
    "Do you want to execute tool \"string_replace\"?",
    "    ✓ Yes, execute this tool",
    "  > ✗ No, cancel execution",
  })
  eq("waiting", watch.step(300))
  eq(0, #sent)
  -- Selection back on Yes: the redraw restarts the settle window.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, PROMPT)
  eq("waiting", watch.step(400))
  eq(0, #sent)
  -- Quiet long enough: answer.
  eq("approved", watch.step(800))
  eq(1, #sent)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("approve watch answers only the accepted tool's prompt", function()
  capture()
  local buf = term_buf({
    "Tool Approval",
    "Do you want to execute tool \"execute_bash\"?",
    "  > ✓ Yes, execute this tool",
    "    ✗ No, cancel execution",
  })
  local watch = approve.attach(buf, { tool_name = "string_replace", quiet_ms = 300, now = 0 })
  eq("waiting", watch.step(1000))
  eq(0, #sent)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Tool Approval",
    "Do you want to execute tool \"string_replace\"?",
    "  > ✓ Yes, execute this tool",
    "    ✗ No, cancel execution",
  })
  eq("waiting", watch.step(1100))
  eq("approved", watch.step(1500))
  eq(1, #sent)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("reject watch sends Escape, not Enter", function()
  capture()
  local buf = term_buf(PROMPT)
  local watch = approve.attach(buf, { action = "reject", quiet_ms = 300, now = 0 })
  eq("rejected", watch.step(1000))
  eq(1, #sent)
  eq("\27", first_key().text)
  eq(false, first_key().submit, "Escape must not be followed by a bare Enter")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("reject watch cancels even when the selection is on No", function()
  capture()
  local buf = term_buf({
    "Tool Approval",
    "Do you want to execute tool \"string_replace\"?",
    "    ✓ Yes, execute this tool",
    "  > ✗ No, cancel execution",
  })
  local watch = approve.attach(buf, { action = "reject", quiet_ms = 300, now = 0 })
  eq("rejected", watch.step(1000))
  eq(1, #sent)
  eq("\27", first_key().text)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("reject watch waits while the prompt is not on screen", function()
  capture()
  local buf = term_buf({ "still working on it" })
  local watch = approve.attach(buf, { action = "reject", quiet_ms = 300, now = 0 })
  eq("waiting", watch.step(1000))
  eq(0, #sent)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("watch stops at the timeout without sending anything", function()
  capture()
  local buf = term_buf({ "no prompt here" })
  local watch = approve.attach(buf, { quiet_ms = 300, timeout_ms = 5000, now = 0 })
  eq("stopped", watch.step(5100))
  eq(0, #sent)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("accept arms an approve watch, deny arms a reject watch", function()
  capture()
  config.setup({})
  diff.setup()
  local saved_get_bufnr = terminal.get_bufnr
  local buf = term_buf(PROMPT)
  terminal.get_bufnr = function()
    return buf
  end

  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("original\n")
  f:close()

  diff.open({
    type = "file_change",
    id = "a1",
    filePath = tmp,
    originalContent = "original\n",
    newContent = "updated\n",
    toolName = "string_replace",
    toolArgs = {},
  })
  diff.accept("a1")
  eq(true, approve.is_watching(), "accept should arm the approve watch")
  eq("approve", approve.watch_action())

  diff.open({
    type = "file_change",
    id = "a2",
    filePath = tmp,
    originalContent = "original\n",
    newContent = "updated\n",
    toolName = "string_replace",
    toolArgs = {},
  })
  diff.deny("a2")
  eq(true, approve.is_watching(), "a deny must arm a reject watch")
  eq("reject", approve.watch_action())

  approve.cancel()
  terminal.get_bufnr = saved_get_bufnr
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("closing a diff without a decision answers nothing", function()
  capture()
  config.setup({})
  diff.setup()
  local saved_get_bufnr = terminal.get_bufnr
  local buf = term_buf(PROMPT)
  terminal.get_bufnr = function()
    return buf
  end

  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("original\n")
  f:close()
  diff.open({
    type = "file_change",
    id = "a4",
    filePath = tmp,
    originalContent = "original\n",
    newContent = "updated\n",
    toolName = "string_replace",
    toolArgs = {},
  })
  diff.close("a4", "closed by test")
  eq(false, approve.is_watching(), "close without a decision must not answer the prompt")

  terminal.get_bufnr = saved_get_bufnr
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("answer_tool_prompt = false leaves the CLI prompt alone", function()
  capture()
  config.setup({ diff_opts = { answer_tool_prompt = false } })
  diff.setup()
  local saved_get_bufnr = terminal.get_bufnr
  local buf = term_buf(PROMPT)
  terminal.get_bufnr = function()
    return buf
  end

  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("original\n")
  f:close()
  diff.open({
    type = "file_change",
    id = "a3",
    filePath = tmp,
    originalContent = "original\n",
    newContent = "updated\n",
    toolName = "string_replace",
    toolArgs = {},
  })
  diff.accept("a3")
  eq(false, approve.is_watching())

  config.setup({})
  terminal.get_bufnr = saved_get_bufnr
  vim.api.nvim_buf_delete(buf, { force = true })
end)
