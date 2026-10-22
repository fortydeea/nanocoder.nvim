-- User command behavior: :NanocoderSelectModel relaunch rules.
-- Empty or cancelled prompts must never restart the terminal or the socket.
local config = require("nanocoder.config")
local nanocoder = require("nanocoder")
local terminal = require("nanocoder.terminal")

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
