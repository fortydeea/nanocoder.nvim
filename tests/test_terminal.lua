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
