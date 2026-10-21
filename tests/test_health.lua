-- Health check smoke tests: the module must load and run without error.
local config = require("nanocoder.config")

---Run fn with every health report API stubbed (0.8 report_* and 0.10+ ok/...).
---Returns ok, err, and the captured report messages ("key: msg").
local function capture_reports(fn)
  local ht = vim.health or require("health")
  local keys = { "start", "ok", "warn", "error", "info",
    "report_start", "report_ok", "report_warn", "report_error", "report_info" }
  local captured, orig = {}, {}
  for _, k in ipairs(keys) do
    orig[k] = ht[k]
    ht[k] = function(msg) captured[#captured + 1] = k .. ": " .. tostring(msg) end
  end
  local ok, err = pcall(fn)
  for _, k in ipairs(keys) do
    ht[k] = orig[k]
  end
  return ok, err, captured
end

test("checkhealth nanocoder runs the health check", function()
  -- :checkhealth is the real entry point on every Neovim version (0.8.3's
  -- report_* need state that only its run loop initializes).
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local ok, err, captured = capture_reports(function()
    vim.cmd("checkhealth nanocoder")
  end)
  eq(true, ok, "checkhealth raised: " .. tostring(err))
  -- Our check() reports its section first; the framework's "healthcheck not
  -- found" fallback also names nanocoder, but never as a bare section start.
  local ours = false
  for _, m in ipairs(captured) do
    if m == "start: nanocoder" or m == "report_start: nanocoder" then ours = true end
  end
  _G.ok(ours, "health check should report its own section: " .. vim.inspect(captured))
end)

test("checkhealth reports a missing CLI instead of raising", function()
  local health = require("nanocoder.health")
  config.setup({ terminal_cmd = "/nonexistent/nanocoder" })
  local ok, err, captured = capture_reports(health.check)
  config.setup({})
  eq(true, ok, "health check raised: " .. tostring(err))
  local saw = false
  for _, m in ipairs(captured) do
    if m:match("is not runnable", 1, true) then saw = true end
  end
  _G.ok(saw, "missing CLI should report 'is not runnable': " .. vim.inspect(captured))
end)
