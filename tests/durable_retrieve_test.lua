-- Offline unit tests for 0.64 durable HLC recovery and retrieve_text wire shape.
--
--   lua tests/durable_retrieve_test.lua

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

local function assert_equal(a, b, msg)
  if a ~= b then
    error((msg or "not equal") .. ": got " .. tostring(a)
      .. ", expected " .. tostring(b))
  end
end

local fixture = {
  query_id = "abcdefabcdefabcdefabcdefabcdefab",
  status = "committed",
  state = "completed",
  server_state = "completed",
  terminal_state = "committed",
  operation = "INSERT",
  committed = true,
  committed_statements = 1,
  last_commit_epoch = 17,
  last_commit_epoch_text = "17",
  last_commit_hlc = {
    physical_micros = 1700000000000000,
    logical = 3,
    node_tiebreaker = 7,
  },
  first_commit_statement_index = 0,
  last_commit_statement_index = 0,
  completed_statements = 1,
  statement_index = 0,
  cancel_outcome = nil,
  cancellation_reason = "none",
  retryable = false,
  outcome = {
    committed = true,
    committed_statements = 1,
    last_commit_epoch = 17,
    last_commit_epoch_text = "17",
    last_commit_hlc = {
      physical_micros = 1700000000000000,
      logical = 3,
      node_tiebreaker = 7,
    },
    first_commit_statement_index = 0,
    last_commit_statement_index = 0,
    completed_statements = 1,
    statement_index = 0,
    serialization = "succeeded",
    serialization_state = "succeeded",
    terminal_state = "committed",
  },
  durable = {
    committed = true,
    committed_statements = 1,
    last_commit_epoch = 17,
    last_commit_epoch_text = "17",
    last_commit_hlc = {
      physical_micros = 1700000000000000,
      logical = 3,
      node_tiebreaker = 7,
    },
    first_commit_statement_index = 0,
    last_commit_statement_index = 0,
    completed_statements = 1,
    statement_index = 0,
    serialization = "succeeded",
    serialization_state = "succeeded",
    terminal_state = "committed",
  },
  terminal_error = nil,
}

check("parse_query_status structural HLC", function()
  local status = mongreldb.parse_query_status(fixture)
  assert_equal(status.committed, true)
  local hlc = status:commit_hlc()
  assert(hlc ~= nil, "commit_hlc is nil")
  assert_equal(hlc.physical_micros, 1700000000000000)
  assert_equal(hlc.logical, 3)
  assert_equal(hlc.node_tiebreaker, 7)
  assert_equal(status:serialization_state(), "succeeded")
  assert_equal(status.outcome.last_commit_epoch, 17)
end)

check("parse_commit_hlc rejects missing physical_micros", function()
  assert_equal(mongreldb.parse_commit_hlc(nil), nil)
  assert_equal(mongreldb.parse_commit_hlc({}), nil)
  assert_equal(mongreldb.parse_commit_hlc({ logical = 1 }), nil)
end)

check("retrieve_text payload shape via build (manual)", function()
  -- Wire shape for POST kit/retrieve_text
  local payload = {
    table = "docs",
    embedding_column = 3,
    text = "cat sat",
    k = 5,
  }
  local enc = mongreldb.json.encode(payload)
  local dec = mongreldb.json.decode(enc)
  assert_equal(dec.table, "docs")
  assert_equal(dec.embedding_column, 3)
  assert_equal(dec.text, "cat sat")
  assert_equal(dec.k, 5)
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failures))
if failures > 0 then os.exit(1) end
