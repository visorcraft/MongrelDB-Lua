-- Basic CRUD example for the MongrelDB Lua client.
--
-- Run with:
--   luarocks install luasocket --local
--   eval $(luarocks path --bin)
--   lua examples/basic_crud.lua
--
-- Requires a running mongreldb-server on http://127.0.0.1:8453.
local mongreldb = require("mongreldb")

local db = mongreldb.connect("http://127.0.0.1:8453")

print("health:", db:health())

-- Drop a leftover table if present, then create a fresh one.
pcall(function() db:dropTable("demo") end)

db:createTable("demo", {
  { id = 1, name = "id", ty = "int64", primary_key = true, nullable = false },
  { id = 2, name = "label", ty = "varchar", primary_key = false, nullable = false },
  { id = 3, name = "amount", ty = "float64", primary_key = false, nullable = false },
})

db:put("demo", { [1] = 1, [2] = "first",  [3] = 10.0 })
db:put("demo", { [1] = 2, [2] = "second", [3] = 20.0 })
print("count:", db:count("demo"))

-- Upsert: change the second row.
db:upsert("demo", { [1] = 2, [2] = "second", [3] = 42.0 }, { [3] = 42.0 })

-- Read it back via the query builder.
local rows = db:query("demo", { mongreldb.condition("pk", { value = 2 }) })
print("row 2:", #rows, "rows returned")

-- Batch delete in a transaction.
db:transaction({
  { delete_by_pk = { table = "demo", pk = 1 } },
  { delete_by_pk = { table = "demo", pk = 2 } },
})
print("count after txn:", db:count("demo"))
