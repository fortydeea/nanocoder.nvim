-- User commands. Full set is registered in setup(); lazy.nvim `cmd` triggers
-- work because the commands exist after setup() runs.
local log = require("nanocoder.log")

local M = {}

---Create a user command once (re-running setup() must not error).
---@param name string
---@param fn function
---@param opts table|nil
local function create(name, fn, opts)
  opts = opts or {}
  opts.force = true
  vim.api.nvim_create_user_command(name, fn, opts)
end

---Wire up all user commands. Idempotent.
function M.setup()
  local nanocoder = require("nanocoder")
  local terminal = require("nanocoder.terminal")

  -- Toggle / focus / lifecycle -------------------------------------------

  create("Nanocoder", function()
    terminal.toggle()
  end, { desc = "Toggle the nanocoder terminal" })

  create("NanocoderFocus", function()
    if not terminal.focus() then
      nanocoder.start()
    end
  end, { desc = "Focus the nanocoder terminal (opens when closed)" })

  create("NanocoderStart", function()
    nanocoder.start()
  end, { desc = "Start the nanocoder terminal and companion connection" })

  create("NanocoderStop", function()
    nanocoder.stop()
  end, { desc = "Stop the companion connection and terminal job" })

  create("NanocoderOpen", function()
    nanocoder.open()
  end, { desc = "Open the nanocoder terminal window" })

  create("NanocoderClose", function()
    nanocoder.close()
  end, { desc = "Close the nanocoder terminal window" })

  create("NanocoderStatus", function()
    local status = nanocoder.status()
    local parts = {
      "connected: " .. tostring(status.connected),
      "provider: " .. tostring(status.terminal_provider),
      "terminal: " .. (status.terminal_open and "open" or "closed"),
    }
    if status.port then
      parts[#parts + 1] = "port: " .. tostring(status.port)
    end
    if status.cli_version then
      parts[#parts + 1] = "cli: " .. tostring(status.cli_version)
    end
    if status.model then
      parts[#parts + 1] = "model: " .. tostring(status.model)
    end
    log.info("status — " .. table.concat(parts, ", "))
    vim.notify("[nanocoder] " .. table.concat(parts, ", "))
  end, { desc = "Show nanocoder companion status" })

  -- Context / sending -----------------------------------------------

  create("NanocoderSend", function(args)
    local context = require("nanocoder.context")
    if args.range > 0 then
      context.send_selection()
    else
      local prompt = vim.fn.input("Nanocoder prompt: ")
      if prompt ~= "" then
        context.send_prompt(prompt)
      end
    end
  end, { desc = "Send the visual selection (or a prompted message) to nanocoder", range = true })

  create("NanocoderSendText", function(args)
    local text = args.args
    if text == "" then
      log.warn("NanocoderSendText: no text given")
      return
    end
    local submit = not args.bang
    if not terminal.send_text(text, submit) then
      log.warn("NanocoderSendText: no terminal pane available (provider " .. terminal.get_provider_name() .. ")")
    end
  end, { desc = "Type text into the nanocoder terminal (! to insert without submitting)", nargs = "+", bang = true })

  create("NanocoderAdd", function(args)
    local context = require("nanocoder.context")
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" then
      log.warn("NanocoderAdd: buffer has no file name")
      return
    end
    local start_line, end_line
    if args.range > 0 then
      start_line = args.line1 - 1
      end_line = args.line2 - 1
    end
    context.add_file(path, start_line, end_line)
  end, { desc = "Add the current file (with optional range) to nanocoder's context", range = true })

  create("NanocoderTreeAdd", function()
    local context = require("nanocoder.context")
    local line = vim.api.nvim_get_current_line()
    local path = context.path_from_tree_line(line)
    if not path then
      log.warn("NanocoderTreeAdd: could not find a file path on the current line")
      return
    end
    context.add_file(path)
  end, { desc = "Add the file under the cursor in a file tree to nanocoder's context" })

  create("NanocoderSelectModel", function()
    vim.ui.input({ prompt = "provider (empty for default): " }, function(provider)
      vim.ui.input({ prompt = "model (empty for default): " }, function(model)
        local argv = { "nanocoder", "--vscode" }
        if provider and provider ~= "" then
          argv[#argv + 1] = "--provider"
          argv[#argv + 1] = provider
        end
        if model and model ~= "" then
          argv[#argv + 1] = "--model"
          argv[#argv + 1] = model
        end
        terminal.set_cli_argv(argv)
        log.info("relaunching with: " .. table.concat(argv, " "))
        nanocoder.stop()
        nanocoder.start()
      end)
    end)
  end, { desc = "Choose provider/model and relaunch the nanocoder terminal" })

  log.debug("commands registered")

  -- Diff review -----------------------------------------------------

  create("NanocoderDiffAccept", function()
    local diff = require("nanocoder.diff")
    local buf = vim.api.nvim_get_current_buf()
    local entry = diff._entry_for_buf(buf)
    if entry then
      diff.accept(entry.id)
    elseif diff.pending_count() == 1 then
      diff.accept_all()
    else
      log.warn("NanocoderDiffAccept: no diff under the cursor (pending: " .. diff.pending_count() .. ")")
    end
  end, { desc = "Accept the nanocoder diff under the cursor (or the only pending diff)" })

  create("NanocoderDiffDeny", function()
    local diff = require("nanocoder.diff")
    local buf = vim.api.nvim_get_current_buf()
    local entry = diff._entry_for_buf(buf)
    if entry then
      diff.deny(entry.id)
    elseif diff.pending_count() == 1 then
      diff.deny_all()
    else
      log.warn("NanocoderDiffDeny: no diff under the cursor (pending: " .. diff.pending_count() .. ")")
    end
  end, { desc = "Reject the nanocoder diff under the cursor (or the only pending diff)" })

  create("NanocoderCloseAllDiffs", function()
    local count = require("nanocoder.diff").close_all("closed by user")
    log.info("closed " .. count .. " pending diff(s)")
  end, { desc = "Close all pending nanocoder diffs without accepting" })
end

return M
