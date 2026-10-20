-- Discovery file parsing and stale-detection rules.
local discovery = require("nanocoder.discovery")

local function json(tbl)
  return vim.json.encode(tbl)
end

test("parse: valid file", function()
  local info, err = discovery.parse(
    json({ version = 1, port = 51820, token = "aabb", pid = 12345, cliVersion = "1.2.3", startedAt = 42 }),
    { alive_fn = function()
      return true
    end }
  )
  eq(nil, err)
  eq(51820, info.port)
  eq("aabb", info.token)
  eq(12345, info.pid)
  eq("1.2.3", info.cliVersion)
  eq(42, info.startedAt)
end)

test("parse: corrupt JSON", function()
  local info, err = discovery.parse("{not json", { alive_fn = function()
    return true
  end })
  eq(nil, info)
  ok(err:match("corrupt"), err)
end)

test("parse: wrong shape (missing token)", function()
  local info, err = discovery.parse(
    json({ version = 1, port = 51820, pid = 1 }),
    { alive_fn = function()
      return true
    end }
  )
  eq(nil, info)
  ok(err:match("invalid shape"), err)
end)

test("parse: wrong shape (port not a number)", function()
  local info, err = discovery.parse(
    json({ version = 1, port = "51820", token = "x", pid = 1 }),
    { alive_fn = function()
      return true
    end }
  )
  eq(nil, info)
  ok(err:match("invalid shape"), err)
end)

test("parse: refuses newer schema version", function()
  local info, err = discovery.parse(
    json({ version = 2, port = 51820, token = "x", pid = 1 }),
    { alive_fn = function()
      return true
    end }
  )
  eq(nil, info)
  ok(err:match("newer than supported"), err)
end)

test("parse: older schema version still readable", function()
  local info = discovery.parse(
    json({ port = 51820, token = "x", pid = 1 }),
    { alive_fn = function()
      return true
    end }
  )
  eq(1, info.version)
end)

test("parse: stale pid is rejected", function()
  local info, err = discovery.parse(
    json({ version = 1, port = 51820, token = "x", pid = 999 }),
    { alive_fn = function()
      return false
    end }
  )
  eq(nil, info)
  ok(err:match("stale"), err)
end)

test("is_process_alive: invalid pids are dead", function()
  eq(false, discovery.is_process_alive(-1))
  eq(false, discovery.is_process_alive(0))
  eq(false, discovery.is_process_alive(1.5))
  eq(false, discovery.is_process_alive("nope"))
end)

test("is_process_alive: current process is alive", function()
  eq(true, discovery.is_process_alive(vim.fn.getpid()))
end)

test("is_process_alive: huge pid is dead", function()
  eq(false, discovery.is_process_alive(4194304 + 9999))
end)

test("discovery_path respects NANOCODER_CONFIG_DIR override", function()
  eq("/tmp/custom/nanocoder/vscode-server.json", discovery.discovery_path("/tmp/custom/nanocoder"))
end)

test("resolve: explicit port+token wins over the discovery file", function()
  local info, err = discovery.resolve({ port = 59999, token = "manual-token" })
  eq(nil, err)
  eq(59999, info.port)
  eq("manual-token", info.token)
  eq("manual", info.cliVersion)
end)

test("resolve: falls back to the discovery file", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/vscode-server.json"
  local f = io.open(path, "w")
  f:write(json({ version = 1, port = 51821, token = "t", pid = vim.fn.getpid(), cliVersion = "9.9.9" }))
  f:close()
  local info, err = discovery.resolve({ discovery_path = path })
  eq(nil, err)
  eq(51821, info.port)
  eq("t", info.token)
end)

test("resolve: missing discovery file reports not-found", function()
  local info, err = discovery.resolve({ discovery_path = "/nonexistent/vscode-server.json" })
  eq(nil, info)
  ok(err:match("not found"), err)
end)
