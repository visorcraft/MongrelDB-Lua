# Quickstart

This guide walks through installing the MongrelDB Lua client, connecting to a
running `mongreldb-server`, and doing your first round-trip of CRUD and query.

## Prerequisites

- Lua 5.3 or newer, or LuaJIT.
- LuaSocket (`luarocks install luasocket`).
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
  daemon. The simplest start is the prebuilt Linux binary:

  ```sh
  curl -L -o mongreldb-server \
    https://github.com/visorcraft/MongrelDB/releases/download/v0.60.3/mongreldb-server-linux-x64
  chmod +x mongreldb-server
  ./mongreldb-server ./data --port 8453
  ```

## Install

Install via LuaRocks:

```sh
luarocks install mongreldb
```

The client has a single runtime dependency (LuaSocket) and ships a vendored
JSON encoder, so there is no extra JSON library to install.

## Connect

```lua
local mongreldb = require("mongreldb")
local db = mongreldb.connect("http://127.0.0.1:8453")
print(db:health()) -- true
```

## Create a table and insert rows

```lua
db:createTable("orders", {
  { id = 1, name = "id",       ty = "int64",   primary_key = true,  nullable = false },
  { id = 2, name = "customer", ty = "varchar", primary_key = false, nullable = false },
  { id = 3, name = "amount",   ty = "float64", primary_key = false, nullable = false },
  -- Enum columns carry their variants on the column descriptor, and a
  -- scalar default_value or dynamic default_expr seeds new rows.
  { id = 4, name = "status",   ty = "enum",
    enum_variants = { "active", "paused", "archived" },
    default_value = "active" },
})

db:put("orders", { [1] = 1, [2] = "Alice", [3] = 99.50, [4] = "active" })
db:put("orders", { [1] = 2, [2] = "Bob",   [3] = 150.00, [4] = "active" })

print(db:count("orders")) -- 2
```

Cells are passed as a table mapping column id to value.

## Run a query

```lua
local rows = db:query("orders", {
  mongreldb.condition("pk", { value = 1 }),
})
```

## Column defaults and explicit null

Static defaults are sent as typed JSON values. Use `mongreldb.null` for an
explicit JSON `null`; plain Lua `nil` would drop the key from the descriptor.
Dynamic defaults use `default_expr`.

```lua
db:createTable("orders", {
  { id = 1, name = "id",       ty = "int64",   primary_key = true, nullable = false },
  { id = 2, name = "status",   ty = "varchar", default_value = "draft" },
  { id = 3, name = "attempts", ty = "int64",   default_value = 3 },
  { id = 4, name = "active",   ty = "bool",    default_value = true },
  { id = 5, name = "notes",    ty = "varchar", default_value = mongreldb.null },
  { id = 6, name = "created",  ty = "timestamp_nanos", default_expr = "now" },
})
```

## History retention

Set how many epochs of history remain readable for `AS OF EPOCH` queries.

```lua
db:setHistoryRetentionEpochs(1000)
print(db:historyRetentionEpochs()) -- 1000
print(db:earliestRetainedEpoch())  -- oldest retained epoch

-- Read the table as it existed at epoch 42.
local historical = db:sql("SELECT * FROM orders AS OF EPOCH 42")
```

## Next steps

- [Transactions](transactions.md) for atomic multi-op commits.
- [Queries](queries.md) for the native index condition API.
- [SQL](sql.md) for DataFusion-backed ad-hoc SQL.
- [Auth](auth.md) for Bearer and Basic authentication.
- [Errors](errors.md) for the exception hierarchy.
