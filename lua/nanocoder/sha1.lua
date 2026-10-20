-- Vendored pure-Lua SHA-1 (RFC 3174).
-- Used only to derive `Sec-WebSocket-Accept` during the WebSocket handshake.
-- Arithmetic only (no `bit` library) so it runs on any Lua 5.1/LuaJIT build.
local M = {}

local floor = math.floor
local MOD = 4294967296 -- 2^32

-- Byte-wise XOR lookup table (256x256), built once.
local XOR = {}
do
  for a = 0, 255 do
    local row = {}
    for b = 0, 255 do
      local x, p, aa, bb = 0, 1, a, b
      for _ = 1, 8 do
        if (aa % 2) ~= (bb % 2) then
          x = x + p
        end
        aa = floor(aa / 2)
        bb = floor(bb / 2)
        p = p * 2
      end
      row[b] = x
    end
    XOR[a] = row
  end
end

---Split a 32-bit unsigned int into 4 bytes (LSB first).
local function bytes32(x)
  local b1 = x % 256
  x = floor(x / 256)
  local b2 = x % 256
  x = floor(x / 256)
  local b3 = x % 256
  x = floor(x / 256)
  return b1, b2, b3, x % 256
end

---32-bit XOR.
local function bxor(a, b)
  local a1, a2, a3, a4 = bytes32(a)
  local b1, b2, b3, b4 = bytes32(b)
  return XOR[a1][b1] + XOR[a2][b2] * 256 + XOR[a3][b3] * 65536 + XOR[a4][b4] * 16777216
end

---32-bit AND via the identity a AND b = (a + b - (a XOR b)) / 2.
local function band(a, b)
  return floor((a + b - bxor(a, b)) / 2)
end

---Rotate left by n bits.
local function rotl(x, n)
  n = n % 32
  if n == 0 then
    return x % MOD
  end
  local left = (x % 2 ^ (32 - n)) * 2 ^ n
  local right = floor(x / 2 ^ (32 - n))
  return (left + right) % MOD
end

---SHA-1 of a raw byte string, returned as 20 raw digest bytes.
---@param msg string raw bytes
---@return string raw digest
function M.digest_raw(msg)
  local h0 = 0x67452301
  local h1 = 0xEFCDAB89
  local h2 = 0x98BADCFE
  local h3 = 0x10325476
  local h4 = 0xC3D2E1F0

  -- Padding: 0x80, zeros to 56 mod 64, then 64-bit big-endian bit length.
  local ml = #msg
  local bitlen = ml * 8
  local pad = (56 - (ml + 1) % 64) % 64
  msg = msg .. "\128" .. string.rep("\0", pad)

  -- 64-bit big-endian bit length. Messages here are small, so the high
  -- 32 bits are derived by division rather than packed arithmetic.
  local hi = floor(bitlen / 4294967296)
  local lo = bitlen % 4294967296
  msg = msg
    .. string.char(
      floor(hi / 16777216) % 256,
      floor(hi / 65536) % 256,
      floor(hi / 256) % 256,
      hi % 256,
      floor(lo / 16777216) % 256,
      floor(lo / 65536) % 256,
      floor(lo / 256) % 256,
      lo % 256
    )

  -- Process 64-byte blocks.
  for offset = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local j = offset + i * 4
      local b1, b2, b3, b4 = msg:byte(j, j + 3)
      w[i] = (b1 * 16777216 + b2 * 65536 + b3 * 256 + b4) % MOD
    end
    for i = 16, 79 do
      w[i] = rotl(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bxor(band(b, c), band(MOD - 1 - b, d))
        k = 0x5A827999
      elseif i < 40 then
        f = bxor(bxor(b, c), d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bxor(bxor(band(b, c), band(b, d)), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(bxor(b, c), d)
        k = 0xCA62C1D6
      end
      local temp = (rotl(a, 5) + f + e + k + w[i]) % MOD
      e = d
      d = c
      c = rotl(b, 30)
      b = a
      a = temp
    end

    h0 = (h0 + a) % MOD
    h1 = (h1 + b) % MOD
    h2 = (h2 + c) % MOD
    h3 = (h3 + d) % MOD
    h4 = (h4 + e) % MOD
  end

  local function u32_be(x)
    return string.char(
      floor(x / 16777216) % 256,
      floor(x / 65536) % 256,
      floor(x / 256) % 256,
      x % 256
    )
  end

  return u32_be(h0) .. u32_be(h1) .. u32_be(h2) .. u32_be(h3) .. u32_be(h4)
end

---SHA-1 of a raw byte string, returned as 40 lowercase hex chars.
---@param msg string raw bytes
---@return string hex digest
function M.digest(msg)
  return (M.digest_raw(msg):gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

return M
