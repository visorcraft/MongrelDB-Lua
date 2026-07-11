-- MongrelDB Lua client.
--
-- Pure Lua HTTP client for mongreldb-server. Talks JSON over the Kit
-- transaction, query, and SQL endpoints, with a small exception hierarchy
-- and a fluent-ish query builder.
--
-- Depends on LuaSocket for the transport and a vendored JSON encoder, so the
-- only external runtime dependency is luasocket.
--
-- Usage:
--   local mongreldb = require("mongreldb")
--   local db = mongreldb.connect("http://127.0.0.1:8453")
--   db:createTable("orders", columns)
--   db:put("orders", {[1] = 1, [2] = "Alice", [3] = 99.5})

local json = require("mongreldb.json")
local socket = require("socket")
local url_parser = require("socket.url")

-- Exception table. Each is a plain table with .message and .type fields so
-- callers can match by type without pcall gymnastics.
local M = {}
M.null = json.null

M.errors = {
  -- Base. All other errors set their .type to one of these strings.
  mongreldb = "mongreldb",
  auth = "auth",
  not_found = "not_found",
  constraint = "constraint",
  connection = "connection",
  query = "query",
}

-- Build an error object. kind is one of M.errors.* strings.
local function make_error(kind, message, extra)
  local err = { type = kind, message = message }
  if extra then
    for k, v in pairs(extra) do err[k] = v end
  end
  -- Implement __tostring so `tostring(err)` and `error(err)` read well.
  return setmetatable(err, {
    __tostring = function() return kind .. ": " .. message end,
  })
end

-- Map an HTTP status code to the right error kind.
local function kind_for_status(status)
  if status == 401 or status == 403 then return M.errors.auth end
  if status == 404 then return M.errors.not_found end
  if status == 409 then return M.errors.constraint end
  return M.errors.query
end

-- Parse the daemon's {"error":{"message":...,"code":...,"op_index":...}} envelope.
local function parse_error_envelope(body)
  local decoded = json.decode(body)
  if type(decoded) == "table" and type(decoded.error) == "table" then
    return decoded.error.message or body, decoded.error.code or "",
      decoded.error.op_index
  end
  return body, nil, nil
end

-- Percent-encode a single URL path segment so a table name containing '/',
-- '?', '#', or CR/LF cannot inject extra path segments or header bytes.
local function encode_path_segment(seg)
  return url_parser.escape(tostring(seg))
end

-- Reject CR/LF in a string to prevent CRLF header injection.
local function assert_no_crlf(value, field)
  if value and (value:find("\r") or value:find("\n")) then
    error(make_error(M.errors.query,
      "illegal CR/LF in " .. field .. " value"), 2)
  end
end

-- Flatten {col_id = value} into {col_id, value, col_id, value, ...}.
-- Returns a sequential Lua array (1-indexed) ready for JSON encoding.
local function cells_to_flat(cells)
  local flat = {}
  local keys = {}
  for k in pairs(cells) do
    local nk = tonumber(k)
    if nk == nil or math.floor(nk) ~= nk or nk < 1 then
      error(make_error(M.errors.query,
        "cell key must be a positive integer column id, got " .. tostring(k)), 2)
    end
    table.insert(keys, nk)
  end
  table.sort(keys, function(a, b) return a < b end)
  for _, k in ipairs(keys) do
    table.insert(flat, k)
    table.insert(flat, cells[k])
  end
  return flat
end

-- Translate friendly aliases to the server's canonical wire keys for a single
-- condition (column->column_id, min/max->lo/hi, etc.).
local function normalize_condition(cond_type, params)
  local aliases = {
    column = "column_id",
    min = "lo",
    max = "hi",
    min_inclusive = "lo_inclusive",
    max_inclusive = "hi_inclusive",
  }
  local out = {}
  local seen = {}
  for k, v in pairs(params) do
    local key = k
    if (cond_type == "fm_contains" or cond_type == "fm_contains_all")
       and k == "value" then
      key = "pattern"
    end
    local canonical = aliases[key] or key
    if seen[canonical] then
      error(make_error(M.errors.query,
        "duplicate condition key '" .. canonical .. "' (alias collision)"), 2)
    end
    seen[canonical] = true
    out[canonical] = v
  end
  return out
end

-- -- The Client -----------------------------------------------------------

local Client = {}
Client.__index = Client

-- Open the TCP connection, send the request, read the full response, and close.
-- Returns status_code, body. Raises a connection error on network failure.
local function http_request(base_url, method, path, headers, body)
  -- Resolve base URL into host and port.
  local parsed = url_parser.parse(base_url)
  local host = parsed.host
  local port = parsed.port or 80
  if parsed.scheme == "https" then
    error(make_error(M.errors.connection,
      "HTTPS is not supported by the built-in transport; terminate TLS in a reverse proxy"))
  end

  local conn = socket.connect(host, port)
  if not conn then
    error(make_error(M.errors.connection,
      "cannot connect to " .. host .. ":" .. tostring(port)), 2)
  end
  conn:settimeout(60)

  -- Assemble the request line and headers.
  local lines = { method .. " /" .. path .. " HTTP/1.1" }
  local h = {}
  for k, v in pairs(headers or {}) do h[k] = v end
  h["Host"] = host .. ":" .. tostring(port)
  h["Connection"] = "close"
  if body then h["Content-Type"] = "application/json" end
  h["Content-Length"] = body and #body or 0
  h["Accept"] = "application/json"
  for k, v in pairs(h) do
    table.insert(lines, k .. ": " .. tostring(v))
  end
  table.insert(lines, "")
  if body then
    table.insert(lines, body)
  else
    table.insert(lines, "")
  end

  local ok, err = conn:send(table.concat(lines, "\r\n"))
  if not ok then
    conn:close()
    error(make_error(M.errors.connection, "send failed: " .. tostring(err)), 2)
  end

  -- Read the entire response as one string.
  local response = {}
  while true do
    local chunk, rerr, partial = conn:receive(4096)
    if chunk then table.insert(response, chunk) end
    if rerr == "closed" then
      if partial and #partial > 0 then table.insert(response, partial) end
      break
    elseif rerr then
      conn:close()
      error(make_error(M.errors.connection, "receive failed: " .. tostring(rerr)), 2)
    end
  end
  conn:close()

  local raw = table.concat(response)
  -- Split status line / headers / body on the first blank line. find() returns
  -- start and end byte positions of the separator, so the body starts one byte
  -- past the end position. Handle both CRLF and bare-LF blank lines.
  local sep_start, sep_end = raw:find("\r\n\r\n", 1, true)
  local body_start
  if sep_start then
    body_start = sep_end + 1
  else
    sep_start = raw:find("\n\n", 1, true)
    if not sep_start then
      error(make_error(M.errors.query, "malformed HTTP response"), 2)
    end
    body_start = sep_start + 2
  end
  local status_line = raw:match("^HTTP/%d%.%d (%d+) ")
  local status = tonumber(status_line) or 0
  local resp_body = raw:sub(body_start)
  -- Cap the response body at 256 MB so a runaway query or a misbehaving
  -- daemon cannot exhaust memory.
  local max_bytes = 256 * 1024 * 1024 -- 268435456 bytes
  if #resp_body > max_bytes then
    error(make_error(M.errors.query,
      "response body exceeds " .. max_bytes .. " bytes (" .. #resp_body .. " bytes)"), 2)
  end
  return status, resp_body
end

--- Connect to a running mongreldb-server daemon.
-- @param url Base URL (e.g. "http://127.0.0.1:8453")
-- @param opts Optional table: { token = "...", username = "...", password = "..." }
function M.connect(url, opts)
  opts = opts or {}
  local self = setmetatable({
    url = url,
    token = opts.token,
    username = opts.username,
    password = opts.password,
  }, Client)

  -- Precompute the Authorization header once.
  self._auth_header = nil
  if opts.token then
    -- Reject CR/LF to prevent CRLF header injection.
    assert_no_crlf(opts.token, "token")
    self._auth_header = "Bearer " .. opts.token
  elseif opts.username then
    assert_no_crlf(opts.username, "username")
    assert_no_crlf(opts.password, "password")
    -- Base64 encode the credentials inline (no mime dependency).
    local creds = opts.username .. ":" .. (opts.password or "")
    self._auth_header = "Basic " .. (M._base64(creds))
  end

  return self
end

-- Tiny base64 encoder (avoids pulling in mime, which LuaSocket ships but is
-- sometimes stripped from minimal builds).
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M._base64(s)
  local out, i = {}, 1
  while i <= #s do
    local a = s:byte(i) or 0
    local b = (i + 1 <= #s) and s:byte(i + 1) or 0
    local c = (i + 2 <= #s) and s:byte(i + 2) or 0
    local n = a * 0x10000 + b * 0x100 + c
    -- Split the 24-bit group into four 6-bit sextets.
    local x1 = math.floor(n / 0x40000)            -- n >> 18
    local x2 = math.floor(n / 0x1000) % 0x40      -- (n >> 12) & 0x3F
    local x3 = math.floor(n / 0x40) % 0x40        -- (n >> 6)  & 0x3F
    local x4 = n % 0x40                           -- n & 0x3F
    table.insert(out, b64chars:sub(x1 + 1, x1 + 1))
    table.insert(out, b64chars:sub(x2 + 1, x2 + 1))
    if i + 1 <= #s then
      table.insert(out, b64chars:sub(x3 + 1, x3 + 1))
    else
      table.insert(out, "=")
    end
    if i + 2 <= #s then
      table.insert(out, b64chars:sub(x4 + 1, x4 + 1))
    else
      table.insert(out, "=")
    end
    i = i + 3
  end
  return table.concat(out)
end

-- Core request helper. Returns the decoded JSON body (or nil for empty
-- responses like 204). Raises an error object of the appropriate kind for
-- non-2xx or network failures, and for a non-empty body that is not valid JSON.
function Client:_request(method, path, body)
  local headers = {}
  if self._auth_header then
    headers["Authorization"] = self._auth_header
  end

  local status, resp_body = http_request(self.url, method, path, headers, body)

  if status >= 200 and status < 300 then
    -- Empty body (e.g. 204 No Content) is a valid "nothing to return".
    if resp_body == nil or resp_body == "" then
      return nil
    end
    local decoded, err = json.decode(resp_body)
    if decoded == nil and err ~= nil then
      error(make_error(M.errors.query,
        "malformed JSON response: " .. tostring(err)), 2)
    end
    return decoded
  end

  local message, code, op_index = parse_error_envelope(resp_body)
  if message == "" then message = "Server error (" .. status .. ")" end
  local kind = kind_for_status(status)
  if message:sub(1, 10) == "not found:" then kind = M.errors.not_found end
  error(make_error(kind, message,
    { error_code = code, op_index = op_index, status = status }), 2)
end

-- Internal: POST a JSON payload.
function Client:_post(path, payload)
  local body, err = json.encode(payload)
  if not body then
    error(make_error(M.errors.query, "request payload cannot be JSON-encoded: " .. tostring(err)), 2)
  end
  return self:_request("POST", path, body)
end

-- -- Public API ------------------------------------------------------------

--- Check daemon health. Returns true on success, false on failure.
function Client:health()
  local ok = pcall(function() return self:_request("GET", "health") end)
  return ok
end

--- List all table names.
function Client:tableNames()
  local data = self:_request("GET", "tables")
  if type(data) == "table" then return data end
  return {}
end

local function retention(data)
  if type(data) ~= "table" or type(data.history_retention_epochs) ~= "number"
      or type(data.earliest_retained_epoch) ~= "number" then
    error(make_error(M.errors.query, "malformed history retention response"), 2)
  end
  return data
end

function Client:setHistoryRetentionEpochs(epochs)
  local body, err = json.encode({ history_retention_epochs = epochs })
  if not body then
    error(make_error(M.errors.query,
      "history retention payload cannot be JSON-encoded: " .. tostring(err)), 2)
  end
  return retention(self:_request("PUT", "history/retention", body))
end

function Client:historyRetention()
  return retention(self:_request("GET", "history/retention"))
end

function Client:historyRetentionEpochs() return self:historyRetention().history_retention_epochs end
function Client:earliestRetainedEpoch() return self:historyRetention().earliest_retained_epoch end

--- Build the JSON request body for `POST /kit/create_table`.
-- Exposed on the module so wire-shape conformance tests can assert the
-- exact on-wire keys (`enum_variants`, `default_value`, ...) without
-- standing up a daemon or a socket mock. The helper is the single source
-- of truth for the payload; Client:createTable delegates to it.
function M._build_create_table_body(name, columns, constraints)
  local payload = { name = name, columns = columns }
  if constraints ~= nil then payload.constraints = constraints end
  local body, err = json.encode(payload)
  if not body then
    error(make_error(M.errors.query,
      "request payload cannot be JSON-encoded: " .. tostring(err)), 2)
  end
  return body
end

--- Create a table. Returns the new table id, or 0 if none was reported.
function Client:createTable(name, columns, constraints)
  local body = M._build_create_table_body(name, columns, constraints)
  local data = self:_request("POST", "kit/create_table", body)
  if type(data) == "table" then return data.table_id or 0 end
  return 0
end

--- Drop a table by name.
function Client:dropTable(name)
  self:_request("DELETE", "tables/" .. encode_path_segment(name))
end

--- Row count for a table.
function Client:count(table_name)
  local data = self:_request("GET", "tables/" .. encode_path_segment(table_name) .. "/count")
  if type(data) == "table" and type(data.count) == "number" then
    return data.count
  end
  error(make_error(M.errors.query, "malformed count response"), 2)
end

--- Insert a row. cells maps column id to value ({[1] = 1, [2] = "Alice"}).
function Client:put(table_name, cells)
  local data = self:_post("kit/txn", {
    ops = {
      { put = { table = table_name, cells = cells_to_flat(cells) } },
    },
  })
  if type(data) == "table" and type(data.results) == "table" then
    return data.results[1] or {}
  end
  return {}
end

--- Upsert (insert or update on PK conflict).
function Client:upsert(table_name, cells, update_cells)
  local op = { table = table_name, cells = cells_to_flat(cells) }
  if update_cells then
    op.update_cells = cells_to_flat(update_cells)
  end
  local data = self:_post("kit/txn", {
    ops = { { upsert = op } },
  })
  if type(data) == "table" and type(data.results) == "table" then
    return data.results[1] or {}
  end
  return {}
end

--- Delete a row by its internal row id.
function Client:delete(table_name, row_id)
  self:_post("kit/txn", {
    ops = { { delete = { table = table_name, row_id = row_id } } },
  })
end

--- Delete a row by its primary key value.
function Client:deleteByPk(table_name, pk)
  self:_post("kit/txn", {
    ops = { { delete_by_pk = { table = table_name, pk = pk } } },
  })
end

--- Execute SQL. Requests the JSON result format, so a SELECT returns a JSON
--- array of row objects keyed by column name. Returns decoded rows for SELECTs,
--- or an empty table for statements (INSERT/UPDATE) that produce no rows.
function Client:sql(statement)
  -- An old server may ignore the requested JSON format and answer with Arrow
  -- IPC binary bytes (not valid JSON), which _post surfaces as a "malformed
  -- JSON response" error. Treat that specific case as "no rows" rather than
  -- raising, so callers keep working against legacy servers. Genuine server
  -- errors (auth, constraint, HTTP 5xx, ...) still propagate.
  local ok, data = pcall(self._post, self, "sql",
    { sql = statement, format = "json" })
  if ok then
    return type(data) == "table" and data or {}
  end
  local err = data
  local msg = type(err) == "table" and err.message or tostring(err)
  if msg and msg:find("malformed JSON") then
    io.stderr:write("mongreldb.sql warning: response was not valid JSON; returning empty result\n")
    return {}
  end
  error(err, 2)
end

--- Run a native query. conditions is a list of {type = params} tables.
--- Optional: projection (array of column ids), limit (int).
function Client:query(table_name, conditions, opts)
  opts = opts or {}
  local payload = { table = table_name }
  if conditions and #conditions > 0
     and next(conditions) ~= nil then
    payload.conditions = conditions
  end
  if opts.projection then payload.projection = opts.projection end
  if opts.limit then payload.limit = opts.limit end
  local data = self:_post("kit/query", payload)
  if type(data) == "table" then
    return data.rows or {}, data.truncated or false
  end
  return {}, false
end

--- Build a normalized condition (translates friendly aliases).
function M.condition(cond_type, params)
  return { [cond_type] = normalize_condition(cond_type, params) }
end

--- Full schema catalog.
function Client:schema()
  local data = self:_request("GET", "kit/schema")
  if type(data) == "table" then return data.tables or {} end
  return {}
end

--- Descriptor for a single table.
function Client:schemaFor(table_name)
  local data = self:_request("GET", "kit/schema/" .. encode_path_segment(table_name))
  if type(data) == "table" then return data end
  return {}
end

--- Compact all tables.
function Client:compact()
  local data = self:_post("compact", {})
  if type(data) == "table" then return data end
  return {}
end

--- Stage and commit a batch transaction atomically.
-- ops is a list of {put = {...}}, {upsert = {...}}, {delete = {...}},
-- {delete_by_pk = {...}} tables.
-- Optional idempotency_key for safe retries.
function Client:transaction(ops, idempotency_key)
  local payload = { ops = ops }
  if idempotency_key then
    payload.idempotency_key = idempotency_key
  end
  local data = self:_post("kit/txn", payload)
  if type(data) == "table" then return data.results or {} end
  return {}
end

-- Re-export the json module and error kinds for callers.
M.json = json

return M
