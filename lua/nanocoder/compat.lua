-- Neovim 0.8+ compatibility helpers. Zero dependencies.
local M = {}

---The libuv binding table (vim.uv on 0.10+, vim.loop earlier).
M.uv = vim.uv or vim.loop

---Encode binary string to base64. Uses vim.base64 when available (0.10+),
---falls back to the vendored pure-Lua implementation.
---@param data string raw bytes
---@return string
function M.base64_encode(data)
  if vim.base64 and vim.base64.encode then
    return vim.base64.encode(data)
  end
  return require("nanocoder.base64").encode(data)
end

---Decode base64 string to binary. Uses vim.base64 when available (0.10+).
---@param data string
---@return string|nil decoded, string|nil err
function M.base64_decode(data)
  if vim.base64 and vim.base64.decode then
    return vim.base64.decode(data)
  end
  return require("nanocoder.base64").decode(data)
end

---vim.json.decode (0.7+) with a table fallback for very old builds.
---@param s string
---@return any
function M.json_decode(s)
  return vim.json.decode(s)
end

---True when t is a sequential list table (JSON array shape).
---@param t table
---@return boolean
function M.is_list(t)
  if vim.islist then
    return vim.islist(t)
  end
  return vim.tbl_islist(t) -- 0.8/0.9
end

---vim.json.encode with a table fallback for very old builds.
---@param t any
---@return string
function M.json_encode(t)
  return vim.json.encode(t)
end

return M
