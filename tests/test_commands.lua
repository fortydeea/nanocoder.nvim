-- User command behavior: :NanocoderSelectModel relaunch rules, :NanocoderSend
-- routing (visual range vs. prompted message).
-- Empty or cancelled prompts must never restart the terminal or the socket.
local config = require("nanocoder.config")
local nanocoder = require("nanocoder")
local terminal = require("nanocoder.terminal")
local client = require("nanocoder.client")

-- Register :Nanocoder* at load time so the tests below can :cmd them.
-- auto_connect off: no deferred connect churn in a headless test run.
nanocoder.setup({ auto_connect = false })

local CANCEL = {} -- sentinel: vim.ui.input callback receives nil

---Run fn with vim.ui.input answering from the given queue.
---@param answers any[] values to feed (CANCEL yields nil)
---@param fn function
---@return string[] prompts that were asked
local function with_input(answers, fn)
  local original = vim.ui.input
  local asked = {}
  local queue = { unpack(answers) }
  vim.ui.input = function(opts, cb)
    asked[#asked + 1] = opts and opts.prompt or ""
    local answer = table.remove(queue, 1)
    if answer == CANCEL then
      answer = nil
    end
    cb(answer)
  end
  local ok, err = pcall(fn)
  vim.ui.input = original
  if not ok then
    error(err, 0)
  end
  return asked
end

---Run fn with nanocoder.start/stop replaced by recorders.
---@param record string[] receives "start"/"stop" in call order
---@param fn function
local function with_lifecycle(record, fn)
  local orig_start, orig_stop = nanocoder.start, nanocoder.stop
  nanocoder.start = function()
    record[#record + 1] = "start"
  end
  nanocoder.stop = function()
    record[#record + 1] = "stop"
  end
  local ok, err = pcall(fn)
  nanocoder.start, nanocoder.stop = orig_start, orig_stop
  if not ok then
    error(err, 0)
  end
end

test("SelectModel: cancelling the first prompt changes nothing", function()
  config.setup({})
  terminal.set_cli_argv({ "nanocoder", "--vscode" })
  local record = {}
  with_input({ CANCEL }, function()
    with_lifecycle(record, function()
      vim.cmd("NanocoderSelectModel")
    end)
  end)
  eq({}, record)
  eq({ "nanocoder", "--vscode" }, terminal.get_cli_argv())
end)

test("SelectModel: cancelling the second prompt changes nothing", function()
  local record = {}
  with_input({ "openai", CANCEL }, function()
    with_lifecycle(record, function()
      vim.cmd("NanocoderSelectModel")
    end)
  end)
  eq({}, record)
  eq({ "nanocoder", "--vscode" }, terminal.get_cli_argv())
end)

test("SelectModel: empty selection on the default argv does not relaunch", function()
  local orig_running = terminal.is_running
  terminal.is_running = function()
    return true -- pretend a CLI is already running
  end
  local record = {}
  with_input({ "", "" }, function()
    with_lifecycle(record, function()
      vim.cmd("NanocoderSelectModel")
    end)
  end)
  terminal.is_running = orig_running
  eq({}, record)
  eq({ "nanocoder", "--vscode" }, terminal.get_cli_argv())
end)

test("SelectModel: empty selection on a custom argv resets to the default", function()
  terminal.set_cli_argv({ "nanocoder", "--vscode", "--provider", "openai", "--model", "gpt-5" })
  local record = {}
  with_input({ "", "" }, function()
    with_lifecycle(record, function()
      vim.cmd("NanocoderSelectModel")
    end)
  end)
  eq({ "stop", "start" }, record)
  eq({ "nanocoder", "--vscode" }, terminal.get_cli_argv())
end)

test("SelectModel: a real change relaunches once with the selected argv", function()
  local record = {}
  with_input({ "openai", "gpt-5" }, function()
    with_lifecycle(record, function()
      vim.cmd("NanocoderSelectModel")
    end)
  end)
  eq({ "stop", "start" }, record)
  eq({ "nanocoder", "--vscode", "--provider", "openai", "--model", "gpt-5" }, terminal.get_cli_argv())
  terminal.set_cli_argv({ "nanocoder", "--vscode" })
end)

-- :NanocoderSend routing -------------------------------------------------

---Capture send_prompt messages sent to the companion.
---(active_editor pushes from the context autocmds are ignored.)
---@return table[] messages, function restore
local function capture_send()
  local sent = {}
  local orig = client.send
  client.send = function(msg)
    if msg.type == "send_prompt" then
      sent[#sent + 1] = msg
    end
    return true
  end
  return sent, function()
    client.send = orig
  end
end

test("NanocoderSend: <cmd> mapping from visual mode sends the live selection", function()
  local sent, restore = capture_send()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
  vim.api.nvim_buf_set_name(buf, "/tmp/cmd-vis.lua")
  vim.api.nvim_set_current_buf(buf)

  -- The README's recommended mapping shape: <cmd> passes no range and runs
  -- while still in visual mode, with '</'> marks not yet set.
  vim.keymap.set("v", "<leader>as", "<cmd>NanocoderSend<cr>", { buffer = buf })
  local keys = vim.api.nvim_replace_termcodes("jVj<leader>as", true, false, true)
  vim.api.nvim_feedkeys(keys, "x", false)

  eq(1, #sent)
  eq("send_prompt", sent[1].type)
  ok(sent[1].prompt:find("two", 1, true), "prompt should contain the selected line")
  ok(sent[1].prompt:find("three", 1, true), "prompt should contain the selected line")
  ok(not sent[1].prompt:find("one\n", 1, true), "prompt should not contain unselected line 1")
  eq(1, sent[1].context.startLine)
  eq(2, sent[1].context.endLine)
  vim.keymap.del("v", "<leader>as", { buffer = buf })
  vim.api.nvim_buf_delete(buf, { force = true })
  restore()
end)

test("NanocoderSend: an explicit command range sends those lines", function()
  local sent, restore = capture_send()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
  vim.api.nvim_buf_set_name(buf, "/tmp/cmd-range.lua")
  vim.api.nvim_set_current_buf(buf)

  vim.cmd("2,3NanocoderSend")

  eq(1, #sent)
  eq("send_prompt", sent[1].type)
  ok(sent[1].prompt:find("two", 1, true), "prompt should contain line 2")
  ok(sent[1].prompt:find("three", 1, true), "prompt should contain line 3")
  eq(1, sent[1].context.startLine)
  eq(2, sent[1].context.endLine)
  vim.api.nvim_buf_delete(buf, { force = true })
  restore()
end)

test("NanocoderSend: without a range or selection it prompts for a message", function()
  local sent, restore = capture_send()
  local orig_input = vim.fn.input
  local asked
  vim.fn.input = function(prompt)
    asked = prompt
    return "fix the bug"
  end

  vim.cmd("NanocoderSend")

  eq("Nanocoder prompt: ", asked)
  eq(1, #sent)
  eq("send_prompt", sent[1].type)
  eq("fix the bug", sent[1].prompt)
  vim.fn.input = orig_input
  restore()
end)
