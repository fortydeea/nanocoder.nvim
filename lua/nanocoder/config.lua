-- User configuration: defaults, deep merge, validation.
local log = require("nanocoder.log")

local M = {}

---Default configuration values.
M.defaults = {
  log_level = "info",
  terminal_cmd = "nanocoder",
  auto_connect = true,
  discovery_path = nil,
  port = nil,
  token = nil,
  diff_opts = {
    layout = "vertical", -- "vertical" | "horizontal" | "unified"
    open_in_new_tab = false,
    keep_terminal_focus = false,
    hide_terminal_in_new_tab = false,
    auto_resize_terminal = true,
  },
  terminal = {
    provider = "native", -- "native" | "external" | "none" | custom table
    split_direction = "botright",
    split_width_percentage = nil,
    split_height_percentage = 0.4,
    focus_after_send = true,
    auto_insert = true,
    provider_opts = {
      external_terminal_cmd = nil,
    },
    cwd = nil,
    git_repo_cwd = false,
    cwd_provider = nil,
  },
}

---Valid option values for quick validation.
local ENUMS = {
  log_level = { trace = true, debug = true, info = true, warn = true, error = true },
  ["diff_opts.layout"] = { vertical = true, horizontal = true, unified = true },
  ["terminal.provider"] = { native = true, external = true, none = true },
}

M._config = nil

local function validate_enum(path, value, allowed)
  if value ~= nil and not allowed[value] then
    return string.format("invalid %s: %q (expected one of %s)", path, tostring(value), table.concat(vim.tbl_keys(allowed), ", "))
  end
  return nil
end

---Validate a config table. Returns nil when valid, or an error string.
---@param cfg table
---@return string|nil err
function M.validate(cfg)
  local err = validate_enum("log_level", cfg.log_level, ENUMS.log_level)
  if err then
    return err
  end
  err = validate_enum("diff_opts.layout", cfg.diff_opts and cfg.diff_opts.layout, ENUMS["diff_opts.layout"])
  if err then
    return err
  end
  local provider = cfg.terminal and cfg.terminal.provider
  if provider ~= nil then
    if type(provider) == "string" then
      err = validate_enum("terminal.provider", provider, ENUMS["terminal.provider"])
      if err then
        return err
      end
    elseif type(provider) ~= "table" then
      return "terminal.provider must be a string or a custom provider table"
    end
  end
  if cfg.port ~= nil and (type(cfg.port) ~= "number" or cfg.port % 1 ~= 0 or cfg.port < 1 or cfg.port > 65535) then
    return "port must be an integer between 1 and 65535"
  end
  if cfg.token ~= nil and type(cfg.token) ~= "string" then
    return "token must be a string"
  end
  return nil
end

---Merge user options over the defaults and store the result.
---Replaces the stored config wholesale (setup() is expected once).
---@param opts table|nil user options
---@return table cfg
function M.setup(opts)
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local err = M.validate(cfg)
  if err then
    error("[nanocoder] config error: " .. err, 0)
  end
  M._config = cfg
  log.set_level(cfg.log_level)
  if cfg.log_file then
    log.set_file(cfg.log_file)
  end
  return cfg
end

---The active config. Falls back to defaults when setup() has not run.
---@return table
function M.get()
  return M._config or M.defaults
end

---Resolve the working directory the CLI should run in.
---Precedence: terminal.cwd_provider(ctx) > terminal.cwd > git root (when
---git_repo_cwd) > current working directory.
---@param cfg table|nil
---@return string cwd
function M.effective_cwd(cfg)
  cfg = cfg or M.get()
  local term = cfg.terminal or {}
  local file = vim.api.nvim_buf_get_name(0)
  local file_dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or nil
  local ctx = { file = file ~= "" and file or nil, file_dir = file_dir, cwd = vim.fn.getcwd() }

  if term.cwd_provider then
    local ok, provided = pcall(term.cwd_provider, ctx)
    if ok and type(provided) == "string" and provided ~= "" then
      return provided
    end
  end
  if term.cwd and term.cwd ~= "" then
    return term.cwd
  end
  if term.git_repo_cwd then
    local start = file_dir or ctx.cwd
    local root = vim.fn.systemlist({ "git", "-C", start, "rev-parse", "--show-toplevel" })[1]
    if vim.v.shell_error == 0 and root and root ~= "" then
      return root
    end
  end
  return ctx.cwd
end

return M
