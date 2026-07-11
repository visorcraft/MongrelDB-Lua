-- Pure unit tests for the vendored JSON encoder/decoder.
-- No daemon required; runnable with stock Lua 5.3+.
--
--   lua tests/json_test.lua
--   busted tests/json_test.lua

-- Prefer the installed package layout; fall back to the repo's src/ directory
-- so the tests run directly from a fresh checkout with `lua tests/json_test.lua`.
package.path = package.path .. ";./src/?.lua;./src/?/init.lua"
local json = require("mongreldb.json")

local failures, passed = 0, 0

local function check(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write(".")
  else
    failures = failures + 1
    io.write("\nFAIL " .. name .. ": " .. tostring(err) .. "\n")
  end
end

local function assert_equal(a, b, msg)
  if a ~= b then
    error((msg or "not equal") .. ": got " .. tostring(a)
      .. ", expected " .. tostring(b))
  end
end

check("encode string", function()
  assert_equal(json.encode("hello"), '"hello"')
end)

check("encode escapes quotes and control chars", function()
  assert_equal(json.encode('a"b\nc'), '"a\\"b\\nc"')
end)

check("encode integer", function()
  assert_equal(json.encode(42), "42")
end)

check("encode boolean", function()
  assert_equal(json.encode(true), "true")
  assert_equal(json.encode(false), "false")
end)

check("encode nil", function()
  assert_equal(json.encode(nil), "null")
end)

check("encode explicit null sentinel", function()
  assert_equal(json.encode({ value = json.null }), '{"value":null}')
end)

check("explicit null sentinel is distinct from nil in encoded objects", function()
  local body = json.encode({ a = json.null, b = "present" })
  assert_equal(body:find('"a":null') ~= nil, true, "explicit null key should serialize")
  assert_equal(body:find('"b":"present"') ~= nil, true, "string key should serialize")
  -- A nil-valued key is dropped; an explicit null sentinel key is kept.
  body = json.encode({ a = json.null, b = "present", c = nil })
  assert_equal(body:find('"c"') == nil, true, "nil key should be omitted")
end)

check("static default scalars round-trip through encode/decode", function()
  local defaults = {
    string = "draft",
    integer = 7,
    boolean = true,
    literal_now = "now",
  }
  local body = json.encode(defaults)
  local decoded = json.decode(body)
  assert_equal(decoded.string, "draft")
  assert_equal(decoded.integer, 7)
  assert_equal(decoded.boolean, true)
  assert_equal(decoded.literal_now, "now")
end)

check("encode array", function()
  local s = json.encode({ 1, 2, 3 })
  assert_equal(s, "[1,2,3]")
end)

check("encode object", function()
  local s = json.encode({ a = 1 })
  assert_equal(s, '{"a":1}')
end)

check("encode empty table is object", function()
  local s = json.encode({})
  assert_equal(s, "{}")
end)

check("encode rejects NaN", function()
  local s, err = json.encode(math.sqrt(-1))
  assert_equal(s, nil, "NaN should be rejected")
  assert_equal(err ~= nil, true, "NaN should report an error")
end)

check("encode rejects Infinity", function()
  local s, err = json.encode(math.huge)
  assert_equal(s, nil, "Infinity should be rejected")
  assert_equal(err ~= nil, true, "Infinity should report an error")
end)

check("decode string", function()
  assert_equal(json.decode('"hi"'), "hi")
end)

check("decode number", function()
  assert_equal(json.decode("3.14"), 3.14)
end)

check("decode array", function()
  local t = json.decode("[1,2,3]")
  assert_equal(t[1], 1)
  assert_equal(t[3], 3)
end)

check("decode object", function()
  local t = json.decode('{"a":1,"b":2}')
  assert_equal(t.a, 1)
  assert_equal(t.b, 2)
end)

check("decode nested", function()
  local t = json.decode('{"a":[1,2]}')
  assert_equal(t.a[1], 1)
  assert_equal(t.a[2], 2)
end)

check("decode handles null", function()
  local t = json.decode('{"a":null}')
  assert_equal(t.a, nil)
end)

check("roundtrip object", function()
  local original = { id = 1, name = "Alice", active = true }
  local decoded = json.decode(json.encode(original))
  assert_equal(decoded.id, 1)
  assert_equal(decoded.name, "Alice")
  assert_equal(decoded.active, true)
end)

io.write("\n")
print(string.format("passed: %d, failed: %d", passed, failures))
os.exit(failures == 0 and 0 or 1)
