local ADDON, ns = ...

ns.VERSION = "0.1.0"
ns.data = {}

function ns.print(msg)
  print("|cff7fd1aeWayfinder:|r " .. tostring(msg))
end

---------------------------------------------------------------- events

local frame = CreateFrame("Frame")
local handlers = {}

-- Several modules can listen to the same game event.
function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    frame:RegisterEvent(event)
  end
  table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end)

-- Internal messages between modules (e.g. "DATA_CHANGED" -> panel refresh).
local listeners = {}

function ns.Listen(message, fn)
  listeners[message] = listeners[message] or {}
  table.insert(listeners[message], fn)
end

function ns.Fire(message, ...)
  for _, fn in ipairs(listeners[message] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end

---------------------------------------------------------------- saved data

local DEFAULTS = {
  npcs = {},         -- [npcID] = harvested NPC (see Harvest.lua)
  settings = { showArrow = true },
}

local CHAR_DEFAULTS = {
  knownTaxi = {},    -- [taxi nodeID] = true
  classSpells = nil, -- last class trainer reading (see Harvest.lua)
}

local function applyDefaults(target, defaults)
  for k, v in pairs(defaults) do
    if target[k] == nil then
      target[k] = type(v) == "table" and CopyTable(v) or v
    elseif type(v) == "table" and type(target[k]) == "table" then
      applyDefaults(target[k], v)
    end
  end
end

ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  WayfinderDB = WayfinderDB or {}
  WayfinderCharDB = WayfinderCharDB or {}
  applyDefaults(WayfinderDB, DEFAULTS)
  applyDefaults(WayfinderCharDB, CHAR_DEFAULTS)
  ns.db, ns.charDB = WayfinderDB, WayfinderCharDB
  ns.Fire("DB_READY")
end)

---------------------------------------------------------------- formatting

function ns.FormatMoney(copper)
  copper = copper or 0
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return string.format("%dg %ds", g, s) end
  if s > 0 then return string.format("%ds %dc", s, c) end
  return c .. "c"
end

function ns.FormatDuration(seconds)
  if not seconds or seconds == math.huge then return "?" end
  if seconds < 60 then return "<1 min" end
  local minutes = math.floor(seconds / 60 + 0.5)
  if minutes < 60 then return "~" .. minutes .. " min" end
  return string.format("~%d h %d min", math.floor(minutes / 60), minutes % 60)
end

function ns.EnumName(enum, value)
  for k, v in pairs(enum or {}) do
    if v == value then return k end
  end
  return nil
end

function ns.MapName(mapID)
  local info = mapID and C_Map.GetMapInfo(mapID)
  return info and info.name or "?"
end

function ns.SavePosition(frame, key)
  local point, _, relativePoint, x, y = frame:GetPoint()
  ns.db.settings[key] = { point, relativePoint, x, y }
end

function ns.RestorePosition(frame, key)
  local p = ns.db.settings[key]
  if p then
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  end
end

---------------------------------------------------------------- slash

local HELP = {
  "/wf - open or close the Wayfinder panel",
  "/wf stop - stop the current directions",
  "/wf arrow - toggle the on-screen arrow (text directions stay)",
  "/wf where - print your map ID and coordinates (to report data fixes)",
}

SLASH_WAYFINDER1 = "/wf"
SLASH_WAYFINDER2 = "/wayfinder"
SlashCmdList.WAYFINDER = function(msg)
  local cmd = (msg or ""):lower():match("^(%S*)")
  if cmd == "" then
    ns.Panel.Toggle()
  elseif cmd == "stop" then
    ns.Nav.Stop()
  elseif cmd == "arrow" then
    ns.db.settings.showArrow = not ns.db.settings.showArrow
    ns.print("arrow " .. (ns.db.settings.showArrow and "on" or "off"))
    ns.Fire("SETTINGS_CHANGED")
  elseif cmd == "where" then
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then
      local x, y = pos:GetXY()
      ns.print(string.format("mapID=%d (%s) x=%.4f y=%.4f", mapID, ns.MapName(mapID), x, y))
    else
      ns.print("no map position here")
    end
  else
    for _, line in ipairs(HELP) do ns.print(line) end
  end
end
