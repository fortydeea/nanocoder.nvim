-- Read the nanocoder companion discovery file (`vscode-server.json`).
-- Mirrors nanocoder's source/vscode/discovery.ts reader rules: treat missing,
-- corrupt, shape-invalid, version-too-new, and stale-pid files as "not ready".
local compat = require("nanocoder.compat")

local M = {}

M.DISCOVERY_FILENAME = "vscode-server.json"
M.DISCOVERY_VERSION = 1

---Resolve the nanocoder config directory the same way the CLI does.
---@return string
function M.default_config_dir()
  local env_config = os.getenv("NANOCODER_CONFIG_DIR")
  if env_config and env_config ~= "" then
    return env_config
  end
  local base
  if compat.uv.os_uname().sysname == "Windows_NT" then
    base = os.getenv("APPDATA")
    if not base or base == "" then
      base = (os.getenv("USERPROFILE") or "") .. "\\AppData\\Roaming"
    end
  elseif compat.uv.os_uname().sysname == "Darwin" then
    base = (os.getenv("HOME") or "") .. "/Library/Preferences"
  else
    base = os.getenv("XDG_CONFIG_HOME")
    if not base or base == "" then
      base = (os.getenv("HOME") or "") .. "/.config"
    end
  end
  return base .. "/nanocoder"
end

---Absolute path to the discovery file.
---@param config_dir string|nil override for tests
---@return string
function M.discovery_path(config_dir)
  return (config_dir or M.default_config_dir()) .. "/" .. M.DISCOVERY_FILENAME
end

---Test whether a PID is alive without signalling it.
---`kill(pid, 0)`: success or EPERM means alive, ESRCH means dead.
---@param pid number
---@param uv table|nil uv table to use (injectable for tests)
---@return boolean
function M.is_process_alive(pid, uv)
  uv = uv or compat.uv
  if type(pid) ~= "number" or pid ~= pid or pid <= 0 or pid % 1 ~= 0 then
    return false
  end
  -- luv's kill() returns 0 on success or nil, err on failure; it does not throw.
  local ok, err = uv.kill(pid, 0)
  if ok then
    return true
  end
  -- EPERM: exists but is not ours to signal. Anything else: dead or unusable.
  return type(err) == "string" and err:match("EPERM") ~= nil
end

---Parse raw discovery-file JSON with the upstream reader rules.
---@param raw string file contents
---@param opts table|nil { alive_fn = fun(pid:number):boolean } injectable for tests
---@return table|nil info, string|nil err
function M.parse(raw, opts)
  opts = opts or {}
  local alive_fn = opts.alive_fn or M.is_process_alive

  local ok, parsed = pcall(compat.json_decode, raw)
  if not ok or type(parsed) ~= "table" then
    return nil, "corrupt discovery file"
  end

  -- Shape check: port, token, pid are mandatory.
  if type(parsed.port) ~= "number" or type(parsed.token) ~= "string" or type(parsed.pid) ~= "number" then
    return nil, "discovery file has invalid shape"
  end

  -- Refuse a newer schema than we understand; older ones stay readable.
  local version = type(parsed.version) == "number" and parsed.version or M.DISCOVERY_VERSION
  if version > M.DISCOVERY_VERSION then
    return nil, "discovery file version " .. version .. " is newer than supported " .. M.DISCOVERY_VERSION
  end

  -- Stale detection: a dead PID means the CLI that wrote this is gone.
  if not alive_fn(parsed.pid) then
    return nil, "discovery file is stale (pid " .. tostring(parsed.pid) .. " not running)"
  end

  return {
    version = version,
    port = parsed.port,
    token = parsed.token,
    pid = parsed.pid,
    cliVersion = type(parsed.cliVersion) == "string" and parsed.cliVersion or "0.0.0",
    startedAt = type(parsed.startedAt) == "number" and parsed.startedAt or 0,
  }
end

---Read and parse the discovery file.
---@param opts table|nil { path = string, alive_fn = fun(pid:number):boolean }
---@return table|nil info, string|nil err
function M.read(opts)
  opts = opts or {}
  local path = opts.path or M.discovery_path()
  local f = io.open(path, "r")
  if not f then
    return nil, "discovery file not found: " .. path
  end
  local raw = f:read("*a")
  f:close()
  return M.parse(raw, opts)
end

---Resolve connection info from manual config (SSH/remote fallback) or the
---discovery file, preferring explicit config when both are present.
---@param cfg table plugin config (uses cfg.port / cfg.token / cfg.discovery_path)
---@return table|nil info, string|nil err
function M.resolve(cfg)
  if cfg and cfg.port and cfg.token and cfg.token ~= "" then
    return {
      version = M.DISCOVERY_VERSION,
      port = cfg.port,
      token = cfg.token,
      pid = nil,
      cliVersion = "manual",
      startedAt = 0,
    }
  end
  return M.read({ path = cfg and cfg.discovery_path or nil })
end

return M
