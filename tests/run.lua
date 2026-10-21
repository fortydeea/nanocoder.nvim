-- Minimal assert-based test runner for dev use and CI.
-- Run headlessly:  nvim --headless -c "luafile tests/run.lua" -c "qa!"
-- No dependencies; compatible with Neovim 0.8+.

local tests = {}
local failures = {}
local current_file = "?"

---Register a test case.
---@param name string
---@param fn function
function _G.test(name, fn)
  tests[#tests + 1] = { file = current_file, name = name, fn = fn }
end

function _G.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      string.format(
        "%sexpected %s, got %s",
        msg and (msg .. ": ") or "",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function _G.ok(value, msg)
  if not value then
    error((msg or "expected truthy value") .. " (got " .. vim.inspect(value) .. ")", 2)
  end
end

function _G.fails(fn, needle, msg)
  local success, err = pcall(fn)
  if success then
    error((msg or "expected error") .. ", but call succeeded", 2)
  end
  if needle and not tostring(err):match(needle, 1, true) then
    error("error did not contain '" .. needle .. "': " .. tostring(err), 2)
  end
end

-- Make plugin modules requireable from the repo root.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local files = {
  "tests/test_sha1.lua",
  "tests/test_base64.lua",
  "tests/test_websocket.lua",
  "tests/test_discovery.lua",
  "tests/test_protocol.lua",
  "tests/test_config.lua",
  "tests/test_terminal.lua",
  "tests/test_setup.lua",
  "tests/test_context.lua",
  "tests/test_handlers.lua",
  "tests/test_diff.lua",
  "tests/test_health.lua",
  "tests/test_log.lua",
}

for _, file in ipairs(files) do
  current_file = file
  local chunk, err = loadfile(root .. "/" .. file)
  if not chunk then
    error("failed to load " .. file .. ": " .. tostring(err))
  end
  chunk()
end

for _, t in ipairs(tests) do
  local success, err = pcall(t.fn)
  if success then
    io.write("PASS  " .. t.file .. " :: " .. t.name .. "\n")
  else
    failures[#failures + 1] = { t = t, err = err }
    io.write("FAIL  " .. t.file .. " :: " .. t.name .. "\n      " .. tostring(err) .. "\n")
  end
end

io.write(string.format("\n%d passed, %d failed\n", #tests - #failures, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
end
