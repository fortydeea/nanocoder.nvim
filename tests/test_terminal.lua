-- Terminal provider argv building and dispatch.
local config = require("nanocoder.config")
local terminal = require("nanocoder.terminal")

test("build_cli_argv: nanocoder --vscode by default", function()
  config.setup({})
  eq({ "nanocoder", "--vscode" }, terminal.build_cli_argv())
end)

test("build_cli_argv: honors terminal_cmd", function()
  config.setup({ terminal_cmd = "/opt/nanocoder/bin/nanocoder" })
  eq({ "/opt/nanocoder/bin/nanocoder", "--vscode" }, terminal.build_cli_argv())
end)

test("setup selects the native provider by default", function()
  config.setup({})
  terminal.setup(config.get())
  eq("native", terminal.get_provider_name())
end)

test("setup selects the none provider when configured", function()
  config.setup({ terminal = { provider = "none" } })
  terminal.setup(config.get())
  eq("none", terminal.get_provider_name())
end)

test("external provider without config falls back to native", function()
  config.setup({ terminal = { provider = "external" } })
  terminal.setup(config.get())
  eq("native", terminal.get_provider_name())
end)

test("external provider is kept when configured", function()
  config.setup({
    terminal = {
      provider = "external",
      provider_opts = { external_terminal_cmd = "alacritty -e %s" },
    },
  })
  terminal.setup(config.get())
  eq("external", terminal.get_provider_name())
end)

test("custom provider table is accepted", function()
  local calls = {}
  config.setup({
    terminal = {
      provider = {
        open = function()
          calls.open = true
          return true
        end,
        close = function() end,
        focus = function()
          return false
        end,
        is_open = function()
          return false
        end,
        send_text = function()
          return false
        end,
      },
    },
  })
  terminal.setup(config.get())
  eq("custom", terminal.get_provider_name())
  eq(true, terminal.open())
  eq(true, calls.open)
end)

test("native provider opens a real terminal and sends text", function()
  config.setup({})
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  eq(false, terminal.is_open())
  eq(true, terminal.open(false))
  eq(true, terminal.is_open())
  eq(true, terminal.is_running())

  local bufnr = terminal.get_bufnr()
  ok(bufnr and vim.api.nvim_buf_is_valid(bufnr), "terminal buffer should exist")

  eq(true, terminal.send_text("echo hello", true))
  eq(true, terminal.send_text("no submit", false))

  terminal.close()
  eq(false, terminal.is_open())

  terminal.stop_job()
  eq(false, terminal.is_running())
end)

test("native provider defaults to a right-side vertical split", function()
  config.setup({})
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  local cols = vim.o.columns
  eq(true, terminal.open(false))
  local win = vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(win)
  _G.ok(width < cols, "split should be narrower than the full editor: " .. width .. "/" .. cols)
  _G.ok(vim.api.nvim_win_get_height(win) >= vim.o.lines - 4, "vertical split should be full height")
  terminal.close()
  terminal.stop_job()
end)

test("vertical split defaults to 40 columns", function()
  config.setup({})
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  eq(40, config.get().terminal.split_width)
  vim.cmd("only")
  eq(true, terminal.open(false))
  local win = vim.api.nvim_get_current_win()
  eq(40, vim.api.nvim_win_get_width(win), "default vertical split should be 40 columns wide")
  terminal.close()
  terminal.stop_job()
end)

test("split_width_percentage overrides the fixed column width", function()
  config.setup({ terminal = { split_width_percentage = 0.5 } })
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  local cols = vim.o.columns
  vim.cmd("only")
  eq(true, terminal.open(false))
  local win = vim.api.nvim_get_current_win()
  eq(math.floor(cols * 0.5), vim.api.nvim_win_get_width(win))
  terminal.close()
  terminal.stop_job()
  config.setup({})
end)

test("stop_job closes the terminal window and wipes its buffer", function()
  config.setup({})
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  local before = vim.api.nvim_tabpage_list_wins(0)
  eq(true, terminal.open(false))
  local bufnr = terminal.get_bufnr()
  eq(#before + 1, #vim.api.nvim_tabpage_list_wins(0), "open() should add exactly one window")

  terminal.stop_job()
  eq(false, terminal.is_running())
  eq(false, terminal.is_open())
  eq(#before, #vim.api.nvim_tabpage_list_wins(0), "stop_job() should close the terminal window")
  ok(not (bufnr and vim.api.nvim_buf_is_valid(bufnr)), "stop_job() should wipe the dead terminal buffer")
end)

test("relaunch reuses one split and one running job", function()
  config.setup({})
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  -- Simulate :NanocoderSelectModel: stop the old CLI, then start a new one.
  local before = vim.api.nvim_tabpage_list_wins(0)
  eq(true, terminal.open(false))
  terminal.stop_job()
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })
  eq(true, terminal.open(false))

  eq(#before + 1, #vim.api.nvim_tabpage_list_wins(0), "relaunch must not stack a second split")
  eq(true, terminal.is_running())
  terminal.close()
  terminal.stop_job()
end)

test("open() after close() reattaches to the running job instead of respawning", function()
  config.setup({})
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  eq(true, terminal.open(false))
  local bufnr = terminal.get_bufnr()
  terminal.close()
  eq(true, terminal.open(false))
  eq(bufnr, terminal.get_bufnr(), "reopen should reuse the live terminal buffer, not respawn the CLI")
  eq(true, terminal.is_running())
  terminal.stop_job()
end)

test("native provider honors split_direction = botright (horizontal)", function()
  config.setup({ terminal = { split_direction = "botright", split_height_percentage = 0.4 } })
  terminal.setup(config.get())
  terminal.set_cli_argv({ "sh", "-c", "while true; do sleep 1; done" })

  local lines = vim.o.lines
  eq(true, terminal.open(false))
  local win = vim.api.nvim_get_current_win()
  local height = vim.api.nvim_win_get_height(win)
  _G.ok(height < lines, "split should be shorter than the full editor: " .. height .. "/" .. lines)
  terminal.close()
  terminal.stop_job()
  config.setup({})
end)
