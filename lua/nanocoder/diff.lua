-- Native diff review for proposed file changes (file_change lifecycle).
-- A `file_change` message from the CLI opens a diff view; :w accepts (sends
-- apply_change), :q rejects (sends reject_change). `close_diff` closes the
-- matching view. The CLI is authoritative for applying the change — the diff
-- view is a review surface, not the source of truth.
local client = require("nanocoder.client")
local config = require("nanocoder.config")
local log = require("nanocoder.log")
local protocol = require("nanocoder.protocol")
local terminal = require("nanocoder.terminal")

local M = {}

---Pending diffs keyed by the CLI's file_change id.
---@type table<string, table>
M._pending = {}

---Open diff view state, keyed by buffer number.
local buf_state = {}

---Build the User event payload for a diff view.
---@param entry table pending diff entry
---@param reason string|nil for the Closed event
---@return table data
local function event_data(entry, reason)
  return {
    tab_name = entry.tab_name,
    file_path = entry.file_path,
    new_file_path = entry.new_file_path,
    is_new_file = entry.is_new_file,
    diff_window = entry.diff_window,
    target_window = entry.target_window,
    terminal_window = terminal.is_open() and terminal.get_bufnr() or nil,
    tab_number = entry.tab_number,
    reason = reason,
  }
end

local function fire_user(name, data)
  vim.api.nvim_exec_autocmds("User", { pattern = name, data = data })
end

---Clear diff mode and drop scratch buffers so repeated diffs do not accumulate
---in diff mode until Neovim refuses with E96 (max 8 diff buffers).
---@param entry table
local function cleanup_diff(entry)
  for _, win in ipairs({ entry.left_win, entry.diff_window }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(function()
        vim.api.nvim_win_call(win, function()
          vim.cmd("diffoff")
        end)
      end)
    end
  end
  -- Both sides are scratch buffers we created (the proposed content is never
  -- written to disk — the CLI applies the change), so both are safe to delete.
  if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) then
    pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
  end
  if entry.is_new_file and entry.left_bufnr and vim.api.nvim_buf_is_valid(entry.left_bufnr) then
    pcall(vim.api.nvim_buf_delete, entry.left_bufnr, { force = true })
  end
end

---Close a diff view and notify the CLI.
---@param id string file_change id
---@param accepted boolean true = apply_change, false = reject_change
---@param reason string
local function resolve(id, accepted, reason)
  local entry = M._pending[id]
  if not entry then
    log.debug("diff resolve: unknown id " .. tostring(id))
    return false
  end
  -- Remove the entry before closing the window so the BufWinLeave handler
  -- (which rejects) sees nothing left to do and does not double-send.
  M._pending[id] = nil
  buf_state[entry.bufnr] = nil

  local msg = accepted and protocol.apply_change(id) or protocol.reject_change(id)
  client.send(msg)

  cleanup_diff(entry)
  if entry.diff_window and vim.api.nvim_win_is_valid(entry.diff_window) then
    pcall(vim.api.nvim_win_close, entry.diff_window, true)
  end

  fire_user("NanocoderDiffClosed", event_data(entry, reason))
  log.info((accepted and "accepted" or "rejected") .. " diff: " .. (entry.file_path or "?"))
  return true
end

---Look up the pending diff entry whose proposed buffer is `bufnr`.
---@param bufnr integer
---@return table|nil entry
function M._entry_for_buf(bufnr)
  local state = buf_state[bufnr]
  if state and M._pending[state.id] then
    return M._pending[state.id]
  end
  return nil
end

---Open a diff view for a proposed change.
---@param msg table file_change message
---@return boolean opened
function M.open(msg)
  local cfg = config.get().diff_opts or {}
  local layout = cfg.layout or "vertical"

  if M._pending[msg.id] then
    log.debug("diff already open for id " .. msg.id)
    return true
  end

  -- If the cursor is inside a proposed diff window, return to the window that
  -- diff was opened from first. Building the next layout from a diff window
  -- would make that window the left side and fire BufWinLeave (auto-reject)
  -- on the previous proposal.
  local current_buf = vim.api.nvim_get_current_buf()
  local here = buf_state[current_buf]
  if here and M._pending[here.id] then
    local origin = M._pending[here.id].left_win
    if origin and vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  end

  -- A new proposal while one is open replaces the previous one (the CLI
  -- only tracks one in-flight change per session in practice).
  for other_id, other in pairs(M._pending) do
    if other.file_path == msg.filePath then
      M.close(other_id, "replaced by new diff")
    end
  end

  local old_path = msg.old_file_path or msg.filePath
  local new_path = msg.new_file_path or msg.filePath
  local is_new = (msg.originalContent == "") and (msg.newContent ~= "")

  -- Left side: the current file on disk (or an empty buffer for new files).
  local left_buf
  local left_win = vim.api.nvim_get_current_win()
  if is_new then
    left_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(left_buf, old_path .. " (current)")
  else
    vim.cmd("edit " .. vim.fn.fnameescape(old_path))
    left_buf = vim.api.nvim_get_current_buf()
    vim.cmd("diffthis")
  end

  -- Right side: the proposed content, marked unmodified so :q is clean.
  local right_buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(right_buf, new_path .. " (proposed)")
  local lines = vim.split(msg.newContent, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, lines)
  vim.bo[right_buf].modified = false

  local diff_win
  if layout == "horizontal" then
    vim.cmd("belowright split")
  else
    vim.cmd("vert belowright split")
  end
  diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(diff_win, right_buf)
  if layout ~= "unified" then
    vim.cmd("diffthis")
  end

  local entry = {
    id = msg.id,
    file_path = old_path,
    new_file_path = new_path,
    is_new_file = is_new,
    tab_name = vim.fn.fnamemodify(new_path, ":t"),
    diff_window = diff_win,
    left_win = left_win,
    target_window = vim.fn.win_getid(vim.fn.winnr("#") or 0),
    bufnr = right_buf,
    left_bufnr = left_buf,
  }
  M._pending[msg.id] = entry
  buf_state[right_buf] = { id = msg.id, accepted = nil }

  -- Buffer-local autocmds: :w accepts (without writing to disk — the CLI
  -- applies the change itself), :q/:close rejects. Normal files are untouched.
  local group = vim.api.nvim_create_augroup("nanocoder_diff_" .. msg.id, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = right_buf,
    callback = function()
      vim.bo[right_buf].modified = false
      M.accept(msg.id)
    end,
    desc = "Nanocoder: accept this diff",
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = right_buf,
    callback = function()
      if M._pending[msg.id] then
        M.deny(msg.id)
      end
    end,
    desc = "Nanocoder: reject this diff when the view is closed",
  })

  vim.keymap.set("n", "q", function()
    M.deny(msg.id)
  end, { buffer = right_buf, desc = "Nanocoder: reject this diff" })

  fire_user("NanocoderDiffOpened", event_data(entry))
  log.info("diff opened for " .. new_path .. " (" .. msg.id .. ")")
  return true
end

---Accept the diff: send apply_change and close the view.
---@param id string
---@return boolean
function M.accept(id)
  return resolve(id, true, "diff accepted")
end

---Reject the diff: send reject_change and close the view.
---@param id string
---@return boolean
function M.deny(id)
  return resolve(id, false, "diff rejected")
end

---Close a diff view without changing the accept/reject outcome.
---@param id string
---@param reason string
---@return boolean
function M.close(id, reason)
  local entry = M._pending[id]
  if not entry then
    return false
  end
  M._pending[id] = nil
  buf_state[entry.bufnr] = nil
  cleanup_diff(entry)
  if entry.diff_window and vim.api.nvim_win_is_valid(entry.diff_window) then
    vim.api.nvim_win_close(entry.diff_window, true)
  end
  fire_user("NanocoderDiffClosed", event_data(entry, reason))
  return true
end

---Accept every pending diff (mirrors claudecode's :NanocoderDiffAccept).
---@return number count
function M.accept_all()
  local count = 0
  for id in pairs(M._pending) do
    if M.accept(id) then
      count = count + 1
    end
  end
  return count
end

---Reject every pending diff.
---@return number count
function M.deny_all()
  local count = 0
  for id in pairs(M._pending) do
    if M.deny(id) then
      count = count + 1
    end
  end
  return count
end

---Close every pending diff without an outcome (clears the view).
---@return number count
function M.close_all(reason)
  local count = 0
  for id in pairs(M._pending) do
    if M.close(id, reason or "closed") then
      count = count + 1
    end
  end
  return count
end

---Number of open diff views.
---@return number
function M.pending_count()
  return vim.tbl_count(M._pending)
end

---Wire the CLI -> editor handlers for the diff lifecycle.
function M.setup()
  client.on(protocol.T_FILE_CHANGE, function(msg)
    local ok, err = pcall(M.open, msg)
    if not ok then
      log.error("file_change handling failed: " .. tostring(err))
    end
  end)
  client.on(protocol.T_CLOSE_DIFF, function(msg)
    M.close(msg.id, "closed by CLI")
  end)
  log.debug("diff lifecycle enabled")
end

return M
