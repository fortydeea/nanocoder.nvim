-- :checkhealth nanocoder — environment, CLI, discovery file, and connection.
-- vim.health is 0.10+; Neovim 0.8/0.9 exposes the same API via require("health").
local M = {}

local health = vim.health or require("health")

-- The 0.8/0.9 module uses report_* names; normalize to the 0.10 API.
local function h_ok(msg)
  (health.ok or health.report_ok)(msg)
end

local function h_warn(msg)
  (health.warn or health.report_warn)(msg)
end

local function h_error(msg)
  (health.error or health.report_error)(msg)
end

local function h_info(msg)
  (health.info or health.report_info)(msg)
end

local function h_start(msg)
  (health.start or health.report_start)(msg)
end

function M.check()
  h_start("nanocoder")

  -- Neovim version -----------------------------------------------

  local v = vim.version()
  if v.major > 0 or v.minor >= 8 then
    h_ok(string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch))
  else
    h_error("Neovim >= 0.8 is required")
  end

  if not (vim.uv or vim.loop) then
    h_error("no vim.uv/vim.loop binding found")
  end

  -- nanocoder CLI -----------------------------------------------

  local config = require("nanocoder.config")
  local cfg = config.get()
  local cmd = cfg.terminal_cmd or "nanocoder"
  if vim.fn.executable(cmd) ~= 1 then
    h_error(cmd .. " is not runnable. Install the Nano-Collective nanocoder CLI (`npm install -g @nanocollective/nanocoder`).")
  else
    local version = vim.fn.systemlist({ cmd, "--version" })
    if vim.v.shell_error == 0 then
      h_ok(cmd .. ": " .. (version[1] or "(no version output)"))
    else
      h_error(cmd .. " is not runnable. Install the Nano-Collective nanocoder CLI (`npm install -g @nanocollective/nanocoder`).")
    end
  end

  -- Discovery file ----------------------------------------------

  local discovery = require("nanocoder.discovery")
  local path = cfg.discovery_path or discovery.discovery_path()
  local info_tbl, err = discovery.read({ path = path })
  if info_tbl then
    h_ok(string.format("discovery file %s (port %d, cli %s, pid %d)",
      path, info_tbl.port, info_tbl.cliVersion, info_tbl.pid))
    if not cfg.port then
      h_info("using discovery file for port/token (set `port`/`token` to override)")
    end
  else
    h_warn(path .. ": " .. tostring(err))
    if cfg.port and cfg.token then
      h_ok("manual port/token configured (discovery file not needed)")
    else
      h_warn("run `nanocoder --vscode` (or :NanocoderStart) to create the discovery file")
    end
  end

  -- Connection --------------------------------------------------

  local client = require("nanocoder.client")
  if client.is_connected() then
    local i = client.get_info()
    h_ok("WebSocket connected on port " .. tostring(i and i.port))
  else
    h_warn("not connected to a nanocoder companion")
  end

  -- Terminal provider ------------------------------------------

  local terminal = require("nanocoder.terminal")
  h_info("terminal provider: " .. terminal.get_provider_name())
  if terminal.get_provider_name() == "external" then
    local opts = (cfg.terminal and cfg.terminal.provider_opts) or {}
    if not opts.external_terminal_cmd then
      h_error("external provider selected but provider_opts.external_terminal_cmd is not set")
    end
  end

  -- Pending diffs ----------------------------------------------

  local diff = require("nanocoder.diff")
  if diff.pending_count() > 0 then
    h_info(diff.pending_count() .. " pending diff(s)")
  end
end

return M
