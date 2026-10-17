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
        elseif k == "RegisterEvent" then events[(...)] = events[(...)] or {}; table.insert(events[(...)], self)
        elseif k == "SetText" then rawset(self, "text", (...))
        elseif k == "GetText" then return rawget(self, "text")
        elseif k == "SetRotation" then rawset(self, "rotation", (...))
        elseif k == "Show" then rawset(self, "shown", true); if self.scripts.OnShow then self.scripts.OnShow(self) end
        elseif k == "Hide" then rawset(self, "shown", false)
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
check(plan:find("boat") and plan:find("fly"), "Darkshore: boat across, then fly (" .. plan .. ")")
check(far and ns.Router.Summary(far.route):find("boat to Menethil Harbor"), "summary mentions the boat")

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

io.write("panel\n")
ns.Panel.Toggle()
check(true, "panel opens and refreshes without errors")

for _, line in ipairs(chat) do io.write("[chat] ", line, "\n") end
if failures > 0 then
  io.write(failures, " FAILED\n")
  os.exit(1)
end
io.write("WAYFINDER SMOKE OK\n")
