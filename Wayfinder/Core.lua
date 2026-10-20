local ADDON, ns = ...

ns.VERSION = "0.3.0"
ns.data = {}

function ns.print(msg)
  print("|cff7fd1aeWayfinder:|r " .. tostring(msg))
end

---------------------------------------------------------------- events

local frame = CreateFrame("Frame")
local handlers = {}

-- Several modules can listen to the same game event. An event this client
-- doesn't have (renamed or removed between versions) is skipped: registering
-- it would be an error, and one error stops the rest of a file loading.
function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      ns.unknownEvents = ns.unknownEvents or {}
      table.insert(ns.unknownEvents, event)
    end
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

---------------------------------------------------------------- panel pages

-- Pages register themselves from their own files; UI/Panel.lua (loaded last)
-- turns them into tabs. See the page contract at the top of UI/Panel.lua.
ns.pages = {}

function ns.RegisterPage(page)
  table.insert(ns.pages, page)
end

-- /wf subcommands added by modules from their own files:
--   ns.RegisterCommand("item", "/wf item <link> - where an item comes from", function(rest) ... end)
-- `rest` keeps its original case, so links survive.
ns.commands = {}

-- Changes a setting and tells the windows (SETTINGS_CHANGED(key)).
function ns.SetSetting(key, value)
  ns.db.settings[key] = value
  ns.Fire("SETTINGS_CHANGED", key)
end

function ns.RegisterCommand(name, help, run)
  ns.commands[name] = { help = help, run = run }
end

---------------------------------------------------------------- saved data

local DEFAULTS = {
  npcs = {},         -- [npcID] = harvested NPC (see Harvest.lua)
  transports = {},   -- recorded with /wf dock (see Docks.lua)
  dungeonEntrances = {}, -- [name key] = entrances you walked through (see Dungeons.lua)
  -- showArrow: the compass in the directions box; tomtom: nil until you've
  -- been asked (see UI/Options.lua), then true / false.
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

-- The game's quest difficulty colour for a level ({r, g, b}), or nil.
function ns.DifficultyColor(level)
  if type(level) ~= "number" or level <= 0 or not GetQuestDifficultyColor then return nil end
  local c = GetQuestDifficultyColor(level)
  return c and { r = c.r, g = c.g, b = c.b } or nil
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
  "/wf compass - the compass in the directions box on or off (text directions stay)",
  "/wf tomtom - TomTom's arrow on or off for Wayfinder's directions (when TomTom is installed)",
  "/wf where - print your map ID and coordinates (to report data fixes)",
  "/wf dock [boat|zeppelin|portal] - record a transport: once where you board, once where you get off",
  "/wf dock list - copy recorded transports",
  "/wf debug - version, data sources and scan times (/wf debug cards: the For you cards; /wf debug quest <id|name>: a quest's chain data and why it's notable)",
}

SLASH_WAYFINDER1 = "/wf"
SLASH_WAYFINDER2 = "/wayfinder"
SlashCmdList.WAYFINDER = function(msg)
  local cmd, rest = (msg or ""):lower():match("^(%S*)%s*(.-)$")
  local registered = ns.commands[cmd]
  if registered then
    registered.run((msg or ""):match("^%S*%s*(.-)$"))
  elseif cmd == "" then
    ns.Panel.Toggle()
  elseif cmd == "stop" then
    ns.Nav.Stop()
  elseif cmd == "tomtom" then
    ns.SetSetting("tomtom", ns.db.settings.tomtom ~= true)
    ns.print("TomTom arrow " .. (ns.db.settings.tomtom and "on (when TomTom is installed)" or "off"))
  elseif cmd == "arrow" or cmd == "compass" then
    ns.SetSetting("showArrow", not ns.db.settings.showArrow)
    ns.print("compass " .. (ns.db.settings.showArrow and "on" or "off"))
  elseif cmd == "where" then
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then
      local x, y = pos:GetXY()
      ns.print(string.format("mapID=%d (%s) x=%.4f y=%.4f", mapID, ns.MapName(mapID), x, y))
    else
      ns.print("no map position here")
    end
  elseif cmd == "dock" then
    ns.Docks.Command(rest)
  elseif cmd == "debug" then
    ns.print("version " .. ns.VERSION)
    if rest == "cards" then
      for _, line in ipairs(ns.Cards.Diagnose()) do ns.print(line) end
      return
    end
    local questQuery = rest:match("^quest%s+(.+)$")
    if questQuery then
      local id = tonumber(questQuery) or tonumber(questQuery:match("quest:(%d+)"))
      local matches = id and { { id = id } } or ns.Quests.FindQuests(questQuery)
      if #matches == 0 then ns.print("no quest called " .. questQuery) end
      for i = 1, math.min(#matches, 3) do
        for _, line in ipairs(ns.Quests.Describe(matches[i].id)) do ns.print(line) end
        for _, line in ipairs(ns.Quests.DescribeNotable(matches[i].id)) do ns.print(line) end
        for _, line in ipairs(ns.Quests.DescribeChain(matches[i].id)) do ns.print(line) end
      end
      return
    end
    ns.print("data sources: " .. (ns.Data.Status() or "none (install a Wayfinder data addon for quests, items and more NPCs)"))
    local function count(t)
      local n = 0
      for _ in pairs(t) do n = n + 1 end
      return n
    end
    ns.print(string.format("learned NPCs: %d, known flight paths: %d", count(ns.db.npcs), count(ns.charDB.knownTaxi)))
    for name, ms in pairs(ns.debugTimings or {}) do
      ns.print(string.format("%s scan: %.0f ms", name, ms))
    end
    if ns.ForYou and ns.ForYou.lastParts then ns.print("forYou parts (ms): " .. ns.ForYou.lastParts) end
    if ns.QuestTimes then ns.print(ns.QuestTimes.Describe(ns.ForYou and ns.ForYou.SECONDS_PER_QUEST)) end
    if ns.unknownEvents then ns.print("events this client doesn't have: " .. table.concat(ns.unknownEvents, ", ")) end
  else
    for _, line in ipairs(HELP) do ns.print(line) end
    for _, command in pairs(ns.commands) do ns.print(command.help) end
  end
end
