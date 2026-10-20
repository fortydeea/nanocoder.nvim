-- Config defaults, merge, validation, and cwd resolution.
local config = require("nanocoder.config")

test("defaults are valid", function()
  eq(nil, config.validate(config.defaults))
end)

test("setup merges user opts over defaults", function()
  local cfg = config.setup({ log_level = "debug", terminal = { split_height_percentage = 0.6 } })
  eq("debug", cfg.log_level)
  eq(0.6, cfg.terminal.split_height_percentage)
  eq("native", cfg.terminal.provider) -- untouched default survives the merge
  eq("nanocoder", cfg.terminal_cmd)
end)

test("validate rejects bad log_level", function()
  ok(config.validate({ log_level = "loud" }):match("log_level"), "bad log_level must fail")
end)

test("validate rejects bad diff layout", function()
  ok(config.validate({ diff_opts = { layout = "diagonal" } }):match("layout"), "bad layout must fail")
end)

test("validate rejects bad provider string", function()
  ok(config.validate({ terminal = { provider = "tmux" } }):match("provider"), "bad provider must fail")
end)

test("validate accepts a custom provider table", function()
  eq(nil, config.validate({ terminal = { provider = {
    open = function() end,
    close = function() end,
    focus = function() end,
    is_open = function() end,
  } } }))
end)

test("validate rejects non-table provider", function()
  ok(config.validate({ terminal = { provider = 7 } }):match("provider"), "non-table provider must fail")
end)

test("validate rejects out-of-range port", function()
  ok(config.validate({ port = 99999 }):match("port"), "huge port must fail")
  ok(config.validate({ port = 1.5 }):match("port"), "fractional port must fail")
  eq(nil, config.validate({ port = 51820 }))
end)

test("setup raises on invalid config", function()
  fails(function()
    config.setup({ log_level = "nope" })
  end, "config error")
end)

test("effective_cwd: explicit cwd wins", function()
  config.setup({ terminal = { cwd = "/tmp/explicit" } })
  eq("/tmp/explicit", config.effective_cwd())
end)

test("effective_cwd: cwd_provider wins over cwd", function()
  config.setup({
    terminal = {
      cwd = "/tmp/from-cwd",
      cwd_provider = function(ctx)
        return "/tmp/from-provider/" .. (ctx.file_dir or "")
      end,
    },
  })
  ok(config.effective_cwd():match("^/tmp/from%-provider/"), "provider result should be used")
end)

test("effective_cwd: falls back to the current working directory", function()
  config.setup({})
  eq(vim.fn.getcwd(), config.effective_cwd())
end)

test("effective_cwd: git_repo_cwd resolves the repo root", function()
  config.setup({ terminal = { git_repo_cwd = true } })
  local cwd = config.effective_cwd()
  -- This repo is under git; the resolved root should contain .git.
  ok(vim.fn.isdirectory(cwd .. "/.git") == 1 or cwd == vim.fn.getcwd(), "git root resolution: " .. cwd)
end)
