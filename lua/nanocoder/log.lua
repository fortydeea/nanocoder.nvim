-- Leveled logging. Lines are appended to a log file; warnings and errors are
-- also surfaced through vim.notify. Nothing here ever interrupts the editor.
local M = {}

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }

local state = {
  level = "info",
  file = nil,
}

---Default log path: stdpath("cache")/nanocoder.log.
---@return string
function M.default_path()
  return vim.fn.stdpath("cache") .. "/nanocoder.log"
end

---Set the minimum log level.
---@param level string one of trace|debug|info|warn|error
function M.set_level(level)
  if LEVELS[level] then
    state.level = level
  end
end

---Set the log file path. Pass nil to disable file logging.
---@param path string|nil
function M.set_file(path)
  state.file = path
end

---@return string current level
function M.get_level()
  return state.level
end

local function write(level, msg)
  if LEVELS[level] < LEVELS[state.level] then
    return
  end
  local line = string.format("[nanocoder][%s] %s", level, msg)

  if state.file then
    local ok, f = pcall(io.open, state.file, "a")
    if ok and f then
      f:write(line, "\n")
      f:close()
    end
  end

  -- Only warnings and errors reach the user; the rest belongs in the file.
  if level == "warn" or level == "error" then
    local notify_level = level == "error" and vim.log.levels.ERROR or vim.log.levels.WARN
    vim.notify(line, notify_level)
  end
end

for _, level in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  M[level] = function(msg)
    write(level, msg)
  end
end

return M
