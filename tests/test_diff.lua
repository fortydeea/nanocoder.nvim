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

test("a sidebar window (neo-tree style) is never hijacked by the diff", function()
  capture()
  config.setup({})
  diff.setup()

  -- Sidebar: a nofile buffer in its own window, and it is focused — the state
  -- when the CLI proposes a change while the user is in neo-tree.
  local side_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[side_buf].buftype = "nofile"
  vim.api.nvim_buf_set_name(side_buf, "neo-tree filesystem [1]")
  local side_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(side_win, side_buf)

  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  eq(true, diff.open(file_change_msg("s1", tmp, "a\n", "b\n")))

  eq(side_buf, vim.api.nvim_win_get_buf(side_win), "the sidebar window must keep its buffer")
  local entry = diff._pending.s1
  ok(entry, "s1 should be pending")
  ok(entry.left_win ~= side_win, "the diff must not use the sidebar window")

  diff.close_all("test cleanup")
  pcall(vim.api.nvim_buf_delete, side_buf, { force = true })
end)

test("with the terminal focused, a sidebar is skipped in favor of a file window", function()
  capture()
  config.setup({})
  diff.setup()
  local terminal = require("nanocoder.terminal")

  -- Layout: terminal (focused) + sidebar (the alternate window) + a plain
  -- file window. The old usable() accepted the sidebar and hijacked it.
  local side_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[side_buf].buftype = "nofile"
  vim.api.nvim_buf_set_name(side_buf, "neo-tree filesystem [1]")
  local side_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(side_win, side_buf)

  local file_tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "f" }, file_tmp)
  vim.cmd("split " .. vim.fn.fnameescape(file_tmp))
  local file_win = vim.api.nvim_get_current_win()

  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.cmd("split")
  local term_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(term_win, term_buf)
  local orig_get_bufnr = terminal.get_bufnr
  terminal.get_bufnr = function()
    return term_buf
  end

  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  eq(true, diff.open(file_change_msg("s2", tmp, "a\n", "b\n")))

  eq(term_buf, vim.api.nvim_win_get_buf(term_win), "the terminal buffer must survive")
  eq(side_buf, vim.api.nvim_win_get_buf(side_win), "the sidebar window must keep its buffer")
  eq(file_win, diff._pending.s2.left_win, "the diff must use the file window")

  terminal.get_bufnr = orig_get_bufnr
  diff.close_all("test cleanup")
  pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
  pcall(vim.api.nvim_buf_delete, side_buf, { force = true })
end)

test("a dirty buffer prompts and Save writes it before the diff opens", function()
  capture()
  config.setup({})
  diff.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local user_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "dirty" })
  local asked = 0
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    asked = asked + 1
    return 1 -- &Save
  end

  eq(true, diff.open(file_change_msg("p1", tmp, "a\n", "b\n")))
  vim.fn.confirm = orig_confirm

  eq(1, asked, "the buffer's unsaved changes must prompt")
  eq(false, vim.bo[user_buf].modified, "Save must write the buffer")
  eq({ "dirty" }, vim.fn.readfile(tmp), "the buffer content must reach the disk")
  eq(1, diff.pending_count(), "the diff must be open")

  diff.close_all("test cleanup")
end)

test("a dirty buffer and Show unsaved keeps the edits and still opens the diff", function()
  capture()
  config.setup({})
  diff.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local user_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "dirty" })
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 2 -- Show &unsaved
  end

  -- Regression: a bare :edit on the modified buffer failed with E37 and the
  -- diff silently never opened. Reusing the buffer must open it anyway.
  eq(true, diff.open(file_change_msg("p2", tmp, "a\n", "b\n")))
  vim.fn.confirm = orig_confirm

  eq(true, vim.bo[user_buf].modified, "unsaved edits must survive")
  eq({ "a" }, vim.fn.readfile(tmp), "the buffer must not be written")
  eq(user_buf, diff._pending.p2.left_bufnr, "the diff must show the user's buffer")

  diff.deny("p2")
  eq(true, vim.api.nvim_buf_is_valid(user_buf), "the user's buffer must survive")
end)

test("a dirty buffer and Cancel rejects the change and opens nothing", function()
  capture()
  config.setup({})
  diff.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local user_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "dirty" })
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 3 -- &Cancel
  end

  eq(false, diff.open(file_change_msg("p3", tmp, "a\n", "b\n")))
  vim.fn.confirm = orig_confirm

  eq(0, diff.pending_count(), "no diff must open")
  eq(1, count_type("reject_change"), "the change must be rejected")
  eq("p3", first_type("reject_change").id)
  eq(true, vim.bo[user_buf].modified, "the buffer must stay untouched")

  pcall(vim.api.nvim_buf_delete, user_buf, { force = true })
end)

test("a clean buffer opens the diff without prompting", function()
  capture()
  config.setup({})
  diff.setup()
  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "a" }, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    error("confirm must not be called for a clean buffer")
  end

  eq(true, diff.open(file_change_msg("p4", tmp, "a\n", "b\n")))
  vim.fn.confirm = orig_confirm

  eq(1, diff.pending_count())
  diff.deny("p4")
end)
