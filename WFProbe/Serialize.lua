local _, ns = ...

-- Renders values as readable Lua table text for the copy/paste export.

local MAX_DEPTH = 12
local MAX_ARRAY = 50

local function quote(s)
  -- "|" becomes \124 so item links and colour codes copy out as plain text.
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("|", "\\124")
  return '"' .. s .. '"'
end

local function scalar(v)
  if ns.isSecret(v) then return '"<secret ' .. type(v) .. '>"' end
  local tv = type(v)
  if tv == "string" then return quote(v) end
  if tv == "number" then
    if v % 1 ~= 0 then return string.format("%.4f", v) end
    return tostring(v)
  end
  if tv == "boolean" or tv == "nil" then return tostring(v) end
  return '"<' .. tv .. '>"'
end

-- Function fields are skipped so mixins (e.g. Vector2D positions) print as data.
local function sortedKeys(t)
  local keys = {}
  for k, v in pairs(t) do
    if type(v) ~= "function" then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function key(k)
  if type(k) == "string" and k:match("^[%a_][%w_]*$") then return k end
  return "[" .. scalar(k) .. "]"
end

local function write(buf, v, depth, seen)
  if type(v) ~= "table" or ns.isSecret(v) then
    buf[#buf + 1] = scalar(v)
    return
  end
  if seen[v] then buf[#buf + 1] = '"<cycle>"' return end
  if depth >= MAX_DEPTH then buf[#buf + 1] = '"<max depth>"' return end

  local keys = sortedKeys(v)
  if #keys == 0 then buf[#buf + 1] = "{}" return end

  seen[v] = true
  local isArray = #v == #keys
  local pad = string.rep("  ", depth + 1)
  local shown = isArray and math.min(#keys, MAX_ARRAY) or #keys
  buf[#buf + 1] = "{\n"
  for i = 1, shown do
    local k = keys[i]
    buf[#buf + 1] = pad
    if not isArray then buf[#buf + 1] = key(k) .. " = " end
    write(buf, v[k], depth + 1, seen)
    buf[#buf + 1] = ",\n"
  end
  if shown < #keys then
    buf[#buf + 1] = pad .. "-- ... " .. (#keys - shown) .. " more\n"
  end
  buf[#buf + 1] = string.rep("  ", depth) .. "}"
  seen[v] = nil
end

function ns.serialize(v)
  local buf = {}
  write(buf, v, 0, {})
  return table.concat(buf)
end
