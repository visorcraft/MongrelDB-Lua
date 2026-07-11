-- Wire-shape conformance tests for the MongrelDB Lua client.
--
-- The /kit/create_table endpoint accepts a rich column descriptor that
-- includes `enum_variants` and `default_value` (alias for `default_expr`
-- on the server). These tests pin the JSON the Lua client emits so a
-- future encoder change cannot silently strip those keys on the way to
-- the daemon.
--
-- No daemon or socket needed; the unit under test is the body builder
-- the Client:createTable method delegates to.
--
--   lua tests/wire_shape_test.lua
--   busted tests/wire_shape_test.lua

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"
local mongreldb = require("mongreldb")

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

local function assert_true(cond, msg)
  if not cond then
    error((msg or "assertion failed") .. ": got " .. tostring(cond), 2)
  end
end

local function assert_equal(a, b, msg)
  if a ~= b then
    error((msg or "not equal") .. ": got " .. tostring(a)
      .. ", expected " .. tostring(b))
  end
end

-- Returns true if `needle` is present as a complete JSON key token in
-- `haystack`. The check is permissive on whitespace and ignores partial
-- matches so a substring like "enum_variants_other" would not satisfy it.
local function json_contains_key(body, key)
  -- Match "key" optionally followed by a value, and never as a suffix of
  -- a longer identifier. The negative lookahead keeps us from accepting
  -- "default_value_legacy" as a hit for "default_value".
  return body:find('"' .. key .. '"') ~= nil
end

check("createTable body includes enum_variants and default_value verbatim", function()
  local columns = {
    {
      id = 1,
      name = "id",
      ty = "int64",
      primary_key = true,
      nullable = false,
    },
    {
      id = 2,
      name = "status",
      ty = "enum",
      enum_variants = { "active", "paused", "archived" },
    },
    {
      id = 3,
      name = "created_at",
      ty = "timestamp_nanos",
      default_value = "now",
    },
  }
  local constraints = {
    checks = {
      { id = 1, name = "id_present", expr = { IsNotNull = 1 } },
    },
  }
  local body = mongreldb._build_create_table_body("orders", columns, constraints)
  assert_true(json_contains_key(body, "enum_variants"),
    "enum_variants should appear verbatim in the JSON body")
  assert_true(json_contains_key(body, "default_value"),
    "default_value should appear verbatim in the JSON body")
  -- Values must also survive the round-trip.
  assert_true(body:find('"active"') ~= nil,
    "enum variant value should be present")
  assert_true(body:find('"paused"') ~= nil,
    "enum variant value should be present")
  assert_true(json_contains_key(body, "constraints"),
    "constraints should appear in the JSON body")
  assert_true(json_contains_key(body, "checks"),
    "constraints.checks should appear in the JSON body")
  assert_true(json_contains_key(body, "IsNotNull"),
    "check expression should appear in the JSON body")
end)

check("createTable body omits enum_variants and default_value when unset", function()
  local columns = {
    {
      id = 1,
      name = "id",
      ty = "int64",
      primary_key = true,
      nullable = false,
    },
    {
      id = 2,
      name = "label",
      ty = "varchar",
      primary_key = false,
      nullable = false,
    },
  }
  local body = mongreldb._build_create_table_body("plain", columns)
  assert_true(not json_contains_key(body, "enum_variants"),
    "enum_variants must not appear when the column has no variants")
  assert_true(not json_contains_key(body, "default_value"),
    "default_value must not appear when the column has no default")
end)

check("createTable body round-trips through the JSON decoder", function()
  local columns = {
    {
      id = 1,
      name = "id",
      ty = "int64",
      primary_key = true,
      nullable = false,
    },
    {
      id = 2,
      name = "status",
      ty = "enum",
      enum_variants = { "a", "b" },
      default_value = "a",
    },
  }
  local body = mongreldb._build_create_table_body("orders", columns)
  local decoded = mongreldb.json.decode(body)
  assert_equal(type(decoded), "table", "decoded body should be an object")
  assert_equal(decoded.name, "orders", "table name should round-trip")
  local c2 = decoded.columns[2]
  assert_equal(type(c2), "table", "second column should decode")
  assert_equal(c2.ty, "enum", "ty should round-trip")
  assert_equal(type(c2.enum_variants), "table",
    "enum_variants should decode to an array")
  assert_equal(#c2.enum_variants, 2, "enum_variants length")
  assert_equal(c2.enum_variants[1], "a", "first variant")
  assert_equal(c2.enum_variants[2], "b", "second variant")
  assert_equal(c2.default_value, "a", "default_value should round-trip")
end)

io.write("\n")
print(string.format("passed: %d, failed: %d", passed, failures))
os.exit(failures == 0 and 0 or 1)
