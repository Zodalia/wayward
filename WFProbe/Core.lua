local ADDON, ns = ...

ns.VERSION = "0.2.0"
ns.MAX_SAMPLES = 5

function ns.print(msg)
  print("|cff4fc3f7WFProbe:|r " .. tostring(msg))
end

local function pack(...)
  return { n = select("#", ...), ... }
end

-- Midnight-era clients hand addons "secret" values that error on most operations.
function ns.isSecret(v)
  if type(issecretvalue) ~= "function" then return false end
  local ok, res = pcall(issecretvalue, v)
  return ok and res == true
end

local function resolve(path)
  local obj = _G
  for part in path:gmatch("[^%.]+") do
    if type(obj) ~= "table" then return nil end
    obj = obj[part]
  end
  return obj
end

local function isEmpty(v)
  if ns.isSecret(v) then return false end
  local ok, empty = pcall(function()
    return v == nil or (type(v) == "table" and next(v) == nil)
  end)
  return ok and empty
end

-- Calls a global API by dotted path ("C_Map.GetMapInfo") and records whether it
-- is missing, errors, returns nothing, or returns data.
function ns.try(path, ...)
  local fn = resolve(path)
  if type(fn) ~= "function" then
    return { status = "missing" }
  end
  local r = pack(pcall(fn, ...))
  if not r[1] then
    return { status = "error", err = tostring(r[2]) }
  end
  if r.n <= 2 then
    return { status = isEmpty(r[2]) and "empty" or "ok", value = r[2] }
  end
  local values = {}
  for i = 2, r.n do values[i - 1] = r[i] end
  return { status = "ok", values = values }
end

-- First return value of an API call, or nil if it is missing or errors.
function ns.get(path, ...)
  local rec = ns.try(path, ...)
  if rec.values then return rec.values[1] end
  return rec.value
end

-- Keeps reports small: a count plus the first few (optionally mapped) entries.
function ns.sample(list, n, mapFn)
  if type(list) ~= "table" or ns.isSecret(list) then return list end
  local out = { count = #list, samples = {} }
  for i = 1, math.min(#list, n or ns.MAX_SAMPLES) do
    local item = list[i]
    if mapFn then
      local ok, mapped = pcall(mapFn, item, i)
      item = ok and mapped or ("<error: " .. tostring(mapped) .. ">")
    end
    out.samples[i] = item
  end
  return out
end

function ns.listFunctions(name)
  local t = _G[name]
  if type(t) ~= "table" then return "<missing>" end
  local names = {}
  for k, v in pairs(t) do
    if type(v) == "function" then names[#names + 1] = k end
  end
  table.sort(names)
  return table.concat(names, ", ")
end

local unpack = unpack or table.unpack
local READ_ONLY = { "Get", "Is", "Has", "Can", "Fetch", "Should", "Does", "Are" }

local function isReadOnly(name)
  for _, prefix in ipairs(READ_ONLY) do
    if name:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function describe(rec)
  if rec.status ~= "ok" then return rec.status end
  local v = rec.value
  if rec.values then v = rec.values[1] end
  if ns.isSecret(v) then return "ok(secret)" end
  if type(v) == "table" then
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return "ok(table:" .. n .. ")"
  end
  return "ok(" .. tostring(v) .. ")"
end

-- Discovers what an unfamiliar namespace returns: calls every read-style
-- function (Get*/Is*/Has*/...) with each argument set and summarises the result.
-- Only the first successful result per function is kept, sampled.
function ns.explore(nsName, argSets)
  local t = _G[nsName]
  if type(t) ~= "table" then return { status = "missing" } end
  local out, labels = {}, {}
  for label in pairs(argSets) do labels[#labels + 1] = label end
  table.sort(labels)
  for name, fn in pairs(t) do
    if type(fn) == "function" and isReadOnly(name) then
      local parts, firstOk = {}, nil
      for _, label in ipairs(labels) do
        local rec = ns.try(nsName .. "." .. name, unpack(argSets[label]))
        parts[#parts + 1] = label .. "=" .. describe(rec)
        if rec.status == "ok" and not firstOk then
          firstOk = rec.values or rec.value
          if type(firstOk) == "table" then firstOk = ns.sample(firstOk, 3) end
        end
      end
      out[name] = firstOk ~= nil and { calls = table.concat(parts, " "), firstOk = firstOk }
        or table.concat(parts, " ")
    end
  end
  return out
end

function ns.enumName(enum, value)
  if type(enum) == "table" then
    for k, v in pairs(enum) do
      if v == value then return k end
    end
  end
  return tostring(value)
end

-- The headline is the short yes/no summary printed at the top of the export.
ns.currentHeadline = {}

function ns.headline(key, value)
  ns.currentHeadline[key] = value
end

function ns.headlineMax(key, value)
  local cur = ns.currentHeadline[key]
  if type(value) == "number" and (type(cur) ~= "number" or value > cur) then
    ns.currentHeadline[key] = value
  end
end

function ns.charData()
  local key = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
  WFProbeDB.chars = WFProbeDB.chars or {}
  local data = WFProbeDB.chars[key]
  if not data then
    data = { probes = {}, events = {} }
    WFProbeDB.chars[key] = data
  end
  return data, key
end

-- SavedVariables round-trip check: one addon author reports the Forever beta
-- writes SavedVariables on logout but restores nothing on load.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    local fromDisk = type(WFProbeDB) == "table"
    WFProbeDB = fromDisk and WFProbeDB or {}
    local previous = WFProbeDB.loadCount or 0
    WFProbeDB.loadCount = previous + 1
    ns.svCheck = {
      tableExistedOnLoad = fromDisk,
      previousLoadCount = previous,
      previousLogout = WFProbeDB.lastLogout,
      verdict = previous > 0 and "restored OK"
        or "nothing restored: first load ever, OR the SavedVariables bug (run /reload and check again)",
    }
  elseif event == "PLAYER_ENTERING_WORLD" then
    ns.svCheck.isInitialLogin, ns.svCheck.isReload = arg1, arg2
    if arg1 or arg2 then
      ns.print("loaded. Type /wfprobe to run the probes (out of combat, in the open world).")
    end
  elseif event == "PLAYER_LOGOUT" then
    WFProbeDB.lastLogout = date("%Y-%m-%d %H:%M:%S")
  end
end)

local HELP = {
  "/wfprobe - run all probes and open the report",
  "/wfprobe show - reopen the report",
  "/wfprobe waypoint - test the built-in waypoint arrow (/wfprobe waypoint clear)",
  "/wfprobe nav - diagnose why the waypoint arrow is or isn't showing",
  "/wfprobe clear - delete stored probe data",
}

SLASH_WFPROBE1 = "/wfprobe"
SlashCmdList.WFPROBE = function(msg)
  local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
  if cmd == "" or cmd == "run" then
    if InCombatLockdown() then
      ns.print("leave combat first; combat data is restricted and would skew the results.")
      return
    end
    ns.RunAll()
    ns.ShowExport()
  elseif cmd == "show" then
    ns.ShowExport()
  elseif cmd == "waypoint" then
    ns.TestWaypoint(arg == "clear")
  elseif cmd == "nav" then
    ns.NavDiag()
  elseif cmd == "clear" then
    WFProbeDB.chars = {}
    ns.print("stored probe data cleared.")
  else
    for _, line in ipairs(HELP) do ns.print(line) end
  end
end
