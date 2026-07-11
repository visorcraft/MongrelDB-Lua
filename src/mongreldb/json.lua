-- Minimal JSON encoder/decoder for the MongrelDB Lua client.
--
-- Self-contained: no external dependencies. The encoder produces compact JSON
-- suitable for the daemon's Content-Type: application/json extractors, and
-- rejects NaN/Infinity (no valid JSON representation) with an error. The
-- decoder is a tolerant recursive parser that accepts the daemon's responses.

local json = {}
json.null = setmetatable({}, { __tostring = function() return "null" end })

-- Detect NaN without depending on math.huge comparisons elsewhere.
local function is_nan(v)
  return type(v) == "number" and v ~= v
end

local function is_inf(v)
  return type(v) == "number" and (v == math.huge or v == -math.huge)
end

local encode_string

local function encode_value(v, out)
  if v == json.null then
    table.insert(out, "null")
    return
  end
  local t = type(v)
  if t == "nil" then
    table.insert(out, "null")
  elseif t == "boolean" then
    table.insert(out, v and "true" or "false")
  elseif t == "number" then
    if is_nan(v) or is_inf(v) then
      error("cannot JSON-encode NaN or Infinity")
    end
    -- Integer-valued numbers print without a decimal point on most Lua builds.
    if math.floor(v) == v and math.abs(v) < 1e15 then
      table.insert(out, string.format("%d", v))
    else
      table.insert(out, string.format("%.17g", v))
    end
  elseif t == "string" then
    encode_string(v, out)
  elseif t == "table" then
    -- Heuristic: a table is an object if it has no positive integer keys, or
    -- if it has at least one string key. Otherwise it is an array.
    local is_array = true
    local count = 0
    for k in pairs(v) do
      count = count + 1
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false
        break
      end
    end
    if count == 0 and next(v) == nil then
      -- Empty table: encode as object {} (the daemon expects objects for ops).
      is_array = false
    end

    if is_array then
      table.insert(out, "[")
      local keys = {}
      for k in pairs(v) do table.insert(keys, k) end
      table.sort(keys)
      for i, k in ipairs(keys) do
        if i > 1 then table.insert(out, ",") end
        encode_value(v[k], out)
      end
      table.insert(out, "]")
    else
      table.insert(out, "{")
      local first = true
      local keys = {}
      for k in pairs(v) do table.insert(keys, k) end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for _, k in ipairs(keys) do
        if not first then table.insert(out, ",") end
        first = false
        encode_string(tostring(k), out)
        table.insert(out, ":")
        encode_value(v[k], out)
      end
      table.insert(out, "}")
    end
  else
    error("cannot JSON-encode value of type " .. t)
  end
end

function encode_string(s, out)
  local r = { '"' }
  for i = 1, #s do
    local b = string.byte(s, i)
    if b == 0x22 then      table.insert(r, '\\"')      -- "
    elseif b == 0x5C then  table.insert(r, "\\\\")     -- backslash
    elseif b == 0x0A then  table.insert(r, "\\n")      -- LF
    elseif b == 0x0D then  table.insert(r, "\\r")      -- CR
    elseif b == 0x09 then  table.insert(r, "\\t")      -- tab
    elseif b == 0x08 then  table.insert(r, "\\b")
    elseif b == 0x0C then  table.insert(r, "\\f")
    elseif b < 0x20 then
      table.insert(r, string.format("\\u%04x", b))
    elseif b < 0x80 then
      table.insert(r, string.char(b))
    else
      -- Pass multi-byte UTF-8 sequences through unchanged. Malformed bytes
      -- become U+FFFD on the daemon side.
      table.insert(r, string.char(b))
    end
  end
  table.insert(r, '"')
  for _, part in ipairs(r) do table.insert(out, part) end
end

--- Encode a Lua value to a JSON string.
function json.encode(v)
  local out = {}
  local ok, err = pcall(encode_value, v, out)
  if not ok then
    return nil, err
  end
  return table.concat(out)
end

-- -- Decoder ---------------------------------------------------------------

local Decoder = {}
Decoder.__index = Decoder

function Decoder:new(s)
  return setmetatable({ s = s, i = 1 }, self)
end

function Decoder:peek()
  return self.s:sub(self.i, self.i)
end

function Decoder:next()
  local c = self.s:sub(self.i, self.i)
  self.i = self.i + 1
  return c
end

function Decoder:skip_ws()
  while self.i <= #self.s do
    local c = self.s:sub(self.i, self.i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      self.i = self.i + 1
    else
      break
    end
  end
end

function Decoder:parse_value()
  self:skip_ws()
  local c = self:peek()
  if c == "{" then return self:parse_object()
  elseif c == "[" then return self:parse_array()
  elseif c == '"' then return self:parse_string()
  elseif c == "t" or c == "f" then return self:parse_bool()
  elseif c == "n" then return self:parse_null()
  elseif c == "-" or (c >= "0" and c <= "9") then return self:parse_number()
  else
    error("unexpected character '" .. (c or "") .. "' at position " .. self.i)
  end
end

function Decoder:parse_object()
  self.i = self.i + 1 -- {
  local obj = {}
  self:skip_ws()
  if self:peek() == "}" then
    self.i = self.i + 1
    return obj
  end
  while true do
    self:skip_ws()
    local key = self:parse_string()
    self:skip_ws()
    if self:next() ~= ":" then error("expected ':' in object") end
    obj[key] = self:parse_value()
    self:skip_ws()
    local sep = self:next()
    if sep == "}" then break
    elseif sep ~= "," then error("expected ',' or '}' in object") end
  end
  return obj
end

function Decoder:parse_array()
  self.i = self.i + 1 -- [
  local arr = {}
  self:skip_ws()
  if self:peek() == "]" then
    self.i = self.i + 1
    return arr
  end
  while true do
    table.insert(arr, self:parse_value())
    self:skip_ws()
    local sep = self:next()
    if sep == "]" then break
    elseif sep ~= "," then error("expected ',' or ']' in array") end
  end
  return arr
end

function Decoder:parse_string()
  if self:next() ~= '"' then error("expected '\"' to start string") end
  local parts = {}
  while self.i <= #self.s do
    local c = self:next()
    if c == '"' then
      return table.concat(parts)
    elseif c == "\\" then
      local esc = self:next()
      if esc == '"' then table.insert(parts, '"')
      elseif esc == "\\" then table.insert(parts, "\\")
      elseif esc == "/" then table.insert(parts, "/")
      elseif esc == "n" then table.insert(parts, "\n")
      elseif esc == "r" then table.insert(parts, "\r")
      elseif esc == "t" then table.insert(parts, "\t")
      elseif esc == "b" then table.insert(parts, "\b")
      elseif esc == "f" then table.insert(parts, "\f")
      elseif esc == "u" then
        local hex = self.s:sub(self.i, self.i + 3)
        self.i = self.i + 4
        local cp = tonumber(hex, 16)
        if cp < 0x80 then
          table.insert(parts, string.char(cp))
        else
          -- Re-encode as UTF-8. Good enough for the BMP range the daemon emits.
          if cp < 0x800 then
            table.insert(parts, string.char(0xC0 + math.floor(cp / 0x40),
              0x80 + (cp % 0x40)))
          else
            table.insert(parts, string.char(0xE0 + math.floor(cp / 0x1000),
              0x80 + (math.floor(cp / 0x40) % 0x40),
              0x80 + (cp % 0x40)))
          end
        end
      else
        error("invalid escape \\" .. esc)
      end
    else
      table.insert(parts, c)
    end
  end
  error("unterminated string")
end

function Decoder:parse_number()
  local start = self.i
  if self:peek() == "-" then self.i = self.i + 1 end
  while self.i <= #self.s do
    local c = self.s:sub(self.i, self.i)
    if (c >= "0" and c <= "9") or c == "." or c == "e" or c == "E"
       or c == "+" or c == "-" then
      self.i = self.i + 1
    else
      break
    end
  end
  return tonumber(self.s:sub(start, self.i - 1))
end

function Decoder:parse_bool()
  if self.s:sub(self.i, self.i + 3) == "true" then
    self.i = self.i + 4
    return true
  elseif self.s:sub(self.i, self.i + 4) == "false" then
    self.i = self.i + 5
    return false
  end
  error("invalid literal at position " .. self.i)
end

function Decoder:parse_null()
  if self.s:sub(self.i, self.i + 3) == "null" then
    self.i = self.i + 4
    return nil
  end
  error("invalid literal at position " .. self.i)
end

--- Decode a JSON string to a Lua value.
function json.decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local d = Decoder:new(s)
  local ok, value = pcall(function() return d:parse_value() end)
  if not ok then return nil, value end
  d:skip_ws()
  if d.i <= #d.s then
    return nil, "trailing data after JSON value at position " .. d.i
  end
  return value
end

return json
