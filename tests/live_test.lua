-- Live integration tests for the MongrelDB Lua client.
--
-- These tests boot a real mongreldb-server and round-trip data through every
-- public method. They skip automatically when no daemon is reachable at the
-- URL in MONGRELDB_URL (default http://127.0.0.1:8453), so the suite still
-- passes offline.
--
--   lua tests/live_test.lua
--   busted tests/live_test.lua
--
-- Requires luasocket (luarocks install luasocket).

package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

-- Load the client. If luasocket is not installed the require fails; in that
-- case we still want the file to run so the suite reports a clean skip rather
-- than a hard error.
local mongreldb_load_ok, mongreldb = pcall(require, "mongreldb")

local SERVER_URL = os.getenv("MONGRELDB_URL") or "http://127.0.0.1:8453"

local failures, passed, skipped = 0, 0, 0

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

local function skip(name, reason)
  skipped = skipped + 1
  io.write("\nSKIP " .. name .. ": " .. reason .. "\n")
end

local function assert_equal(a, b, msg)
  if a ~= b then
    error((msg or "not equal") .. ": got " .. tostring(a)
      .. ", expected " .. tostring(b))
  end
end

local columns = {
  { id = 1, name = "id", ty = "int64", primary_key = true, nullable = false },
  { id = 2, name = "label", ty = "varchar", primary_key = false, nullable = false },
  { id = 3, name = "amount", ty = "float64", primary_key = false, nullable = false },
}

-- Probe the daemon once. If it is not up (or the client could not load, e.g.
-- luasocket is missing), skip every live test.
local function server_reachable()
  if not mongreldb_load_ok then return false end
  local ok = pcall(function()
    local db = mongreldb.connect(SERVER_URL)
    if not db:health() then error("not healthy") end
  end)
  return ok
end

local reachable = server_reachable()

if not reachable then
  if not mongreldb_load_ok then
    skip("all live tests",
      "mongreldb module could not load (is luasocket installed?)")
  else
    skip("all live tests", "MONGRELDB_URL not reachable at " .. SERVER_URL)
  end
else
  local unique = tostring(os.time())

  check("health", function()
    local db = mongreldb.connect(SERVER_URL)
    assert_equal(db:health(), true, "health should be true")
  end)

  check("createTable, put, count, query", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_items_" .. unique
    db:createTable(table, columns)
    db:put(table, { [1] = 1, [2] = "alpha", [3] = 10.0 })
    db:put(table, { [1] = 2, [2] = "beta", [3] = 25.0 })
    assert_equal(db:count(table), 2)
    local rows = db:query(table, { mongreldb.condition("pk", { value = 2 }) })
    assert_equal(#rows >= 1, true, "query should return a row")
  end)

  check("upsert updates on PK conflict", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_upsert_" .. unique
    db:createTable(table, columns)
    db:put(table, { [1] = 1, [2] = "alpha", [3] = 10.0 })
    db:upsert(table, { [1] = 1, [2] = "alpha", [3] = 99.0 }, { [3] = 99.0 })
    assert_equal(db:count(table), 1)
  end)

  check("transaction commits multiple ops atomically", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_txn_" .. unique
    db:createTable(table, columns)
    local ops = {
      { put = { table = table, cells = { 1, 10, 2, "dave", 3, 50.0 } } },
      { put = { table = table, cells = { 1, 11, 2, "eve", 3, 75.0 } } },
      { delete_by_pk = { table = table, pk = 10 } },
    }
    db:transaction(ops)
    assert_equal(db:count(table), 1)
  end)

  check("sql round-trips", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_sql_" .. unique
    db:createTable(table, columns)
    db:put(table, { [1] = 1, [2] = "alpha", [3] = 1.0 })
    db:sql("INSERT INTO " .. table .. " (id, label, amount) VALUES (2, 'beta', 2.0)")
    assert_equal(db:count(table), 2)
  end)

  check("schema lists the created table", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_schema_" .. unique
    db:createTable(table, columns)
    local names = db:tableNames()
    local found = false
    for _, n in ipairs(names) do
      if n == table then found = true break end
    end
    assert_equal(found, true, "table should appear in tableNames")
    local desc = db:schemaFor(table)
    assert_equal(next(desc) ~= nil, true, "schemaFor should return a descriptor")
  end)
end

io.write("\n")
print(string.format("passed: %d, failed: %d, skipped: %d", passed, failures, skipped))
os.exit(failures == 0 and 0 or 1)
