-- Basic CRUD example for the MongrelDB Lua client.
--
-- Run with:
--   luarocks install luasocket --local
--   eval $(luarocks path --bin)
--   lua examples/basic_crud.lua
--
-- Requires a running mongreldb-server on http://127.0.0.1:8453.

-- Make `require("mongreldb")` resolve when running the example directly with
-- `lua examples/basic_crud.lua` from the repo root (no luarocks install of the
-- client needed). src/mongreldb/init.lua matches both patterns below.
package.path = package.path .. ";./src/?.lua;./src/?/init.lua"

local mongreldb = require("mongreldb")

local db = mongreldb.connect("http://127.0.0.1:8453")

print("health:", db:health())

-- Per-run unique suffix so concurrent/CI runs never collide on a table name.
local table_name = "lua_demo_" .. os.time()

-- Run the body in a protected call so the table is ALWAYS dropped, even on
-- error. The cleanup pcall runs unconditionally afterward.
local ok, err = pcall(function()
  db:createTable(table_name, {
    { id = 1, name = "id", ty = "int64", primary_key = true, nullable = false },
    { id = 2, name = "label", ty = "varchar", primary_key = false, nullable = false },
    { id = 3, name = "amount", ty = "float64", primary_key = false, nullable = false },
    -- Enum column: variants ride on the column descriptor.
    { id = 4, name = "status", ty = "enum",
      enum_variants = { "active", "paused", "archived" } },
    -- The daemon accepts "now" and "uuid" default expressions.
    { id = 5, name = "created_at", ty = "timestamp_nanos",
      default_value = "now" },
  }, {
    checks = {
      { id = 1, name = "id_present", expr = { IsNotNull = 1 } },
    },
  })

  db:put(table_name, { [1] = 1, [2] = "first",  [3] = 10.0, [4] = "active" })
  db:put(table_name, { [1] = 2, [2] = "second", [3] = 20.0, [4] = "paused" })
  print("count:", db:count(table_name))

  -- Upsert: change the second row.
  db:upsert(table_name, { [1] = 2, [2] = "second", [3] = 42.0, [4] = "paused" },
    { [3] = 42.0 })

  -- Read it back via the query builder.
  local rows = db:query(table_name, { mongreldb.condition("pk", { value = 2 }) })
  print("row 2:", #rows, "rows returned")

  -- Batch delete in a transaction.
  db:transaction({
    { delete_by_pk = { table = table_name, pk = 1 } },
    { delete_by_pk = { table = table_name, pk = 2 } },
  })
  print("count after txn:", db:count(table_name))
end)

-- Guaranteed cleanup: drop the table even if the body errored.
pcall(function() db:dropTable(table_name) end)
print("dropped:", table_name)

if not ok then
  io.stderr:write("error: ", tostring(err), "\n")
  os.exit(1)
end
