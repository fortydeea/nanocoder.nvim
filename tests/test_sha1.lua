-- SHA-1 against the RFC 3174 test vectors.
local sha1 = require("nanocoder.sha1")

test("RFC 3174 vector: 'abc'", function()
  eq("a9993e364706816aba3e25717850c26c9cd0d89d", sha1.digest("abc"))
end)

test("RFC 3174 vector: empty string", function()
  eq("da39a3ee5e6b4b0d3255bfef95601890afd80709", sha1.digest(""))
end)

test("RFC 3174 vector: 448-bit message", function()
  eq("84983e441c3bd26ebaae4aa1f95129e5e54670f1", sha1.digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
end)

test("RFC 3174 vector: 896-bit message", function()
  eq(
    "a49b2446a02c645bf419f995b67091253a04a259",
    sha1.digest("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
  )
end)

test("one million 'a' characters (RFC 3174 vector)", function()
  eq("34aa973cd4c4daa4f61eeb2bdbad27316534016f", sha1.digest(string.rep("a", 1000000)))
end)

test("digest is 40 lowercase hex chars", function()
  local d = sha1.digest("hello")
  eq(40, #d)
  ok(d:match("^[0-9a-f]+$"), "digest should be lowercase hex")
end)
