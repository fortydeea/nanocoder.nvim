-- Logging must never touch the UI from a fast event (uv callbacks).
test("log.warn from a fast event does not raise", function()
  local log = require("nanocoder.log")
  local errmsg = nil
  local done = false
  local timer = vim.uv and vim.uv.new_timer() or vim.loop.new_timer()
  timer:start(0, 0, function()
    -- This callback runs in a fast event context.
    local ok, err = pcall(log.warn, "fast event probe")
    errmsg = ok and "" or tostring(err)
    done = true
  end)
  vim.wait(500, function()
    return done
  end)
  timer:stop()
  timer:close()
  eq(true, done, "timer callback should have run")
  eq("", errmsg, "log.warn must not raise in a fast event")
end)
