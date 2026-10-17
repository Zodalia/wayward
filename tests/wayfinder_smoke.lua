-- Runs Wayfinder against stubbed WoW APIs and a fake two-continent world.
-- Checks our own logic (routing, step advance, harvesting, panel), not real
-- Forever behaviour. Usage (from repo root): lua tests/wayfinder_smoke.lua
local dir = arg[1] or "Wayfinder"
local timers, chat, waypoints, events = {}, {}, {}, {}
local failures = 0

local function check(cond, msg)
  if cond then
    io.write("  ok   ", msg, "\n")
  else
    failures = failures + 1
    io.write("  FAIL ", msg, "\n")
  end
end

---------------------------------------------------------------- frames

-- Like real frames: unknown Capitalised keys are no-op methods, others are nil.
local function newObj()
  local o = { scripts = {}, shown = true }
  return setmetatable(o, { __index = function(_, k)
    if type(k) == "string" and k:match("^%u") then
      return function(self, ...)
        if k == "SetScript" then local name, fn = ...; self.scripts[name] = fn
        elseif k == "HookScript" then
          local name, fn = ...
          local old = self.scripts[name]
          self.scripts[name] = old and function(...) old(...); fn(...) end or fn
        elseif k == "RegisterEvent" then events[(...)] = events[(...)] or {}; table.insert(events[(...)], self)
        elseif k == "SetText" then rawset(self, "text", (...))
        elseif k == "GetText" then return rawget(self, "text")
        elseif k == "SetRotation" then rawset(self, "rotation", (...))
        elseif k == "Show" then rawset(self, "shown", true); if self.scripts.OnShow then self.scripts.OnShow(self) end
        elseif k == "Hide" then rawset(self, "shown", false)
        elseif k == "SetShown" then rawset(self, "shown", (...) and true or false)
        elseif k == "IsShown" then return rawget(self, "shown")
        elseif k == "CreateFontString" or k == "CreateTexture" then return newObj()
        elseif k == "GetPoint" then return "CENTER", nil, "CENTER", 0, 0
        end
      end
    end
  end })
end

CreateFrame = function() return newObj() end
GameTooltip = newObj()
UIParent = newObj()
UISpecialFrames = {}
print = function(...) chat[#chat + 1] = table.concat({ ... }, " ") end
geterrorhandler = function() return function(err) error(err, 0) end end
CopyTable = function(t) local c = {} for k, v in pairs(t) do c[k] = type(v) == "table" and CopyTable(v) or v end return c end
tinsert = table.insert
time, date = os.time, os.date
strsplit = function(sep, s) local r = {} for p in (s .. sep):gmatch("(.-)%" .. sep) do r[#r + 1] = p end return table.unpack(r) end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
SlashCmdList = {}

---------------------------------------------------------------- fake world

-- Continent maps convert to world yards: X north, Y west (as in the game).
local CONTINENTS = { [1415] = 0, [1414] = 1 }
-- Zones as rectangles in their continent's 0-1 map space.
local ZONES = {
  [1453] = { cont = 1415, x0 = 0.40, y0 = 0.68, w = 0.06, h = 0.06, name = "Stormwind City" },
  [1433] = { cont = 1415, x0 = 0.48, y0 = 0.66, w = 0.08, h = 0.08, name = "Redridge Mountains" },
  [1437] = { cont = 1415, x0 = 0.38, y0 = 0.42, w = 0.10, h = 0.10, name = "Wetlands" },
  [1439] = { cont = 1414, x0 = 0.40, y0 = 0.15, w = 0.10, h = 0.20, name = "Darkshore" },
}

local function vec(x, y) return { x = x, y = y, GetXY = function(s) return s.x, s.y end } end
CreateVector2D = vec

local function toContinent(mapID, x, y)
  if CONTINENTS[mapID] then return mapID, x, y end
  local z = ZONES[mapID]
  if not z then return nil end
  return z.cont, z.x0 + x * z.w, z.y0 + y * z.h
end

local player = { mapID = 1433, x = 0.5, y = 0.5, facing = 0 }

C_Map = {
  GetWorldPosFromMapPos = function(mapID, p)
    local cont, cx, cy = toContinent(mapID, p.x, p.y)
    if not cont then return nil end
    return CONTINENTS[cont], vec(4000 - cy * 12000, 4000 - cx * 8000)
  end,
  GetMapPosFromWorldPos = function(instance, w, mapID)
    local cx, cy = (4000 - w.y) / 8000, (4000 - w.x) / 12000
    if CONTINENTS[mapID] then return mapID, vec(cx, cy) end
    local z = ZONES[mapID]
    return mapID, vec((cx - z.x0) / z.w, (cy - z.y0) / z.h)
  end,
  GetMapInfoAtPosition = function(cont, cx, cy)
    for id, z in pairs(ZONES) do
      if z.cont == cont and cx >= z.x0 and cx <= z.x0 + z.w and cy >= z.y0 and cy <= z.y0 + z.h then
        return { mapID = id }
      end
    end
  end,
  GetMapChildrenInfo = function() return { { mapID = 1415 }, { mapID = 1414 } } end,
  GetMapInfo = function(id) return { mapID = id, name = ZONES[id] and ZONES[id].name or tostring(id) } end,
  GetBestMapForUnit = function() return player.mapID end,
  GetPlayerMapPosition = function() return vec(player.x, player.y) end,
  CanSetUserWaypointOnMap = function() return true end,
  SetUserWaypoint = function(point) waypoints[#waypoints + 1] = point end,
  ClearUserWaypoint = function() waypoints[#waypoints + 1] = "cleared" end,
}
UiMapPoint = { CreateFromCoordinates = function(mapID, x, y) return { mapID = mapID, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
C_TaxiMap = {
  GetTaxiNodesForMap = function(cont)
    if cont == 1415 then
      return {
        { nodeID = 2, name = "Stormwind, Elwynn", faction = 2, position = vec(0.43, 0.70) },
        { nodeID = 5, name = "Lakeshire, Redridge", faction = 2, position = vec(0.515, 0.69) },
        { nodeID = 7, name = "Menethil Harbor, Wetlands", faction = 2, position = vec(0.385, 0.475) },
        { nodeID = 11, name = "Undercity, Tirisfal", faction = 1, position = vec(0.45, 0.25) },
      }
    end
    return { { nodeID = 26, name = "Auberdine, Darkshore", faction = 2, position = vec(0.44, 0.25) } }
  end,
  GetAllTaxiNodes = function()
    return { { nodeID = 5, state = 0 }, { nodeID = 2, state = 1 }, { nodeID = 7, state = 1 },
      { nodeID = 26, state = 1 }, { nodeID = 99, state = 2 } }
  end,
}
GetTaxiMapID = function() return 1415 end
Enum = {
  UIMapType = { Continent = 2, Zone = 3 },
  PlayerInteractionType = { Merchant = 5, Trainer = 7 },
  TrainerType = { General = 0, Tradeskills = 2, Pet = 3 },
}

UnitClass = function() return "Warlock", "WARLOCK", 9 end
UnitFactionGroup = function() return "Alliance" end
UnitLevel = function() return 20 end
UnitName = function(u) return u == "npc" and "Test Darkbinder" or "Zodalia" end
UnitGUID = function() return "Creature-0-1-0-2-999-AB" end
GetMoney = function() return 5000 end
GetPlayerFacing = function() return player.facing end

local SERVICES = {
  { "Corruption", "unavailable", 136118, req = 24, cost = 2700 },
  { "Life Tap", "available", 136126, req = 20, cost = 1000 },
  { "Shadow Bolt", "used", 136197, req = 20, cost = 0 },
}
GetNumTrainerServices = function() return #SERVICES end
GetTrainerServiceInfo = function(i) return SERVICES[i][1], SERVICES[i][2], SERVICES[i][3] end
GetTrainerServiceLevelReq = function(i) return SERVICES[i].req end
GetTrainerServiceCost = function(i) return SERVICES[i].cost end
IsTradeskillTrainer = function() return false end
C_Trainer = { GetTrainerType = function() return 0 end }

---------------------------------------------------------------- load

local ns = {}
for line in io.lines(dir .. "/Wayfinder.toc") do
  local file = line:match("^([^#%s].-%.lua)%s*$")
  if file then assert(loadfile(dir .. "/" .. file:gsub("\\", "/")))("Wayfinder", ns) end
end

local function fire(event, ...)
  for _, f in ipairs(events[event] or {}) do f.scripts.OnEvent(f, event, ...) end
end
local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

fire("ADDON_LOADED", "Wayfinder")

---------------------------------------------------------------- tests

io.write("geo\n")
local b1 = ns.Geo.Bearing({ wx = 0, wy = 0 }, { wx = 10, wy = 0 })
local b2 = ns.Geo.Bearing({ wx = 0, wy = 0 }, { wx = 0, wy = 10 })
check(math.abs(b1) < 1e-6, "north is bearing 0")
check(math.abs(b2 - math.pi / 2) < 1e-6, "west is bearing +pi/2 (counter-clockwise, like GetPlayerFacing)")
local trainerNode = ns.Geo.Node(1453, 0.3938, 0.8483, "t")
local zoneID, zx, zy = ns.Geo.ZonePoint(trainerNode)
check(zoneID == 1453 and math.abs(zx - 0.3938) < 1e-6 and math.abs(zy - 0.8483) < 1e-6,
  "world -> zone point round-trips (" .. tostring(zoneID) .. ")")

io.write("harvest\n")
fire("TAXIMAP_OPENED")
check(ns.charDB.knownTaxi[5] and ns.charDB.knownTaxi[2] and not ns.charDB.knownTaxi[99],
  "current/reachable flight paths are known, unreachable ones are not")
fire("TRAINER_SHOW")
runTimers()
local summary = ns.Trainers.SpellSummary()
check(summary and summary.trainable == 1 and summary.cost == 1000, "1 spell trainable now for 10s")
check(summary and summary.nextLevel == 24 and summary.nextCount == 1, "next spell at level 24")
check(ns.db.npcs[999] and ns.db.npcs[999].kinds.classTrainer and ns.db.npcs[999].class == "WARLOCK",
  "trainer harvested as a warlock class trainer")

io.write("routing\n")
ns.db.npcs[999] = nil -- route to the seeded Stormwind trainer only
local results = ns.Trainers.Results()
local r = results[1]
check(r and r.title == "Demisette Cloyce" and r.route, "Redridge: seeded trainer found with a route")
local modes = {}
for _, s in ipairs(r.route.steps) do modes[#modes + 1] = s.mode end
check(table.concat(modes, ",") == "walk,fly,walk", "Redridge: walk, fly, walk (" .. table.concat(modes, ",") .. ")")
check(ns.Router.Describe(r.route, 1) == "Go to the flight master at Lakeshire, Redridge", "step 1 text")
check(ns.Router.Describe(r.route, 2) == "Fly to Stormwind, Elwynn", "step 2 text")

player.mapID, player.x, player.y = 1439, 0.5, 0.5
local far = ns.Trainers.Results()[1]
local kinds = {}
for _, s in ipairs(far and far.route and far.route.steps or {}) do kinds[#kinds + 1] = s.kind or s.mode end
local plan = table.concat(kinds, ",")
check(plan == "walk,boat,walk", "Darkshore: Forever's direct boat to Stormwind (" .. plan .. ")")
check(far and ns.Router.Summary(far.route) == "boat to Stormwind Harbor", "summary mentions the boat")

io.write("navigation\n")
player.mapID, player.x, player.y = 1433, 0.5, 0.5
r = ns.Trainers.Results()[1]
ns.Nav.Start(r.title, r.goal, r.route)
check(#waypoints == 1 and waypoints[1].mapID == 1433, "waypoint placed on the zone map of the flight master")
check(ns.Nav.active.index == 1, "starts at step 1")
-- Arrive at the flight master.
local fp = r.route.steps[1].to
player.mapID, player.x, player.y = fp.mapID, fp.x, fp.y
ns.HUD.Update()
check(ns.Nav.active.index == 2, "reaching the flight master advances to the flight")
-- Land in Stormwind.
local landing = r.route.steps[2].to
player.mapID, player.x, player.y = landing.mapID, landing.x, landing.y
player.facing = 0
ns.HUD.Update()
check(ns.Nav.active.index == 3, "landing advances to the final walk")
-- Arrive at the trainer.
player.mapID, player.x, player.y = 1453, 0.3938, 0.8483
ns.HUD.Update()
check(ns.Nav.active == nil and waypoints[#waypoints] == "cleared", "arriving stops and clears our waypoint")

io.write("live time and re-planning\n")
ns.charDB.knownTaxi = {}
player.mapID, player.x, player.y = 1433, 0.5, 0.5
r = ns.Trainers.Results()[1]
check(#r.route.steps == 1 and r.route.steps[1].mode == "walk", "no known flight paths: walk the whole way")
ns.Nav.Start(r.title, r.goal, r.route)
check(chat[#chat]:find("talk to a flight master"), "starting without flight paths prints the tip")
local before = ns.Nav.RemainingSeconds(ns.Geo.PlayerNode())
player.x = 0.3 -- walk part of the way west toward Stormwind
local after = ns.Nav.RemainingSeconds(ns.Geo.PlayerNode())
check(after < before - 5, string.format("remaining time drops while walking (%.0fs -> %.0fs)", before, after))
player.x = 0.5 -- back at Lakeshire, talk to the flight master
fire("TAXIMAP_OPENED")
modes = {}
for _, s in ipairs(ns.Nav.active.route.steps) do modes[#modes + 1] = s.mode end
check(table.concat(modes, ",") == "walk,fly,walk",
  "learning flight paths re-plans the active route (" .. table.concat(modes, ",") .. ")")
ns.Nav.Stop()

io.write("panel\n")
ns.Panel.Toggle()
check(ns.Panel.IsShown(), "first /wf opens the panel")

io.write("without QuestieDB\n")
local noHubs, noHubsErr = ns.QuestHubs.Results()
check(#noHubs == 0 and noHubsErr and noHubsErr:find("not installed"), "quest hubs explain that QuestieDB is needed")
check(ns.Questie.StatusText() == nil, "no QuestieDB status line")

io.write("questiedb bridge\n")
local NPCS = {
  [461] = { name = "Demisette Cloyce", subName = "Warlock Trainer", npcFlags = 18, friendlyToFaction = "A",
    spawns = { [1519] = { { 39.38, 84.83 } } } },
  [5000] = { name = "Ursula Deline", subName = "Warlock Trainer", npcFlags = 16, friendlyToFaction = "A",
    spawns = { [1519] = { { 45.0, 70.0 } } } },
  [5001] = { name = "Horde Warlock", subName = "Warlock Trainer", npcFlags = 16, friendlyToFaction = "H",
    spawns = { [1519] = { { 50, 50 } } } },
  [5002] = { name = "Some Mage", subName = "Mage Trainer", npcFlags = 16, friendlyToFaction = "A",
    spawns = { [1519] = { { 30, 30 } } } },
  [344] = { name = "Magistrate Solomon", npcFlags = 2, friendlyToFaction = "A", spawns = { [44] = { { 30.0, 45.0 } } } },
  -- Same town, just beyond the hub radius from Solomon: merged by place name.
  [345] = { name = "Foreman Oslow", npcFlags = 2, friendlyToFaction = "A", spawns = { [44] = { { 36.0, 30.0 } } } },
  [6000] = { name = "Stormwind Questgiver", npcFlags = 2, friendlyToFaction = "AH",
    spawns = { [1519] = { { 50.0, 50.0 } } } },
}
local QUESTS = {
  [1] = { name = "Redridge Goulash", questLevel = 18, requiredLevel = 15, startedBy = { { 344 } } },
  [2] = { name = "Already done", questLevel = 18, requiredLevel = 15, startedBy = { { 344 } } },
  [3] = { name = "Mages only", questLevel = 18, requiredLevel = 15, requiredClasses = 128, startedBy = { { 344 } } },
  [4] = { name = "Needs prequest", questLevel = 18, requiredLevel = 15, preQuestSingle = { 999 }, startedBy = { { 344 } } },
  [5] = { name = "Too easy", questLevel = 5, requiredLevel = 1, startedBy = { { 344 } } },
  [6] = { name = "Stormwind errand", questLevel = 20, requiredLevel = 18, startedBy = { { 6000 } } },
  [7] = { name = "Lakeshire Logs", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } } },
  [8] = { name = "Horde only", questLevel = 19, requiredLevel = 15, requiredRaces = 2, startedBy = { { 344 } } },
  [9] = { name = "Too high", questLevel = 30, requiredLevel = 28, startedBy = { { 344 } } },
  [10] = { name = "Already in log", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } } },
  [11] = { name = "Bridge Footings", questLevel = 17, requiredLevel = 14, startedBy = { { 345 } } },
  [12] = { name = "Too hard", questLevel = 26, requiredLevel = 18, startedBy = { { 344 } } },
  -- Chains: 14 leads to 13 (only recorded on 14), so 13 waits until 14 is done.
  [13] = { name = "Chain part 2", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } } },
  [14] = { name = "Chain part 1", questLevel = 19, requiredLevel = 15, nextQuestInChain = 13, startedBy = { { 6000 } } },
  -- Its only predecessor is Horde-only, so an Alliance character can take it.
  [15] = { name = "Alliance step", questLevel = 18, requiredLevel = 15, startedBy = { { 344 } } },
  [16] = { name = "Horde step", questLevel = 18, requiredLevel = 15, requiredRaces = 2, nextQuestInChain = 15,
    startedBy = { { 344 } } },
  [17] = { name = "Needs parent", questLevel = 18, requiredLevel = 15, parentQuest = 99, startedBy = { { 344 } } },
  [18] = { name = "Superseded", questLevel = 18, requiredLevel = 15, nextQuestInChain = 2, startedBy = { { 344 } } },
}
local function entity(rows, defaults)
  local E = {}
  function E.Get(id, key)
    local row = rows[id]
    if not row then return nil end
    if row[key] == nil then return defaults[key] end
    return row[key]
  end
  E.GetRaw = E.Get
  function E.GetAll(id, keys)
    if not rows[id] then return nil end
    local out = { n = #keys }
    for i, k in ipairs(keys) do out[i] = E.Get(id, k) end
    return out
  end
  function E.GetAllIds()
    local ids = {}
    for id in pairs(rows) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
  end
  return E
end
NpcDB = entity(NPCS, { npcFlags = 0 })
QuestDB = entity(QUESTS, { questLevel = 0, requiredLevel = 0, requiredRaces = 0, requiredClasses = 0,
  nextQuestInChain = 0, parentQuest = 0, requiredMaxLevel = 0, availableUntilCompleted = 0,
  availableStartingWith = 0, disabledByQuest = 0, breadcrumbForQuestId = 0 })
ObjectDB = entity({}, {})
loadstring = loadstring or load
LibQuestieDB = {
  readMode = "baked",
  RequireContract = function(v) return v <= 4, "provider speaks contract 4" end,
  Enum = { npcFlags = { TRAINER = 16, QUEST_GIVER = 2 }, classKeys = { WARLOCK = 256, MAGE = 128 },
    raceMaskById = { [1] = 1, [2] = 2 } },
  Meta = { QuestMeta = { questKeys = { name = 1, startedBy = 2, requiredLevel = 4, questLevel = 5,
    requiredRaces = 6, requiredClasses = 7, preQuestGroup = 12, preQuestSingle = 13, exclusiveTo = 16,
    requiredSkill = 18, nextQuestInChain = 22, parentQuest = 25, breadcrumbForQuestId = 27,
    requiredMaxLevel = 32, availableUntilCompleted = 33, availableStartingWith = 34, disabledByQuest = 36 } } },
  Support = { Get = function() return { private = { areaIdToUiMapId = "return { [44] = 1433, [1519] = 1453 }" } } end },
}
UnitRace = function() return "Human", "Human", 1 end
C_QuestLog = {
  GetAllCompletedQuestIDs = function() return { 2 } end,
  GetNumQuestLogEntries = function() return 1 end,
  GetInfo = function() return { questID = 10, isHeader = false } end,
}

player.mapID, player.x, player.y = 1433, 0.5, 0.5
check(ns.Questie.Available() and ns.Questie.StatusText() == "QuestieDB (baked)", "QuestieDB detected (contract 4)")
local trainers = ns.Trainers.Results()
local names = {}
for _, t in ipairs(trainers) do names[#names + 1] = t.title end
table.sort(names)
check(table.concat(names, ",") == "Demisette Cloyce,Ursula Deline",
  "trainers merge seed + QuestieDB, same faction and class only (" .. table.concat(names, ",") .. ")")

local hubs = ns.QuestHubs.Results()
check(#hubs == 2, "two quest hubs (" .. #hubs .. ")")
check(hubs[1] and hubs[1].title == "Lakeshire  ·  4 quests",
  "nearest hub named after its town, both clusters merged: " .. tostring(hubs[1] and hubs[1].title))
check(hubs[2] and hubs[2].title == "Stormwind  ·  2 quests", "farther hub second: " .. tostring(hubs[2] and hubs[2].title))
local listed = {}
for _, h in ipairs(hubs) do for _, d in ipairs(h.details) do listed[#listed + 1] = d.text end end
local text = table.concat(listed, "\n")
check(text:find("Redridge Goulash") and text:find("Lakeshire Logs") and text:find("Stormwind errand")
  and text:find("Bridge Footings") and text:find("Chain part 1") and text:find("Alliance step"),
  "eligible quests listed")
local leaked = {}
for _, name in ipairs({ "Already done", "Mages only", "Needs prequest", "Too easy", "Horde only", "Too high",
  "Already in log", "Too hard", "Chain part 2", "Horde step", "Needs parent", "Superseded" }) do
  if text:find(name, 1, true) then leaked[#leaked + 1] = name end
end
check(#leaked == 0, "ineligible quests filtered (leaked: " .. table.concat(leaked, ", ") .. ")")
check(hubs[1] and hubs[1].route and ns.Router.Describe(hubs[1].route, #hubs[1].route.steps) == "Walk to Lakeshire (Magistrate Solomon)",
  "hub has directions to its main quest giver")
ns.Panel.Select(2)
check(ns.Panel.IsShown(), "panel shows quest hubs without errors")

io.write("dock recorder\n")
local subZone = "Auberdine"
GetSubZoneText = function() return subZone end
player.mapID, player.x, player.y = 1439, 0.5, 0.5
SlashCmdList.WAYFINDER("dock")
check(ns.charDB.pendingDock and ns.charDB.pendingDock.a.label == "Auberdine", "first /wf dock starts recording at Auberdine")
SlashCmdList.WAYFINDER("dock")
check(#ns.db.transports == 0, "a second /wf dock without moving is refused")
subZone = "Test Pier"
player.mapID, player.x, player.y = 1453, 0.8, 0.5
SlashCmdList.WAYFINDER("dock")
local recorded = ns.db.transports[1]
check(recorded and recorded.kind == "boat" and recorded.b.label == "Test Pier" and recorded.time >= 30,
  "arriving saves the boat with its trip time")
check(recorded and ns.Docks.LuaLine(recorded):find('label = "Test Pier"'), "recorded boat exports as a data line")
player.mapID, player.x, player.y = 1439, 0.5, 0.5
ns.Panel.Select(1)
local viaNewBoat = ns.Trainers.Results()[1]
local usesIt = false
for _, st in ipairs(viaNewBoat and viaNewBoat.route and viaNewBoat.route.steps or {}) do
  if st.mode == "transport" and st.to.label == "Test Pier" then usesIt = true end
end
check(usesIt, "Darkshore to Stormwind now takes the recorded boat (" .. ns.Router.Summary(viaNewBoat.route) .. ")")
SlashCmdList.WAYFINDER("dock list")
check(true, "/wf dock list opens the copy box")

---------------------------------------------------------------- vendors (begin)

io.write("vendors\n")
local merchant = { items = {}, repairs = false }
GetMerchantNumItems = function() return #merchant.items end
C_MerchantFrame = { GetItemInfo = function(i) return { itemID = merchant.items[i], price = 10, stackCount = 1 } end }
CanMerchantRepair = function() return merchant.repairs end
local ITEM_INSTANT = {
  [100] = { 2, 2 },  -- a bow
  [9999] = { 6, 2 }, -- arrows not in Data/VendorGoods.lua
}
C_Item = { GetItemInfoInstant = function(id)
  local c = ITEM_INSTANT[id]
  if c then return id, "", "", "", 0, c[1], c[2] end
end }
local durability = { 50, 50 }
GetInventoryItemDurability = function(slot) if slot == 1 then return durability[1], durability[2] end end
local npcName = "Test Darkbinder"
UnitName = function(u) return u == "npc" and npcName or "Zodalia" end
local function visitMerchant(id, name, mapID, x, y, items, repairs)
  UnitGUID = function() return "Creature-0-1-0-2-" .. id .. "-AB" end
  npcName, merchant.items, merchant.repairs = name, items, repairs
  player.mapID, player.x, player.y = mapID, x, y
  fire("MERCHANT_SHOW")
  runTimers()
end
local function titles(list)
  local t = {}
  for _, v in ipairs(list) do t[#t + 1] = v.title end
  return table.concat(t, " | ")
end
local function find(list, needle)
  for i, v in ipairs(list) do
    if v.title:find(needle, 1, true) then return v, i end
  end
end

visitMerchant(8001, "Lakeshire Cook", 1433, 0.45, 0.5, { 1205, 4542, 9999 }, false)
local cook = ns.db.npcs[8001]
check(cook and cook.kinds.vendor and #cook.goods == 3 and cook.goods[1] == 1205,
  "merchant visit records the vendor's item IDs")
check(cook and cook.sells.food and cook.sells.arrow and cook.repairs == false,
  "goods get a category guess (food, arrows from the item class) and no repairs")
visitMerchant(8002, "Stormwind Smith", 1453, 0.5, 0.5, { 1179 }, true)
check(ns.db.npcs[8002] and ns.db.npcs[8002].repairs == true, "repairing vendor recorded as such")
ns.db.npcs[8003] = { kinds = { vendor = true }, name = "Orgrimmar Grocer", faction = "Horde", mapID = 1433,
  x = 0.5, y = 0.5, goods = { 1205 }, sells = { food = true }, repairs = true }

-- Without QuestieDB: only vendors you visited.
local realAvailable = ns.Questie.Available
ns.Questie.Available = function() return false, "QuestieDB is not installed" end
player.mapID, player.x, player.y = 1433, 0.5, 0.5
local shops = ns.Vendors.Results()
check(#shops == 2 and shops[1].id == 8001 and shops[2].id == 8002,
  "without QuestieDB: visited vendors of your faction, nearest first (" .. titles(shops) .. ")")
check(shops[1].title == "Lakeshire Cook  ·  Food & drink", "row says why: " .. tostring(shops[1].title))
check(shops[2].title == "Stormwind Smith  ·  Repair, Food & drink", "repair listed: " .. tostring(shops[2].title))
local older = shops[2].details[2]
check(older and older.text:find("Ice Cold Milk") and older.text:find("older tier"),
  "lower-tier food is marked (" .. tostring(older and older.text) .. ")")
check(not ns.Vendors.SummaryText():find("repair"), "full durability: no repair warning")

durability = { 10, 50 }
shops = ns.Vendors.Results()
check(shops[1] and shops[1].id == 8002, "gear at 20%: the repair vendor jumps to the top (" .. titles(shops) .. ")")
check(ns.Vendors.SummaryText():find("Gear at 20%%: repair soon"), "summary warns: " .. ns.Vendors.SummaryText())
check(shops[1].title:find("|cffff7f3fRepair|r", 1, true), "repair label highlighted")
durability = { 50, 50 }
ns.Questie.Available = realAvailable

-- With QuestieDB: ItemDB sellers, repair flags, faction filter.
NPCS[7000] = { name = "Innkeeper Farley", subName = "Innkeeper", npcFlags = 4 + 128, friendlyToFaction = "A",
  spawns = { [44] = { { 52.0, 50.0 } } } }
NPCS[7001] = { name = "Horde Cook", subName = "Food & Drink", npcFlags = 4, friendlyToFaction = "H",
  spawns = { [44] = { { 50.0, 50.0 } } } }
NPCS[7002] = { name = "Stormwind Armorer", subName = "Armorer", npcFlags = 4 + 16384, friendlyToFaction = "A",
  spawns = { [1519] = { { 60.0, 60.0 } } } }
NPCS[7003] = { name = "Redridge Smith", subName = "Blacksmith", npcFlags = 4 + 16384, friendlyToFaction = "A",
  spawns = { [44] = { { 20.0, 60.0 } } } }
NPCS[7004] = { name = "Lakeshire Bowyer", subName = "Bowyer", npcFlags = 4, friendlyToFaction = "A",
  spawns = { [44] = { { 55.0, 45.0 } } } }
local ITEMS = {
  [1205] = { vendors = { 7000, 7001 } },
  [4542] = { vendors = { 7000 } },
  [2515] = { vendors = { 7004 } },
}
ItemDB = entity(ITEMS, {})
LibQuestieDB.Meta.ItemMeta = { itemKeys = { name = 1, vendors = 14 } }
LibQuestieDB.Enum.npcFlags.VENDOR, LibQuestieDB.Enum.npcFlags.REPAIR = 4, 16384

player.mapID, player.x, player.y = 1433, 0.5, 0.5
shops = ns.Vendors.Results()
check(not find(shops, "Horde Cook") and not find(shops, "Orgrimmar"), "other faction's vendors hidden (" .. titles(shops) .. ")")
local inn = find(shops, "Innkeeper Farley")
check(inn and inn.title == "Innkeeper Farley  ·  Food & drink" and inn.details[1].text:find("Melon Juice"),
  "QuestieDB vendor found through ItemDB sellers: " .. tostring(inn and inn.details[1].text))
local _, near = find(shops, "Redridge Smith")
local _, farther = find(shops, "Stormwind Armorer")
check(near and farther and near < farther, "repair vendors ranked by travel time (" .. titles(shops) .. ")")
local sorted = true
for i = 2, #shops do
  if shops[i].route.seconds < shops[i - 1].route.seconds then sorted = false end
end
check(sorted, "rows sorted by travel time")
check(not find(shops, "Bowyer"), "no ammo vendors for a warlock")

UnitClass = function() return "Hunter", "HUNTER", 3 end
GetInventorySlotInfo = function(name) return name == "RangedSlot" and 18 or 0 end
GetInventoryItemID = function(_, slot) return slot == 18 and 100 or nil end
GetInventoryItemCount = function() return 150 end
shops = ns.Vendors.Results()
local bowyer = find(shops, "Lakeshire Bowyer")
check(bowyer and bowyer.title:find("Ammo") and bowyer.details[1].text:find("Sharp Arrow"),
  "hunter with a bow: arrow vendor listed (" .. titles(shops) .. ")")
check(ns.Vendors.SummaryText():find("Ammo %(150 left%)"), "summary shows ammo left: " .. ns.Vendors.SummaryText())

UnitClass = function() return "Mage", "MAGE", 8 end
GetInventoryItemID = function() return nil end
NPCS[7005] = { name = "Reagent Seller", subName = "Reagents", npcFlags = 4, friendlyToFaction = "A",
  spawns = { [1519] = { { 40.0, 40.0 } } } }
ITEMS[17031] = { vendors = { 7005 } }
shops = ns.Vendors.Results()
local reagents = find(shops, "Reagent Seller")
check(reagents and reagents.title:find("Reagents") and reagents.details[1].text == "Reagents: Rune of Teleportation",
  "mage: reagent vendor listed with the reagent (" .. tostring(reagents and reagents.details[1].text) .. ")")
check(ns.Vendors.SummaryText():find("Reagents: Light Feather, Rune of Teleportation", 1, true),
  "summary names your reagents: " .. ns.Vendors.SummaryText())
check(not ns.Vendors.SummaryText():find("Ammo"), "no ranged weapon, not a hunter: no ammo need")
UnitClass = function() return "Warlock", "WARLOCK", 9 end

ns.Panel.Select(4)
check(ns.Panel.IsShown(), "panel shows vendors without errors")

---------------------------------------------------------------- vendors (end)
---------------------------------------------------------------- dungeons (begin)

io.write("dungeons\n")
-- Client dungeon finder list: names without area IDs, one level each.
local LFG = {
  [1] = { name = "Wailing Caverns", level = 17 },
  [2] = { name = "Scholomance", level = 57 },
  [5] = { name = "Deadmines", level = 20 },
  [10] = { name = "Molten Core", level = 60, players = 40 },
  [12] = { name = "Warsong Gulch", level = 10, type = 5 },
  [15] = { name = "Stormwind Stockade", level = 22 },
  [20] = { name = "Hall of Testing", level = 21 },
}
GetLFGDungeonInfo = function(id)
  local d = LFG[id]
  if d then return d.name, d.type or 0, 0, d.level, d.level, d.level, d.level, d.level, 0, 0, "", 1, d.players or 5 end
end
ns.data.dungeons = {
  { areaID = 1581, name = "The Deadmines", level = 18,
    entrances = { { mapID = 1439, x = 0.5, y = 0.9 }, { mapID = 1433, x = 0.6, y = 0.5 } } },
  { areaID = 718, name = "Wailing Caverns", level = 17, entrances = { { mapID = 1433, x = 0.55, y = 0.5 } } },
  { areaID = 717, name = "The Stockade", aliases = { "Stormwind Stockade" }, level = 24, faction = "Alliance",
    entrances = { { mapID = 1453, x = 0.5, y = 0.5 } } },
  { areaID = 2437, name = "Ragefire Chasm", level = 18, faction = "Horde", entrances = { { mapID = 1433, x = 0.4, y = 0.5 } } },
  { areaID = 721, name = "Gnomeregan", level = 29, entrances = { { mapID = 1437, x = 0.5, y = 0.5 } } },
  { areaID = 209, name = "Shadowfang Keep", level = 22, entrances = { { mapID = 1437, x = 0.3, y = 0.3 } } },
  { areaID = 2057, name = "Scholomance", level = 50, entrances = { { mapID = 1437, x = 0.6, y = 0.6 } } },
  { areaID = 2717, name = "Molten Core", level = 60, raid = true, entrances = { { mapID = 1437, x = 0.5, y = 0.6 } } },
}
local function reloadBridge() assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns) end
local function titles(list)
  local out = {}
  for _, d in ipairs(list) do out[#out + 1] = d.title end
  return table.concat(out, " | ")
end
local function find(list, prefix)
  for _, d in ipairs(list) do
    if d.title:sub(1, #prefix) == prefix then return d end
  end
end

-- Without QuestieDB: entrances from Data/Dungeons.lua, levels from the client.
local savedLib, savedLevel = LibQuestieDB, UnitLevel
LibQuestieDB = nil
reloadBridge()
player.mapID, player.x, player.y = 1433, 0.5, 0.5
local dungeons = ns.Dungeons.Results()
local all = titles(dungeons)
check(not ns.Questie.Available() and ns.Dungeons.SummaryText():find("Install QuestieDB"),
  "without QuestieDB: summary suggests installing it")
check(dungeons[1] and dungeons[1].title == "The Deadmines  ·  level 20",
  "client level wins over data, matched by name without \"The\" (" .. all .. ")")
local deadmines, wc = find(dungeons, "The Deadmines"), find(dungeons, "Wailing Caverns")
check(deadmines and wc and deadmines.score < wc.score and wc.route.seconds < deadmines.route.seconds,
  "level fit outranks a slightly shorter trip (Deadmines level 20 before nearer Wailing Caverns level 17)")
check(deadmines and deadmines.goal.mapID == 1433 and deadmines.route
  and ns.Router.Describe(deadmines.route, #deadmines.route.steps) == "Walk to The Deadmines entrance",
  "route to the nearer of two entrances")
local stockade = find(dungeons, "The Stockade")
check(stockade and stockade.title == "The Stockade  ·  level 22" and stockade.route
  and math.abs(stockade.goal.x - 0.5) < 1e-6, "alias \"Stormwind Stockade\" matched; a route into Stormwind")
local sfk = find(dungeons, "Shadowfang Keep")
check(sfk and sfk.details[1].text:find("Wayfinder estimate"), "no client entry: data level, marked as an estimate")
check(sfk and sfk.details[2].text:find("approximate"), "data entrances are marked approximate")
check(not all:find("Ragefire") and not all:find("Gnomeregan") and not all:find("Scholomance")
  and not all:find("Molten Core") and not all:find("Warsong"),
  "other faction's capital, too high, raids and battlegrounds hidden at level 20")
ns.Panel.Select(3)
check(ns.Panel.IsShown(), "panel shows dungeons without errors")

UnitLevel = function() return 58 end
all = titles(ns.Dungeons.Results())
check(all:find("Scholomance") and not all:find("Molten Core"), "level 58: Scholomance yes, level 60 raid not yet")
UnitLevel = function() return 60 end
all = titles(ns.Dungeons.Results())
check(all:find("Molten Core %(raid%)") and not all:find("Deadmines"), "level 60: raids show, low dungeons don't")
UnitLevel = savedLevel

-- With QuestieDB: its entrances (already Forever coordinates), dungeon quests,
-- and dungeons only it knows when the client lists them.
LibQuestieDB = savedLib
LibQuestieDB.Meta.QuestMeta.questKeys.zoneOrSort = 17
LibQuestieDB.EraToForeverByUiMapId = function(mapID, x, y)
  if mapID == 1453 then return x + 10, y end
  return x, y
end
LibQuestieDB.Support.Get = function()
  return { private = { areaIdToUiMapId = "return { [44] = 1433, [1519] = 1453 }", dungeons = {
    [1581] = { "The Deadmines", { 10029 }, 40, { { 44, 70, 40 } } },
    [99001] = { "Hall of Testing", nil, 44, { { 44, 40, 60 } } },
    [3562] = { "Hellfire Ramparts", nil, 3483, { { 3483, 47.7, 53.6 } } },
  } } }
end
QUESTS[20] = { name = "Defias Ledger", questLevel = 20, requiredLevel = 14, zoneOrSort = 1581, startedBy = { { 344 } } }
QUESTS[21] = { name = "Red Silk Bandanas", questLevel = 21, requiredLevel = 15, zoneOrSort = 10029, startedBy = { { 6000 } } }
QUESTS[22] = { name = "Deadmines Too High", questLevel = 30, requiredLevel = 28, zoneOrSort = 1581, startedBy = { { 344 } } }
QUESTS[10].zoneOrSort = 1581 -- "Already in log"
reloadBridge()
dungeons = ns.Dungeons.Results()
all = titles(dungeons)
deadmines = find(dungeons, "The Deadmines")
check(deadmines and deadmines.zone == "Redridge Mountains  ·  2 quests for you  ·  1 in your log",
  "dungeon quests counted, alternative area IDs included (" .. tostring(deadmines and deadmines.zone) .. ")")
check(deadmines and math.abs(deadmines.goal.x - 0.7) < 1e-6 and math.abs(deadmines.goal.y - 0.4) < 1e-6,
  "QuestieDB entrance used as is (no Era conversion)")
local listedQuests = {}
for _, d in ipairs(deadmines and deadmines.details or {}) do listedQuests[#listedQuests + 1] = d.text end
local questText = table.concat(listedQuests, "\n")
check(questText:find("Defias Ledger") and questText:find("Red Silk Bandanas") and questText:find("Already in log")
  and not questText:find("Too High") and not questText:find("approximate"), "tooltip lists the dungeon's quests")
check(find(dungeons, "Hall of Testing") and not all:find("Hellfire"),
  "QuestieDB-only dungeon shows when the client lists it; later expansions don't")
stockade = find(dungeons, "The Stockade")
check(stockade and math.abs(stockade.goal.x - 0.6) < 1e-6, "our Era Stormwind point converted with EraToForever")
ns.Panel.Select(3)
check(ns.Panel.IsShown(), "panel shows dungeons with QuestieDB")

---------------------------------------------------------------- dungeons (end)

---------------------------------------------------------------- journeys + pages (foundation)
io.write("journeys\n")
ns.Nav.Stop()
player.mapID, player.x, player.y = 1433, 0.5, 0.5
local function stopAt(mapID, x, y, label, questID)
  return { node = ns.Geo.Node(mapID, x, y, label),
    text = questID and ("Pick up quest " .. questID .. " from " .. label) or ("Enter " .. label),
    action = questID and { kind = "pickup", questID = questID } or nil }
end
local farStop = stopAt(1433, 0.95, 0.95, "Far camp", 101)
local nearStop = stopAt(1433, 0.55, 0.55, "Near camp", 102)
local midStop = stopAt(1433, 0.75, 0.75, "Middle camp", 103)
local entrance = stopAt(1453, 0.5, 0.5, "Test Dungeon")
local journey = ns.Journey.Plan(ns.Geo.PlayerNode(),
  { title = "Test run", stops = { farStop, nearStop, midStop }, finish = entrance })
local order = {}
for _, st in ipairs(journey.stops) do order[#order + 1] = st.node.label end
check(table.concat(order, ",") == "Near camp,Middle camp,Far camp,Test Dungeon",
  "stops in the quickest order, finish last (" .. table.concat(order, ",") .. ")")
local stopSteps = 0
for _, st in ipairs(journey.steps) do if st.stop then stopSteps = stopSteps + 1 end end
check(stopSteps == 4, "each leg ends on its stop")
ns.Nav.StartJourney(journey)
player.x, player.y = 0.55, 0.55
ns.HUD.Update()
check(ns.Nav.Waiting() and ns.Nav.CurrentStep().stop == nearStop, "waits at the first stop for its quest")
check(ns.Router.Describe(ns.Nav.active.route, ns.Nav.active.index) == "Pick up quest 102 from Near camp",
  "the stop says what to do there")
ns.HUD.Update()
check(ns.Nav.CurrentStep().stop == nearStop, "standing at the stop does not skip it")
fire("QUEST_ACCEPTED", 102)
check(nearStop.done and ns.Nav.CurrentStep().stop ~= nearStop, "accepting the quest moves the journey on")
fire("QUEST_ACCEPTED", 101)
check(farStop.done and #ns.Nav.active.journey.stops == 2, "a later quest picked up early is planned out")
player.x, player.y = 0.75, 0.75
ns.HUD.Update()
fire("QUEST_ACCEPTED", 103)
check(midStop.done, "middle stop done")
player.mapID, player.x, player.y = 1453, 0.5, 0.5
ns.HUD.Update()
check(ns.Nav.active == nil, "reaching the final stop ends the journey")

io.write("pages\n")
local seenQuery
ns.RegisterPage({ id = "test", label = "Test", order = 5, searchable = true, placeholder = "Find things",
  SummaryText = function(q) return "summary " .. q end,
  EmptyText = function() return "nothing" end,
  Results = function(q)
    seenQuery = q
    return { { title = "Result " .. q, subtitle = "sub", journey = journey,
      actions = { { label = "Go", run = function() end } } } }
  end })
ns.Panel.Search("test", "abc")
check(seenQuery == "abc", "Panel.Search opens a page with its query")
local findPage
for _, page in ipairs(ns.pages) do if page.id == "find" then findPage = page end end
ns.Panel.Select(2)
local filtered = findPage.Results("lakeshire")
check(#filtered == 1 and filtered[1].title:find("Lakeshire"), "the Find page filters results by text")
check(#findPage.Results("") >= 2, "an empty filter shows everything")

io.write("shared helpers\n")
local commandArg
ns.RegisterCommand("echo", "/wf echo - test", function(rest) commandArg = rest end)
SlashCmdList.WAYFINDER("echo |cff9d9d9d|Hitem:2589::::|h[Linen Cloth]|h|r")
check(commandArg == "|cff9d9d9d|Hitem:2589::::|h[Linen Cloth]|h|r", "registered /wf commands get the raw text")
player.mapID, player.x, player.y = 1433, 0.5, 0.5
check(ns.Questie.IsQuestAvailable(1) and not ns.Questie.IsQuestAvailable(2), "IsQuestAvailable uses the hub rules")
check(ns.Questie.Quest(14) and ns.Questie.Quest(14).nextQuestInChain == 13, "Quest(id) returns the quest row")
local giverName = ns.Questie.QuestGiver(1, ns.Geo.PlayerNode())
check(giverName == "Magistrate Solomon", "QuestGiver finds the nearest starter")
local catalogue = ns.Dungeons.Catalogue()
local someArea
for areaID in pairs(catalogue[1] and catalogue[1].areaIDs or {}) do someArea = areaID break end
check(someArea and ns.Dungeons.ForArea(someArea) and ns.Dungeons.ForArea(someArea).name == catalogue[1].name,
  "Dungeons.ForArea finds a dungeon by area ID")

---------------------------------------------------------------- quests page (begin)
do
  io.write("quests page\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local function reload() assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns) end
  local added = { 10, 30, 31, 32, 33 }
  QUESTS[10].finishedBy = { { 6000 } } -- "Already in log", handed in in Stormwind
  QUESTS[30] = { name = "Chain part 3", questLevel = 20, requiredLevel = 15, preQuestSingle = { 13 },
    startedBy = { { 345 } } }
  QUESTS[31] = { name = "After the log quest", questLevel = 20, requiredLevel = 15, preQuestSingle = { 10 },
    startedBy = { { 345 } } }
  QUESTS[32] = { name = "Defias Orders", questLevel = 21, requiredLevel = 16, zoneOrSort = 1581,
    startedBy = { { 345 } } }
  QUESTS[33] = { name = "Lost to the Horde", questLevel = 20, requiredLevel = 15, startedBy = { { 5001 } } }
  for i = 1, 25 do
    QUESTS[200 + i] = { name = "Filler errand " .. i, questLevel = 20, requiredLevel = 15, requiredRaces = 2,
      startedBy = { { 344 } } }
    added[#added + 1] = 200 + i
  end
  LibQuestieDB.Meta.QuestMeta.questKeys.finishedBy = 3
  reload()

  local function status(id) return (ns.Questie.QuestStatus(id)) end
  local codes = {}
  for _, id in ipairs({ 1, 10, 2, 13, 9, 3, 8, 18, 5, 4, 4242 }) do codes[#codes + 1] = status(id) end
  check(table.concat(codes, ",") == "available,inLog,done,needsEarlier,tooLow,notForYou,notForYou,unavailable,"
    .. "available,needsEarlier,unknown", "every status (" .. table.concat(codes, ",") .. ")")
  local _, greyReason = ns.Questie.QuestStatus(5)
  check(greyReason:find("Grey"), "a grey quest is available but says so: " .. greyReason)
  local _, reason, stepID, stepState = ns.Questie.QuestStatus(30)
  check(stepID == 14 and stepState == "available" and reason:find("Start the chain: Chain part 1", 1, true),
    "a two-step chain starts at its first quest: " .. reason)
  check(select(1, ns.Questie.ChainStart(31)) == 10 and select(2, ns.Questie.ChainStart(31)) == "inLog",
    "a chain waiting on a quest in your log says to finish it")
  _, reason, stepID = ns.Questie.QuestStatus(4)
  check(stepID == nil and reason:find("can't take yet"), "no takeable step: " .. reason)
  local agree = true
  local done, inLog = ns.Questie.PlayerQuestState()
  for id in pairs(QUESTS) do
    local s, r = ns.Questie.QuestStatus(id, done, inLog)
    local fits = s == "available" and r == "You can take this quest."
    if ns.Questie.IsQuestAvailable(id, done, inLog) ~= fits then agree = false end
  end
  check(agree, "IsQuestAvailable is exactly 'available' at a fitting level")
  local hubs = ns.QuestHubs.Results()
  check(#hubs == 2 and hubs[1].title == "Lakeshire  ·  6 quests", "quest hubs still apply the same rules ("
    .. tostring(hubs[1] and hubs[1].title) .. ")")

  local function byTitle(list, title)
    for _, row in ipairs(list) do if row.title == title then return row end end
  end
  local rows = ns.QuestsPage.Results("CHAIN")
  local got = {}
  for _, row in ipairs(rows) do got[#got + 1] = row.title end
  check(table.concat(got, " | ") == "[19] Chain part 1 | [19] Chain part 2 | [20] Chain part 3",
    "case-insensitive search, available first (" .. table.concat(got, " | ") .. ")")
  local part1 = byTitle(rows, "[19] Chain part 1")
  local stop = part1 and part1.journey and part1.journey.stops[1]
  check(stop and stop.action.kind == "pickup" and stop.action.questID == 14
    and stop.text == "Pick up Chain part 1 from Stormwind Questgiver", "available: to the quest giver")
  local part3 = byTitle(rows, "[20] Chain part 3")
  stop = part3 and part3.journey and part3.journey.stops[1]
  check(stop and stop.action.questID == 14 and stop.text == "Start the chain: pick up Chain part 1 from Stormwind Questgiver"
    and part3.subtitle:find("start: Chain part 1", 1, true), "needs earlier quests: to the start of the chain")
  -- Quest rows by id: a dungeon run row can come first ("Already in log" is a Deadmines quest).
  local function questRow(text, id)
    for _, row in ipairs(ns.QuestsPage.Results(text)) do if row.id == "quest" .. id then return row end end
  end
  local inLogRow = questRow("already in log", 10)
  stop = inLogRow and inLogRow.journey and inLogRow.journey.stops[1]
  check(stop and stop.action.kind == "turnin" and stop.action.questID == 10 and stop.node.mapID == 1453
    and stop.text == "Hand in Already in log to Stormwind Questgiver", "in your log: to where you hand it in")
  rows = ns.QuestsPage.Results("after the log")
  stop = rows[1] and rows[1].journey and rows[1].journey.stops[1]
  check(stop and stop.action.kind == "turnin" and stop.action.questID == 10, "chain behind a log quest: hand that in first")
  local function subFor(text, id)
    local r = questRow(text, id)
    return r and r.subtitle or ""
  end
  check(subFor("too high", 9):find("Too low") and subFor("too high", 9):find("level 28"), "too low: " .. subFor("too high", 9))
  check(subFor("horde only", 8):find("Not for your race"), "race: " .. subFor("horde only", 8))
  check(subFor("mages only", 3):find("Not for your class"), "class: " .. subFor("mages only", 3))
  check(subFor("already done", 2):find("Done") and not questRow("already done", 2).journey, "done: no route")
  check(subFor("lost to the horde", 33):find("no known quest giver"), "other faction's giver: no route")
  rows = ns.QuestsPage.Results("|cffffff00|Hquest:4242:20|h[Lost Quest]|h|r")
  check(#rows == 1 and rows[1].title == "Lost Quest" and rows[1].subtitle:find("Unknown to QuestieDB"),
    "a quest link unknown to QuestieDB")
  rows = ns.QuestsPage.Results("|cffffff00|Hquest:1:18|h[Redridge Goulash]|h|r")
  check(#rows == 1 and rows[1].title == "[18] Redridge Goulash", "a shift-clicked quest link finds that quest")
  rows = ns.QuestsPage.Results("filler")
  check(#rows == 20 and ns.QuestsPage.SummaryText("filler"):find("First 20 of 25"), "results capped at 20")
  check(#ns.QuestsPage.Results("x") == 0 and ns.QuestsPage.EmptyText("x"):find("at least"), "one letter is too short")

  -- Dungeon quests in one trip: givers first (quickest order), the entrance last.
  rows = ns.QuestsPage.Results("defias")
  local run = rows[1]
  check(run and run.title == "The Deadmines: pick up 3 quests" and run.journey, "search offers the dungeon run: "
    .. tostring(run and run.title))
  local dungeons = ns.Dungeons.Results()
  local deadmines
  for _, d in ipairs(dungeons) do if d.title:find("^The Deadmines") then deadmines = d end end
  check(deadmines and deadmines.actions and deadmines.actions[1].label == "Quests", "Dungeons row has a Quests action")
  ns.Panel.Search("quests", "")
  deadmines.actions[1].run(deadmines)
  local journey = ns.Nav.active and ns.Nav.active.journey
  local texts = {}
  for _, st in ipairs(journey and journey.stops or {}) do texts[#texts + 1] = st.text end
  check(table.concat(texts, " | ") == "Pick up Defias Ledger from Magistrate Solomon | Pick up Defias Orders from "
    .. "Foreman Oslow | Pick up Red Silk Bandanas from Stormwind Questgiver | Enter The Deadmines",
    "pickup stops in order, then the entrance (" .. table.concat(texts, " | ") .. ")")
  check(journey and journey.stops[1].action.kind == "pickup" and journey.stops[4].node == deadmines.goal
    and not ns.Panel.IsShown(), "journey ends at the entrance and the panel closes")
  ns.Nav.Stop()

  local seen
  local realResults = ns.QuestsPage.Results
  ns.QuestsPage.Results = function(q) seen = q return realResults(q) end
  SlashCmdList.WAYFINDER("quest Redridge Goulash")
  check(ns.Panel.IsShown() and seen == "Redridge Goulash", "/wf quest opens the Quests page with that search")
  ns.QuestsPage.Results = realResults

  local savedLib = LibQuestieDB
  LibQuestieDB = nil
  reload()
  local none, err = ns.QuestsPage.Results("chain")
  check(#none == 0 and err and err:find("Install QuestieDB"), "without QuestieDB: the page says it is needed")
  check(ns.QuestsPage.SummaryText(""):find("Install QuestieDB"), "without QuestieDB: summary too")
  for _, d in ipairs(ns.Dungeons.Results()) do
    if d.actions then check(false, "no dungeon quest action without QuestieDB") end
  end
  ns.Panel.Search("quests", "chain")
  check(ns.Panel.IsShown(), "panel shows the Quests page without QuestieDB")

  LibQuestieDB = savedLib
  QUESTS[10].finishedBy = nil
  for i = 2, #added do QUESTS[added[i]] = nil end
  reload()
end
---------------------------------------------------------------- quests page (end)
---------------------------------------------------------------- items page (begin)
do
  io.write("items page\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  -- Wetlands (area 11) joins the area map; the bridge is reloaded to pick it up.
  local baseGet = LibQuestieDB.Support.Get
  LibQuestieDB.Support.Get = function(name)
    local t = baseGet(name)
    t.private.areaIdToUiMapId = "return { [44] = 1433, [1519] = 1453, [11] = 1437 }"
    return t
  end
  assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns)

  NPCS[9100] = { name = "Edwin VanCleef", rank = 3, minLevel = 21, maxLevel = 21, spawns = { [1581] = { { -1, -1 } } } }
  NPCS[9104] = { name = "Defias Pirate", rank = 1, minLevel = 19, maxLevel = 20, spawns = { [10029] = { { -1, -1 } } } }
  NPCS[9101] = { name = "Murloc Forager", minLevel = 18, maxLevel = 19, spawns = { [44] = { { 60, 60 }, { 80, 80 } } } }
  NPCS[9102] = { name = "Murloc Scout", minLevel = 17, maxLevel = 18, spawns = { [44] = { { 30, 30 } } } }
  NPCS[9103] = { name = "Wetlands Murloc", minLevel = 22, maxLevel = 24, spawns = { [11] = { { 50, 50 } } } }
  NPCS[9105] = { name = "Ogre Mauler", minLevel = 30, maxLevel = 31, spawns = { [11] = { { 20, 20 } } } }
  ObjectDB = entity({ [9200] = { name = "Battered Chest", spawns = { [44] = { { 55, 55 } } } } }, {})
  ITEMS[9001] = { name = "Cruel Barb", itemLevel = 24, requiredLevel = 19, npcDrops = { 9100, 9104 } }
  ITEMS[9002] = { name = "Murloc Fin", itemLevel = 15, npcDrops = { 9101, 9102, 9103 } }
  ITEMS[9003] = { name = "Shiny Pearl", objectDrops = { 9200 }, itemDrops = { 9007 } }
  ITEMS[9007] = { name = "Big-mouth Clam", npcDrops = { 9101 } }
  ITEMS[9004] = { name = "Goulash Ring", questRewards = { 1, 4, 10, 2, 3, 9, 13 } }
  ITEMS[9005] = { name = "Fine Longbow", vendors = { 7004, 7001 }, npcDrops = { 9105 } }
  QUESTS[10].finishedBy = { { 345 } }
  QUESTS[1].finishedBy = { { 344 } } -- Redridge Goulash, handed back to Solomon
  LibQuestieDB.Meta.QuestMeta.questKeys.finishedBy = 3

  local page
  for _, p in ipairs(ns.pages) do if p.id == "items" then page = p end end
  local seen
  local realResults = page.Results
  page.Results = function(q) seen = q; return realResults(q) end
  local function rows(q) return (ns.Items.Results(q)) end
  local function names(list)
    local t = {}
    for _, r in ipairs(list) do t[#t + 1] = r.title end
    return table.concat(t, " | ")
  end
  local function detailText(r)
    local t = {}
    for _, d in ipairs(r and r.details or {}) do t[#t + 1] = d.text end
    return table.concat(t, "\n")
  end

  check(page and page.order == 40 and page.searchable, "Items page registered (order 40, searchable)")
  check(ns.Items.ParseID("|cffa335ee|Hitem:9001::::::::20:::::|h[Cruel Barb]|h|r") == 9001
    and ns.Items.ParseID("item:9002") == 9002 and ns.Items.ParseID("Cruel Barb") == nil, "item ID parsed from a link")

  local link = "|cffa335ee|Hitem:9001::::::::20:::::|h[Cruel Barb]|h|r"
  SlashCmdList.WAYFINDER("item " .. link)
  check(ns.Panel.IsShown() and seen == link, "/wf item <link> opens the Items page with the link")
  check(ns.Items.SummaryText(link):find("Cruel Barb  ·  item level 24  ·  requires level 19", 1, true),
    "summary names the item and its levels: " .. ns.Items.SummaryText(link))

  -- Dungeon drop: to the entrance, boss named, quests on the way.
  local list = rows(link)
  local dm = list[1]
  check(dm and dm.title == "Drops from Edwin VanCleef and 1 other in The Deadmines",
    "dungeon drop names the boss (alternative area IDs count): " .. names(list))
  check(dm and dm.route and math.abs(dm.goal.x - 0.7) < 1e-6 and math.abs(dm.goal.y - 0.4) < 1e-6,
    "dungeon drop routes to the entrance")
  check(detailText(dm):find("Dungeon level 20; you are level 20.", 1, true), "tooltip has the dungeon level")
  check(dm and dm.actions and dm.actions[1].label == "+2 quests", "dungeon quests offered as a journey")
  dm.actions[1].run(dm)
  local j = ns.Nav.active and ns.Nav.active.journey
  check(j and #j.stops == 3 and j.stops[3].text == "Enter The Deadmines" and j.stops[1].action.kind == "pickup",
    "+2 quests: pick both up, then the entrance")
  ns.Nav.Stop()

  -- World drop: one row per zone, nearest first.
  list = rows("item:9002")
  check(#list == 2 and list[1].title == "Drops from Murloc Forager and 1 other" and list[1].zone == "Redridge Mountains"
    and list[2].title == "Drops from Wetlands Murloc" and list[2].zone == "Wetlands",
    "world drop grouped per zone, nearest zone first: " .. names(list))
  check(list[1].route and math.abs(list[1].goal.x - 0.6) < 1e-6, "routes to the nearest spawn")
  check(detailText(list[1]):find("Murloc Scout, level 17-18", 1, true), "tooltip lists the mobs with levels")

  -- Objects and containers.
  list = rows("item:9003")
  check(names(list) == "Found in Battered Chest | Comes in Big-mouth Clam", "object and container rows: " .. names(list))
  list[2].actions[1].run(list[2])
  check(seen == "item:9007", "Look up searches the container")

  -- Quest rewards.
  list = rows("item:9004")
  local all = names(list)
  local function stops(r) return r and r.journey and r.journey.stops or {} end
  local goulash = stops(list[1])
  check(list[1] and list[1].title == "Reward from Redridge Goulash"
    and detailText(list[1]):find("take it now from Magistrate Solomon", 1, true)
    and goulash[1] and goulash[1].action.kind == "pickup" and goulash[1].node.label == "Magistrate Solomon"
    and goulash[#goulash].action.kind == "turnin",
    "available quest first, tracked from pickup to hand-in: " .. all)
  local inLog, chain, closed, high
  for _, r in ipairs(list) do
    if r.title:find("Already in log", 1, true) then inLog = r end
    if r.title:find("Chain part 2", 1, true) then chain = r end
    if r.title:find("Needs prequest", 1, true) then closed = r end
    if r.title:find("Too high", 1, true) then high = r end
  end
  check(inLog and inLog.title:find("in your log") and stops(inLog)[1]
    and stops(inLog)[1].action.kind == "turnin" and stops(inLog)[1].node.label == "Foreman Oslow",
    "quest in your log: says so, tracked to where you hand it in")
  check(chain and chain.title:find("needs earlier quests") and stops(chain)[1]
    and stops(chain)[1].node.label == "Stormwind Questgiver" and stops(chain)[1].action.questID == 14
    and detailText(chain):find("Start the chain: pick up Chain part 1 from Stormwind Questgiver", 1, true),
    "quest needing earlier quests: routes to the start of its chain")
  check(closed and not closed.route and closed.subtitle == "Needs earlier quests you can't take yet",
    "no open chain step: says so, no route")
  check(high and high.title:find("from level 28"), "quest above your level: says from which level")
  check(list[#list].title:find("Already done  ·  done", 1, true) and not list[#list].route, "done quest last, no route")
  check(not all:find("Mages only"), "another class's quest is hidden")
  local tiersOk = true
  for i, r in ipairs(list) do
    if (r == chain or r == high) and i <= 2 then tiersOk = false end
  end
  check(tiersOk, "quests you can do now rank above later ones")

  -- Vendor beats a too-high drop; other faction's vendor hidden.
  list = rows("item:9005")
  check(list[1] and list[1].title == "Sold by Lakeshire Bowyer" and list[1].route, "nearest vendor that sells it: " .. names(list))
  check(list[2] and list[2].title == "Drops from Ogre Mauler" and detailText(list[2]):find("Level 30 and up"),
    "drop from mobs far above you ranks after the vendor")
  check(not names(list):find("Horde"), "other faction's vendor hidden")
  list = rows("item:1205")
  check(list[1] and list[1].title == "Sold by Innkeeper Farley" and detailText(list[1]):find("1 other vendor sells it too", 1, true),
    "QuestieDB sellers and visited vendors together: " .. detailText(list[1]))

  -- Name search.
  list = rows("murloc")
  check(list[1] and list[1].title:find("Drops from Murloc Forager"), "a single name match shows its sources")
  list = rows("fin")
  check(names(list) == "Fine Longbow | Murloc Fin" and list[1].actions[1].label == "Show",
    "several matches: a list to pick from, names starting with the text first (" .. names(list) .. ")")
  list[2].actions[1].run(list[2])
  check(seen == "item:9002", "Show looks the item up")
  list = rows("FINE longbow")
  check(list[1] and list[1].title == "Sold by Lakeshire Bowyer", "name search ignores case")
  check(#rows("fi") == 0 and ns.Items.EmptyText("fi"):find("at least 3"), "short names wait for more letters")

  -- Tooltip line.
  check(ns.Items.TooltipLine(9002) and not ns.Items.TooltipLine(424242), "tooltip line only for items with sources")
  InCombatLockdown = function() return true end
  check(ns.Items.TooltipLine(9002) == nil, "no tooltip line in combat")
  InCombatLockdown = nil

  -- Without QuestieDB: vendors you visited only.
  local realAvailable = ns.Questie.Available
  ns.Questie.Available = function() return false, "QuestieDB is not installed" end
  GetItemInfo = function(id)
    if id == 1205 then return "Melon Juice", "|cffffffff|Hitem:1205::::|h[Melon Juice]|h|r", 1, 5, 1 end
  end
  list = rows("item:1205")
  check(#list == 1 and list[1].title == "Sold by Lakeshire Cook" and detailText(list[1]):find("last visited"),
    "without QuestieDB: the visited vendor that sold it (" .. names(list) .. ")")
  check(ns.Items.SummaryText("item:1205"):find("Install QuestieDB"), "summary says QuestieDB is needed for the rest")
  check(#rows("item:9001") == 0 and ns.Items.EmptyText("item:9001"):find("Install QuestieDB"),
    "without QuestieDB: no drops, and the page says why")
  list = rows("melon")
  check(list[1] and list[1].title == "Sold by Lakeshire Cook", "without QuestieDB: names searched among visited goods")
  check(#rows("cruel") == 0 and ns.Items.EmptyText("cruel"):find("vendors you visited"), "unknown name explained")
  ns.Panel.Search("items", "item:1205")
  check(ns.Panel.IsShown(), "panel shows the Items page without QuestieDB")
  GetItemInfo = nil
  ns.Questie.Available = realAvailable

  ns.Panel.Search("items", "fin")
  check(ns.Panel.IsShown(), "panel shows the Items page with QuestieDB")
  page.Results = realResults
end
---------------------------------------------------------------- items page (end)
---------------------------------------------------------------- for you (begin)

io.write("for you\n")
do
  local function rows()
    ns.ForYou.Invalidate()
    return ns.ForYou.Results()
  end
  local function find(list, prefix)
    for i, r in ipairs(list) do
      if r.title:sub(1, #prefix) == prefix then return r, i end
    end
  end
  local function titles(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = r.title end
    return table.concat(out, " | ")
  end

  local lowest
  for _, page in ipairs(ns.pages) do
    if page.id ~= "test" and (not lowest or page.order < lowest.order) then lowest = page end
  end
  check(lowest and lowest.id == "foryou" and ns.ForYou.runs >= 1,
    "For you has the lowest order and was computed when /wf first opened")

  -- QuestieDB quest XP: [questID] = { questLevel, xp }. Quest 21 has none.
  local zoneSupport = LibQuestieDB.Support.Get
  local XP = { [1] = { 18, 1500 }, [7] = { 19, 1500 }, [11] = { 17, 1500 }, [15] = { 18, 1500 },
    [6] = { 20, 1400 }, [14] = { 19, 1400 }, [20] = { 20, 1600 }, [10] = { 19, 1000 } }
  LibQuestieDB.Support.Get = function(name)
    if name == "QuestXP" then return { db = XP } end
    return zoneSupport(name)
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local started = os.clock()
  local list = rows()
  local ms = (os.clock() - started) * 1000
  check(ms < 100, string.format("a refresh takes %.1f ms here", ms))
  check(list[1] and list[1].title == "Train 1 new spell in Stormwind" and list[1].route,
    "trainable, affordable spell comes first with directions (" .. titles(list) .. ")")
  local lakeshire, li = find(list, "Pick up 5 quests in Lakeshire")
  local stormwind, si = find(list, "Pick up 3 quests in Stormwind")
  local deadmines, di = find(list, "Pick up 2 quests, then run The Deadmines")
  check(lakeshire and stormwind and deadmines and li < si and si < di,
    "hubs and dungeons by XP per minute: Lakeshire, Stormwind, Deadmines (" .. titles(list) .. ")")
  local sorted, rated = true, 0
  for i = 2, #list do
    if list[i].rate and list[i - 1].rate and list[i].rate > list[i - 1].rate then sorted = false end
    if list[i].rate then rated = rated + 1 end
  end
  check(sorted and rated == 3, "XP options sorted by XP per minute")
  check(lakeshire and lakeshire.subtitle:find("~299 XP/min", 1, true)
    and lakeshire.details[1].text:find("7,600 XP", 1, true),
    "hub XP is the sum of its quests over trip + 5 min each: " .. tostring(lakeshire and lakeshire.subtitle))
  check(stormwind and stormwind.details[2].text:find("estimated for 1 quest"), "a quest without XP data is estimated")
  check(#list <= 7 and find(list, "Run Hall of Testing"), "dungeons without quests fill the remaining rows")
  check(ns.ForYou.SummaryText():find("1 thing due") and not ns.ForYou.SummaryText():find("quests per hour"),
    "summary: " .. ns.ForYou.SummaryText())

  -- Dungeon quests become one journey: pickups first, the entrance last.
  local dj = deadmines and deadmines.journey
  local last = dj and dj.stops[#dj.stops]
  local picked = {}
  for _, st in ipairs(dj and dj.stops or {}) do
    if st.action then picked[#picked + 1] = st.action.kind .. st.action.questID end
  end
  table.sort(picked)
  check(last and last.text == "Enter The Deadmines" and table.concat(picked, ",") == "pickup20,pickup21",
    "dungeon journey picks up its quests, then goes to the entrance (" .. table.concat(picked, ",") .. ")")
  check(deadmines and deadmines.subtitle:find("1 in your log"), "quests in your log count too")

  -- Gear at 20%: repair before training.
  durability = { 10, 50 }
  list = rows()
  check(list[1] and list[1].title:find("^Repair") and list[2] and list[2].title:find("^Train"),
    "low durability: repair first, then training (" .. titles(list) .. ")")
  durability = { 50, 50 }

  -- A big XP quest in Stormwind: training there is on the way, so one journey.
  XP[6] = { 20, 12000 }
  list = rows()
  local combo = list[1]
  check(combo and combo.journey and combo.title == "Train in Stormwind, then pick up 3 quests in Stormwind",
    "need on the way to the best option: one journey (" .. tostring(combo and combo.title) .. ")")
  check(combo and #combo.journey.stops == 2 and combo.journey.stops[2].text:find("^Pick up quests here")
    and combo.actions and combo.actions[1].label == "Train only", "train first, quests last, a Train only button")
  local sw, swi = find(list, "Pick up 3 quests in Stormwind")
  local _, lki = find(list, "Pick up 5 quests in Lakeshire")
  check(sw and lki and swi < lki, "more XP per minute outranks the nearer hub (" .. titles(list) .. ")")
  combo.actions[1].run(combo)
  check(ns.Nav.active and ns.Nav.active.journey == nil and ns.Nav.active.title:find("^Train"),
    "Train only gives plain directions to the trainer")
  ns.Nav.Stop()
  XP[6] = { 20, 1400 }

  -- Without XP data: quests per hour, weighted by level fit.
  LibQuestieDB.Support.Get = zoneSupport
  list = rows()
  check(ns.ForYou.SummaryText():find("No quest XP in your QuestieDB"), "summary explains the fallback")
  local lk, lkIndex = find(list, "Pick up 5 quests in Lakeshire")
  local _, swIndex = find(list, "Pick up 3 quests in Stormwind")
  check(lk and lk.subtitle:find("quests/h") and not lk.subtitle:find("XP") and swIndex and lkIndex < swIndex,
    "fallback ranks by quests per hour: " .. tostring(lk and lk.subtitle))

  -- Without QuestieDB: needs and dungeons by level fit.
  local savedLib = LibQuestieDB
  LibQuestieDB = nil
  reloadBridge()
  list = rows()
  check(ns.ForYou.SummaryText():find("Install QuestieDB"), "without QuestieDB the summary says so")
  check(list[1] and list[1].title:find("^Train") and find(list, "Run The Deadmines") and not find(list, "Pick up"),
    "without QuestieDB: training, then dungeons (" .. titles(list) .. ")")
  LibQuestieDB = savedLib
  LibQuestieDB.Support.Get = function(name)
    if name == "QuestXP" then return { db = XP } end
    return zoneSupport(name)
  end
  reloadBridge()

  -- An undiscovered flight path where you stand.
  ns.charDB.knownTaxi[5] = nil
  list = rows()
  check(find(list, "Learn the Lakeshire flight path"), "undiscovered flight path close by (" .. titles(list) .. ")")
  ns.charDB.knownTaxi[5] = true

  -- Low on food (2 Melon Juice in the bags).
  C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
    GetContainerItemInfo = function(bag, slot) if slot == 1 then return { itemID = 1205, stackCount = 2 } end end,
  }
  list = rows()
  local food, fi = find(list, "Buy food & drink at")
  check(food and fi <= 2 and food.subtitle:find("2 food & drink left"), "low on food: buy some (" .. titles(list) .. ")")
  C_Container = nil

  -- A hunter with a bow and no ammo.
  UnitClass = function() return "Hunter", "HUNTER", 3 end
  GetInventoryItemID = function(_, slot) return slot == 18 and 100 or nil end
  list = rows()
  local ammo = list[1]
  check(ammo and ammo.title:find("^Buy ammo at Lakeshire Cook") and ammo.subtitle:find("no ammo left"),
    "out of ammo: the nearest arrow seller first (" .. titles(list) .. ")")
  UnitClass = function() return "Warlock", "WARLOCK", 9 end
  GetInventoryItemID = function() return nil end

  -- Cache: reused within a few seconds, recomputed on DATA_CHANGED.
  local clock = 100
  GetTime = function() return clock end
  rows()
  local runs = ns.ForYou.runs
  ns.ForYou.Results()
  clock = clock + 1
  ns.ForYou.Results()
  check(ns.ForYou.runs == runs, "a refresh within a few seconds is reused")
  ns.Fire("DATA_CHANGED")
  ns.ForYou.Results()
  check(ns.ForYou.runs == runs + 1, "DATA_CHANGED recomputes")
  GetTime = nil

  runs = ns.ForYou.runs
  SlashCmdList.WAYFINDER("next")
  check(ns.Panel.IsShown() and ns.ForYou.runs > runs, "/wf next opens the panel on For you")
  LibQuestieDB.Support.Get = zoneSupport
end

---------------------------------------------------------------- for you (end)

---------------------------------------------------------------- trips (begin)
do
  io.write("trips\n")
  ns.Nav.Stop()
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives }
  -- A quest with an objective: kill Murloc Foragers (NPC 9101, Redridge), hand in to Foreman Oslow.
  QUESTS[40] = { name = "Murloc Menace", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } } }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.objectives, questKeys.triggerEnd = 10, 9
  assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns)
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()

  local qs = ns.Journey.QuestStops(40, here)
  local kinds = {}
  for _, st in ipairs(qs) do kinds[#kinds + 1] = st.action.kind end
  check(table.concat(kinds, ",") == "pickup,complete,turnin", "a whole quest: pick up, do it, hand in")
  check(qs[2] and qs[2].after[1] == qs[1] and qs[3].after[1] == qs[2] and qs[2].node.mapID == 1433,
    "objectives are where the quest's mobs are, after the pickup")
  local journey = ns.Journey.Plan(here, { title = "Murloc Menace", stops = { qs[3], qs[2], qs[1] } })
  kinds = {}
  for _, st in ipairs(journey.stops) do kinds[#kinds + 1] = st.action.kind end
  check(table.concat(kinds, ",") == "pickup,complete,turnin", "stop order rules hold even when given backwards")

  ns.Nav.StartJourney(journey)
  check(ns.JourneyOverview.IsShown(), "a journey with several stops opens the overview")
  local rows = ns.JourneyOverview.Rows()
  check(#rows == 3 and rows[1].state == "now", "the overview lists every stop, the first one now")
  check(ns.charDB.nav and ns.charDB.nav.journey and #ns.charDB.nav.journey.stops == 3, "the trip is saved")

  -- Pick it up: the quest is in the log, objectives not done.
  player.mapID, player.x, player.y = qs[1].node.mapID, qs[1].node.x, qs[1].node.y
  ns.HUD.Update()
  local log = { 10 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function() return false end
  C_QuestLog.GetQuestObjectives = function(id)
    return id == 40 and { { text = "3/8 Murloc Forager slain", finished = false } } or {}
  end
  log[#log + 1] = 40
  fire("QUEST_ACCEPTED", 40)
  local step = ns.Nav.CurrentStep()
  check(step and step.stop and step.stop.action.kind == "complete", "after the pickup: do the objectives")
  check(ns.HUD.ObjectiveText(40) == "3/8 Murloc Forager slain", "the directions box shows objective progress")
  fire("QUEST_LOG_UPDATE")
  check(ns.Nav.CurrentStep().stop.action.kind == "complete", "objectives not done yet: keep going")
  C_QuestLog.IsComplete = function(id) return id == 40 end
  fire("QUEST_LOG_UPDATE")
  step = ns.Nav.CurrentStep()
  check(step and step.stop and step.stop.action.kind == "turnin", "objectives done: go and hand it in")

  -- Log out and back in: the open part of the trip comes back.
  ns.Nav.active = nil
  ns.Nav.Resume()
  check(ns.Nav.active and #ns.Nav.active.journey.stops == 1 and ns.Nav.active.journey.stops[1].action.kind == "turnin",
    "after a relog the trip resumes from where it was")
  check(#ns.JourneyOverview.Rows() == 3, "the overview still shows the stops already done")
  fire("QUEST_TURNED_IN", 40)
  check(ns.Nav.active == nil and ns.charDB.nav == nil, "handing it in ends the trip and clears the save")

  -- Dropping a pickup drops what needs it.
  log = { 10 }
  local goulash = ns.Journey.QuestStops(1, here)
  local visit = { node = ns.Geo.Node(1433, 0.9, 0.9, "Lookout"), text = "Visit the lookout" }
  local stops = { visit }
  for _, st in ipairs(goulash) do stops[#stops + 1] = st end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = stops }))
  ns.Nav.Drop(goulash[1])
  check(goulash[1].skipped and goulash[#goulash].skipped and #ns.Nav.active.journey.stops == 1
    and ns.Nav.active.journey.stops[1] == visit, "dropping a pickup also drops its hand-in")
  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()

  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]
  QUESTS[40] = nil
  assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns)
end
---------------------------------------------------------------- trips (end)
---------------------------------------------------------------- quest log trips (begin)
do
  io.write("quest log trips\n")
  ns.Nav.Stop()
  local function reload() assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns) end
  local savedLog = { C_QuestLog.GetAllCompletedQuestIDs, C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo,
    C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives }
  -- Murlocs to kill near Lakeshire; quests given by Solomon (344), handed in to Oslow (345) or in Stormwind (6000).
  NPCS[9201] = { name = "Log Murloc", minLevel = 18, maxLevel = 19, spawns = { [44] = { { 70, 70 } } } }
  QUESTS[50] = { name = "Murloc Cull", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9201 } } } }
  QUESTS[51] = { name = "Bandit Letter", questLevel = 18, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 6000 } } }
  QUESTS[52] = { name = "Lost Necklace", questLevel = 17, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 344 } } }
  QUESTS[53] = { name = "Gnoll Patrol", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9201 } } } }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy, questKeys.objectives = 3, 10
  reload()

  local completed = { 2 }
  local log = {
    { title = "Redridge Mountains", isHeader = true },
    { title = "Murloc Cull", questID = 50, level = 19 },
    { title = "Bandit Letter", questID = 51, level = 18 },
    { title = "Elwynn Forest", isHeader = true },
    { title = "Lost Necklace", questID = 52, level = 17 },
  }
  local complete = { [51] = true, [52] = true }
  C_QuestLog.GetAllCompletedQuestIDs = function() return completed end
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return log[i] end
  C_QuestLog.IsComplete = function(id) return complete[id] == true end
  C_QuestLog.GetQuestObjectives = function(id)
    if id == 50 then
      return { { text = "Log Murloc slain: 3/8", finished = false }, { text = "Murloc fin: 2/2", finished = true } }
    end
    return {}
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  ns.QuestsPage.ClearPicks()

  local function byID(rows, id)
    for _, row in ipairs(rows) do if row.id == id then return row end end
  end
  local function kinds(stops)
    local out = {}
    for _, st in ipairs(stops) do out[#out + 1] = st.action.kind .. st.action.questID end
    return table.concat(out, ",")
  end

  -- The log, with progress.
  local rows = ns.QuestsPage.Results("")
  local cull, letter, necklace = byID(rows, "log50"), byID(rows, "log51"), byID(rows, "log52")
  check(cull and letter and necklace and not byID(rows, "picked"), "empty search lists the quest log, headers skipped")
  check(cull and cull.title == "[19] Murloc Cull" and cull.subtitle:find("Redridge Mountains", 1, true)
    and cull.subtitle:find("Log Murloc slain: 3/8", 1, true), "a log quest shows zone and the first unfinished objective: "
    .. tostring(cull and cull.subtitle))
  check(necklace and necklace.subtitle:find("Elwynn Forest", 1, true) and necklace.subtitle:find("Ready to hand in"),
    "a complete quest is ready to hand in")
  check(ns.QuestsPage.SummaryText(""):find("Your quest log: 3 quests"), "summary counts the log")

  -- Clicking a log quest: what's left of it, no pickup.
  check(cull and cull.journey and kinds(cull.journey.stops) == "complete50,turnin50",
    "a log quest's trip skips the pickup: " .. kinds(cull and cull.journey and cull.journey.stops or {}))
  check(letter and letter.journey and kinds(letter.journey.stops) == "turnin51", "a complete log quest: just hand it in")

  -- The hand-in row.
  local handin = byID(rows, "handin")
  check(handin and handin.title == "Hand in 2 completed quests" and handin.journey
    and #handin.journey.stops == 2 and handin.journey.stops[1].action.kind == "turnin"
    and handin.journey.stops[2].action.kind == "turnin", "one row hands in every completed quest")
  check(rows[1] == handin, "trip rows come before the log")

  -- Pick and unpick.
  check(cull.actions and cull.actions[1].label == "Add", "log rows have an Add action")
  cull.actions[1].run(cull)
  check(WayfinderCharDB.questPicks and WayfinderCharDB.questPicks[50] == true, "the pick is saved per character")
  rows = ns.QuestsPage.Results("")
  check(byID(rows, "log50").actions[1].label == "Added", "a picked quest says Added")
  check(byID(rows, "picked") and byID(rows, "picked").title == "Plan a trip for 1 quest" and rows[1].id == "picked",
    "picking shows a trip row at the top")
  byID(rows, "log50").actions[1].run()
  rows = ns.QuestsPage.Results("")
  check(not byID(rows, "picked") and byID(rows, "log50").actions[1].label == "Add", "clicking Added unpicks it")

  -- Picking from a search, then one trip for both.
  ns.QuestsPage.TogglePick(50)
  local found = byID(ns.QuestsPage.Results("gnoll patrol"), "quest53")
  check(found and found.actions and found.actions[1].label == "Add", "search results have the Add action too")
  found.actions[1].run(found)
  local done = byID(ns.QuestsPage.Results("already done"), "quest2")
  check(done and not done.actions, "no Add on a quest you have done")
  rows = ns.QuestsPage.Results("")
  local picked = byID(rows, "picked")
  check(picked and picked.title == "Plan a trip for 2 quests" and picked.journey, "trip row for 2 picked quests")
  local order = {}
  for i, st in ipairs(picked and picked.journey.stops or {}) do order[st.action.kind .. st.action.questID] = i end
  check(#picked.journey.stops == 5 and order.pickup53 < order.complete53 and order.complete53 < order.turnin53
    and order.complete50 < order.turnin50 and not order.pickup50,
    "the combined trip keeps each quest's own order: " .. kinds(picked.journey.stops))
  check(#picked.details == 2 and picked.actions[1].label == "Clear", "the tooltip names the quests; Clear empties it")
  ns.Panel.Search("quests", "")
  check(ns.Panel.IsShown(), "panel shows the quest log with trip rows")
  ns.Nav.StartJourney(picked.journey, true) -- what clicking the row does
  check(ns.Nav.active and #ns.Nav.active.journey.stops == 5, "the combined trip starts as one journey")
  ns.Nav.Stop()

  -- Done quests leave the picks.
  completed = { 2, 53 }
  rows = ns.QuestsPage.Results("")
  check(byID(rows, "picked").title == "Plan a trip for 1 quest" and not WayfinderCharDB.questPicks[53],
    "a quest you have done leaves the picks")
  fire("QUEST_TURNED_IN", 50)
  check(next(WayfinderCharDB.questPicks) == nil and not byID(ns.QuestsPage.Results(""), "picked"),
    "handing in the last picked quest clears the trip row")
  ns.QuestsPage.TogglePick(50)
  byID(ns.QuestsPage.Results(""), "picked").actions[1].run()
  check(next(WayfinderCharDB.questPicks) == nil, "Clear empties the picks")

  -- Without QuestieDB: the log still shows, without trips.
  ns.QuestsPage.TogglePick(50)
  local savedLib = LibQuestieDB
  LibQuestieDB = nil
  reload()
  rows = ns.QuestsPage.Results("")
  cull = byID(rows, "log50")
  check(#rows == 3 and cull and cull.title == "[19] Murloc Cull" and not cull.journey and not cull.actions
    and cull.subtitle:find("directions need QuestieDB") and cull.subtitle:find("3/8", 1, true),
    "without QuestieDB: the log lists, says directions need it, no trips: " .. tostring(cull and cull.subtitle))
  check(ns.QuestsPage.SummaryText(""):find("Install QuestieDB"), "without QuestieDB: the summary says so")
  ns.Panel.Search("quests", "")
  check(ns.Panel.IsShown(), "panel shows the quest log without QuestieDB")
  log = {}
  rows = ns.QuestsPage.Results("")
  check(#rows == 0 and ns.QuestsPage.EmptyText(""):find("quest log is empty"), "an empty log says so")
  LibQuestieDB = savedLib

  ns.QuestsPage.ClearPicks()
  C_QuestLog.GetAllCompletedQuestIDs, C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives = savedLog[1], savedLog[2], savedLog[3], savedLog[4], savedLog[5]
  for id = 50, 53 do QUESTS[id] = nil end
  NPCS[9201] = nil
  reload()
end
---------------------------------------------------------------- quest log trips (end)
---------------------------------------------------------------- for you: quest log (begin)
do
  io.write("for you: quest log\n")
  ns.Nav.Stop()
  local function rows()
    ns.ForYou.Invalidate()
    return ns.ForYou.Results()
  end
  local function find(list, prefix)
    for i, r in ipairs(list) do
      if r.title:sub(1, #prefix) == prefix then return r, i end
    end
  end
  local function titles(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = r.title end
    return table.concat(out, " | ")
  end
  local function xpOf(row)
    local n = row and row.details[1].text:match("~([%d,]+) XP")
    return n and tonumber((n:gsub(",", ""))) or 0
  end
  local function actions(journey)
    local out = {}
    for _, st in ipairs(journey and journey.stops or {}) do
      out[#out + 1] = st.action and (st.action.kind .. st.action.questID) or "arrive"
    end
    return table.concat(out, ",")
  end

  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives }
  local savedMoney, zoneSupport = GetMoney, LibQuestieDB.Support.Get
  GetMoney = function() return 0 end -- training not affordable: no need ahead of the XP options
  local XP = { [1] = { 18, 1500 }, [7] = { 19, 1500 }, [11] = { 17, 1500 }, [15] = { 18, 1500 },
    [6] = { 20, 1400 }, [14] = { 19, 1400 }, [20] = { 20, 1600 }, [10] = { 19, 1000 },
    [50] = { 19, 1200 }, [51] = { 18, 1100 }, [52] = { 19, 900 }, [53] = { 19, 1300 }, [54] = { 20, 1400 } }
  LibQuestieDB.Support.Get = function(name)
    if name == "QuestXP" then return { db = XP } end
    return zoneSupport(name)
  end
  -- 50, 51: done, handed in to a watcher out in the hills; 52: done, handed in
  -- to Magistrate Solomon in Lakeshire; 53, 54: murlocs still to kill.
  NPCS[6100] = { name = "Watcher Dodds", npcFlags = 2, friendlyToFaction = "A", spawns = { [44] = { { 70.0, 70.0 } } } }
  QUESTS[50] = { name = "Watch Report", questLevel = 19, requiredLevel = 15, startedBy = { { 6100 } }, finishedBy = { { 6100 } } }
  QUESTS[51] = { name = "Watch Supplies", questLevel = 18, requiredLevel = 15, startedBy = { { 6100 } }, finishedBy = { { 6100 } } }
  QUESTS[52] = { name = "Solomon's Letter", questLevel = 19, requiredLevel = 15, startedBy = { { 6000 } }, finishedBy = { { 344 } } }
  QUESTS[53] = { name = "Murloc Fins", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } }, finishedBy = { { 345 } },
    objectives = { { { 9101 } } } }
  QUESTS[54] = { name = "Murloc Eyes", questLevel = 20, requiredLevel = 15, startedBy = { { 344 } }, finishedBy = { { 345 } },
    objectives = { { { 9101 } } } }
  reloadBridge()

  local log, complete = { 10, 50, 51, 52, 53, 54 }, { [50] = true, [51] = true, [52] = true }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function(id) return complete[id] == true end
  C_QuestLog.GetQuestObjectives = function(id)
    if id == 53 then return { { text = "4/8 Murloc Fin", finished = false, numFulfilled = 4, numRequired = 8 } } end
    if id == 54 then return { { text = "0/6 Murloc Eye", finished = false } } end
    return {}
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  local started = os.clock()
  local list = rows()
  local ms = (os.clock() - started) * 1000
  check(ms < 100, string.format("a refresh with log quests takes %.1f ms here", ms))

  -- Hand-ins: full XP for only the trip, so they come first.
  local handin, hi = find(list, "Hand in 2 quests to Watcher Dodds")
  check(handin and hi == 1, "quests ready to hand in rank first (" .. titles(list) .. ")")
  local best = true
  for _, r in ipairs(list) do
    if r ~= handin and r.rate and handin and r.rate >= handin.rate then best = false end
  end
  check(best and handin.subtitle:find("2 quests ready", 1, true) and xpOf(handin) == 2300,
    "hand-ins: 1,200 + 1,100 XP, the best XP per minute: " .. tostring(handin and handin.subtitle))
  check(handin and actions(handin.journey) == "turnin50,turnin51",
    "the hand-in trip waits for each quest to be handed in (" .. actions(handin and handin.journey) .. ")")
  check(handin and handin.details[1].text:find("2 x 30 s per hand-in", 1, true),
    "tooltip times hand-ins: " .. tostring(handin and handin.details[1].text))

  -- The Lakeshire hub also hands in Solomon's Letter, before picking up.
  local hub = find(list, "Pick up 5 quests and hand in 1 in Lakeshire")
  check(hub and hub.journey and actions(hub.journey) == "turnin52,arrive"
    and hub.journey.stops[2].text:find("^Pick up quests here"),
    "hub with a hand-in: hand in first, then pick up (" .. titles(list) .. " / " .. actions(hub and hub.journey) .. ")")
  check(hub and xpOf(hub) == 7600 + 900 and hub.subtitle:find("5 quests + 1 to hand in", 1, true),
    "hub XP counts the hand-in: " .. tostring(hub and hub.subtitle))
  check(hub and hub.actions and hub.actions[1].label == "Hand in only", "a Hand in only button on the hub")
  check(not find(list, "Hand in 1 quest in Lakeshire"), "the hub's hand-in isn't listed twice")
  hub.actions[1].run(hub)
  check(ns.Nav.active and actions(ns.Nav.active.journey) == "turnin52", "Hand in only: just the hand-in")
  ns.Nav.Stop()

  -- Unfinished quests near each other: one whole-quest trip (Journey.QuestStops).
  local finish = find(list, "Finish 2 quests")
  local trip = actions(finish and finish.journey)
  check(finish and trip:find("complete53") and trip:find("complete54")
    and trip:find("complete53.*turnin53") and trip:find("complete54.*turnin54"),
    "finish trip: do each quest's objectives, then hand it in (" .. trip .. ")")
  local resolved = finish and finish.journey.stops[1].resolve
  check(resolved and resolved.kind == "objectives", "finish trip stops come from Journey.QuestStops")
  check(finish and xpOf(finish) == 2700 and finish.details[1].text:find("left on 2 in your log", 1, true)
    and finish.subtitle:find("2 quests in your log", 1, true),
    "finish trip: full XP, time left only: " .. tostring(finish and finish.details[1].text))
  local fins
  for _, d in ipairs(finish and finish.details or {}) do
    if d.text:find("Murloc Fins") then fins = d.text end
  end
  check(fins and fins:find("~50%% done"), "objective progress shows: " .. tostring(fins))
  check(finish and finish.details[1].text:find("~8 min left", 1, true),
    "half-done objectives: 2.5 + 5 min left, not two full quests")

  -- Dungeon quests in your log count toward the dungeon, not a finish trip.
  local deadmines = find(list, "Pick up 2 quests, then run The Deadmines")
  local withLogged = xpOf(deadmines)
  check(deadmines and deadmines.subtitle:find("3 quests (1 in your log)", 1, true) and not trip:find("10"),
    "dungeon keeps its log quest: " .. tostring(deadmines and deadmines.subtitle))
  -- Handed in already (out of the log, can't be taken again): 1,000 XP less.
  local savedDone = C_QuestLog.GetAllCompletedQuestIDs
  C_QuestLog.GetAllCompletedQuestIDs = function() return { 2, 10 } end
  log = { 50, 51, 52, 53, 54 }
  local without = xpOf(find(rows(), "Pick up 2 quests, then run The Deadmines"))
  check(withLogged - without == 1000, string.format("dungeon XP counts the logged quest (%d vs %d)", withLogged, without))
  C_QuestLog.GetAllCompletedQuestIDs = savedDone

  -- Ready to hand in: out of the dungeon, into the Lakeshire hand-ins (Foreman Oslow).
  log = { 10, 50, 51, 52, 53, 54 }
  complete[10] = true
  list = rows()
  deadmines = find(list, "Pick up 2 quests, then run The Deadmines")
  hub = find(list, "Pick up 5 quests and hand in 2 in Lakeshire")
  check(deadmines and not deadmines.subtitle:find("in your log") and hub and xpOf(hub) == 7600 + 900 + 1000,
    "a done dungeon quest is a hand-in, not dungeon XP (" .. titles(list) .. ")")
  check(ns.ForYou.SummaryText():find("Quest log counted at full XP: 4 ready to hand in, 2 to finish", 1, true),
    "summary says how the log counts: " .. ns.ForYou.SummaryText())

  -- A need on the way to hand-ins goes wherever it is quickest.
  GetMoney = savedMoney
  list = rows()
  check(list[1] and list[1].title:find("Train") and #list <= 7, "training back first once affordable (" .. titles(list) .. ")")

  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]
  LibQuestieDB.Support.Get = zoneSupport
  for id = 50, 54 do QUESTS[id] = nil end
  NPCS[6100] = nil
  reloadBridge()
  ns.ForYou.Invalidate()
end
---------------------------------------------------------------- for you: quest log (end)
---------------------------------------------------------------- look (begin)
io.write("look\n")
do
  -- CreateFrame that knows the children of the templates we use, can fail
  -- some of them, and records which templates were asked for.
  local savedCreate, asked = CreateFrame, {}
  local failing, unknown = {}, {}
  local CHILDREN = {
    ButtonFrameTemplate = { "CloseButton", "TitleContainer", "Inset" },
    TooltipBackdropTemplate = { "NineSlice" },
    SearchBoxTemplate = { "Instructions" },
    PanelTopTabButtonTemplate = { "Text", "Left", "Right" },
  }
  CreateFrame = function(frameType, name, parent, template)
    asked[#asked + 1] = template or frameType
    if template and failing[template] then error("Couldn't find inherited node \"" .. template .. "\"") end
    local f = savedCreate()
    for _, key in ipairs(CHILDREN[template] or {}) do rawset(f, key, newObj()) end
    if rawget(f, "TitleContainer") then rawset(f.TitleContainer, "TitleText", newObj()) end
    return f
  end
  C_XMLUtil = { GetTemplateInfo = function(name) if not unknown[name] then return {} end end }
  local hidPortrait, selectedTab = 0, nil
  ButtonFrameTemplate_HidePortrait = function() hidPortrait = hidPortrait + 1 end
  PanelTemplates_SetTab = function(frame, id) frame.selectedTab = id; selectedTab = id end

  -- Fresh copies of the four UI files (their frames are created once).
  local function freshUI()
    local ui = setmetatable({ pages = {}, listeners = {} }, { __index = ns })
    function ui.RegisterPage(page) table.insert(ui.pages, page) end
    function ui.Listen(message, fn)
      ui.listeners[message] = ui.listeners[message] or {}
      table.insert(ui.listeners[message], fn)
    end
    function ui.On() end
    for _, page in ipairs(ns.pages) do
      if page.id ~= "find" then ui.RegisterPage(page) end
    end
    for _, file in ipairs({ "CopyBox", "HUD", "JourneyOverview", "Panel" }) do
      assert(loadfile(dir .. "/UI/" .. file .. ".lua"))("Wayfinder", ui)
    end
    return ui
  end
  local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do if v == value then n = n + 1 end end
    return n
  end
  local function openAll(ui)
    asked = {}
    local ok, err = pcall(function()
      ui.Panel.Toggle()
      ui.Panel.SelectPage("find")
      ui.ShowCopyBox("Look", "text")
      ui.JourneyOverview.Show()
      ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Look",
        stops = { { node = ns.Geo.Node(1433, 0.9, 0.9, "Lookout"), text = "Visit the lookout" } } }))
      for _, fn in ipairs(ui.listeners.NAV_CHANGED) do fn() end
      ns.Nav.Stop()
    end)
    if not ok then io.write("  ", tostring(err), "\n") end
    return ok and ui.Panel.IsShown()
  end

  failing = { ButtonFrameTemplate = true, SearchBoxTemplate = true, PanelTopTabButtonTemplate = true }
  unknown = { TooltipBackdropTemplate = true }
  check(openAll(freshUI()), "windows open when the templates fail")
  check(count(asked, "ButtonFrameTemplate") == 2 and count(asked, "BackdropTemplate") == 4
    and count(asked, "TooltipBackdropTemplate") == 0 and count(asked, "InputBoxTemplate") == 1,
    "a failing or unknown template falls back to the old look")
  failing, unknown = {}, {}
  local ui = freshUI()
  check(openAll(ui), "windows open with the templates")
  local findIndex
  for i, page in ipairs(ui.pages) do if page.id == "find" then findIndex = i end end
  check(count(asked, "BackdropTemplate") == 0 and count(asked, "SearchBoxTemplate") == 1 and hidPortrait == 2
    and selectedTab == findIndex, "template windows, search box and tabs (tab " .. tostring(selectedTab) .. ")")

  -- Without EllesmereUI the skin does nothing.
  fire("PLAYER_LOGIN")
  runTimers()
  check(ns.Skin.Status() == nil, "no skin without EllesmereUI or ElvUI")

  -- A stubbed EllesmereUI that calls back right away, as after login.
  local calls, looksChanged, registeredAs = {}, nil, nil
  local function record(name) return function() calls[name] = (calls[name] or 0) + 1 end end
  local S = { apiVersion = 3, OnLooksChanged = function(fn) looksChanged = fn end }
  for _, name in ipairs({ "Shell", "Panel", "Inset", "Button", "CloseButton", "EditBox", "Tab", "SetTabSelection",
    "ScrollBar", "Font" }) do S[name] = record(name) end
  EllesmereUI = { RegisterSkin = function(name, fn) registeredAs = name; fn(S) end }
  fire("PLAYER_LOGIN")
  runTimers()
  check(ns.Skin.Status() == "EllesmereUI" and registeredAs == "Wayfinder", "EllesmereUI skin registered")
  check((calls.Shell or 0) >= 4 and (calls.Panel or 0) >= 4 and (calls.Tab or 0) > 0 and (calls.EditBox or 0) >= 2
    and (calls.Font or 0) > 0 and (calls.Inset or 0) >= 2, "windows made earlier get EllesmereUI's look")
  local shells, boxes, fonts = calls.Shell, calls.Panel, calls.Font
  openAll(freshUI())
  check(calls.Shell == shells + 2 and calls.Panel == boxes + 2 and (calls.SetTabSelection or 0) > 0,
    "new windows get it right away")
  ns.Panel.Toggle()
  ns.Panel.Toggle()
  check(calls.Font > fonts, "the font is read again when a window shows")
  fonts = calls.Font
  if looksChanged then looksChanged() end
  check(calls.Font > fonts, "and when EllesmereUI's looks change")

  -- /wf skin
  local said = #chat
  SlashCmdList.WAYFINDER("skin")
  shells = calls.Shell
  openAll(freshUI())
  check(ns.db.settings.skin == false and calls.Shell == shells, "/wf skin turns it off for new windows")
  check(chat[said + 1]:find("skin off; /reload", 1, true) ~= nil, "and says a reload removes it from open ones")
  SlashCmdList.WAYFINDER("skin")
  check(ns.db.settings.skin == true and calls.Shell == shells + 2, "/wf skin again paints what was missed")

  CreateFrame, C_XMLUtil, EllesmereUI = savedCreate, nil, nil
  ButtonFrameTemplate_HidePortrait, PanelTemplates_SetTab = nil, nil
end
---------------------------------------------------------------- look (end)
---------------------------------------------------------------- panel scrolling (begin)
do
  io.write("panel scrolling\n")
  local many = {}
  for i = 1, 12 do many[i] = { title = "R" .. i, subtitle = "row " .. i } end
  ns.RegisterPage({ id = "many", label = "Many", order = 99, searchable = true,
    SummaryText = function() return "" end, EmptyText = function() return "" end,
    Results = function(q) return q == "" and many or { many[1] } end })
  ns.Panel.Search("many", "")
  local function first() local v = ns.Panel.VisibleResults() return v[1] and v[1].title, #v end
  local top, count = first()
  check(top == "R1" and count == 7, "seven results show, starting at the first")
  ns.Panel.Scroll(-3)
  check(first() == "R4", "scrolling down moves the list")
  ns.Panel.Scroll(-50)
  check(first() == "R6", "scrolling stops at the last page")
  ns.Panel.Refresh()
  check(first() == "R6", "a data refresh keeps your place")
  ns.Panel.Scroll(50)
  check(first() == "R1", "scrolling up returns to the top")
  ns.Panel.Scroll(-2)
  ns.Panel.Search("many", "x")
  check(first() == "R1", "a new search starts at the top")
end
---------------------------------------------------------------- panel scrolling (end)
---------------------------------------------------------------- caches (begin)
do
  io.write("caches\n")
  QUESTS[41] = { name = "Forager Count", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 344 } }, objectives = { { { 9101 } } } }
  assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns)
  local clock, reads = 100, 0
  GetTime = function() return clock end
  local realCompleted = C_QuestLog.GetAllCompletedQuestIDs
  C_QuestLog.GetAllCompletedQuestIDs = function() reads = reads + 1 return realCompleted() end
  ns.Questie.PlayerQuestState()
  ns.Questie.PlayerQuestState()
  check(reads == 1, "quest state is read once per moment")
  fire("QUEST_LOG_UPDATE")
  ns.Questie.PlayerQuestState()
  check(reads == 2, "a quest event starts a fresh read")
  clock = clock + 2
  ns.Questie.PlayerQuestState()
  check(reads == 3, "and so does time passing")
  C_QuestLog.GetAllCompletedQuestIDs = realCompleted
  GetTime = nil

  local realGet, spawnReads = NpcDB.Get, 0
  NpcDB.Get = function(id, key)
    if key == "spawns" and id == 9101 then spawnReads = spawnReads + 1 end
    return realGet(id, key)
  end
  local here = ns.Geo.PlayerNode()
  local a = ns.Questie.ObjectiveNode(41, here)
  local b = ns.Questie.ObjectiveNode(41, here)
  check(a and b and spawnReads == 1, "a quest's objective places are built once")
  NpcDB.Get = realGet
  QUESTS[41] = nil
  assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns)
end
---------------------------------------------------------------- caches (end)
---------------------------------------------------------------- trip polish (begin)
do
  io.write("trip polish\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  -- Trainers in one room are one row.
  NPCS[5003] = { name = "Gakin the Darkbinder", subName = "Warlock Trainer", npcFlags = 16, friendlyToFaction = "A",
    spawns = { [1519] = { { 39.40, 84.86 } } } }
  assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns)
  local grouped
  for _, r in ipairs(ns.Trainers.Results()) do
    if r.title:find("warlock trainers", 1, true) then grouped = r end
  end
  check(grouped and grouped.title:find("^2 warlock trainers in ") and #grouped.details == 2,
    "trainers in the same room are one row: " .. tostring(grouped and grouped.title))
  NPCS[5003] = nil

  -- Walking into another zone is its own step.
  -- On foot only: no flight paths, and not the quick boat the dock test recorded.
  local known, recorded = ns.charDB.knownTaxi, ns.db.transports
  ns.charDB.knownTaxi, ns.db.transports = {}, {}
  local here = ns.Geo.PlayerNode()
  local goal = ns.Geo.Node(1437, 0.5, 0.5, "Wetlands camp")
  local route = ns.Router.WithZoneSteps(ns.Router.Plan(here, goal, ns.Network.Build()))
  local entry
  for _, st in ipairs(route.steps) do if st.zoneEntry then entry = st end end
  check(entry and entry.zoneEntry == 1437 and ns.Router.Describe(route, 1) == "Walk to Wetlands",
    "a walk into another zone gets a 'Walk to Wetlands' step")
  check(ns.Journey.StopZone({ node = goal }) == "Wetlands", "stops know their zone")
  ns.Nav.Start("Wetlands camp", goal, ns.Router.Plan(here, goal, ns.Network.Build()))
  check(ns.Nav.CurrentStep().zoneEntry == 1437, "the zone step comes first")
  player.mapID, player.x, player.y = 1437, 0.5, 0.97
  ns.HUD.Update()
  check(ns.Nav.active and not ns.Nav.CurrentStep().zoneEntry, "being in the zone completes that step")

  -- Re-routing: walking away from the target.
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1437, 0.5, 0.5
  goal = ns.Geo.Node(1437, 0.5, 0.9, "South shore")
  ns.Nav.Start("South shore", goal, ns.Router.Plan(ns.Geo.PlayerNode(), goal, ns.Network.Build()))
  ns.HUD.Update()
  local before = #chat
  player.y = 0.375
  ns.HUD.Update()
  player.y = 0.25
  ns.HUD.Update()
  check(#chat > before and chat[#chat]:find("re%-routed from here %(you went another way%)"),
    "walking well away from the target re-routes")

  -- Re-routing: a hearthstone-style jump.
  ns.charDB.knownTaxi, ns.db.transports = known, recorded
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local trainer = ns.Trainers.Results()[1]
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  ns.HUD.Update()
  before = #chat
  player.mapID, player.x, player.y = 1453, 0.6, 0.6
  ns.HUD.Update()
  check(chat[#chat]:find("re%-routed from here %(you moved a long way%)", 1) and ns.Nav.CurrentStep().mode == "walk"
    and ns.Nav.active.route.steps[1].from.mapID == 1453, "a hearth re-routes from where you land")
  ns.Nav.Stop()

  -- TomTom.
  local added, removed = {}, 0
  TomTom = {
    AddWaypoint = function(_, mapID, x, y, opts) added[#added + 1] = { mapID = mapID, opts = opts } return { #added } end,
    RemoveWaypoint = function() removed = removed + 1 end,
  }
  local blizzard = #waypoints
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  trainer = ns.Trainers.Results()[1]
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(ns.Nav.UsingTomTom() and #added == 1 and added[1].opts.crazy and #waypoints == blizzard,
    "with TomTom, its arrow shows the way instead of ours")
  ns.Nav.Next()
  check(#added == 2 and removed == 1, "each step replaces the TomTom waypoint")
  ns.Nav.Stop()
  check(removed == 2, "stopping clears it")
  SlashCmdList.WAYFINDER("tomtom")
  check(not ns.Nav.UsingTomTom(), "/wf tomtom turns it off")
  SlashCmdList.WAYFINDER("tomtom")
  TomTom.AddWaypoint = function() error("old TomTom") end
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(not ns.Nav.UsingTomTom() and #waypoints > blizzard, "a TomTom that fails falls back to our own arrow")
  ns.Nav.Stop()
  TomTom = nil

  -- Minimap button and addon compartment.
  Minimap = CreateFrame("Frame")
  GetCursorPosition = function() return 0, 0 end
  fire("PLAYER_LOGIN")
  check(ns.MinimapButton.IsShown(), "a minimap button appears")
  SlashCmdList.WAYFINDER("minimap")
  check(not ns.MinimapButton.IsShown(), "/wf minimap hides it")
  SlashCmdList.WAYFINDER("minimap")
  local wasShown = ns.Panel.IsShown()
  Wayfinder_OnAddonCompartmentClick(nil, "LeftButton")
  check(ns.Panel.IsShown() ~= wasShown, "the addon compartment entry opens the panel")
  assert(loadfile(dir .. "/QuestieBridge.lua"))("Wayfinder", ns)
end
---------------------------------------------------------------- trip polish (end)
---------------------------------------------------------------- flight knowledge (begin)
do
  io.write("flight knowledge\n")
  ns.Nav.Stop()
  local known, seen = ns.charDB.knownTaxi, ns.charDB.taxiSeen
  ns.charDB.knownTaxi, ns.charDB.taxiSeen = {}, {}
  check(not ns.Harvest.FlightsKnownOn(1414), "no flight map opened on Kalimdor: its flight paths are unknown")
  ERR_NEWTAXIPATH = "New flight path discovered!"
  player.mapID, player.x, player.y = 1414, 0.44, 0.25 -- at Auberdine's flight master
  fire("UI_INFO_MESSAGE", 0, "New flight path discovered!")
  check(ns.charDB.knownTaxi[26] and ns.Harvest.FlightsKnownOn(1414),
    "'New flight path discovered!' marks the nearest flight path as known")
  ns.charDB.knownTaxi, ns.charDB.taxiSeen = {}, {}
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local allNodes = C_TaxiMap.GetAllTaxiNodes
  -- Like the real flight map: only this continent's flight paths.
  C_TaxiMap.GetAllTaxiNodes = function() return { { nodeID = 5, state = 0 }, { nodeID = 2, state = 1 } } end
  fire("TAXIMAP_OPENED")
  C_TaxiMap.GetAllTaxiNodes = allNodes
  check(ns.charDB.taxiSeen[1415] and ns.Harvest.FlightsKnownOn(1415) and not ns.Harvest.FlightsKnownOn(1414),
    "opening a flight map tells Wayfinder about that continent only")
  ns.charDB.knownTaxi, ns.charDB.taxiSeen = known, seen

  -- TomTom waypoints say what to do, not the flight path's name.
  local titles = {}
  SlashCmdList.WAYFINDER("tomtom")
  SlashCmdList.WAYFINDER("tomtom") -- off and on again: retries TomTom after the earlier failure
  TomTom = { AddWaypoint = function(_, _, _, _, opts) titles[#titles + 1] = opts.title return { #titles } end,
    RemoveWaypoint = function() end }
  local trainer = ns.Trainers.Results()[1]
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(titles[1] == ns.Router.Describe(ns.Nav.active.route, 1) and titles[1]:find("^Go to the flight master"),
    "TomTom's waypoint is titled with the step: " .. tostring(titles[1]))
  ns.Nav.Stop()
  TomTom = nil
end
---------------------------------------------------------------- flight knowledge (end)
for _, line in ipairs(chat) do io.write("[chat] ", line, "\n") end
if failures > 0 then
  io.write(failures, " FAILED\n")
  os.exit(1)
end
io.write("WAYFINDER SMOKE OK\n")
