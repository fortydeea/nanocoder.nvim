-- base64 encode/decode vectors and padding edge cases.
local base64 = require("nanocoder.base64")

test("encode: empty string", function()
  eq("", base64.encode(""))
end)

test("encode: RFC 4648 vectors", function()
  eq("Zg==", base64.encode("f"))
  eq("Zm8=", base64.encode("fo"))
  eq("Zm9v", base64.encode("foo"))
  eq("Zm9vYg==", base64.encode("foob"))
  eq("Zm9vYmE=", base64.encode("fooba"))
  eq("Zm9vYmFy", base64.encode("foobar"))
end)

test("decode: RFC 4648 vectors roundtrip", function()
  for _, s in ipairs({ "", "f", "fo", "foo", "foob", "fooba", "foobar" }) do
    local encoded = base64.encode(s)
    local decoded, err = base64.decode(encoded)
    eq(nil, err, "decode of " .. encoded)
    eq(s, decoded, "roundtrip of " .. encoded)
  end
end)

test("encode: high bytes (0x00, 0xff)", function()
  eq("AP8=", base64.encode(string.char(0, 255)))
end)

test("decode: rejects bad length", function()
  local decoded, err = base64.decode("Zm9vY")
  eq(nil, decoded)
  ok(err:match("length"), "should complain about length")
end)

test("decode: rejects invalid characters", function()
  local decoded, err = base64.decode("Zm9*")
  eq(nil, decoded)
  ok(err:match("character"), "should complain about characters")
end)

test("decode: rejects bad padding", function()
  local decoded, err = base64.decode("Z=9v")
  eq(nil, decoded)
end)

test("roundtrip: random-ish binary of odd lengths", function()
  for n = 0, 12 do
    local parts = {}
    for i = 1, n do
      parts[i] = string.char((i * 37) % 256)
    end
    local s = table.concat(parts)
    eq(s, base64.decode(base64.encode(s)))
  end
end)
