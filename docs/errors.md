# Error handling

The Lua client reports errors as table objects with a `.type` field. Every
error also has a `.message` and implements `__tostring` so it prints cleanly.
You match on `.type` to react to the specific category.

## Error types

| `.type` | Meaning |
|---|---|
| `mongreldb` | Base category, unexpected internal error |
| `auth` | HTTP 401 / 403 |
| `not_found` | HTTP 404 |
| `constraint` | HTTP 409, constraint violation at commit |
| `connection` | Network-level failure (refused, DNS, timeout) |
| `query` | HTTP 400 / 500, malformed payloads, JSON failures |

Because Lua has no built-in exception type, the client raises these via
`error()`; wrap calls in `pcall` to catch them.

## Catching by category

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

## Constraint fields

A `constraint` error carries extra fields:

- `error_code` - the server's error code string, e.g. `UNIQUE_VIOLATION`.
- `op_index` - when reported, the index of the offending operation within the
  batch (useful when a [transaction](transactions.md) commit fails).
- `status` - the HTTP status code.

## Connection failures

A `connection` error is raised for any network-level problem: connection
refused, DNS lookup failure, or a broken socket. The `health()` helper
swallows these and returns `false` instead, which is handy for startup
checks:

```lua
if not db:health() then
  -- daemon not reachable; degrade gracefully
end
```

## JSON edge cases

The client refuses to send values that have no valid JSON representation:
infinity, NaN, and recursive structures. These raise a `query` error at the
client boundary rather than corrupting data on the server. Malformed UTF-8 is
passed through so the daemon can substitute it.
