package = "mongreldb"
version = "0.64.5-1"

source = {
  url = "git://github.com/visorcraft/MongrelDB-Lua.git",
  tag = "v0.64.5",
}

description = {
  summary = "Pure Lua HTTP client for MongrelDB.",
  detailed = [[
Pure Lua HTTP client for the MongrelDB server database with SQL, vector search,
full-text search, and AI-native retrieval. Talks JSON over the Kit transaction,
query, and SQL endpoints of a running mongreldb-server daemon. Built on
LuaSocket with a vendored JSON encoder, so the only external runtime dependency
is luasocket.
]],
  homepage = "https://www.mongreldb.com",
  license = "MIT OR Apache-2.0",
  issues_url = "https://github.com/visorcraft/MongrelDB-Lua/issues",
  maintainer = "visorcraft",
  labels = { "database", "sql", "embedded-database", "lua" },
}

dependencies = {
  "lua >= 5.3",
  "luasocket >= 3.0",
}

supported_platforms = { "unix", "linux", "macosx", "win32" }

build = {
  type = "builtin",
  modules = {
    ["mongreldb"] = "src/mongreldb/init.lua",
    ["mongreldb.json"] = "src/mongreldb/json.lua",
  },
  copy_directories = { "tests", "docs", "assets" },
}
