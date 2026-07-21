<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Lua Client</h1>

<p align="center">
  <b>Pure Lua HTTP client for the MongrelDB server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
</p>

<p align="center">
  <a href="https://luarocks.org/modules/visorcraft/mongreldb"><img src="https://img.shields.io/badge/luarocks-mongreldb-2C2D72.svg" alt="LuaRocks" /></a>
  <a href="https://www.lua.org/"><img src="https://img.shields.io/badge/Lua-%3E%3D5.3-000080.svg" alt="Lua" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Lua client | `mongreldb` | `luarocks install mongreldb` |

## Requirements

- **Lua 5.3 or newer**
- **LuaSocket** (`luarocks install luasocket`) for the HTTP transport
- The vendored JSON encoder has no further dependencies
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, with idempotency keys for safe retries.
- **Native query conditions** that push down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match.
- **Idempotent batch transactions**, all operations staged in a list and committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, multi-statement execution, and the `mongreldb_fts_rank` relevance-scoring UDF.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **Maintenance**: compaction (all tables or per-table).
- **LuaSocket transport** with a vendored JSON encoder, so the only external runtime dependency is `luasocket`.
- **Typed error objects** with a `.type` field: `auth` (401/403), `not_found` (404), `constraint` (409, with error code and op index), `connection` (network), and `query` (everything else).
- **Robust JSON handling**: NaN and Infinity raise a clear `query` error instead of corrupting data; malformed UTF-8 is passed through so the daemon can substitute it.

## Examples

Runnable, commented examples live in [`examples/`](examples):

- [Basic CRUD](examples/basic_crud.lua), connect, create a table, insert, query, count.

## Quick Example

```lua
local mongreldb = require("mongreldb")

-- Connect to a running mongreldb-server daemon.
local db = mongreldb.connect("http://127.0.0.1:8453")

-- Create a table.
db:createTable("orders", {
  { id = 1, name = "id",       ty = "int64",   primary_key = true,  nullable = false },
  { id = 2, name = "customer", ty = "varchar", primary_key = false, nullable = false },
  { id = 3, name = "amount",   ty = "float64", primary_key = false, nullable = false },
  -- Enum columns carry their variants on the column descriptor, and a
  -- scalar default_value and dynamic default_expr are passed through.
  { id = 4, name = "status",   ty = "enum",
    enum_variants = { "active", "paused", "archived" } },
  { id = 5, name = "created_at", ty = "timestamp_nanos",
    default_expr = "now" },
}, {
  checks = {
    { id = 1, name = "id_present", expr = { IsNotNull = 1 } },
  },
})

-- Insert rows. Cells map column id to value.
db:put("orders", { [1] = 1, [2] = "Alice", [3] = 99.50, [4] = "active" })
db:put("orders", { [1] = 2, [2] = "Bob",   [3] = 150.00, [4] = "active" })

-- Upsert (insert or update on PK conflict).
db:upsert("orders", { [1] = 1, [2] = "Alice", [3] = 120.00, [4] = "active" },
  { [3] = 120.00 })

-- Query with a native index condition (learned-range index on a float column).
local rows = db:query("orders", {
  mongreldb.condition("range_f64", {
    column = 3, min = 100.0, max = 200.0,
    min_inclusive = true, max_inclusive = true,
  }),
}, { projection = { 1, 2 }, limit = 100 })

print(db:count("orders")) -- 2

-- Run SQL.
db:sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## Auth

```lua
-- Bearer token (--auth-token mode).
local db = mongreldb.connect("http://127.0.0.1:8453", { token = "my-secret-token" })

-- HTTP Basic (--auth-users mode).
local db = mongreldb.connect("http://127.0.0.1:8453",
  { username = "admin", password = "s3cret" })
```

## Transactions

Operations are staged in a list and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```lua
local ops = {
  { put = { table = "orders", cells = { 1, 10, 2, "Dave", 3, 50.0 } } },
  { put = { table = "orders", cells = { 1, 11, 2, "Eve",  3, 75.0 } } },
  { delete_by_pk = { table = "orders", pk = 2 } },
}

local ok, err = pcall(function()
  db:transaction(ops) -- atomic, all or nothing
end)
if not ok and err.type == "constraint" then
  print("Constraint violated:", err.error_code, "-", err.message)
end

-- Idempotent commit, safe to retry; daemon returns the original response.
db:transaction(ops2, "order-20-create")
```

## Query builder

Conditions push down to the engine's specialized indexes. `mongreldb.condition`
accepts friendly aliases that are translated to the server's on-wire keys:
`column` (to `column_id`), `min`/`max` (to `lo`/`hi`),
`min_inclusive`/`max_inclusive` (to `lo_inclusive`/`hi_inclusive`). The canonical
keys are also accepted directly. Use `range` for integer columns and `range_f64`
for float64 columns.

```lua
-- Bitmap equality (low-cardinality columns).
db:query("orders", { mongreldb.condition("bitmap_eq", { column = 2, value = "Alice" }) })

-- Range query on a float64 column (use `range` for integer columns).
db:query("orders", {
  mongreldb.condition("range_f64", {
    column = 3, min = 50.0, max = 150.0,
    min_inclusive = true, max_inclusive = true,
  }),
}, { limit = 100 })

-- Range query on an integer column.
db:query("orders", {
  mongreldb.condition("range", { column = 1, min = 1, max = 100 }),
}, { limit = 100 })

-- Full-text search (FM-index).
db:query("documents", {
  mongreldb.condition("fm_contains", { column = 2, pattern = "database performance" }),
}, { limit = 10 })

-- Vector similarity search (HNSW).
db:query("embeddings", {
  mongreldb.condition("ann", { column = 2, query = { 0.1, 0.2, 0.3 }, k = 10 }),
})

-- Check whether a result was capped by the limit.
local rows, truncated = db:query("orders",
  { mongreldb.condition("range_f64", {
      column = 3, min = 0.0, max = 9999.0,
      min_inclusive = true, max_inclusive = true,
    }) },
  { limit = 100 })
if truncated then
  -- result set hit the limit; more matches exist on the server.
end
```

## SQL

```lua
db:sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
db:sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

-- Recursive CTEs and window functions.
db:sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
db:sql("SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders")
```

## ANN index backends

The engine's `ann` index is swappable across three backends - `hnsw` (the default), `diskann`, and `ivf` - selected with the `algorithm` option. Quantization is independently configurable: `dense`, `binary_sign`, or `product` (product quantization, with `num_subvectors`, `bits_per_subvector`, `pq_training_samples`, `pq_seed`, and `pq_rerank_factor`). These are ordinary DDL strings run through `sql`, so no client changes are needed.

```lua
-- DiskANN (in-memory Vamana graph)
db:sql("CREATE INDEX orders_emb_diskann ON orders USING ann (embedding) WITH (algorithm = 'diskann', quantization = 'dense', diskann_l = 50, diskann_r = 64, beam_width = 8)")

-- IVF with dense vectors (clustered)
db:sql("CREATE INDEX orders_emb_ivf ON orders USING ann (embedding) WITH (algorithm = 'ivf', quantization = 'dense', nlist = 1024, nprobe = 16)")

-- HNSW with product quantization (recall-tuned)
db:sql("CREATE INDEX orders_emb_hnsw_pq ON orders USING ann (embedding) WITH (algorithm = 'hnsw', quantization = 'product', m = 16, ef_construction = 200, ef_search = 50, num_subvectors = 32, pq_training_samples = 50000, pq_rerank_factor = 8)")
```


## User and role management

User and role administration is done through SQL against the `/sql` endpoint.
Quote identifiers and escape literals so caller-supplied names are safe to
interpolate.

```lua
db:sql('CREATE USER "admin" WITH PASSWORD \'s3cret-pw\'')
db:sql('ALTER USER "admin" ADMIN')

db:sql('CREATE ROLE "analyst"')
db:sql('GRANT SELECT ON orders TO "analyst"')
db:sql('GRANT "analyst" TO "alice"')
```

## Error handling

```lua
local mongreldb = require("mongreldb")
local db = mongreldb.connect("http://127.0.0.1:8453")

local ok, err = pcall(function() db:put("orders", { [1] = 1 }) end) -- duplicate PK
if not ok then
  if err.type == "constraint" then
    print("Constraint:", err.error_code) -- UNIQUE_VIOLATION
  elseif err.type == "auth" then
    print("Not authorized:", err.message)
  elseif err.type == "not_found" then
    print("Not found:", err.message)
  elseif err.type == "connection" then
    print("Can't reach daemon:", err.message)
  else
    print("Error:", err.message)
  end
end
```

## API reference

### `mongreldb` module

| Method | Description |
|---|---|
| `mongreldb.connect(url, opts)` | Connect to a daemon |
| `mongreldb.condition(type, params)` | Build a normalized condition |
| `mongreldb.json` | The vendored JSON module |
| `mongreldb.null` | JSON-null sentinel for explicit `null` values |
| `mongreldb.errors` | Error-type string constants |

### `Client` object (from `connect`)

| Method | Description |
|---|---|
| `health()` | Check daemon health |
| `tableNames()` | List table names |
| `createTable(name, columns, constraints?, indexes?)` | Create a table with optional constraints and all index definitions |
| `dropTable(name)` | Drop a table |
| `count(table)` | Row count |
| `put(table, cells)` | Insert a row |
| `upsert(table, cells, update_cells)` | Upsert a row |
| `delete(table, rowId)` | Delete by row ID |
| `deleteByPk(table, pk)` | Delete by primary key |
| `query(table, conditions, opts)` | Run a native query; opts include `limit` and `offset` |
| `sql(statement)` | Execute SQL |
| `schema()` | Full schema catalog |
| `schemaFor(table)` | Single table schema |
| `compact()` | Compact all tables |
| `transaction(ops, idempotency_key)` | Commit a batch atomically |
| `historyRetention()` | Get the full history retention response |
| `setHistoryRetentionEpochs(epochs)` | Set the history retention window |
| `historyRetentionEpochs()` | Get the current retention window |
| `earliestRetainedEpoch()` | Get the oldest readable epoch |

## History retention

Control how far back time-travel queries can read. The window is measured in
epochs (monotonically increasing commit numbers).

```lua
-- Keep at least 1000 epochs of history readable.
db:setHistoryRetentionEpochs(1000)

print(db:historyRetentionEpochs()) -- 1000
print(db:earliestRetainedEpoch())  -- oldest epoch still available

-- Read a table as it existed at a specific epoch.
local rows = db:sql("SELECT label FROM orders AS OF EPOCH 42 WHERE id = 1")
```

These endpoints require admin privileges when the daemon runs with auth enabled.
Raising retention prevents history from being garbage collected, but it cannot
restore epochs that have already been pruned.

## Static defaults and explicit null

Column descriptors can carry a literal `default_value` or a dynamic
`default_expr`. Use `mongreldb.null` when you need an explicit JSON `null`
because Lua `nil` removes the key from the table.

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

`default_expr` accepts only `"now"` or `"uuid"`; everything else is a static
literal. A literal `"now"` string in `default_value` remains a string default.

## Building and testing

The test suite is split into a pure unit suite (no daemon needed) and a live
integration suite.

```sh
luarocks install luasocket --local     # the only runtime dependency
lua tests/json_test.lua                # pure unit tests, always runnable
```

For the live round-trip suite, start a daemon and point the tests at it:

```sh
MONGRELDB_URL=http://127.0.0.1:8453 lua tests/live_test.lua
```

Linting:

```sh
luacheck src tests
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change, the suite must stay green.
3. Keep Lua 5.3 as the minimum supported version.
4. Match the existing style: two-space indent, `snake_case`, colon-syntax
   methods, and `luacheck` clean.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
