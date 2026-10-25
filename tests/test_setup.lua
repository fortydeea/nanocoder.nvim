-- End-to-end setup() wiring smoke test.
local nanocoder = require("nanocoder")

test("setup() registers every command", function()
  nanocoder.setup({})
  eq(true, nanocoder.is_initialized())
  for _, name in ipairs({
    "Nanocoder",
    "NanocoderFocus",
    "NanocoderStart",
    "NanocoderStop",
    "NanocoderOpen",
    "NanocoderClose",
    "NanocoderStatus",
    "NanocoderSend",
    "NanocoderSendText",
    "NanocoderAdd",
    "NanocoderTreeAdd",
    "NanocoderSelectModel",
    "NanocoderContinue",
    "NanocoderResume",
    "NanocoderRestart",
    "NanocoderDiffAccept",
    "NanocoderDiffDeny",
    "NanocoderCloseAllDiffs",
  }) do
    eq(2, vim.fn.exists(":" .. name), "command :" .. name .. " should exist")
  end
end)

test("status() reports the connection state", function()
  local status = nanocoder.status()
  eq("table", type(status))
  eq(false, status.connected)
  eq("native", status.terminal_provider)
end)

test("re-running setup() is idempotent (commands use force=true)", function()
  nanocoder.setup({ log_level = "warn" })
  eq(true, nanocoder.is_initialized())
end)

test("connection_ack and status messages dispatch to registered handlers", function()
  local client = require("nanocoder.client")
  local dispatched = {}
  client.on("status", function(msg)
    dispatched[#dispatched + 1] = msg
  end)

  -- Exercise the message pipeline without a live socket.
  client._receive_raw(vim.json.encode({ type = "status", connected = true, model = "m1", provider = "p1" }))
  eq(1, #dispatched)
  eq("m1", dispatched[1].model)
end)

test("undecodable messages are discarded without raising", function()
  local client = require("nanocoder.client")
  client._receive_raw("{ not json")
  ok(true)
end)
