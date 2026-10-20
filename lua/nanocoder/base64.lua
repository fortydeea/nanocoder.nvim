-- Pure-Lua base64 (RFC 4648). Vendored so Neovim 0.8/0.9 work without vim.base64.
local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local REVERSE = {}
for i = 1, #ALPHABET do
  REVERSE[ALPHABET:sub(i, i)] = i - 1
end

---Encode raw bytes to base64.
---@param data string raw bytes
---@return string
function M.encode(data)
  local out = {}
  local n = #data
  local i = 1
  while i + 2 <= n do
    local a, b, c = data:byte(i, i + 2)
    local n1 = a * 65536 + b * 256 + c
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 262144) % 64 + 1, math.floor(n1 / 262144) % 64 + 1)
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 4096) % 64 + 1, math.floor(n1 / 4096) % 64 + 1)
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 64) % 64 + 1, math.floor(n1 / 64) % 64 + 1)
    out[#out + 1] = ALPHABET:sub(n1 % 64 + 1, n1 % 64 + 1)
    i = i + 3
  end
  local rem = n - i + 1
  if rem == 1 then
    local a = data:byte(i)
    local n1 = a * 65536
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 262144) % 64 + 1, math.floor(n1 / 262144) % 64 + 1)
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 4096) % 64 + 1, math.floor(n1 / 4096) % 64 + 1)
    out[#out + 1] = "="
    out[#out + 1] = "="
  elseif rem == 2 then
    local a, b = data:byte(i, i + 1)
    local n1 = a * 65536 + b * 256
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 262144) % 64 + 1, math.floor(n1 / 262144) % 64 + 1)
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 4096) % 64 + 1, math.floor(n1 / 4096) % 64 + 1)
    out[#out + 1] = ALPHABET:sub(math.floor(n1 / 64) % 64 + 1, math.floor(n1 / 64) % 64 + 1)
    out[#out + 1] = "="
  end
  return table.concat(out)
end

---Decode base64 to raw bytes.
---@param data string
---@return string|nil decoded, string|nil err
function M.decode(data)
  data = data:gsub("%s", "")
  if #data % 4 ~= 0 then
    return nil, "invalid base64 length"
  end
  local out = {}
  local i = 1
  while i <= #data do
    local c1, c2, c3, c4 = data:sub(i, i), data:sub(i + 1, i + 1), data:sub(i + 2, i + 2), data:sub(i + 3, i + 3)
    local v1, v2 = REVERSE[c1], REVERSE[c2]
    if v1 == nil or v2 == nil then
      return nil, "invalid base64 character"
    end
    local v3, v4 = REVERSE[c3], REVERSE[c4]
    local n1 = v1 * 262144 + v2 * 4096
    if c3 == "=" then
      if c4 ~= "=" then
        return nil, "invalid base64 padding"
      end
      out[#out + 1] = string.char(math.floor(n1 / 65536) % 256)
    else
      if v3 == nil then
        return nil, "invalid base64 character"
      end
      n1 = n1 + v3 * 64
      if c4 == "=" then
        out[#out + 1] = string.char(math.floor(n1 / 65536) % 256, math.floor(n1 / 256) % 256)
      else
        if v4 == nil then
          return nil, "invalid base64 character"
        end
        n1 = n1 + v4
        out[#out + 1] = string.char(math.floor(n1 / 65536) % 256, math.floor(n1 / 256) % 256, n1 % 256)
      end
    end
    i = i + 4
  end
  return table.concat(out)
end

return M
