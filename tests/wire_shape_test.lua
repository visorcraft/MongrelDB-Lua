-- Wire-shape conformance tests for the MongrelDB Lua client.
--
-- The /kit/create_table endpoint accepts a rich column descriptor that
-- includes `enum_variants`, scalar `default_value`, and dynamic
-- `default_expr`. These tests pin the JSON the Lua client emits so a
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
local socket = require("socket")

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

-- Returns true if the quoted key appears anywhere in the JSON body.
-- This is a simple substring check, not a token-level parser: it can
-- match partial keys (e.g. "enum_variants_other" contains
-- "enum_variants"). It is sufficient here because the emitted JSON is
-- compact and the keys under test are distinct enough in practice.
local function json_contains_key(body, key)
  return body:find('"' .. key .. '"') ~= nil
end

-- Replace socket.connect with a fake transport that records each request and
-- returns the queued HTTP responses. This lets the unit test assert the exact
-- method, path, body, and response handling of the retention methods without
-- standing up a real daemon.
local function mock_socket(responses)
  local orig_connect = socket.connect
  local state = { requests = {}, index = 1 }

  socket.connect = function(host, port)
    local req = { host = host, port = port, raw = "" }
    table.insert(state.requests, req)
    local conn = {}
    function conn.settimeout(_, _) end
    function conn.send(_, data)
      req.raw = req.raw .. data
      return #data, nil
    end
    function conn.receive(_, _)
      local entry = responses[state.index]
      if not entry then
        return nil, "closed", ""
      end
      if not req.response_sent then
        req.response_sent = true
        state.index = state.index + 1
        local body = entry.body or ""
        local status_text = entry.status_text or "OK"
        local lines = {
          "HTTP/1.1 " .. tostring(entry.status) .. " " .. status_text,
          "Content-Type: application/json",
          "Content-Length: " .. #body,
          "Connection: close",
          "",
          body,
        }
        return table.concat(lines, "\r\n")
      end
      return nil, "closed", ""
    end
    function conn.close(_) end
    return conn
  end

  return state, function() socket.connect = orig_connect end
end

local function parse_request(raw)
  local method, path = raw:match("^(%S+)%s+(%S+)%s+HTTP")
  local body = raw:match("\r\n\r\n(.*)$") or raw:match("\n\n(.*)$") or ""
  return method, path, body
end

check("createTable body preserves enum, static-default, and dynamic-default fields", function()
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
      default_expr = "now",
    },
    {
      id = 4,
      name = "attempts",
      ty = "int64",
      default_value = 3,
    },
    { id = 5, name = "s", ty = "varchar", default_value = "draft" },
    { id = 6, name = "b", ty = "bool", default_value = true },
    { id = 7, name = "n", ty = "varchar", default_value = mongreldb.null },
    {
      id = 8,
      name = "embedding",
      ty = "embedding(384)",
      embedding_source = {
        kind = "configured_model",
        provider_id = "docs",
        model_id = "model",
        model_version = "1",
      },
    },
  }
  local constraints = {
    checks = {
      { id = 1, name = "id_present", expr = { IsNotNull = 1 } },
    },
  }
  local indexes = {
    { name = "bm", column_id = 2, kind = "bitmap" },
    { name = "fm", column_id = 2, kind = "fm_index" },
    {
      name = "ann",
      column_id = 8,
      kind = "ann",
      predicate = "embedding IS NOT NULL",
      options = { ann = { m = 24, ef_construction = 96, ef_search = 48, quantization = "dense",
        algorithm = "diskann", diskann = { r = 64, l = 128, beam_width = 8, alpha = 120 } } },
    },
    { name = "range", column_id = 4, kind = "learned_range" },
    { name = "minhash", column_id = 2, kind = "minhash" },
    { name = "sparse", column_id = 2, kind = "sparse" },
  }
  local body = mongreldb._build_create_table_body("orders", columns, constraints, indexes)
  assert_true(json_contains_key(body, "enum_variants"),
    "enum_variants should appear verbatim in the JSON body")
  assert_true(json_contains_key(body, "default_value"),
    "default_value should appear verbatim in the JSON body")
  assert_true(body:find('"default_value":3') ~= nil,
    "default_value should preserve its numeric JSON type")
  assert_true(body:find('"default_expr":"now"') ~= nil,
    "default_expr should appear verbatim in the JSON body")
  assert_true(body:find('"default_value":"draft"') ~= nil, "string default missing")
  assert_true(body:find('"default_value":true') ~= nil, "bool default missing")
  assert_true(body:find('"default_value":null') ~= nil, "null default missing")
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
  assert_true(body:find('"embedding_source"') ~= nil, "embedding source missing")
  for _, kind in ipairs({ "bitmap", "fm_index", "ann", "learned_range", "minhash", "sparse" }) do
    assert_true(body:find('"kind":"' .. kind .. '"') ~= nil, kind .. " index missing")
  end
  assert_true(body:find('"quantization":"dense"') ~= nil, "Dense ANN missing")
  assert_true(body:find('"algorithm":"diskann"') ~= nil, "DiskANN algorithm missing")
  assert_true(body:find('"beam_width":8') ~= nil, "DiskANN options missing")
  assert_true(body:find('"predicate":"embedding IS NOT NULL"') ~= nil,
    "index predicate missing")
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

check("createTable body encodes the full static-default matrix as typed JSON", function()
  local columns = {
    { id = 1, name = "s", ty = "varchar", default_value = "draft" },
    { id = 2, name = "i", ty = "int64", default_value = 7 },
    { id = 3, name = "b", ty = "bool", default_value = true },
    { id = 4, name = "n", ty = "varchar", default_value = mongreldb.null },
    { id = 5, name = "literal_now", ty = "varchar", default_value = "now" },
    { id = 6, name = "dyn_now", ty = "timestamp_nanos", default_expr = "now" },
    { id = 7, name = "dyn_uuid", ty = "uuid", default_expr = "uuid" },
  }
  local body = mongreldb._build_create_table_body("defaults_matrix", columns)
  local decoded = mongreldb.json.decode(body)
  assert_equal(type(decoded), "table", "decoded body should be an object")
  assert_equal(decoded.name, "defaults_matrix", "table name should round-trip")

  local by_name = {}
  for _, col in ipairs(decoded.columns) do
    by_name[col.name] = col
  end

  assert_equal(by_name.s.default_value, "draft", "string default")
  assert_equal(by_name.i.default_value, 7, "integer default")
  assert_equal(by_name.b.default_value, true, "boolean default")
  -- Lua cannot represent JSON null in a table, so the decoded value is nil.
  -- Prove the key was emitted by inspecting the raw encoded body.
  assert_equal(body:find('"default_value":null') ~= nil, true,
    "explicit null sentinel should encode as JSON null")
  assert_equal(by_name.n.default_value, nil,
    "decoded null sentinel becomes Lua nil")
  -- Literal "now" must remain a static string default, not become default_expr.
  assert_equal(by_name.literal_now.default_value, "now",
    "literal now should stay a string default_value")
  assert_equal(by_name.literal_now.default_expr, nil,
    "literal now must not set default_expr")
  -- Dynamic defaults must use default_expr and omit default_value.
  assert_equal(by_name.dyn_now.default_expr, "now", "now default_expr")
  assert_equal(by_name.dyn_now.default_value, nil,
    "default_expr column has no default_value")
  assert_equal(by_name.dyn_uuid.default_expr, "uuid", "uuid default_expr")
  assert_equal(by_name.dyn_uuid.default_value, nil,
    "uuid default_expr has no default_value")
end)

check("setHistoryRetentionEpochs sends PUT /history/retention with the correct body", function()
  local responses = {
    { status = 200, body = '{"history_retention_epochs":7,"earliest_retained_epoch":3}' },
  }
  local captured, restore = mock_socket(responses)
  local ok, test_err = pcall(function()
    local db = mongreldb.connect("http://127.0.0.1:9999")
    local result = db:setHistoryRetentionEpochs(42)
    assert_equal(#captured.requests, 1, "exactly one request should be sent")
    local method, path, body = parse_request(captured.requests[1].raw)
    assert_equal(method, "PUT", "method should be PUT")
    assert_equal(path, "/history/retention", "path should be /history/retention")
    local parsed_body = mongreldb.json.decode(body)
    assert_equal(type(parsed_body), "table", "body should decode to an object")
    assert_equal(parsed_body.history_retention_epochs, 42,
      "body key should be history_retention_epochs")
    assert_equal(type(result), "table", "result should be a table")
    assert_equal(result.history_retention_epochs, 7,
      "response history_retention_epochs should be decoded")
    assert_equal(result.earliest_retained_epoch, 3,
      "response earliest_retained_epoch should be decoded")
  end)
  restore()
  if not ok then error(test_err) end
end)

check("historyRetentionEpochs and earliestRetainedEpoch send GET /history/retention", function()
  local responses = {
    { status = 200, body = '{"history_retention_epochs":7,"earliest_retained_epoch":3}' },
    { status = 200, body = '{"history_retention_epochs":7,"earliest_retained_epoch":3}' },
  }
  local captured, restore = mock_socket(responses)
  local ok, test_err = pcall(function()
    local db = mongreldb.connect("http://127.0.0.1:9999")
    local epochs = db:historyRetentionEpochs()
    local earliest = db:earliestRetainedEpoch()
    assert_equal(epochs, 7, "historyRetentionEpochs should return the field")
    assert_equal(earliest, 3, "earliestRetainedEpoch should return the field")
    assert_equal(#captured.requests, 2, "each getter should send one request")
    for _, req in ipairs(captured.requests) do
      local method, path = parse_request(req.raw)
      assert_equal(method, "GET", "getter method should be GET")
      assert_equal(path, "/history/retention", "getter path should be /history/retention")
    end
  end)
  restore()
  if not ok then error(test_err) end
end)

check("history retention methods propagate non-2xx responses as errors", function()
  local error_body = '{"error":{"message":"down for maintenance","code":"UNAVAILABLE"}}'
  local responses = {
    { status = 503, status_text = "Service Unavailable", body = error_body },
    { status = 503, status_text = "Service Unavailable", body = error_body },
    { status = 503, status_text = "Service Unavailable", body = error_body },
  }
  local _, restore = mock_socket(responses)
  local ok, test_err = pcall(function()
    local db = mongreldb.connect("http://127.0.0.1:9999")
    local threw, err = false, nil
    local function catch(fn)
      return pcall(function() fn() end)
    end
    local cok, cerr = catch(function() db:historyRetentionEpochs() end)
    if not cok then threw = true; err = cerr end
    assert_equal(threw, true, "historyRetentionEpochs should throw on 503")
    assert_equal(type(err), "table", "error should be a typed table")
    assert_equal(err.status, 503, "error should carry the HTTP status")

    threw, err = false, nil
    cok, cerr = catch(function() db:earliestRetainedEpoch() end)
    if not cok then threw = true; err = cerr end
    assert_equal(threw, true, "earliestRetainedEpoch should throw on 503")
    assert_equal(err.status, 503, "error should carry the HTTP status")

    threw, err = false, nil
    cok, cerr = catch(function() db:setHistoryRetentionEpochs(42) end)
    if not cok then threw = true; err = cerr end
    assert_equal(threw, true, "setHistoryRetentionEpochs should throw on 503")
    assert_equal(err.status, 503, "error should carry the HTTP status")
  end)
  restore()
  if not ok then error(test_err) end
end)

io.write("\n")
print(string.format("passed: %d, failed: %d", passed, failures))
os.exit(failures == 0 and 0 or 1)
