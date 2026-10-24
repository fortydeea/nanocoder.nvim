-- Diff lifecycle: open/accept/deny/close and the User events.
-- NOTE: context.lua's autocmds push active_editor updates in the background
-- during these tests, so assertions filter `sent` by message type rather than
-- counting every message.
local client = require("nanocoder.client")
local config = require("nanocoder.config")
local diff = require("nanocoder.diff")
local handlers = require("nanocoder.handlers")

-- Capture what would be sent to the companion.
local sent = {}
local function capture()
  sent = {}
  client.send = function(msg)
    sent[#sent + 1] = msg
    return true
  end
end

---Count captured messages of a given type.
local function count_type(t)
  local n = 0
  for _, m in ipairs(sent) do
    if m.type == t then
      n = n + 1
    end
  end
  return n
end

---First captured message of a given type, or nil.
local function first_type(t)
  for _, m in ipairs(sent) do
    if m.type == t then
      return m
    end
  end
  return nil
end

local function file_change_msg(id, path, original, new)
  return {
    type = "file_change",
    id = id,
    filePath = path,
    originalContent = original,
    newContent = new,
    toolName = "string_replace",
    toolArgs = {},
  }
end

test("file_change opens a diff and fires NanocoderDiffOpened", function()
  capture()
  config.setup({})
  diff.setup()
  handlers.setup()

  local events = {}
  local group = vim.api.nvim_create_augroup("nanocoder_test_diff_events", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NanocoderDiffOpened",
    callback = function(ev)
      events[#events + 1] = ev.data
    end,
  })

  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("local x = 1\n")
  f:close()

  eq(true, diff.open(file_change_msg("d1", tmp, "local x = 1\n", "local x = 2\n")))
  eq(1, diff.pending_count())
  eq(1, #events)
  eq("d1", diff._pending.d1 and diff._pending.d1.id)
  eq(tmp, events[1].file_path)

  diff.close_all("test cleanup")
  vim.api.nvim_del_augroup_by_id(group)
end)

test("accept sends apply_change and closes the view", function()
  capture()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("original\n")
  f:close()

  eq(true, diff.open(file_change_msg("d2", tmp, "original\n", "updated\n")))
  eq(1, diff.pending_count())

  eq(true, diff.accept("d2"))
  eq(0, diff.pending_count())
  eq(1, count_type("apply_change"))
  eq("d2", first_type("apply_change").id)
  eq(0, count_type("reject_change"))
end)

test("deny sends reject_change and closes the view", function()
  capture()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("original\n")
  f:close()

  diff.open(file_change_msg("d3", tmp, "original\n", "updated\n"))
  eq(true, diff.deny("d3"))
  eq(0, diff.pending_count())
  eq(1, count_type("reject_change"))
  eq(0, count_type("apply_change"))
end)

test("accept twice is a no-op the second time", function()
  capture()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("a\n")
  f:close()

  diff.open(file_change_msg("d4", tmp, "a\n", "b\n"))
  eq(true, diff.accept("d4"))
  eq(false, diff.accept("d4"))
  eq(1, count_type("apply_change"))
end)

test("close_all closes every pending diff without a change message", function()
  capture()
  for i = 1, 3 do
    local tmp = vim.fn.tempname() .. ".lua"
    local f = io.open(tmp, "w")
    f:write("x\n")
    f:close()
    diff.open(file_change_msg("c" .. i, tmp, "x\n", "y\n"))
  end
  eq(3, diff.pending_count())
  eq(3, diff.close_all("closed by test"))
  eq(0, diff.pending_count())
  eq(0, count_type("apply_change"))
  eq(0, count_type("reject_change"))
end)

test("close_diff message from the CLI closes the view", function()
  capture()
  config.setup({})
  diff.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("a\n")
  f:close()

  diff.open(file_change_msg("d5", tmp, "a\n", "b\n"))
  eq(1, diff.pending_count())
  client._receive_raw(vim.json.encode({ type = "close_diff", id = "d5" }))
  eq(0, diff.pending_count())
  eq(0, count_type("apply_change"))
  eq(0, count_type("reject_change"))
end)

test("new file case: empty original content marks is_new_file", function()
  capture()
  local tmp = vim.fn.tempname() .. ".lua"
  local events = {}
  local group = vim.api.nvim_create_augroup("nanocoder_test_newfile", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NanocoderDiffOpened",
    callback = function(ev)
      events[#events + 1] = ev.data
    end,
  })

  diff.open(file_change_msg("d6", tmp, "", "local fresh = true\n"))
  eq(1, #events)
  eq(true, events[1].is_new_file)
  diff.close_all("test cleanup")
  vim.api.nvim_del_augroup_by_id(group)
end)

test("a new proposal for the same file replaces the old one", function()
  capture()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("v1\n")
  f:close()

  diff.open(file_change_msg("d7", tmp, "v1\n", "v2\n"))
  eq(1, diff.pending_count())
  diff.open(file_change_msg("d8", tmp, "v1\n", "v3\n"))
  eq(1, diff.pending_count())
  ok(diff._pending.d8, "the newer proposal should be pending")
  eq(nil, diff._pending.d7, "the older proposal should be closed")
  diff.close_all("test cleanup")
end)

test("NanocoderDiffOpened event carries the expected fields", function()
  capture()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("a\n")
  f:close()

  local opened, closed
  local group = vim.api.nvim_create_augroup("nanocoder_test_fields", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NanocoderDiffOpened",
    callback = function(ev)
      opened = ev.data
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NanocoderDiffClosed",
    callback = function(ev)
      closed = ev.data
    end,
  })

  diff.open(file_change_msg("d9", tmp, "a\n", "b\n"))
  ok(opened, "opened event should fire")
  ok(diff._pending.d9, "d9 should be pending")
  eq(tmp, opened.file_path, "file_path should be set")
  ok(opened.tab_name ~= nil, "tab_name should be set")
  eq(nil, opened.reason, "opened event has no reason")

  diff.accept("d9")
  ok(closed, "closed event should fire")
  eq("diff accepted", closed.reason)

  vim.api.nvim_del_augroup_by_id(group)
end)

test("file_change routed through dispatch opens a diff", function()
  capture()
  config.setup({})
  diff.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("a\n")
  f:close()

  local before = diff.pending_count()
  client._receive_raw(vim.json.encode(file_change_msg("d10", tmp, "a\n", "b\n")))
  eq(before + 1, diff.pending_count())
  diff.close_all("test cleanup")
end)

test("many sequential diffs do not accumulate diff-mode buffers (E96 guard)", function()
  capture()
  config.setup({})
  diff.setup()
  for i = 1, 10 do
    local tmp = vim.fn.tempname() .. ".lua"
    local f = io.open(tmp, "w")
    f:write("a\n")
    f:close()
    diff.open(file_change_msg("e" .. i, tmp, "a\n", "b\n"))
    diff.accept("e" .. i)
  end
  eq(0, diff.pending_count())
  eq(10, count_type("apply_change"))
end)

test("accept/deny does not leave buffers behind (buffer growth guard)", function()
  capture()
  config.setup({})
  diff.setup()
  local before = #vim.api.nvim_list_bufs()
  for i = 1, 5 do
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a" }, tmp)
    diff.open(file_change_msg("g" .. i, tmp, "a\n", "b\n"))
    if i % 2 == 0 then
      diff.accept("g" .. i)
    else
      diff.deny("g" .. i)
    end
  end
  -- Both sides (the :edit-ed file buffer and the "(proposed)" scratch) must
  -- be wiped; each cycle used to leak one file buffer.
  eq(before, #vim.api.nvim_list_bufs())
end)

test("a buffer the user already had open survives diff cleanup", function()
  capture()
  config.setup({})
  diff.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local user_buf = vim.api.nvim_get_current_buf()

  diff.open(file_change_msg("h1", tmp, "a\n", "b\n"))
  eq(true, diff.deny("h1"))
  eq(true, vim.api.nvim_buf_is_valid(user_buf), "the user's buffer must survive")
end)

test("a diff round-trip must not resize the terminal window", function()
  capture()
  config.setup({})
  diff.setup()
  local terminal = require("nanocoder.terminal")
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  vim.cmd("only")
  eq(true, terminal.open(false))
  local term_win = vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(term_win)

  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  eq(true, diff.open(file_change_msg("r1", tmp, "a\n", "b\n")))
  eq(width, vim.api.nvim_win_get_width(term_win), "opening a diff must not resize the terminal")
  eq(true, diff.deny("r1"))
  eq(width, vim.api.nvim_win_get_width(term_win), "denying a diff must not resize the terminal")

  terminal.stop_job()
end)

test("file_change while the terminal is focused never replaces the terminal buffer", function()
  capture()
  config.setup({})
  diff.setup()
  local terminal = require("nanocoder.terminal")

  -- Fake the nanocoder terminal: a scratch buffer in its own window, which is
  -- the current (focused) window — the state when the CLI proposes a change.
  local term_buf = vim.api.nvim_create_buf(false, true)
  local term_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(term_win, term_buf)
  local orig_get_bufnr = terminal.get_bufnr
  terminal.get_bufnr = function()
    return term_buf
  end

  local tmp = vim.fn.tempname() .. ".lua"
  local f = io.open(tmp, "w")
  f:write("a\n")
  f:close()

  eq(true, diff.open(file_change_msg("t1", tmp, "a\n", "b\n")))

  -- The terminal window still shows the terminal buffer; the diff opened
  -- elsewhere. Without the fix, :edit ran in the terminal window and the
  -- terminal buffer vanished from every window.
  eq(term_buf, vim.api.nvim_win_get_buf(term_win))
  eq(true, vim.api.nvim_buf_is_valid(term_buf))
  local entry = diff._pending.t1
  ok(entry, "t1 should be pending")
  ok(entry.left_win ~= term_win, "the diff must not use the terminal window")
  -- entry.bufnr is the proposed scratch buffer ("<path> (proposed)" by design,
  -- else its name would collide with the file buffer); the file is left_bufnr.
  eq(tmp, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(entry.left_bufnr), ":p"))

  terminal.get_bufnr = orig_get_bufnr
  diff.close_all("test cleanup")
  pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
end)
