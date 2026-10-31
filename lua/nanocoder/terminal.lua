-- Terminal integration: run the nanocoder CLI inside Neovim (or externally).
-- Providers: "native" (built-in :terminal), "external" (spawn a terminal app),
-- "none" (no terminal at all), or a custom table implementing the provider API.
local config = require("nanocoder.config")
local log = require("nanocoder.log")

local M = {}

-- Resolved provider state, owned by setup().
local state = {
  provider = nil,
  provider_name = nil,
  bufnr = nil,
  winid = nil,
  job_id = nil,
  cmd = nil,
  args = nil,
  session = nil, -- one-shot session flags for the next spawn
}

---Launch arguments for the CLI. `nanocoder --vscode` starts the companion
---WebSocket server the plugin then dials into. `--no-alt-screen` keeps the TUI
---inline so the terminal buffer stays ordinary scrollback the plugin can read.
---@param cfg table|nil
---@return string[] argv
function M.build_cli_argv(cfg)
  cfg = cfg or config.get()
  local argv = { cfg.terminal_cmd or "nanocoder", "--vscode", "--no-alt-screen" }
  return argv
end

--------------------------------------------------------------
-- Native provider: a built-in :terminal buffer in a split.
--------------------------------------------------------------

local native = {}

---Buffers already being followed, so a reattach never stacks a second handler.
local following_bufs = {}

function native.is_available()
  return true
end

---Hold the normal-mode cursor where the user left it while the CLI repaints.
---The CLI appends output and clears its saved lines (CSI 2J/3J/H). Each clear
---removes the lines above the cursor and Neovim answers by shifting it up the
---buffer, so the transcript creeps past it and the cursor walks to line 1.
---A repaint rebuilds the same transcript, so the one thing that survives it is
---the cursor's distance from the end of the buffer. Restoring that distance
---keeps the tail at the tail and leaves a cursor the user scrolled up exactly
---where they put it.
---@param buf integer terminal buffer
---@param win integer window showing it
local function hold_row(buf, win)
  if following_bufs[buf] then
    return
  end
  following_bufs[buf] = true
  local offset = 0 -- lines between the cursor and the last line
  local scheduled = false

  local function attached()
    return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
  end

  local function record()
    offset = vim.api.nvim_buf_line_count(buf) - vim.api.nvim_win_get_cursor(win)[1]
  end

  -- CursorMoved does not fire for cursor changes inside a terminal buffer, so
  -- watch the keys instead: a key in normal mode is the only way the user can
  -- move the cursor here.
  local ns = vim.api.nvim_create_namespace("nanocoder_terminal_cursor")
  vim.on_key(function()
    if vim.api.nvim_get_current_buf() ~= buf then
      return
    end
    vim.schedule(function()
      if attached() and vim.api.nvim_get_mode().mode:sub(1, 1) == "n" then
        record()
      end
    end)
  end, ns)

  vim.api.nvim_buf_attach(buf, false, {
    -- on_bytes reports byte edits only, so drops at the top of the buffer are
    -- only visible here.
    on_lines = function(_, _, _, first, last, new_last)
      if not attached() or scheduled then
        return
      end

      local dropped = first == 0 and math.max(last - new_last, 0) or 0
      local count = vim.api.nvim_buf_line_count(buf)
      local line = vim.api.nvim_win_get_cursor(win)[1]
      if dropped == 0 or M._cursor_line_for(count, offset) == line then
        return
      end

      scheduled = true
      local moved = line
      -- Setting the cursor inside the callback does not stick: Neovim shifts it
      -- again once the redraw finishes, so defer to the main loop. One restore
      -- covers a burst of drops because it re-reads the buffer when it runs.
      vim.schedule(function()
        scheduled = false
        if not attached() or vim.api.nvim_get_mode().mode:sub(1, 1) == "t" then
          return
        end
        -- A different line means the user moved the cursor in the meantime,
        -- and that is their view to keep.
        if vim.api.nvim_win_get_cursor(win)[1] ~= moved then
          return
        end
        local now = vim.api.nvim_buf_line_count(buf)
        pcall(vim.api.nvim_win_set_cursor, win, { M._cursor_line_for(now, offset), 0 })
      end)
    end,
    on_detach = function()
      vim.on_key(nil, ns)
      following_bufs[buf] = nil
    end,
  })
end

---True when a job id refers to a job that has not exited yet.
---@param job_id integer|nil
---@return boolean
local function job_alive(job_id)
  if not job_id then
    return false
  end
  -- jobwait with timeout 0 returns -1 for a job still running.
  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

---Open the CLI in a native terminal split. Reuses the existing window and a
---still-running job where possible so a relaunch never stacks a second split.
---@param cfg table
---@param focus boolean|nil
---@return boolean opened
function native.open(cfg, focus)
  local term = cfg.terminal
  local alive = job_alive(state.job_id)

  -- Window open and job running: nothing to do.
  if M.is_open() and alive then
    return true
  end

  -- Reuse the existing window when its job died, otherwise open a split.
  local direction = term.split_direction or "botright"
  local vertical = direction:find("vert", 1, true) ~= nil
  local win, created = state.winid, false
  if not (win and vim.api.nvim_win_is_valid(win)) then
    vim.cmd(direction .. " split")
    win = vim.api.nvim_get_current_win()
    created = true
    if vertical then
      -- split_width_percentage (when set) overrides the fixed column width.
      local pct = term.split_width_percentage
      local width = pct and math.floor(vim.o.columns * pct) or (term.split_width or 40)
      vim.api.nvim_win_set_width(win, math.max(width, 10))
    else
      local height = math.floor(vim.o.lines * (term.split_height_percentage or 0.4))
      vim.api.nvim_win_set_height(win, math.max(height, 3))
    end
  end

  -- Pin the split so splits opened/closed for diffs never redistribute its
  -- size ('equalalways' would otherwise grow the terminal after each diff).
  if vertical then
    vim.wo[win].winfixwidth = true
  else
    vim.wo[win].winfixheight = true
  end

  -- Window closed but the job still runs: show that buffer again.
  if alive and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_win_set_buf(win, state.bufnr)
    state.winid = win
    hold_row(state.bufnr, win)
    if term.auto_insert and focus ~= false then
      vim.cmd("startinsert")
    end
    log.debug("terminal reattached (job " .. tostring(state.job_id) .. ")")
    return true
  end

  -- An exited job's buffer is dead weight; drop it before spawning a new CLI.
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
    state.bufnr = nil
    state.job_id = nil
  end

  local cmd = M.take_cli_argv(cfg)
  local cwd = config.effective_cwd(cfg)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  local job_id
  if vim.fn.exists("*termopen") == 1 then
    job_id = vim.fn.termopen(cmd, { cwd = cwd })
  else
    job_id = vim.fn.jobstart(cmd, { cwd = cwd, term = true })
  end
  if job_id <= 0 then
    log.error("failed to start terminal job: " .. table.concat(cmd, " "))
    if created then
      vim.api.nvim_win_close(win, true)
    end
    return false
  end

  state.bufnr = buf
  state.winid = win
  state.job_id = job_id

  hold_row(buf, win)

  if term.auto_insert and focus ~= false then
    vim.cmd("startinsert")
  end
  log.debug("terminal opened (job " .. job_id .. ")")
  return true
end

function native.close()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
end

function native.focus()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
    if config.get().terminal.auto_insert then
      vim.cmd("startinsert")
    end
    return true
  end
  return false
end

function native.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

---Write text to the terminal job channel.
---@param text string
---@param submit boolean append "\r" to submit
---@return boolean ok
function native.send_text(text, submit)
  if not state.job_id then
    return false
  end
  local payload = text .. (submit and "\r" or "")
  local ok = pcall(vim.api.nvim_chan_send, state.job_id, payload)
  return ok and true or false
end

function native.get_bufnr()
  return state.bufnr
end

--------------------------------------------------------------
-- External provider: spawn a terminal application outside Neovim.
--------------------------------------------------------------

local external = {}

function external.is_available(cfg)
  local opts = (cfg and cfg.terminal and cfg.terminal.provider_opts) or {}
  return opts.external_terminal_cmd ~= nil
end

---Build the command for an external terminal.
---Accepts a string template (`%s` = CLI command) or a function(cmd, env).
---@param cfg table
---@param cli_argv string[]
---@return string[]|nil argv
local function external_argv(cfg, cli_argv)
  local opts = cfg.terminal.provider_opts or {}
  local tmpl = opts.external_terminal_cmd
  local cli_str = table.concat(cli_argv, " ")
  if type(tmpl) == "function" then
    local ok, result = pcall(tmpl, cli_str, { cwd = config.effective_cwd(cfg) })
    if not ok then
      log.error("external_terminal_cmd function failed: " .. tostring(result))
      return nil
    end
    if type(result) == "string" then
      return { result }
    end
    return result
  end
  if type(tmpl) == "string" then
    -- Support both `%s` (command) and two `%s` (cwd, command) templates.
    local cwd = config.effective_cwd(cfg)
    local cmd = tmpl
    local first = cmd:find("%%s", 1, true)
    if first then
      local second = cmd:find("%%s", first + 3, true)
      if second then
        cmd = cmd:gsub("%%s", cwd, 1):gsub("%%s", cli_str, 1)
      else
        cmd = cmd:gsub("%%s", cli_str, 1)
      end
    end
    return { cmd }
  end
  return nil
end

function external.open(cfg)
  local argv = external_argv(cfg, M.take_cli_argv(cfg))
  if not argv then
    log.error("external provider: no external_terminal_cmd configured")
    return false
  end
  local ok, err = pcall(function()
    vim.fn.jobstart(argv, { detach = true, cwd = config.effective_cwd(cfg) })
  end)
  if not ok then
    log.error("external provider failed to spawn: " .. tostring(err))
    return false
  end
  return true
end

function external.close()
  -- External terminals are managed by the user's terminal application.
end

function external.focus()
  return false
end

function external.is_open()
  return false
end

function external.send_text()
  log.warn("external provider cannot receive typed text; run prompts in the external terminal")
  return false
end

--------------------------------------------------------------
-- None provider: no terminal management at all.
--------------------------------------------------------------

local none = {
  is_available = function()
    return true
  end,
  open = function()
    log.info("terminal provider is 'none'; start `nanocoder --vscode --no-alt-screen` yourself")
    return false
  end,
  close = function() end,
  focus = function()
    return false
  end,
  is_open = function()
    return false
  end,
  send_text = function()
    log.warn("terminal provider is 'none'; there is no pane to type into")
    return false
  end,
}

--------------------------------------------------------------
-- Public terminal API (dispatches to the active provider).
--------------------------------------------------------------

local BUILTIN = {
  native = native,
  external = external,
  none = none,
}

---Select the provider from config and return it.
---@param cfg table
---@return table provider
local function resolve_provider(cfg)
  local name = cfg.terminal and cfg.terminal.provider or "native"
  if type(name) == "table" then
    -- Custom provider table: require the API surface we call.
    for _, fn in ipairs({ "open", "close", "focus", "is_open" }) do
      if type(name[fn]) ~= "function" then
        error("[nanocoder] custom terminal provider missing function: " .. fn)
      end
    end
    return name
  end
  return BUILTIN[name] or BUILTIN.native
end

---Initialize the terminal layer (called from setup()).
---@param cfg table
function M.setup(cfg)
  state.provider = resolve_provider(cfg)
  state.provider_name = type(cfg.terminal.provider) == "table" and "custom" or cfg.terminal.provider
  if state.provider_name == "external" and not external.is_available(cfg) then
    log.warn("external terminal provider selected but provider_opts.external_terminal_cmd is unset; falling back to native")
    state.provider = BUILTIN.native
    state.provider_name = "native"
  end
end

---Override the CLI launch command (used by :NanocoderSelectModel).
---@param argv string[]
function M.set_cli_argv(argv)
  state.cmd = argv
end

---@return string[]|nil argv
function M.get_cli_argv()
  return state.cmd
end

---Set one-shot session flags for the next launch (e.g. {"--continue"} or
---{"--resume", "last"}), used by :NanocoderContinue and :NanocoderResume.
---@param args string[]|nil
function M.set_session_args(args)
  state.session = args
end

---@return string[]|nil
function M.get_session_args()
  return state.session
end

---argv for the next spawn: the CLI argv plus any pending session flags.
---Consumes the session flags so later plain launches start a fresh session.
---@param cfg table|nil
---@return string[] argv
function M.take_cli_argv(cfg)
  local argv = vim.deepcopy(state.cmd or M.build_cli_argv(cfg))
  if state.session then
    vim.list_extend(argv, state.session)
    state.session = nil
  end
  return argv
end

---Open the terminal (idempotent).
---@param focus boolean|nil
---@return boolean
function M.open(focus)
  local cfg = config.get()
  return state.provider.open(cfg, focus)
end

---Close the terminal window (the job keeps running).
function M.close()
  state.provider.close()
end

---Focus the terminal window when it is open.
---@return boolean focused
function M.focus()
  return state.provider.focus()
end

---Toggle terminal visibility: open when closed, focus when already open,
---close when focused.
---@return boolean
function M.toggle()
  if not state.provider.is_open() then
    return M.open(true)
  end
  local win = state.winid
  if win and vim.api.nvim_get_current_win() == win then
    M.close()
    return false
  end
  return M.focus()
end

---@return boolean
function M.is_open()
  return state.provider.is_open()
end

---@return boolean
function M.is_running()
  return job_alive(state.job_id)
end

---Type text into the terminal pane.
---@param text string
---@param submit boolean|nil append Enter (default true)
---@return boolean
function M.send_text(text, submit)
  if submit == nil then
    submit = true
  end
  return state.provider.send_text(text, submit)
end

---@return integer|nil bufnr
function M.get_bufnr()
  return state.bufnr
end

---Stop the terminal job and clear the pane it ran in (used by :NanocoderStop).
function M.stop_job()
  if state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
  end
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  state.job_id = nil
  state.bufnr = nil
  state.winid = nil
  log.debug("terminal job stopped")
end

---@return string provider name for diagnostics
function M.get_provider_name()
  return state.provider_name or "native"
end

---Line to put the cursor on so its distance from the end of the transcript is
---preserved across a repaint. Exposed for tests.
---@param count integer line count after a drop
---@param offset integer lines between the cursor and the last line
---@return integer
function M._cursor_line_for(count, offset)
  return math.max(1, count - offset)
end

return M
