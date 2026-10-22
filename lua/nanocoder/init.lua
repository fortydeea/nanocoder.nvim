-- nanocoder.nvim: Neovim companion for the nanocoder coding agent.
-- Pure Lua, zero dependencies. See README.md and PROTOCOL.md.
local M = {}

local initialized = false

---Configure and start the plugin.
---@param opts table|nil see config.lua for the schema
function M.setup(opts)
  local config = require("nanocoder.config")
  local log = require("nanocoder.log")

  local cfg = config.setup(opts)
  require("nanocoder.terminal").setup(cfg)
  require("nanocoder.commands").setup()
  require("nanocoder.context").setup()
  require("nanocoder.diagnostics").setup()
  require("nanocoder.handlers").setup()
  require("nanocoder.diff").setup()
  require("nanocoder.client").on_connection(function(connected, reason)
    if connected then
      log.info("nanocoder companion connected")
    elseif reason then
      log.debug("nanocoder companion disconnected: " .. reason)
    end
  end)

  local client = require("nanocoder.client")
  local protocol = require("nanocoder.protocol")
  client.on(protocol.T_CONNECTION_ACK, function(msg)
    log.info("companion protocol " .. msg.protocolVersion .. " (cli " .. tostring(msg.cliVersion) .. ")")
  end)
  client.on(protocol.T_STATUS, function(msg)
    M._model = msg.model
    M._provider = msg.provider
    if msg.connected then
      log.debug(string.format("companion status: model=%s provider=%s cwd=%s",
        tostring(msg.model), tostring(msg.provider), tostring(msg.workingDirectory)))
    end
  end)
  client.on_unhandled(function(msg)
    log.debug("unhandled message type: " .. tostring(msg.type))
  end)

  initialized = true
  if cfg.auto_connect then
    -- Defer so setup() returns even when no companion is running yet.
    vim.defer_fn(function()
      require("nanocoder.client").connect()
    end, 200)
  end
end

---@return boolean
function M.is_initialized()
  return initialized
end

---Toggle the terminal window (same as :Nanocoder).
function M.toggle()
  return require("nanocoder.terminal").toggle()
end

---Focus the terminal window (same as :NanocoderFocus).
function M.focus()
  return require("nanocoder.terminal").focus()
end

---Start the terminal and connection.
function M.start()
  local terminal = require("nanocoder.terminal")
  local client = require("nanocoder.client")
  -- open() is idempotent: it reattaches to a live job and revives a dead pane
  -- in place instead of stacking a second split.
  terminal.open(false)
  client.reset()
  client.connect()
end

---Stop the connection and the terminal job.
function M.stop()
  require("nanocoder.client").disconnect()
  require("nanocoder.terminal").stop_job()
end

---Open the terminal window without focusing it.
function M.open()
  return require("nanocoder.terminal").open(false)
end

---Close the terminal window.
function M.close()
  require("nanocoder.terminal").close()
end

---Send a prompt (with optional context) to the connected CLI.
---@param prompt string
---@param context table|nil { filePath?, selection?, fileName?, startLine?, endLine?, cursorPosition? }
---@return boolean sent
function M.send(prompt, context)
  local protocol = require("nanocoder.protocol")
  local client = require("nanocoder.client")
  return client.send(protocol.send_prompt(prompt, context))
end

---Report connection and last-known status.
---@return table
function M.status()
  local client = require("nanocoder.client")
  local info = client.get_info()
  return {
    connected = client.is_connected(),
    port = info and info.port or nil,
    cli_version = info and info.cliVersion or nil,
    terminal_open = require("nanocoder.terminal").is_open(),
    terminal_provider = require("nanocoder.terminal").get_provider_name(),
    model = M._model,
    provider = M._provider,
  }
end

-- Last-known model/provider, updated by the status message handler.
M._model = nil
M._provider = nil

return M
