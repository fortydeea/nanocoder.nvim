-- Editor context sharing: selection tracking (active_editor), prompt context
-- assembly, and the "add file to context" commands. Protocol direction is
-- Neovim -> CLI (send_prompt, context, active_editor).
local client = require("nanocoder.client")
local config = require("nanocoder.config")
local log = require("nanocoder.log")
local protocol = require("nanocoder.protocol")
local terminal = require("nanocoder.terminal")

local M = {}

-- Debounce timer for active_editor updates.
local debounce_timer = nil
local DEBOUNCE_MS = 300

-- Files pushed into the CLI's context via :NanocoderAdd / :NanocoderTreeAdd.
local context_files = {}

---Build the active_editor payload from the current window state.
---@return table
local function current_editor_state()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return {}
  end

  local state = {
    filePath = path,
    fileName = vim.fn.fnamemodify(path, ":t"),
  }

  -- Visual selection, when present: capture the selected text and range.
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("[vV\22]") then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2] - 1 -- protocol is 0-based
    local end_line = end_pos[2] - 1
    if start_line >= 0 and end_line >= start_line then
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
      state.selection = table.concat(lines, "\n")
      state.startLine = start_line
      state.endLine = end_line
    end
  end

  return state
end

---Send the current editor state as an active_editor message.
---@param immediate boolean|nil bypass the debounce
function M.update(immediate)
  local function send()
    local state = current_editor_state()
    client.send(protocol.active_editor(state))
    if state.filePath then
      log.debug("active_editor -> " .. state.filePath)
    end
  end

  if immediate then
    send()
    return
  end

  if debounce_timer then
    debounce_timer:stop()
    pcall(function()
      debounce_timer:close()
    end)
    debounce_timer = nil
  end

  local uv = require("nanocoder.compat").uv
  local timer = uv.new_timer()
  debounce_timer = timer
  timer:start(DEBOUNCE_MS, 0, function()
    timer:stop()
    timer:close()
    debounce_timer = nil
    vim.schedule(send)
  end)
end

---Build the prompt context table from the current buffer/selection.
---@param opts table|nil { start_line = number, end_line = number } (0-based, inclusive)
---@return table context
function M.prompt_context(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local ctx = {}

  if path ~= "" then
    ctx.filePath = path
    ctx.fileName = vim.fn.fnamemodify(path, ":t")
    ctx.cursorPosition = {
      line = vim.api.nvim_win_get_cursor(0)[1] - 1,
      character = 0,
    }
  end

  local start_line = opts.start_line
  local end_line = opts.end_line

  if start_line == nil then
    -- Fall back to the visual marks when a selection exists.
    local mode = vim.api.nvim_get_mode().mode
    if mode:match("[vV\22]") then
      start_line = vim.fn.getpos("'<")[2] - 1
      end_line = vim.fn.getpos("'>")[2] - 1
    end
  end

  if start_line and end_line and start_line >= 0 and end_line >= start_line then
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
    ctx.selection = table.concat(lines, "\n")
    ctx.startLine = start_line
    ctx.endLine = end_line
  end

  return ctx
end

---Send a prompt with the current context to the CLI.
---Prefers the WebSocket channel; falls back to typing into the terminal pane
---when the companion is not connected (never both, to avoid duplicates).
---@param prompt string
---@param opts table|nil passed to prompt_context
---@return boolean sent
function M.send_prompt(prompt, opts)
  local ctx = M.prompt_context(opts)
  if client.send(protocol.send_prompt(prompt, ctx)) then
    return true
  end
  if terminal.is_open() then
    log.debug("send_prompt: falling back to terminal input")
    return terminal.send_text(prompt, true)
  end
  log.warn("prompt not sent (companion not connected and no terminal open)")
  return false
end

---Add a file (and optional line range) to the CLI's context.
---@param file_path string
---@param start_line number|nil 0-based
---@param end_line number|nil 0-based
---@return boolean sent
function M.add_file(file_path, start_line, end_line)
  if not file_path or file_path == "" then
    log.warn("add_file: no file path")
    return false
  end

  context_files[file_path] = true

  -- Push the workspace context with the updated openFiles list.
  local open_files = vim.tbl_keys(context_files)
  client.send(protocol.context({
    workspaceFolder = config.effective_cwd(),
    openFiles = open_files,
    activeFile = file_path,
  }))

  -- Also announce the range so the CLI can attach just the selected lines.
  local state = {
    filePath = file_path,
    fileName = vim.fn.fnamemodify(file_path, ":t"),
  }
  if start_line and end_line then
    local bufnr = vim.fn.bufnr(file_path)
    if bufnr ~= -1 then
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
      state.selection = table.concat(lines, "\n")
    end
    state.startLine = start_line
    state.endLine = end_line
  end
  client.send(protocol.active_editor(state))

  log.info("added to context: " .. file_path)
  return true
end

---Extract a file path from a tree/picker buffer line (netrw, nvim-tree,
---neo-tree, oil, minifiles). Best-effort: matches the first absolute or
---./-relative path in the line.
---@param line string
---@return string|nil path
function M.path_from_tree_line(line)
  if not line or line == "" then
    return nil
  end
  -- Prefer the last whitespace-delimited token containing a slash.
  for token in line:gmatch("%S+") do
    if token:match("^/") or token:match("^%./") or token:match("^~") then
      return vim.fn.fnamemodify(token, ":p")
    end
  end
  return nil
end

---Send a visual selection as a prompt to the CLI.
---@return boolean sent
function M.send_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.getpos("'<")[2] - 1
  local end_line = vim.fn.getpos("'>")[2] - 1
  if start_line < 0 or end_line < start_line then
    log.warn("send_selection: no visual selection")
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  local selection = table.concat(lines, "\n")
  local ctx = M.prompt_context({ start_line = start_line, end_line = end_line })
  local prompt = "Please consider this selection:\n\n```\n" .. selection .. "\n```"
  return M.send_prompt(prompt, { start_line = start_line, end_line = end_line })
end

---Clear tracked context files.
function M.clear()
  context_files = {}
end

---@return string[]
function M.get_context_files()
  return vim.tbl_keys(context_files)
end

---Wire autocmds that keep the CLI informed of editor state.
function M.setup()
  local group = vim.api.nvim_create_augroup("nanocoder_context", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function()
      M.update(false)
    end,
    desc = "nanocoder: push active_editor updates to the companion",
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*:[vV\22]*",
    callback = function()
      M.update(true)
    end,
    desc = "nanocoder: push selection state when entering visual mode",
  })

  log.debug("context tracking enabled")
end

return M
