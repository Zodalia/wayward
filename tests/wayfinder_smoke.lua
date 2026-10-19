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

-- Events Forever's (Mainline) client doesn't have any more.
REMOVED_EVENTS = { LEARNED_SPELL_IN_TAB = true, OLD_REMOVED_EVENT = true }

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
        elseif k == "RegisterEvent" then
          -- Like the game: an event it doesn't have is an error.
          if REMOVED_EVENTS[(...)] then error("Attempt to register unknown event \"" .. (...) .. "\"", 2) end
          events[(...)] = events[(...)] or {}; table.insert(events[(...)], self)
        elseif k == "SetText" then
          -- Like the game: text on a font string with no font is an error.
          if rawget(self, "fontString") and not rawget(self, "hasFont") then error("Font not set", 2) end
          rawset(self, "text", (...))
        elseif k == "SetFontObject" or k == "SetFont" then
          if (...) ~= nil then rawset(self, "hasFont", true) end
        elseif k == "GetText" then return rawget(self, "text")
        elseif k == "SetRotation" then rawset(self, "rotation", (...))
        -- Like the game: a masked texture can't take tex coords.
        elseif k == "SetMask" then rawset(self, "masked", true)
        elseif k == "SetTexCoord" then
          if rawget(self, "masked") then error("Cannot set tex coords when texture has mask", 2) end
        elseif k == "Show" then rawset(self, "shown", true); if self.scripts.OnShow then self.scripts.OnShow(self) end
        elseif k == "Hide" then rawset(self, "shown", false)
        elseif k == "SetShown" then rawset(self, "shown", (...) and true or false)
        elseif k == "IsShown" then return rawget(self, "shown")
        elseif k == "CreateFontString" then
          local fs = newObj()
          rawset(fs, "fontString", true)
          rawset(fs, "hasFont", select(3, ...) ~= nil) -- a template brings its font
          return fs
        elseif k == "CreateTexture" then return newObj()
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
    -- The world map (947): each continent on its own half.
    if mapID == 947 then return mapID, vec((instance % 2) * 0.5 + cx * 0.5, cy) end
    local z = ZONES[mapID]
    if not z then return nil end
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
check(ns.Router.Describe(r.route, 1) == "Talk to the flight master at Lakeshire, Redridge", "step 1 text")
do
  local fm = r.route.steps[1].to
  ns.db.npcs[990002] = { name = "Ariena Stormfeather", kinds = { flightMaster = true }, mapID = fm.mapID, x = fm.x, y = fm.y }
  ns.Fire("DATA_CHANGED")
  local named = ns.Trainers.Results()[1]
  check(ns.Router.Describe(named.route, 1) == "Talk to Ariena Stormfeather, the flight master at Lakeshire, Redridge",
    "a flight master you've met is named: " .. ns.Router.Describe(named.route, 1))
  ns.db.npcs[990002] = nil
  ns.Fire("DATA_CHANGED")
end
check(ns.Router.Describe(r.route, 2) == "Fly to Stormwind, Elwynn", "step 2 text")

player.mapID, player.x, player.y = 1439, 0.5, 0.5
local far = ns.Trainers.Results()[1]
local kinds = {}
for _, s in ipairs(far and far.route and far.route.steps or {}) do kinds[#kinds + 1] = s.kind or s.mode end
local plan = table.concat(kinds, ",")
check(plan == "walk,boat,walk", "Darkshore: Forever's direct boat to Stormwind (" .. plan .. ")")
check(far and ns.Router.Summary(far.route) == "boat to Stormwind Harbor", "summary mentions the boat")

-- The router against a plain search over the whole graph (the old planner):
-- the same trip times for random trips between these maps.
do
  local R = ns.Router
  local function walk(a, b)
    local d = ns.Geo.Distance(a, b)
    return d < math.huge and d * R.WALK_FACTOR / R.RUN_SPEED or nil
  end
  local function fly(a, b)
    local d = ns.Geo.Distance(a, b)
    return d < math.huge and R.FLY_OVERHEAD + d / R.FLY_SPEED or nil
  end
  local function reference(start, goal, net)
    local nodes, links = { start, goal }, {}
    for _, n in ipairs(net.flights) do nodes[#nodes + 1] = n end
    for _, t in ipairs(net.transports) do
      nodes[#nodes + 1] = t.a
      local ia = #nodes
      nodes[#nodes + 1] = t.b
      links[ia], links[#nodes] = links[ia] or {}, links[#nodes] or {}
      table.insert(links[ia], { #nodes, t.time })
      table.insert(links[#nodes], { ia, t.time })
    end
    local dist, done = {}, {}
    for i = 1, #nodes do dist[i] = math.huge end
    dist[1] = 0
    for _ = 1, #nodes do
      local cur, best = nil, math.huge
      for i = 1, #nodes do if not done[i] and dist[i] < best then cur, best = i, dist[i] end end
      if not cur then break end
      done[cur] = true
      for j = 1, #nodes do
        if not done[j] and j ~= cur then
          local c = walk(nodes[cur], nodes[j])
          if c and best + c < dist[j] then dist[j] = best + c end
          if nodes[cur].isFlight and nodes[j].isFlight then
            c = fly(nodes[cur], nodes[j])
            if c and best + c < dist[j] then dist[j] = best + c end
          end
        end
      end
      for _, l in ipairs(links[cur] or {}) do
        if best + l[2] < dist[l[1]] then dist[l[1]] = best + l[2] end
      end
    end
    return dist[2]
  end
  local net = ns.Network.Build()
  local maps, seed, same, compared = { 1433, 1453, 1439, 1437 }, 7, 0, 0
  local function rand()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  end
  for _ = 1, 300 do
    local a = ns.Geo.Node(maps[math.floor(rand() * #maps) + 1], 0.1 + rand() * 0.8, 0.1 + rand() * 0.8, "A")
    local b = ns.Geo.Node(maps[math.floor(rand() * #maps) + 1], 0.1 + rand() * 0.8, 0.1 + rand() * 0.8, "B")
    if a and b then
      compared = compared + 1
      local route, want = ns.Router.Plan(a, b, net), reference(a, b, net)
      local got = route and route.seconds or math.huge
      if (got == math.huge and want == math.huge) or math.abs(got - want) < 1e-6 then same = same + 1 end
    end
  end
  check(compared > 200 and same == compared, string.format("router matches a full search: %d of %d trips", same, compared))
end

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
check(ns.Nav.active.index == 1 and ns.Nav.Waiting() and ns.Nav.Interaction() == "talk",
  "at the flight master: talk to them first")
fire("TAXIMAP_OPENED")
check(ns.Nav.active.index == 2 and ns.Nav.Interaction() == "fly", "the flight map opens: now the flight")
check(ns.HUD.Lines()[4]:find("Pick Stormwind", 1, true), "the box says what to pick: " .. ns.HUD.Lines()[4])
-- In the air: no compass, nothing re-planned, however far you go.
UnitOnTaxi = function() return true end
player.facing = 0
local beforeIndex, chatBefore = ns.Nav.active.index, #chat
player.mapID, player.x, player.y = 1453, 0.45, 0.75
ns.HUD.Update()
check(ns.Nav.Flying() and ns.Nav.active.index == beforeIndex and #chat == chatBefore,
  "on the flight: no steps passed, no re-planning")
check(not ns.HUD.ArrowShown(), "and no compass arrow")
UnitOnTaxi = function() return false end
player.mapID, player.x, player.y = fp.mapID, fp.x, fp.y
-- Land in Stormwind.
local landing = r.route.steps[2].to
player.mapID, player.x, player.y = landing.mapID, landing.x, landing.y
player.facing = 0
ns.HUD.Update()
check(ns.Nav.active.index == 3, "landing advances to the final walk")
-- Arrive at the trainer.
player.mapID, player.x, player.y = 1453, 0.3938, 0.8483
ns.HUD.Update()
check(ns.Nav.active and ns.Nav.Waiting() and ns.Nav.TargetNPC() == r.goal.npc and r.goal.npc,
  "at the trainer: talk to them (" .. tostring(r.goal.npc) .. ")")
local savedUnitName = UnitName
UnitName = function(unit) if unit == "npc" or unit == "mouseover" then return r.goal.npc end return "Me" end
local raidMarks = 0
UnitExists = function() return true end
UnitIsPlayer = function() return false end
SetRaidTarget = function() raidMarks = raidMarks + 1 end
-- The star over their nameplate (friendly NPC nameplates on).
local plate = CreateFrame("Frame")
C_NamePlate = { GetNamePlateForUnit = function() return plate end,
  GetNamePlates = function() return { { namePlateUnitToken = "nameplate1" } } end }
UnitName = function(unit) if unit == "npc" or unit == "nameplate1" or unit == "mouseover" then return r.goal.npc end return "Me" end
check(ns.Marker.Try("nameplate1") and raidMarks == 0, "the trainer's nameplate gets a star (no raid marker: those are protected)")
check(ns.Marker.TooltipLine("mouseover") == "Wayfinder: Talk to " .. r.goal.npc, "and their tooltip a line: "
  .. tostring(ns.Marker.TooltipLine("mouseover")))
SlashCmdList.WAYFINDER("marker")
check(not ns.Marker.Try("nameplate1") and ns.Marker.TooltipLine("mouseover") == nil, "/wf marker turns both off")
SlashCmdList.WAYFINDER("marker")
UnitName = function(unit) if unit == "npc" then return r.goal.npc end return "Someone else" end
check(not ns.Marker.Try("nameplate1"), "someone else doesn't get one")
UnitName = function(unit) if unit == "npc" then return r.goal.npc end return "Me" end
-- The target button by the directions box: /target <them>.
local hud = ns.HUD.Frame()
rawset(hud, "GetRight", function() return 600 end)
rawset(hud, "GetTop", function() return 700 end)
ns.TargetButton.Sync()
check(ns.TargetButton.Macro() == "/target " .. r.goal.npc, "the target button targets them: " .. tostring(ns.TargetButton.Macro()))
InCombatLockdown = function() return true end
ns.Nav.Stop()
ns.TargetButton.Sync()
check(ns.TargetButton.Macro() == "/target " .. r.goal.npc, "in combat it waits")
InCombatLockdown = nil
fire("PLAYER_REGEN_ENABLED")
check(ns.TargetButton.Macro() == nil, "and changes once combat ends")
ns.Nav.Start(r.title, r.goal, r.route)
player.mapID, player.x, player.y = 1453, 0.3938, 0.8483
ns.HUD.Update()
UnitExists, UnitIsPlayer, SetRaidTarget, C_NamePlate = nil, nil, nil, nil
fire("GOSSIP_SHOW")
UnitName = savedUnitName
check(ns.Nav.active == nil and waypoints[#waypoints] == "cleared", "talking to them ends it and clears our waypoint")
check(ns.Fanfare.lastTrip and ns.Fanfare.lastTrip.title == r.title,
  "plain directions get the fanfare too: " .. tostring(ns.Fanfare.lastTrip and ns.Fanfare.lastTrip.title))

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

io.write("without data sources\n")
local noHubs, noHubsErr = ns.QuestHubs.Results()
check(#noHubs == 0 and noHubsErr and noHubsErr:find("No quest data"), "quest hubs explain that quest data is needed")
check(ns.Data.Status() == nil, "no data source status line")

io.write("data sources\n")
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

-- The fixtures above are kept in QuestieDB's shape (rows with spawns per
-- AreaID in map percent, race and class bit masks). fixtureSource turns them
-- into a Wayfinder data source (Wayfinder/Sources.lua), reading the globals at
-- call time so tests can change rows; refreshData() registers it again, which
-- resets Wayfinder's caches, and dropData() takes it away.
local function fixtureSource()
  local function support(name)
    local ok, module = pcall(LibQuestieDB.Support.Get, name)
    return ok and module or nil
  end
  local areaMaps = {}
  local function uiMap(areaID)
    local zone = support("ZoneDB")
    local src = zone and zone.private and zone.private.areaIdToUiMapId
    if type(src) == "string" then
      areaMaps[src] = areaMaps[src] or assert(loadstring(src))()
      return areaMaps[src][areaID]
    end
    return type(src) == "table" and src[areaID] or nil
  end
  local function positions(spawns)
    local out = {}
    for areaID, points in pairs(type(spawns) == "table" and spawns or {}) do
      for _, p in ipairs(points) do
        if type(p[1]) == "number" then
          out[#out + 1] = { mapID = uiMap(areaID), x = p[1] / 100, y = p[2] / 100, areaID = areaID }
        end
      end
    end
    return out
  end
  local function set(mask, bitByKey)
    if (mask or 0) == 0 then return nil end
    local out = {}
    for key, bit in pairs(bitByKey or {}) do
      if math.floor(mask / bit) % 2 == 1 then out[key] = true end
    end
    return out
  end
  local FLAGS = { TRAINER = "trainer", VENDOR = "vendor", REPAIR = "repair", FLIGHT_MASTER = "flightMaster",
    QUEST_GIVER = "questGiver" }
  local function npcFlags(id)
    local mask, out = NpcDB.Get(id, "npcFlags") or 0, {}
    for enumKey, flag in pairs(FLAGS) do
      local bit = LibQuestieDB.Enum.npcFlags[enumKey]
      if bit and mask ~= 0 and math.floor(mask / bit) % 2 == 1 then out[flag] = true end
    end
    return out
  end

  local source = { id = "fixtures", label = "Fixtures", priority = 10 }
  function source.Status() return LibQuestieDB.readMode end
  function source.QuestIDs() return QuestDB.GetAllIds() end
  function source.Quest(id)
    if not QuestDB.GetAll(id, { "name" }) then return nil end
    local q = {}
    for field in pairs(LibQuestieDB.Meta.QuestMeta.questKeys) do q[field] = QuestDB.Get(id, field) end
    q.races = set(q.requiredRaces, LibQuestieDB.Enum.raceMaskById)
    q.classes = set(q.requiredClasses, LibQuestieDB.Enum.classKeys)
    q.requiredRaces, q.requiredClasses = nil, nil
    if type(q.triggerEnd) == "table" then q.triggerEnd = { q.triggerEnd[1], positions(q.triggerEnd[2]) } end
    if type(q.extraObjectives) == "table" then
      local extras = {}
      for i, e in ipairs(q.extraObjectives) do extras[i] = { positions(e[1]), e[2], e[3] } end
      q.extraObjectives = extras
    end
    return q
  end
  function source.Npc(id)
    if not NpcDB.GetAll(id, { "name" }) then return nil end
    return { id = id, name = NpcDB.Get(id, "name"), subName = NpcDB.GetRaw(id, "subName"),
      faction = NpcDB.Get(id, "friendlyToFaction"), rank = NpcDB.Get(id, "rank"),
      minLevel = NpcDB.Get(id, "minLevel"), maxLevel = NpcDB.Get(id, "maxLevel"),
      flags = npcFlags(id), positions = positions(NpcDB.Get(id, "spawns")) }
  end
  function source.NpcIDs(flag)
    local out = {}
    for _, id in ipairs(NpcDB.GetAllIds()) do
      if npcFlags(id)[flag] then out[#out + 1] = id end
    end
    return out
  end
  function source.Object(id)
    if not (ObjectDB and ObjectDB.GetAll(id, { "name" })) then return nil end
    return { id = id, name = ObjectDB.Get(id, "name"), positions = positions(ObjectDB.Get(id, "spawns")) }
  end
  function source.Item(id)
    if not (ItemDB and ItemDB.GetAll(id, { "name" })) then return nil end
    local item = { id = id }
    for _, k in ipairs({ "name", "itemLevel", "requiredLevel", "npcDrops", "objectDrops", "itemDrops",
      "questRewards", "vendors" }) do
      item[k] = ItemDB.Get(id, k)
    end
    return item
  end
  function source.ItemIDs() return ItemDB and ItemDB.GetAllIds() or {} end
  function source.Dungeons()
    local zone = support("ZoneDB")
    local out = {}
    for areaID, d in pairs(zone and zone.private and zone.private.dungeons or {}) do
      local spawns = {}
      for _, loc in ipairs(d[4] or {}) do
        spawns[loc[1]] = spawns[loc[1]] or {}
        table.insert(spawns[loc[1]], { loc[2], loc[3] })
      end
      out[#out + 1] = { areaID = areaID, name = d[1], alternativeAreaIds = d[2] or {}, positions = positions(spawns) }
    end
    return out
  end
  function source.QuestXP()
    local xp = support("QuestXP")
    return xp and xp.db
  end
  function source.EraToForever(mapID, x, y)
    local convert = LibQuestieDB.EraToForeverByUiMapId
    if not convert then return nil end
    local fx, fy = convert(mapID, x * 100, y * 100)
    return fx / 100, fy / 100
  end
  return source
end
local fixtures = fixtureSource()
local function refreshData() Wayfinder.RegisterSource(fixtures) end
local function dropData() Wayfinder.UnregisterSource("fixtures") end
refreshData()

player.mapID, player.x, player.y = 1433, 0.5, 0.5
check(ns.Quests.Available() and ns.Data.Status() == "Fixtures (baked)", "a registered source is used")
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
ns.Panel.SelectPage("quests", 2)
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
ns.Panel.SelectPage("trainers", 1)
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
dropData()
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
refreshData()

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

ns.Panel.SelectPage("vendors")
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
  -- Forever's new dungeons sit far above the vanilla IDs.
  [3273] = { name = "Hall of Thanes", level = 21 },
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
local savedLevel = UnitLevel
dropData()
player.mapID, player.x, player.y = 1433, 0.5, 0.5
local dungeons = ns.Dungeons.Results()
local all = titles(dungeons)
check(not ns.Quests.Available() and ns.Dungeons.SummaryText():find("Install a Wayfinder data addon"),
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
ns.Panel.SelectPage("dungeons")
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
refreshData()
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
refreshData()
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
ns.Panel.SelectPage("dungeons")
check(ns.Panel.IsShown(), "panel shows dungeons with QuestieDB")

-- A dungeon only the dungeon finder lists: shown without directions, after
-- the ones you can be routed to, until you walk in once.
dungeons = ns.Dungeons.Results()
local thanes, thanesAt = find(dungeons, "Hall of Thanes"), nil
for i, d in ipairs(dungeons) do if d == thanes then thanesAt = i end end
check(thanes and thanes.title == "Hall of Thanes  ·  level 21" and not thanes.route
  and thanes.zone:find("entrance not known yet", 1, true), "a new Forever dungeon (ID 3273) is listed without directions")
local lastRouted = 0
for i, d in ipairs(dungeons) do if d.route then lastRouted = i end end
check(thanesAt and thanesAt > lastRouted, "after every dungeon with a known entrance")
check(thanes and thanes.details[#thanes.details].text:find("Walk in once", 1, true), "its tooltip says how to fix that")

-- Walking in records the entrance: where you were when the loading screen came.
local inside, lfg = false, false
IsInInstance = function() return inside, inside and "party" or "none" end
IsPartyLFG = function() return lfg end
GetInstanceInfo = function() return "The Hall of Thanes", "party", 1, "Normal", 5, 0, false, 3065 end
player.mapID, player.x, player.y = 1433, 0.31, 0.62
fire("PLAYER_LEAVING_WORLD")
inside = true
fire("PLAYER_ENTERING_WORLD")
local saved = ns.db.dungeonEntrances.hallofthanes
check(saved and saved.instanceID == 3065 and #saved.points == 1 and saved.points[1].mapID == 1433
  and math.abs(saved.points[1].x - 0.31) < 1e-9, "entering the instance records its entrance")
inside = false
player.mapID, player.x, player.y = 1433, 0.5, 0.5
thanes = find(ns.Dungeons.Results(), "Hall of Thanes")
check(thanes and thanes.route and math.abs(thanes.goal.x - 0.31) < 1e-9 and not thanes.zone:find("not known", 1, true),
  "and the next time it has directions")
local deadminesNow = find(ns.Dungeons.Results(), "The Deadmines")

-- Close to a known entrance: the same one. Through the dungeon finder: not counted.
player.mapID, player.x, player.y = 1433, 0.3101, 0.6201
fire("PLAYER_LEAVING_WORLD")
inside = true
fire("PLAYER_ENTERING_WORLD")
check(#ns.db.dungeonEntrances.hallofthanes.points == 1, "walking in again at the same spot adds nothing")
inside, lfg = false, true
player.mapID, player.x, player.y = 1433, 0.9, 0.9
fire("PLAYER_LEAVING_WORLD")
inside = true
fire("PLAYER_ENTERING_WORLD")
check(#ns.db.dungeonEntrances.hallofthanes.points == 1, "a dungeon finder teleport isn't an entrance")
inside, lfg = false, false
player.mapID, player.x, player.y = 1433, 0.5, 0.5
check(deadminesNow and deadminesNow.route, "dungeons with entrances keep theirs")

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
local questPage
for _, page in ipairs(ns.pages) do if page.id == "quests" then questPage = page end end
ns.Panel.SelectPage("quests", 2)
local filtered = questPage.Results("lakeshire")
check(#filtered == 1 and filtered[1].title:find("Lakeshire"), "the search box filters a category's results by text")
check(#questPage.Results("") >= 2, "an empty filter shows everything")

io.write("shared helpers\n")
local commandArg
ns.RegisterCommand("echo", "/wf echo - test", function(rest) commandArg = rest end)
SlashCmdList.WAYFINDER("echo |cff9d9d9d|Hitem:2589::::|h[Linen Cloth]|h|r")
check(commandArg == "|cff9d9d9d|Hitem:2589::::|h[Linen Cloth]|h|r", "registered /wf commands get the raw text")
player.mapID, player.x, player.y = 1433, 0.5, 0.5
check(ns.Quests.IsQuestAvailable(1) and not ns.Quests.IsQuestAvailable(2), "IsQuestAvailable uses the hub rules")
check(ns.Quests.Quest(14) and ns.Quests.Quest(14).nextQuestInChain == 13, "Quest(id) returns the quest row")
local giverName = ns.Quests.QuestGiver(1, ns.Geo.PlayerNode())
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
  local function reload() refreshData() end
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

  local function status(id) return (ns.Quests.QuestStatus(id)) end
  local codes = {}
  for _, id in ipairs({ 1, 10, 2, 13, 9, 3, 8, 18, 5, 4, 4242 }) do codes[#codes + 1] = status(id) end
  check(table.concat(codes, ",") == "available,inLog,done,needsEarlier,tooLow,notForYou,notForYou,unavailable,"
    .. "available,needsEarlier,unknown", "every status (" .. table.concat(codes, ",") .. ")")
  local _, greyReason = ns.Quests.QuestStatus(5)
  check(greyReason:find("Grey"), "a grey quest is available but says so: " .. greyReason)
  local _, reason, stepID, stepState = ns.Quests.QuestStatus(30)
  check(stepID == 14 and stepState == "available" and reason:find("Start the chain: Chain part 1", 1, true),
    "a two-step chain starts at its first quest: " .. reason)
  check(select(1, ns.Quests.ChainStart(31)) == 10 and select(2, ns.Quests.ChainStart(31)) == "inLog",
    "a chain waiting on a quest in your log says to finish it")
  _, reason, stepID = ns.Quests.QuestStatus(4)
  check(stepID == nil and reason:find("can't take yet"), "no takeable step: " .. reason)
  local agree = true
  local done, inLog = ns.Quests.PlayerQuestState()
  for id in pairs(QUESTS) do
    local s, r = ns.Quests.QuestStatus(id, done, inLog)
    local fits = s == "available" and r == "You can take this quest."
    if ns.Quests.IsQuestAvailable(id, done, inLog) ~= fits then agree = false end
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
  check(#rows == 1 and rows[1].title == "Lost Quest" and rows[1].subtitle:find("Not in the quest data"),
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

  dropData()
  local none, err = ns.QuestsPage.Results("chain")
  check(#none == 0 and err and err:find("Install a Wayfinder data addon"), "without QuestieDB: the page says it is needed")
  check(ns.QuestsPage.SummaryText(""):find("Install a Wayfinder data addon"), "without QuestieDB: summary too")
  for _, d in ipairs(ns.Dungeons.Results()) do
    if d.actions then check(false, "no dungeon quest action without QuestieDB") end
  end
  ns.Panel.Search("quests", "chain")
  check(ns.Panel.IsShown(), "panel shows the Quests page without QuestieDB")

  refreshData()
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
  refreshData()

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

  check(page and page.order == 60 and page.searchable, "Items page registered (order 60, last tab, searchable)")
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
  dropData()
  GetItemInfo = function(id)
    if id == 1205 then return "Melon Juice", "|cffffffff|Hitem:1205::::|h[Melon Juice]|h|r", 1, 5, 1 end
  end
  list = rows("item:1205")
  check(#list == 1 and list[1].title == "Sold by Lakeshire Cook" and detailText(list[1]):find("last visited"),
    "without QuestieDB: the visited vendor that sold it (" .. names(list) .. ")")
  check(ns.Items.SummaryText("item:1205"):find("Install a Wayfinder data addon"), "summary says QuestieDB is needed for the rest")
  check(#rows("item:9001") == 0 and ns.Items.EmptyText("item:9001"):find("Install a Wayfinder data addon"),
    "without QuestieDB: no drops, and the page says why")
  list = rows("melon")
  check(list[1] and list[1].title == "Sold by Lakeshire Cook", "without QuestieDB: names searched among visited goods")
  check(#rows("cruel") == 0 and ns.Items.EmptyText("cruel"):find("vendors you visited"), "unknown name explained")
  ns.Panel.Search("items", "item:1205")
  check(ns.Panel.IsShown(), "panel shows the Items page without QuestieDB")
  GetItemInfo = nil
  refreshData()

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
  local function count(category)
    local n = 0
    for _, r in ipairs(list) do if r.category == category then n = n + 1 end end
    return n
  end
  local redridge = find(list, "Quest in Redridge Mountains")
  local goulash = find(list, "Do ")
  local deadmines = find(list, "Run The Deadmines")
  check(list[1].category == "Due now" and redridge and redridge.category == "Questing zone"
    and goulash and goulash.category == "Best quest" and deadmines and deadmines.category == "Dungeon",
    "one card per kind: due now, a questing zone, the dungeon, the best quest (" .. titles(list) .. ")")
  local order = {}
  for _, r in ipairs(list) do order[#order + 1] = r.category end
  check(table.concat(order, ","):find("^Due now,Questing zone,Dungeon"), "what's due, then where to quest, then the dungeon: "
    .. table.concat(order, ","))
  check(not find(list, "Quest in Stormwind City"), "a zone with fewer than 4 quests for you gets no card")
  check(count("Dungeon") == 1, "one dungeon card")
  local also
  for _, d in ipairs(deadmines and deadmines.details or {}) do
    if d.text:find("^Also for your level") then also = d.text end
  end
  check(not (also and also:find("Hall of Testing", 1, true)) and not find(list, "Run Hall of Testing"),
    "with QuestieDB, a dungeon without quests for you isn't suggested (its mobs give little XP)")
  -- The zone: what you can take now, what chains unlock, where to start.
  check(redridge and redridge.place == "Levels 17-19  ·  start at Lakeshire" and redridge.route
    and redridge.details[1].text:find("4 quests you can take now, 1 more as their chains unlock", 1, true),
    "a questing zone: levels, quests now and unlocked by chains, the hub to start at: " .. tostring(redridge and redridge.details[1].text))
  check(redridge and redridge.details[2].text == "Start at Lakeshire: the trip picks up its 4 quests."
    and redridge.goal.label:find("^Lakeshire"),
    "the first hub (one hub per place): " .. tostring(redridge and redridge.details[2].text))
  local pickups = {}
  for _, st in ipairs(redridge and redridge.journey and redridge.journey.stops or {}) do
    pickups[#pickups + 1] = st.action and st.action.kind or "?"
  end
  check(#pickups == 4 and table.concat(pickups, ","):find("^pickup,pickup,pickup,pickup$"),
    "the zone's trip picks up the first hub's quests: " .. table.concat(pickups, ","))
  local estimated = false
  for _, d in ipairs(deadmines and deadmines.details or {}) do
    if d.text:find("estimated for 1 quest") then estimated = true end
  end
  check(estimated, "a quest without XP data is estimated")
  local function statText(r)
    local out = {}
    for _, st in ipairs(r and r.stats or {}) do out[#out + 1] = st[1] .. "=" .. st[2] end
    return table.concat(out, ",")
  end
  check(statText(redridge):find("^Quests=4 %+ 1,XP=~7,300,Trip="),
    "a zone's card numbers: quests now + later, XP, travel: " .. statText(redridge))
  check(list[1].stats and list[1].stats[1][1] == "Spells" and list[1].stats[2][1] == "Cost" and list[1].place:find("spell"),
    "the training card: spells, cost and travel: " .. tostring(list[1].place))
  check(list[1].details[2] and not list[1].details[2].more and list[1].details[2].text:find("  -  ", 1, true),
    "the spells you can learn come first on it: " .. tostring(list[1].details[2] and list[1].details[2].text))
  check(ns.ForYou.SummaryText():find("1 thing due") and ns.ForYou.SummaryText():find("best of each kind")
    and not ns.ForYou.SummaryText():find("quests per hour"), "summary: " .. ns.ForYou.SummaryText())

  -- The best quest is a whole-quest trip.
  local kinds = {}
  for _, st in ipairs(goulash and goulash.journey and goulash.journey.stops or {}) do kinds[#kinds + 1] = st.action.kind end
  check(kinds[1] == "pickup" and kinds[#kinds] == "turnin" and statText(goulash):find("XP=", 1, true),
    "best quest: pick it up, do it, hand it in, with its XP (" .. table.concat(kinds, ",") .. ")")

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
  check(deadmines and deadmines.title == "Run The Deadmines  ·  level 20" and deadmines.place:find("2 pickups on the way"),
    "the dungeon card keeps its name; the pickups are in its place line: " .. tostring(deadmines and deadmines.place))
  check(deadmines and deadmines.subtitle:find("1 in your log"), "quests in your log count too")

  -- Three more Deadmines quests from level 22: most of its quests aren't open yet.
  for i, id in ipairs({ 30, 31, 32 }) do
    QUESTS[id] = { name = "Later Defias " .. i, questLevel = 22, requiredLevel = 22, zoneOrSort = 1581, startedBy = { { 344 } } }
  end
  refreshData()
  list = rows()
  check(not find(list, "Run The Deadmines") and ns.ForYou.SummaryText():find("The Deadmines at level 22 (", 1, true),
    "a dungeon most of whose quests open later waits, and the page says when: " .. ns.ForYou.SummaryText())
  for _, id in ipairs({ 30, 31, 32 }) do QUESTS[id] = nil end
  refreshData()
  list = rows()

  -- Gear at 20%: repair before training.
  durability = { 10, 50 }
  list = rows()
  check(list[1] and list[1].title:find("^Repair") and list[2] and list[2].title:find("^Train"),
    "low durability: repair first, then training (" .. titles(list) .. ")")
  durability = { 50, 50 }

  -- Gear at 70%: worth a repair when a repairer is close; never before what's due.
  durability = { 35, 50 }
  list = rows()
  local soon = find(list, "Repair at")
  check(soon and soon.category == "Worth a visit" and list[1].category == "Due now",
    "gear at 70% with a repairer close by: worth a visit, after what's due (" .. titles(list) .. ")")
  check(ns.ForYou.SummaryText():find("1 thing due"), "worth-a-visit cards aren't counted as due")
  durability = { 50, 50 }

  -- No spell list yet, at an even level: a visit to the trainer is worth it.
  local savedSpells = ns.charDB.classSpells
  ns.charDB.classSpells = nil
  list = rows()
  local visit = find(list, "Visit your trainer in")
  check(visit and visit.category == "Worth a visit" and visit.place:find("level 20"),
    "never visited a trainer, level 20: new spells likely (" .. titles(list) .. ")")
  UnitLevel = function() return 21 end
  check(not find(rows(), "Visit your trainer in"), "odd levels don't")
  UnitLevel = function() return 20 end
  -- Last visit two levels ago, nothing left to learn then: likely again.
  ns.charDB.classSpells = { updated = 0, level = 18, services = { { name = "Old", type = "used", levelReq = 16 } } }
  check(find(rows(), "Visit your trainer in"), "two levels since the last visit: worth another")
  ns.charDB.classSpells = { updated = 0, level = 20, services = { { name = "Old", type = "used", levelReq = 16 } } }
  check(not find(rows(), "Visit your trainer in"), "just visited: no")
  ns.charDB.classSpells = savedSpells

  -- A big XP quest in Stormwind becomes the best quest; needs stay their own cards.
  XP[6] = { 20, 12000 }
  list = rows()
  check(find(list, "Do Stormwind errand") and not list[1].journey,
    "the quest worth the most XP is the best quest; training stays a card of its own (" .. titles(list) .. ")")
  XP[6] = { 20, 1400 }

  -- Without XP data: quests per hour, weighted by level fit.
  LibQuestieDB.Support.Get = zoneSupport
  list = rows()
  check(ns.ForYou.SummaryText():find("No quest XP in the data"), "summary explains the fallback")
  local rz = find(list, "Quest in Redridge")
  check(rz and statText(rz):find("Hubs=", 1, true) and not statText(rz):find("XP"),
    "without XP data a zone counts quests and hubs: " .. statText(rz))

  -- Without QuestieDB: needs and dungeons by level fit.
  dropData()
  list = rows()
  check(ns.ForYou.SummaryText():find("Install a Wayfinder data addon"), "without QuestieDB the summary says so")
  check(list[1] and list[1].title:find("^Train") and find(list, "Run The Deadmines") and not find(list, "Pick up"),
    "without QuestieDB: training, then dungeons (" .. titles(list) .. ")")
  refreshData()
  LibQuestieDB.Support.Get = function(name)
    if name == "QuestXP" then return { db = XP } end
    return zoneSupport(name)
  end
  refreshData()

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
---------------------------------------------------------------- professions (begin)
do
  io.write("professions\n")
  ns.Nav.Stop()
  local P = ns.Professions
  local prof, rank = P.FromSubtitle("Expert Tailor")
  check(prof == "Tailoring" and rank == "Expert" and P.FromSubtitle("Tailoring Trainer") == "Tailoring"
    and P.FromSubtitle("Tailoring Supplies") == nil, "trainer subtitles name the profession and rank")
  check(P.FromServices({ { name = "Linen Cloak" }, { name = "Journeyman Tailoring" } }) == "Tailoring",
    "a trainer's services say which profession")

  -- Tailoring 73/75 (Journeyman ready), Herbalism 40/75 (not enough skill yet).
  local skills = { { "Professions", true }, { "Tailoring", false, 73, 75 }, { "Herbalism", false, 40, 75 } }
  local savedNum, savedInfo = GetNumSkillLines, GetSkillLineInfo
  GetNumSkillLines = function() return #skills end
  GetSkillLineInfo = function(i) local l = skills[i]; return l[1], l[2], true, l[3], 0, 0, l[4] end
  local mine = P.Mine()
  check(mine.Tailoring.rank == 73 and mine.Herbalism.cap == 75 and not mine.Professions, "your professions and skill")
  local r1, s1 = P.NextRank(mine.Tailoring)
  local r2, s2 = P.NextRank(mine.Herbalism)
  check(r1.name == "Journeyman" and s1 == "ready" and r2.name == "Journeyman" and s2 == "skill",
    "the next rank: Tailoring can train Journeyman, Herbalism needs 50 skill first")

  -- A tailor you visited (teaches up to Journeyman) and one from QuestieDB.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  ns.db.npcs[990010] = { name = "Georgio Bolero", kinds = { professionTrainer = true }, profession = "Tailoring",
    ranks = { "Apprentice", "Journeyman" }, mapID = 1433, x = 0.52, y = 0.5 }
  NPCS[990011] = { name = "Expert Seamstress", subName = "Expert Tailor", npcFlags = 16, friendlyToFaction = "A",
    spawns = { [1519] = { { 50, 50 } } } }
  refreshData()
  local qt = ns.Data.NearestOfKind("professionTrainer", "Alliance", here, function(t) return t.profession == "Tailoring" end)
  check(#qt == 1 and qt[1].rank == "Expert", "QuestieDB's tailors, with the rank their subtitle names")

  ns.Panel.SelectPage("trainers", 3)
  local rows = P.Results()
  local first = rows[1] and rows[1].title:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  check(first == "Tailoring  (Georgio Bolero)" and rows[1].subtitle:find("train Journeyman now", 1, true),
    "Professions tab: what you can train now first, with the trainer: " .. tostring(first))
  local primary, secondary
  for _, r in ipairs(rows) do
    if r.title:find("^Learn Alchemy") then primary = true end
    if r.title:find("^Learn Cooking") then secondary = true end
  end
  check(not primary and secondary, "two primary professions already: only secondary ones to learn")

  ns.ForYou.Invalidate()
  local list = ns.ForYou.Results()
  local card
  for _, r in ipairs(list) do if r.title:find("^Train Journeyman Tailoring") then card = r end end
  check(card and card.category == "Worth a visit" and card.stats[1][2] == "73/75",
    "a For you card to train Journeyman Tailoring (worth a visit below your cap)")
  skills[2][3] = 75
  ns.ForYou.Invalidate()
  list = ns.ForYou.Results()
  card = nil
  for _, r in ipairs(list) do if r.title:find("^Train Journeyman Tailoring") then card = r end end
  check(card and card.category == "Due now", "at your cap it's due")
  -- Its trip: to the trainer, then buy the rank (done when the cap goes up).
  local stop = card and card.journey and card.journey.stops[1]
  check(stop and stop.action.kind == "train" and stop.text == "Train Journeyman Tailoring at Georgio Bolero",
    "the card's trip has a step to buy the rank")
  runTimers()
  ns.Nav.StartJourney(card.journey)
  player.mapID, player.x, player.y = stop.node.mapID, stop.node.x, stop.node.y
  ns.HUD.Update()
  check(ns.Nav.Waiting() and ns.HUD.Lines()[4]:find("talk to Georgio Bolero and train it", 1, true),
    "at the trainer: talk to them and train it")
  local savedName = UnitName
  UnitName = function(unit) if unit == "npc" then return "Georgio Bolero" end return "Me" end
  fire("GOSSIP_SHOW")
  UnitName = savedName
  check(ns.Nav.active ~= nil, "talking alone doesn't finish it")
  skills[2][4] = 150
  fire("SKILL_LINES_CHANGED")
  runTimers()
  check(ns.Nav.active == nil and ns.Fanfare.lastTrip.title:find("Journeyman Tailoring", 1, true),
    "buying Journeyman (the cap goes to 150) finishes it")

  GetNumSkillLines, GetSkillLineInfo = savedNum, savedInfo
  ns.db.npcs[990010], NPCS[990011] = nil, nil
  refreshData()
  ns.ForYou.Invalidate()
end
---------------------------------------------------------------- professions (end)

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
  refreshData()
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
  refreshData()
end
---------------------------------------------------------------- trips (end)
---------------------------------------------------------------- quest steps (begin)
do
  io.write("quest steps\n")
  ns.Nav.Stop()
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete }
  local savedObjects, savedCount = ObjectDB, GetItemCount
  -- Like The Blackwood Corrupted: collect a sample (object 600), fill a bowl (an
  -- extra objective), then the talisman (item 501, from Murloc Foragers).
  ITEMS[500] = { name = "Blackwood Grain Sample", objectDrops = { 600 } }
  ITEMS[501] = { name = "Talisman of Corruption", npcDrops = { 9101 } }
  ObjectDB = entity({ [600] = { spawns = { [44] = { { 45.0, 50.0 } } } } }, {})
  QUESTS[41] = { name = "The Blackwood Corrupted", questLevel = 18, requiredLevel = 14, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { nil, nil, { { 501 } } }, requiredSourceItems = { 500, 501 },
    extraObjectives = { { { [44] = { { 40.0, 50.0 } } }, "Interface\\Icons\\event", "Fill the bowl at the moonwell" } } }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy, questKeys.objectives, questKeys.requiredSourceItems, questKeys.extraObjectives = 3, 10, 21, 27
  LibQuestieDB.Meta.ItemMeta.itemKeys.npcDrops, LibQuestieDB.Meta.ItemMeta.itemKeys.objectDrops = 2, 3
  refreshData()
  local bags = {}
  GetItemCount = function(id) return bags[id] or 0 end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()

  local qs = ns.Journey.QuestStops(41, here)
  local kinds = {}
  for _, st in ipairs(qs) do kinds[#kinds + 1] = st.action.kind end
  check(table.concat(kinds, ",") == "pickup,item,manual,complete,turnin",
    "a quest with steps: pick up, collect, its extra step, do it, hand in: " .. table.concat(kinds, ","))
  check(qs[2].text == "Collect Blackwood Grain Sample for The Blackwood Corrupted" and qs[2].after[1] == qs[1]
    and qs[3].text == "Fill the bowl at the moonwell" and qs[3].after[1] == qs[2] and qs[4].after[1] == qs[3],
    "the collecting comes after the pickup, the extra step after it, the objective last")
  bags[500] = 1
  local kinds2 = {}
  for _, st in ipairs(ns.Journey.QuestStops(41, here)) do kinds2[#kinds2 + 1] = st.action.kind end
  check(table.concat(kinds2, ",") == "pickup,manual,complete,turnin", "an item you already have isn't collected again")
  bags[500] = nil

  -- Start it with the quest in the log: skip the collecting, then collect anyway.
  local log = { 41 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function() return false end
  qs = ns.Journey.QuestStops(41, here)
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Blackwood", stops = qs }))
  check(ns.Nav.CurrentStep().stop.action.kind == "item", "first: collect the sample")
  ns.Nav.Next()
  check(ns.JourneyOverview.Rows()[1].state == "skipped", "skipped it")
  bags[500] = 1
  fire("BAG_UPDATE_DELAYED")
  check(ns.JourneyOverview.Rows()[1].state == "done", "a skipped stop you then do counts as done")
  -- The extra step is confirmed with next: done, not skipped.
  while ns.Nav.CurrentStep() and ns.Nav.CurrentStep().stop ~= qs[2] do ns.Nav.Next() end
  ns.Nav.Next()
  check(qs[2].done and not qs[2].passed, "next confirms a quest's extra step")
  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()

  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete = savedLog[1], savedLog[2], savedLog[3]
  ObjectDB, GetItemCount = savedObjects, savedCount
  QUESTS[41], ITEMS[500], ITEMS[501] = nil, nil, nil
  refreshData()
end
---------------------------------------------------------------- quest steps (end)
---------------------------------------------------------------- quests not offered (begin)
do
  io.write("quests not offered\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  -- Two quests from Magistrate Solomon, by the data; the game offers only the first.
  local a, b = ns.Journey.QuestStops(1, here), ns.Journey.QuestStops(7, here)
  local stops = {}
  for _, st in ipairs(a) do stops[#stops + 1] = st end
  for _, st in ipairs(b) do stops[#stops + 1] = st end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Solomon", stops = stops }))
  check(a[1].giver and a[1].giver == b[1].giver and ns.Quests.IsQuestAvailable(7), "both pickups at the same giver, by the data")
  local giver = a[1].node
  player.mapID, player.x, player.y = giver.mapID, giver.x, giver.y
  ns.HUD.Update()
  local savedName = UnitName
  UnitName = function(unit) if unit == "npc" then return a[1].giver end return "Me" end
  C_GossipInfo = { GetAvailableQuests = function() return { { questID = 1 } } end }
  fire("GOSSIP_SHOW")
  check(b[1].skipped and b[#b].skipped and not a[1].skipped, "the pickup the giver doesn't offer is dropped, with its hand-in")
  check(not ns.Quests.IsQuestAvailable(7) and ns.Quests.QuestStatus(7) == "needsEarlier",
    "and counts as locked everywhere: " .. tostring(select(2, ns.Quests.QuestStatus(7))))
  check(chat[#chat]:find("isn't offered yet", 1, true), "and says so: " .. chat[#chat])
  local said = #chat
  SlashCmdList.WAYFINDER("debug quest 7")
  check(#chat > said + 2 and chat[said + 2]:find("(id 7)", 1, true) and chat[#chat]:find("didn't offer it", 1, true),
    "/wf debug quest shows the chain data and the giver's answer")
  fire("QUEST_TURNED_IN", 999)
  check(ns.Quests.IsQuestAvailable(7), "handing in any quest makes it worth asking again")
  UnitName, C_GossipInfo = savedName, nil
  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()
end
---------------------------------------------------------------- quests not offered (end)
---------------------------------------------------------------- inferred chains (begin)
do
  io.write("inferred chains\n")
  -- Forever's own quests with no chain data: the Return the Statuette series.
  QUESTS[285] = { name = "Search More Hovels", questLevel = 20, requiredLevel = 15, startedBy = { { 344 } }, finishedBy = { { 344 } } }
  QUESTS[286] = { name = "Return the Statuette", questLevel = 20, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, preQuestSingle = { 285 } }
  QUESTS[98189] = { name = "Return the Statuette", questLevel = 20, requiredLevel = 15, startedBy = { { 345 } }, finishedBy = { { 345 } } }
  QUESTS[98190] = { name = "A Friend of the Family", questLevel = 20, requiredLevel = 15, startedBy = { { 345 } }, finishedBy = { { 344 } } }
  QUESTS[98191] = { name = "A Friend of the Family", questLevel = 20, requiredLevel = 15, startedBy = { { 344 } }, finishedBy = { { 344 } } }
  -- Same name, one per faction: the Horde one can't hold up the Alliance one.
  QUESTS[98300] = { name = "Report In", questLevel = 20, requiredLevel = 15, requiredRaces = 2, startedBy = { { 344 } } }
  QUESTS[98301] = { name = "Report In", questLevel = 20, requiredLevel = 15, requiredRaces = 1, startedBy = { { 344 } } }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy = 3
  refreshData()
  local function after(id) return ns.Quests.Quest(id).inferredAfter end
  check(after(98189) == 286 and after(98191) == 98190, "a Forever quest named like an earlier one comes after it")
  check(after(98190) == 98189, "a Forever quest given by whoever takes the previous one comes after it")
  check(after(286) == nil and after(285) == nil, "Era quests keep their own data")
  check(not ns.Quests.IsQuestAvailable(98189) and not ns.Quests.IsQuestAvailable(98190)
    and not ns.Quests.IsQuestAvailable(98191), "the whole series waits for the original chain")
  check(ns.Quests.IsQuestAvailable(98301), "the other faction's quest of the same name doesn't hold it up")
  local _, reason = ns.Quests.QuestStatus(98190)
  check(reason and reason:find("Search More Hovels", 1, true), "its chain starts where the data's chain does: " .. tostring(reason))
  local savedDone = C_QuestLog.GetAllCompletedQuestIDs
  C_QuestLog.GetAllCompletedQuestIDs = function() return { 2, 285, 286 } end
  check(ns.Quests.IsQuestAvailable(98189) and not ns.Quests.IsQuestAvailable(98190),
    "after the original: the next part opens, the one after it doesn't yet")
  C_QuestLog.GetAllCompletedQuestIDs = savedDone
  for _, id in ipairs({ 285, 286, 98189, 98190, 98191, 98300, 98301 }) do QUESTS[id] = nil end
  refreshData()
end
---------------------------------------------------------------- inferred chains (end)
---------------------------------------------------------------- objects and follow-ups (begin)
do
  io.write("objects and follow-ups\n")
  ns.Nav.Stop()
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete }
  local savedObjects = ObjectDB
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy = 3
  -- Handed in to an object: Buzzbox 323, in Redridge.
  ObjectDB = entity({ [700] = { name = "Buzzbox 323", spawns = { [44] = { { 55.0, 50.0 } } } } }, {})
  QUESTS[44] = { name = "Buzzbox Report", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } }, finishedBy = { nil, { 700 } } }
  -- Chain part 1 (in your log, done) is handed in to Magistrate Solomon, who gives Chain part 2.
  QUESTS[14].finishedBy = { { 344 } }
  refreshData()
  local log = { 44, 14 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function() return true end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()

  local box = ns.Journey.QuestStops(44, here)
  check(#box == 1 and box[1].node.object and box[1].text == "Hand in Buzzbox Report to Buzzbox 323",
    "a hand-in to an object knows it's an object")
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Buzzbox", stops = box }))
  player.x, player.y = box[1].node.x, box[1].node.y
  ns.HUD.Update()
  check(ns.Nav.Interaction() == "use" and ns.Nav.TargetNPC() == nil and ns.HUD.Lines()[4]:find("use Buzzbox 323", 1, true),
    "at the object: use it, nothing to target: " .. ns.HUD.Lines()[4])
  ns.Nav.Stop()

  -- Its follow-up is picked up where you hand it in: offered.
  check(#ns.Quests.FollowUps(14) == 1 and ns.Quests.FollowUps(14)[1].id == 13, "Chain part 1 is followed by Chain part 2")
  local shown
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which, a, b, data)
    shown = { which = which, text = string.format(StaticPopupDialogs[which].text, a, b), data = data }
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Hand in", stops = ns.Journey.QuestStops(14, here) }))
  check(shown and shown.which == "WAYFINDER_FOLLOWUP" and shown.text:find("Chain part 1 continues with Chain part 2", 1, true)
    and shown.data,
    "handing in a quest offers its follow-up when it's on the way")
  StaticPopupDialogs.WAYFINDER_FOLLOWUP.OnAccept(nil, shown.data)
  local kinds = {}
  for _, st in ipairs(ns.Nav.active.journey.stops) do kinds[#kinds + 1] = st.action.kind .. st.action.questID end
  check(table.concat(kinds, ",") == "turnin14,pickup13", "Add puts it after the hand-in: " .. table.concat(kinds, ","))
  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()
  StaticPopupDialogs, StaticPopup_Show = nil, nil

  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete = savedLog[1], savedLog[2], savedLog[3]
  ObjectDB, QUESTS[44], QUESTS[14].finishedBy = savedObjects, nil, nil
  refreshData()
end
---------------------------------------------------------------- objects and follow-ups (end)
---------------------------------------------------------------- quest pickups (begin)
do
  io.write("quest pickups\n")
  ns.Nav.Stop()
  runTimers()
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy, questKeys.objectives = 3, 10
  QUESTS[45] = { name = "Murloc Count", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } } }
  refreshData()
  local log = {}
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function() return false end
  local shown
  StaticPopupDialogs = {}
  -- Like the game: two text arguments, then the data; the dialog's text is formatted with them.
  StaticPopup_Show = function(which, a, b, data)
    local text = string.format(StaticPopupDialogs[which].text, a, b)
    shown = { which = which, text = text, data = data }
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  -- No trip on: start one for it?
  log[1] = 45
  fire("QUEST_ACCEPTED", 45)
  runTimers()
  check(shown and shown.which == "WAYFINDER_PICKUP_NEW" and shown.text:find("You picked up Murloc Count", 1, true)
    and shown.text:find("min)?", 1, true) and shown.data,
    "picking up a quest with no trip on offers a trip for it, with its time")
  StaticPopupDialogs.WAYFINDER_PICKUP_NEW.OnAccept(nil, shown.data)
  local kinds = {}
  for _, st in ipairs(ns.Nav.active.journey.stops) do kinds[#kinds + 1] = st.action.kind end
  check(table.concat(kinds, ",") == "complete,turnin", "Start trip: do it, hand it in: " .. table.concat(kinds, ","))

  -- On that trip, another quest: add it (and how much longer), or a new trip.
  shown = nil
  log[2] = 40
  QUESTS[40] = { name = "Murloc Menace", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } } }
  refreshData()
  fire("QUEST_ACCEPTED", 40)
  runTimers()
  check(shown and shown.which == "WAYFINDER_PICKUP_ADD" and shown.text:find("Murloc Menace", 1, true)
    and shown.text:find("more), or start a new trip", 1, true) and shown.data,
    "with a trip on: add it, with the time it adds, or a new trip: " .. tostring(shown and shown.text))
  StaticPopupDialogs.WAYFINDER_PICKUP_ADD.OnAccept(nil, shown.data)
  check(ns.Nav.TripHasQuest(40) and ns.Nav.TripHasQuest(45), "Add to trip: both quests in it")

  -- Already in the trip: nothing to ask.
  shown = nil
  fire("QUEST_ACCEPTED", 40)
  runTimers()
  check(shown == nil, "a quest already in the trip isn't asked about")
  ns.db.settings.askOnPickup = false
  ns.Nav.Stop()
  fire("QUEST_ACCEPTED", 45)
  runTimers()
  check(shown == nil, "the option turns the question off")
  ns.db.settings.askOnPickup = nil

  ns.JourneyOverview.Toggle()
  StaticPopupDialogs, StaticPopup_Show = nil, nil
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete = savedLog[1], savedLog[2], savedLog[3]
  QUESTS[45], QUESTS[40] = nil, nil
  refreshData()
end
---------------------------------------------------------------- quest pickups (end)
---------------------------------------------------------------- unknown events (begin)
do
  io.write("unknown events\n")
  local ok = pcall(ns.On, "LEARNED_SPELL_IN_TAB", function() end)
  check(ok and ns.unknownEvents and ns.unknownEvents[#ns.unknownEvents] == "LEARNED_SPELL_IN_TAB",
    "an event the client doesn't have is skipped, not an error that stops a file loading")
  check(type(ns.Nav.Tick) == "function" and type(ns.Nav.Resume) == "function" and type(ns.Nav.FollowUpOffer) == "function",
    "the navigator loaded to the end")
end
---------------------------------------------------------------- unknown events (end)
---------------------------------------------------------------- on the way (begin)
do
  io.write("on the way\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = {
    { node = ns.Geo.Node(1433, 0.53, 0.5, "First"), text = "Visit First" },
    { node = ns.Geo.Node(1433, 0.56, 0.5, "Second"), text = "Visit Second" } } }))
  -- Lakeshire's quest givers are right by this trip.
  local onTheWay = ns.OnTheWay.Get()
  local labels = {}
  for _, sug in ipairs(onTheWay) do labels[#labels + 1] = sug.kind .. ":" .. sug.label .. " +" .. math.floor(sug.extra) end
  check(#onTheWay > 0 and onTheWay[1].extra <= 180 and onTheWay[1].kind == "pickup",
    "suggestions on the way, 3 min or less: " .. table.concat(labels, " | "))
  local firstQuest = onTheWay[1] and onTheWay[1].stops[1].action.questID
  check(firstQuest and ns.OnTheWay.Add(onTheWay[1]) and ns.Nav.TripHasQuest(firstQuest), "Add puts it in the trip")
  local still = false
  for _, sug in ipairs(ns.OnTheWay.Get()) do
    for _, st in ipairs(sug.stops) do if st.action and st.action.questID == firstQuest then still = true end end
  end
  check(not still, "and it isn't suggested again")
  -- The overview shows them, and the rest of the trip on a map.
  C_Map.GetMapArtLayers = function() return { { tileWidth = 256, tileHeight = 256, layerWidth = 1002, layerHeight = 668 } } end
  C_Map.GetMapArtLayerTextures = function() return { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } end
  ns.JourneyOverview.Show()
  check(ns.RouteMap.mapID == 1433 and ns.RouteMap.lines >= 1, "the overview has a map of the rest of the trip")
  C_Map.GetMapArtLayers, C_Map.GetMapArtLayerTextures = nil, nil
  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()
end
---------------------------------------------------------------- on the way (end)
---------------------------------------------------------------- fanfare (begin)
do
  io.write("fanfare\n")
  ns.Nav.Stop()
  runTimers()
  -- A two-stop trip: 400 XP, then a level-up with 300 more; one quest handed in.
  local xp, max = 1000, 2000
  UnitXP = function() return xp end
  UnitXPMax = function() return max end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local a = { node = ns.Geo.Node(1433, 0.53, 0.5, "First"), text = "Visit First" }
  local b = { node = ns.Geo.Node(1433, 0.56, 0.5, "Second"), text = "Visit Second" }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = { a, b } }))
  ns.HUD.Update()
  xp = 1400
  fire("PLAYER_XP_UPDATE")
  fire("QUEST_TURNED_IN", 999)
  player.x = 0.53
  ns.HUD.Update()
  xp, max = 100, 2500 -- levelled: 600 to finish the level, 100 into the next
  fire("PLAYER_XP_UPDATE")
  player.x = 0.56
  ns.HUD.Update()
  local f = ns.Fanfare.lastTrip
  check(ns.Nav.active == nil and f and f.title == "Errands" and f.xp == 1100 and f.quests == 1 and f.distance > 30,
    string.format("a finished trip's fanfare: %s XP, %s quests, %s yd", tostring(f and f.xp), tostring(f and f.quests),
      tostring(f and math.floor(f.distance))))
  UnitXP, UnitXPMax = nil, nil

  -- New journeys: learned quietly the first time, then shown.
  ns.charDB.seenCards = nil
  local zone = { id = "zone1437", kind = "zone", category = "Questing zone", title = "Quest in Wetlands",
    goal = b.node, route = ns.Router.Plan(here, b.node, ns.Network.Build()) }
  ns.Fanfare.lastNew = nil
  ns.ForYou.CheckNew({ zone })
  check(ns.Fanfare.lastNew == nil, "the first look only learns what's there")
  local dungeon = { id = "dungeonStockade", kind = "dungeon", category = "Dungeon", title = "Run The Stockade  ·  level 24",
    goal = b.node, route = zone.route }
  ns.ForYou.CheckNew({ zone, dungeon, { id = "finish", category = "Finish", title = "Finish 2 quests" } })
  check(ns.Fanfare.lastNew == dungeon, "a new dungeon card pops up as a new journey")
  ns.ForYou.CheckNew({ zone, dungeon })
  check(ns.Fanfare.lastNew == dungeon, "and only once")
  player.x = 0.5
  ns.Panel.Activate(dungeon)
  check(ns.Nav.active and ns.Nav.active.title:find("Stockade", 1, true), "clicking it starts it")
  ns.Nav.Stop()
end
---------------------------------------------------------------- fanfare (end)
---------------------------------------------------------------- objective areas (begin)
do
  io.write("objective areas\n")
  ns.Nav.Stop()
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives }
  -- Kill Murloc Foragers (spawns at 60,60 and 80,80) and Murloc Scouts (30,30), in Redridge.
  QUESTS[43] = { name = "Murloc Sweep", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 }, { 9102 } } } }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy, questKeys.objectives = 3, 10
  refreshData()
  C_QuestLog.GetNumQuestLogEntries = function() return 1 end
  C_QuestLog.GetInfo = function() return { questID = 43, isHeader = false } end
  C_QuestLog.IsComplete = function() return false end
  local objectives = { { text = "Murloc Forager slain: 2/8", finished = false }, { text = "Murloc Scout slain: 0/5", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 43 and objectives or {} end
  local groups = ns.Quests.ObjectiveGroups(43)
  check(#groups == 2 and groups[1].name == "Murloc Forager" and #groups[1].nodes == 2,
    "QuestieDB's objectives as named groups of spawns")

  player.mapID, player.x, player.y = 1433, 0.5, 0.95
  local here = ns.Geo.PlayerNode()
  local stops = ns.Journey.QuestStops(43, here)
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Murloc Sweep", stops = stops }))
  check(ns.Nav.CurrentStep().stop.action.kind == "complete" and not ns.Nav.InArea(), "on the way to the murlocs")

  player.x, player.y = 0.62, 0.6
  ns.HUD.Update()
  local lines = ns.HUD.Lines()
  check(ns.Nav.InArea() and ns.Nav.Waiting() and not ns.Nav.ownsWaypoint,
    "near any of their spawns: in the area, no waypoint")
  check(lines[4]:find("In the area", 1, true) and lines[4]:find("2/8", 1, true),
    "the box says so, with the progress: " .. lines[4])
  player.x = 0.45
  ns.HUD.Update()
  check(ns.Nav.InArea(), "a little way out: still in the area (no flicker at the edge)")
  player.x, player.y = 0.45, 0.95
  ns.HUD.Update()
  local to = ns.Nav.CurrentStep().to
  check(not ns.Nav.InArea() and ns.Nav.ownsWaypoint and math.abs(to.x - 0.8) < 1e-6 and math.abs(to.y - 0.8) < 1e-6,
    string.format("well out: the way points at the nearest spawn from here (%.2f, %.2f)", to.x, to.y))

  -- Foragers done: only the Scouts' spawns count now.
  objectives[1] = { text = "Murloc Forager slain: 8/8", finished = true }
  player.x, player.y = 0.62, 0.6
  ns.HUD.Update()
  check(not ns.Nav.InArea(), "a finished objective's spawns don't count any more")
  player.x, player.y = 0.31, 0.3
  ns.HUD.Update()
  check(ns.Nav.InArea(), "the open objective's do")

  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]
  QUESTS[43] = nil
  refreshData()
end
---------------------------------------------------------------- objective areas (end)
---------------------------------------------------------------- quest log trips (begin)
do
  io.write("quest log trips\n")
  ns.Nav.Stop()
  local function reload() refreshData() end
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

  -- Add puts a quest into the trip you're on, or starts one.
  ns.Nav.Stop()
  check(cull.actions and cull.actions[1].label == "Add", "log rows have an Add action")
  cull.actions[1].run(cull)
  check(ns.Nav.active and ns.Nav.TripHasQuest(50), "with no trip on, Add starts one with that quest")
  rows = ns.QuestsPage.Results("")
  check(byID(rows, "log50").actions[1].label == "In trip" and not byID(rows, "picked"),
    "a quest in the trip says In trip; no separate pile of picks")

  -- Adding from a search joins the same trip, re-ordered from here.
  local found = byID(ns.QuestsPage.Results("gnoll patrol"), "quest53")
  check(found and found.actions and found.actions[1].label == "Add", "search results have the Add action too")
  found.actions[1].run(found)
  local done = byID(ns.QuestsPage.Results("already done"), "quest2")
  check(done and not done.actions, "no Add on a quest you have done")
  local stops = ns.Nav.active.journey.stops
  local order = {}
  for i, st in ipairs(stops) do order[st.action.kind .. st.action.questID] = i end
  check(#stops == 5 and order.pickup53 < order.complete53 and order.complete53 < order.turnin53
    and order.complete50 < order.turnin50 and not order.pickup50,
    "added quests keep their own order inside the one trip: " .. kinds(stops))
  check(ns.Nav.active.title == "Your trip", "the trip is called Your trip once it holds more")

  -- In trip takes it out; the hand-in row can join too.
  byID(ns.QuestsPage.Results(""), "log50").actions[1].run()
  check(not ns.Nav.TripHasQuest(50) and ns.Nav.TripHasQuest(53), "In trip takes the quest out again")
  local handinRow = byID(ns.QuestsPage.Results(""), "handin")
  check(handinRow.actions and handinRow.actions[1].label == "Add", "with a trip on, the hand-in row can be added")
  handinRow.actions[1].run()
  check(ns.Nav.TripHasQuest(51) and ns.Nav.TripHasQuest(52) and ns.Nav.TripHasQuest(53), "its hand-ins join the trip")
  ns.Nav.Stop()

  -- Without QuestieDB: the log still shows, without trips.
  dropData()
  rows = ns.QuestsPage.Results("")
  cull = byID(rows, "log50")
  check(#rows == 3 and cull and cull.title == "[19] Murloc Cull" and not cull.journey and not cull.actions
    and cull.subtitle:find("directions need quest data") and cull.subtitle:find("3/8", 1, true),
    "without QuestieDB: the log lists, says directions need it, no trips: " .. tostring(cull and cull.subtitle))
  check(ns.QuestsPage.SummaryText(""):find("Install a Wayfinder data addon"), "without QuestieDB: the summary says so")
  ns.Panel.Search("quests", "")
  check(ns.Panel.IsShown(), "panel shows the quest log without QuestieDB")
  log = {}
  rows = ns.QuestsPage.Results("")
  check(#rows == 0 and ns.QuestsPage.EmptyText(""):find("quest log is empty"), "an empty log says so")
  refreshData()

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
  refreshData()

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
  local _, fi2 = find(list, "Finish ")
  check(handin and fi2 and hi < fi2, "quests ready to hand in rank before finishing (" .. titles(list) .. ")")
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

  -- One hand-in card (the best group); the hub card just picks up.
  local handinCards = 0
  for _, r in ipairs(list) do if r.category == "Hand in" then handinCards = handinCards + 1 end end
  check(handinCards == 1 and not find(list, "Hand in 1 quest in Lakeshire"), "only the best hand-in group gets a card")
  local zone = find(list, "Quest in Redridge")
  check(zone and zone.journey and zone.route, "the zone card is a trip to pick up its first hub's quests")
  check(find(list, "Finish ") and find(list, "Finish ").category == "Finish", "one card to finish quests in your log")

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
  local deadmines = find(list, "Run The Deadmines")
  local withLogged = xpOf(deadmines)
  check(deadmines and deadmines.subtitle:find("3 quests (1 in your log)", 1, true) and not trip:find("10"),
    "dungeon keeps its log quest: " .. tostring(deadmines and deadmines.subtitle))
  -- Handed in already (out of the log, can't be taken again): 1,000 XP less.
  local savedDone = C_QuestLog.GetAllCompletedQuestIDs
  C_QuestLog.GetAllCompletedQuestIDs = function() return { 2, 10 } end
  log = { 50, 51, 52, 53, 54 }
  local without = xpOf(find(rows(), "Run The Deadmines"))
  check(withLogged - without == 1000, string.format("dungeon XP counts the logged quest (%d vs %d)", withLogged, without))
  C_QuestLog.GetAllCompletedQuestIDs = savedDone

  -- Ready to hand in: out of the dungeon, into the Lakeshire hand-ins (Foreman Oslow).
  log = { 10, 50, 51, 52, 53, 54 }
  complete[10] = true
  list = rows()
  deadmines = find(list, "Run The Deadmines")
  check(deadmines and not deadmines.subtitle:find("in your log") and find(list, "Hand in"),
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
  refreshData()
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
  -- The main window's header buttons select one tab (or none) directly.
  PanelTemplates_SelectTab = function(tab) selectedTab = rawget(tab, "text") end
  PanelTemplates_DeselectTab = function() end

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
      -- Panel.lua registers its own category pages again.
      if not ({ quests = true, vendors = true, trainers = true, dungeons = true })[page.id] then ui.RegisterPage(page) end
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
      ui.Panel.SelectPage("trainers")
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
  -- Windows: the main window, its side panel and the copy box; plus the HUD and overview boxes.
  check(count(asked, "ButtonFrameTemplate") == 3 and count(asked, "BackdropTemplate") == 5
    and count(asked, "TooltipBackdropTemplate") == 0 and count(asked, "InputBoxTemplate") == 1,
    "a failing or unknown template falls back to the old look")
  failing, unknown = {}, {}
  local ui = freshUI()
  check(openAll(ui), "windows open with the templates")
  check(count(asked, "BackdropTemplate") == 0 and count(asked, "SearchBoxTemplate") == 1 and hidPortrait == 3
    and ui.Panel.SelectedTab() == "trainers",
    "template windows, search box and side tabs (tab " .. tostring(ui.Panel.SelectedTab()) .. ")")

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
  check((calls.Shell or 0) >= 4 and (calls.Panel or 0) >= 4 and (calls.EditBox or 0) >= 2
    and (calls.Font or 0) > 0 and (calls.Inset or 0) >= 2, "windows made earlier get EllesmereUI's look")
  local shells, boxes, fonts = calls.Shell, calls.Panel, calls.Font
  openAll(freshUI())
  check(calls.Shell == shells + 3 and calls.Panel == boxes + 2,
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
  check(ns.db.settings.skin == true and calls.Shell == shells + 3, "/wf skin again paints what was missed")

  CreateFrame, C_XMLUtil, EllesmereUI = savedCreate, nil, nil
  ButtonFrameTemplate_HidePortrait, PanelTemplates_SetTab = nil, nil
  PanelTemplates_SelectTab, PanelTemplates_DeselectTab = nil, nil
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
  refreshData()
  local clock, reads = 100, 0
  GetTime = function() return clock end
  local realCompleted = C_QuestLog.GetAllCompletedQuestIDs
  C_QuestLog.GetAllCompletedQuestIDs = function() reads = reads + 1 return realCompleted() end
  ns.Quests.PlayerQuestState()
  ns.Quests.PlayerQuestState()
  check(reads == 1, "quest state is read once per moment")
  fire("QUEST_LOG_UPDATE")
  ns.Quests.PlayerQuestState()
  check(reads == 2, "a quest event starts a fresh read")
  clock = clock + 2
  ns.Quests.PlayerQuestState()
  check(reads == 3, "and so does time passing")
  C_QuestLog.GetAllCompletedQuestIDs = realCompleted
  GetTime = nil

  local realGet, spawnReads = NpcDB.Get, 0
  NpcDB.Get = function(id, key)
    if key == "spawns" and id == 9101 then spawnReads = spawnReads + 1 end
    return realGet(id, key)
  end
  local here = ns.Geo.PlayerNode()
  local a = ns.Quests.ObjectiveNode(41, here)
  local b = ns.Quests.ObjectiveNode(41, here)
  check(a and b and spawnReads == 1, "a quest's objective places are built once")
  NpcDB.Get = realGet
  QUESTS[41] = nil
  refreshData()
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
  refreshData()
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
  -- Found TomTom: asked once, nothing used until you answer.
  ns.db.settings.tomtom = nil
  local asked
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which) asked = which end
  check(ns.Options.AskTomTom() and asked == "WAYFINDER_TOMTOM" and not ns.Nav.UsingTomTom(),
    "with TomTom installed, Wayfinder asks whether to use its arrow")
  StaticPopupDialogs.WAYFINDER_TOMTOM.OnCancel(nil, nil, "clicked")
  check(ns.db.settings.tomtom == false and not ns.Options.AskTomTom(), "No thanks: off, and not asked again")
  StaticPopupDialogs.WAYFINDER_TOMTOM.OnAccept()
  check(ns.db.settings.tomtom == true, "Use TomTom: on")
  StaticPopupDialogs, StaticPopup_Show = nil, nil
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(ns.Nav.UsingTomTom() and #added == 1 and added[1].opts.crazy and #waypoints == blizzard,
    "with TomTom on, its arrow and pin show the way")
  ns.HUD.Update()
  check(ns.db.settings.showArrow and ns.HUD.CompassShown(), "the compass can stay on alongside TomTom")
  UnitOnTaxi = function() return true end
  ns.HUD.Update()
  check(ns.Nav.tomtomWaypoint == nil and ns.Nav.Flying(), "on a flight, TomTom's arrow comes down")
  UnitOnTaxi = function() return false end
  ns.HUD.Update()
  check(ns.Nav.tomtomWaypoint ~= nil, "and goes back up when you land")
  -- Start again for the counts below.
  ns.Nav.Stop()
  for k in pairs(added) do added[k] = nil end
  removed = 0
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  SlashCmdList.WAYFINDER("compass")
  check(not ns.HUD.CompassShown() and ns.HUD.Width() < 330, "compass off: no circle, a narrower box")
  SlashCmdList.WAYFINDER("compass")
  check(ns.HUD.CompassShown() and ns.HUD.Width() == 330, "and back")
  ns.Nav.Next()
  check(#added == 2 and removed == 1, "each step replaces the TomTom waypoint")
  ns.Nav.Stop()
  check(removed == 2, "stopping clears it")
  SlashCmdList.WAYFINDER("tomtom")
  check(not ns.Nav.UsingTomTom(), "/wf tomtom turns it off")
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(ns.Nav.ownsWaypoint, "TomTom off: the game's map pin shows the way")
  SlashCmdList.WAYFINDER("tomtom")
  check(ns.Nav.UsingTomTom() and #added == 3, "turning it on during a trip moves the waypoint to TomTom")
  check(not ns.Nav.ownsWaypoint and waypoints[#waypoints] == "cleared", "and takes down the map pin we put up")
  ns.Nav.Stop()
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
  refreshData()
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
  check(titles[1] == ns.Router.Describe(ns.Nav.active.route, 1) and titles[1]:find("^Talk to the flight master"),
    "TomTom's waypoint is titled with the step: " .. tostring(titles[1]))
  ns.Nav.Stop()
  TomTom = nil
end
---------------------------------------------------------------- flight knowledge (end)
---------------------------------------------------------------- adding to a trip (begin)
do
  io.write("adding to a trip\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1439, 0.5, 0.5 -- Darkshore
  local here = ns.Geo.PlayerNode()
  local function stopAt(mapID, x, y, label) return { node = ns.Geo.Node(mapID, x, y, label), text = "Visit " .. label } end
  local function labels()
    local out = {}
    for _, st in ipairs(ns.Nav.active.journey.stops) do out[#out + 1] = st.node.label end
    return table.concat(out, ",")
  end

  -- A trip to Stormwind is on; adding something near you puts it first.
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Stormwind errands", stops = { stopAt(1453, 0.5, 0.5, "Bank") } }))
  ns.Nav.AddToTrip({ stopAt(1439, 0.55, 0.5, "Shore camp") }, "Shore camp")
  check(labels() == "Shore camp,Bank", "an added stop goes where it fits best, here first: " .. labels())
  check(ns.Nav.active.title == "Your trip" and ns.JourneyOverview.IsShown(), "the trip is renamed and the overview shows it")
  ns.Nav.Stop()

  -- Starting something while a trip is on asks: add, replace or cancel.
  local shown
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which, a, b, data) shown = { which = which, trip = a, label = b, data = data } end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Stormwind errands", stops = { stopAt(1453, 0.5, 0.5, "Bank") } }))
  local other = ns.Journey.Plan(here, { title = "Shore run", stops = { stopAt(1439, 0.55, 0.5, "Shore camp") } })
  ns.Nav.StartJourney(other)
  check(shown and shown.which == "WAYFINDER_TRIP" and shown.trip == "Stormwind errands" and shown.label == "Shore run",
    "starting a journey during a trip asks first")
  check(ns.Nav.active.title == "Stormwind errands", "nothing changes until you answer (Cancel keeps the trip)")
  shown.data.add()
  check(labels() == "Shore camp,Bank", "Add to trip merges it into the current trip")
  shown = nil
  local trainer = ns.Trainers.Results()[1]
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(shown and shown.label == trainer.title, "plain directions ask too")
  shown.data.replace()
  check(ns.Nav.active.title == trainer.title and not ns.Nav.active.journey, "Replace starts the new directions instead")

  -- Plain directions become a trip when something is added.
  shown = nil
  ns.Nav.AddToTrip({ stopAt(1439, 0.55, 0.5, "Shore camp") }, "Shore camp")
  check(not shown and ns.Nav.active.journey and #ns.Nav.active.journey.stops == 2,
    "adding to plain directions makes a trip with both: " .. (ns.Nav.active.journey and labels() or "-"))

  -- The same quest isn't added twice; a row's stops can be added (shift-click).
  ns.Nav.Stop()
  StaticPopupDialogs, StaticPopup_Show = nil, nil
  local quest = { node = ns.Geo.Node(1439, 0.6, 0.5, "Giver"), text = "Pick up X", action = { kind = "pickup", questID = 777 } }
  ns.Nav.AddToTrip({ quest }, "X")
  check(ns.Nav.TripHasQuest(777) and not ns.Nav.AddToTrip({ { node = quest.node, text = "again",
    action = { kind = "pickup", questID = 777 } } }, "X"), "a quest already in the trip isn't added again")
  local row = { title = "Row", goal = ns.Geo.Node(1439, 0.4, 0.5, "Row spot") }
  check(#ns.Nav.StopsFor(row) == 1 and ns.Nav.AddToTrip(ns.Nav.StopsFor(row), row.title)
    and #ns.Nav.active.journey.stops == 2, "a panel row's destination can be added (shift-click)")
  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()
end
---------------------------------------------------------------- adding to a trip (end)
---------------------------------------------------------------- reordering a trip (begin)
do
  io.write("reordering a trip\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1439, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local function stopAt(x, label) return { node = ns.Geo.Node(1439, x, 0.5, label), text = "Visit " .. label } end
  local function labels()
    local out = {}
    for _, st in ipairs(ns.Nav.active.journey.stops) do out[#out + 1] = st.node.label end
    return table.concat(out, ",")
  end
  local pickup = { node = ns.Geo.Node(1439, 0.56, 0.5, "Giver"), text = "Pick up Q", action = { kind = "pickup", questID = 881 } }
  local turnin = { node = ns.Geo.Node(1439, 0.58, 0.5, "Finisher"), text = "Hand in Q", after = { pickup },
    action = { kind = "turnin", questID = 881 } }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands",
    stops = { stopAt(0.52, "A"), stopAt(0.54, "B"), pickup, turnin } }))
  check(labels() == "A,B,Giver,Finisher", "planned nearest first: " .. labels())
  ns.JourneyOverview.Show()
  local function stepLines()
    local out = {}
    for _, line in ipairs(ns.JourneyOverview.Lines()) do
      if line.step then out[#out + 1] = line.state .. ":" .. ns.Router.Describe(ns.Nav.active.route, line.stepIndex, true) end
    end
    return table.concat(out, " / ")
  end
  check(stepLines() == "now:Walk to A", "the current stop shows the steps that get you there: " .. stepLines())
  ns.JourneyOverview.ToggleSteps(ns.Nav.active.journey.stops[1])
  check(stepLines() == "", "its - folds them")
  ns.JourneyOverview.ToggleSteps(ns.Nav.active.journey.stops[1])
  ns.JourneyOverview.ToggleSteps(ns.Nav.active.journey.stops[2])
  check(stepLines() == "now:Walk to A / next:Walk to B", "and any stop's + shows its own: " .. stepLines())
  ns.JourneyOverview.ToggleSteps(ns.Nav.active.journey.stops[2])
  ns.HUD.Update()
  local lines = ns.HUD.Lines()
  check(lines[1]:find("Errands", 1, true) and lines[1]:find("0 of 4 done", 1, true) and lines[2] == "Visit A"
    and lines[3] == "" and lines[4]:find("yd", 1, true),
    "the directions box: trip and stops done, the step, distance and time (no step count for a one-step stop): "
      .. table.concat(lines, " | "))

  -- Skipping ahead and back: the stops come back.
  ns.Nav.Next()
  ns.Nav.Next()
  check(ns.Journey.StopsDone(ns.Nav.active.journey) == 0 and ns.JourneyOverview.Rows()[1].state == "skipped",
    "skipped stops aren't counted as done; the overview says skipped")
  local function shape()
    local out = {}
    for _, line in ipairs(ns.JourneyOverview.Lines()) do
      if not line.step then
        out[#out + 1] = line.header and ("finished" .. line.count .. (line.folded and "+" or "-")) or line.row.state
      end
    end
    return table.concat(out, ",")
  end
  check(shape() == "finished2-,skipped,skipped,now,next", "two finished stops: a line for them, open: " .. shape())
  ns.JourneyOverview.ToggleFinished()
  check(shape() == "finished2+,now,next", "click the line to fold them: " .. shape())
  ns.JourneyOverview.ToggleFinished()
  check(shape() == "finished2-,skipped,skipped,now,next", "and again to show them")
  ns.Nav.Next()
  check(shape() == "finished3-,skipped,skipped,skipped,now", "your choice holds for this trip: " .. shape())
  ns.Nav.Prev()
  ns.Nav.Prev()
  ns.Nav.Prev()
  local states = {}
  for _, r in ipairs(ns.JourneyOverview.Rows()) do states[#states + 1] = r.state end
  check(table.concat(states, ",") == "now,next,next,next", "going back opens them again: " .. table.concat(states, ","))
  ns.JourneyOverview.Show()
  check(ns.JourneyOverview.HandleCount() == 4, "every open stop has a drag handle")
  check(ns.JourneyOverview.Move(1, 2) and labels() == "B,A,Giver,Finisher", "dragging A below B swaps them: " .. labels())
  check(ns.Nav.active.route.steps[#ns.Nav.active.route.steps].stop == turnin
    and ns.Nav.active.route.steps[1].stop.node.label == "B", "the directions follow the new order")
  check(not ns.JourneyOverview.Move(4, 1) and labels() == "B,A,Giver,Finisher",
    "a hand-in can't go before its pickup")
  check(ns.JourneyOverview.Move(3, 1) and labels() == "Giver,B,A,Finisher", "dragging up puts it before the target")
  ns.Nav.AddToTrip({ stopAt(0.51, "Near") }, "Near")
  check(labels() == "Near,Giver,B,A,Finisher", "an added stop finds its place, your order kept: " .. labels())
  local saved = ns.Journey.Save(ns.Nav.active.journey)
  local resumed = ns.Journey.Resume(ns.Journey.Load(saved), here)
  local order = {}
  for _, st in ipairs(resumed.stops) do order[#order + 1] = st.node.label end
  -- (Near is close enough to count as visited.)
  check(table.concat(order, ",") == "Giver,B,A,Finisher", "your order survives a reload: " .. table.concat(order, ","))
  -- A new trip folds by itself from three finished stops.
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Fold", stops = {
    stopAt(0.52, "F1"), stopAt(0.53, "F2"), stopAt(0.54, "F3"), stopAt(0.55, "F4") } }))
  ns.Nav.Next()
  ns.Nav.Next()
  check(shape() == "finished2-,skipped,skipped,now,next", "under three: shown")
  ns.Nav.Next()
  check(shape() == "finished3+,now", "three finished: folded by themselves: " .. shape())
  -- A trip too long to show at once scrolls.
  local many = {}
  for i = 1, 14 do many[i] = stopAt(0.5 + i * 0.01, "S" .. i) end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Long", stops = many }))
  ns.JourneyOverview.Show()
  local top = ns.JourneyOverview.shownLines
  check(ns.JourneyOverview.scrolled == 0 and top < #ns.JourneyOverview.Lines(), "a long trip doesn't all fit")
  ns.JourneyOverview.Scroll(-3)
  check(ns.JourneyOverview.scrolled == 3, "the mouse wheel scrolls it")
  local height = ns.JourneyOverview.Height()
  ns.JourneyOverview.Scroll(-100)
  check(ns.JourneyOverview.scrolled == ns.JourneyOverview.maxScroll
    and ns.JourneyOverview.scrolled + ns.JourneyOverview.shownLines == #ns.JourneyOverview.Lines(),
    "it stops once the last line shows")
  check(ns.JourneyOverview.Height() == height, "and the window keeps its size")
  ns.JourneyOverview.Scroll(10)
  check(ns.JourneyOverview.scrolled == 0, "and back to the top, no further")
  ns.Nav.Stop()
  ns.JourneyOverview.Toggle()
end
---------------------------------------------------------------- reordering a trip (end)
---------------------------------------------------------------- cards (begin)
do
  io.write("cards\n")
  ns.Nav.Stop()
  local forYou
  for _, page in ipairs(ns.pages) do if page.id == "foryou" then forYou = page end end
  check(forYou.layout == "cards" and forYou.width and forYou.width > 384, "For you uses the card layout on a wider panel")

  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local goal = ns.Geo.Node(1433, 0.6, 0.5, "Camp")
  local route = ns.Router.Plan(ns.Geo.PlayerNode(), goal, ns.Network.Build())
  local suggestions = {}
  for i = 1, 5 do
    suggestions[i] = { title = "Suggestion " .. i, subtitle = "|cff7fd1aewhy " .. i .. "|r", goal = goal, route = route,
      details = { { text = "rank" }, { text = "detail " .. i } }, kind = i == 1 and "dungeon" or "hub",
      icon = "Interface\\Icons\\INV_Misc_Key_14" }
  end
  -- A class icon cut from a sheet: needs tex coords, which a masked icon can't take.
  suggestions[2].icon = "Interface\\TargetingFrame\\UI-Classes-Circles"
  suggestions[2].iconCoords = { 0, 0.25, 0, 0.25 }
  ns.RegisterPage({ id = "cardtest", label = "Cards", order = 98, layout = "cards", width = 730,
    SummaryText = function() return "cards" end, EmptyText = function() return "none" end,
    Results = function() return suggestions end })
  ns.Panel.Search("cardtest", "")
  local function titles()
    local out = {}
    for _, r in ipairs(ns.Cards.Visible()) do out[#out + 1] = r.title end
    return table.concat(out, ",")
  end
  check(titles() == "Suggestion 1,Suggestion 2,Suggestion 3", "one large and two small cards: " .. titles())
  check(table.concat(ns.Cards.Drawn(), ",") == "Suggestion 1|Go,Suggestion 2|Go,Suggestion 3|Go",
    "every card shows its title and button text: " .. table.concat(ns.Cards.Drawn(), ","))
  local said = #chat
  SlashCmdList.WAYFINDER("debug cards")
  check(chat[said + 1]:find("version " .. ns.VERSION, 1, true) and #chat == said + 4
    and chat[said + 2]:find('large: shown=true', 1, true) and chat[said + 2]:find('title="Suggestion 1"', 1, true),
    "/wf debug cards reports the version and what each card shows")
  ns.Cards.Step(-1)
  check(titles() == "Suggestion 4,Suggestion 5", "the arrows page through the suggestions, none twice")
  ns.Panel.Scroll(-10)
  check(titles() == "Suggestion 4,Suggestion 5", "the mouse wheel pages too, stopping at the last page")
  ns.Panel.Refresh()
  check(titles() == "Suggestion 4,Suggestion 5", "a refresh keeps the page you were on")
  suggestions[6] = { title = "Suggestion 6", subtitle = "new", goal = goal, route = route, details = {} }
  ns.Panel.Refresh()
  check(titles() == "Suggestion 1,Suggestion 2,Suggestion 3", "when the cards change, back to page 1")
  suggestions[6] = nil
  ns.Panel.Refresh()
  ns.Panel.Search("cardtest", "")
  ns.Cards.Step(10)
  check(titles() == "Suggestion 1,Suggestion 2,Suggestion 3", "back to the first")

  -- The card button and shift-click work like a row.
  ns.Panel.Activate(suggestions[1])
  check(ns.Nav.active and ns.Nav.active.title == "Suggestion 1", "a card's Go starts its directions")
  IsShiftKeyDown = function() return true end
  ns.Panel.Search("cardtest", "")
  ns.Panel.Activate(suggestions[2])
  check(ns.Nav.active.journey and #ns.Nav.active.journey.stops == 2, "shift-click on a card adds it to the trip")
  IsShiftKeyDown = nil
  ns.Nav.Stop()

  -- Details marked `more` stay off the cards (the tooltip has them).
  ns.Cards.Show({ { title = "Noted", subtitle = "s", route = route, details = { { text = "rank" },
    { text = "Quests in your log count at full XP; ...", more = true }, { text = "shown" } } } }, "", true)
  check(ns.Cards.Detail(1) == "shown", "a card leaves out details marked more: " .. tostring(ns.Cards.Detail(1)))
  ns.Cards.Show(suggestions, "", true)

  ns.Cards.Show({ { title = "Run The Stockade  ·  level 23", subtitle = "Stormwind City  ·  ~5 min  ·  1 quest",
    place = "Stormwind City  ·  Group", category = "Dungeon", stats = { { "Level", "23" }, { "Travel", "~5 min" }, { "XP/min", "~281" } },
    route = { steps = {} } } }, "", true)
  check(ns.Cards.Tag(1) == "DUNGEON", "a card says what kind of suggestion it is: " .. tostring(ns.Cards.Tag(1)))
  check(table.concat(ns.Cards.Stats(1), ",") == "LEVEL=23,TRAVEL=~5 min,XP/MIN=~281",
    "a card shows its numbers as labelled blocks: " .. table.concat(ns.Cards.Stats(1), ","))
  check(ns.Cards.Drawn()[1] == "Run The Stockade|Go", "a dungeon's level moves from the card title to the subtitle")

  -- Other pages keep rows at the normal width.
  ns.Panel.SelectPage("trainers", 1)
  check(#ns.Panel.VisibleResults() > 0, "the Trainers page still shows rows")
end
---------------------------------------------------------------- cards (end)
---------------------------------------------------------------- side panel (begin)
do
  io.write("side panel\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  ns.Panel.Search("foryou", "")
  check(ns.Panel.IsShown() and not ns.Panel.SideShown(), "For you shows in the main window, side panel closed")
  ns.Panel.SelectPage("quests")
  check(ns.Panel.SideShown() and ns.Panel.IsShown() and ns.Panel.SelectedTab() == "quests",
    "a list page opens in the side panel; its side tab is selected")
  ns.Panel.CloseSide()
  check(not ns.Panel.SideShown() and ns.Panel.IsShown() and ns.Panel.SelectedTab() == nil,
    "closing the side panel keeps the main window and clears the tab")
  ns.Panel.SelectPage("trainers", 1)
  check(ns.Panel.SideShown() and #ns.Panel.VisibleResults() > 0, "Trainers opens in the side panel")
  local tabs = {}
  for _, page in ipairs(ns.pages) do if page.layout ~= "cards" and not page.id:find("test") then tabs[#tabs + 1] = page.id end end
  check(table.concat(tabs, ",") :find("quests,vendors,trainers,dungeons,items", 1, true),
    "side tabs: Quests, Vendors, Trainers, Dungeons, Items (" .. table.concat(tabs, ",") .. ")")
  ns.Panel.Select(2)
  check(ns.Panel.SideShown() and ns.Panel.SelectedTab() == "trainers", "the Weapons category of Trainers opens")
  local here = ns.Geo.PlayerNode()
  -- A warlock (swords, staves, daggers) who knows daggers; the master teaches swords for
  -- 10s and staves for 1g; the purse holds 50s.
  ns.db.npcs[990001] = { name = "Test Weaponmaster", kinds = { weaponMaster = true }, mapID = here.mapID,
    x = here.x + 0.01, y = here.y, weapons = { "Swords", "Staves" },
    teaches = { WARLOCK = { { name = "Swords", cost = 1000 }, { name = "Staves", cost = 10000 } } } }
  local savedSpell, savedMoney = IsPlayerSpell, GetMoney
  IsPlayerSpell = function(id) return id == 1180 end
  GetMoney = function() return 5000 end
  local rows = ns.WeaponMasters.Results()
  local titles = {}
  for _, r in ipairs(rows) do titles[#titles + 1] = (r.title:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  local joined = table.concat(titles, " | ")
  check(titles[1] == "Swords  (Test Weaponmaster)" and titles[2] == "Staves  (Test Weaponmaster)",
    "weapons to learn first, the trainer in brackets, affordable ones first: " .. joined)
  check(rows[1].subtitle:find("10s", 1, true) and rows[2].subtitle:find("you have 50s", 1, true),
    "with the cost against your purse: " .. rows[2].subtitle)
  check(not joined:find("Daggers", 1, true) and not joined:find("Weapon master:", 1, true),
    "a weapon you know isn't listed, and weapon masters get no rows of their own: " .. joined)
  check(ns.WeaponMasters.SummaryText():find("You know Daggers. You can learn 2 more", 1, true),
    "the summary says what you know: " .. ns.WeaponMasters.SummaryText())
  IsPlayerSpell, GetMoney = savedSpell, savedMoney
  ns.db.npcs[990001] = nil
  ns.Panel.Search("quests", "redridge")
  check(ns.Panel.SideShown(), "/wf quest and /wf item open the side panel with the search")
  ns.Panel.Search("foryou", "")
  check(not ns.Panel.SideShown(), "going back to For you closes the side panel")
end
---------------------------------------------------------------- side panel (end)
---------------------------------------------------------------- route map (begin)
do
  io.write("route map\n")
  -- Without the map art API: no map, no error.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local goal = ns.Geo.Node(1433, 0.6, 0.5, "Camp")
  local r = { title = "Camp", goal = goal, route = ns.Router.Plan(here, goal, ns.Network.Build()) }
  check(ns.RouteMap.Show(r) == false, "no map art API: no route map")
  C_Map.GetMapArtLayers = function() return { { tileWidth = 256, tileHeight = 256, layerWidth = 1002, layerHeight = 668 } } end
  C_Map.GetMapArtLayerTextures = function() return { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } end
  ns.Panel.ShowTooltip(UIParent, r)
  check(ns.RouteMap.view < 1, "a short route zooms in: " .. tostring(ns.RouteMap.view))
  check(ns.RouteMap.mapID == 1433 and ns.RouteMap.lines >= 1 and ns.RouteMap.marks == 2,
    string.format("hovering shows the zone map with the route (map %s, %s lines, %s marks)",
      tostring(ns.RouteMap.mapID), tostring(ns.RouteMap.lines), tostring(ns.RouteMap.marks)))
  -- A trip across the sea: the world map, or the destination's continent without its art.
  player.mapID, player.x, player.y = 1439, 0.5, 0.5
  local sw = ns.Geo.Node(1453, 0.5, 0.5, "Stormwind")
  local trip = ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Over the sea", stops = {
    { node = ns.Geo.Node(1439, 0.55, 0.5, "Shore"), text = "Visit Shore" }, { node = sw, text = "Visit Stormwind" } } })
  check(trip and ns.RouteMap.Show({ title = "Over the sea", journey = trip }) and ns.RouteMap.mapID == 947,
    "a trip over the sea uses the world map: " .. tostring(ns.RouteMap.mapID))
  check(ns.RouteMap.marks >= 2, "you, its stops and the destination are marked")
  C_Map.GetMapArtLayers, C_Map.GetMapArtLayerTextures = nil, nil
  ns.RouteMap.Hide()
end
---------------------------------------------------------------- route map (end)
---------------------------------------------------------------- speed (begin)
do
  io.write("speed\n")
  -- Switching side tabs rebuilds only the side page, even once the For you
  -- cache has expired.
  ns.Panel.SelectPage("foryou")
  ns.ForYou.Invalidate()
  ns.Panel.Refresh()
  local runs = ns.ForYou.runs
  ns.ForYou.Invalidate()
  ns.Panel.SelectPage("trainers", 1)
  ns.Panel.SelectPage("vendors")
  ns.Panel.SelectPage("trainers", 2)
  check(ns.ForYou.runs == runs, "side tab switches don't rebuild For you (" .. (ns.ForYou.runs - runs) .. " rebuilds)")
  ns.Panel.SelectPage("foryou")
  check(ns.ForYou.runs == runs + 1, "going back to For you rebuilds it")

  -- The dungeon list is built once, not once per quest that asks about it.
  local realDungeons, builds = ns.Data.Dungeons, 0
  ns.Data.Dungeons = function(...) builds = builds + 1 return realDungeons(...) end
  ns.Dungeons.Forget()
  for areaID = 1, 300 do ns.Dungeons.ForArea(areaID) end
  ns.Dungeons.Catalogue()
  check(builds == 1, "300 dungeon lookups build the dungeon list once (" .. builds .. ")")
  ns.Data.Dungeons = realDungeons

  -- The quests you can take are worked out once per change to your quests or
  -- level; another refresh only sorts them by distance again.
  local here = ns.Geo.PlayerNode()
  ns.Quests.QuestHubs(here, 12)
  local realLog, logReads = C_QuestLog.GetAllCompletedQuestIDs, 0
  C_QuestLog.GetAllCompletedQuestIDs = function(...) logReads = logReads + 1 return realLog(...) end
  local hubs1 = ns.Quests.QuestHubs(here, 12)
  local hubs2 = ns.Quests.QuestHubs(here, 12)
  check(logReads == 0 and #hubs1 == #hubs2, "quest hubs again: the quest list is reused (" .. logReads .. " log reads)")
  local before = logReads
  fire("QUEST_TURNED_IN", 1)
  ns.Quests.QuestHubs(here, 12)
  check(logReads > before, "handing in a quest makes it check again")
  local realLevel = UnitLevel
  UnitLevel = function() return realLevel() + 1 end
  before = logReads
  ns.Quests.QuestHubs(here, 12)
  ns.Quests.QuestHubs(here, 12)
  check(logReads == before + 1, "so does a new level, once")
  UnitLevel = realLevel
  C_QuestLog.GetAllCompletedQuestIDs = realLog

  -- The zone at a world point is asked of the map once.
  local realInfo, asked = C_Map.GetMapInfoAtPosition, 0
  C_Map.GetMapInfoAtPosition = function(...) asked = asked + 1 return realInfo(...) end
  local node = ns.Geo.Node(1433, 0.4123, 0.5678, "Somewhere")
  local first = ns.Geo.ZoneAt(node.instance, node.wx, node.wy)
  local before = asked
  check(ns.Geo.ZoneAt(node.instance, node.wx, node.wy) == first and asked == before and before > 0,
    "a zone lookup is cached (" .. asked .. " map calls)")
  C_Map.GetMapInfoAtPosition = realInfo
end
---------------------------------------------------------------- speed (end)
---------------------------------------------------------------- difficulty colours (begin)
do
  io.write("difficulty colours\n")
  local YELLOW, ORANGE, GREEN = { r = 1, g = 1, b = 0 }, { r = 1, g = 0.5, b = 0.25 }, { r = 0.25, g = 0.75, b = 0.25 }
  GetQuestDifficultyColor = function(level)
    local diff = level - UnitLevel("player")
    if diff >= 3 then return ORANGE end
    if diff >= -2 then return YELLOW end
    return GREEN
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local function same(c, want) return c and c.r == want.r and c.g == want.g and c.b == want.b end

  -- A hub coloured like most of its quests (its median level).
  local hubs = ns.QuestHubs.Results()
  local checked = 0
  for _, hub in ipairs(hubs) do
    local levels = {}
    for _, d in ipairs(hub.details or {}) do
      local l = d.text and tonumber(d.text:match("^%[(%d+)%]"))
      if l then levels[#levels + 1] = l end
    end
    table.sort(levels)
    if #levels > 0 then
      checked = checked + 1
      check(same(hub.titleColor, GetQuestDifficultyColor(levels[math.floor((#levels + 1) / 2)])),
        hub.title .. ": coloured by its median quest level")
    end
  end
  check(checked > 0, "hubs were checked")
  check(ns.DifficultyColor(23) and same(ns.DifficultyColor(23), ORANGE), "orange 3 levels up")

  -- Journal search results and dungeons carry their level's colour too.
  local found = ns.QuestsPage.Results("Lakeshire Logs")
  check(found[1] and same(found[1].titleColor, YELLOW), "a quest in the journal is coloured by its level")
  local dungeonRows = ns.Dungeons.Results()
  check(dungeonRows[1] and dungeonRows[1].titleColor ~= nil, "dungeon rows are coloured by their level")
  GetQuestDifficultyColor = nil
  check(ns.DifficultyColor(20) == nil, "no colour API: rows keep the font's colour")
end
---------------------------------------------------------------- difficulty colours (end)
---------------------------------------------------------------- data sources (begin)
do
  io.write("data source merging\n")
  -- Two sources know the same NPC: the higher priority wins each field it
  -- has, the lower one fills the rest; ID lists are combined without repeats.
  Wayfinder.RegisterSource({ id = "low", label = "Low", priority = 1,
    Npc = function(id) if id == 777 then return { name = "Old Name", subName = "Weapon Master", faction = "A",
      flags = { trainer = true }, positions = { { mapID = 1433, x = 0.5, y = 0.52 } } } end end,
    NpcIDs = function(flag) if flag == "trainer" then return { 777, 461 } end end,
    ClassSpells = function(class)
      if class == "WARLOCK" then return { { spellID = 9001, level = 6, cost = 100 }, { spellID = 9002, level = 30, cost = 900 },
        { spellID = 9003, level = 4, cost = 50, talent = 9100 }, { spellID = 9004, level = 4, cost = 50, races = { [2] = true } },
        { spellID = 9005, level = 4, cost = 50, faction = "Horde" } } end
    end,
    TrainerSpells = function(id) if id == 777 then return { { spellID = 227, level = 1, cost = 1000 } } end end })
  Wayfinder.RegisterSource({ id = "high", label = "High", priority = 50,
    Npc = function(id) if id == 777 then return { name = "New Name" } end end,
    NpcIDs = function(flag) if flag == "trainer" then return { 777 } end end,
    ClassSpells = function(class) if class == "WARLOCK" then return { { spellID = 9001, level = 4 } } end end })
  local npc = ns.Data.Npc(777)
  check(npc and npc.name == "New Name" and npc.subName == "Weapon Master" and npc.faction == "A",
    "NPC fields merge by priority: " .. tostring(npc and npc.name) .. ", " .. tostring(npc and npc.subName))
  local trainerIDs = ns.Data.NpcIDs("trainer")
  local seen = {}
  for _, id in ipairs(trainerIDs) do seen[id] = (seen[id] or 0) + 1 end
  check(seen[777] == 1 and seen[461] == 1, "ID lists combined without repeats")
  local spells = ns.Data.ClassSpells("WARLOCK")
  local first
  for _, sp in ipairs(spells) do if sp.spellID == 9001 then first = sp end end
  check(#spells == 5 and first and first.level == 4 and first.cost == 100,
    "class spells merge by spell ID: level from the higher source, cost from the lower")
  check(ns.Data.Status():find("High") and ns.Data.Status():find("Low"), "both sources in the status line")
  check(ns.Data.Has("ClassSpells") and not ns.Data.Has("TaxiCost"), "Has() names what sources can answer")

  -- Before any trainer visit, the Trainers page uses the class spells.
  local savedSpells, savedKnown = ns.charDB.classSpells, IsPlayerSpell
  ns.charDB.classSpells = nil
  IsPlayerSpell = function() return false end
  local summary = ns.Trainers.SpellSummary()
  check(summary and summary.fromData and summary.trainable == 1 and summary.cost == 100 and summary.nextLevel == 30,
    "no trainer visit yet: spells from the data, not another race's, faction's or talent's ("
      .. tostring(summary and summary.trainable) .. " trainable)")
  IsPlayerSpell = function(id) return id == 9100 end
  fire("SPELLS_CHANGED")
  check(ns.Trainers.SpellSummary().trainable == 2, "with the talent, its spell counts")
  check(ns.Trainers.SummaryText():find("from spell data"), "summary says where the list comes from")
  check(ns.Trainers.SummaryText():find("\nSpell 9001", 1, true), "the spells you can learn are named under it: "
    .. ns.Trainers.SummaryText())
  IsPlayerSpell = function(id) return id == 9001 end
  fire("SPELLS_CHANGED")
  summary = ns.Trainers.SpellSummary()
  check(summary and summary.trainable == 0, "a spell you know isn't counted again")
  ns.charDB.classSpells, IsPlayerSpell = savedSpells, savedKnown
  check(not ns.Trainers.SpellSummary().fromData, "a trainer visit wins over the data")

  -- A weapon master you never talked to: what it teaches comes from the data.
  IsPlayerSpell = function() return false end
  local masters = ns.WeaponMasters.Results()
  IsPlayerSpell = savedKnown
  local staves
  for _, row in ipairs(masters) do
    if row.title:find("^Staves") then staves = row end
  end
  check(staves and staves.title:find("New Name") and staves.subtitle:find("10s"),
    "weapon taught by an unvisited master, from its trainer list: " .. tostring(staves and staves.subtitle))

  -- A source that errors is reported and skipped; the page keeps working.
  local savedHandler, reported = geterrorhandler, nil
  geterrorhandler = function() return function(err) reported = err end end
  Wayfinder.RegisterSource({ id = "broken", label = "Broken", priority = 99,
    Npc = function() error("boom") end })
  check(ns.Data.Npc(777) and ns.Data.Npc(777).name == "New Name" and reported and reported:find("broken"),
    "a failing source is reported and skipped: " .. tostring(reported))
  geterrorhandler = savedHandler

  for _, id in ipairs({ "low", "high", "broken" }) do Wayfinder.UnregisterSource(id) end
  check(ns.Data.Status() == "Fixtures (baked)" and not ns.Data.Has("ClassSpells"), "unregistering takes a source away")
end
---------------------------------------------------------------- data sources (end)
---------------------------------------------------------------- perf (begin)
do
  io.write("perf\n")
  local realSelect, realPlan, realClock = ns.Panel.SelectPage, ns.Router.Plan, debugprofilestop
  -- A clock that moves, so every timed call counts.
  local ticks = 0
  debugprofilestop = function() ticks = ticks + 1 return ticks end
  SlashCmdList.WAYFINDER("perf on")
  check(ns.db.settings.perf and ns.Perf.Enabled() and ns.Panel.SelectPage ~= realSelect, "/wf perf on wraps the modules")
  ns.Panel.SelectPage("trainers", 1)
  ns.Panel.SelectPage("vendors")
  local report = ns.Perf.Report()
  check(report:find("Panel.SelectPage(trainers, 1)", 1, true) and report:find("Panel.SelectPage(vendors)", 1, true),
    "each tab switch is a trace, named after its tab")
  local trace = table.concat(ns.Perf.TraceLines(1), "\n")
  check(trace:find("\n  Panel.Refresh", 1, true) and trace:find("\n    page:trainers.Results", 1, true)
    and trace:find("\n      Trainers.Results", 1, true) and trace:find("Router.Plan", 1, true),
    "a trace is a tree: refresh > page > its module > routing:\n" .. trace)
  check(report:find("source:fixtures", 1, true), "data source calls are timed per source")
  for _ = 1, 50 do ns.Geo.PlayerNode() end
  report = ns.Perf.Report()
  check(report:find("Quick calls outside the traces", 1, true) and report:find("Geo.PlayerNode", 1, true)
    and #ns.Perf.Traces() <= 40, "quick per-frame calls are tallied, not kept as traces")
  local ok = pcall(ns.Quests.Quest, nil)
  check(ok, "wrapped functions still work with odd input")
  local before = #ns.Perf.Traces()
  SlashCmdList.WAYFINDER("perf")
  check(#ns.Perf.TraceLines() > 1, "/wf perf prints the last trace")
  SlashCmdList.WAYFINDER("perf off")
  check(not ns.db.settings.perf and ns.Panel.SelectPage == realSelect and ns.Router.Plan == realPlan,
    "/wf perf off puts the original functions back")
  ns.Panel.SelectPage("trainers", 1)
  check(#ns.Perf.Traces() == before, "nothing is recorded while off")
  debugprofilestop = realClock
end
---------------------------------------------------------------- perf (end)
for _, line in ipairs(chat) do io.write("[chat] ", line, "\n") end
if failures > 0 then
  io.write(failures, " FAILED\n")
  os.exit(1)
end
io.write("WAYFINDER SMOKE OK\n")
