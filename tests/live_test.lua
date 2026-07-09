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
    -- The returned row must carry primary key 2. Confirm via SQL JSON mode,
    -- where rows are keyed by column name.
    local pk_rows = db:sql("SELECT id FROM " .. table .. " WHERE id = 2")
    assert_equal(#pk_rows >= 1, true, "sql SELECT should return the pk=2 row")
    assert_equal(pk_rows[1].id, 2, "selected row id should be 2")
  end)

  check("upsert updates on PK conflict", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_upsert_" .. unique
    db:createTable(table, columns)
    db:put(table, { [1] = 1, [2] = "alpha", [3] = 10.0 })
    db:upsert(table, { [1] = 1, [2] = "alpha", [3] = 99.0 }, { [3] = 99.0 })
    assert_equal(db:count(table), 1)
    -- Query the row back and verify the upserted value landed. SQL JSON mode
    -- returns rows keyed by column name.
    local rows = db:sql("SELECT amount FROM " .. table .. " WHERE id = 1")
    assert_equal(#rows >= 1, true, "sql SELECT should return the upserted row")
    assert_equal(rows[1].amount, 99.0, "amount should be updated to 99.0")
  end)

  check("transaction commits multiple ops atomically", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_txn_" .. unique
    db:createTable(table, columns)
    -- Stage and commit the puts first. Rows inserted in a batch are not yet
    -- visible to a delete_by_pk within the same batch (the delete runs against
    -- the pre-commit state and returns "not_found"), so the delete has to land
    -- in its own transaction once the puts are committed.
    db:transaction({
      { put = { table = table, cells = { 1, 10, 2, "dave", 3, 50.0 } } },
      { put = { table = table, cells = { 1, 11, 2, "eve", 3, 75.0 } } },
    })
    db:transaction({
      { delete_by_pk = { table = table, pk = 10 } },
    })
    assert_equal(db:count(table), 1)
  end)

  check("sql round-trips", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_sql_" .. unique
    db:createTable(table, columns)
    db:put(table, { [1] = 1, [2] = "alpha", [3] = 1.0 })
    db:sql("INSERT INTO " .. table .. " (id, label, amount) VALUES (2, 'beta', 2.0)")
    assert_equal(db:count(table), 2)
    -- JSON mode makes SELECT return rows as JSON objects (column names as
    -- keys). Verify both rows come back with the right primary keys.
    local selected = db:sql("SELECT id FROM " .. table .. " ORDER BY id")
    assert_equal(#selected, 2, "sql SELECT should return both rows")
    assert_equal(selected[1].id, 1, "first selected id should be 1")
    assert_equal(selected[2].id, 2, "second selected id should be 2")
  end)

  check("range query returns only rows within the bounds", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_range_" .. unique
    db:createTable(table, columns)
    db:put(table, { [1] = 1, [2] = "a", [3] = 50.0 })
    db:put(table, { [1] = 2, [2] = "b", [3] = 75.0 })
    db:put(table, { [1] = 3, [2] = "c", [3] = 90.0 })
    db:put(table, { [1] = 4, [2] = "d", [3] = 100.0 })
    -- Only scores >= 80 should come back (90 and 100) - assert the count.
    -- The `amount` column is float64, so use `range_f64` (plain `range`
    -- expects an i64 bound and rejects floats). range_f64 requires both
    -- bounds (min/max) and the inclusivity flags (min_inclusive/max_inclusive).
    local rows = db:query(table, {
      mongreldb.condition("range_f64", {
        column = 3,
        min = 80.0,
        max = 200.0,
        min_inclusive = true,
        max_inclusive = true,
      }),
    })
    assert_equal(#rows, 2, "range query should return 2 rows")
    -- Only rows with id 3 (amount 90) and 4 (amount 100) qualify. Confirm
    -- their exact PK values via SQL JSON mode (rows keyed by column name).
    local selected = db:sql("SELECT id FROM " .. table .. " WHERE amount >= 80.0 ORDER BY id")
    assert_equal(#selected, 2, "sql range should select 2 rows")
    assert_equal(selected[1].id, 3, "first range id should be 3")
    assert_equal(selected[2].id, 4, "second range id should be 4")
  end)

  check("schemaFor on nonexistent table raises not_found", function()
    local db = mongreldb.connect(SERVER_URL)
    local caught
    local ok, err = pcall(function()
      db:schemaFor("nonexistent_table_xyz")
    end)
    if not ok then caught = err end
    assert_equal(type(caught) == "table", true,
      "schemaFor on missing table should raise a typed error")
    assert_equal(caught.type, mongreldb.errors.not_found,
      "error type should be not_found")
  end)

  check("idempotent transaction does not duplicate the row", function()
    local db = mongreldb.connect(SERVER_URL)
    local table = "lua_idem_" .. unique
    db:createTable(table, columns)
    -- Idempotency key must be unique per run so a stale key from an earlier
    -- run can't be replayed against this table.
    local key = "order-100-create-" .. unique
    -- First idempotent commit inserts the row.
    db:transaction({
      { put = { table = table, cells = { 1, 100, 2, "order", 3, 1.0 } } },
    }, key)
    assert_equal(db:count(table), 1)
    -- A second, identical commit with the SAME key must not duplicate it.
    pcall(function()
      db:transaction({
        { put = { table = table, cells = { 1, 100, 2, "order", 3, 1.0 } } },
      }, key)
    end)
    assert_equal(db:count(table), 1)
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
