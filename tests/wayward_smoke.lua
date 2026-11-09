-- Runs Wayward against stubbed WoW APIs and a fake two-continent world.
-- Checks our own logic (routing, step advance, harvesting, panel), not real
-- Forever behaviour. Usage (from repo root): lua tests/wayward_smoke.lua
-- WAYWARD_GAME=era runs it as the Classic Era client: no C_QuestLog.GetInfo
-- and friends (the old GetQuestLogTitle family instead) and no map pins.
local dir = arg[1] or "Wayward"
local ERA = os.getenv("WAYWARD_GAME") == "era"
local TEST_SOURCE = debug.getinfo(1, "S").source
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

-- A check of something only Forever does (its own quests, its moved maps,
-- its dungeons' low XP); Classic Era checks `era` instead, when given.
local function foreverCheck(cond, msg, era, eraMsg)
  if not ERA then return check(cond, msg) end
  if era ~= nil then return check(era, "Classic Era: " .. (eraMsg or msg)) end
  io.write("  skip ", msg, " (Forever only)\n")
end

-- A check about the game's map pin; Classic Era has none, so there it checks
-- that none was ever put up.
local function pinCheck(cond, msg)
  if ERA then return check(#waypoints == 0, "Classic Era, no map pin: " .. msg) end
  check(cond, msg)
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
          -- Like the game: a tooltip's colour and alpha must be numbers (SetText(text, r, g, b, alpha, wrap)).
          for i = 2, math.min(select("#", ...), 5) do
            local v = select(i, ...)
            if v ~= nil and type(v) ~= "number" then error("bad argument #" .. i .. " to 'SetText'", 2) end
          end
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
        elseif k == "SetFrameStrata" then rawset(self, "strata", (...))
        elseif k == "GetFrameStrata" then return rawget(self, "strata")
        elseif k == "SetFrameLevel" then rawset(self, "level", (...))
        elseif k == "GetFrameLevel" then return rawget(self, "level")
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
strsplit = function(sep, s) local r = {} for p in (s .. sep):gmatch("(.-)%" .. sep) do r[#r + 1] = p end return (unpack or table.unpack)(r) end
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
  -- Starting zones: no NPCs of their own (For you's starting-zone test fills them).
  [1429] = { cont = 1415, x0 = 0.40, y0 = 0.76, w = 0.08, h = 0.08, name = "Elwynn Forest" },
  [1426] = { cont = 1415, x0 = 0.28, y0 = 0.55, w = 0.08, h = 0.08, name = "Dun Morogh" },
  [1438] = { cont = 1414, x0 = 0.28, y0 = 0.05, w = 0.08, h = 0.08, name = "Teldrassil" },
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
UnitRace = function() return "Human", "Human", 1 end
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

if ERA then
  WOW_PROJECT_CLASSIC, WOW_PROJECT_ID = 2, 2
  -- Classic Era has no map pins.
  C_Map.CanSetUserWaypointOnMap, C_Map.SetUserWaypoint, C_Map.ClearUserWaypoint = nil, nil, nil
  UiMapPoint, C_SuperTrack, C_Trainer = nil, nil, nil
end

---------------------------------------------------------------- load

local ns = {}
for line in io.lines(dir .. "/Wayward.toc") do
  local file = line:match("^([^#%s].-%.lua)%s*$")
  if file then assert(loadfile(dir .. "/" .. file:gsub("\\", "/")))("Wayward", ns) end
end
-- The bundled zone links are the real world's; this one is made of rectangles
-- and has none, until the "walking between zones" section draws its own.
local BUNDLED_ZONE_LINKS = ns.data.zoneLinks
ns.data.zoneLinks = {}

local function fire(event, ...)
  -- Classic Era's QUEST_ACCEPTED has the quest log index first.
  if ERA and event == "QUEST_ACCEPTED" then return fire("QUEST_ACCEPTED_ERA", 1, ...) end
  if event == "QUEST_ACCEPTED_ERA" then event = "QUEST_ACCEPTED" end
  for _, f in ipairs(events[event] or {}) do f.scripts.OnEvent(f, event, ...) end
end
local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

-- Saved variables from the addon's time as Wayfinder, as the client would
-- restore them from the old files (keys the addon doesn't touch, so the rest
-- of the run starts from defaults).
WayfinderDB = { legacy = { note = "Old" }, settings = { legacyFlag = true } }
WayfinderCharDB = { legacyChar = 7 }

fire("ADDON_LOADED", "Wayward")

---------------------------------------------------------------- tests

io.write("built-in sources\n")
check(ns.Data.Has("ClassSpells") and ns.Data.ClassSpells("WARLOCK") and #ns.Data.ClassSpells("WARLOCK") > 50
  and ns.Data.Status() == "Class spells", "the built-in class spells register at load: " .. tostring(ns.Data.Status()))
check(not ns.Data.Has("Quest") and not ns.questieLive, "without QuestieDB there is no quest source")
-- The rest of the run uses fixtures only.
Wayward.UnregisterSource("spells")
check(ns.Data.Status() == nil, "unregistered for the fixture tests")

io.write("rename\n")
check(ns.db == WaywardDB and ns.db.legacy and ns.db.legacy.note == "Old" and ns.db.settings.legacyFlag == true,
  "WayfinderDB is copied into WaywardDB on the first load")
check(ns.charDB == WaywardCharDB and ns.charDB.legacyChar == 7, "WayfinderCharDB likewise")
check(ns.db ~= WayfinderDB and WayfinderDB.legacy ~= ns.db.legacy and WayfinderDB.settings.minimapIcon == nil,
  "the old tables are left as they were (a copy, not a reference)")
WaywardDB.marker = "kept"
WayfinderDB.later = true
fire("ADDON_LOADED", "Wayward")
check(WaywardDB.marker == "kept" and WaywardDB.later == nil, "a later load doesn't copy again over Wayward data")
check(Wayfinder == Wayward and Wayfinder.RegisterSource == Wayward.RegisterSource, "Wayfinder is an alias of the Wayward global")
check(SlashCmdList.WAYWARD and SLASH_WAYWARD1 == "/wayward" and SLASH_WAYWARD2 == "/ww" and SLASH_WAYWARD3 == "/wf",
  "/wayward, /ww and the old /wf all reach the command")

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
fire("TRAINER_CLOSED")
check(ns.charDB.skippedSpells and ns.charDB.skippedSpells["Life Tap"] and not ns.charDB.skippedSpells["Shadow Bolt"]
  and not ns.charDB.skippedSpells["Corruption"], "closing the trainer remembers what you could learn and didn't")
check(ns.Trainers.SpellSummary(true).trainable == 0 and ns.Trainers.SpellSummary(true).skipped == 1,
  "which a summary can leave out")
ns.charDB.skippedSpells = nil
check(summary and summary.nextLevel == 24 and summary.nextCount == 1, "next spell at level 24")
check(ns.db.npcs[999] and ns.db.npcs[999].kinds.classTrainer and ns.db.npcs[999].class == "WARLOCK",
  "trainer harvested as a warlock class trainer")
-- Classic Era gives a service's name once it has loaded (its rank may come
-- first): the rank isn't taken for a name, and the list is read again then.
do
  local realInfo, lateName = GetTrainerServiceInfo, nil
  GetTrainerServiceInfo = function(i)
    if i == 4 then return lateName, "Rank 2", "unavailable", false end
    return realInfo(i)
  end
  SERVICES[4] = { req = 22, cost = 900 }
  local function named(name)
    for _, s in ipairs(ns.charDB.classSpells.services) do if s.name == name then return s end end
  end
  fire("TRAINER_SHOW")
  runTimers()
  check(#ns.charDB.classSpells.services == 3 and not named("Rank 2"), "a service with no name yet isn't read")
  lateName = "Drain Life"
  fire("TRAINER_SERVICE_INFO_NAME_UPDATE")
  check(named("Drain Life") and named("Drain Life").rank == "Rank 2", "once its name loads, it is")
  fire("TRAINER_CLOSED")
  SERVICES[4], GetTrainerServiceInfo = nil, realInfo
  fire("TRAINER_SHOW")
  runTimers()
  fire("TRAINER_CLOSED")
  ns.charDB.skippedSpells = nil
end

io.write("routing\n")
ns.db.npcs[999] = nil -- route to the seeded Stormwind trainer only
if ERA then
  -- Seed NPCs are Forever positions: Classic Era leaves them out, and you
  -- learn the trainer by talking to it instead.
  check(ns.Trainers.Results()[1] == nil, "Classic Era: no seeded trainer (Forever positions)")
  ns.db.npcs[461] = CopyTable(ns.data.seedNPCs[461])
end
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
if ERA then
  check(not plan:find("boat,walk$") or not ns.Router.Summary(far.route):find("Stormwind Harbor"),
    "Classic Era: no boat to Stormwind Harbor (" .. plan .. ")")
else
  check(plan == "walk,boat,walk", "Darkshore: Forever's direct boat to Stormwind (" .. plan .. ")")
  check(far and ns.Router.Summary(far.route) == "boat to Stormwind Harbor", "summary mentions the boat")
end

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
pinCheck(#waypoints == 1 and waypoints[1].mapID == 1433, "waypoint placed on the zone map of the flight master")
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
check(ns.Marker.TooltipLine("mouseover") == "Wayward: Talk to " .. r.goal.npc, "and their tooltip a line: "
  .. tostring(ns.Marker.TooltipLine("mouseover")))
SlashCmdList.WAYWARD("marker")
check(not ns.Marker.Try("nameplate1") and ns.Marker.TooltipLine("mouseover") == nil, "/ww marker turns both off")
SlashCmdList.WAYWARD("marker")
UnitName = function(unit) if unit == "npc" then return r.goal.npc end return "Someone else" end
check(not ns.Marker.Try("nameplate1"), "someone else doesn't get one")
UnitName = function(unit) if unit == "npc" then return r.goal.npc end return "Me" end
-- The target button by the directions box: /target <them>.
local hud = ns.HUD.Frame()
rawset(hud, "GetRight", function() return 600 end)
rawset(hud, "GetTop", function() return 700 end)
ns.TargetButton.Sync()
check(ns.TargetButton.Macro() == "/target " .. r.goal.npc, "the target button targets them: " .. tostring(ns.TargetButton.Macro()))
check(ns.TargetButton.Frame():GetFrameStrata() == (ns.HUD.Frame():GetFrameStrata() or "MEDIUM"),
  "on the directions box's layer, so the Wayward window covers it: " .. tostring(ns.TargetButton.Frame():GetFrameStrata()))
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
check(ns.Nav.active == nil, "talking to them ends it")
pinCheck(waypoints[#waypoints] == "cleared", "and clears our waypoint")
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
check(ns.Panel.IsShown(), "first /ww opens the panel")

do
  io.write("profile\n")
  local P, strip = ns.Profile, ns.Profile.Strip()
  local saved = { ns.Hearth.Node, ns.Data.Has, ns.charDB.classSpells, ns.charDB.knownTaxi, ns.Harvest.FlightsKnownOn }
  ns.charDB.profileComplete = nil
  ns.Hearth.Node = function() return nil end
  ns.Data.Has = function() return false end
  ns.charDB.classSpells = { updated = 0, level = 1, services = {} }
  ns.charDB.knownTaxi = { [5] = true }
  ns.Harvest.FlightsKnownOn = function() return true end
  P.Update()
  local state = P.State()
  check(state.percent == 60 and state.next.key == "hearth" and strip:IsShown() and strip.percent:GetText() == "60%"
    and not strip.tick:IsShown() and not strip.nextText,
    "the profile shows how far along you are, with no next step beside it: " .. tostring(strip.percent:GetText()))
  ns.Harvest.FlightsKnownOn = function(continent) return continent == 1415 end
  state = P.State()
  check(state.percent == 40 and state.steps[1].done and not state.steps[2].done
    and state.steps[2].label == "Flight paths: Kalimdor",
    "flight paths count once per continent: " .. tostring(state.percent))
  ns.Harvest.FlightsKnownOn = function() return true end
  ns.Hearth.Node = function() return {} end
  ns.Data.Has = function() return true end
  P.Update()
  check(strip:IsShown() and strip.tick:IsShown() and strip.percent:GetText() == "100%" and ns.charDB.profileComplete,
    "at 100% it gets a tick, for the rest of the session")
  P.session = "a later session"
  P.Update()
  check(not strip:IsShown(), "and is gone from the next session on")
  ns.Hearth.Node = function() return nil end
  P.Update()
  check(not strip:IsShown(), "even if something is missing again")
  ns.Hearth.Node, ns.Data.Has, ns.charDB.classSpells, ns.charDB.knownTaxi, ns.Harvest.FlightsKnownOn = saved[1],
    saved[2], saved[3], saved[4], saved[5]
  ns.charDB.profileComplete = nil
end

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
C_QuestLog = {
  GetAllCompletedQuestIDs = function() return { 2 } end,
  GetNumQuestLogEntries = function() return 1 end,
  GetInfo = function() return { questID = 10, isHeader = false } end,
}

-- Classic Era: the tests below keep setting (and saving and restoring)
-- Forever's C_QuestLog functions; those go into a hidden table that the
-- client's old global functions read from. To the addon C_QuestLog answers
-- nil for them, as on Era; to the tests here, the hidden ones.
if ERA then
  local MODERN = { GetAllCompletedQuestIDs = true, GetNumQuestLogEntries = true, GetInfo = true, IsComplete = true,
    GetLogIndexForQuestID = true, GetTitleForQuestID = true }
  local hidden = {}
  for k in pairs(MODERN) do hidden[k] = rawget(C_QuestLog, k); C_QuestLog[k] = nil end
  setmetatable(C_QuestLog, {
    __index = function(_, k)
      if MODERN[k] and debug.getinfo(2, "S").source == TEST_SOURCE then return hidden[k] end
      return nil
    end,
    __newindex = function(t, k, v) if MODERN[k] then hidden[k] = v else rawset(t, k, v) end end,
  })
  GetNumQuestLogEntries = function() return hidden.GetNumQuestLogEntries and hidden.GetNumQuestLogEntries() or 0 end
  GetQuestLogTitle = function(i)
    local info = hidden.GetInfo and hidden.GetInfo(i)
    if not info then return nil end
    return info.title or ("Quest " .. tostring(info.questID)), info.level or 0, nil, info.isHeader, false,
      nil, 0, info.questID or 0, nil, nil, nil, nil, nil, nil, nil, info.isHidden
  end
  IsQuestComplete = function(id) return hidden.IsComplete and hidden.IsComplete(id) or false end
  GetQuestLogIndexByID = function(id)
    for i = 1, GetNumQuestLogEntries() do
      local info = hidden.GetInfo(i)
      if info and info.questID == id then return i end
    end
    return 0
  end
  GetQuestsCompleted = function()
    local out = {}
    for _, id in ipairs(hidden.GetAllCompletedQuestIDs and hidden.GetAllCompletedQuestIDs() or {}) do out[id] = true end
    return out
  end
end

-- The fixtures above are kept in QuestieDB's shape (rows with spawns per
-- AreaID in map percent, race and class bit masks). fixtureSource turns them
-- into a Wayward data source (Wayward/Sources.lua), reading the globals at
-- call time so tests can change rows; refreshData() registers it again, which
-- resets Wayward's caches, and dropData() takes it away.
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
    QUEST_GIVER = "questGiver", INNKEEPER = "innkeeper", BANKER = "banker", AUCTIONEER = "auctioneer",
    STABLEMASTER = "stableMaster" }
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
  function source.ObjectIDs(name)
    local out = {}
    for _, id in ipairs(ObjectDB and ObjectDB.GetAllIds() or {}) do
      if not name or ObjectDB.Get(id, "name") == name then out[#out + 1] = id end
    end
    return out
  end
  function source.Item(id)
    if not (ItemDB and ItemDB.GetAll(id, { "name" })) then return nil end
    local item = { id = id }
    for _, k in ipairs({ "name", "itemLevel", "requiredLevel", "npcDrops", "objectDrops", "itemDrops",
      "questRewards", "vendors", "class", "subClass" }) do
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
local function refreshData() Wayward.RegisterSource(fixtures) end
local function dropData() Wayward.UnregisterSource("fixtures") end
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
SlashCmdList.WAYWARD("dock")
check(ns.charDB.pendingDock and ns.charDB.pendingDock.a.label == "Auberdine", "first /ww dock starts recording at Auberdine")
SlashCmdList.WAYWARD("dock")
check(#ns.db.transports == 0, "a second /ww dock without moving is refused")
subZone = "Test Pier"
player.mapID, player.x, player.y = 1453, 0.8, 0.5
SlashCmdList.WAYWARD("dock")
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
SlashCmdList.WAYWARD("dock list")
check(true, "/ww dock list opens the copy box")

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
GetInventoryItemCount = function() return 100 end
-- 100 Sharp Arrows (in the ammo slot) and 50 Rough Arrows: every arrow counts.
C_Container = {
  GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
  GetContainerItemInfo = function(_, slot)
    if slot == 1 then return { itemID = 2515, stackCount = 100 } end
    if slot == 2 then return { itemID = 2512, stackCount = 50 } end
  end,
}
shops = ns.Vendors.Results()
local bowyer = find(shops, "Lakeshire Bowyer")
check(bowyer and bowyer.title:find("Ammo") and bowyer.details[1].text:find("Sharp Arrow"),
  "hunter with a bow: arrow vendor listed (" .. titles(shops) .. ")")
check(ns.Vendors.SummaryText():find("Ammo %(150 left%)"), "summary shows ammo left, of every kind: "
  .. ns.Vendors.SummaryText())
C_Container = nil

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
check(not ns.Quests.Available() and ns.Dungeons.SummaryText():find("Install QuestieDB"),
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
check(sfk and sfk.details[1].text:find("Wayward estimate"), "no client entry: data level, marked as an estimate")
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
foreverCheck(stockade and math.abs(stockade.goal.x - 0.6) < 1e-6, "our Era Stormwind point converted with EraToForever",
  stockade and math.abs(stockade.goal.x - 0.6) > 1e-6, "our Era Stormwind point used as is")
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
check(entrance.action and entrance.action.kind == "enter" and entrance.action.dungeon == "Test Dungeon"
  and journey.def.finish == nil and journey.root.stops[4] == entrance,
  "the finish \"Enter X\" is an ordinary stop of the enter kind, last of the stops planned with it")
player.mapID, player.x, player.y = 1453, 0.5, 0.5
ns.HUD.Update()
check(ns.Nav.active and ns.Nav.Waiting() and ns.Nav.Interaction() == "enter"
  and ns.HUD.Lines()[4]:find("go in", 1, true), "at the entrance the journey waits for you to go in: " .. ns.HUD.Lines()[4])
local savedInstance = { IsInInstance, GetInstanceInfo }
IsInInstance = function() return true, "party" end
GetInstanceInfo = function() return "Test Dungeon", "party", 1, "Normal", 5, 0, false, 1 end
fire("PLAYER_ENTERING_WORLD")
IsInInstance, GetInstanceInfo = savedInstance[1], savedInstance[2]
check(ns.Nav.active == nil and entrance.done, "loading into the dungeon ends the journey")

io.write("hearthstone\n")
do
  -- Bound in Stormwind, standing in Redridge: a quick pickup, then into Stormwind.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local savedCount = GetItemCount
  local bags, cooldownStart = { [6948] = 1 }, 0
  GetItemCount = function(id) return bags[id] or 0 end
  GetBindLocation = function() return "Stormwind City" end
  GetItemCooldown = function() return cooldownStart, cooldownStart > 0 and 3600 or 0 end
  GetTime = function() return 1000 end
  ns.charDB.hearth = { name = "Stormwind City", mapID = 1453, x = 0.52, y = 0.5 }
  local function plan()
    local pickup = stopAt(player.mapID, 0.52, 0.52, "Lakeshire camp", 104)
    return ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Hearth run", stops = { pickup },
      finish = stopAt(1453, 0.5, 0.5, "Test Dungeon") })
  end
  local function modes(j)
    local out = {}
    for _, st in ipairs(j.steps) do out[#out + 1] = st.mode end
    return table.concat(out, ",")
  end
  -- With the flight it saves under HEARTH_MIN_SAVING: not worth an hour's cooldown.
  local flying = plan()
  check(not flying.hearth and not modes(flying):find("hearth", 1, true) and flying.withoutHearth == flying.seconds,
    string.format("a flight gets you there in %.0f s: the Hearthstone isn't spent on what's left (%s)",
      flying.seconds, modes(flying)))
  -- Walking all the way from the Wetlands, it saves minutes.
  local savedTaxi = ns.charDB.knownTaxi
  ns.charDB.knownTaxi = {}
  player.mapID = 1437
  local with = plan()
  bags[6948] = nil
  local without = plan()
  bags[6948] = 1
  check(with.hearth and not with.hearth.cooldown and with.hearth.stop.node.label == "Test Dungeon"
    and with.hearth.label == "Stormwind City" and modes(with):find("hearth", 1, true)
    and with.hearth.saves >= ns.Journey.HEARTH_MIN_SAVING,
    "a Hearthstone home stands in for the long walk into Stormwind (" .. modes(with) .. ")")
  check(not without.hearth and not modes(without):find("hearth", 1, true) and with.seconds < without.seconds,
    string.format("without one in your bags it's the long way (%.0f s vs %.0f s)", with.seconds, without.seconds))
  check(math.abs(with.withoutHearth - without.seconds) < 1,
    string.format("the plan knows what it takes if you keep the Hearthstone (%.0f s vs %.0f s)", with.withoutHearth,
      without.seconds))
  local index
  for i, st in ipairs(with.steps) do if st.mode == "hearth" then index = i end end
  check(ns.Router.Describe(with, index) == "Hearth to Stormwind City", "the step says to hearth")
  cooldownStart = 900 -- used 100 s ago: ready in ~58 min
  local cooling = plan()
  check(cooling.hearth and cooling.hearth.cooldown and cooling.hearth.readyIn > 3000
    and not modes(cooling):find("hearth", 1, true), "on cooldown: not used, but the plan says what it would save")
  cooldownStart = 0
  ns.charDB.hearth.name = "Goldshire"
  check(not plan().hearth, "bound somewhere else since: we don't know where it takes you")
  ns.charDB.knownTaxi, player.mapID = savedTaxi, 1433
  GetItemCount, GetBindLocation, GetItemCooldown, GetTime = savedCount, nil, nil, nil
  ns.charDB.hearth = nil
end

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
ns.RegisterCommand("echo", "/ww echo - test", function(rest) commandArg = rest end)
SlashCmdList.WAYWARD("echo |cff9d9d9d|Hitem:2589::::|h[Linen Cloth]|h|r")
check(commandArg == "|cff9d9d9d|Hitem:2589::::|h[Linen Cloth]|h|r", "registered /ww commands get the raw text")
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
  SlashCmdList.WAYWARD("quest Redridge Goulash")
  check(ns.Panel.IsShown() and seen == "Redridge Goulash", "/ww quest opens the Quests page with that search")
  ns.QuestsPage.Results = realResults

  dropData()
  local none, err = ns.QuestsPage.Results("chain")
  check(#none == 0 and err and err:find("Install QuestieDB"), "without QuestieDB: the page says it is needed")
  check(ns.QuestsPage.SummaryText(""):find("Install QuestieDB"), "without QuestieDB: summary too")
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
  -- /ww item and the Show / Look up actions open Find's Items view, which
  -- shows Items.Results; the wrapper sees what it was asked.
  local seen
  local realResults = ns.Items.Results
  ns.Items.Results = function(q) seen = q; return realResults(q) end
  local function rows(q) return (realResults(q)) end
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
  SlashCmdList.WAYWARD("item " .. link)
  check(ns.Panel.IsShown() and seen == link and ns.Panel.SelectedTab() == "find",
    "/ww item <link> opens Find's Items view with the link")
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
  check(ns.Items.SummaryText("item:1205"):find("Install QuestieDB"), "summary says QuestieDB is needed for the rest")
  check(#rows("item:9001") == 0 and ns.Items.EmptyText("item:9001"):find("Install QuestieDB"),
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
  ns.Items.Results = realResults
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
  -- Needs are observations now (ForYou.Observations), not cards.
  local function observations()
    ns.ForYou.Invalidate()
    ns.ForYou.Results()
    return ns.ForYou.Observations()
  end
  local function obsFind(list, kind, text)
    for i, o in ipairs(list) do
      if o.kind == kind and (not text or o.text:find(text, 1, true)) then return o, i end
    end
  end
  local function obsTexts(list)
    local out = {}
    for _, o in ipairs(list) do out[#out + 1] = o.kind .. ": " .. o.text end
    return table.concat(out, " | ")
  end

  -- (Find is the first side tab, order 5; For you is the first card page.)
  local lowest
  for _, page in ipairs(ns.pages) do
    if page.id ~= "test" and page.layout == "cards" and (not lowest or page.order < lowest.order) then lowest = page end
  end
  check(lowest and lowest.id == "foryou" and ns.ForYou.runs >= 1,
    "For you has the lowest order of the card pages and was computed when /ww first opened")

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
  local obs = ns.ForYou.Observations()
  local train = obsFind(obs, "train")
  check(train and train.text:find("1 new spell to train for ", 1, true) and train.text:find("in Stormwind", 1, true)
    and train.action and train.action.kind == "detour" and train.action.stop and train.action.stop.node,
    "a trainable, affordable spell is an observation with a detour to the trainer (" .. obsTexts(obs) .. ")")
  check(not find(list, "Train ") and not find(list, "Visit your trainer"), "and not a card (" .. titles(list) .. ")")
  local function count(category)
    local n = 0
    for _, r in ipairs(list) do if r.category == category then n = n + 1 end end
    return n
  end
  local redridge = find(list, "Quest in Redridge Mountains")
  local goulash = find(list, "Do ")
  local deadmines = find(list, "Run The Deadmines")
  check(redridge and redridge.category == "Questing zone"
    and goulash and goulash.category == "Best quest" and deadmines and deadmines.category == "Dungeon"
    and count("Due now") == 0 and count("Worth a visit") == 0,
    "one card per kind: a questing zone, the dungeon, the best quest; nothing due as a card (" .. titles(list) .. ")")
  local roles, honest = {}, #list > 0
  local ROLE_FOR = { progression = "continue", novelty = "explore" }
  for _, r in ipairs(list) do
    roles[#roles + 1] = r.role or "?"
    if r.role ~= (ROLE_FOR[r.lead] or "alternative") then honest = false end
  end
  check(honest, "every card's tag is what it is about (progression continues, novelty explores): " .. table.concat(roles, ","))
  local scored = #list > 0
  for _, r in ipairs(list) do
    local p = r.relevance_parts
    if not (r.why and r.relevance and r.relevance >= 0 and r.relevance <= 1 and p and p.suitability and p.proximity
      and p.progression and p.novelty and p.intent and r.details[1].text == r.why .. ".") then scored = false end
  end
  check(scored, "every card has a relevance 0..1, its five parts and a why that heads its details")
  check(not find(list, "Quest in Stormwind City"), "a zone with fewer than 4 quests for you gets no card")
  check(count("Dungeon") == 1, "one dungeon card")
  local also
  for _, d in ipairs(deadmines and deadmines.details or {}) do
    if d.text:find("^Also for your level") then also = d.text end
  end
  foreverCheck(not (also and also:find("Hall of Testing", 1, true)) and not find(list, "Run Hall of Testing"),
    "with QuestieDB, a dungeon without quests for you isn't suggested (its mobs give little XP)",
    (also and also:find("Hall of Testing", 1, true)) or find(list, "Run Hall of Testing"),
    "a dungeon without quests for you is still suggested (its mobs give full XP)")
  -- The zone: what you can take now, what chains unlock, where to start.
  check(redridge and redridge.place == "Levels 17-19  ·  start at Lakeshire" and redridge.route
    and redridge.details[2].text:find("4 quests you can take now, 1 more as their chains unlock", 1, true),
    "a questing zone: levels, quests now and unlocked by chains, the hub to start at: " .. tostring(redridge and redridge.details[2].text))
  check(redridge and redridge.details[3].text == "Start at Lakeshire: the journey picks up its 4 quests."
    and redridge.goal.label:find("^Lakeshire"),
    "the first hub (one hub per place): " .. tostring(redridge and redridge.details[3].text))
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
  check(statText(redridge):find("^Quests=4 %+ 1,XP=~7,300,Journey="),
    "a zone's card numbers: quests now + later, XP, travel: " .. statText(redridge))
  check(train and train.highlights[1] == "1 new spell" and train.highlights[2] == ns.FormatMoney(1000),
    "the training observation highlights the spells and the cost: " .. table.concat(train and train.highlights or {}, ","))
  check(train and train.details[1] and not train.details[1].more and train.details[1].text:find("  -  ", 1, true),
    "the spells you can learn come first in its details: " .. tostring(train and train.details[1] and train.details[1].text))
  check(ns.ForYou.SummaryText():find("^A few good options") and not ns.ForYou.SummaryText():find("^Level")
    and not ns.ForYou.SummaryText():find("good to know")
    and not ns.ForYou.SummaryText():find("quests per hour") and not ns.ForYou.SummaryText():find("XP per minute"),
    "summary: " .. ns.ForYou.SummaryText())

  -- Spells left at the trainer: no card for them, the Class page still lists them.
  local savedSpells = ns.charDB.classSpells
  ns.charDB.classSpells = { updated = 0, level = 20, services = {
    { name = "Life Tap", type = "available", levelReq = 20, cost = 1000 } } }
  ns.Trainers.RecordSkipped(ns.charDB.classSpells.services)
  check(not obsFind(observations(), "train"), "closing the trainer without Life Tap: no training observation for it")
  check(ns.Trainers.SpellSummary().trainable == 1, "the Class page still counts it")
  table.insert(ns.charDB.classSpells.services, { name = "Drain Soul", type = "available", levelReq = 20, cost = 500 })
  train = obsFind(observations(), "train")
  local notCounted = train and train.details[#train.details].text
  check(train and train.text:find("^1 new spell to train") and train.details[1].text:find("^Drain Soul")
    and notCounted == "Not counted: 1 spell you left at the trainer.",
    "a spell you haven't left there gets an observation of its own: " .. tostring(train and train.text) .. " / "
      .. tostring(notCounted))
  ns.charDB.skippedSpells = nil
  check(obsFind(observations(), "train", "2 new spells"), "without it, both count again")

  -- A spell is known when any of the client's checks says so (Classic Era's
  -- spellbook can hide a lower rank IsPlayerSpell knows).
  C_SpellBook = { IsSpellKnown = function() return false end }
  IsPlayerSpell = function(id) return id == 1130 end
  check(ns.KnowsSpell(1130) == true and ns.KnowsSpell(1131) == false, "known when either check says so")
  C_SpellBook, IsPlayerSpell = nil, nil
  check(ns.KnowsSpell(1130) == nil, "nil when the client can't say")

  -- A hunter's level 6 visit, not read again after buying Hunter's Mark, that
  -- doesn't list Concussive Shot (Classic Era leaves out a spell whose name
  -- hasn't loaded). At level 8 the spellbook and the spell data win: a card
  -- for the level 8 spells (an observation).
  Wayward.RegisterSource({ id = "hunter", label = "Hunter", priority = 2,
    ClassSpells = function(class)
      if class == "WARLOCK" then return { { spellID = 1130, level = 6, cost = 100 },
        { spellID = 5116, level = 8, cost = 200 }, { spellID = 14260, level = 8, cost = 200 } } end
    end })
  local NAMES = { [1130] = { "Hunter's Mark", "Rank 1" }, [5116] = { "Concussive Shot", "" },
    [14260] = { "Raptor Strike", "Rank 2" } }
  local realInfo, realSubtext, realKnown, realLevel = GetSpellInfo, GetSpellSubtext, IsPlayerSpell, UnitLevel
  GetSpellInfo = function(id) return NAMES[id] and NAMES[id][1] end
  GetSpellSubtext = function(id) return NAMES[id] and NAMES[id][2] end
  IsPlayerSpell = function(id) return id == 1130 end
  UnitLevel = function() return 6 end
  fire("SPELLS_CHANGED")
  ns.charDB.classSpells = { updated = 0, level = 6, services = {
    { name = "Hunter's Mark", rank = "Rank 1", type = "available", levelReq = 6, cost = 100 },
    { name = "Raptor Strike", type = "unavailable", levelReq = 8, cost = 200 } } }
  ns.Trainers.RecordSkipped(ns.charDB.classSpells.services)
  local hunter = ns.Trainers.SpellSummary()
  check(hunter.trainable == 0 and hunter.nextLevel == 8 and hunter.nextCount == 2,
    "a spell you know isn't trainable, whatever the visit says; the level 8 spells wait: "
      .. table.concat(hunter.names, ", "))
  UnitLevel = function() return 8 end
  hunter = ns.Trainers.SpellSummary(true)
  local learn = obsFind(observations(), "train")
  check(hunter.trainable == 2 and hunter.skipped == 0 and table.concat(hunter.names, ", ")
    == "Raptor Strike, Concussive Shot", "level 8: the spells since the visit, not Hunter's Mark: "
      .. table.concat(hunter.names, ", "))
  check(learn and learn.text:find("^2 new spells to train") and table.concat(learn.spells or {}, ", ")
    == "Raptor Strike, Concussive Shot", "an observation for them: " .. tostring(learn and learn.text))
  -- The same spell at another level on this client: matched by name, not added twice.
  table.insert(ns.charDB.classSpells.services, { name = "Concussive Shot", type = "unavailable", levelReq = 7 })
  check(ns.Trainers.SpellSummary().trainable == 2, "a spell without ranks the visit lists isn't added again")
  Wayward.UnregisterSource("hunter")
  GetSpellInfo, GetSpellSubtext, IsPlayerSpell, UnitLevel = realInfo, realSubtext, realKnown, realLevel
  ns.charDB.skippedSpells = nil
  fire("SPELLS_CHANGED")
  ns.charDB.classSpells = savedSpells

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
    if st.action and st.action.questID then picked[#picked + 1] = st.action.kind .. st.action.questID end
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
  foreverCheck(not find(list, "Run The Deadmines") and ns.ForYou.SummaryText():find("The Deadmines at level 22 (", 1, true),
    "a dungeon most of whose quests open later waits, and the page says when: " .. ns.ForYou.SummaryText())
  for _, id in ipairs({ 30, 31, 32 }) do QUESTS[id] = nil end
  refreshData()
  list = rows()

  -- Gear at 20%: the repair is more urgent than training.
  durability = { 10, 50 }
  obs = observations()
  check(obs[1] and obs[1].kind == "repair" and obs[1].text:find("^Gear at 20%%: repair at ") and obs[2] and obs[2].kind == "train"
    and obs[1].highlights[1] == "20%" and obs[1].action.kind == "detour",
    "low durability: the repair observation first, then training (" .. obsTexts(obs) .. ")")
  check(not find(ns.ForYou.Results(), "Repair"), "and no repair card")
  durability = { 50, 50 }

  -- Gear at 70%: worth knowing when a repairer is close; less urgent than what's due.
  durability = { 35, 50 }
  obs = observations()
  local soon, si = obsFind(obs, "repair")
  local _, ti = obsFind(obs, "train")
  check(soon and soon.text:find("^Gear at 70%%: ") and soon.urgency < 0.5 and ti and si > ti
    and soon.action and soon.action.kind == "detour",
    "gear at 70% with a repairer close by: an observation after what's due (" .. obsTexts(obs) .. ")")
  check(not ns.ForYou.SummaryText():find("good to know", 1, true), "the tiles speak for themselves: " .. ns.ForYou.SummaryText())
  durability = { 50, 50 }

  -- No spell list yet, at an even level: a visit to the trainer is worth it.
  local savedSpells = ns.charDB.classSpells
  ns.charDB.classSpells = nil
  obs = observations()
  local visit = obsFind(obs, "train")
  check(visit and visit.text:find("^New spells are likely at level 20") and visit.action and visit.action.kind == "go"
    and visit.action.route,
    "never visited a trainer, level 20: new spells likely, with directions (" .. obsTexts(obs) .. ")")
  UnitLevel = function() return 21 end
  check(not obsFind(observations(), "train"), "odd levels don't")
  UnitLevel = function() return 20 end
  -- Last visit two levels ago, nothing left to learn then: likely again.
  ns.charDB.classSpells = { updated = 0, level = 18, services = { { name = "Old", type = "used", levelReq = 16 } } }
  check(obsFind(observations(), "train", "likely"), "two levels since the last visit: worth another")
  ns.charDB.classSpells = { updated = 0, level = 20, services = { { name = "Old", type = "used", levelReq = 16 } } }
  check(not obsFind(observations(), "train"), "just visited: no")
  ns.charDB.classSpells = savedSpells

  -- Training you can't afford yet: an observation that shows the Class page.
  local savedMoney = GetMoney
  GetMoney = function() return 0 end
  local short = obsFind(observations(), "train")
  check(short and short.text:find("once you have 10s", 1, true) and short.action and short.action.kind == "show"
    and short.action.page == "trainers", "spells you can't afford yet: an observation that shows the Class page: "
    .. tostring(short and short.text))
  GetMoney = savedMoney

  -- A big XP quest in Stormwind becomes the best quest; training stays an observation.
  XP[6] = { 20, 12000 }
  list = rows()
  check(find(list, "Do Stormwind errand") and not find(list, "Train"),
    "the quest worth the most XP is the best quest; training isn't a card (" .. titles(list) .. ")")
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
  check(ns.ForYou.SummaryText():find("Install QuestieDB"), "without QuestieDB the summary says so")
  check(obsFind(ns.ForYou.Observations(), "train") and find(list, "Run The Deadmines") and not find(list, "Pick up"),
    "without QuestieDB: training to know about, dungeons as cards (" .. titles(list) .. ")")
  refreshData()
  LibQuestieDB.Support.Get = function(name)
    if name == "QuestXP" then return { db = XP } end
    return zoneSupport(name)
  end
  refreshData()

  -- An undiscovered flight path where you stand.
  ns.charDB.knownTaxi[5] = nil
  obs = observations()
  local flight = obsFind(obs, "flight")
  check(flight and flight.text:find("^The Lakeshire flight path is ") and flight.highlights[1] == "Lakeshire"
    and flight.action.kind == "detour" and flight.action.stop.text:find("flight master", 1, true),
    "undiscovered flight path close by: an observation with a detour (" .. obsTexts(obs) .. ")")
  check(not find(ns.ForYou.Results(), "Learn the"), "and no card")
  ns.charDB.knownTaxi[5] = true

  -- Low on food (2 Melon Juice in the bags).
  C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
    GetContainerItemInfo = function(bag, slot) if slot == 1 then return { itemID = 1205, stackCount = 2 } end end,
  }
  obs = observations()
  local food = obsFind(obs, "food")
  check(food and food.text:find("^2 food & drink left: buy food & drink at ") and food.highlights[1] == "2 food",
    "low on food: an observation to buy some (" .. obsTexts(obs) .. ")")
  C_Container = nil

  -- A hunter with a bow and no ammo.
  UnitClass = function() return "Hunter", "HUNTER", 3 end
  GetInventoryItemID = function(_, slot) return slot == 18 and 100 or nil end
  -- 150 Rough and 800 Sharp Arrows: plenty, whichever is in the ammo slot.
  C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
    GetContainerItemInfo = function(_, slot)
      if slot == 1 then return { itemID = 2512, stackCount = 150 } end
      if slot == 2 then return { itemID = 2515, stackCount = 800 } end
    end,
  }
  check(not obsFind(observations(), "ammo"), "plenty of ammo across two kinds: no ammo observation")
  C_Container = nil
  obs = observations()
  local ammo = obs[1]
  check(ammo and ammo.kind == "ammo" and ammo.text:find("^No ammo left: buy ammo at Lakeshire Cook")
    and ammo.urgency > (obsFind(obs, "train") or { urgency = 0 }).urgency,
    "out of ammo: the nearest arrow seller, the most urgent thing (" .. obsTexts(obs) .. ")")
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
  SlashCmdList.WAYWARD("next")
  check(ns.Panel.IsShown() and ns.ForYou.runs > runs, "/ww next opens the panel on For you")

  -- Low levels: your starting zone first, not another starting zone.
  local realZoneQuests, realLevel = ns.Quests.ZoneQuests, UnitLevel
  local counts = { [1429] = 4, [1426] = 7, [1433] = 5 }
  ns.Quests.ZoneQuests = function()
    local zones, id = {}, 90000
    for mapID, n in pairs(counts) do
      local z = { mapID = mapID, quests = {} }
      for i = 1, n do
        id = id + 1
        z.quests[i] = { id = id, name = "Low quest " .. id, level = 5, node = ns.Geo.Node(mapID, 0.5, 0.5),
          giver = "Giver " .. mapID, chain = false }
      end
      zones[mapID] = z
    end
    return zones
  end
  -- (The cards are in role order now, so the zones offered are compared as a set.)
  local function zoneTitles()
    local out = {}
    for _, r in ipairs(rows()) do
      if r.category == "Questing zone" then out[#out + 1] = r.title:gsub("^Quest in ", "") end
    end
    table.sort(out)
    return table.concat(out, ",")
  end
  UnitLevel = function() return 5 end
  player.mapID, player.x, player.y = 1429, 0.5, 0.5
  check(zoneTitles() == "Elwynn Forest,Redridge Mountains",
    "level 5 in Elwynn: Elwynn, no other starting zone: " .. zoneTitles())
  player.mapID = 1453
  check(zoneTitles() == "Elwynn Forest,Redridge Mountains",
    "level 5 in Stormwind: your race's starting zone: " .. zoneTitles())
  counts[1429] = 2
  player.mapID = 1429
  check(zoneTitles() == "Dun Morogh,Redridge Mountains",
    "with too few quests left at home, another starting zone is fine: " .. zoneTitles())
  counts[1438] = 9
  check(zoneTitles() == "Dun Morogh,Redridge Mountains",
    "but not one across the sea, however many quests it has: " .. zoneTitles())
  counts[1438] = nil
  counts[1429] = 4
  UnitLevel = function() return 10 end
  check(zoneTitles() == "Dun Morogh,Elwynn Forest,Redridge Mountains",
    "from level 10, every zone with quests for you: " .. zoneTitles())
  ns.Quests.ZoneQuests, UnitLevel = realZoneQuests, realLevel
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  LibQuestieDB.Support.Get = zoneSupport

  -- A card with a quest your trip already has isn't shown; it's back once the trip ends.
  local cards, picked = rows(), nil
  for _, r in ipairs(cards) do
    for _, st in ipairs(r.journey and r.journey.stops or {}) do
      if not picked and st.action and st.action.questID then picked = { card = r, id = st.action.questID } end
    end
  end
  check(picked ~= nil, "a card with a quest on its trip: " .. titles(cards))
  if picked then
    local function showing()
      for _, r in ipairs(ns.ForYou.Results()) do if r.id == picked.card.id then return true end end
      return false
    end
    local here = ns.Geo.PlayerNode()
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Just that quest", stops = ns.Journey.QuestStops(picked.id, here) }), true)
    check(ns.Nav.TripHasQuest(picked.id) and not showing(),
      "with that quest on your trip, " .. picked.card.title .. " isn't shown: " .. titles(ns.ForYou.Results()))
    ns.Nav.Stop()
    check(showing(), "and it's back once the trip ends")
  end

  -- Nor a dungeon your trip goes to, after its pickups are done (only the entrance is left).
  local run = find(rows(), "Run The Deadmines")
  check(run and run.goal, "a dungeon card: " .. titles(ns.ForYou.Results()))
  if run then
    local function showing()
      return find(ns.ForYou.Results(), "Run The Deadmines") ~= nil
    end
    local here = ns.Geo.PlayerNode()
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Deadmines quests", stops = {},
      finish = { node = run.goal, text = "Enter The Deadmines" } }), true)
    check(ns.Nav.active and not showing(),
      "with its entrance on your trip, the dungeon isn't shown: " .. titles(ns.ForYou.Results()))
    ns.Nav.Stop()
    ns.Nav.Start("The Deadmines", run.goal, run.route)
    check(ns.Nav.active and not showing(), "nor with directions to it")
    ns.Nav.Stop()
    check(showing(), "and it's back once the trip ends")
  end
end

---------------------------------------------------------------- for you (end)
---------------------------------------------------------------- warm-up (begin)
do
  io.write("warm-up\n")
  -- Every clock read 5 ms on: a slice is a couple of reads, as if the data were huge.
  local realClock, t = debugprofilestop, 0
  debugprofilestop = function() t = t + 5 return t end
  ns.Fire("SOURCES_CHANGED")
  ns.ForYou.Invalidate()
  local list, err = ns.ForYou.Results()
  check(#list == 0 and err == "Getting the quest data ready..." and ns.Warming(),
    "after the sources change, For you waits while the quest data is indexed: " .. tostring(err))
  check(ns.ForYou.SummaryText() == "Getting the quest data ready...", "and says so")
  local frame, ticks = ns.WarmFrame(), 0
  while ns.Warming() and ticks < 10000 do
    frame.scripts.OnUpdate(frame, 0.016)
    ticks = ticks + 1
  end
  check(not ns.Warming() and ticks > 3, "the index is built a slice per frame (" .. ticks .. " frames)")
  debugprofilestop = realClock
  ns.ForYou.Invalidate()
  list = ns.ForYou.Results()
  check(#list > 0 and ns.Quests.Quest(1) ~= nil, "then For you has its cards (" .. #list .. ")")

  -- For you itself is built a slice per frame too, pausing inside its
  -- providers (under Lua 5.1, a pause inside a plain pcall would be an error).
  local titles = {}
  for _, r in ipairs(list) do titles[#titles + 1] = r.title end
  local runs = ns.ForYou.runs
  debugprofilestop = function() t = t + 5 return t end
  ns.Fire("SOURCES_CHANGED") -- cold caches, as after a login
  ns.Quests.Warm()
  frame = ns.WarmFrame()
  while ns.Warming() do frame.scripts.OnUpdate(frame, 0.016) end
  ns.Panel.Toggle()
  local refreshed = 0
  local realRefresh = ns.Panel.Refresh
  ns.Panel.Refresh = function(...) refreshed = refreshed + 1 return realRefresh(...) end
  ns.ForYou.Invalidate()
  local shown = ns.ForYou.Results()
  check(ns.Warming() and ns.ForYou.runs == runs and #shown == #list,
    "while it's built, For you shows the last cards (" .. #shown .. ")")
  ticks = 0
  while ns.Warming() and ticks < 100000 do
    frame.scripts.OnUpdate(frame, 0.016)
    ticks = ticks + 1
  end
  debugprofilestop = realClock
  local again = {}
  for _, r in ipairs(ns.ForYou.Results()) do again[#again + 1] = r.title end
  check(ticks > 10 and ns.ForYou.runs > runs and table.concat(again, "|") == table.concat(titles, "|"),
    string.format("built over %d frames, the same cards: %s", ticks, table.concat(again, " | ")))
  check(refreshed > 0, "and the panel refreshes itself when it's done")
  ns.Panel.Refresh = realRefresh
  ns.Panel.Toggle()
end
---------------------------------------------------------------- warm-up (end)
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
  check(card and card.category == "Profession" and card.stats[1][2] == "73/75" and card.role and card.why,
    "a For you card to train Journeyman Tailoring (a suggestion below your cap)")
  local capObs
  for _, o in ipairs(ns.ForYou.Observations()) do if o.kind == "profession" then capObs = o end end
  check(capObs == nil, "below your cap it isn't an observation")
  skills[2][3] = 75
  ns.ForYou.Invalidate()
  list = ns.ForYou.Results()
  card = nil
  for _, r in ipairs(list) do if r.title:find("^Train Journeyman Tailoring") then card = r end end
  for _, o in ipairs(ns.ForYou.Observations()) do if o.kind == "profession" then capObs = o end end
  check(card and card.category == "Profession" and card.relevance_parts.progression == 1 and capObs
    and capObs.text:find("^Tailoring is at its cap %(75/75%)") and capObs.action.kind == "detour"
    and capObs.action.stop.action.kind == "train",
    "at your cap it's an observation too, with a detour to train the rank: " .. tostring(capObs and capObs.text))
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

  -- Expert Fishing comes from a book, not a trainer: a fishing trainer close
  -- by is passed over for whoever sells the book.
  skills[#skills + 1] = { "Fishing", false, 150, 150 }
  NPCS[990012] = { name = "Lakeshire Angler", subName = "Fishing Trainer", npcFlags = 16, friendlyToFaction = "A",
    spawns = { [44] = { { 51, 51 } } } }
  refreshData()
  ns.ForYou.Invalidate()
  local function fishingCard()
    for _, r in ipairs(ns.ForYou.Results()) do if r.title:find("Fishing", 1, true) then return r end end
  end
  local function fishingRow()
    for _, r in ipairs(P.Results()) do if r.id == "professionFishing" then return r end end
  end
  local row = fishingRow()
  check(fishingCard() == nil and row and not row.goal and row.subtitle:find("no seller known yet", 1, true)
    and row.details[1].text:find("Expert Fishing - The Bass and You", 1, true),
    "Expert Fishing with no seller known: no trainer offered, the book named: " .. tostring(row and row.subtitle))
  NPCS[990013] = { name = "Old Man Heminway", subName = "Fishing Supplies", npcFlags = 4, friendlyToFaction = "AH",
    spawns = { [1519] = { { 40, 60 } } } }
  ITEMS[16083] = { name = "Expert Fishing - The Bass and You", vendors = { 990013 } }
  refreshData()
  ns.ForYou.Invalidate()
  card = fishingCard()
  stop = card and card.journey and card.journey.stops[1]
  check(card and card.title:find("^Learn Expert Fishing") and card.goal.npc == "Old Man Heminway"
    and stop and stop.text == "Buy Expert Fishing - The Bass and You from Old Man Heminway and read it"
    and stop.action.kind == "train" and stop.action.book == 16083,
    "Expert Fishing: a card to buy the book from its seller, not a trainer: " .. tostring(card and card.title))
  row = fishingRow()
  check(row and row.title:find("Old Man Heminway", 1, true) and row.subtitle:find("learn Expert now", 1, true),
    "Professions tab: Expert Fishing at the book's seller: " .. tostring(row and row.title))
  check(P.Book("Fishing", "Journeyman") == nil and P.Book("Cooking", "Expert").id == 16072
    and P.Book("First Aid", "Expert").id == 16084 and P.Book("Tailoring", "Expert") == nil,
    "only Expert in the secondary professions is a book")
  ns.Nav.StartJourney(card.journey)
  player.mapID, player.x, player.y = stop.node.mapID, stop.node.x, stop.node.y
  ns.HUD.Update()
  check(ns.Nav.Waiting() and ns.HUD.Lines()[4]:find("talk to Old Man Heminway, buy the book and read it", 1, true),
    "at the seller: buy the book and read it: " .. tostring(ns.HUD.Lines()[4]))
  skills[#skills][4] = 225
  fire("SKILL_LINES_CHANGED")
  runTimers()
  check(ns.Nav.active == nil, "reading the book (the cap goes to 225) finishes it")

  -- Artisan Fishing comes from Nat Pagle's quest (at 225 skill, not 200),
  -- and Nat Pagle teaches it once you hand it in.
  local savedLevel, savedCompleted = UnitLevel, C_QuestLog.GetAllCompletedQuestIDs
  UnitLevel = function() return 35 end
  skills[#skills][3] = 210
  local r3, s3, need3 = P.NextRank({ rank = 210, cap = 225 }, "Fishing")
  check(r3.name == "Artisan" and s3 == "skill" and need3 == 225 and P.Quest("Fishing", "Artisan") == 6607
    and P.Quest("Fishing", "Expert") == nil, "Artisan Fishing: a quest that needs 225 skill")
  row = fishingRow()
  check(row and row.subtitle:find("Artisan at 225 skill", 1, true) and row.subtitle:find("no quest giver known yet", 1, true),
    "Professions tab: Artisan Fishing at 225, no quest data yet: " .. tostring(row and row.subtitle))
  skills[#skills][3] = 225
  NPCS[990014] = { name = "Nat Pagle", npcFlags = 2, friendlyToFaction = "AH", spawns = { [1519] = { { 45, 55 } } } }
  QUESTS[6607] = { name = "Nat Pagle, Angler Extreme", questLevel = 45, requiredLevel = 35,
    requiredSkill = { 356, 225 }, startedBy = { { 990014 } }, finishedBy = { { 990014 } } }
  refreshData()
  ns.ForYou.Invalidate()
  card = fishingCard()
  local kinds = {}
  for _, s in ipairs(card and card.journey and card.journey.stops or {}) do kinds[#kinds + 1] = s.action and s.action.kind end
  local last = card and card.journey.stops[#card.journey.stops]
  check(card and card.title == "Learn Artisan Fishing: Nat Pagle, Angler Extreme" and kinds[1] == "pickup"
    and kinds[#kinds] == "train" and last.npc == "Nat Pagle" and last.after and last.after[1].action.kind == "turnin",
    "Artisan Fishing: do Nat Pagle's quest, then train it with them: " .. tostring(card and card.title)
      .. " (" .. table.concat(kinds, ", ") .. ")")
  row = fishingRow()
  check(row and row.title:find("Nat Pagle", 1, true) and row.subtitle:find("learn Artisan now", 1, true)
    and row.details[1].text:find("once you hand it in", 1, true),
    "Professions tab: Artisan Fishing from Nat Pagle's quest: " .. tostring(row and row.details and row.details[1].text))
  C_QuestLog.GetAllCompletedQuestIDs = function() return { 2, 6607 } end
  fire("QUEST_TURNED_IN", 6607)
  refreshData()
  ns.ForYou.Invalidate()
  card = fishingCard()
  check(card and card.title:find("^Train Artisan Fishing in") and #card.journey.stops == 1
    and card.journey.stops[1].action.kind == "train",
    "quest handed in: just train Artisan Fishing with Nat Pagle: " .. tostring(card and card.title))

  UnitLevel, C_QuestLog.GetAllCompletedQuestIDs = savedLevel, savedCompleted
  skills[#skills] = nil
  GetNumSkillLines, GetSkillLineInfo = savedNum, savedInfo
  ns.db.npcs[990010], NPCS[990011], NPCS[990012], NPCS[990013], ITEMS[16083] = nil, nil, nil, nil, nil
  NPCS[990014], QUESTS[6607] = nil, nil
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
  check(not ns.JourneyOverview.IsShown(), "a journey with several stops doesn't open the overview by itself")
  ns.JourneyOverview.Show()
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

  -- A reload where the game gives no position (the Deeprun Tram): planned
  -- from the last place it did, and the directions don't move on by themselves.
  local savedNav, realMap = ns.charDB.nav, player.mapID
  check(ns.charDB.lastPlace and ns.charDB.lastPlace.mapID == realMap, "the last place you stood is kept")
  ns.Nav.active, player.mapID = nil, nil
  fire("PLAYER_ENTERING_WORLD", false, true)
  runTimers()
  check(ns.Nav.active and ns.Nav.active.journey.stops[1].action.kind == "turnin",
    "no position after a reload (the tram): the trip resumes from where you last stood")
  check(ns.Geo.PlayerNode().stale and ns.Geo.PlayerNodeExact() == nil and ns.Nav.Tick() == nil,
    "planning uses the last place; arriving waits for a real position")
  player.mapID = realMap
  check(not ns.Geo.PlayerNode().stale, "out of the tram: where you stand again")

  -- A reload before the game has ever placed you: the trip waits for it, it isn't lost.
  savedNav = ns.charDB.nav
  ns.charDB.lastPlace = nil
  ns.Nav.active, player.mapID = nil, nil
  fire("PLAYER_ENTERING_WORLD", false, true)
  runTimers()
  check(ns.Nav.active == nil and ns.charDB.nav == savedNav, "no position yet after a reload: the saved trip is kept")
  player.mapID = realMap
  runTimers()
  check(ns.Nav.active and ns.Nav.active.journey.stops[1].action.kind == "turnin", "a moment later it resumes")
  -- Never placed: kept, and said so once the tries run out.
  savedNav = ns.charDB.nav
  ns.charDB.lastPlace = nil
  ns.Nav.active, player.mapID = nil, nil
  local before = #chat
  fire("PLAYER_ENTERING_WORLD", false, true)
  for _ = 1, 12 do runTimers() end
  check(ns.charDB.nav == savedNav and table.concat(chat, "\n", before + 1):find("/ww resume", 1, true),
    "still nowhere after the tries: kept, and /ww resume is offered")
  player.mapID = realMap
  SlashCmdList.WAYWARD("resume")
  check(ns.Nav.active ~= nil, "/ww resume picks it up")
  -- An error resuming keeps it for the next login, a few times.
  savedNav = ns.charDB.nav
  local realLoad = ns.Journey.Load
  ns.Journey.Load = function() error("old save") end
  ns.Nav.active = nil
  local errorHandler = geterrorhandler
  geterrorhandler = function() return function() end end
  fire("PLAYER_ENTERING_WORLD", false, true)
  runTimers()
  check(ns.charDB.nav == savedNav and savedNav.failed == 1, "an error resuming keeps the trip for next time")
  fire("PLAYER_ENTERING_WORLD", false, true)
  runTimers()
  fire("PLAYER_ENTERING_WORLD", false, true)
  runTimers()
  check(ns.charDB.nav == nil, "after three logins with errors it's dropped")
  -- The game stopping a slow script says nothing about the trip: not counted.
  ns.charDB.nav = savedNav
  savedNav.failed = nil
  ns.Journey.Load = function() error("Interface/AddOns/Wayward/Sources.lua:76: script ran too long") end
  for _ = 1, 4 do
    fire("PLAYER_ENTERING_WORLD", false, true)
    runTimers()
  end
  check(ns.charDB.nav == savedNav and savedNav.failed == nil, "a script that ran too long doesn't count against the trip")
  geterrorhandler, ns.Journey.Load = errorHandler, realLoad

  -- Re-planned in the background, a slice per frame (a slow clock: a pause at
  -- nearly every step).
  local realClock, t = debugprofilestop, 0
  debugprofilestop = function() t = t + 5 return t end
  ns.Nav.active = nil
  fire("PLAYER_ENTERING_WORLD", false, true)
  local frames = 0
  for _ = 1, 50 do
    runTimers()
    local warm = ns.WarmFrame()
    while ns.Warming() and frames < 10000 do
      warm.scripts.OnUpdate(warm, 0.016)
      frames = frames + 1
    end
    if ns.Nav.active then break end
  end
  debugprofilestop = realClock
  check(ns.Nav.active and frames >= 1 and ns.Nav.active.journey.stops[1].action.kind == "turnin",
    "after a reload the trip is re-planned in the background (" .. frames .. " frames) and resumes")
  ns.Nav.active = nil
  ns.charDB.nav = savedNav
  ns.Nav.Resume()
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
  ns.Nav.MoveOn()
  check(ns.Nav.CurrentStep().stop == qs[1] and chat[#chat]:find("nothing else on the journey to do first", 1, true),
    "move on: everything after needs the sample, so nothing can come first")
  bags[500] = 1
  fire("BAG_UPDATE_DELAYED")
  check(ns.JourneyOverview.Rows()[1].state == "done" and ns.Nav.CurrentStep().stop == qs[2], "collected: on to the bowl")
  -- The extra step is confirmed with move on, there: done.
  check(ns.Nav.MoveOnKind() == "later", "away from the moonwell, move on would do it later")
  player.mapID, player.x, player.y = qs[2].node.mapID, qs[2].node.x, qs[2].node.y
  ns.HUD.Update()
  check(ns.Nav.MoveOnKind() == "done" and ns.HUD.Lines()[4]:find("then move on", 1, true),
    "at it, move on confirms it: " .. ns.HUD.Lines()[4])
  ns.Nav.MoveOn()
  check(qs[2].done and not qs[2].passed and ns.Nav.CurrentStep().stop ~= qs[2], "move on confirms a quest's extra step")
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
  SlashCmdList.WAYWARD("debug quest 7")
  local debugText = table.concat(chat, "\n", said + 1)
  check(#chat > said + 2 and chat[said + 2]:find("(id 7)", 1, true) and debugText:find("didn't offer it", 1, true)
    and debugText:find("notable: nothing stands out", 1, true) and debugText:find("chain ahead", 1, true),
    "/ww debug quest shows the chain data, the giver's answer, why it's notable and the chain ahead")
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
  if ERA then
    -- Classic Era's high IDs (Season of Discovery's) aren't Forever's additions.
    check(after(98189) == nil and after(98190) == nil and after(98191) == nil and ns.Quests.IsQuestAvailable(98189),
      "Classic Era: no chains inferred for high quest IDs")
  else
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
  end
  for _, id in ipairs({ 285, 286, 98189, 98190, 98191, 98300, 98301 }) do QUESTS[id] = nil end
  refreshData()
end
---------------------------------------------------------------- inferred chains (end)
---------------------------------------------------------------- chain ahead (begin)
do
  io.write("chain ahead\n")
  -- Three steps after Westfall Rumours, the last a Deadmines quest.
  QUESTS[501] = { name = "Westfall Rumours", questLevel = 18, requiredLevel = 15, nextQuestInChain = 502,
    startedBy = { { 344 } }, finishedBy = { { 344 } } }
  QUESTS[502] = { name = "Following the Trail", questLevel = 20, requiredLevel = 16, startedBy = { { 344 } },
    finishedBy = { { 344 } } }
  QUESTS[503] = { name = "The Defias Hideout", questLevel = 22, requiredLevel = 17, preQuestSingle = { 502 },
    nextQuestInChain = 504, startedBy = { { 344 } }, finishedBy = { { 344 } } }
  QUESTS[504] = { name = "Into the Mines", questLevel = 24, requiredLevel = 18, zoneOrSort = 1581,
    startedBy = { { 344 } }, finishedBy = { { 344 } } }
  -- A fork: two quests that close each other (the first Horde-only), both leading on.
  QUESTS[510] = { name = "Pick a Side", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } } }
  QUESTS[511] = { name = "Side of the Horde", questLevel = 19, requiredLevel = 15, requiredRaces = 2,
    preQuestSingle = { 510 }, exclusiveTo = { 512 }, startedBy = { { 344 } } }
  QUESTS[512] = { name = "Side of the Alliance", questLevel = 19, requiredLevel = 15, preQuestSingle = { 510 },
    exclusiveTo = { 511 }, startedBy = { { 344 } } }
  QUESTS[513] = { name = "Either Way", questLevel = 20, requiredLevel = 15, preQuestSingle = { 511, 512 },
    startedBy = { { 344 } } }
  -- A cycle in the data.
  QUESTS[520] = { name = "Round and Round", questLevel = 19, requiredLevel = 15, nextQuestInChain = 521,
    startedBy = { { 344 } } }
  QUESTS[521] = { name = "And Round Again", questLevel = 19, requiredLevel = 15, nextQuestInChain = 520,
    startedBy = { { 344 } } }
  -- Forever's own, no chain data: the second of the name is inferred to follow the first.
  QUESTS[98400] = { name = "Ledger Errand", questLevel = 20, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 344 } } }
  QUESTS[98401] = { name = "Ledger Errand", questLevel = 21, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 344 } } }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy = 3
  refreshData()
  local function ids(steps)
    local out = {}
    for _, q in ipairs(steps or {}) do out[#out + 1] = q.id end
    return table.concat(out, ",")
  end

  local ahead = ns.Quests.ChainAhead(501)
  check(ahead and ids(ahead.steps) == "502,503,504" and ahead.count == 3 and ahead.reachable == 3,
    "the chain ahead follows nextQuestInChain and preQuestSingle: " .. ids(ahead and ahead.steps))
  check(ahead.levelSpan and ahead.levelSpan[1] == 20 and ahead.levelSpan[2] == 24, "with the levels of its steps")
  check(#ahead.dungeons == 1 and ahead.dungeons[1].name == "The Deadmines" and ahead.dungeons[1].areaID == 1581
    and ahead.dungeons[1].questID == 504, "and the dungeon quest in it")
  check(ahead.endsAt and ahead.endsAt.name == "The Deadmines" and ahead.endsAt.dungeon, "ending in the dungeon")
  check(ns.Quests.RewardItems ~= nil or ahead.items == nil, "no reward items without Quests.RewardItems")
  check(ns.Quests.ChainText(501) == "Chain: 3 more quests (levels 20-24), ends in The Deadmines",
    "chain text: " .. tostring(ns.Quests.ChainText(501)))
  check(ns.Quests.ChainText(503) == "Leads to a Deadmines quest", "one step to a dungeon quest: "
    .. tostring(ns.Quests.ChainText(503)))
  check(ns.Quests.ChainText(504) == nil and ns.Quests.ChainAhead(504).count == 0, "nothing follows: no text")
  check(ns.Quests.ChainAhead(502).endsAt.name == "The Deadmines" and ns.Quests.ChainDungeon(502) == "The Deadmines",
    "the dungeon is named from a step further back")
  local nonDungeon = ns.Quests.ChainAhead(98400)
  foreverCheck(nonDungeon.endsAt and nonDungeon.endsAt.name and not nonDungeon.endsAt.dungeon,
    "a chain outside a dungeon ends at the last hand-in's place: " .. tostring(nonDungeon.endsAt and nonDungeon.endsAt.name))

  local fork = ns.Quests.ChainAhead(510)
  check(ids(fork.steps) == "512,513" and ids(fork.alternatives[512]) == "511" and fork.reachable == 2,
    "quests that close each other are one step, the one you can do first: " .. ids(fork.steps))
  check(ns.Quests.ChainText(510) == "Chain: 2 more quests (levels 19-20), ends in " .. fork.endsAt.name,
    "the fork counts once: " .. tostring(ns.Quests.ChainText(510)))
  check(ids(ns.Quests.ChainAhead(520).steps) == "521" and ids(ns.Quests.ChainAhead(521).steps) == "520",
    "a cycle in the data ends the walk")
  foreverCheck(ids(nonDungeon.steps) == "98401" and ns.Quests.ChainText(98400):find("^Chain: 1 more quest %(level 21%)"),
    "an inferred Forever link counts: " .. tostring(ns.Quests.ChainText(98400)),
    ids(nonDungeon.steps) == "", "no inferred link for a high quest ID")
  check(ns.Quests.ChainHighlight(501) and ns.Quests.ChainHighlight(503) and not ns.Quests.ChainHighlight(98400),
    "worth pointing out: a dungeon quest or a long chain, not one more quest")
  check(ns.Quests.ChainAhead(501) == ahead, "kept until the data changes")
  ns.Fire("DATA_CHANGED")
  check(ns.Quests.ChainAhead(501) ~= ahead and ids(ns.Quests.ChainAhead(501).steps) == "502,503,504",
    "and built again after")

  -- Where it shows: Quests page search and log rows, the overview, the pickup question.
  local function rowWith(results, id)
    for _, r in ipairs(results) do
      if r.id == id then return r end
    end
  end
  local function detailWith(r, text)
    for _, d in ipairs(r and r.details or {}) do
      if d.text:find(text, 1, true) then return true end
    end
    return false
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local row = rowWith(ns.QuestsPage.Results("Defias Hideout"), "quest503")
  check(row and row.subtitle:find("leads to The Deadmines", 1, true) and detailWith(row, "Leads to a Deadmines quest"),
    "a search result says where its chain leads: " .. tostring(row and row.subtitle))
  row = rowWith(ns.QuestsPage.Results("Pick a Side"), "quest510")
  check(row and not row.subtitle:find("leads to", 1, true) and detailWith(row, "Chain: 2 more quests"),
    "no dungeon: only the tooltip line")
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete }
  local log = { 501 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false, title = QUESTS[log[i]].name } end
  C_QuestLog.IsComplete = function() return false end
  row = rowWith(ns.QuestsPage.Results(""), "log501")
  check(row and row.subtitle:find("leads to The Deadmines", 1, true) and detailWith(row, "Chain: 3 more quests"),
    "a quest log row too: " .. tostring(row and row.subtitle))
  check(ns.JourneyOverview.StopTooltipText({ action = { kind = "pickup", questID = 501 } })
    == ns.Quests.ChainText(501) and ns.JourneyOverview.StopTooltipText({ text = "Fly" }) == nil,
    "a quest stop in the overview has the chain in its tooltip")
  local tipRow = { stop = { text = "Pick up Westfall Rumours", action = { kind = "pickup", questID = 501 } } }
  local tipOk, tipErr = pcall(ns.JourneyOverview.ShowStopTooltip, tipRow)
  check(tipOk and tipRow.tooltip, "hovering the stop shows that tooltip" .. (tipErr and (": " .. tostring(tipErr)) or ""))

  ns.Nav.Stop()
  ns.Snackbar.Clear()
  fire("QUEST_ACCEPTED", 501)
  runTimers()
  local shown = ns.Snackbar.Current()
  check(shown and shown.text:find("You picked up Westfall Rumours. Start a journey", 1, true)
    and shown.note == "Chain: 3 more quests (levels 20-24), ends in The Deadmines.",
    "the pickup question says it leads to a long chain: " .. tostring(shown and shown.note))
  ns.Snackbar.Clear()
  log = { 98400 }
  fire("QUEST_ACCEPTED", 98400)
  runTimers()
  shown = ns.Snackbar.Current()
  check(shown and shown.text:find("You picked up Ledger Errand. Start a journey", 1, true) and shown.note == nil,
    "but not about one more quest: " .. tostring(shown and shown.note))
  ns.Snackbar.Clear()
  ns.Nav.Stop()
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete = savedLog[1], savedLog[2], savedLog[3]

  -- /ww debug quest lists the steps.
  local said = #chat
  SlashCmdList.WAYWARD("debug quest 510")
  local listed = table.concat(chat, "\n", said + 1)
  check(listed:find("chain ahead: 2 steps, 2 you can do", 1, true) and listed:find("or Side of the Horde (511)", 1, true),
    "/ww debug quest prints the chain ahead with its alternatives")
  for _, id in ipairs({ 501, 502, 503, 504, 510, 511, 512, 513, 520, 521, 98400, 98401 }) do QUESTS[id] = nil end
  refreshData()
end
---------------------------------------------------------------- chain ahead (end)
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

  -- Its follow-up is picked up where you hand it in, on the way: it goes in, and a snackbar says so.
  check(#ns.Quests.FollowUps(14) == 1 and ns.Quests.FollowUps(14)[1].id == 13, "Chain part 1 is followed by Chain part 2")
  ns.Snackbar.Clear()
  local shown
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which, a, b, data)
    shown = { which = which, text = string.format(StaticPopupDialogs[which].text, a, b), data = data }
  end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local played = {}
  PlaySound = function(id) played[#played + 1] = id end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Hand in", stops = ns.Journey.QuestStops(14, here) }))
  local offer = ns.Nav.pendingFollowUps
  local snack = ns.Snackbar.Current()
  check(shown == nil and offer and offer.heading == "Chain part 1 continues with:"
    and #offer.quests == 1 and offer.quests[1].quest.id == 13 and offer.quests[1].checked and ns.Nav.TripHasQuest(13),
    "handing in a quest adds its follow-up, unasked, when it's on the way")
  check(snack and not snack.question and snack.text:find("Chain part 1 continues: added Chain part 2 to your journey (~", 1, true)
    and snack.actions[1].label == "Undo" and snack.actions[1].icon == "undo" and #snack.actions == 1
    and snack.quests[13] and snack.quests[14],
    "a snackbar says so, with undo: " .. tostring(snack and snack.text))
  check(#played == 1 and played[1] == ns.Sounds.Kit("start"),
    "one sound: the journey's start, not the added stop's too: " .. table.concat(played, ","))
  PlaySound = nil
  local e = offer.quests[1]
  check(e.seconds == e.travel + offer.perQuest and snack.detail and #snack.detail == 1
    and snack.detail[1]:find("Chain part 2: ", 1, true) and snack.detail[1]:find("to do it", 1, true),
    "each quest has its time (travel + doing it), on hover: " .. tostring(snack.detail and snack.detail[1]))
  local kinds = {}
  for _, st in ipairs(ns.Nav.active.journey.stops) do kinds[#kinds + 1] = st.action.kind .. st.action.questID end
  check(table.concat(kinds, ",") == "turnin14,pickup13", "it goes after the hand-in: " .. table.concat(kinds, ","))
  ns.Snackbar.Click(1)
  check(not ns.Nav.TripHasQuest(13) and ns.Nav.TripHasQuest(14) and ns.Snackbar.Current() == nil,
    "Remove takes the follow-up out again; the hand-in stays")
  ns.Nav.Stop()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Hand in", stops = ns.Journey.QuestStops(14, here) }))
  ns.Snackbar.Clear()
  -- Talking to the giver before handing in: the follow-up isn't offered yet, and that's expected.
  local turnin, pickup = ns.Nav.active.journey.stops[1], ns.Nav.active.journey.stops[2]
  player.x, player.y = pickup.node.x, pickup.node.y
  ns.Fire("QUESTS_OFFERED", pickup.giver, {})
  check(ns.Nav.active and ns.Nav.TripHasQuest(13) and not (ns.charDB.notOffered and ns.charDB.notOffered[13]),
    "a follow-up still waiting on the hand-in isn't dropped as not offered")
  player.x, player.y = turnin.node.x, turnin.node.y
  fire("QUEST_TURNED_IN", 14)
  check(ns.Nav.active and turnin.done and ns.Nav.TripHasQuest(13), "handing in moves on to the follow-up, not the end")
  fire("QUEST_REMOVED", 14)
  runTimers()
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  -- A chain: the quests on the way go in, the rest of it doesn't.
  local chain = { quests = {
    { quest = { id = 1 }, depth = 1, travel = 0, seconds = 300, stops = {}, checked = true },
    { quest = { id = 2 }, parent = 1, depth = 2, travel = 60, seconds = 360, stops = {}, checked = true },
    { quest = { id = 3 }, parent = 2, depth = 3, travel = 600, seconds = 900, stops = {}, checked = false },
  } }
  local choice = ns.Nav.FollowUpChoice(chain)
  check(choice.count == 2 and choice.seconds == 660, "only the chain on the way goes in, and its time adds up")

  -- A follow-up out of the way (10 min more): listed, unticked, for one quest you chose; not for a bigger trip.
  local realPlan = ns.Journey.Plan
  ns.Journey.Plan = function(start, def, net)
    local planned = realPlan(start, def, net)
    for _, st in ipairs(planned and def.stops or {}) do
      if st.action and st.action.kind == "pickup" and st.action.questID == 13 then
        planned.seconds = planned.seconds + 600
        break
      end
    end
    return planned
  end
  ns.Nav.Stop()
  ns.Nav.pendingFollowUps = nil
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Hand in", stops = ns.Journey.QuestStops(14, here) }))
  offer, snack = ns.Nav.pendingFollowUps, ns.Snackbar.Current()
  check(offer and #offer.quests == 1 and offer.quests[1].quest.id == 13 and not offer.quests[1].checked
    and offer.quests[1].travel > 180 and not ns.Nav.TripHasQuest(13),
    "one quest's follow-up out of the way isn't added unasked")
  check(snack and snack.question and snack.text:find("Chain part 1 continues with Chain part 2 (~", 1, true)
    and snack.text:find("Add it to your journey?", 1, true) and snack.actions[1].label == "Add to journey",
    "a snackbar asks about it: " .. tostring(snack and snack.text))
  ns.Snackbar.Click(1)
  check(ns.Nav.TripHasQuest(13) and ns.Snackbar.Current() == nil, "Add to journey adds it")
  ns.Nav.Stop()
  ns.Snackbar.Clear()
  local both = ns.Journey.QuestStops(14, here)
  for _, st in ipairs(ns.Journey.QuestStops(44, here)) do both[#both + 1] = st end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Hand ins", stops = both }))
  check(ns.Snackbar.Current() == nil and not ns.Nav.TripHasQuest(13),
    "a journey of several hand-ins only takes follow-ups on the way, and asks nothing")
  ns.Nav.Stop()
  ns.Journey.Plan = realPlan

  -- Abandoning a quest: its stops (and the follow-up after them) leave the trip; nothing left ends it.
  local other = { node = ns.Geo.Node(1433, 0.6, 0.5, "Elsewhere"), text = "Visit Elsewhere" }
  local stops = ns.Journey.QuestStops(14, here)
  stops[#stops + 1] = other
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Two things", stops = stops }))
  check(ns.Nav.TripHasQuest(13), "the follow-up is on the trip")
  check(ns.Snackbar.Current() and ns.Snackbar.Current().quests[14], "with its snackbar up")
  log = { 44 }
  fire("QUEST_REMOVED", 14)
  runTimers()
  local left = {}
  for _, st in ipairs(ns.Nav.active and ns.Nav.active.journey.stops or {}) do left[#left + 1] = st.text end
  check(ns.Nav.active and not ns.Nav.TripHasQuest(14) and not ns.Nav.TripHasQuest(13) and #left == 1
    and left[1] == "Visit Elsewhere", "an abandoned quest and its follow-up leave the trip: " .. table.concat(left, ","))
  check(ns.Snackbar.Current() == nil, "and the snackbar about them goes: its Remove has nothing left to take out")
  ns.Nav.Stop()
  log = { 44, 14 }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Hand in", stops = ns.Journey.QuestStops(14, here) }))
  ns.Snackbar.Clear()
  local abandoned = false
  ns.Listen("QUEST_ABANDONED", function() abandoned = true end)
  fire("QUEST_TURNED_IN", 14)
  fire("QUEST_REMOVED", 14)
  log = { 44 }
  runTimers()
  check(not abandoned, "a hand-in isn't taken for abandoning")
  ns.Nav.Stop()
  log = { 44, 14 }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Hand in", stops = ns.Journey.QuestStops(14, here) }))
  ns.Snackbar.Clear()
  log = { 44 }
  fire("QUEST_REMOVED", 14)
  runTimers()
  check(ns.Nav.active == nil, "abandoning the trip's only quest cancels the trip")
  log = { 44, 14 }
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
  ns.Snackbar.Clear()
  -- The newest snackbar, on screen or waiting behind the one that is.
  local function newest()
    local q = ns.Snackbar.Queued()
    return q[#q] or ns.Snackbar.Current()
  end
  local shown
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  -- No trip on: start one for it?
  local played = {}
  PlaySound = function(id) played[#played + 1] = id end
  log[1] = 45
  fire("QUEST_ACCEPTED", 45)
  runTimers()
  shown = newest()
  check(shown and shown.question and shown.text:find("You picked up Murloc Count. Start a journey for it (~", 1, true)
    and shown.text:find("min)?", 1, true) and #shown.actions == 1 and shown.actions[1].label == "Start journey",
    "picking up a quest with no journey on offers one for it, with its time, in a snackbar: " .. tostring(shown and shown.text))
  check(#played == 1 and played[1] == ns.Sounds.Kit("popup"), "the question plays the popup sound")
  PlaySound = nil
  ns.Snackbar.Click(1)
  local kinds = {}
  for _, st in ipairs(ns.Nav.active.journey.stops) do kinds[#kinds + 1] = st.action.kind end
  check(table.concat(kinds, ",") == "complete,turnin", "Start trip: do it, hand it in: " .. table.concat(kinds, ","))

  -- On that trip, another quest: add it (and how much longer), or a new trip.
  ns.Snackbar.Clear()
  log[2] = 40
  QUESTS[40] = { name = "Murloc Menace", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } } }
  refreshData()
  check(ns.Nav.PickupOffer({ 40 }).extra <= 180, "Murloc Menace adds 3 min or less to the journey")
  local said = #chat
  fire("QUEST_ACCEPTED", 40)
  runTimers()
  shown = newest()
  check(ns.Nav.TripHasQuest(40) and ns.Nav.TripHasQuest(45) and shown and not shown.question,
    "a pickup that adds 3 min or less goes straight into the journey, unasked")
  check(shown.text:find("Added Murloc Menace to your journey (", 1, true) and #shown.actions == 1
    and shown.actions[1].label == "Undo" and shown.actions[1].icon == "undo" and shown.quests[40],
    "a snackbar says so, with the time and Remove: " .. tostring(shown.text))
  check(chat[#chat]:find("picked up Murloc Menace: added to your journey (", 1, true)
    and chat[#chat]:find("x drops it", 1, true) and #chat == said + 1,
    "and chat says so, with the time and how to drop it: " .. tostring(chat[#chat]))
  ns.Snackbar.Click(1)
  check(not ns.Nav.TripHasQuest(40) and ns.Nav.TripHasQuest(45) and ns.charDB.askedProgress[40]
    and chat[#chat]:find("took Murloc Menace out of your journey.", 1, true),
    "Remove takes it out again, and progress on it won't be asked about: " .. tostring(chat[#chat]))
  check(not ns.Nav.RemoveAdded({}, "nothing"), "Remove with nothing left to take out does nothing")
  ns.charDB.askedProgress[40] = nil
  ns.Nav.AddToTrip(ns.Nav.PickupOffer({ 40 }).stops, "Murloc Menace")

  -- Picked up together, one that adds more than 3 min (made so here) and one
  -- that doesn't: the near one goes in, the far one is asked about.
  QUESTS[47] = { name = "Murloc Courier", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } } }
  QUESTS[48] = { name = "Murloc Scales", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } } }
  refreshData()
  local realOffer = ns.Nav.PickupOffer
  ns.Nav.PickupOffer = function(ids)
    local offer = realOffer(ids)
    for _, id in ipairs(offer and offer.ids or {}) do
      if id == 47 and offer.extra then offer.extra = offer.extra + 200 end
    end
    return offer
  end
  log[3], log[4] = 48, 47
  fire("QUEST_ACCEPTED", 48)
  fire("QUEST_ACCEPTED", 47)
  runTimers()
  check(ns.Nav.TripHasQuest(48) and not ns.Nav.TripHasQuest(47), "the near quest goes in, the far one doesn't")
  shown = newest()
  check(shown and shown.question and shown.text:find("You picked up Murloc Courier. Add it to your journey (about ~", 1, true)
    and ns.Snackbar.Current() and ns.Snackbar.Current().text:find("Added Murloc Scales", 1, true),
    "the one that adds more than 3 min is asked about, on its own, after the note on the near one: "
      .. tostring(shown and shown.text))
  -- Under 3 min only because the plan with it spends your Hearthstone: asked,
  -- and the question says so.
  ns.Nav.PickupOffer = function(ids)
    local offer = realOffer(ids)
    if offer and offer.extra then offer.extraNoHearth = offer.extra + 400 end
    return offer
  end
  ns.Snackbar.Clear()
  fire("QUEST_ACCEPTED", 47)
  runTimers()
  shown = newest()
  check(not ns.Nav.TripHasQuest(47) and shown and shown.question
    and shown.text:find("but only by using your Hearthstone: ~", 1, true) and shown.text:find("without it)?", 1, true),
    "fitting only by hearthing: asked, not added, and the question says why: " .. tostring(shown and shown.text))
  check(not ns.Nav.ExtraText({ extra = 100, extraNoHearth = 130 }):find("Hearthstone", 1, true),
    "a hearth that makes up under a minute isn't mentioned")
  ns.Nav.PickupOffer = realOffer
  ns.Snackbar.Clear()
  ns.Nav.RemoveQuest(48)
  log[3], log[4] = nil, nil
  QUESTS[47], QUESTS[48] = nil, nil
  refreshData()

  -- An addon that accepts and hands in for you (like Thunderbrew): a
  -- repeatable picked up and handed in before the pickup is looked at isn't
  -- planned all over again.
  local savedFlagsKey = questKeys.specialFlags
  questKeys.specialFlags = 24
  QUESTS[49] = { name = "Murloc Brew", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 344 } }, objectives = { { { 9101 } } }, specialFlags = 1 }
  refreshData()
  check(ns.Quests.IsRepeatable(49), "Murloc Brew is repeatable")
  ns.Snackbar.Clear()
  log[3] = 49
  fire("QUEST_ACCEPTED", 49)
  log[3] = nil
  fire("QUEST_TURNED_IN", 49)
  runTimers()
  check(newest() == nil and not ns.Nav.TripHasQuest(49),
    "a repeatable handed in straight after picking it up isn't added again, nor asked about")
  questKeys.specialFlags = savedFlagsKey
  QUESTS[49] = nil
  refreshData()

  -- The option off: asked about like any other pickup.
  ns.Snackbar.Clear()
  ns.Nav.RemoveQuest(40)
  ns.db.settings.autoAddPickups = false
  check(not ns.Nav.TripHasQuest(40) and ns.Nav.TripHasQuest(45), "Murloc Menace dropped from the journey")
  fire("QUEST_ACCEPTED", 40)
  runTimers()
  shown = newest()
  check(shown and shown.question and shown.text:find("Murloc Menace", 1, true) and shown.text:find("more)?", 1, true)
    and shown.actions[1].label == "Add to journey" and shown.actions[2].label == "New journey"
    and shown.actions[2].tooltip:find("set aside", 1, true),
    "with a journey on and the option off: add it, with the time it adds, or a new journey: "
      .. tostring(shown and shown.text))
  ns.Snackbar.Click(1)
  check(ns.Nav.TripHasQuest(40) and ns.Nav.TripHasQuest(45), "Add to trip: both quests in it")
  ns.db.settings.autoAddPickups = nil
  local auto
  for _, c in ipairs(ns.Options.Choices()) do
    if c.name == "Automatically add quest pickups" then auto = c end
  end
  check(auto and auto.section == "Journeys and quests" and auto.get() == true, "the option is there, on by default")

  -- Already in the trip: nothing to ask.
  ns.Snackbar.Clear()
  fire("QUEST_ACCEPTED", 40)
  runTimers()
  check(newest() == nil, "a quest already in the trip isn't asked about")

  -- Progress on a logged quest outside the journey: asked once, out of combat.
  QUESTS[46] = { name = "Murloc Hunt", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } } }
  refreshData()
  local savedObjectives = C_QuestLog.GetQuestObjectives
  local hunt = { { numFulfilled = 0, text = "Murlocs slain: 0/8" } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 46 and hunt or {} end
  log[3] = 46
  fire("QUEST_LOG_UPDATE")
  runTimers()
  check(newest() == nil, "a quest just seen in the log isn't asked about")
  hunt[1].numFulfilled = 1
  InCombatLockdown = function() return true end
  fire("QUEST_LOG_UPDATE")
  runTimers()
  check(newest() == nil, "progress isn't asked about in combat")
  InCombatLockdown = nil
  fire("PLAYER_REGEN_ENABLED")
  shown = newest()
  check(shown and shown.question and shown.text:find("You made progress on Murloc Hunt. Add it", 1, true),
    "progress on a quest outside the journey asks to add it, once out of combat: " .. tostring(shown and shown.text))
  ns.Snackbar.Clear()
  hunt[1].numFulfilled = 2
  fire("QUEST_LOG_UPDATE")
  runTimers()
  check(newest() == nil, "Not now: more progress on it isn't asked about again")
  log[3] = nil
  C_QuestLog.GetQuestObjectives = savedObjectives
  QUESTS[46] = nil
  ns.charDB.askedProgress = nil
  refreshData()

  ns.db.settings.askOnPickup = false
  ns.Nav.Stop()
  fire("QUEST_ACCEPTED", 45)
  runTimers()
  check(newest() == nil, "the option turns the question off")
  ns.db.settings.askOnPickup = nil

  ns.JourneyOverview.Toggle()
  ns.Snackbar.Clear()
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

  -- A pickup whose hand-in adds under a minute brings it along; one handed in
  -- far away doesn't (that's asked about once you pick it up).
  QUESTS[1].finishedBy, QUESTS[7].finishedBy = { { 344 } }, { { 6000 } }
  refreshData()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = {
    { node = ns.Geo.Node(1433, 0.53, 0.5, "First"), text = "Visit First" } } }))
  local solomon
  for _, sug in ipairs(ns.OnTheWay.Get()) do
    for _, st in ipairs(sug.stops) do
      if st.action and st.action.questID == 1 then solomon = sug end
    end
  end
  local function tripKinds(questID)
    local kinds = {}
    for _, st in ipairs(ns.Nav.active and ns.Nav.active.journey.root.stops or {}) do
      if st.action and st.action.questID == questID then kinds[#kinds + 1] = st.action.kind end
    end
    return table.concat(kinds, ",")
  end
  chat = {}
  check(solomon and ns.OnTheWay.Add(solomon), "Solomon's quests are on the way and added")
  check(tripKinds(1) == "pickup,turnin", "handed in where it's picked up: the hand-in comes along: " .. tripKinds(1))
  check(tripKinds(7) == "pickup", "handed in in Stormwind: just the pickup: " .. tripKinds(7))
  local said = false
  for _, line in ipairs(chat) do
    if line:find("handing in Redridge Goulash adds under a minute", 1, true) then said = true end
  end
  check(said, "and says so in chat")
  ns.Nav.Stop()
  QUESTS[1].finishedBy, QUESTS[7].finishedBy = nil, nil
  refreshData()
end
---------------------------------------------------------------- on the way (end)
---------------------------------------------------------------- errands (begin)
do
  io.write("errands\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local function trip()
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = {
      { node = ns.Geo.Node(1433, 0.53, 0.5, "First"), text = "Visit First" },
      { node = ns.Geo.Node(1433, 0.56, 0.5, "Second"), text = "Visit Second" } } }))
  end
  local function rowText()
    local out = {}
    for _, r in ipairs(ns.ErrandPicker.Rows()) do out[#out + 1] = r.text .. " " .. r.time end
    return table.concat(out, " | ")
  end
  trip()
  local hud = ns.HUD.Frame()
  check(hud.add and hud.add.scripts.OnClick, "the directions box has a + button")

  -- Worn gear: it opens on repairs, least out of the way first, your side only.
  durability = { 10, 50 }
  hud.add.scripts.OnClick(hud.add)
  check(ns.ErrandPicker.IsShown() and ns.ErrandPicker.Selected() == "repair",
    "+ opens the list, on repairs with worn gear: " .. tostring(ns.ErrandPicker.Selected()))
  local repairs = ns.Errands.Get("repair")
  check(repairs[1] and repairs[1].npc == "Redridge Smith", "the repairer by the trip comes first: " .. rowText())
  local sorted = true
  for i = 2, #repairs do
    if repairs[i].extra < repairs[i - 1].extra then sorted = false end
  end
  check(sorted, "sorted by the time each adds to the trip")
  check(ns.ErrandPicker.Rows()[1].time:find("^%+"), "each row says the time it adds: " .. rowText())
  durability = { 50, 50 }

  -- Kinds: a stable master only for hunters.
  local function hasKind(key)
    for _, kind in ipairs(ns.Errands.Kinds()) do if kind.key == key then return true end end
    return false
  end
  check(hasKind("mailbox") and hasKind("banker") and not hasKind("stableMaster"), "a warlock gets no stable master")
  UnitClass = function() return "Hunter", "HUNTER", 3 end
  check(hasKind("stableMaster"), "a hunter does")
  UnitClass = function() return "Warlock", "WARLOCK", 9 end

  -- Innkeepers and banks from the sources' NPC flags.
  LibQuestieDB.Enum.npcFlags.INNKEEPER, LibQuestieDB.Enum.npcFlags.BANKER = 128, 131072
  NPCS[7100] = { name = "Lakeshire Banker", npcFlags = 131072, friendlyToFaction = "A",
    spawns = { [44] = { { 54.0, 52.0 } } } }
  NPCS[7101] = { name = "Horde Innkeeper", npcFlags = 128, friendlyToFaction = "H",
    spawns = { [44] = { { 80.0, 20.0 } } } }
  refreshData()
  ns.ErrandPicker.Select("banker")
  check(ns.ErrandPicker.Rows()[1] and ns.ErrandPicker.Rows()[1].text:find("Lakeshire Banker", 1, true),
    "banks listed: " .. rowText())
  ns.ErrandPicker.Select("innkeeper")
  check(rowText():find("Innkeeper Farley", 1, true) and not rowText():find("Horde Innkeeper", 1, true),
    "inns of your side only: " .. rowText())

  -- Mailboxes: none known, then the sources' (in your towns), then the ones you open.
  ns.ErrandPicker.Select("mailbox")
  check(ns.ErrandPicker.EmptyText() and ns.ErrandPicker.EmptyText():find("Open one once", 1, true),
    "no mailboxes known: says how to learn one: " .. tostring(ns.ErrandPicker.EmptyText()))
  local savedObjects = ObjectDB
  ObjectDB = entity({ [9300] = { name = "Mailbox", spawns = { [44] = { { 52.5, 50.5 } } } },
    [9301] = { name = "Mailbox", spawns = { [44] = { { 80.5, 20.5 } } } } }, {})
  refreshData()
  local boxes = ns.Errands.Get("mailbox")
  check(#boxes == 1 and math.abs(boxes[1].node.x - 0.525) < 0.001,
    "the sources' mailboxes in your towns only: " .. #boxes)
  ObjectDB = savedObjects
  refreshData()
  player.x, player.y = 0.545, 0.505
  fire("MAIL_SHOW")
  fire("MAIL_SHOW")
  check(#ns.db.mailboxes == 1, "opening a mailbox records it, once: " .. #ns.db.mailboxes)
  player.x, player.y = 0.5, 0.5
  ns.ErrandPicker.Select("mailbox")
  check(ns.ErrandPicker.Rows()[1] and ns.ErrandPicker.Rows()[1].text:find("Mailbox", 1, true), "and lists it: " .. rowText())

  -- Add: the stop goes in the trip and the list closes; the NPC is someone to talk to.
  ns.ErrandPicker.Select("repair")
  check(ns.ErrandPicker.AddRow(1) and not ns.ErrandPicker.IsShown(), "Add puts it in the trip and closes the list")
  local added
  for _, st in ipairs(ns.Nav.active.journey.root.stops) do
    if st.npc == "Redridge Smith" then added = st end
  end
  check(added and added.action and added.action.kind == "talk" and added.text == "Repair at Redridge Smith",
    "a stop to talk to the repairer: " .. tostring(added and added.text))
  hud.add.scripts.OnClick(hud.add)
  ns.ErrandPicker.Select("repair")
  check(ns.ErrandPicker.Rows()[1].time:find("in your journey", 1, true) and not ns.ErrandPicker.AddRow(1),
    "listed again as in your journey, and not added twice: " .. rowText())
  -- The last kind you added from is where it opens next time.
  ns.ErrandPicker.Toggle()
  ns.ErrandPicker.Toggle()
  check(ns.ErrandPicker.Selected() == "repair", "opens on the kind you last added from")

  -- A mailbox stop: an object, done when you get there.
  ns.ErrandPicker.Select("mailbox")
  ns.ErrandPicker.AddRow(1)
  local box
  for _, st in ipairs(ns.Nav.active.journey.root.stops) do
    if st.text == "Check your mail" then box = st end
  end
  check(box and box.node.object and not box.action, "a mailbox stop has nobody to talk to")
  hud.add.scripts.OnClick(hud.add)
  ns.ErrandPicker.Select("mailbox")
  check(ns.ErrandPicker.Rows()[1] and ns.ErrandPicker.Rows()[1].time:find("in your journey", 1, true),
    "and the mailbox shows as in your journey: " .. rowText())
  ns.ErrandPicker.Hide()

  -- Plain directions become a trip with the place added.
  ns.Nav.Stop()
  check(not ns.ErrandPicker.IsShown(), "stopping the directions closes the list")
  local second = ns.Geo.Node(1433, 0.56, 0.5, "Second")
  ns.Nav.Start("Second", second, ns.Router.Plan(here, second, ns.Network.Build()))
  ns.ErrandPicker.Toggle()
  ns.ErrandPicker.Select("banker")
  check(ns.ErrandPicker.AddRow(1) and ns.Nav.active.journey and #ns.Nav.active.journey.stops == 2,
    "plain directions: the place joins the destination in a trip")
  ns.Nav.Stop()
  ns.db.mailboxes = {}
  NPCS[7100], NPCS[7101] = nil, nil
  LibQuestieDB.Enum.npcFlags.INNKEEPER, LibQuestieDB.Enum.npcFlags.BANKER = nil, nil
  refreshData()
end
---------------------------------------------------------------- errands (end)
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
  local keys = {}
  for _, h in ipairs(ns.Fanfare.lastShown) do keys[#keys + 1] = h.key end
  check(table.concat(keys, ",") == "xp,quests", "the banner shows what the trip achieved (almost half a level first): " .. table.concat(keys, ","))
  UnitXP, UnitXPMax = nil, nil

  -- A few seconds later: For you's top trip as "Up next" (not the one just done).
  local savedWhenReady = ns.ForYou.WhenReady
  local top = { title = "Quest in Elwynn Forest", route = { steps = {}, seconds = 60 } }
  ns.ForYou.WhenReady = function(fn) fn({ { title = "Errands", journey = {} }, { title = "No route" }, top }) end
  ns.Fanfare.lastUpNext = nil
  runTimers()
  check(ns.Fanfare.lastUpNext == nil and ns.Fanfare.TripFrame():IsShown(),
    "after a journey, the next one waits while the banner is up")
  ns.Fanfare.TripFrame():Hide()
  runTimers()
  check(ns.Fanfare.lastUpNext == top, "and is suggested once it's gone")
  ns.Fanfare.lastUpNext = nil
  ns.Nav.Start("Elsewhere", ns.Geo.Node(1433, 0.9, 0.5, "Elsewhere"), { steps = {}, seconds = 1 })
  ns.ForYou.SuggestNext("Errands")
  check(ns.Nav.active and ns.Fanfare.lastUpNext == nil, "but not once you're on your way somewhere")
  ns.Nav.Stop()
  ns.Fanfare.lastUpNext = nil
  ns.SetSetting("suggestNext", false)
  ns.ForYou.SuggestNext("Errands")
  check(ns.Fanfare.lastUpNext == nil, "and not when turned off in the options")
  ns.SetSetting("suggestNext", true)
  ns.ForYou.WhenReady = savedWhenReady

  -- The banner picks 2 to 4 stats, the biggest achievements first.
  local function shown(stats)
    local out = {}
    for _, h in ipairs(ns.Fanfare.Highlights(stats)) do out[#out + 1] = h.key end
    return table.concat(out, ",")
  end
  check(shown({ seconds = 600, distance = 800 }) == "distance,seconds", "nothing achieved: just distance and time, no zero XP or quests")
  check(shown({ picked = 3, money = 40000, seconds = 600, distance = 800 }) == "money,picked",
    "4 gold beats 3 quests taken, and neither needs time or distance")
  check(shown({ quests = 1, seconds = 600, distance = 800 }) == "quests,distance", "one achievement: topped up to two")
  check(shown({ levels = 1, quests = 5, money = 500, xp = 5000, picked = 2, flights = 1, seconds = 600,
    distance = 800 }) == "levels,quests,xp,flights", "a big trip: the four that stand out, a level first")
  check(shown({ money = 30, picked = 6 }):find("^picked"), "a few copper doesn't beat six quests taken")

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
  -- Trainer cards: new only for a spell no card has shown.
  local function trainCard(title, spells)
    return { id = "needtrain", kind = "train", category = "Due now", title = title, spells = spells,
      goal = b.node, route = zone.route }
  end
  local train = trainCard("Train 2 new spells in Stormwind", { "Fireball (Rank 3)", "Frost Nova" })
  ns.ForYou.CheckNew({ zone, train })
  check(ns.Fanfare.lastNew == train, "a trainer card with new spells pops up")
  ns.ForYou.CheckNew({ zone, trainCard("Train 2 new spells in Goldshire", { "Frost Nova", "Fireball (Rank 3)" }) })
  check(ns.Fanfare.lastNew == train, "not again for the same spells at another trainer")
  ns.ForYou.CheckNew({ zone, trainCard("Train 1 new spell in Stormwind", { "Frost Nova" }) })
  check(ns.Fanfare.lastNew == train, "nor for fewer of them")
  local more = trainCard("Train 3 new spells in Stormwind", { "Frost Nova", "Fireball (Rank 3)", "Arcane Missiles" })
  ns.ForYou.CheckNew({ zone, more })
  check(ns.Fanfare.lastNew == more, "but again for a spell not shown before")
  -- On a flight, the zones passed over set nothing off until the landing.
  local realResults, looked = ns.ForYou.Results, 0
  ns.ForYou.Results = function() looked = looked + 1 return {} end
  runTimers()
  looked = 0
  UnitOnTaxi = function() return true end
  fire("ZONE_CHANGED_NEW_AREA")
  runTimers()
  runTimers()
  fire("ZONE_CHANGED_NEW_AREA")
  runTimers()
  check(looked == 0, "flying over zones: no suggestions planned, no toasts")
  UnitOnTaxi = function() return false end
  runTimers()
  runTimers()
  check(looked >= 1, "landing: looked at where you are")
  ns.ForYou.Results = realResults
  player.x = 0.5
  ns.Panel.Activate(dungeon)
  check(ns.Nav.active and ns.Nav.active.title:find("Stockade", 1, true), "clicking it starts it")
  ns.Nav.Stop()
end
---------------------------------------------------------------- fanfare (end)
---------------------------------------------------------------- sounds (begin)
do
  io.write("sounds\n")
  ns.Nav.Stop()
  runTimers()
  local played = {}
  PlaySound = function(id) played[#played + 1] = id end
  local function last() return played[#played] end
  local function chatSince(n) return table.concat(chat, "\n", n + 1) end
  local steps = ns.Sounds.Options("step")
  check(ns.Sounds.Kit("popup") == 7355 and ns.Sounds.Kit("step") == 836 and ns.Sounds.Kit("start") == 231913
    and ns.Sounds.Kit("complete") == 218238 and ns.Sounds.Kit("toast") == 73280, "each moment has its default sound")

  local before = #chat
  SlashCmdList.WAYWARD("sounds")
  check(chatSince(before):find("step (a stop added to your journey): 1. IG_ABILITY_PAGE_TURN", 1, true),
    "/ww sounds lists the moments and what each plays")
  before = #chat
  SlashCmdList.WAYWARD("sounds step")
  check(chatSince(before):find("> 1. IG_ABILITY_PAGE_TURN", 1, true)
    and chatSince(before):find("15. IG_WRITE_QUEST", 1, true), "/ww sounds step lists its shortlist, the chosen one marked")

  SlashCmdList.WAYWARD("sounds step 3")
  check(last() == steps[3][1] and ns.Sounds.Kit("step") == steps[1][1], "playing one to compare doesn't change the choice")
  SlashCmdList.WAYWARD("sounds step next")
  check(last() == steps[4][1], "next plays the one after the last tried")
  SlashCmdList.WAYWARD("sounds step " .. #steps)
  SlashCmdList.WAYWARD("sounds step next")
  check(last() == steps[1][1], "and wraps round to the first")
  local count = #played
  SlashCmdList.WAYWARD("sounds step 99")
  SlashCmdList.WAYWARD("sounds nonsense")
  SlashCmdList.WAYWARD("sounds use step")
  check(#played == count, "a number out of range or an unknown moment plays nothing")

  SlashCmdList.WAYWARD("sounds use step 3")
  check(ns.Sounds.Kit("step") == steps[3][1] and ns.db.settings.sounds.step == steps[3][1], "use keeps it (saved)")
  SlashCmdList.WAYWARD("sounds use start " .. #ns.Sounds.Options("start"))
  check(ns.Sounds.Kit("start") == 4140, "the race option plays your race's sting (a human here)")
  SlashCmdList.WAYWARD("sounds use start default")

  -- In a trip: start, a stop added, the end.
  played = {}
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local a = { node = ns.Geo.Node(1433, 0.53, 0.5, "First"), text = "Visit First" }
  local b = { node = ns.Geo.Node(1433, 0.56, 0.5, "Second"), text = "Visit Second" }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = { a } }))
  check(#played == 1 and played[1] == 231913, "starting a trip plays the start sound")
  ns.Nav.AddToTrip({ b }, "Second")
  check(#played == 2 and played[2] == steps[3][1], "adding a stop plays the chosen click")
  player.x = 0.53
  ns.HUD.Update()
  player.x = 0.56
  ns.HUD.Update()
  check(ns.Nav.active == nil and #played == 3 and played[3] == 218238, "the end of the trip plays the complete sound")
  ns.Nav.Start("Second", b.node, ns.Router.Plan(here, b.node, ns.Network.Build()))
  check(#played == 4 and played[4] == 218238, "directions to where you are: the fanfare's sound, no start sound after it")
  player.x = 0.5
  ns.Nav.Start("Second", b.node, ns.Router.Plan(here, b.node, ns.Network.Build()))
  check(#played == 5 and played[5] == 231913, "plain directions play the start sound too")
  ns.Nav.Stop()

  SlashCmdList.WAYWARD("sounds use step off")
  played = {}
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = { a } }))
  ns.Nav.AddToTrip({ b }, "Second")
  check(ns.Sounds.Kit("step") == nil and #played == 1, "off: no click, the other sounds stay")
  ns.Nav.Stop()
  SlashCmdList.WAYWARD("sounds use step default")
  check(ns.Sounds.Kit("step") == steps[1][1] and ns.db.settings.sounds.step == nil, "default goes back to the default")

  -- test: the real banner, toast and question, with sample text.
  played = {}
  local lastTrip = ns.Fanfare.lastTrip
  SlashCmdList.WAYWARD("sounds test complete 2")
  check(last() == ns.Sounds.Options("complete")[2][1] and ns.Fanfare.lastTrip == lastTrip and ns.Nav.active == nil,
    "test complete shows the banner with sound 2, and isn't a real trip")
  SlashCmdList.WAYWARD("sounds test toast")
  check(last() == 73280 and ns.Nav.active == nil, "test toast shows a toast now, with the chosen sound")
  ns.Snackbar.Clear()
  SlashCmdList.WAYWARD("sounds test popup")
  local shown = ns.Snackbar.Current()
  check(shown and shown.question and shown.text:find("You picked up Sample Quest", 1, true)
    and last() == 7355, "test popup shows the question with its sound")
  ns.Snackbar.Click(1)
  check(ns.Nav.active == nil, "and its button starts nothing")
  before = #chat
  SlashCmdList.WAYWARD("sounds test step")
  check(chatSince(before):find("a sound test", 1, true) and last() == steps[1][1], "test step: a sample line and the click")

  -- Any sound kit by its ID.
  before = #chat
  SlashCmdList.WAYWARD("sounds step id 567")
  check(last() == 567 and chatSince(before):find("#567 (not on the list)", 1, true)
    and chatSince(before):find("/ww sounds use step id 567", 1, true), "/ww sounds step id 567 plays any kit")
  count = #played
  SlashCmdList.WAYWARD("sounds step id abc")
  SlashCmdList.WAYWARD("sounds step id")
  check(#played == count, "an id that isn't a number plays nothing")
  PlaySound = function(id) played[#played + 1] = id return id ~= 999999 end
  before = #chat
  SlashCmdList.WAYWARD("sounds step id 999999")
  check(chatSince(before):find("didn't play it: no sound kit 999999", 1, true), "a kit the game won't play says so")
  before = #chat
  SlashCmdList.WAYWARD("sounds test complete id 999999")
  check(last() == 999999 and chatSince(before):find("didn't play it", 1, true), "and so does a test with it")
  before = #chat
  SlashCmdList.WAYWARD("sounds step 1")
  check(not chatSince(before):find("didn't play", 1, true), "a kit that plays says nothing more")
  SlashCmdList.WAYWARD("sounds use step id 567")
  before = #chat
  SlashCmdList.WAYWARD("sounds")
  check(ns.Sounds.Kit("step") == 567 and chatSince(before):find("step (a stop added to your journey): #567 (not on the list)", 1, true),
    "use step id 567 keeps it, and the list shows it")

  -- export: the choices on one line.
  local copied
  local realCopy = ns.ShowCopyBox
  ns.ShowCopyBox = function(_, text) copied = text end
  SlashCmdList.WAYWARD("sounds use toast off")
  SlashCmdList.WAYWARD("sounds use start " .. #ns.Sounds.Options("start"))
  SlashCmdList.WAYWARD("sounds export")
  check(copied and copied:match("^[^\n]*") == "popup=7355 step=567 start=race complete=218238 toast=off"
    and copied:find("toast: off", 1, true), "export copies every moment's sound: " .. tostring(copied))
  ns.ShowCopyBox = realCopy

  ns.db.settings.sounds = nil
  PlaySound = nil
end
---------------------------------------------------------------- sounds (end)
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
  check(lines[4]:find("In the area", 1, true) and lines[5] == "Murloc Forager slain: 2/8\nMurloc Scout slain: 0/5",
    "the box says so, with each objective on its own line: " .. lines[4] .. " | " .. lines[5])
  player.x = 0.45
  ns.HUD.Update()
  check(ns.Nav.InArea(), "a little way out: still in the area (no flicker at the edge)")
  player.x, player.y = 0.45, 0.95
  ns.HUD.Update()
  local to = ns.Nav.CurrentStep().to
  check(not ns.Nav.InArea() and math.abs(to.x - 0.8) < 1e-6 and math.abs(to.y - 0.8) < 1e-6,
    string.format("well out: the way points at the nearest spawn from here (%.2f, %.2f)", to.x, to.y))
  pinCheck(ns.Nav.ownsWaypoint, "with the waypoint back up")

  -- Foragers done: only the Scouts' spawns count now.
  objectives[1] = { text = "Murloc Forager slain: 8/8", finished = true }
  player.x, player.y = 0.62, 0.6
  ns.HUD.Update()
  check(not ns.Nav.InArea(), "a finished objective's spawns don't count any more")
  player.x, player.y = 0.31, 0.3
  ns.HUD.Update()
  check(ns.Nav.InArea(), "the open objective's do")

  -- Several areas: spawns close together are one (a camp); each spawn here is its own.
  ns.Nav.Stop()
  objectives[1] = { text = "Murloc Forager slain: 2/8", finished = false }
  local areas = ns.Quests.ObjectiveAreas(43)
  check(#areas == 3 and #areas[1] == 1 and areas[1][1].group == 1 and areas[3][1].group == 2,
    "the objectives' spawns as areas, in a stable order: " .. #areas)
  local clock = 1000
  time = function() return clock end
  local function at(node, x, y) return node and math.abs(node.x - x) < 1e-6 and math.abs(node.y - y) < 1e-6 end

  -- Clear the camp at 60,60 (a minute there) and walk off: on to another,
  -- the one on the way to the hand-in (Scouts at 30,30; Oslow at 36,30).
  player.x, player.y = 0.62, 0.6
  here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Murloc Sweep", stops = ns.Journey.QuestStops(43, here) }))
  ns.HUD.Update()
  check(ns.Nav.InArea(), "in the first camp")
  clock = clock + 60
  local before = #chat
  player.x, player.y = 0.6, 0.4
  ns.HUD.Update()
  local stop = ns.Nav.CurrentStep().stop
  check(stop.action.kind == "complete" and not ns.Nav.InArea() and at(stop.node, 0.3, 0.3),
    string.format("left a cleared camp: on to the one on the way, not back (%.2f, %.2f)", stop.node.x, stop.node.y))
  check(table.concat(chat, "\n", before + 1):find("cleared: on to another for Murloc Sweep", 1, true),
    "and says so")
  check(ns.HUD.Lines()[4]:find("Next spot", 1, true), "the box says it's the next spot: " .. ns.HUD.Lines()[4])
  check(ns.Journey.ClearedAreas(stop) == 1, "one area cleared")
  -- /ww plan: the areas the data has for it, which is cleared, which is aimed for.
  local planText = ns.PlanReport.Build()
  check(planText:find("Do Murloc Sweep", 1, true) and planText:find("areas in the data: 3", 1, true)
    and planText:find("cleared lately", 1, true) and planText:find("aimed for", 1, true)
    and planText:find("left a cleared spot of Do Murloc Sweep", 1, true),
    "the plan report lists the quest's areas, the cleared one, and the re-plan:\n" .. planText)

  -- Back in the cleared camp: still the area. A short step out again points
  -- at the nearest camp not cleared, though the cleared one is nearer.
  player.x, player.y = 0.62, 0.6
  ns.HUD.Update()
  check(ns.Nav.InArea(), "a cleared camp is still the area when you're in it")
  clock = clock + 5
  player.x, player.y = 0.6, 0.4
  ns.HUD.Update()
  check(at(ns.Nav.CurrentStep().to, 0.3, 0.3), "a short step out doesn't point back at a cleared camp")
  ns.Nav.Recalculate()
  check(at(ns.Nav.CurrentStep().stop.node, 0.3, 0.3), "nor does planning the trip again (a stop done on the way)")

  -- Remembered with the trip, and for about a respawn.
  local saved = ns.Journey.Save(ns.Nav.active.journey)
  local loaded = ns.Journey.Load(saved)
  local doStop
  for _, s in ipairs(loaded.stops) do if s.action.kind == "complete" then doStop = s end end
  check(doStop and doStop.worked and doStop.worked[1] == 1060, "the trip saves the cleared camps")
  doStop.worked = { [1] = clock - 100, [2] = clock - 10, [3] = clock - 50 }
  check(at(ns.Journey.PickArea(doStop, ns.Geo.PlayerNode()), 0.6, 0.6),
    "all cleared: the one cleared longest ago (it respawns first)")
  clock = clock + 400
  check(ns.Journey.ClearedAreas(doStop) == 0, "after a respawn nothing counts as cleared")

  -- Another quest's camp on the way: making progress there makes it the next stop.
  NPCS[9150] = { name = "Redridge Gnoll", minLevel = 18, maxLevel = 19, spawns = { [44] = { { 90, 20 } } } }
  QUESTS[46] = { name = "Gnoll Patrol", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9150 } } } }
  refreshData()
  local log = { 43, 46 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  local gnolls = { { text = "Redridge Gnoll slain: 0/6", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 43 and objectives or id == 46 and gnolls or {} end
  ns.Nav.Stop()
  player.x, player.y = 0.62, 0.6
  here = ns.Geo.PlayerNode()
  local trip = ns.Journey.QuestStops(43, here)
  for _, s in ipairs(ns.Journey.QuestStops(46, here)) do trip[#trip + 1] = s end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge", stops = trip }))
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop.action.questID == 43 and ns.Nav.InArea(), "doing the murlocs first")
  player.x, player.y = 0.62, 0.45
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop.action.questID == 43 and not ns.Nav.InArea(), "stepped out of the murloc camp")
  player.x, player.y = 0.9, 0.2
  fire("QUEST_LOG_UPDATE")
  check(ns.Nav.CurrentStep().stop.action.questID == 43, "in the gnoll camp, nothing done there yet: murlocs still next")
  before = #chat
  gnolls[1] = { text = "Redridge Gnoll slain: 1/6", finished = false }
  fire("QUEST_LOG_UPDATE")
  local current = ns.Nav.CurrentStep().stop
  check(current.action.questID == 46 and current.action.kind == "complete",
    "a gnoll killed there: the gnolls are the next stop")
  check(table.concat(chat, "\n", before + 1):find("you're doing Gnoll Patrol here", 1, true), "and it says so")
  ns.HUD.Update()
  check(ns.Nav.InArea() and ns.Nav.CurrentStep().stop.action.questID == 46, "in their area, no arrow")
  local murlocs
  for _, s in ipairs(ns.Nav.active.journey.stops) do
    if s.action and s.action.questID == 43 and s.action.kind == "complete" then murlocs = s end
  end
  check(murlocs and not murlocs.done, "the murlocs are still on the trip")

  -- One camp, cleared: other stops first while it respawns, not straight back.
  NPCS[9151] = { name = "Tarantula", minLevel = 18, maxLevel = 19, spawns = { [44] = { { 70, 40 } } } }
  QUESTS[47] = { name = "Spider Legs", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9151 } } } }
  refreshData()
  log = { 47 }
  local spiders = { { text = "Tarantula slain: 3/10", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 47 and spiders or {} end
  ns.Nav.Stop()
  player.x, player.y = 0.7, 0.4
  here = ns.Geo.PlayerNode()
  trip = ns.Journey.QuestStops(47, here)
  local errand = { node = ns.Geo.Node(1433, 0.2, 0.8, "Lakeshire docks"), text = "Go to Lakeshire docks" }
  trip[#trip + 1] = errand
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Spiders", stops = trip }))
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop.action.questID == 47 and ns.Nav.InArea(), "in the only spider camp")
  clock = clock + 60
  before = #chat
  player.x, player.y = 0.7, 0.55
  ns.HUD.Update()
  local spiderStop
  for _, s in ipairs(ns.Nav.active.journey.stops) do if s.action and s.action.kind == "complete" then spiderStop = s end end
  check(ns.Nav.active.journey.stops[1] == errand and spiderStop and ns.Journey.RespawnIn(spiderStop) == 300,
    "left it cleared: the errand first while it respawns, though the camp is nearer")
  check(table.concat(chat, "\n", before + 1):find("other stops first while it respawns", 1, true), "and says so")
  clock = clock + 400
  check(ns.Journey.RespawnIn(spiderStop) == 0, "respawned: no wait")
  ns.Nav.Recalculate()
  check(ns.Nav.CurrentStep().stop == spiderStop, "and the camp is next again, being nearest")
  -- With nothing else to do, the way goes back and the box says when it respawns.
  ns.Nav.Stop()
  spiderStop.worked, spiderStop.inArea = { [1] = clock - 100 }, nil
  ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Spiders", stops = { spiderStop } }))
  ns.HUD.Update()
  check(ns.HUD.Lines()[4]:find("Respawns in ~3 min", 1, true), "the box says when it respawns: " .. ns.HUD.Lines()[4])
  local walk = ns.Router.Plan(ns.Geo.PlayerNode(), spiderStop.node, ns.Network.Build()).seconds
  check(walk < 200 and ns.Nav.active.journey.seconds == 200 and ns.Nav.RemainingSeconds(ns.Geo.PlayerNode()) == 200,
    string.format("the trip's time waits for the respawn: %.0f s, not the %.0f s walk", ns.Nav.active.journey.seconds, walk))
  clock = clock + 150
  check(ns.Nav.RemainingSeconds(ns.Geo.PlayerNode()) == 50, "and the wait shrinks as it respawns")
  clock = clock + 100
  check(math.abs(ns.Nav.RemainingSeconds(ns.Geo.PlayerNode()) - walk) < 1, "respawned: just the walk")

  -- Nameplates: the murlocs in sight. Killing there, then none left you could
  -- kill (one tapped by someone else): the camp looks cleared, sooner than 30 s.
  log = { 43 }
  objectives[1] = { text = "Murloc Forager slain: 2/8", finished = false }
  objectives[2] = { text = "Murloc Scout slain: 0/5", finished = false }
  C_QuestLog.GetQuestObjectives = function(id) return id == 43 and objectives or {} end
  local units = { nameplate1 = { id = 9101 }, nameplate2 = { id = 9101, taken = true }, nameplate3 = { id = 1234 } }
  local savedGUID, savedName = UnitGUID, UnitName
  C_NamePlate = { GetNamePlateForUnit = function() return nil end, GetNamePlates = function()
    local out = {}
    for token in pairs(units) do out[#out + 1] = { namePlateUnitToken = token } end
    return out
  end }
  UnitGUID = function(u) return units[u] and ("Creature-0-1-0-2-" .. units[u].id .. "-AB") or savedGUID(u) end
  UnitName = function(u) return units[u] and "A murloc" or savedName(u) end
  UnitIsDead = function(u) return units[u] and units[u].dead or false end
  UnitIsTapDenied = function(u) return units[u] and units[u].taken or false end
  ns.Nav.Stop()
  clock = 5000
  player.x, player.y = 0.62, 0.6
  here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Murloc Sweep", stops = ns.Journey.QuestStops(43, here) }))
  ns.HUD.Update()
  local camp = ns.Nav.CurrentStep().stop
  check(ns.Nav.InArea() and ns.Camps.InSight(43) == 1, "in the camp: one murloc in sight you could kill")
  local function kill(n, at)
    objectives[1] = { text = "Murloc Forager slain: " .. n .. "/8", finished = false }
    clock = at
    ns.HUD.Update()
  end
  kill(3, 5005)
  kill(4, 5010)
  check(ns.Camps.TimeLeft(camp) == 45 and ns.HUD.Lines()[4]:find("<1 min left here", 1, true),
    "two kills in 10 s, 9 to go: the time left here: " .. ns.HUD.Lines()[4])
  check(ns.Nav.RemainingSeconds(ns.Geo.PlayerNode()) >= 45, "and the trip's time counts it")
  units.nameplate1 = nil
  kill(5, 5012)
  check(not ns.Camps.LooksCleared(camp), "none left to kill just now: not cleared yet")
  clock = 5022
  ns.HUD.Update()
  check(ns.Camps.LooksCleared(camp) and ns.HUD.Lines()[4]:find("Camp looks cleared", 1, true),
    "none for 10 s: the camp looks cleared: " .. ns.HUD.Lines()[4])
  before = #chat
  clock = 5023
  player.x, player.y = 0.6, 0.4
  ns.HUD.Update()
  check(ns.Journey.ClearedAreas(ns.Nav.CurrentStep().stop) == 1
    and table.concat(chat, "\n", before + 1):find("cleared: on to another", 1, true),
    "leaving after 23 s counts it as cleared, because it looked it")

  -- Without nameplates the game will show: by the time there, as before.
  C_NamePlate = nil
  local scouts = ns.Nav.CurrentStep().stop
  player.x, player.y = 0.31, 0.3
  ns.HUD.Update()
  clock = 5030
  objectives[2] = { text = "Murloc Scout slain: 1/5", finished = false }
  ns.HUD.Update()
  check(ns.Nav.InArea() and not ns.Camps.LooksCleared(scouts) and ns.Camps.InSight(43) == nil,
    "no nameplates: nothing in sight, never looks cleared")

  -- Dying there and releasing: not leaving the camp, not a reason to re-plan.
  clock = 5100
  local deadNow = true
  UnitIsDeadOrGhost = function() return deadNow end
  fire("PLAYER_DEAD")
  local to = ns.Nav.CurrentStep().to
  before = #chat
  player.x, player.y = 0.9, 0.9
  ns.HUD.Update()
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop == scouts and ns.Nav.CurrentStep().to == to and not ns.Nav.InArea()
    and ns.Journey.ClearedAreas(scouts) == 1 and #chat == before,
    "released to a graveyard: the camp isn't cleared, the trip is as it was")
  deadNow = false
  fire("PLAYER_UNGHOST")
  ns.HUD.Update()
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop == scouts and ns.Nav.CurrentStep().to == to and #chat == before,
    "alive again at the spirit healer: still no re-plan, the way goes back to the camp")
  player.x, player.y = 0.31, 0.3
  ns.HUD.Update()
  check(ns.Nav.InArea() and scouts.visit and scouts.visit.since == 5100, "back in the camp: a new visit")
  -- Move on in a camp: it's cleared now, whatever the time there.
  check(ns.Nav.MoveOnKind() == "cleared", "in a camp, move on clears it")
  before = #chat
  ns.Nav.MoveOn()
  check(ns.Journey.Cleared(scouts, 3) and not ns.Nav.InArea()
    and table.concat(chat, "\n", before + 1):find("cleared: on to another for Murloc Sweep", 1, true)
    and at(ns.Nav.CurrentStep().stop.node, 0.8, 0.8), "and the trip goes on to the camp not cleared yet")
  ns.HUD.Update()
  check(not ns.Nav.InArea() and ns.HUD.ArrowShown(), "still standing in it: not the area now, the arrow shows the way")
  player.x, player.y = 0.31, 0.6
  ns.HUD.Update()
  player.x, player.y = 0.31, 0.3
  ns.HUD.Update()
  check(ns.Nav.InArea(), "walk out and back: it's the area again")

  -- Another spot (the directions box's button, beside the objectives): the
  -- spot it's headed for is left alone for a while, on to another.
  ns.Nav.Stop()
  clock = clock + 1000
  player.x, player.y = 0.5, 0.5
  here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Murloc Sweep", stops = ns.Journey.QuestStops(43, here) }))
  ns.HUD.Update()
  local hud = ns.HUD.Frame()
  local sweep = ns.Nav.CurrentStep().stop
  check(sweep.action.kind == "complete" and ns.Nav.CanOtherArea() and hud.otherArea:IsShown()
    and hud.otherArea:GetText() == "Another spot" and ns.HUD.Lines()[5] ~= "",
    "a quest in three spots: Another spot shows beside its objectives")
  local spots, aimed = {}, ns.Journey.AimedArea(sweep)
  spots[aimed] = true
  before = #chat
  hud.otherArea.scripts.OnClick(hud.otherArea)
  check(ns.Nav.CurrentStep().stop == sweep and ns.Journey.Cleared(sweep, aimed) and not spots[ns.Journey.AimedArea(sweep)]
    and table.concat(chat, "\n", before + 1):find("another spot for Murloc Sweep", 1, true),
    "click it: the same stop, at another spot, and it says so")
  spots[ns.Journey.AimedArea(sweep)] = true
  clock = clock + 5
  hud.otherArea.scripts.OnClick(hud.otherArea)
  check(ns.Nav.CurrentStep().stop == sweep and not spots[ns.Journey.AimedArea(sweep)], "again: the third spot")
  -- In one: it counts as cleared, and isn't the area till you've walked out.
  local third = ns.Journey.AimedArea(sweep)
  local node = sweep.node
  player.x, player.y = node.x, node.y
  ns.HUD.Update()
  check(ns.Nav.InArea() and hud.otherArea:IsShown(), "in the third spot: the button's still there")
  clock = clock + 5
  ns.Nav.OtherArea()
  check(not ns.Nav.InArea() and ns.Journey.Cleared(sweep, third) and ns.Nav.CurrentStep().stop == sweep
    and ns.Journey.AimedArea(sweep) ~= third, "click it there: cleared, on to the spot cleared longest ago")
  -- One spot only: no button.
  ns.Nav.Stop()
  local oneSpot = { node = ns.Geo.Node(1433, 0.3, 0.3), text = "Do one", action = { kind = "complete", questID = 99999 } }
  check(ns.Journey.AimedArea(oneSpot) == nil, "a quest with no other spot: nothing to switch to")

  -- The game's own quest marker (Forever) wins over stray spawns in the
  -- data: only the areas near it count, wherever the others are.
  ns.Nav.Stop()
  local savedOnMap, savedLogIndex, savedGetTime = C_QuestLog.GetQuestsOnMap, C_QuestLog.GetLogIndexForQuestID, GetTime
  GetTime = nil -- the marker read fresh each time
  local markerAt = ns.Geo.Node(1433, 0.3, 0.3)
  local continent = ns.Geo.Continents()[markerAt.instance]
  local mx, my = ns.Geo.MapPos(markerAt, continent)
  local markerOn = true
  C_QuestLog.GetLogIndexForQuestID = function(id) return id == 43 and 1 or nil end
  C_QuestLog.GetQuestsOnMap = function(mapID)
    return markerOn and mapID == continent and { { questID = 43, x = mx, y = my } } or {}
  end
  check(ns.Geo.Distance(markerAt, ns.Geo.Node(1433, 0.8, 0.8)) > ns.Journey.MARKER_YARDS
    and ns.Geo.Distance(markerAt, ns.Geo.Node(1433, 0.6, 0.6)) <= ns.Journey.MARKER_YARDS,
    "(the camp at 80,80 is well away from the marker, the one at 60,60 isn't)")
  local nearMarker, farCounted = ns.Journey.OpenAreas(43), false
  for _, area in ipairs(nearMarker) do
    if at(area.nodes[1], 0.8, 0.8) then farCounted = true end
  end
  check(#nearMarker == 2 and not farCounted,
    "with the game's marker on the Scouts' camp, the camp far from it doesn't count: " .. #nearMarker)
  here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Murloc Sweep", stops = ns.Journey.QuestStops(43, here) }))
  local markerText = ns.PlanReport.Build()
  check(markerText:find("far from the game's marker: left out", 1, true), "and the plan report says so:\n" .. markerText)
  ns.Nav.Stop()
  markerOn = false
  check(#ns.Journey.OpenAreas(43) == 3, "without a marker, every camp in the data counts")
  C_QuestLog.GetQuestsOnMap, C_QuestLog.GetLogIndexForQuestID, GetTime = savedOnMap, savedLogIndex, savedGetTime

  -- A big area (a whole island of spawns) isn't cleared by a minute there:
  -- walking off it, the way comes back to it, not on to stray spawns.
  local island = {}
  for k = 0, 9 do island[#island + 1] = { 50 + (k % 5) * 0.4, 85 + math.floor(k / 5) * 0.4 } end
  NPCS[9160] = { name = "Island Wizard", minLevel = 18, maxLevel = 19, spawns = { [44] = island } }
  QUESTS[49] = { name = "Island Sweep", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9160 } } } }
  refreshData()
  C_QuestLog.GetInfo = function() return { questID = 49, isHeader = false } end
  local wizards = { { text = "Island Wizard slain: 2/8", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 49 and wizards or {} end
  player.x, player.y = 0.509, 0.852
  here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Island", stops = ns.Journey.QuestStops(49, here) }))
  ns.HUD.Update()
  local islandStop = ns.Nav.CurrentStep().stop
  check(ns.Nav.InArea() and #ns.Quests.ObjectiveAreas(49)[1] >= 8, "on the island, a big area")
  clock = clock + 60
  player.x, player.y = 0.509, 0.6
  ns.HUD.Update()
  check(not ns.Nav.InArea() and ns.Journey.ClearedAreas(islandStop) == 0 and ns.Journey.RespawnIn(islandStop) == 0,
    "walked off after a minute: not counted as cleared, no respawn wait")

  -- A lone murloc by a bridge, the rest of them down the river: the stray
  -- isn't where the quest is done. Standing by it isn't being in the area,
  -- and the way goes on to the river.
  ns.Nav.Stop()
  local river = {}
  for k = 0, 11 do river[#river + 1] = { 40 + (k % 4) * 0.4, 40 + math.floor(k / 4) * 0.4 } end
  local strayAt = { 60, 40 }
  river[#river + 1] = strayAt
  NPCS[9161] = { name = "River Murloc", minLevel = 18, maxLevel = 19, spawns = { [44] = river } }
  QUESTS[400] = { name = "River Bounty", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9161 } } } }
  refreshData()
  C_QuestLog.GetInfo = function() return { questID = 400, isHeader = false } end
  local fins = { { text = "River Murloc slain: 0/8", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 400 and fins or {} end
  local riverAreas = ns.Quests.ObjectiveAreas(400)
  local strayIndex
  for index, area in ipairs(riverAreas) do
    if #area == 1 then strayIndex = index end
  end
  check(#riverAreas == 2 and strayIndex ~= nil, "(the river camp and the stray are two areas)")
  local riverOpen = ns.Journey.OpenAreas(400)
  check(#riverOpen == 1 and riverOpen[1].index ~= strayIndex and ns.Journey.StrayArea(400, strayIndex),
    "a lone spawn off from the camp isn't one of the quest's areas")
  player.x, player.y = (strayAt[1] + 0.3) / 100, strayAt[2] / 100
  here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "River", stops = ns.Journey.QuestStops(400, here) }))
  ns.HUD.Update()
  local riverStop = ns.Nav.CurrentStep().stop
  check(riverStop.action.kind == "complete" and not ns.Nav.InArea()
    and ns.Geo.Distance(riverStop.node, ns.Geo.Node(1433, 0.41, 0.41)) < 150,
    "standing by the stray: not in the area, headed for the river")
  local riverText = ns.PlanReport.Build()
  check(riverText:find("a stray, the rest are in camps: left out", 1, true), "the plan report says so:\n" .. riverText)
  -- A creature that's only ever a lone spawn here and there keeps them all.
  NPCS[9161].spawns[44] = { { 20, 20 }, { 40, 40 }, { 60, 60 } }
  refreshData()
  check(#ns.Journey.OpenAreas(400) == 3, "lone spawns all over: every one counts")
  ns.Nav.Stop()
  QUESTS[400], NPCS[9161] = nil, nil

  UnitGUID, UnitName, UnitIsDead, UnitIsTapDenied, UnitIsDeadOrGhost = savedGUID, savedName, nil, nil, nil
  QUESTS[49], NPCS[9160] = nil, nil
  time = os.time
  QUESTS[46], NPCS[9150], QUESTS[47], NPCS[9151] = nil, nil, nil, nil
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

  -- Add detour puts a quest into the journey you're on, or starts one.
  ns.Nav.Stop()
  check(cull.actions and cull.actions[1].label == "Start journey", "with no journey on, log rows say Start journey")
  cull.actions[1].run(cull)
  check(ns.Nav.active and ns.Nav.TripHasQuest(50), "with no journey on, Start journey starts one with that quest")
  rows = ns.QuestsPage.Results("")
  check(byID(rows, "log50").actions[1].label == "In journey" and not byID(rows, "picked"),
    "a quest in the journey says In journey; no separate pile of picks")

  -- Adding from a search joins the same journey, re-ordered from here.
  local found = byID(ns.QuestsPage.Results("gnoll patrol"), "quest53")
  check(found and found.actions and found.actions[1].label == "Add detour", "search results have the Add detour action too")
  found.actions[1].run(found)
  local done = byID(ns.QuestsPage.Results("already done"), "quest2")
  check(done and not done.actions, "no Add on a quest you have done")
  local stops = ns.Nav.active.journey.stops
  local order = {}
  for i, st in ipairs(stops) do order[st.action.kind .. st.action.questID] = i end
  check(#stops == 5 and order.pickup53 < order.complete53 and order.complete53 < order.turnin53
    and order.complete50 < order.turnin50 and not order.pickup50,
    "added quests keep their own order inside the one trip: " .. kinds(stops))
  check(ns.Nav.active.title:find(" and 1 more quest$") ~= nil,
    "a journey you put together is named after its quests: " .. ns.Nav.active.title)

  -- In journey takes it out; the hand-in row can join too.
  byID(ns.QuestsPage.Results(""), "log50").actions[1].run()
  check(not ns.Nav.TripHasQuest(50) and ns.Nav.TripHasQuest(53), "In journey takes the quest out again")
  local handinRow = byID(ns.QuestsPage.Results(""), "handin")
  check(handinRow.actions and handinRow.actions[1].label == "Add detour",
    "with a journey on, the hand-in row can be added as a detour")
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
  check(ns.QuestsPage.SummaryText(""):find("Install QuestieDB"), "without QuestieDB: the summary says so")
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
  -- The estimate line of a card's tooltip ("~2,300 XP in ~5 min (trip ...)").
  local function estimate(row)
    for _, d in ipairs(row and row.details or {}) do
      if d.text:find("^~") or d.text:find("^Least travel") then return d.text end
    end
    return ""
  end
  local function xpOf(row)
    local n = estimate(row):match("~([%d,]+) XP")
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

  -- Hand-ins continue what's under way: the continuation on the first page.
  local handin, hi = find(list, "Hand in 2 quests to Watcher Dodds")
  local finishRow = find(list, "Finish ")
  check(handin and hi == 1 and handin.role == "continue" and handin.relevance_parts.progression == 1 and finishRow,
    "quests ready to hand in are the continuation (" .. titles(list) .. ")")
  check(handin and handin.why:find("^Quests ready to hand in") and not handin.why:find("XP"),
    "and the card says so, not XP per minute: " .. tostring(handin and handin.why))
  check(handin and handin.subtitle:find("2 quests ready", 1, true) and xpOf(handin) == 2300,
    "hand-ins: 1,200 + 1,100 XP in the tooltip: " .. estimate(handin))
  check(handin and actions(handin.journey) == "turnin50,turnin51",
    "the hand-in trip waits for each quest to be handed in (" .. actions(handin and handin.journey) .. ")")
  check(handin and estimate(handin):find("2 x 30 s per hand-in", 1, true),
    "tooltip times hand-ins: " .. estimate(handin))
  local function readyIn(list)
    for _, o in ipairs(list) do
      if o.kind == "handin" and o.text:find("^2 quests ready to hand in to Watcher Dodds") then return o end
    end
  end
  local readyObs = readyIn(ns.ForYou.Observations(true))
  check(readyObs and readyObs.action.kind == "detour" and #readyObs.action.stops == 2
    and readyObs.action.stops[1].action.kind == "turnin" and readyObs.action.stop == readyObs.action.stops[1],
    "quests ready to hand in are an observation too, with the hand-in stops as a detour: "
      .. tostring(readyObs and readyObs.text))
  check(not readyIn(ns.ForYou.Observations()),
    "but while the hand-in card is on the first page, Good to know doesn't repeat it")

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
  check(finish and xpOf(finish) == 2700 and estimate(finish):find("left on 2 in your log", 1, true)
    and finish.subtitle:find("2 quests in your log", 1, true),
    "finish trip: full XP, time left only: " .. estimate(finish))
  local fins
  for _, d in ipairs(finish and finish.details or {}) do
    if d.text:find("Murloc Fins") then fins = d.text end
  end
  check(fins and fins:find("~50%% done"), "objective progress shows: " .. tostring(fins))
  check(finish and estimate(finish):find("~8 min left", 1, true),
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
  check(ns.ForYou.SummaryText():find("Quest log: 4 ready to hand in, 2 to finish", 1, true),
    "summary says how the log counts: " .. ns.ForYou.SummaryText())

  -- Training, once affordable, is an observation; the cards stay the journeys.
  GetMoney = savedMoney
  list = rows()
  local trainObs
  for _, o in ipairs(ns.ForYou.Observations()) do if o.kind == "train" then trainObs = o end end
  check(trainObs and trainObs.action.kind == "detour" and not find(list, "Train") and #list <= 9,
    "training once affordable: an observation with a detour, not a card (" .. titles(list) .. ")")

  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]
  LibQuestieDB.Support.Get = zoneSupport
  for id = 50, 54 do QUESTS[id] = nil end
  NPCS[6100] = nil
  refreshData()
  ns.ForYou.Invalidate()
end
---------------------------------------------------------------- for you: quest log (end)
---------------------------------------------------------------- quest times (begin)
do
  io.write("quest times\n")
  local savedTime, clock = time, 100000
  time = function() return clock end
  ns.charDB.questTimes = nil
  local function minutes(n) clock = clock + n * 60 end
  local function quest(id, took)
    fire("QUEST_ACCEPTED", id)
    minutes(took)
    fire("QUEST_TURNED_IN", id)
  end
  fire("PLAYER_ENTERING_WORLD", true, false)
  for i, took in ipairs({ 4, 6, 8, 10 }) do quest(700 + i, took) end
  check(ns.QuestTimes.Seconds() == nil and ns.QuestTimes.Describe(300):find("4 of 5 quests timed", 1, true),
    "under 5 quests timed: no average yet (" .. ns.QuestTimes.Describe(300) .. ")")
  quest(705, 90)
  check(ns.charDB.questTimes.samples[5] == 60, "a quest over an hour counts as 60 min")
  check(math.abs(ns.QuestTimes.Seconds() - (4 + 6 + 8 + 10 + 60) / 5 * 60) < 1e-6,
    "from 5 quests, the average: " .. tostring(ns.QuestTimes.Seconds()))

  -- Quests done side by side share the time: each counts from the last hand-in.
  ns.charDB.questTimes = nil
  fire("QUEST_ACCEPTED", 711)
  fire("QUEST_ACCEPTED", 712)
  fire("QUEST_ACCEPTED", 713)
  minutes(9)
  fire("QUEST_TURNED_IN", 711)
  minutes(6)
  fire("QUEST_TURNED_IN", 712)
  fire("QUEST_TURNED_IN", 713)
  local samples = ns.charDB.questTimes.samples
  check(#samples == 3 and samples[1] == 9 and samples[2] == 6 and samples[3] == 0,
    "three quests at once: 9, 6 and 0 min, not 9, 15 and 15 (" .. table.concat(samples, ",") .. ")")

  -- A logout in between: not counted; a /reload is.
  fire("QUEST_ACCEPTED", 720)
  fire("QUEST_ACCEPTED", 721)
  minutes(5)
  fire("PLAYER_ENTERING_WORLD", false, true)
  minutes(5)
  fire("QUEST_TURNED_IN", 720)
  check(#samples == 4 and samples[4] == 10, "a /reload keeps the quests being timed")
  minutes(600)
  fire("PLAYER_ENTERING_WORLD", true, false)
  minutes(3)
  fire("QUEST_TURNED_IN", 721)
  check(#samples == 4, "a quest accepted before a logout isn't timed")
  fire("QUEST_TURNED_IN", 799)
  check(#samples == 4, "a quest accepted before Wayward saw it isn't timed")

  -- Only the last 20 count.
  for i = 1, 25 do quest(800 + i, i <= 5 and 50 or 7) end
  check(#samples == 20 and math.abs(ns.QuestTimes.Seconds() - 7 * 60) < 1e-6, "a rolling average of the last 20")
  local chat0 = #chat
  SlashCmdList.WAYWARD("debug")
  local said
  for i = chat0 + 1, #chat do if chat[i]:find("quest time: ~7.0 min, the average of your last 20", 1, true) then said = true end end
  check(said, "/ww debug shows the average")

  ns.charDB.questTimes = nil
  time = savedTime
end
---------------------------------------------------------------- quest times (end)
---------------------------------------------------------------- for you: time budget (begin)
do
  io.write("for you: time budget\n")
  ns.Nav.Stop()
  local function rows()
    ns.ForYou.Invalidate()
    return ns.ForYou.Results()
  end
  local function describe(list)
    local out = {}
    for _, r in ipairs(list) do
      out[#out + 1] = string.format("%s [%s] %s", r.title, r.category or "?", r.badge or "-")
    end
    return table.concat(out, " | ")
  end
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives }
  local savedMoney = GetMoney
  GetMoney = function() return 0 end
  NPCS[6100] = { name = "Watcher Dodds", npcFlags = 2, friendlyToFaction = "A", spawns = { [44] = { { 70.0, 70.0 } } } }
  QUESTS[50] = { name = "Watch Report", questLevel = 19, requiredLevel = 15, startedBy = { { 6100 } }, finishedBy = { { 6100 } } }
  QUESTS[51] = { name = "Watch Supplies", questLevel = 18, requiredLevel = 15, startedBy = { { 6100 } }, finishedBy = { { 6100 } } }
  QUESTS[52] = { name = "Solomon's Letter", questLevel = 19, requiredLevel = 15, startedBy = { { 6000 } }, finishedBy = { { 344 } } }
  QUESTS[53] = { name = "Murloc Fins", questLevel = 19, requiredLevel = 15, startedBy = { { 344 } }, finishedBy = { { 345 } },
    objectives = { { { 9101 } } } }
  refreshData()
  local log, complete = { 50, 51, 52, 53 }, { [50] = true, [51] = true, [52] = true }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function(id) return complete[id] == true end
  C_QuestLog.GetQuestObjectives = function() return {} end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  local function find(list, prefix)
    for _, r in ipairs(list) do
      if r.title:sub(1, #prefix) == prefix then return r end
    end
  end
  local function minutesOf(r)
    if not (r and r.badge) then return nil end
    if r.badge == "<1 min" then return 0 end
    return tonumber(r.badge:match("^~(%d+) min$"))
  end
  local function allFit(list, budget)
    for _, r in ipairs(list) do
      local m = minutesOf(r)
      if not m or m > budget then return false end
    end
    return #list > 0
  end

  ns.ForYou.SetBudget(nil)
  local list = rows()
  check(find(list, "Run The Deadmines") and find(list, "Hand in 2 quests to Watcher Dodds") and not list[1].badge
    and not ns.ForYou.SummaryText():find("Fits in"),
    "no budget: the dungeon and the hand-ins, no times on the cards (" .. describe(list) .. ")")

  SlashCmdList.WAYWARD("time 20")
  check(ns.charDB.budgetMinutes == 20, "/ww time 20 sets a 20 minute budget for this character")
  list = rows()
  check(ns.ForYou.SummaryText():find("^Fits in 20 min:"), "the summary says what it fits in: " .. ns.ForYou.SummaryText())
  check(allFit(list, 20), "every card shows its time, all within 20 min (" .. describe(list) .. ")")
  check(not find(list, "Run The Deadmines"), "no dungeon in 20 minutes")
  local handin = find(list, "Hand in")
  check(handin and handin.title == "Hand in 1 quest in Lakeshire" and handin.details[2].text:find("^Least travel of 2 that fit in 20 min"),
    "with a budget, hand-ins by least travel (" .. tostring(handin and handin.details[2].text) .. ")")

  ns.ForYou.SetBudget(60)
  list = rows()
  local deadmines = find(list, "Run The Deadmines")
  check(deadmines and minutesOf(deadmines) and allFit(list, 60), "with an hour, the dungeon fits: " .. describe(list))

  -- From the Wetlands: the finish trip takes just over 10 minutes.
  player.mapID, player.x, player.y = 1437, 0.5, 0.5
  ns.ForYou.SetBudget(10)
  list = rows()
  check(not find(list, "Finish") and find(list, "Quest in Redridge") and allFit(list, 10),
    "what doesn't fit in 10 min is left out (" .. describe(list) .. ")")
  ns.ForYou.SetBudget(15)
  list = rows()
  check(find(list, "Finish") and allFit(list, 15), "in 15 min the finish trip fits (" .. describe(list) .. ")")

  -- Nothing fits in 3 minutes: the quickest anyway, a bit over.
  ns.ForYou.SetBudget(3)
  list = rows()
  check(#list == 1 and list[1].title == "Hand in 1 quest in Lakeshire" and list[1].over
    and list[1].category == "Hand in  ·  a bit over" and list[1].badge == "~4 min",
    "nothing fits: the single quickest option, labelled a bit over (" .. describe(list) .. ")")
  check(ns.ForYou.SummaryText():find("^Nothing to quest fits in 3 min") and list[1].details[1].text:find("^Nothing fits in 3 min"),
    "the page says nothing fits: " .. ns.ForYou.SummaryText())

  -- Your own quest time, once learned, replaces the 5 minutes per quest.
  ns.charDB.questTimes = { samples = { 10, 10, 10, 10, 10 }, accepted = {} }
  ns.ForYou.SetBudget(nil)
  list = rows()
  local finish = find(list, "Finish")
  check(finish and finish.details[2].text:find("~10 min left on 1 in your log", 1, true),
    "the finish trip uses your 10 min average: " .. tostring(finish and finish.details[2].text))
  ns.charDB.questTimes = nil

  -- The buttons by the summary line, and each card's time.
  local wasShown = ns.Panel.IsShown()
  ns.Panel.Search("foryou")
  local buttons = {}
  for _, btn in ipairs(ns.Panel.ControlButtons()) do buttons[btn:GetText()] = btn end
  check(buttons["15"] and buttons["30"] and buttons["60"] and buttons.Any, "For you has 15 / 30 / 60 / Any buttons")
  buttons["30"].scripts.OnClick(buttons["30"])
  check(ns.charDB.budgetMinutes == 30 and ns.ForYou.SummaryText():find("^Fits in 30 min:"), "30 sets a 30 minute budget")
  local badge = ns.Cards.Badge(1)
  check(badge and badge:find("min$") and badge == ns.Cards.Visible()[1].badge, "the cards show their time: " .. tostring(badge))
  buttons.Any.scripts.OnClick(buttons.Any)
  check(ns.charDB.budgetMinutes == nil and ns.Cards.Badge(1) == nil, "Any clears it, and the cards drop their times")
  if not wasShown then ns.Panel.Toggle() end

  SlashCmdList.WAYWARD("time off")
  check(ns.charDB.budgetMinutes == nil and ns.ForYou.Budget() == nil, "/ww time off clears the budget")
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  ns.ForYou.SetBudget(nil)
  GetMoney = savedMoney
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]
  QUESTS[50], QUESTS[51], QUESTS[52], QUESTS[53], NPCS[6100] = nil, nil, nil, nil, nil
  refreshData()
  ns.ForYou.Invalidate()
end
---------------------------------------------------------------- for you: time budget (end)
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
    ui.Movers = { Add = function() end } -- the real panes stay ns's own
    for _, page in ipairs(ns.pages) do
      -- Panel.lua registers its own category pages again.
      if not ({ quests = true, vendors = true, trainers = true, dungeons = true })[page.id] then ui.RegisterPage(page) end
    end
    for _, file in ipairs({ "CopyBox", "HUD", "JourneyOverview", "Panel" }) do
      assert(loadfile(dir .. "/UI/" .. file .. ".lua"))("Wayward", ui)
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
  check(ns.Skin.Status() == "EllesmereUI" and registeredAs == "Wayward", "EllesmereUI skin registered")
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

  -- /ww skin
  local said = #chat
  SlashCmdList.WAYWARD("skin")
  shells = calls.Shell
  openAll(freshUI())
  check(ns.db.settings.skin == false and calls.Shell == shells, "/ww skin turns it off for new windows")
  check(chat[said + 1]:find("skin off; /reload", 1, true) ~= nil, "and says a reload removes it from open ones")
  SlashCmdList.WAYWARD("skin")
  check(ns.db.settings.skin == true and calls.Shell == shells + 3, "/ww skin again paints what was missed")

  CreateFrame, C_XMLUtil, EllesmereUI = savedCreate, nil, nil
  ButtonFrameTemplate_HidePortrait, PanelTemplates_SetTab = nil, nil
  PanelTemplates_SelectTab, PanelTemplates_DeselectTab = nil, nil
end
---------------------------------------------------------------- look (end)
---------------------------------------------------------------- panel scrolling (begin)
do
  io.write("panel scrolling\n")
  local many = {}
  for i = 1, 20 do many[i] = { title = "R" .. i, subtitle = "row " .. i } end
  ns.RegisterPage({ id = "many", label = "Many", order = 99, searchable = true,
    SummaryText = function() return "" end, EmptyText = function() return "" end,
    Results = function(q) return q == "" and many or { many[1] } end })
  ns.Panel.Search("many", "")
  local function first() local v = ns.Panel.VisibleResults() return v[1] and v[1].title, #v end
  local top, count = first()
  check(top == "R1" and count == 11, "eleven results show (the taller window), starting at the first: " .. count)
  ns.Panel.Scroll(-3)
  check(first() == "R4", "scrolling down moves the list")
  ns.Panel.Scroll(-50)
  check(first() == "R10", "scrolling stops at the last page")
  ns.Panel.Refresh()
  check(first() == "R10", "a data refresh keeps your place")
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
  -- (The rows' details name the trainers first, then the spells to learn there: Find.)
  local named = grouped and #grouped.details >= 2 and (grouped.details[1].text .. grouped.details[2].text) or ""
  check(grouped and grouped.title:find("^2 warlock trainers in ") and named:find("Cloyce", 1, true)
    and named:find("Gakin", 1, true), "trainers in the same room are one row: " .. tostring(grouped and grouped.title))
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

  -- Re-planning as you go, with padding: a stop either side of you, and you
  -- skirting the halfway point between them.
  ns.Nav.Stop()
  local liveClock, savedGetTime = 5000, GetTime
  GetTime = function() return liveClock end
  local perUnit = ns.Geo.Distance(ns.Geo.Node(1437, 0.5, 0.5), ns.Geo.Node(1437, 0.6, 0.5)) * 10
  local function stand(yards) -- east of the halfway point (west when negative), a while later
    liveClock = liveClock + 10
    player.mapID, player.x, player.y = 1437, 0.5 + yards / perUnit, 0.5
    ns.HUD.Update()
  end
  local westBank = { node = ns.Geo.Node(1437, 0.3, 0.5, "West bank"), text = "Go to West bank" }
  local eastBank = { node = ns.Geo.Node(1437, 0.7, 0.5, "East bank"), text = "Go to East bank" }
  player.mapID, player.x, player.y = 1437, 0.5 - 10 / perUnit, 0.5
  ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Banks", stops = { eastBank, westBank } }))
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop == westBank, "the nearer bank first")
  local pad = ns.Journey.STICK_YARDS / 2
  stand(pad - 10)
  check(ns.Nav.CurrentStep().stop == westBank, "past the halfway point, inside the padding: the west bank still")
  before = #chat
  stand(pad + 15)
  check(ns.Nav.CurrentStep().stop == eastBank, "well past it: the east bank is next, re-planned as you go")
  check(#chat > before and chat[#chat]:find("Go to East bank is next now", 1, true), "and it says so: " .. chat[#chat])
  stand(-(pad - 10))
  check(ns.Nav.CurrentStep().stop == eastBank, "back over the halfway point, inside the padding: no flip back")
  stand(-(pad + 15))
  check(ns.Nav.CurrentStep().stop == westBank, "well back the other way: the west bank again")
  -- /ww plan: copied, with why re-planning waits, both orders and the re-plans.
  local reportCopied
  local realCopyBox = ns.ShowCopyBox
  ns.ShowCopyBox = function(_, text) reportCopied = text end
  SlashCmdList.WAYWARD("plan")
  ns.ShowCopyBox = realCopyBox
  check(reportCopied and reportCopied:find("Journey: Banks", 1, true)
    and reportCopied:find("Re-planning as you go: looked 0 s ago", 1, true)
    and reportCopied:find("1. Go to West bank", 1, true) and reportCopied:find("same order: a re-plan now keeps it", 1, true)
    and reportCopied:find("re-plan as you go: next Go to East bank instead of Go to West bank", 1, true)
    and reportCopied:find("re-plan as you go: next Go to West bank instead of Go to East bank", 1, true),
    "/ww plan copies the report:\n" .. tostring(reportCopied))
  -- Not every frame: the next look waits a few seconds.
  player.x = 0.5 + (pad + 15) / perUnit
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop == westBank, "a moment later: not re-planned yet")
  stand(pad + 15)
  check(ns.Nav.CurrentStep().stop == eastBank, "a few seconds on: it is")
  -- A stop out on a spur (there and back whichever way): planned first from
  -- out there, then you walk back. It costs about the same first or later,
  -- so the stop by you goes first, not the far one.
  ns.Nav.Stop()
  local farStop = { node = ns.Geo.Node(1437, 0.7, 0.5, "Far camp"), text = "Go to Far camp" }
  local byStop = { node = ns.Geo.Node(1437, 0.5, 0.5, "Near camp"), text = "Go to Near camp" }
  local homeStop = { node = ns.Geo.Node(1437, 0.2, 0.5, "Home camp"), text = "Go to Home camp" }
  player.mapID, player.x, player.y = 1437, 0.66, 0.5
  ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Spur", stops = { byStop, homeStop, farStop } }))
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop == farStop, "out by the far camp: it comes first")
  before = #chat
  stand(pad - 5) -- just on the spur side of the near camp
  check(ns.Nav.CurrentStep().stop == byStop, "walked back to the near camp: it's next, not the far one")
  check(#chat > before and chat[#chat]:find("Go to Near camp is next now", 1, true), "and it says so")
  check(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Spur", stops = { farStop, homeStop, byStop } })
    .stops[1] == byStop, "planned fresh from there, the near camp comes first too")

  -- Pinned (the overview's lock): a stop keeps its place while the rest
  -- re-plans around it.
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1437, 0.66, 0.5
  ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Spur", stops = { byStop, homeStop, farStop } }))
  ns.JourneyOverview.Show()
  ns.HUD.Update()
  local pinsShown, pinsOn = ns.JourneyOverview.PinCount()
  check(ns.Nav.CurrentStep().stop == farStop and pinsShown == 3 and pinsOn == 0,
    string.format("each open stop has a pin, none on (%d, %d)", pinsShown, pinsOn))
  check(ns.Nav.TogglePin(farStop) and select(2, ns.JourneyOverview.PinCount()) == 1, "pin the far camp")
  stand(pad - 5)
  check(ns.Nav.CurrentStep().stop == farStop, "walked back to the near camp: the pinned far camp stays next")
  local pinSaved = ns.Journey.Load(ns.Journey.Save(ns.Nav.active.journey))
  local savedFar, savedBy
  for _, s in ipairs(pinSaved.stops) do
    if s.text == "Go to Far camp" then savedFar = s elseif s.text == "Go to Near camp" then savedBy = s end
  end
  check(savedFar and savedFar.pinned and savedBy and savedBy.pinnedBy and savedBy.pinnedBy[1] == savedFar,
    "the pin is saved with the journey")
  check(ns.Nav.TogglePin(farStop) and select(2, ns.JourneyOverview.PinCount()) == 0, "unpin it")
  stand(-(pad - 5))
  check(ns.Nav.CurrentStep().stop == byStop, "unpinned: the next re-plan puts the near camp first again")
  -- Pinning a later stop keeps the ones ahead of it ahead.
  ns.Nav.Stop()
  player.x = 0.66
  ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Spur", stops = { byStop, homeStop, farStop } }))
  ns.JourneyOverview.Show()
  ns.HUD.Update()
  check(ns.Nav.active.journey.stops[2] == byStop and ns.Nav.TogglePin(byStop), "pin the near camp, second")
  stand(pad - 5)
  check(ns.Nav.CurrentStep().stop == farStop and ns.Nav.active.journey.stops[2] == byStop,
    "by the near camp: the far camp stays ahead of it")
  -- Moving on from a pinned stop unpins it; so does dragging (your whole order).
  ns.Nav.TogglePin(farStop)
  ns.Nav.MoveOn()
  check(not ns.Journey.IsPinned(farStop) and ns.Journey.IsPinned(byStop), "moving on from a pinned stop unpins it")
  ns.Nav.MoveStop(homeStop, ns.Nav.active.journey.stops[1])
  pinsShown, pinsOn = ns.JourneyOverview.PinCount()
  check(not ns.Journey.IsPinned(byStop) and pinsShown == 0,
    "dragging a stop: your order, no pins (" .. pinsShown .. " shown)")

  -- Your own order (dragged in the overview) is never re-planned away.
  ns.Nav.Stop()
  ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Banks", stops = { eastBank, westBank } }))
  stand(pad + 15)
  check(ns.Nav.CurrentStep().stop == eastBank, "the east bank first again")
  check(ns.Nav.MoveStop(westBank, eastBank) and ns.Nav.CurrentStep().stop == westBank, "you put the west bank first")
  stand(pad + 40)
  check(ns.Nav.CurrentStep().stop == westBank, "and it stays first, though the east bank is nearer")
  ns.Nav.Stop()
  GetTime = savedGetTime

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
  check(ns.Options.AskTomTom() and asked == "WAYWARD_TOMTOM" and not ns.Nav.UsingTomTom(),
    "with TomTom installed, Wayward asks whether to use its arrow")
  StaticPopupDialogs.WAYWARD_TOMTOM.OnCancel(nil, nil, "clicked")
  check(ns.db.settings.tomtom == false and not ns.Options.AskTomTom(), "No thanks: off, and not asked again")
  StaticPopupDialogs.WAYWARD_TOMTOM.OnAccept()
  check(ns.db.settings.tomtom == true and ns.db.settings.showArrow == false, "Use TomTom: on, and the compass off")
  ns.SetSetting("showArrow", true)
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
  SlashCmdList.WAYWARD("compass")
  check(not ns.HUD.CompassShown() and ns.HUD.Width() < 330, "compass off: no circle, a narrower box")
  SlashCmdList.WAYWARD("compass")
  check(ns.HUD.CompassShown() and ns.HUD.Width() == 330, "and back")
  fire("TAXIMAP_OPENED")
  check(#added == 2 and removed == 1, "each step replaces the TomTom waypoint")
  ns.Nav.Stop()
  check(removed == 2, "stopping clears it")
  SlashCmdList.WAYWARD("tomtom")
  check(not ns.Nav.UsingTomTom(), "/ww tomtom turns it off")
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  pinCheck(ns.Nav.ownsWaypoint, "TomTom off: the game's map pin shows the way")
  SlashCmdList.WAYWARD("tomtom")
  check(ns.Nav.UsingTomTom() and #added == 3, "turning it on during a trip moves the waypoint to TomTom")
  pinCheck(not ns.Nav.ownsWaypoint and waypoints[#waypoints] == "cleared", "and takes down the map pin we put up")
  ns.Nav.Stop()
  TomTom.AddWaypoint = function() error("old TomTom") end
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(not ns.Nav.UsingTomTom() and ns.Nav.active, "a TomTom that fails falls back to our own arrow")
  pinCheck(#waypoints > blizzard, "and the game's map pin")
  ns.Nav.Stop()

  -- The game's map pin outlasts a reload: ours from last time comes down.
  TomTom.AddWaypoint = function(_, mapID, x, y, opts) added[#added + 1] = { mapID = mapID, opts = opts } return { #added } end
  ns.Nav.ResetTomTom()
  if not ERA then
  local function reload(userPin)
    -- A fresh UI: nothing on, the trip and the pin still saved.
    ns.Nav.active, ns.Nav.ownsWaypoint, ns.Nav.tomtomWaypoint = nil, false, nil
    C_Map.GetUserWaypoint = function() return userPin end
    fire("PLAYER_ENTERING_WORLD", false, true)
    runTimers()
  end
  ns.db.settings.tomtom = false
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  local pin = ns.charDB.pin
  check(pin and pin.mapID and ns.Nav.ownsWaypoint, "where our map pin is gets saved")
  ns.db.settings.tomtom = true
  local before = #waypoints
  reload({ uiMapID = pin.mapID, position = vec(pin.x, pin.y) })
  check(ns.Nav.active and ns.Nav.tomtomWaypoint and #waypoints == before + 1 and waypoints[#waypoints] == "cleared"
    and not ns.Nav.ownsWaypoint and ns.charDB.pin == nil, "resumed with TomTom on: our old map pin comes down")
  ns.Nav.Stop()
  ns.db.settings.tomtom = false
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  pin = ns.charDB.pin
  ns.charDB.nav = nil
  before = #waypoints
  reload({ uiMapID = pin.mapID, position = vec(pin.x, pin.y) })
  check(not ns.Nav.active and #waypoints == before + 1 and waypoints[#waypoints] == "cleared" and ns.charDB.pin == nil,
    "no trip to resume: our old map pin comes down")
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  pin = ns.charDB.pin
  ns.charDB.nav = nil
  before = #waypoints
  reload({ uiMapID = pin.mapID, position = vec(pin.x + 0.1, pin.y) })
  check(#waypoints == before and ns.charDB.pin == nil, "a pin you placed yourself since stays")
  ns.Nav.Stop()
  C_Map.GetUserWaypoint = nil
  end
  ns.db.settings.tomtom = true

  -- TomTom's corpse waypoint comes down once you're alive, also when its
  -- corpse search puts it back up a moment later.
  do
    local corpse = { 1433, 0.4, 0.4, title = "My Corpse", corpse = true }
    local other = { 1433, 0.6, 0.6, title = "Elsewhere" }
    local gone = {}
    TomTom.waypoints = { [1433] = { c = corpse, o = other } }
    TomTom.RemoveWaypoint = function(_, uid)
      gone[uid] = true
      for _, byKey in pairs(TomTom.waypoints) do
        for k, v in pairs(byKey) do if v == uid then byKey[k] = nil end end
      end
    end
    local wasDead = UnitIsDeadOrGhost
    local deadNow = true
    UnitIsDeadOrGhost = function() return deadNow end
    fire("PLAYER_DEAD")
    runTimers()
    check(not gone[corpse], "dead: TomTom's corpse waypoint stays")
    deadNow = false
    fire("PLAYER_UNGHOST")
    check(gone[corpse] and not gone[other], "alive again: TomTom's corpse waypoint comes down, other waypoints stay")
    local again = { 1433, 0.4, 0.4, title = "My Corpse", corpse = true }
    TomTom.waypoints[1433].c = again
    runTimers()
    check(gone[again], "and again, when TomTom's corpse search puts it back up")
    UnitIsDeadOrGhost = wasDead
    TomTom.waypoints = nil
  end
  TomTom = nil

  -- Minimap button and addon compartment.
  Minimap = CreateFrame("Frame")
  GetCursorPosition = function() return 0, 0 end
  fire("PLAYER_LOGIN")
  check(ns.MinimapButton.IsShown(), "a minimap button appears")
  SlashCmdList.WAYWARD("minimap")
  check(not ns.MinimapButton.IsShown(), "/ww minimap hides it")
  SlashCmdList.WAYWARD("minimap")
  local wasShown = ns.Panel.IsShown()
  Wayward_OnAddonCompartmentClick(nil, "LeftButton")
  check(ns.Panel.IsShown() ~= wasShown, "the addon compartment entry opens the panel")
  local chatBefore = #chat
  Wayward_OnAddonCompartmentClick(nil, "RightButton")
  check(#chat > chatBefore and chat[#chat]:find("options:", 1, true) and ns.Panel.IsShown() ~= wasShown,
    "right-click opens the options (a chat line without the Settings API)")
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
    "opening a flight map tells Wayward about that continent only")
  ns.charDB.knownTaxi, ns.charDB.taxiSeen = known, seen

  -- TomTom waypoints say what to do, not the flight path's name.
  local titles = {}
  SlashCmdList.WAYWARD("tomtom")
  SlashCmdList.WAYWARD("tomtom") -- off and on again: retries TomTom after the earlier failure
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
  check(ns.Nav.active.title == "Stormwind errands", "a detour keeps the journey's name: " .. ns.Nav.active.title)
  check(not ns.JourneyOverview.IsShown() and ns.HUD.Flashing(),
    "adding to a trip doesn't open the overview; the book button flashes instead")
  local hud = ns.HUD.Frame()
  for _ = 1, 30 do hud.scripts.OnUpdate(hud, 0.1) end
  check(not ns.HUD.Flashing(), "and stops after a few pulses")
  ns.JourneyOverview.Show()
  ns.Nav.AddToTrip({ stopAt(1439, 0.6, 0.5, "Dock") }, "Dock")
  check(ns.JourneyOverview.IsShown() and not ns.HUD.Flashing() and #ns.JourneyOverview.Rows() == 3,
    "with the overview open it shows the new stop, no flash")
  ns.Nav.Stop()

  -- Starting something while a journey is on asks: add as a detour, switch journey, or cancel.
  local shown
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which, a, b, data) shown = { which = which, trip = a, label = b, data = data } end
  ns.charDB.journeys = nil
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Stormwind errands", stops = { stopAt(1453, 0.5, 0.5, "Bank") } }))
  local other = ns.Journey.Plan(here, { title = "Shore run", stops = { stopAt(1439, 0.55, 0.5, "Shore camp") } })
  ns.Nav.StartJourney(other)
  check(shown and shown.which == "WAYWARD_TRIP" and shown.trip == "Stormwind errands" and shown.label == "Shore run"
    and StaticPopupDialogs.WAYWARD_TRIP.button1 == "Add as detour" and StaticPopupDialogs.WAYWARD_TRIP.button3 == "Switch journey"
    and StaticPopupDialogs.WAYWARD_TRIP.button2 == "Cancel", "starting a journey during a journey asks first: detour, switch or cancel")
  check(ns.Nav.active.title == "Stormwind errands", "nothing changes until you answer (Cancel keeps the journey)")
  shown.data.add()
  check(labels() == "Shore camp,Bank", "Add as detour merges it into the current journey")
  shown = nil
  local trainer = ns.Trainers.Results()[1]
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  check(shown and shown.label == trainer.title, "plain directions ask too")
  shown.data.switch()
  check(ns.Nav.active.title == trainer.title and not ns.Nav.active.journey, "Switch journey starts the new directions instead")
  check(#ns.Nav.SetAsideList() == 1 and not ns.Journey.IsGenericTitle(ns.Nav.SetAsideList()[1].title)
    and ns.Nav.SetAsideList()[1].stops == 2,
    "and sets the journey aside, with its 2 stops left: " .. tostring(ns.Nav.SetAsideList()[1] and ns.Nav.SetAsideList()[1].title))
  ns.charDB.journeys = nil

  -- Plain directions become a journey when something is added.
  shown = nil
  ns.Nav.AddToTrip({ stopAt(1439, 0.55, 0.5, "Shore camp") }, "Shore camp")
  check(not shown and ns.Nav.active.journey and #ns.Nav.active.journey.stops == 2 and ns.Nav.active.journey.kind == "custom",
    "adding to plain directions makes a custom journey with both: " .. (ns.Nav.active.journey and labels() or "-"))

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

  local function shape()
    local out = {}
    for _, line in ipairs(ns.JourneyOverview.Lines()) do
      if not line.step then
        out[#out + 1] = line.header and ("finished" .. line.count .. (line.folded and "+" or "-")) or line.row.state
      end
    end
    return table.concat(out, ",")
  end
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
  local function fold(title)
    player.x = 0.5
    ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = title, stops = {
      stopAt(0.52, "F1"), stopAt(0.55, "F2"), stopAt(0.58, "F3"), stopAt(0.61, "F4"), stopAt(0.64, "F5") } }))
    local f = ns.Nav.active.journey.stops
    return f[1], f[2], f[3], f[4]
  end
  local function visit(stop)
    player.x, player.y = stop.node.x, stop.node.y
    ns.HUD.Update()
  end
  local f1, f2, f3, f4 = fold("Fold")
  visit(f1)
  visit(f2)
  check(shape() == "finished2-,done,done,now,next,next", "under three: shown, under a line for them: " .. shape())
  ns.Nav.Drop(f3)
  check(shape() == "finished2-,done,done,now,next", "a skipped stop isn't listed at all: " .. shape())
  visit(f4)
  check(shape() == "finished3+,now", "three finished: folded by themselves: " .. shape())
  f1, f2, f3, f4 = fold("Fold again")
  visit(f1)
  visit(f2)
  ns.JourneyOverview.ToggleFinished()
  check(shape() == "finished2+,now,next,next", "click the line to fold them: " .. shape())
  ns.JourneyOverview.ToggleFinished()
  check(shape() == "finished2-,done,done,now,next,next", "and again to show them")
  visit(f3)
  check(shape() == "finished3-,done,done,done,now,next", "your choice holds for this trip: " .. shape())
  player.x, player.y = 0.5, 0.5
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
---------------------------------------------------------------- move on and skip (begin)
do
  io.write("move on and skip\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1439, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local function stopAt(x, label) return { node = ns.Geo.Node(1439, x, 0.5, label), text = "Visit " .. label } end
  local function labels()
    local out = {}
    for _, st in ipairs(ns.Nav.active.journey.stops) do out[#out + 1] = st.node.label end
    return table.concat(out, ",")
  end
  local pickup = { node = ns.Geo.Node(1439, 0.52, 0.5, "Giver"), text = "Pick up Q", action = { kind = "pickup", questID = 882 } }
  local turnin = { node = ns.Geo.Node(1439, 0.54, 0.5, "Finisher"), text = "Hand in Q", after = { pickup },
    action = { kind = "turnin", questID = 882 } }
  local far = stopAt(0.6, "Far")
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = { pickup, turnin, far } }))
  check(labels() == "Giver,Finisher,Far", "planned nearest first: " .. labels())
  ns.HUD.Update()
  local f = ns.HUD.Frame()
  check(f.moveOn:IsShown() and f.skip:IsShown() and f.next == nil and f.prev == nil,
    "a trip's box has move on and skip, no next or back")
  local function tip(b) b.scripts.OnEnter(b) return GameTooltip:GetText() end
  check(tip(f.moveOn) == "Do this stop later" and tip(f.skip) == "Skip this stop"
    and tip(f.list) == "View details" and tip(f.close) == "End journey", "the buttons' tooltips")

  -- The x on a journey asks first; Keep going (or Escape) leaves it on.
  do
    local asked
    StaticPopupDialogs = {}
    StaticPopup_Show = function(which, text, _, data) asked = { which = which, text = text, data = data } end
    local journey = ns.Nav.active
    f.close.scripts.OnClick(f.close)
    check(asked and asked.which == "WAYWARD_END" and ns.Nav.active == journey
      and asked.text:find('End "Errands"?', 1, true) and asked.text:find("done 0 of 3 stops", 1, true)
      and StaticPopupDialogs.WAYWARD_END.button1 == "End journey" and StaticPopupDialogs.WAYWARD_END.button2 == "Keep going",
      "ending a journey asks first, and nothing changes until you answer: " .. tostring(asked and asked.text))
    StaticPopupDialogs.WAYWARD_END.OnAccept(nil, { active = {} })
    check(ns.Nav.active == journey, "a stale yes (another journey since) ends nothing")
    local fanfare = ns.Fanfare.lastTrip
    StaticPopupDialogs.WAYWARD_END.OnAccept(nil, asked.data)
    check(ns.Nav.active == nil, "yes ends the journey")
    check(ns.Fanfare.lastTrip == fanfare, "nothing done on it: no fanfare")
    StaticPopupDialogs, StaticPopup_Show = nil, nil

    -- Ended once it came to something: what it came to, headed "Journey ended".
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Cut short", stops = { stopAt(0.62, "A1"), stopAt(0.64, "A2") } }))
    ns.Nav.active.stats.picked = 2
    ns.Nav.End()
    local last = ns.Fanfare.lastTrip
    local keys = {}
    for _, h in ipairs(ns.Fanfare.lastShown or {}) do keys[#keys + 1] = h.key end
    check(ns.Nav.active == nil and last ~= fanfare and last.title == "Cut short" and last.ended and last.stops == 0
      and ns.Fanfare.TripFrame().heading:GetText() == "Journey ended"
      and table.concat(keys, ","):find("picked", 1, true),
      "ended after picking up quests: its fanfare, headed Journey ended: " .. table.concat(keys, ","))
    ns.Fanfare.TripFrame():Hide()
    local b1, b2 = stopAt(0.62, "B1"), stopAt(0.64, "B2")
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Half done", stops = { b1, b2 } }))
    for _, st in ipairs(ns.Journey.AllStops(ns.Nav.active.journey)) do
      if st.node.label == "B1" then st.done = true end
    end
    ns.Nav.End()
    keys = {}
    for _, h in ipairs(ns.Fanfare.lastShown or {}) do keys[#keys + 1] = h.key end
    check(ns.Fanfare.lastTrip.title == "Half done" and ns.Fanfare.lastTrip.stops == 1 and keys[1] == "stops",
      "ended with a stop done: the stops done show: " .. table.concat(keys, ","))
    ns.Fanfare.TripFrame():Hide()
    fanfare = ns.Fanfare.lastTrip
    ns.Nav.Start("Somewhere", stopAt(0.66, "Plain").node,
      ns.Router.Plan(here, stopAt(0.66, "Plain").node, ns.Network.Build()))
    ns.Nav.active.stats.picked = 1
    ns.Nav.End()
    check(ns.Nav.active == nil and ns.Fanfare.lastTrip == fanfare, "plain directions stopped: no fanfare")

    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = { pickup, turnin, far } }))
    ns.HUD.Update()
  end

  -- Move on, not in a camp: this stop later, after the next one that doesn't need it.
  check(ns.Nav.MoveOnKind() == "later", "move on would do it later")
  local before = #chat
  ns.Nav.MoveOn()
  check(labels() == "Far,Giver,Finisher" and chat[before + 1] == "|cff7fd1aeWayward:|r later: Pick up Q, after Visit Far.",
    "the pickup goes after Far (not after its own hand-in): " .. labels() .. " / " .. tostring(chat[before + 1]))
  local root = ns.Nav.active.journey.root
  check(not root.manual, "the rest is still planned for you")
  local loaded = ns.Journey.Load(ns.Journey.Save(ns.Nav.active.journey))
  check(loaded.stops[1].later and loaded.stops[1].later[1] == loaded.stops[3], "the choice is saved with the trip")
  before = #chat
  ns.Nav.MoveOn()
  check(labels() == "Giver,Finisher,Far" and pickup.later == nil and far.later and far.later[1] == pickup,
    "Far later too: your newest choice wins, no loop: " .. labels())

  -- In a trip you ordered yourself it moves there.
  ns.Nav.Stop()
  local a, b, c = stopAt(0.52, "A"), stopAt(0.54, "B"), stopAt(0.56, "C")
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Mine", stops = { a, b, c } }))
  ns.Nav.MoveStop(c, a)
  check(labels() == "C,A,B", "your order: " .. labels())
  ns.Nav.MoveOn()
  check(labels() == "A,C,B" and ns.Nav.active.journey.root.manual and c.later == nil and c.laterUntil == nil,
    "move on keeps it: " .. labels())

  -- Do this stop later moves it down the list: behind whatever fits in the
  -- next LATER_SECONDS, not just the next stop, and it stays there when you
  -- walk elsewhere or pick up another quest, till the wait runs down.
  ns.Nav.Stop()
  local savedTime, clock = time, 200000
  time = function() return clock end
  player.x = 0.5
  local d1, d2, d3, d4 = stopAt(0.56, "D1"), stopAt(0.6, "D2"), stopAt(0.64, "D3"), stopAt(0.68, "D4")
  ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Down", stops = { d1, d2, d3, d4 } }))
  check(labels() == "D1,D2,D3,D4", "nearest first: " .. labels() .. " in " .. ns.Nav.active.journey.seconds .. " s")
  before = #chat
  ns.Nav.MoveOn()
  check(labels() == "D2,D3,D4,D1" and chat[before + 1] == "|cff7fd1aeWayward:|r later: Visit D1, after 3 other stops.",
    "later: to the end of the list, not just past the next stop: " .. labels() .. " / " .. tostring(chat[before + 1]))
  check(d1.laterUntil == clock + ns.Journey.LATER_SECONDS, "it waits a while")
  player.x = 0.54
  ns.Nav.Recalculate()
  check(labels() == "D2,D3,D4,D1", "walked back beside it: still later: " .. labels())
  local d5 = stopAt(0.58, "D5")
  ns.Journey.Extend(ns.Nav.active.journey, { d5 })
  ns.Nav.Recalculate()
  check(ns.Nav.active.journey.stops[#ns.Nav.active.journey.stops] == d1 and labels():find("D5", 1, true),
    "a stop added beside it: that one fits in, it's still later: " .. labels())
  local reloaded = ns.Journey.Load(ns.Journey.Save(ns.Nav.active.journey))
  local savedWait
  for _, s in ipairs(reloaded.stops) do if s.text == "Visit D1" then savedWait = s.laterUntil end end
  check(savedWait == d1.laterUntil, "the wait is saved with the journey")
  clock = clock + ns.Journey.LATER_SECONDS / 2
  local next = ns.Nav.HeadingFor()
  ns.Nav.MoveOn()
  check(next ~= d1 and next.laterUntil == clock + ns.Journey.LATER_SECONDS and d1.laterUntil < next.laterUntil,
    "the newer choice waits longer: " .. labels())
  ns.Journey.Postpone(ns.Nav.active.journey, d1)
  check(d1.laterUntil == clock + ns.Journey.LATER_SECONDS * 3 / 2, "postponed again: its wait grows")
  clock = clock + ns.Journey.LATER_SECONDS * 3
  -- The wait over, only the first rule holds (after D2, the stop it was put
  -- behind): it's back on the way, not at the end. (A fresh plan: re-plans
  -- as you go keep the order you're on unless another saves the padding.)
  local fresh = ns.Journey.Plan(ns.Geo.PlayerNode(), { stops = ns.Journey.OpenStops(ns.Nav.active.journey) })
  local freshLabels, position = {}, {}
  for i, s in ipairs(fresh.stops) do
    freshLabels[i] = s.node.label
    position[s] = i
  end
  check(ns.Journey.LaterIn(d1) == 0 and position[d1] > position[d2] and position[d1] < position[d3], "the wait over: it's back where it fits: " .. table.concat(freshLabels, ","))
  time = savedTime

  -- Skip asks first, then takes the stop off with what needs it.
  ns.Nav.Stop()
  pickup.later, far.later, pickup.skipped, turnin.skipped = nil, nil, nil, nil
  pickup.laterUntil, far.laterUntil = nil, nil
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Errands", stops = { pickup, turnin, far } }))
  local shown, popup = nil, nil
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which, text, _, data) shown, popup = which, { text = text, data = data } end
  ns.Nav.Skip()
  check(shown == "WAYWARD_SKIP" and popup.text:find('Skip "Pick up Q"?', 1, true)
    and popup.text:find('with "Hand in Q", which needs it', 1, true) and not pickup.skipped,
    "skip asks, naming what goes with it: " .. tostring(popup and popup.text))
  StaticPopupDialogs.WAYWARD_SKIP.OnAccept(nil, popup.data)
  check(pickup.skipped and turnin.skipped and labels() == "Far", "yes: both off the trip: " .. labels())
  StaticPopupDialogs, StaticPopup_Show = nil, nil
  ns.Nav.Skip()
  check(ns.Nav.active == nil, "skipping the last stop ends the trip")

  -- Plain directions: neither button.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local trainer = ns.Trainers.Results()[1]
  ns.Nav.Start(trainer.title, trainer.goal, trainer.route)
  ns.HUD.Update()
  check(not f.moveOn:IsShown() and not f.skip:IsShown() and ns.Nav.MoveOnKind() == nil, "plain directions: no move on or skip")
  check(tip(f.close) == "Stop directions", "and the x stops directions, not a journey")
  StaticPopupDialogs = {}
  StaticPopup_Show = function() error("plain directions shouldn't ask") end
  f.close.scripts.OnClick(f.close)
  check(ns.Nav.active == nil, "the x on plain directions stops them without asking")
  StaticPopupDialogs, StaticPopup_Show = nil, nil
  ns.Nav.Stop()
end
---------------------------------------------------------------- move on and skip (end)
---------------------------------------------------------------- cards (begin)
do
  io.write("cards\n")
  ns.Nav.Stop()
  local forYou
  for _, page in ipairs(ns.pages) do if page.id == "foryou" then forYou = page end end
  check(forYou.layout == "cards" and select(1, ns.Panel.Size()) > 384, "For you uses the card layout on a wider panel")
  local w, h = ns.Panel.Size()
  check(w >= 840 and h == 672 and w <= 1365 - 384, string.format("the window holds the three regions and fits 1080p: %dx%d", w, h))

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
  check(titles() == "Suggestion 1,Suggestion 2,Suggestion 3", "three cards per page: " .. titles())
  check(table.concat(ns.Cards.Drawn(), ",") == "Suggestion 1|Directions,Suggestion 2|Directions,Suggestion 3|Directions",
    "every card shows its title and button text: " .. table.concat(ns.Cards.Drawn(), ","))
  local said = #chat
  SlashCmdList.WAYWARD("debug cards")
  check(chat[said + 1]:find("version " .. ns.VERSION, 1, true) and #chat == said + 4
    and chat[said + 2]:find('card 1: shown=true', 1, true) and chat[said + 2]:find('title="Suggestion 1"', 1, true),
    "/ww debug cards reports the version and what each card shows")
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

  -- The card button works like a row; while something is on, Add detour
  -- beside it adds the card straight away (shift-click no longer does).
  check(ns.Cards.AddButton(2) == nil, "no Add detour on a card with nothing on")
  ns.Panel.Activate(suggestions[1])
  check(ns.Nav.active and ns.Nav.active.title == "Suggestion 1", "a card's Directions starts its directions")
  suggestions[2].goal = ns.Geo.Node(1433, 0.4, 0.5, "Other camp")
  ns.Panel.Search("cardtest", "")
  check(ns.Cards.Drawn()[2] == "Suggestion 2|Directions|Add detour" and ns.Cards.AddButton(1) == nil,
    "while something is on, a card shows Add detour beside its button, unless it's already on: "
      .. table.concat(ns.Cards.Drawn(), ","))
  local addButton = ns.Cards.AddButton(2)
  addButton.scripts.OnClick(addButton)
  check(ns.Nav.active.journey and #ns.Nav.active.journey.stops == 2, "a card's Add detour adds it to the journey")
  suggestions[2].goal = goal
  ns.Nav.Stop()

  -- The card's one line of why: the row's, else its first detail; the rest
  -- is in the tooltip, not on the card.
  ns.Cards.Show({ { title = "Noted", subtitle = "s", route = route, details = { { text = "|cffffd200rank|r" },
    { text = "Quests in your log count at full XP; ...", more = true }, { text = "shown" } } } }, "", true)
  check(ns.Cards.Detail(1) == "rank", "without a why, a card shows its first detail: " .. tostring(ns.Cards.Detail(1)))
  check(ns.Cards.More == nil, "and nothing more on the card itself: the other details are for the tooltip")
  ns.Cards.Show({ { title = "Facts", route = route, why = "A zone you haven't seen", stats = { { "XP", "~900" } },
    facts = { { "Level", "Level 8-10" }, { "Nearby", "Nearby" }, { "Quests", "11 quests" } } } }, "", true)
  check(table.concat(ns.Cards.Stats(1), ",") == "LEVEL=Level 8-10,NEARBY=Nearby,QUESTS=11 quests",
    "a row's facts come before its stats: " .. table.concat(ns.Cards.Stats(1), ","))
  ns.Cards.Show(suggestions, "", true)

  ns.Cards.Show({ { title = "Run The Stockade  ·  level 23", subtitle = "Stormwind City  ·  ~5 min  ·  1 quest",
    place = "Stormwind City  ·  Group", category = "Dungeon", stats = { { "Level", "23" }, { "Travel", "~5 min" }, { "XP/min", "~281" } },
    route = { steps = {} } } }, "", true)
  check(ns.Cards.Tag(1) == "DUNGEON", "a card says what kind of suggestion it is: " .. tostring(ns.Cards.Tag(1)))
  check(table.concat(ns.Cards.Stats(1), ",") == "LEVEL=23,TRAVEL=~5 min,XP/MIN=~281",
    "a card shows up to three facts in its meta row: " .. table.concat(ns.Cards.Stats(1), ","))
  check(ns.Cards.Drawn()[1] == "Run The Stockade|Directions", "a dungeon's level moves from the card title to the facts")

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
  check(ns.Panel.SideShown(), "/ww quest and /ww item open the side panel with the search")
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
  check(ns.RouteMap.mapID == 1433 and ns.RouteMap.lines >= 1 and ns.RouteMap.youShown and ns.RouteMap.marks == 1
    and ns.RouteMap.numbers[1] == false,
    string.format("hovering shows the zone map with the route, you and an unnumbered destination (map %s, %s lines, %s marks)",
      tostring(ns.RouteMap.mapID), tostring(ns.RouteMap.lines), tostring(ns.RouteMap.marks)))
  -- A point the client can't place in a zone doesn't cost the route its zone map.
  local realInfo = C_Map.GetMapInfoAtPosition
  C_Map.GetMapInfoAtPosition = function() return nil end
  ns.RouteMap.Show({ title = "Camp", route = { steps = {
    { mode = "walk", from = ns.Geo.Node(1433, 0.31, 0.29), to = ns.Geo.Node(1433, 0.71, 0.67), seconds = 30 } } } })
  check(ns.RouteMap.mapID == 1433, "a route on one zone's map shows that zone: " .. tostring(ns.RouteMap.mapID))
  C_Map.GetMapInfoAtPosition = realInfo
  -- What you've explored is drawn over the bare zone art, as on the world map.
  C_MapExplorationInfo = { GetExploredMapTextures = function() return {
    { textureWidth = 300, textureHeight = 200, offsetX = 100, offsetY = 50, fileDataIDs = { 1, 2 } },
    { textureWidth = 100, textureHeight = 100, offsetX = 0, offsetY = 0, isShownByMouseOver = true, fileDataIDs = { 3 } } } end }
  ns.RouteMap.Show(r)
  check(ns.RouteMap.overlays == 2, "explored areas are drawn on the map: " .. tostring(ns.RouteMap.overlays))
  C_MapExplorationInfo = nil
  -- Two zones: their continent.
  ns.RouteMap.Show({ title = "Wetlands", route = { steps = {
    { mode = "walk", from = here, to = ns.Geo.Node(1437, 0.5, 0.5, "Wetlands"), seconds = 300 } } } })
  check(ns.RouteMap.mapID == 1415, "a route across zones shows the continent: " .. tostring(ns.RouteMap.mapID))
  -- A trip across the sea: the world map, or the destination's continent without its art.
  player.mapID, player.x, player.y = 1439, 0.5, 0.5
  local sw = ns.Geo.Node(1453, 0.5, 0.5, "Stormwind")
  local trip = ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Over the sea", stops = {
    { node = ns.Geo.Node(1439, 0.55, 0.5, "Shore"), text = "Visit Shore" }, { node = sw, text = "Visit Stormwind" } } })
  check(trip and ns.RouteMap.Show({ title = "Over the sea", journey = trip }) and ns.RouteMap.mapID == 947,
    "a trip over the sea uses the world map: " .. tostring(ns.RouteMap.mapID))
  check(ns.RouteMap.marks >= 2, "you, its stops and the destination are marked")
  check(ns.RouteMap.youShown, "you're the arrow facing your way, not a badge")
  local numbers = {}
  for _, n in ipairs(ns.RouteMap.numbers) do numbers[#numbers + 1] = tostring(n) end
  check(table.concat(numbers, ",") == "1,2", "the stop and destination are numbered in order: " .. table.concat(numbers, ","))
  check(ns.RouteMap.chevrons >= 1, "chevrons point the way along the legs")
  check(not ns.RouteMap.hearthShown, "no hearthstone on the way: no hearthstone icon")
  local here = ns.Geo.PlayerNode()
  local inn = ns.Geo.Node(1439, 0.45, 0.3, "Inn")
  ns.RouteMap.Show({ title = "Hearth home", route = { steps = {
    { mode = "walk", from = here, to = ns.Geo.Node(1439, 0.55, 0.5, "Shore"), seconds = 30 },
    { mode = "hearth", from = ns.Geo.Node(1439, 0.55, 0.5, "Shore"), to = inn, seconds = 10 } }, seconds = 40 },
    goal = inn })
  -- Each way of travel has its own icon; one the client lacks gives way to the next.
  local realFaction = UnitFactionGroup
  local function iconFor(step)
    ns.RouteMap.Show({ title = "Leg", route = { steps = { step } } })
    return ns.RouteMap.iconFiles[1]
  end
  local a, b = ns.Geo.Node(1439, 0.4, 0.4), ns.Geo.Node(1439, 0.6, 0.6)
  check(iconFor({ mode = "fly", from = a, to = b, seconds = 60 }):find("Gryphon", 1, true), "an Alliance flight is a gryphon")
  UnitFactionGroup = function() return "Horde" end
  check(iconFor({ mode = "fly", from = a, to = b, seconds = 60 }):find("Wyvern", 1, true), "a Horde flight is a wind rider")
  UnitFactionGroup = realFaction
  check(iconFor({ mode = "transport", kind = "boat", from = a, to = b, seconds = 60 }):find("Ship", 1, true), "a boat is a ship")
  check(iconFor({ mode = "transport", kind = "zeppelin", from = a, to = b, seconds = 60 }):find("Zeppelin", 1, true),
    "a zeppelin is a zeppelin")
  -- A client without an icon (no file ID for it) gets the next one.
  GetFileIDFromPath = function(path) if not path:find("Classic", 1, true) then return 1 end end
  check(iconFor({ mode = "transport", kind = "boat", from = a, to = b, seconds = 60 }):find("ShipMount$"),
    "a client without the Classic ship gets the next one: " .. tostring(ns.RouteMap.iconFiles[1]))
  GetFileIDFromPath = function() return nil end
  check(iconFor({ mode = "transport", kind = "boat", from = a, to = b, seconds = 60 }):find("Map", 1, true),
    "with none of them, the last")
  GetFileIDFromPath = nil
  check(iconFor({ mode = "transport", kind = "submarine", from = a, to = b, seconds = 60 }):find("Map", 1, true),
    "something new is the map")
  ns.RouteMap.Show({ title = "Hearth home", route = { steps = {
    { mode = "walk", from = here, to = ns.Geo.Node(1439, 0.55, 0.5, "Shore"), seconds = 30 },
    { mode = "hearth", from = ns.Geo.Node(1439, 0.55, 0.5, "Shore"), to = inn, seconds = 10 } }, seconds = 40 },
    goal = inn })
  check(ns.RouteMap.hearthShown and ns.RouteMap.modeIcons == 1, "a hearthstone leg has its icon mid-leg, walking none: "
    .. tostring(ns.RouteMap.modeIcons))
  C_Map.GetMapArtLayers, C_Map.GetMapArtLayerTextures = nil, nil
  ns.RouteMap.Hide()

  -- There and back on one flight path: the two legs side by side, their
  -- chevrons and icons apart, not on top of each other.
  do
    local v = ns.RouteMap.NewView(UIParent, 280)
    local A, B, C = { px = 20, py = -50 }, { px = 240, py = -50 }, { px = 240, py = -150 }
    local steps = { { mode = "fly", from = A, to = B }, { mode = "fly", from = B, to = A },
      { mode = "walk", from = A, to = C } }
    local s = ns.RouteMap.DrawRoute(v, steps, { A, B, A, C }, function(n) return n.px, n.py end, { you = false })
    local l1, l2, l3 = s.legs[1], s.legs[2], s.legs[3]
    check(s.lanes == 2 and l1[2] ~= l2[2] and math.abs(l1[2] - l2[2]) >= 6 and l1[1] == 20 and l2[1] == 240
      and l3[1] == 20 and l3[2] == -50,
      string.format("there and back: two lanes side by side (y %.1f and %.1f), the walk on its own line",
        l1[2], l2[2]))
    -- The two flights' chevrons: the ones along y = -50 (the walk heads off down).
    local closest, flights = math.huge, 0
    for _, p in ipairs(s.chevronAt) do
      if math.abs(p[2] + 50) < 5 then flights = flights + 1 end
    end
    for i = 1, flights do
      for j = i + 1, flights do
        local p, q = s.chevronAt[i], s.chevronAt[j]
        closest = math.min(closest, math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2))
      end
    end
    local i1, i2 = s.iconAt[1], s.iconAt[2]
    check(flights >= 4 and closest > 15 and i1 and i2 and math.abs(i1[1] - i2[1]) >= 14,
      string.format("their chevrons fall between each other's (closest %.1f px) and the icons apart (%.1f px)",
        closest, i1 and i2 and math.abs(i1[1] - i2[1]) or -1))
    s = ns.RouteMap.DrawRoute(v, { steps[1], steps[3] }, { A, B, C }, function(n) return n.px, n.py end, { you = false })
    check(s.lanes == 0 and s.legs[1][2] == -50 and s.alphas[1] == 1, "a leg of its own stays on its line, in full")
    v.canvas:Hide()
  end
end
---------------------------------------------------------------- route map (end)
---------------------------------------------------------------- world map route (begin)
do
  io.write("world map route\n")
  local W = ns.WorldMapRoute
  local savedMap, savedMixin, savedCreate = WorldMapFrame, MapCanvasDataProviderMixin, CreateFromMixins
  WorldMapFrame = nil
  check(W.Hook() == false and W.Refresh() == nil, "no world map: nothing hooked, no error")

  -- A world map like the game's: a canvas with a size, the map being looked
  -- at, and data providers.
  local providers, shownMap = {}, 1433
  local canvas = newObj()
  canvas.GetWidth = function() return 1000 end
  canvas.GetHeight = function() return 667 end
  WorldMapFrame = newObj()
  WorldMapFrame.AddDataProvider = function(_, p) providers[#providers + 1] = p end
  WorldMapFrame.GetCanvas = function() return canvas end
  WorldMapFrame.GetMapID = function() return shownMap end
  WorldMapFrame.GetCanvasScale = function() return 0.5 end
  MapCanvasDataProviderMixin = { OnAdded = function() end, RefreshAllData = function() end }
  CreateFromMixins = function(...)
    local o = {}
    for _, m in ipairs({ ... }) do for k, v in pairs(m) do o[k] = v end end
    return o
  end
  check(W.Hook() and #providers == 1, "joins the world map as a data provider")
  W.Hook()
  check(#providers == 1, "joins it once")

  ns.Nav.Stop()
  providers[1]:RefreshAllData()
  check(W.Stats() == nil, "no journey: nothing on the world map")

  -- Two stops in Redridge, then one in the Wetlands.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local stops = {
    { node = ns.Geo.Node(1433, 0.6, 0.5, "East camp"), text = "Visit the east camp" },
    { node = ns.Geo.Node(1433, 0.6, 0.7, "South camp"), text = "Visit the south camp" },
    { node = ns.Geo.Node(1437, 0.5, 0.5, "Wetlands camp"), text = "Visit the Wetlands camp" },
  }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "World map", kind = "custom", stops = stops }), true)
  providers[1]:RefreshAllData()
  local s = W.Stats()
  check(s and s.lines >= 2 and s.marks >= 2,
    string.format("the journey is drawn on the zone map: %s lines, %s stops marked",
      tostring(s and s.lines), tostring(s and s.marks)))
  check(s and not s.youShown, "no arrow of ours: the world map shows you")
  check(s and s.chevrons >= 1, "chevrons point the way")
  local legs = s and s.lines or 0

  shownMap = 1415
  providers[1]:OnMapChanged()
  local c = W.Stats()
  check(c and c.lines >= legs and W.mapID == 1415,
    "on the continent the rest of it shows too: " .. tostring(c and c.lines) .. " lines")
  check(c and c.numbers[#c.numbers] ~= false and c.numbers[1] == 1, "the stops are numbered in order")

  -- The other continent's map holds none of it.
  shownMap = 1414
  providers[1]:OnMapChanged()
  local other = W.Stats()
  check(other and other.lines == 0 and other.marks == 0, "a map with none of the journey on it shows none of it")

  -- Lines and badges keep their size on screen as the map zooms.
  shownMap = 1433
  WorldMapFrame.GetCanvasScale = function() return 2 end
  providers[1]:OnCanvasScaleChanged()
  check(W.Stats() and W.Stats().lines >= 1, "zooming in redraws it")

  WorldMapFrame:Show()
  ns.SetSetting("worldMapRoute", false)
  check(W.Stats() == nil, "the option takes it off the map")
  ns.commands.worldmap.run("")
  check(ns.db.settings.worldMapRoute == true and W.Stats() ~= nil, "/ww worldmap puts it back")

  -- The next few steps in full, the ones after fading step by step.
  check(W.Alpha(1) == 1 and W.Alpha(3) == 1 and W.Alpha(4) < 1 and W.Alpha(5) < W.Alpha(4) and W.Alpha(40) > 0.2,
    string.format("steps fade the further ahead they are: %.2f %.2f %.2f", W.Alpha(4), W.Alpha(5), W.Alpha(40)))
  s = W.Refresh()
  check(s and s.alphas[1] == 1 and (s.lines < 4 or s.alphas[s.lines] < 1),
    "drawn so: the step you're on in full, the last ones faded")

  ns.Nav.Stop()
  check(W.Stats() == nil, "the journey ended: it's gone from the map")
  WorldMapFrame:Hide()
  WorldMapFrame, MapCanvasDataProviderMixin, CreateFromMixins = savedMap, savedMixin, savedCreate
end
---------------------------------------------------------------- world map route (end)
---------------------------------------------------------------- minimap route (begin)
do
  io.write("minimap route\n")
  local M = ns.MinimapRoute
  local savedMinimap, savedGetCVar, savedShape = Minimap, GetCVar, GetMinimapShape
  Minimap = nil
  check(M.Update() == nil and M.Refresh() == nil, "no minimap: nothing drawn, no error")

  -- A 140-wide minimap at zoom 0 outdoors: 466 2/3 yards across, so 0.3
  -- pixels a yard.
  local zoom, cvars = 0, { minimapZoom = "0", minimapInsideZoom = "2", rotateMinimap = "0" }
  Minimap = CreateFrame("Frame")
  Minimap.GetWidth = function() return 140 end
  Minimap.GetHeight = function() return 140 end
  Minimap.GetZoom = function() return zoom end
  GetCVar = function(name) return cvars[name] end
  check(math.abs(M.Yards() - 466.67) < 0.01, "zoomed out outdoors it sees 466 yards across")
  zoom = 2
  check(M.Yards() == 180, "at the indoor zoom it's the indoor view: " .. M.Yards())
  zoom = 0

  ns.Nav.Stop()
  check(M.Update() == nil and M.Stats() == nil, "no journey: nothing on the minimap")

  -- A stop 60 yards north, then one 60 yards east of it, then one far off
  -- south. (Redridge's map is 640 yards across and 960 down.)
  player.mapID, player.x, player.y, player.facing = 1433, 0.5, 0.5, 0
  local here = ns.Geo.PlayerNode()
  local function at(north, east, label)
    return ns.Geo.Node(1433, 0.5 + east / 640, 0.5 - north / 960, label)
  end
  local north, northEast = at(60, 0, "North post"), at(60, 60, "East post")
  local far = at(-300, 0, "Far post")
  local stops = {
    { node = north, text = "Visit the north post" },
    { node = northEast, text = "Visit the east post" },
    { node = far, text = "Visit the far post" },
  }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Minimap", kind = "custom", stops = stops }), true)
  local s = M.Stats()
  check(s and s.lines >= 2 and not s.youShown, string.format(
    "a journey is drawn on the minimap, without an arrow of ours: %s lines", tostring(s and s.lines)))
  -- The first leg runs from the middle (you) straight up, 60 yards = 18 px.
  local first = s and s.legs[1]
  check(first and math.abs(first[1] - 70) < 0.5 and math.abs(first[2] + 70) < 0.5
    and math.abs(first[3] - 70) < 0.5 and math.abs(first[4] + 52) < 0.5,
    string.format("north is up, from you in the middle: (%.1f, %.1f) to (%.1f, %.1f)",
      first and first[1] or -1, first and first[2] or -1, first and first[3] or -1, first and first[4] or -1))
  -- The far stop is off the minimap: its leg is cut at the rim, its badge not shown.
  local cut = true
  for _, l in ipairs(s and s.legs or {}) do
    for _, p in ipairs({ { l[1], l[2] }, { l[3], l[4] } }) do
      if (p[1] - 70) ^ 2 + (p[2] + 70) ^ 2 > 67.01 ^ 2 then cut = false end
    end
  end
  check(cut and s.marks == 2, "legs are cut at the round rim, and only the stops on it marked: " .. tostring(s and s.marks))
  -- Only the step you're on and the next: the far stop is the world map's to show.
  check(s and s.lines == 2 and s.numbers[1] == 1 and s.numbers[2] == 2,
    string.format("two steps on the minimap, numbered as on the journey: %s lines", tostring(s and s.lines)))

  -- A square minimap (an addon's) cuts at its corners instead: zoomed in, the
  -- east post (63 px up, 63 right) is past a round rim but inside the square.
  zoom = 5
  M.Tick(1)
  local roundEnd = M.Stats().legs[2]
  GetMinimapShape = function() return "SQUARE" end
  check(M.Tick(1), "a new shape draws it again")
  local squareEnd = M.Stats().legs[2]
  check(roundEnd[3] < 120 and math.abs(squareEnd[3] - 133) < 0.5,
    string.format("square: the leg runs on into the corner (%.1f, round %.1f)", squareEnd[3], roundEnd[3]))
  GetMinimapShape = savedShape
  zoom = 0

  -- Standing still, nothing is drawn again; walking a few yards, it is.
  M.Tick(1)
  check(not M.Tick(1), "standing still: not drawn again")
  player.y = player.y - 0.0005
  check(M.Tick(1), "walking on: drawn again from where you are")
  check(not M.Tick(0.001), "but no more than 30 times a second")
  player.y = 0.5

  -- A minimap that turns with you: facing west (a quarter turn left), the
  -- stop to the north is off to the right.
  cvars.rotateMinimap, player.facing = "1", math.pi / 2
  M.Tick(1)
  first = M.Stats().legs[1]
  local second = M.Stats().legs[2]
  check(first[3] > 85 and math.abs(first[4] + 70) < 0.5 and math.abs(second[3] - 88) < 0.5
    and math.abs(second[4] + 88) < 0.5,
    string.format("turning with you: north is to the right facing west (%.1f, %.1f), east is down (%.1f, %.1f)",
      first[3], first[4], second[3], second[4]))
  cvars.rotateMinimap, player.facing = "0", 0

  -- Zooming in draws it bigger.
  zoom = 5
  M.Tick(1)
  first = M.Stats().legs[1]
  check(math.abs(first[4] + 70 - 63) < 0.5, string.format("zoomed in, 60 yards is 63 px: %.1f", first[4] + 70))
  zoom = 0

  -- The step you're on in full; every one after it fainter, to a floor.
  check(M.Alpha(1) == 1 and M.Alpha(2) < 1 and M.Alpha(3) < M.Alpha(2) and M.Alpha(40) > 0.2,
    string.format("minimap steps fade from the second on: %.2f %.2f %.2f", M.Alpha(2), M.Alpha(3), M.Alpha(40)))
  M.Tick(1)
  local faded = M.Stats()
  check(faded.alphas[1] == 1 and faded.alphas[2] < 1,
    string.format("drawn so: the leg you're on in full, the next faded (%.2f)", faded.alphas[2] or -1))

  -- In the area of the stop you're on: no line to it, its badge and the way on stay.
  M.Tick(1)
  local before = M.Stats()
  local current = ns.Nav.CurrentStep()
  check(current and current.stop, "the step you're on leads to a stop")
  current.stop.inArea = true
  check(M.Tick(1), "walking into the stop's area draws it again")
  local inside = M.Stats()
  local fromYou = false
  for _, l in ipairs(inside.legs) do
    if math.abs(l[1] - 70) < 0.5 and math.abs(l[2] + 70) < 0.5 then fromYou = true end
  end
  check(not fromYou and inside.lines == before.lines - 1 and inside.marks == before.marks,
    string.format("in its area, the line to it goes but the stops stay marked: %d lines (was %d), %d marks (was %d)",
      inside.lines, before.lines, inside.marks, before.marks))
  current.stop.inArea = nil
  check(M.Tick(1) and M.Stats().lines == before.lines, "out of it again, the line is back")

  -- The option, and /ww minimap journey.
  local choice
  for _, c in ipairs(ns.Options.Choices()) do
    if c.name == "Your journey on the minimap" then choice = c end
  end
  check(choice and choice.section == "Maps" and choice.get() == true, "the option is under maps, on by default")
  choice.set(false)
  check(M.Stats() == nil, "the option takes it off the minimap")
  ns.commands.minimap.run("journey")
  check(ns.db.settings.minimapRoute == true and M.Stats() ~= nil, "/ww minimap journey puts it back")

  ns.Nav.Stop()
  check(M.Stats() == nil, "the journey ended: it's gone from the minimap")
  Minimap, GetCVar = savedMinimap, savedGetCVar
end
---------------------------------------------------------------- minimap route (end)
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
  Wayward.RegisterSource({ id = "low", label = "Low", priority = 1,
    Npc = function(id) if id == 777 then return { name = "Old Name", subName = "Weapon Master", faction = "A",
      flags = { trainer = true }, positions = { { mapID = 1433, x = 0.5, y = 0.52 } } } end end,
    NpcIDs = function(flag) if flag == "trainer" then return { 777, 461 } end end,
    ClassSpells = function(class)
      if class == "WARLOCK" then return { { spellID = 9001, level = 6, cost = 100 }, { spellID = 9002, level = 30, cost = 900 },
        { spellID = 9003, level = 4, cost = 50, talent = 9100 }, { spellID = 9004, level = 4, cost = 50, races = { [2] = true } },
        { spellID = 9005, level = 4, cost = 50, faction = "Horde" } } end
    end,
    TrainerSpells = function(id) if id == 777 then return { { spellID = 227, level = 1, cost = 1000 } } end end })
  Wayward.RegisterSource({ id = "high", label = "High", priority = 50,
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

  -- Required spells: a rank 2 whose rank 1 is a talent you don't have isn't
  -- on your list; one whose rank 1 is on it waits for that rank's level.
  Wayward.RegisterSource({ id = "reqs", label = "Reqs", priority = 2,
    ClassSpells = function(class)
      if class == "WARLOCK" then return { { spellID = 9006, level = 6, cost = 200, requires = { 9101 } },
        { spellID = 9007, level = 10, cost = 300, requires = { 9001 } },
        { spellID = 9008, level = 8, cost = 400, requires = { 9002 } } } end
    end })
  IsPlayerSpell = function() return false end
  local listed = {}
  for _, s in ipairs(ns.Trainers.Services()) do listed[s.spellID] = s end
  summary = ns.Trainers.SpellSummary()
  check(not listed[9006] and summary.trainable == 2 and summary.cost == 400,
    "a spell needing a talent (or quest) spell you don't have isn't learnable: " .. summary.trainable .. " trainable")
  check(listed[9007] and listed[9007].type == "available", "one needing a rank you can learn now is learnable now")
  check(listed[9008] and listed[9008].levelReq == 30 and listed[9008].type == "unavailable"
    and summary.nextLevel == 30 and summary.nextCount == 2, "one needing a later rank waits for that rank's level")
  IsPlayerSpell = function(id) return id == 9101 end
  fire("SPELLS_CHANGED")
  check(ns.Trainers.SpellSummary().trainable == 3, "with the talent's spell, the rank after it counts")
  Wayward.UnregisterSource("reqs")

  -- A trainer reading: unavailable at a level you had then means a required
  -- spell you don't have, not a level to wait for.
  ns.charDB.classSpells = { updated = 0, level = 20, services = {
    { name = "Life Tap", type = "available", levelReq = 20, cost = 1000 },
    { name = "Hemorrhage", rank = "Rank 2", type = "unavailable", levelReq = 18, cost = 500 },
    { name = "Shadow Ward", type = "unavailable", levelReq = 22, cost = 700 } } }
  check(ns.Trainers.SpellSummary().trainable == 1, "a spell the trainer won't teach you isn't counted")
  local realLevel = UnitLevel
  UnitLevel = function() return 22 end
  summary = ns.Trainers.SpellSummary()
  check(summary.trainable == 2 and summary.names[2] == "Shadow Ward", "one that waited for your level is, once you reach it")

  -- A talent's rank 2 the trainer marked unavailable below its level isn't
  -- counted once you reach it: the data says it needs the talent. As on
  -- Forever, the reading has no rank (the spell does: they match by level).
  Wayward.RegisterSource({ id = "talent", label = "Talent", priority = 2,
    ClassSpells = function(class)
      if class == "WARLOCK" then return { { spellID = 9010, level = 24, cost = 150, talent = 9110 } } end
    end })
  local realInfo, realSubtext = GetSpellInfo, GetSpellSubtext
  GetSpellInfo = function(id) if id == 9010 then return "Shadowburn" end end
  GetSpellSubtext = function(id) if id == 9010 then return "Rank 2" end end
  IsPlayerSpell = function() return false end
  fire("SPELLS_CHANGED")
  ns.charDB.classSpells.services[#ns.charDB.classSpells.services + 1] =
    { name = "Shadowburn", type = "unavailable", levelReq = 24, cost = 150 }
  UnitLevel = function() return 24 end
  summary = ns.Trainers.SpellSummary()
  check(summary.trainable == 2 and not summary.names[3],
    "a talent's rank 2 isn't counted without the talent: " .. table.concat(summary.names, ", "))
  IsPlayerSpell = function(id) return id == 9110 end
  fire("SPELLS_CHANGED")
  check(ns.Trainers.SpellSummary().trainable == 3, "with the talent, it is")
  GetSpellInfo, GetSpellSubtext = realInfo, realSubtext
  Wayward.UnregisterSource("talent")
  fire("SPELLS_CHANGED")
  UnitLevel = realLevel
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
  Wayward.RegisterSource({ id = "broken", label = "Broken", priority = 99,
    Npc = function() error("boom") end })
  check(ns.Data.Npc(777) and ns.Data.Npc(777).name == "New Name" and reported and reported:find("broken"),
    "a failing source is reported and skipped: " .. tostring(reported))
  geterrorhandler = savedHandler

  for _, id in ipairs({ "low", "high", "broken" }) do Wayward.UnregisterSource(id) end
  check(ns.Data.Status() == "Fixtures (baked)" and not ns.Data.Has("ClassSpells"), "unregistering takes a source away")
end
---------------------------------------------------------------- data sources (end)
---------------------------------------------------------------- notable quests (begin)
do
  io.write("notable quests\n")
  ns.Nav.Stop()
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives }
  local savedClass, savedLevel, savedInstant, savedFaction = UnitClass, UnitLevel, C_Item.GetItemInfoInstant, GetFactionInfoByID
  local keys = LibQuestieDB.Meta.QuestMeta.questKeys
  keys.questFlags, keys.specialFlags, keys.reputationReward, keys.childQuests = 23, 24, 26, 14
  keys.zoneOrSort = 17
  C_QuestLog.GetNumQuestLogEntries = function() return 0 end
  C_QuestLog.GetInfo = function() return nil end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5

  -- Lakeshire quests (Magistrate Solomon, 344), each notable for one reason.
  local function quest(id, name, extra)
    local q = { name = name, questLevel = 19, requiredLevel = 15, zoneOrSort = 44, startedBy = { { 344 } },
      finishedBy = { { 344 } } }
    for k, v in pairs(extra or {}) do q[k] = v end
    QUESTS[id] = q
  end
  quest(501, "Shadow Pact", { zoneOrSort = -61, requiredClasses = 256 })
  quest(502, "Staff Delivery")
  quest(503, "Heavy Lifting")
  quest(504, "The Long Tale", { questFlags = 32 })
  quest(505, "Into the Mines", { nextQuestInChain = 506 })
  quest(506, "Deep in the Mines", { zoneOrSort = 1581 })
  quest(507, "Home Errand", { reputationReward = { { 72, 250 }, { 529, 250 } } })
  quest(508, "Faire Tickets", { zoneOrSort = -364 })
  quest(509, "Smithing Supplies", { zoneOrSort = -121 })
  quest(510, "Ring Run")
  quest(90501, "Forever Frontier")
  quest(90502, "Lakeshire Logs") -- the same name as quest 7: not new
  ITEMS[9501] = { name = "Staff of the Blessed Seer", class = 2, subClass = 10, requiredLevel = 20, itemLevel = 25,
    questRewards = { 502 } }
  ITEMS[9502] = { name = "Heavy Plate Helm", class = 4, subClass = 4, requiredLevel = 40, itemLevel = 45,
    questRewards = { 503 } }
  ITEMS[9503] = { name = "Plain Robe", class = 4, subClass = 1, requiredLevel = 15, questRewards = { 503 } }
  ITEMS[9504] = { name = "Band of Lakeshire", class = 4, subClass = 0, requiredLevel = 18, questRewards = { 510 } }
  -- The client has the staff (green), the robe (white: doesn't count) and the
  -- ring (blue) cached, and knows the ring is a ring; not the helm yet.
  local QUALITY = { [9501] = 2, [9503] = 1, [9504] = 3 }
  local asked = {}
  GetItemInfo = function(id) if QUALITY[id] then return "Item " .. id, nil, QUALITY[id] end end
  C_Item.RequestLoadItemDataByID = function(id) asked[#asked + 1] = id end
  C_Item.GetItemInfoInstant = function(id)
    if id == 9504 then return id, "Armor", "Miscellaneous", "INVTYPE_FINGER", 0, 4, 0 end
    return savedInstant(id)
  end
  GetFactionInfoByID = function(id) if id == 529 then return "Argent Dawn" end end
  refreshData()

  local function kinds(id)
    local out = {}
    for _, r in ipairs(ns.Quests.Notable(id)) do out[#out + 1] = r.kind end
    return table.concat(out, ",")
  end
  local function reason(id, kind)
    for _, r in ipairs(ns.Quests.Notable(id)) do if r.kind == kind then return r.text end end
    return ""
  end

  -- QuestSort: a negative zoneOrSort, by name.
  local sort, detail = ns.Quests.QuestSort(501)
  check(sort == "class" and detail == "WARLOCK", "QuestSort: -61 is a warlock class quest")
  check(ns.Quests.QuestSort(509) == "profession:Blacksmithing" and select(2, ns.Quests.QuestSort(508)) == "Darkmoon Faire"
    and ns.Quests.QuestSort(502) == nil and ns.Quests.QuestSort(1) == nil,
    "QuestSort: professions and holidays named; an AreaID (or none) is no sort")
  check(ns.Quests.QuestArea(ns.Quests.Quest(501)) == nil and ns.Quests.QuestArea(ns.Quests.Quest(506)) == 1581,
    "a QuestSort is never taken for an area; a dungeon quest keeps its AreaID")

  -- RewardItems: quest -> items, from the items' questRewards.
  local rewards = ns.Quests.RewardItems(502)
  check(#rewards == 1 and rewards[1].itemID == 9501 and rewards[1].name == "Staff of the Blessed Seer"
    and rewards[1].class == 2 and rewards[1].subClass == 10 and rewards[1].requiredLevel == 20
    and rewards[1].itemLevel == 25, "RewardItems: the staff, with its class, subclass and levels")
  check(#ns.Quests.RewardItems(503) == 2 and #ns.Quests.RewardItems(1) == 1 and #ns.Quests.RewardItems(7) == 0,
    "RewardItems: every item a quest rewards, none for a quest without")

  -- Notable: each reason in plain words.
  check(kinds(501) == "class" and reason(501, "class"):find("^Class quest %(Warlock%)")
    and ns.Quests.NotableTag(501) == "Class quest", "a warlock class quest: " .. reason(501, "class"))
  check(reason(502, "reward") == "Rewards Staff of the Blessed Seer (your class can use it, level 20)."
    and ns.Quests.NotableTag(502) == "Reward for you", "a green staff a warlock can use: " .. reason(502, "reward"))
  check(kinds(503) == "", "plate isn't for a warlock, and a white robe doesn't count: " .. kinds(503))
  check(ns.Quests.NotableTag(510) == "Reward for you" and reason(510, "reward"):find(", a rare item", 1, true),
    "a blue ring suits anyone (the client knows its slot)")
  check(kinds(504) == "epic" and ns.Quests.NotableTag(504) == "Epic", "an epic quest (questFlags 32)")
  check(reason(505, "dungeon") == "Leads to a quest in The Deadmines (Deep in the Mines).",
    "a chain that leads into a dungeon: " .. reason(505, "dungeon"))
  check(kinds(506) == "", "the dungeon quest itself isn't 'leads to' its own dungeon")
  foreverCheck(kinds(90501) == "forever" and reason(90501, "forever"):find("^Forever%-only quest")
    and kinds(90502) == "", "a Forever-only quest; a Forever copy of an old quest isn't new",
    kinds(90501) == "" and kinds(90502) == "", "no 'New in Forever' for a high quest ID")
  check(reason(507, "reputation") == "Gives reputation with Argent Dawn." and ns.Quests.NotableTag(507) == nil,
    "reputation outside your own cities is a reason, too weak for a tag alone")
  check(kinds(508) == "holiday" and ns.Quests.NotableTag(508) == nil and reason(509, "profession") == "Blacksmithing quest.",
    "holiday and profession quests are mentioned, not tagged")
  check(kinds(7) == "" and ns.Quests.NotableScore(7) == 0, "an ordinary quest: nothing stands out")

  -- Another class, another level: what it can use changes.
  UnitClass = function() return "Warrior", "WARRIOR", 1 end
  check(reason(503, "reward"):find("^Rewards Heavy Plate Helm") and kinds(502) == "reward" and kinds(501) == "",
    "a warrior: the plate helm (worn from 40) and the staff count, a warlock quest doesn't: "
      .. reason(503, "reward"))
  check(ns.Quests.NotableTag(503) == nil and #asked == 1 and asked[1] == 9502,
    "armour of a quality not known yet is mentioned, not tagged; the client is asked for it once")
  UnitLevel = function() return 30 end
  ITEMS[9505] = { name = "Ringmail Vest", class = 4, subClass = 3, requiredLevel = 41, questRewards = { 503 } }
  refreshData()
  check(not reason(503, "reward"):find("Ringmail", 1, true), "mail needing level 41: a warrior wears plate by then")
  ITEMS[9505] = nil
  UnitLevel = savedLevel
  refreshData()
  UnitClass = savedClass

  -- A source with its own quest -> items index is used instead of a pass over every item.
  local itemReads = 0
  local realItem = fixtures.Item
  fixtures.Item = function(id) itemReads = itemReads + 1 return realItem(id) end
  fixtures.QuestRewards = function() return { [502] = { 9501 } } end
  refreshData()
  check(#ns.Quests.RewardItems(502) == 1 and itemReads == 1 and #ns.Quests.RewardItems(503) == 0,
    "a source's QuestRewards index: only the reward items are read (" .. itemReads .. ")")
  fixtures.Item, fixtures.QuestRewards = realItem, nil
  refreshData()

  -- /ww debug quest: sort, flags, rewards and reasons.
  local said = #chat
  SlashCmdList.WAYWARD("debug quest 502")
  local printed = table.concat(chat, "\n", said + 1)
  check(printed:find("rewards: Staff of the Blessed Seer (9501; class 2/10, level 20", 1, true)
    and printed:find("quality 2, yours", 1, true) and printed:find("notable: [reward 2] Rewards Staff", 1, true),
    "/ww debug quest lists rewards and reasons")
  said = #chat
  SlashCmdList.WAYWARD("debug quest the long tale")
  printed = table.concat(chat, "\n", said + 1)
  check(printed:find("flags: epic", 1, true) and printed:find("notable: [epic 4]", 1, true),
    "/ww debug quest <name>: flags and reasons")

  -- Quests page: the tag on the row, the reasons in its tooltip.
  local results = ns.QuestsPage.Results("Shadow Pact")
  local row = results[#results]
  local tip = {}
  for _, d in ipairs(row and row.details or {}) do tip[#tip + 1] = d.text end
  check(row and row.subtitle:find("Class quest", 1, true) and table.concat(tip, "\n"):find("Class quest (Warlock)", 1, true),
    "Quests page: a notable row is tagged, its tooltip says why: " .. tostring(row and row.subtitle))
  results = ns.QuestsPage.Results("Lakeshire Logs")
  check(results[1] and not results[1].subtitle:find("  ·  |c", 1, true), "an ordinary quest has no tag")
  UnitClass = function() return "Mage", "MAGE", 8 end
  results = ns.QuestsPage.Results("Shadow Pact")
  check(results[1] and not results[1].subtitle:find("Class quest", 1, true), "another class's quest isn't tagged")
  UnitClass = savedClass

  -- For you: "Don't miss" the most notable quest close by, a card with its reason as its why.
  ns.ForYou.Invalidate()
  local list = ns.ForYou.Results()
  local order, card, zone = {}, nil, nil
  for _, r in ipairs(list) do
    order[#order + 1] = r.category
    if r.category == "Don't miss" then card = r end
    if r.category == "Questing zone" then zone = zone or r end
  end
  local text = table.concat(order, ",")
  check(card and card.title == "Do The Long Tale" and card.journey and card.icon,
    "Don't miss: the epic quest, the most notable one close by (" .. text .. ")")
  check(card and card.role and card.relevance_parts.novelty == 1 and card.lead == "novelty",
    "its novelty leads: " .. tostring(card and card.role))
  local why = {}
  for _, d in ipairs(card and card.details or {}) do why[#why + 1] = d.text end
  check(card and card.why:find("^Epic quest line") and card.details[2].text:find("^Don't miss: Epic quest line")
    and card.place:find("^Epic"),
    "the card says why in plain words: " .. table.concat(why, " / "))
  check(card and card.details[2].text:find("Its quest giver is ", 1, true) and not card.details[2].text:find("XP", 1, true)
    and not card.why:find("XP"),
    "and how far its quest giver is: " .. tostring(card and card.details[2].text))
  local rewardReason
  for _, r in ipairs(ns.Quests.Notable(502)) do if r.kind == "reward" then rewardReason = r end end
  check(rewardReason and rewardReason.itemID == 9501, "a reward reason carries its item, for the item tooltip")
  local ok, err = pcall(ns.Panel.ShowTooltip, UIParent, { title = "Do Staff quest", item = 9501, details = {} })
  check(ok and ns.Panel.ItemTooltip() and ns.Panel.ItemTooltip():IsShown(), "the reward shows in its own tooltip beside it"
    .. (err and (": " .. tostring(err)) or ""))
  GameTooltip:Hide()
  check(ns.Quests.NotableItem(502) == 9501 and ns.Quests.NotableItem(501) == nil, "a quest's notable reward item")
  local found
  for _, r in ipairs(ns.QuestsPage.Results("Staff Delivery")) do
    if r.id == "quest502" then found = r end
  end
  check(found and found.item == 9501, "Quests page: a search row shows the reward beside its tooltip")
  local savedItemLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete }
  C_QuestLog.GetNumQuestLogEntries = function() return 1 end
  C_QuestLog.GetInfo = function() return { questID = 502, isHeader = false, title = QUESTS[502].name } end
  C_QuestLog.IsComplete = function() return false end
  found = nil
  for _, r in ipairs(ns.QuestsPage.Results("")) do
    if r.id == "log502" then found = r end
  end
  check(found and found.item == 9501, "Quests page: a quest log row too")
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete =
    savedItemLog[1], savedItemLog[2], savedItemLog[3]
  found = nil
  for _, r in ipairs(ns.QuestHubs.Results()) do
    for _, q in ipairs(r.quests or {}) do
      if q.id == 502 then found = r end
    end
  end
  check(found and found.item == 9501, "Quest hubs: a hub row shows its quests' notable reward")
  -- (On Classic Era no Forever chain is inferred, so one more quest is open
  -- and The Long Tale falls off the zone card's list: the dungeon one shows it.)
  local line, reason = "The Long Tale  (Magistrate Solomon)  ·  Epic", "Epic quest line"
  if ERA then line, reason = "Into the Mines  (Magistrate Solomon)  ·  Leads to a dungeon", "Leads to a quest in" end
  local tagged, why
  for i, d in ipairs(zone and zone.details or {}) do
    if d.quest and d.text:find(line, 1, true) then
      tagged, why = true, zone.details[i + 1]
    end
  end
  check(tagged and why and why.more and why.text:find(reason, 1, true),
    "quest lines on other cards carry their tag; the reason is in the tooltip only")

  -- In your log and ready: the card hands it in.
  C_QuestLog.GetNumQuestLogEntries = function() return 1 end
  C_QuestLog.GetInfo = function() return { questID = 504, isHeader = false } end
  C_QuestLog.IsComplete = function(id) return id == 504 end
  fire("QUEST_ACCEPTED", 1, 504) -- into the log (the lists built per quest version start again)
  fire("QUEST_LOG_UPDATE")
  ns.ForYou.Invalidate()
  local ready
  for _, r in ipairs(ns.ForYou.Results()) do if r.category == "Don't miss" then ready = r end end
  check(ready and ready.title == "Hand in The Long Tale", "a notable quest ready to hand in: "
    .. tostring(ready and ready.title))
  C_QuestLog.GetNumQuestLogEntries = function() return 0 end
  C_QuestLog.GetInfo = function() return nil end
  fire("QUEST_LOG_UPDATE")

  -- Slow roads (every trip 100 times longer): nothing notable within ten minutes.
  local realPlan = ns.Router.Plan
  ns.Router.Plan = function(...)
    local r = realPlan(...)
    if not r then return nil end
    local slow = {}
    for k, v in pairs(r) do slow[k] = v end
    slow.seconds, slow.steps = r.seconds * 100, {}
    for i, st in ipairs(r.steps) do
      local c = {}
      for k, v in pairs(st) do c[k] = v end
      c.seconds = (st.seconds or 0) * 100
      slow.steps[i] = c
    end
    return slow
  end
  ns.ForYou.Invalidate()
  local far
  for _, r in ipairs(ns.ForYou.Results()) do if r.category == "Don't miss" then far = r end end
  ns.Router.Plan = realPlan
  check(not far, "no Don't miss card when the notable quests are far away: " .. tostring(far and far.subtitle))

  for id in pairs({ [501] = 1, [502] = 1, [503] = 1, [504] = 1, [505] = 1, [506] = 1, [507] = 1, [508] = 1, [509] = 1,
    [510] = 1, [90501] = 1, [90502] = 1 }) do QUESTS[id] = nil end
  for _, id in ipairs({ 9501, 9502, 9503, 9504 }) do ITEMS[id] = nil end
  GetItemInfo, C_Item.GetItemInfoInstant, GetFactionInfoByID = nil, savedInstant, savedFaction
  C_Item.RequestLoadItemDataByID = nil
  UnitClass, UnitLevel = savedClass, savedLevel
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]
  refreshData()
  ns.ForYou.Invalidate()
end
---------------------------------------------------------------- notable quests (end)
---------------------------------------------------------------- movers (begin)
do
  io.write("movers\n")
  -- Frames that keep their points and size (UIParent: 1000 x 800, scale 1).
  local function placed(o)
    o.SetPoint = function(self, point, rel, relPoint, x, y)
      self.point = { point, rel, relPoint or point, x or 0, y or 0 }
    end
    o.GetPoint = function(self)
      local p = self.point or { "CENTER", nil, "CENTER", 0, 0 }
      return p[1], p[2], p[3], p[4], p[5]
    end
    o.ClearAllPoints = function(self) self.point = nil end
    o.SetSize = function(self, w, h) self.w, self.h = w, h end
    o.GetSize = function(self) return self.w or 0, self.h or 0 end
    o.GetEffectiveScale = function() return 1 end
    return o
  end
  placed(UIParent):SetSize(1000, 800)
  local savedCreate = CreateFrame
  CreateFrame = function(...) return placed(savedCreate(...)) end

  local byKey = {}
  for _, pane in ipairs(ns.Movers.Panes()) do
    byKey[pane.key] = pane
    placed(pane.frame())
    ns.Movers.Reset(pane)
  end
  check(byKey.Directions and byKey.Journey and byKey.TripDone and byKey.NewJourney,
    "the directions, journey, banner and toast can be moved")
  local hud = byKey.Directions.frame()
  hud:SetSize(330, 84)
  check(hud == ns.HUD.Frame() and hud:GetPoint() == "TOP" and select(5, hud:GetPoint()) == -140,
    "the directions box starts at its usual spot")

  -- Blizzard's Edit Mode: a box over each pane while it's open.
  EditModeManagerFrame = newObj()
  rawset(EditModeManagerFrame, "shown", false)
  fire("PLAYER_LOGIN")
  runTimers()
  ns.db.settings.toasts = false
  EditModeManagerFrame:Show()
  local boxes = ns.Movers.Overlays()
  check(ns.Movers.Editing() and boxes.Directions and boxes.Journey and boxes.TripDone and not boxes.NewJourney,
    "Edit Mode shows a box per pane (not the toast while toasts are off)")
  local moved = 0
  ns.Listen("HUD_MOVED", function() moved = moved + 1 end)
  local box, cx, cy = boxes.Directions, 500, 358
  box.GetCenter = function() return cx, cy end
  box.scripts.OnDragStart(box)
  cx, cy = 530, 338
  box.scripts.OnDragStop(box)
  local p = ns.db.settings.hudPos
  check(p and p[1] == "TOP" and p[2] == "TOP" and p[3] == 30 and p[4] == -160 and moved == 1,
    "dragging the box moves the directions by as much, keeps its anchor and saves it")
  box.scripts.OnClick(box)
  check(ns.db.settings.hudPos == nil and select(4, hud:GetPoint()) == 0 and select(5, hud:GetPoint()) == -140,
    "right-click puts it back")
  EditModeManagerFrame.scripts.OnHide(EditModeManagerFrame)
  check(not ns.Movers.Editing() and next(ns.Movers.Overlays()) == nil, "closing Edit Mode hides the boxes")
  ns.db.settings.toasts = nil

  -- EllesmereUI's unlock mode, through its MakeUnlockElement whitelist.
  local got, folder = {}, nil
  EllesmereUI = {
    MakeUnlockElement = function(o)
      return { key = o.key, label = o.label, group = o.group, getFrame = o.getFrame, getSize = o.getSize,
        savePosition = o.savePos, loadPosition = o.loadPos, clearPosition = o.clearPos,
        applyPosition = o.applyPos, isHidden = o.isHidden, ownsPosition = o.ownsPosition, noInitHook = o.noInitHook }
    end,
    RegisterUnlockElements = function(_, elements, f)
      folder = f
      for _, e in ipairs(elements) do got[e.key] = e end
    end,
  }
  fire("PLAYER_LOGIN")
  runTimers()
  local e = got.Wayward_Directions
  check(folder == "Wayward" and e and got.Wayward_Journey and got.Wayward_TripDone and got.Wayward_NewJourney
    and e.getFrame() == hud and e.ownsPosition and e.noInitHook, "the four panes are in EllesmereUI's unlock mode")
  local pos = e.loadPosition("Wayward_Directions")
  check(pos.point == "CENTER" and pos.x == 0 and pos.y == 400 - 140 - 42,
    "it's told where the directions' centre is (" .. tostring(pos.x) .. ", " .. tostring(pos.y) .. ")")
  moved = 0
  e.savePosition("Wayward_Directions", "CENTER", "CENTER", 100, 50)
  p = ns.db.settings.hudPos
  check(p and p[1] == "TOP" and p[2] == "CENTER" and p[3] == 100 and p[4] == 92 and moved == 1,
    "a centre it hands back places the box by its top, so it still grows downwards")
  pos = e.loadPosition("Wayward_Directions")
  check(pos.x == 100 and pos.y == 50, "and reads back the same")
  e.clearPosition("Wayward_Directions")
  check(ns.db.settings.hudPos == nil and select(3, hud:GetPoint()) == "TOP", "its reset puts it back")
  ns.db.settings.toasts = false
  check(got.Wayward_NewJourney.isHidden() and not got.Wayward_Directions.isHidden,
    "no toast mover while toasts are off")
  ns.db.settings.toasts = nil

  CreateFrame, EllesmereUI, EditModeManagerFrame = savedCreate, nil, nil
end
---------------------------------------------------------------- movers (end)
---------------------------------------------------------------- perf (begin)
do
  io.write("perf\n")
  local realSelect, realPlan, realClock = ns.Panel.SelectPage, ns.Router.Plan, debugprofilestop
  -- A clock that moves, so every timed call counts.
  local ticks = 0
  debugprofilestop = function() ticks = ticks + 1 return ticks end
  SlashCmdList.WAYWARD("perf on")
  check(ns.db.settings.perf and ns.Perf.Enabled() and ns.Panel.SelectPage ~= realSelect, "/ww perf on wraps the modules")
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
  SlashCmdList.WAYWARD("perf")
  check(#ns.Perf.TraceLines() > 1, "/ww perf prints the last trace")
  SlashCmdList.WAYWARD("perf off")
  check(not ns.db.settings.perf and ns.Panel.SelectPage == realSelect and ns.Router.Plan == realPlan,
    "/ww perf off puts the original functions back")
  ns.Panel.SelectPage("trainers", 1)
  check(#ns.Perf.Traces() == before, "nothing is recorded while off")
  debugprofilestop = realClock
end
---------------------------------------------------------------- perf (end)
---------------------------------------------------------------- fewer refreshes (begin)
do
  io.write("fewer refreshes\n")
  ns.Nav.Stop()
  local fired = 0
  ns.Listen("DATA_CHANGED", function() fired = fired + 1 end)
  -- The same vendor twice: recorded once.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  UnitGUID = function() return "Creature-0-1-0-2-777-AB" end
  ns.db.npcs[777] = nil
  ns.Harvest.RecordNPC("vendor")
  local once = fired
  ns.Harvest.RecordNPC("vendor")
  check(once == 1 and fired == once, "talking to the same NPC again changes nothing, so nothing refreshes")
  ns.Harvest.RecordNPC("innkeeper")
  check(fired == once + 1, "a new role for them does")
  player.x = 0.6
  ns.Harvest.RecordNPC("vendor")
  check(fired == once + 2 and math.abs(ns.db.npcs[777].x - 0.6) < 1e-6, "and so does meeting them somewhere else")
  ns.db.npcs[777] = nil
  UnitGUID = function() return "Creature-0-1-0-2-999-AB" end
  -- Durability: only a crossing of a line refreshes.
  local durability = 0.9
  GetInventoryItemDurability = function() return durability * 100, 100 end
  fired = 0
  fire("UPDATE_INVENTORY_DURABILITY")
  local first = fired
  durability = 0.85
  fire("UPDATE_INVENTORY_DURABILITY")
  check(fired == first, "gear wearing a little doesn't refresh")
  durability = 0.5
  fire("UPDATE_INVENTORY_DURABILITY")
  check(fired == first + 1, "gear reaching the repair line does")
  GetInventoryItemDurability = nil
  -- The panel refreshes once per burst, and not in combat.
  if not ns.Panel.IsShown() then ns.Panel.Toggle() end
  local runs = ns.ForYou.runs
  ns.Fire("DATA_CHANGED")
  ns.Fire("DATA_CHANGED")
  ns.Fire("DATA_CHANGED")
  check(ns.ForYou.runs == runs, "a burst of changes waits")
  InCombatLockdown = function() return true end
  runTimers()
  check(ns.ForYou.runs == runs, "and not while in combat")
  InCombatLockdown = function() return false end
  fire("PLAYER_REGEN_ENABLED")
  runTimers()
  check(ns.ForYou.runs == runs + 1, "once combat ends, one refresh for the whole burst")
  InCombatLockdown = nil
  ns.Panel.Toggle()
  -- For you's background check comes back after combat.
  InCombatLockdown = function() return true end
  runs = ns.ForYou.runs
  fire("PLAYER_LEVEL_UP")
  runTimers() -- the check runs, sees combat, waits
  InCombatLockdown = function() return false end
  fire("PLAYER_REGEN_ENABLED")
  runTimers()
  check(ns.ForYou.runs == runs + 1, "a level-up in combat is looked at once combat ends")
  InCombatLockdown = nil
  -- A timer callback's error is reported, not lost, and the loop goes on.
  local reported
  local realHandler = geterrorhandler
  geterrorhandler = function() return function(err) reported = err end end
  ns.After(0, function() error("timer boom") end)
  runTimers()
  geterrorhandler = realHandler
  check(reported and tostring(reported):find("timer boom", 1, true), "ns.After reports its callback's error")
end
---------------------------------------------------------------- fewer refreshes (end)
---------------------------------------------------------------- release polish (begin)
do
  io.write("release polish\n")
  -- The welcome window: once, on the first login, after a short delay.
  ns.Welcome.Hide()
  ns.db.settings.welcomed = nil
  fire("PLAYER_LOGIN")
  check(not ns.Welcome.IsShown(), "the welcome waits for the loading screen to clear")
  runTimers()
  check(ns.Welcome.IsShown() and ns.db.settings.welcomed == ns.VERSION, "the welcome shows on the first login, once")
  local lines = ns.Welcome.Lines()
  check(#lines == 5 and lines[2]:find("/ww", 1, true) and lines[4]:find("Data:", 1, true),
    "it says how to open Wayward and which data it has: " .. lines[4])
  ns.Welcome.Hide()
  fire("PLAYER_LOGIN")
  runTimers()
  check(not ns.Welcome.IsShown(), "a later login doesn't show it again")
  SlashCmdList.WAYWARD("welcome")
  check(ns.Welcome.IsShown(), "/ww welcome shows it again")
  if ns.Panel.IsShown() then ns.Panel.Toggle() end
  -- The options, in sections; the compass and TomTom's arrow under navigation aid.
  local sections = {}
  for _, c in ipairs(ns.Options.Choices()) do
    if sections[#sections] ~= c.section then sections[#sections + 1] = c.section end
    if c.name == "Compass in the directions box" or c.name == "TomTom's arrow" then
      check(c.section == "Navigation aid", c.name .. " is under navigation aid")
    end
  end
  check(#sections == 4 and sections[1] == "Navigation aid", "the options come in sections: " .. table.concat(sections, ", "))
  for _, c in ipairs(ns.Options.Choices()) do
    if c.name == "Compass in the directions box" then
      local before = c.get()
      c.set(not before)
      check(c.get() ~= before and ns.db.settings.showArrow == (not before), "a checkbox changes the setting")
      c.set(before)
    end
  end
  local chatBefore
  -- Help is sorted, and an unknown command says so.
  chatBefore = #chat
  SlashCmdList.WAYWARD("nonsense")
  local seenItem, seenWelcome
  for i = chatBefore + 1, #chat do
    if chat[i]:find("no command called nonsense", 1, true) then seenItem = seenItem or 0 end
    if chat[i]:find("/ww item", 1, true) then seenItem = i end
    if chat[i]:find("/ww welcome", 1, true) then seenWelcome = i end
  end
  check(seenItem and seenWelcome and seenItem < seenWelcome, "an unknown command prints the help, commands in order")
  -- The overview stays shut when a journey starts, unless turned on.
  ns.Nav.Stop()
  ns.JourneyOverview.EnsureFrame():Hide()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local function stop(x, label) return { node = ns.Geo.Node(1433, x, 0.5, label), text = "Visit " .. label } end
  local function trip() return ns.Journey.Plan(here, { title = "Two stops", stops = { stop(0.6, "A"), stop(0.7, "B") } }) end
  ns.Nav.StartJourney(trip())
  check(ns.Nav.active and ns.Nav.active.journey and not ns.JourneyOverview.IsShown(),
    "by default, a new journey doesn't open the overview (the directions box's View details does)")
  ns.Nav.Stop()
  ns.db.settings.overviewOnStart = true
  ns.Nav.StartJourney(trip())
  check(ns.JourneyOverview.IsShown(), "with the option on, it does")
  ns.db.settings.overviewOnStart = nil
  ns.Nav.Stop()
  ns.JourneyOverview.EnsureFrame():Hide()
  -- Reset positions.
  ns.db.settings.hudPos = { "TOP", "TOP", 100, -100 }
  SlashCmdList.WAYWARD("reset")
  check(ns.db.settings.hudPos == nil and ns.db.settings.panelPos == nil, "/ww reset forgets every saved position")
end
---------------------------------------------------------------- release polish (end)
---------------------------------------------------------------- game and season (begin)
do
  io.write("game and season\n")
  check(ns.Game() == (ERA and "era" or "forever") and ns.IsForever() == not ERA, "the client is told apart: " .. ns.Game())
  check(ns.Season() == nil and not ns.IsHardcore() and ns.TooHardLevels() == 5
    and ns.GameName() == (ERA and "Classic Era" or "WoW Forever"), "no season: " .. ns.GameName())
  C_Seasons = { GetActiveSeason = function() return 2 end }
  check(ns.Season() == "sod" and ns.TooHardLevels() == 5
    and ns.GameName() == (ERA and "Season of Discovery" or "WoW Forever"), "Season of Discovery: " .. ns.GameName())
  local p = { level = UnitLevel("player") }
  QUESTS[9701] = { name = "Ogre Trouble", questLevel = p.level + 4, requiredLevel = p.level, startedBy = { { 344 } } }
  refreshData()
  local _, reason = ns.Quests.QuestStatus(9701)
  check(reason == "You can take this quest.", "four levels up (orange) is fine off Hardcore: " .. tostring(reason))
  C_Seasons = { GetActiveSeason = function() return 3 end }
  check(ns.IsHardcore() and ns.TooHardLevels() == 3, "Hardcore realm season")
  C_Seasons, C_GameRules = nil, { IsHardcoreActive = function() return true end }
  check(ns.IsHardcore() and ns.GameName() == (ERA and "Hardcore" or "WoW Forever"), "Hardcore rules: " .. ns.GameName())
  ns.Fire("DATA_CHANGED")
  _, reason = ns.Quests.QuestStatus(9701)
  check(reason == string.format("Level %d: hard for you.", p.level + 4), "on Hardcore, orange is too hard: " .. tostring(reason))
  local before = #chat
  SlashCmdList.WAYWARD("debug")
  check(chat[before + 1] and chat[before + 1]:find("(" .. ns.GameName() .. ")", 1, true), "/ww debug names the game: " .. tostring(chat[before + 1]))
  C_GameRules = nil
  QUESTS[9701] = nil
  refreshData()
end
---------------------------------------------------------------- game and season (end)
-- ===== stream C: journey model =====
do
  io.write("stream C: journey model\n")
  ns.Nav.Stop()
  runTimers()
  ns.charDB.journeys = nil
  ns.charDB.detail = nil
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local function visit(x, label, mapID) return { node = ns.Geo.Node(mapID or 1433, x, 0.5, label), text = "Visit " .. label } end
  local function labels()
    local out = {}
    for _, st in ipairs(ns.Nav.active and ns.Nav.active.journey and ns.Nav.active.journey.stops or {}) do
      out[#out + 1] = st.node.label
    end
    return table.concat(out, ",")
  end
  local function goTo(stop)
    player.mapID, player.x, player.y = stop.node.mapID, stop.node.x, stop.node.y
    ns.HUD.Update()
  end

  -- Explore a zone: planned with a text of its own, done once you're in the zone.
  local explore = { node = ns.Geo.Node(1437, 0.5, 0.5, "Wetlands"), action = { kind = "explore", mapID = 1437 } }
  local after = visit(0.5, "Wetlands shore", 1437)
  after.node = ns.Geo.Node(1437, 0.5, 0.9, "Wetlands shore")
  local journey = ns.Journey.Plan(here, { title = "See the Wetlands", kind = "zone",
    icon = "Interface\\Icons\\INV_Misc_Map_01", stops = { explore, after } })
  check(journey and journey.stops[1] == explore and explore.text == "Explore Wetlands"
    and ns.Router.Describe(journey, #journey.steps - 1) ~= nil, "an explore stop plans, named after its zone: " .. tostring(explore.text))
  check(journey.kind == "zone" and journey.icon == "Interface\\Icons\\INV_Misc_Map_01" and journey.def.kind == "zone"
    and journey.root.icon == journey.icon, "the journey carries its kind and icon")
  ns.Nav.StartJourney(journey)
  check(ns.Journey.PendingAction({ stop = explore }) == explore, "an explore stop waits like a quest stop")
  player.mapID, player.x, player.y = 1437, 0.5, 0.97 -- just inside the Wetlands, nowhere near the stop
  ns.HUD.Update()
  check(explore.done and ns.Nav.active and ns.Nav.HeadingFor() == after,
    "being anywhere in the zone does the explore stop; on to the next")
  ns.Nav.Stop()

  -- A zone inside the one to explore counts (the map's parent); flying over it doesn't.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local explore2 = { node = ns.Geo.Node(1437, 0.5, 0.5, "Wetlands"), action = { kind = "explore", mapID = 1437 } }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Wetlands again", stops = { explore2, visit(0.5, "Shore 2", 1437) } }))
  local realBest, realInfo = C_Map.GetBestMapForUnit, C_Map.GetMapInfo
  C_Map.GetBestMapForUnit = function() return 99001 end
  C_Map.GetMapInfo = function(id)
    if id == 99001 then return { mapID = 99001, name = "Menethil Harbor", parentMapID = 1437 } end
    return realInfo(id)
  end
  UnitOnTaxi = function() return true end
  fire("ZONE_CHANGED_NEW_AREA")
  check(not explore2.done, "flying over the zone doesn't count")
  UnitOnTaxi = function() return false end
  fire("ZONE_CHANGED_NEW_AREA")
  check(explore2.done, "a subzone of the zone (its parent map) counts, on the zone change event")
  C_Map.GetBestMapForUnit, C_Map.GetMapInfo = realBest, realInfo
  ns.Nav.Stop()

  -- Enter a dungeon: an ordinary stop that can sit in the middle, done when you load in.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local enter = { node = ns.Geo.Node(1433, 0.56, 0.5, "The Deadmines entrance"),
    action = { kind = "enter", dungeon = "The Deadmines" } }
  local a, b = visit(0.53, "A"), visit(0.6, "B")
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Deadmines day", kind = "dungeon", stops = { b, enter, a } }))
  check(labels() == "A,The Deadmines entrance,B" and enter.text == "Enter The Deadmines",
    "an enter stop is planned where it fits, not last: " .. labels())
  goTo(a)
  goTo(enter)
  check(ns.Nav.Waiting() and ns.Nav.Interaction() == "enter" and ns.HUD.Lines()[4]:find("go in", 1, true),
    "at the entrance: go in: " .. ns.HUD.Lines()[4])
  check(not ns.Nav.EnteredInstance("Wailing Caverns") and not enter.done, "loading into another instance isn't it")
  check(ns.Nav.EnteredInstance("Deadmines") and enter.done and ns.Nav.active and ns.Nav.HeadingFor() == b,
    "loading into the dungeon (\"The\" or not) does the stop; the journey goes on to B")
  ns.Nav.Stop()
  -- A save from before: its `finish` loads as an enter stop after the rest.
  local old = ns.Journey.Load({ title = "Old run", stops = { { node = { mapID = 1433, x = 0.53, y = 0.5, label = "A" }, text = "Visit A" } },
    finish = { node = { mapID = 1453, x = 0.5, y = 0.5, label = "The Stockade" }, text = "Enter The Stockade" } })
  check(old.finish == nil and #old.stops == 2 and old.stops[2].action and old.stops[2].action.kind == "enter"
    and old.stops[2].action.dungeon == "The Stockade" and old.stops[2].after[1] == old.stops[1],
    "an older save's finish loads as an enter stop that comes after the others")
  local hub = ns.Journey.Plan(here, { title = "Hub", stops = {}, finish = { node = a.node, text = "Pick up quests here: X" } })
  check(hub and #hub.stops == 1 and not hub.stops[1].action, "a finish that isn't a dungeon is a plain stop, done on arrival")

  -- Learn: class training, from a result with spells (the training card); done once something is learned.
  -- Opening the trainer harvests the NPC we're targeting, so the NPC table and the read spell list are restored after.
  local savedNPCs, savedClassSpells = CopyTable(ns.db.npcs), ns.charDB.classSpells
  local trainer = ns.Geo.Node(1433, 0.54, 0.5, "Demisette Cloyce")
  trainer.npc = "Demisette Cloyce"
  local stops = ns.Nav.StopsFor({ title = "Train 2 new spells in Lakeshire", goal = trainer, spells = { "Life Tap", 136126 } })
  check(#stops == 1 and stops[1].action.kind == "learn" and stops[1].text == "Train your new spells at Demisette Cloyce"
    and stops[1].npc == "Demisette Cloyce", "a result with spells becomes a learn stop: " .. tostring(stops[1] and stops[1].text))
  local learn = stops[1]
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Training", stops = { learn, visit(0.6, "After") } }))
  goTo(learn)
  check(ns.Nav.Waiting() and ns.Nav.TargetNPC() == "Demisette Cloyce" and ns.HUD.Lines()[4]:find("train your spells", 1, true),
    "at the trainer: talk to them and train your spells: " .. ns.HUD.Lines()[4])
  local savedUnitName = UnitName
  UnitName = function(unit) if unit == "npc" then return "Demisette Cloyce" end return "Zodalia" end
  fire("TRAINER_SHOW")
  check(not learn.done, "opening the trainer alone doesn't finish it (nothing learned yet)")
  SERVICES[2][2] = "used" -- bought Life Tap
  fire("TRAINER_UPDATE")
  check(learn.done and ns.Nav.active and ns.Nav.HeadingFor().node.label == "After",
    "learning a listed spell finishes the stop; on to the next")
  SERVICES[2][2] = "available"
  fire("TRAINER_CLOSED")
  runTimers()
  ns.Nav.Stop()
  -- Any new spell counts when none are listed; a listed spell already known counts at once.
  local any = { node = trainer, npc = trainer.npc, text = "Train at Demisette Cloyce", action = { kind = "learn", spells = {}, npc = trainer.npc } }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Training 2", stops = { any, visit(0.6, "After") } }))
  goTo(any)
  fire("TRAINER_SHOW")
  SERVICES[1][2] = "used" -- bought Corruption
  fire("SPELLS_CHANGED")
  check(any.done, "with no spells listed, any spell bought at the trainer finishes it")
  SERVICES[1][2] = "unavailable"
  fire("TRAINER_CLOSED")
  runTimers()
  ns.Nav.Stop()
  local known = { node = trainer, npc = trainer.npc, action = { kind = "learn", spells = { 136126 }, npc = trainer.npc } }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Training 3", stops = { known, visit(0.6, "After") } }))
  check(known.text == "Train your new spells at Demisette Cloyce", "a learn stop without text names its trainer")
  goTo(known)
  local savedKnown = IsPlayerSpell
  IsPlayerSpell = function(id) return id == 136126 end
  fire("TRAINER_SHOW")
  check(known.done, "a listed spell you already know finishes it as the trainer opens")
  IsPlayerSpell = savedKnown
  fire("TRAINER_CLOSED")
  runTimers()
  ns.Nav.Stop()
  -- Where the client can't show the trainer's list, talking to them has to do.
  local fallback = { node = trainer, npc = trainer.npc, action = { kind = "learn", spells = { "Life Tap" }, npc = trainer.npc } }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Training 4", stops = { fallback, visit(0.6, "After") } }))
  goTo(fallback)
  local savedNum = GetNumTrainerServices
  GetNumTrainerServices = nil
  check(not ns.Nav.CanWatchTraining(), "without the trainer API, training can't be watched")
  fire("TRAINER_SHOW")
  check(fallback.done, "so talking to the trainer finishes the stop")
  GetNumTrainerServices = savedNum
  UnitName = savedUnitName
  fire("TRAINER_CLOSED")
  runTimers()
  ns.Nav.Stop()
  ns.db.npcs, ns.charDB.classSpells = savedNPCs, savedClassSpells
  refreshData()

  -- Kind and icon through save, load, extend and re-plan; the kinds set here.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local zone = ns.Journey.Plan(here, { title = "Zone", kind = "zone", icon = "Interface\\Icons\\INV_Misc_Map_01",
    stops = { visit(0.53, "A"), visit(0.56, "B") } })
  local saved = ns.Journey.Save(zone)
  check(saved.kind == "zone" and saved.icon == "Interface\\Icons\\INV_Misc_Map_01" and saved.finish == nil, "Save keeps the kind and icon")
  local loaded = ns.Journey.Load(saved)
  local resumed = ns.Journey.Resume(loaded, here)
  check(loaded.kind == "zone" and resumed and resumed.kind == "zone" and resumed.icon == saved.icon, "Load and Resume keep them")
  ns.Journey.Extend(zone, { visit(0.59, "C") })
  local replanned = ns.Journey.Replan(zone, here)
  check(replanned and replanned.kind == "zone" and replanned.icon == saved.icon and #replanned.stops == 3,
    "Extend and Replan keep them")
  ns.Nav.StartJourney(replanned)
  ns.Nav.AddToTrip({ visit(0.62, "D") }, "D")
  check(ns.Nav.active.journey.kind == "zone" and ns.Nav.active.title == "Zone", "a detour keeps the journey's kind and name")
  ns.Nav.Stop()
  ns.Nav.AddToTrip({ visit(0.53, "Alone") }, "Alone")
  check(ns.Nav.active and ns.Nav.active.journey.kind == "custom", "a detour with nothing on starts a custom journey")
  ns.Nav.Stop()
  local offer = ns.Nav.PickupOffer({ 1 })
  check(offer and offer.journey.kind == "quest" and offer.journey.icon == "Interface\\GossipFrame\\AvailableQuestIcon",
    "a picked-up quest's journey is of the quest kind")
  check(ns.Nav.AddDetour == ns.Nav.AddToTrip, "Nav.AddDetour is Nav.AddToTrip")

  -- The quest log's buttons, for the quest selected in it: start a journey,
  -- or with one on, add the quest to it or start a new one.
  do
    local QLB = ns.QuestLogButtons
    local savedInfo = ns.QuestLog.Info
    ns.QuestLog.Info = function(i) return i == 1 and { questID = 1, title = "Log quest" } or nil end
    GetQuestLogSelection = function() return 1 end
    QuestLogFrame = newObj()
    QuestLogFrame:Show()
    local id, title = QLB.Selected()
    check(id == 1 and title == "Log quest" and QLB.Mode(1) == "start", "quest log: nothing on, it offers to start a journey")
    -- Planned as the quest really is (not in the log yet: a pickup first).
    ns.QuestLog.Info = savedInfo
    QLB.Sync()
    check(QLB.NewJourney(1, title) and ns.Nav.active and ns.Nav.active.title == "Log quest"
      and ns.Nav.active.journey.kind == "quest" and ns.Nav.TripHasQuest(1) and QLB.Mode(1) == "new",
      "quest log: starts a journey for the quest; it can't be added again")
    ns.Nav.Stop()
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Other", kind = "zone", stops = { visit(0.53, "O1") } }))
    check(QLB.Mode(1) == "both", "quest log: with a journey on, add or new")
    QLB.Sync()
    QLB.AddToJourney(1, title)
    check(ns.Nav.active.title == "Other" and ns.Nav.TripHasQuest(1) and QLB.Mode(1) == "new",
      "quest log: added to the journey on")
    ns.Nav.Stop()
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Other", kind = "zone", stops = { visit(0.53, "O1") } }))
    local aside = #ns.Nav.SetAsideList()
    QLB.NewJourney(1, title)
    check(#ns.Nav.SetAsideList() == aside + 1 and ns.Nav.SetAsideList()[1].title == "Other"
      and ns.Nav.active.title == "Log quest", "quest log: a new journey sets the one on aside")
    ns.Nav.Stop()
    ns.Nav.ForgetSetAside(1)
    ns.QuestLog.Info = function() return nil end
    check(QLB.Selected() == nil, "quest log: a header selected, no buttons")
    QuestLogFrame:Hide()
    QLB.Sync()
    ns.QuestLog.Info, GetQuestLogSelection, QuestLogFrame = savedInfo, nil, nil
  end

  -- Forever: the quests are a tab of the world map; the buttons go by the
  -- selected quest's details there.
  do
    local QLB = ns.QuestLogButtons
    local savedLog = C_QuestLog
    local selected = 1
    C_QuestLog = setmetatable({ GetSelectedQuest = function() return selected end }, { __index = savedLog })
    WorldMapFrame = newObj()
    QuestMapFrame = newObj()
    QuestMapFrame.DetailsFrame = newObj()
    QuestMapFrame.DetailsFrame.AbandonButton = newObj()
    local id = QLB.Selected()
    check(id == 1 and QLB.Mode(1) == "start", "map quest tab: the quest whose details are open, offered a journey")
    QLB.Sync()
    check(QLB.NewJourney(1) and ns.Nav.active and ns.Nav.TripHasQuest(1) and QLB.Mode(1) == "new",
      "map quest tab: starts a journey for the quest")
    ns.Nav.Stop()
    selected = 0
    check(QLB.Selected() == nil, "map quest tab: no quest open, no buttons")
    WorldMapFrame:Hide()
    QLB.Sync()
    C_QuestLog, WorldMapFrame, QuestMapFrame = savedLog, nil, nil
  end

  -- Nav.Progress: the one count for the directions box and the home screen.
  local p1, p2, p3 = visit(0.53, "P1"), visit(0.56, "P2"), visit(0.59, "P3")
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Progress", kind = "custom", stops = { p1, p2, p3 } }))
  local p = ns.Nav.Progress()
  check(p and p.done == 0 and p.total == 3 and p.stopIndex == 1 and p.stopText == "Visit P1" and p.seconds > 0
    and p.kind == "custom" and p.title == "Progress" and not p.directions,
    string.format("progress at the start: %d of %d, stop %d (%s)", p.done, p.total, p.stopIndex, tostring(p.stopText)))
  goTo(p1)
  p = ns.Nav.Progress()
  check(p.done == 1 and p.total == 3 and p.stopIndex == 2 and p.stopText == "Visit P2",
    string.format("after a stop: %d of %d, stop %d (%s)", p.done, p.total, p.stopIndex, tostring(p.stopText)))
  check(ns.HUD.Lines()[1]:find("1 of 3 done", 1, true), "the directions box shows the same count: " .. ns.HUD.Lines()[1])
  ns.Nav.Drop(p2)
  p = ns.Nav.Progress()
  check(p.done == 1 and p.total == 2 and p.stopIndex == 2 and p.stopText == "Visit P3",
    string.format("a skipped stop isn't counted: %d of %d, stop %d", p.done, p.total, p.stopIndex))
  ns.Nav.Stop()
  local dest = ns.Geo.Node(1433, 0.6, 0.5, "Somewhere")
  ns.Nav.Start("Somewhere", dest, ns.Router.Plan(here, dest, ns.Network.Build()))
  p = ns.Nav.Progress()
  check(p and p.directions and p.total == 1 and p.done == 0 and p.stopText == "Somewhere", "plain directions: one stop, the destination")
  ns.Nav.Stop()
  check(ns.Nav.Progress() == nil, "nothing on: no progress")

  -- The last stop done before the others: it's done, and the journey goes on
  -- round the stops still open instead of ending.
  do
    player.mapID, player.x, player.y = 1433, 0.5, 0.5
    local fanfare = ns.Fanfare.lastTrip
    local l1, l2 = visit(0.53, "L1"), visit(0.56, "L2")
    local l3 = { node = ns.Geo.Node(1433, 0.59, 0.5, "L3"), text = "Hand in L", action = { kind = "turnin", questID = 883 } }
    ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Last first", kind = "custom", stops = { l1, l2, l3 } }))
    check(labels() == "L1,L2,L3", "planned in order: " .. labels())
    fire("QUEST_TURNED_IN", 883)
    check(ns.Nav.active and ns.Nav.active.title == "Last first" and l3.done and labels() == "L1,L2"
      and ns.Fanfare.lastTrip == fanfare,
      "the last stop's quest handed in first: it's done, the journey goes on with the rest: " .. labels())
    goTo(l1)
    goTo(l2)
    check(ns.Nav.active == nil and ns.Fanfare.lastTrip ~= fanfare, "with nothing left, the journey has arrived")

    -- Getting to the last stop's place first (another way round): the same.
    player.x = 0.5
    fanfare = ns.Fanfare.lastTrip
    local m1, m2, m3 = visit(0.53, "M1"), visit(0.56, "M2"), visit(0.59, "M3")
    ns.Nav.StartJourney(ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Far end first", kind = "custom",
      stops = { m1, m2, m3 } }))
    goTo(m3)
    local left = labels()
    check(ns.Nav.active and ns.Nav.active.title == "Far end first" and m3.done and not m1.done and not m2.done
      and (left == "M2,M1" or left == "M1,M2") and ns.Fanfare.lastTrip == fanfare,
      "at the last stop before the others: it's done, the journey goes on with the rest: " .. left)
    goTo(m2)
    goTo(m1)
    check(ns.Nav.active == nil, "and arrives once they're done too")
    player.x = 0.5
  end

  -- Set aside, resume, forget.
  local lastFanfare = ns.Fanfare.lastTrip
  local s1, s2, s3 = visit(0.53, "S1"), visit(0.56, "S2"), visit(0.59, "S3")
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "First journey", kind = "zone", icon = "Interface\\Icons\\INV_Misc_Map_01",
    stops = { s1, s2, s3 } }))
  goTo(s1)
  local before = #chat
  local entry = ns.Nav.SetAside()
  local list = ns.Nav.SetAsideList()
  check(ns.Nav.active == nil and ns.charDB.nav == nil and ns.Fanfare.lastTrip == lastFanfare,
    "set aside: navigation ends, nothing saved as the journey on now, no fanfare")
  check(entry and #list == 1 and list[1] == entry and entry.title == "First journey" and entry.kind == "zone"
    and entry.icon == "Interface\\Icons\\INV_Misc_Map_01" and entry.stops == 2 and entry.at and entry.journey.stops[1].done,
    "it's in the list with its kind, icon, time and stops left")
  check(chat[before + 1] and chat[before + 1]:find("set aside: First journey (2 stops left)", 1, true), "and says so: " .. tostring(chat[before + 1]))
  check(ns.Nav.SetAside() == nil, "nothing on: nothing to set aside")
  player.x = 0.5
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Second journey", stops = { visit(0.7, "T1") } }))
  check(ns.Nav.ResumeSetAside(1) and ns.Nav.active and ns.Nav.active.title == "First journey" and labels() == "S2,S3",
    "resuming plans what's left of it from here: " .. labels())
  p = ns.Nav.Progress()
  check(p.done == 1 and p.total == 3, "with the stop already done still counted")
  check(#list == 1 and list[1].title == "Second journey", "the journey that was on is set aside in its place")
  -- After a relog: the list is plain saved data, and still resumes.
  ns.Nav.SetAside()
  ns.Nav.active = nil
  ns.charDB.journeys = CopyTable(ns.charDB.journeys)
  list = ns.Nav.SetAsideList()
  check(#list == 2 and list[1].title == "First journey" and list[2].title == "Second journey", "newest first")
  check(ns.Nav.ResumeSetAside(2) and ns.Nav.active.title == "Second journey" and #list == 1,
    "after a relog a set-aside journey resumes from the saved data")
  ns.Nav.Stop()
  check(ns.Nav.ForgetSetAside(1) and #list == 0 and not ns.Nav.ForgetSetAside(1), "forget takes it off the list")
  -- Five at most: the oldest goes.
  for i = 1, 6 do
    ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Journey " .. i, stops = { visit(0.6, "J" .. i) } }))
    ns.Nav.SetAside()
  end
  local titles = {}
  for _, e in ipairs(ns.Nav.SetAsideList()) do titles[#titles + 1] = e.title end
  check(table.concat(titles, ",") == "Journey 6,Journey 5,Journey 4,Journey 3,Journey 2", "five kept, newest first: " .. table.concat(titles, ","))
  -- The three-way question: Switch journey sets the one on aside and starts the new one.
  ns.charDB.journeys = nil
  StaticPopupDialogs = {}
  local shown
  StaticPopup_Show = function(which, x, y, data) shown = { which = which, data = data } end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "On now", stops = { visit(0.53, "N1"), visit(0.56, "N2") } }))
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Something new", stops = { visit(0.7, "X") } }))
  check(shown and shown.which == "WAYWARD_TRIP" and ns.Nav.active.title == "On now", "a new journey asks first")
  shown.data.switch()
  check(ns.Nav.active.title == "Something new" and #ns.Nav.SetAsideList() == 1 and ns.Nav.SetAsideList()[1].title == "On now",
    "Switch journey: the new one is on, the old one set aside")
  shown = nil
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "A detour", stops = { visit(0.6, "Y") } }))
  shown.data.add()
  check(ns.Nav.active.title == "Something new" and labels():find("Y", 1, true) and #ns.Nav.SetAsideList() == 1,
    "Add as detour: merged, nothing set aside: " .. labels())
  -- The overview lists them under the journey, with Resume and Forget.
  ns.JourneyOverview.Show()
  local rows = ns.JourneyOverview.SetAsideRows()
  check(#rows == 1 and rows[1]:find("On now", 1, true) and rows[1]:find("2 stops left", 1, true) and rows[1]:find("just now", 1, true),
    "the overview lists the set-aside journey: " .. tostring(rows[1]))
  local frame = ns.JourneyOverview.EnsureFrame()
  frame.aside[1].resume.scripts.OnClick(frame.aside[1].resume)
  check(ns.Nav.active.title == "On now" and ns.Nav.SetAsideList()[1].title == "Something new"
    and ns.JourneyOverview.IsShown(), "Resume swaps them, and the overview stays up")
  frame.aside[1].forget.scripts.OnClick(frame.aside[1].forget)
  check(#ns.Nav.SetAsideList() == 0 and #ns.JourneyOverview.SetAsideRows() == 0, "Forget takes it off")
  -- The pickup question's New journey sets the one on aside too.
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete }
  local log = { 10, 1 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function() return false end
  QUESTS[1].finishedBy = { { 345 } }
  refreshData()
  ns.Snackbar.Clear()
  ns.db.settings.autoAddPickups = false -- asked, not added unasked
  fire("QUEST_ACCEPTED", 1)
  runTimers()
  ns.db.settings.autoAddPickups = nil
  local snack = ns.Snackbar.Current()
  check(snack and snack.question and snack.actions[1].label == "Add to journey" and snack.actions[2].label == "New journey",
    "picking up a quest on a journey offers to add it or start a new journey")
  ns.Snackbar.Click(2)
  check(ns.Nav.active.title == "Redridge Goulash" and #ns.Nav.SetAsideList() == 1 and ns.Nav.SetAsideList()[1].title == "On now",
    "New journey sets the one on aside")
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete = savedLog[1], savedLog[2], savedLog[3]
  QUESTS[1].finishedBy = nil
  refreshData()
  StaticPopupDialogs, StaticPopup_Show = nil, nil
  -- /ww journeys lists them in chat; resume and forget by number.
  before = #chat
  SlashCmdList.WAYWARD("journeys")
  local said = table.concat(chat, "\n", before + 1)
  check(said:find("on now: Redridge Goulash", 1, true) and said:find("set aside 1: On now (2 stops left", 1, true),
    "/ww journeys lists the journey on now and the ones set aside")
  SlashCmdList.WAYWARD("journeys resume 1")
  check(ns.Nav.active.title == "On now" and ns.Nav.SetAsideList()[1].title == "Redridge Goulash", "/ww journeys resume 1")
  SlashCmdList.WAYWARD("journeys forget 1")
  check(#ns.Nav.SetAsideList() == 0, "/ww journeys forget 1")
  ns.Nav.Stop()
  ns.JourneyOverview.EnsureFrame():Hide()
  ns.charDB.journeys = nil

  -- Detail on demand: the box shows every step, or just the stop (the step on hover).
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local bank = { node = ns.Geo.Node(1453, 0.5, 0.5, "Bank"), text = "Visit the bank" }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "To Stormwind", stops = { bank } }))
  ns.HUD.Update()
  local step = ns.Router.Describe(ns.Nav.active.route, 1)
  check(ns.Nav.Detail() == "steps" and ns.HUD.Lines()[2] == step and ns.HUD.Lines()[3]:find("^Step 1 of")
    and ns.HUD.StepTooltip() == nil, "by default the box shows the step and its count: " .. ns.HUD.Lines()[2])
  SlashCmdList.WAYWARD("detail stops")
  check(ns.charDB.detail == "stops" and ns.Nav.Detail() == "stops", "/ww detail stops, per character")
  check(ns.HUD.Lines()[2] == "Visit the bank" and ns.HUD.Lines()[3] == "", "now it shows the stop, no step count: " .. ns.HUD.Lines()[2])
  local tip = ns.HUD.StepTooltip()
  check(tip and tip[1] == step and tip[2]:find("^Step 1 of"), "the step and its count are on hover: " .. tostring(tip and tip[1]))
  local hud = ns.HUD.Frame()
  hud.scripts.OnEnter(hud)
  check(GameTooltip:GetText() == step, "hovering the box shows the step")
  hud.scripts.OnLeave(hud)
  local choice
  for _, c in ipairs(ns.Options.Choices()) do
    if c.name == "Every step in the directions box" then choice = c end
  end
  check(choice and choice.section == "Navigation aid" and choice.get() == false, "the option is under navigation aid, off now")
  choice.set(true)
  check(ns.Nav.Detail() == "steps" and ns.HUD.Lines()[2] == step and ns.HUD.StepTooltip() == nil, "ticking it shows the steps again")
  SlashCmdList.WAYWARD("detail")
  check(ns.Nav.Detail() == "stops", "/ww detail alone toggles")
  goTo(bank)
  check(ns.Nav.active == nil, "arriving ends it as before")
  ns.charDB.detail = nil
  ns.Nav.Stop()
  ns.JourneyOverview.EnsureFrame():Hide()
end
-- ===== stream C: journey model (end) =====
-- ===== stream A: relevance =====
---------------------------------------------------------------- stream A: relevance (begin)
do
  io.write("stream A: relevance\n")
  ns.Nav.Stop()
  runTimers()
  local F = ns.ForYou
  local function rows()
    F.Invalidate()
    return F.Results()
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
  local function obsFind(list, kind)
    for i, o in ipairs(list) do if o.kind == kind then return o, i end end
  end
  local function kinds(list)
    local out = {}
    for _, o in ipairs(list) do out[#out + 1] = o.kind end
    return table.concat(out, ",")
  end
  local function near(a, b) return math.abs(a - b) < 0.01 end

  -- The scoring curves.
  local fit = F.LevelFit
  check(fit(20, 20) == 1 and fit(18, 20) == 1 and fit(22, 20) == 1 and near(fit(17, 20), 0.8) and fit(13, 20) == 0
    and near(fit(24, 20), 1 / 3) and fit(25, 20) == 0,
    "level fit: 1.0 within two levels, 0 at grey and five levels up")
  C_GameRules = { IsHardcoreActive = function() return true end }
  check(fit(22, 20) == 1 and fit(23, 20) == 0, "on Hardcore three levels up is already too hard")
  C_GameRules = nil
  local near0 = F.Proximity
  check(near0(60) == 1 and near0(120) == 1 and near(near0(300), 0.75) and near(near0(480), 0.5) and near(near0(990), 0.25)
    and near0(1500) == 0 and near0(3000) == 0 and near0(nil) == 0,
    "proximity: 1.0 within 2 min, 0.5 at 8, 0 past 25")
  local w = F.WEIGHTS
  check(near(w.suitability + w.proximity + w.progression + w.novelty + w.intent, 1) and w.suitability == 0.3,
    "the five weights add up to one, suitability the heaviest")

  -- Roles over synthetic rows: continue leads with progression, explore with
  -- novelty elsewhere, alternative is yet another kind; later pages repeat.
  local function row(title, kind, zone, leadPart, relevance)
    return { title = title, kind = kind, zoneKey = zone, lead = leadPart, relevance = relevance }
  end
  local A = row("A", "handin", "X", "progression", 0.9)
  local B = row("B", "zone", "Y", "novelty", 0.8)
  local C = row("C", "handin", "X", "novelty", 0.85)
  local D = row("D", "dungeon", "Z", "suitability", 0.5)
  local E = row("E", "zone", "Y", "suitability", 0.4)
  local ordered = F.AssignRoles({ A, C, B, D, E })
  local got = {}
  for _, r in ipairs(ordered) do got[#got + 1] = r.title .. "=" .. r.role end
  check(table.concat(got, ",") == "A=continue,B=explore,D=alternative,C=explore,E=alternative",
    "roles: a page mixes kinds and zones, and each card is tagged by what leads it: " .. table.concat(got, ","))
  local only = F.AssignRoles({ row("Z", "zone", "Y", "novelty", 0.3) })
  check(#only == 1 and only[1].role == "explore", "a lone card about a new zone is the exploration, not a continuation")
  local fitOnly = F.AssignRoles({ row("N", "quest", "Y", "suitability", 0.6) })
  check(fitOnly[1].role == "alternative", "a card led by fit alone is an alternative")

  -- The real cards: QuestieDB XP, a quest ready to hand in out in the hills.
  local zoneSupport = LibQuestieDB.Support.Get
  local XP = { [1] = { 18, 1500 }, [7] = { 19, 1500 }, [11] = { 17, 1500 }, [15] = { 18, 1500 },
    [6] = { 20, 1400 }, [14] = { 19, 1400 }, [20] = { 20, 1600 }, [10] = { 19, 1000 }, [50] = { 19, 1200 } }
  LibQuestieDB.Support.Get = function(name)
    if name == "QuestXP" then return { db = XP } end
    return zoneSupport(name)
  end
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives }
  NPCS[6100] = { name = "Watcher Dodds", npcFlags = 2, friendlyToFaction = "A", spawns = { [44] = { { 70.0, 70.0 } } } }
  QUESTS[50] = { name = "Watch Report", questLevel = 19, requiredLevel = 15, startedBy = { { 6100 } }, finishedBy = { { 6100 } } }
  refreshData()
  local log = { 50 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function(id) return id == 50 end
  C_QuestLog.GetQuestObjectives = function() return {} end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local savedSeen, savedKinds, savedVisited = ns.charDB.seenCards, ns.charDB.startedKinds, ns.charDB.visitedZones
  ns.charDB.seenCards, ns.charDB.startedKinds, ns.charDB.visitedZones = nil, nil, {}
  ns.Fanfare.lastNew = nil

  local list = rows()
  local ROLE_FOR = { progression = "continue", novelty = "explore" }
  local function honest(cards)
    for _, r in ipairs(cards) do
      if r.role ~= (ROLE_FOR[r.lead] or "alternative") or r.lead == "proximity" then return false end
    end
    return #cards > 0
  end
  check(#list >= 4 and honest(list), "every card is tagged by its strongest reason, never by distance: " .. titles(list))
  -- Facts: one order on every card (level, how far, what it holds), each saying what it is; no XP.
  local factsOK, seen = true, {}
  for _, r in ipairs(list) do
    local f = r.facts or {}
    local texts = {}
    for _, fact in ipairs(f) do texts[#texts + 1] = fact[2] end
    seen[#seen + 1] = table.concat(texts, ", ")
    if #f == 0 or #f > 3 or f[1][1] ~= "Level" or not f[1][2]:find("^Level %d") then factsOK = false end
    for _, fact in ipairs(f) do
      if fact[1] == "XP" or fact[2]:find("XP") then factsOK = false end
      if not fact[2]:find("%a") then factsOK = false end -- never a bare number
    end
  end
  check(factsOK, "every card's facts start with its level and say what each number is: " .. table.concat(seen, " | "))
  local zoneCard = find(list, "Quest in Redridge Mountains")
  local zf = zoneCard and zoneCard.facts or {}
  check(#zf == 3 and zf[1][2]:find("^Level %d+") and (zf[2][2] == "Nearby" or zf[2][2]:find(" away$")) and zf[3][2]:find("^%d+ quests?$"),
    "a zone card: its levels, how far, its quests")
  local first, second, third = list[1], list[2], list[3]
  check(first and second and (first.zoneKey ~= second.zoneKey or first.kind ~= second.kind),
    "the exploration is in another zone or of another kind than the continuation")
  check(third and third.kind ~= first.kind and third.kind ~= second.kind, "the alternative is of a third kind")
  local handin = find(list, "Hand in 1 quest to Watcher Dodds")
  check(handin and handin.role == "continue" and handin.lead == "progression" and handin.relevance_parts.progression == 1,
    "a quest ready to hand in leads with progression and is the continuation: " .. tostring(handin and handin.role))
  check(handin and handin.why == "Quests ready to hand in, close by",
    "its why names its two strongest parts in words: " .. tostring(handin and handin.why))
  local deadmines = find(list, "Run The Deadmines")
  check(deadmines and deadmines.relevance_parts.novelty >= 0.9 and deadmines.role == "explore"
    and deadmines.why:find("^A dungeon you haven't run"),
    "a dungeon you haven't run is the exploration, and says so: " .. tostring(deadmines and deadmines.why))
  local redridge = find(list, "Quest in Redridge Mountains")
  check(redridge and redridge.relevance_parts.novelty <= 0.2 and redridge.relevance_parts.progression == 0.7,
    "the zone you stand in: nothing new, but it continues what you're doing")
  local stats = {}
  for _, st in ipairs(redridge and redridge.stats or {}) do stats[#stats + 1] = st[1] end
  local rateStat = false
  for _, r in ipairs(list) do
    for _, st in ipairs(r.stats or {}) do if st[1] == "XP/min" or st[1] == "Quests/h" then rateStat = true end end
    for _, d in ipairs(r.details or {}) do if d.text:find("by XP per minute", 1, true) or d.text:find("^#%d+ of %d+") then rateStat = true end end
  end
  check(not rateStat, "no card shows XP per minute or a rank")
  -- Parts are rounded, 0..1, and the relevance is their weighted sum.
  local sums = #list > 0
  for _, r in ipairs(list) do
    local p = r.relevance_parts
    local total = 0
    for name, weight in pairs(w) do
      if not (p[name] >= 0 and p[name] <= 1) then sums = false end
      total = total + weight * p[name]
    end
    if not near(total, r.relevance) then sums = false end
  end
  check(sums, "relevance is the weighted sum of its five parts, each 0..1")

  -- Shown and never started: a card loses novelty slowly (never hidden for it).
  -- (With a clock the cache holds between refreshes, so each rows() is one build.)
  local clock = 1000
  GetTime = function() return clock end
  local key = redridge and (redridge.id .. "|" .. redridge.title)
  check(key and ns.charDB.seenCards[key] == 1, "a refresh counts the cards it showed")
  for _ = 1, 4 do rows() end
  local dmAgain = find(F.Results(), "Run The Deadmines")
  check(ns.charDB.seenCards[key] == 5 and dmAgain and near(dmAgain.relevance_parts.novelty, 0.9 * 0.84),
    string.format("shown five times and never started: a little less new (%.2f -> %.2f), still offered",
      deadmines and deadmines.relevance_parts.novelty or 0, dmAgain and dmAgain.relevance_parts.novelty or 0))
  F.NoteStarted(dmAgain)
  check(ns.charDB.seenCards[dmAgain.id .. "|" .. dmAgain.title] == 1 and ns.charDB.startedKinds.dungeon == 1,
    "starting it from the card resets that and learns the kind")
  local fresh = find(rows(), "Run The Deadmines")
  check(fresh and near(fresh.relevance_parts.novelty, 0.9 * 0.96), "and it is new again next time: " .. tostring(fresh and fresh.relevance_parts.novelty))
  GetTime = nil

  -- Learned intent: the kind you start most scores higher on intent.
  local before = find(F.Results(), "Quest in Redridge Mountains").relevance_parts.intent
  ns.charDB.startedKinds = { zone = 6, dungeon = 1 }
  list = rows()
  local rz, dz = find(list, "Quest in Redridge Mountains"), find(list, "Run The Deadmines")
  check(rz and dz and rz.relevance_parts.intent > before and rz.relevance_parts.intent > dz.relevance_parts.intent,
    string.format("zones started most: a zone's intent rises (%.2f -> %.2f), above the dungeon's (%.2f)", before,
      rz.relevance_parts.intent, dz.relevance_parts.intent))
  -- A journey started from a card counts its kind (journey.def.kind), once.
  ns.charDB.startedKinds = {}
  check(rz.journey and rz.journey.def.kind == "zone", "a card's journey carries its kind")
  ns.Nav.StartJourney(rz.journey)
  check(ns.charDB.startedKinds.zone == 1, "JOURNEY_STARTED learns it: " .. tostring(ns.charDB.startedKinds.zone))
  ns.Nav.Stop()
  runTimers()
  local dj = find(rows(), "Run The Deadmines")
  F.NoteStarted(dj)
  ns.Nav.StartJourney(dj.journey)
  check(ns.charDB.startedKinds.dungeon == 1, "the card button noting it first doesn't count it twice")
  ns.Nav.Stop()
  runTimers()
  -- The explicit preference hook (no setting yet): a preferred kind scores higher on intent.
  ns.charDB.startedKinds = nil
  local plainIntent = find(rows(), "Run The Deadmines").relevance_parts.intent
  ns.charDB.preferKind = "dungeon"
  local preferred = find(rows(), "Run The Deadmines")
  check(F.Preference() == "dungeon" and preferred.relevance_parts.intent > plainIntent,
    string.format("a preferred kind (the hook) scores higher on intent (%.2f -> %.2f)", plainIntent,
      preferred.relevance_parts.intent))
  ns.charDB.preferKind = nil

  -- Observations: ordered by urgency, each with one action. (All of them: the
  -- hand-in tile is held back while its card is on the first page.)
  local obs = F.Observations(true)
  local sorted = #obs > 0
  for i = 2, #obs do if obs[i].urgency > obs[i - 1].urgency then sorted = false end end
  check(sorted, "observations come most urgent first: " .. kinds(obs))
  local shaped = #obs > 0
  for _, o in ipairs(obs) do
    if not (o.id and o.kind and o.icon and o.text and o.highlights and o.urgency >= 0 and o.urgency <= 1) then shaped = false end
    local a = o.action
    if a and not (a.label and ((a.kind == "detour" and a.stop and a.stop.node) or (a.kind == "show" and a.page)
      or (a.kind == "go" and a.goal and a.route))) then shaped = false end
  end
  check(shaped, "every observation has id, kind, icon, text, highlights, urgency and at most one well-formed action")
  local ready = obsFind(obs, "handin")
  check(ready and ready.text == "1 quest ready to hand in to Watcher Dodds, <1 min away." and ready.action.kind == "detour"
    and ready.action.stop.action.kind == "turnin" and ready.action.stop.action.questID == 50
    and ready.highlights[1] == "1 quest",
    "a quest ready to hand in: an observation with its hand-in stop as a detour: " .. tostring(ready and ready.text))
  GetTime = function() return clock end
  F.Invalidate()
  obs = F.Observations()
  local function ids(list)
    local out = {}
    for _, o in ipairs(list) do out[#out + 1] = o.id end
    return table.concat(out, ",")
  end
  local runs = F.runs
  check(ids(F.Observations()) == ids(obs) and F.Results() and ids(F.Observations()) == ids(obs) and F.runs == runs,
    "observations are cached with the cards")
  F.Invalidate()
  F.Observations()
  check(F.runs == runs + 1, "and rebuilt with them")
  check(not obsFind(F.Observations(), "vendor"),
    "a vendor a couple of minutes away, with nothing to sell, isn't worth a tile")

  -- Full bags: the nearest vendor to sell at.
  local free = 0
  C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 16 or 0 end,
    GetContainerNumFreeSlots = function() return free end,
    GetContainerItemInfo = function() return nil end,
  }
  -- Empty bags have no food in them either: the food tile already sends you
  -- to a vendor, so full bags join it rather than taking a tile of their own.
  F.Invalidate()
  obs = F.Observations()
  local food = obsFind(obs, "food")
  check(food and food.text:find("Bags full: sell there too.", 1, true) and food.action.stop.text:find(" and sell$")
    and food.urgency >= 0.85 and not obsFind(obs, "bags") and not obsFind(obs, "vendor"),
    "full bags and no food: one tile for the one vendor: " .. tostring(food and food.text))
  -- Enough food: the bags tile stands on its own.
  local hadBagCount = ns.Vendors.BagCount
  ns.Vendors.BagCount = function() return 20 end
  F.Invalidate()
  obs = F.Observations()
  local bags = obsFind(obs, "bags")
  check(bags and bags.urgency == 0.85 and bags.text:find("^Bags full: the nearest vendor is ") and bags.highlights[1] == "full"
    and bags.action.kind == "detour" and bags.action.stop.text:find("^Sell at ") and not obsFind(obs, "vendor"),
    "full bags: the nearest vendor as a detour, and no separate vendor tile: " .. tostring(bags and bags.text))
  free = 2
  F.Invalidate()
  bags = obsFind(F.Observations(), "bags")
  check(bags and bags.urgency == 0.45 and bags.text:find("^Bags nearly full %(2 of 16 slots free%)"),
    "nearly full: a quieter tile: " .. tostring(bags and bags.text))
  free = 5
  F.Invalidate()
  obs = F.Observations()
  local vendor = obsFind(obs, "vendor")
  check(vendor and vendor.urgency < 0.3 and vendor.action.kind == "detour" and vendor.action.stop.text:find("^Sell at ")
    and vendor.text:find("^Bags filling up %(5 of 16 slots free%), and ") and vendor.highlights[1] == "5 of 16"
    and not obsFind(obs, "bags"),
    "bags filling up and a vendor close by: a quiet tile with the reason: " .. tostring(vendor and vendor.text))
  free = 10
  F.Invalidate()
  check(not obsFind(F.Observations(), "bags") and not obsFind(F.Observations(), "vendor"), "room in the bags: nothing to say")
  ns.Vendors.BagCount = hadBagCount
  C_Container = nil

  -- New spells at the next even level, and where the trainer is.
  local savedSpells = ns.charDB.classSpells
  ns.charDB.classSpells = { updated = 0, level = 20, services = {
    { name = "Old", type = "used", levelReq = 18 },
    { name = "Shadow Bolt", rank = "Rank 5", type = "unavailable", levelReq = 22, cost = 2000 },
    { name = "Curse of Weakness", rank = "Rank 3", type = "unavailable", levelReq = 22, cost = 1500 } } }
  F.Invalidate()
  obs = F.Observations()
  local abilities = obsFind(obs, "abilities")
  check(abilities and abilities.text:find("^2 new spells at level 22: your trainer is ") and abilities.text:find("in Stormwind", 1, true)
    and abilities.action.kind == "show" and abilities.action.page == "trainers" and abilities.highlights[2] == "level 22"
    and not obsFind(obs, "train"),
    "two levels ahead: new spells at level 22, naming the trainer, with the Trainers page to look at: "
    .. tostring(abilities and abilities.text))
  ns.charDB.classSpells.services[2].levelReq, ns.charDB.classSpells.services[3].levelReq = 24, 24
  F.Invalidate()
  check(not obsFind(F.Observations(), "abilities"), "four levels ahead: not yet")
  ns.charDB.classSpells = savedSpells

  -- /ww debug cards prints each card's role, relevance and parts, and each observation.
  F.Invalidate()
  local wasShown = ns.Panel.IsShown()
  ns.Panel.Search("foryou")
  local said = #chat
  SlashCmdList.WAYWARD("debug cards")
  local printed = table.concat(chat, "\n", said + 1)
  check(printed:find("card 1 [continue] ", 1, true) and printed:find("relevance %d%.%d%d %(suitability %d%.%d%d, proximity")
    and printed:find("; why: ", 1, true) and printed:find("card 2 %[%a+%] ")
    and printed:find("observation 1 [", 1, true) and printed:find("urgency %d%.%d%d: "),
    "/ww debug cards prints roles, relevance, parts, why and the observations")
  local lines = F.Diagnose()
  check(#lines >= 4 and lines[1]:find("^card 1 %[continue%]"), "ForYou.Diagnose has the same lines")
  if not wasShown then ns.Panel.Toggle() end

  -- Cards hidden by the journey keep the roles whole: the next page is re-rolled.
  GetTime = nil
  local here = ns.Geo.PlayerNode()
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Just the hand-in", stops = ns.Journey.QuestStops(50, here) }), true)
  list = F.Results()
  local held = #list >= 3 and not find(list, "Hand in 1 quest to Watcher Dodds") and honest(list)
  check(held, "with the hand-in on your journey, the cards left keep honest tags: " .. titles(list))
  -- Nothing the journey already does: the hand-in tile goes, and Find offers no detour to it.
  check(not obsFind(F.Observations(), "handin"), "a hand-in on your journey gets no tile of its own: " .. kinds(F.Observations()))
  local onJourney = ns.Search.WithDetour({ title = "Watcher Dodds",
    journey = ns.Journey.Plan(here, { title = "Watcher Dodds", stops = ns.Journey.QuestStops(50, here) }) })
  check(not onJourney.actions, "Find offers no detour to what the journey already has")
  local elsewhere = ns.Search.WithDetour({ title = "Elsewhere", goal = ns.Geo.Node(1433, 0.7, 0.7, "Elsewhere"),
    route = { steps = {}, seconds = 60 } })
  check(elsewhere.actions and elsewhere.actions[1].label == "Add detour", "but does to somewhere new")
  -- Set aside: its quests aren't suggested again; a tile offers to resume it.
  ns.Nav.SetAside()
  list = F.Results()
  check(not find(list, "Hand in 1 quest to Watcher Dodds"), "a set-aside journey's quests get no card: " .. titles(list))
  local resume = obsFind(F.Observations(), "setaside")
  check(resume and resume.text == "You set aside Just the hand-in, 1 stop left." and resume.action.kind == "resume",
    "a tile offers to resume it: " .. tostring(resume and resume.text))
  check(ns.Observations.Run(resume) and ns.Nav.active and ns.Nav.active.title == "Just the hand-in"
    and #ns.Nav.SetAsideList() == 0 and not obsFind(F.Observations(), "setaside"),
    "Resume starts it again, and the tile goes")
  ns.Nav.Stop()
  runTimers()
  -- A detour tile brings every stop it has, not only the first.
  local two = { { node = ns.Geo.Node(1433, 0.52, 0.5, "One"), text = "One" },
    { node = ns.Geo.Node(1433, 0.56, 0.5, "Two"), text = "Two" } }
  ns.Observations.Run({ text = "Two hand-ins", action = { kind = "detour", stop = two[1], stops = two } })
  local root = ns.Nav.active and ns.Nav.active.journey and (ns.Nav.active.journey.root or ns.Nav.active.journey.def)
  check(root and #root.stops == 2, "a detour tile adds all its stops: " .. tostring(root and #root.stops))
  ns.Nav.Stop()
  runTimers()

  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]
  LibQuestieDB.Support.Get = zoneSupport
  QUESTS[50], NPCS[6100] = nil, nil
  ns.charDB.seenCards, ns.charDB.startedKinds, ns.charDB.visitedZones = savedSeen, savedKinds, savedVisited
  refreshData()
  F.Invalidate()
end
---------------------------------------------------------------- stream A: relevance (end)
---------------------------------------------------------------- stream B: home screen (begin)
-- ===== stream B: home screen =====
do
  io.write("stream B: home screen\n")
  local Box, Obs = ns.JourneyBox, ns.Observations
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  if not ns.Panel.IsShown() then ns.Panel.Toggle() end
  ns.Panel.Search("foryou", "")
  local here = ns.Geo.PlayerNode()
  local goal = ns.Geo.Node(1433, 0.6, 0.5, "Camp")
  local route = ns.Router.Plan(here, goal, ns.Network.Build())
  local function stopTexts()
    local out = {}
    for _, stop in ipairs(ns.Nav.active and ns.Nav.active.journey and ns.Nav.active.journey.stops or {}) do
      out[#out + 1] = stop.text
    end
    return table.concat(out, ",")
  end

  -- The header: your level and zone.
  check(ns.Panel.Headline() == string.format("Level %d  ·  Redridge Mountains", UnitLevel("player")),
    "the header says your level and zone: " .. tostring(ns.Panel.Headline()))

  -- Your journey, with nothing on: one line, and the regions below move up.
  check(Box.State() == "none" and Box.Lines()[1] == "No journey on the go. Pick something below.",
    "no journey: one line (" .. tostring(Box.Lines()[1]) .. ")")
  local collapsed = Box.Frame().height

  -- Plain directions: the destination, "Directions", Continue.
  ns.Nav.Start("Camp", goal, route)
  local lines = Box.Lines()
  check(Box.State() == "directions" and lines[1] == "Camp" and lines[2]:find("^Directions") and lines[3]:find("remaining$"),
    "plain directions: the destination and Directions (" .. table.concat(lines, " / ") .. ")")
  local continue, details = Box.Buttons()
  check(continue == "Continue" and details == nil, "with Continue and no View details")
  check(Box.Frame().height > collapsed, "the box opens up for it")
  ns.Nav.Stop()
  check(Box.State() == "none", "ending the directions collapses it again")

  -- A journey: icon, title, the current stop, stops done, time remaining, the map.
  local def = { title = "The Perfect Stout", kind = "quest", icon = "Interface\\Icons\\INV_Drink_05", stops = {
    { node = ns.Geo.Node(1433, 0.52, 0.5, "Lakeshire"), text = "Talk to the innkeeper" },
    { node = ns.Geo.Node(1433, 0.6, 0.5, "Camp"), text = "Find Shimmerweed" },
    { node = ns.Geo.Node(1433, 0.7, 0.5, "Tower"), text = "Hand in the stout" } } }
  ns.Nav.StartJourney(ns.Journey.Plan(here, def))
  if ns.JourneyOverview.IsShown() then ns.JourneyOverview.Toggle() end
  lines = Box.Lines()
  check(Box.State() == "journey" and lines[1] == "The Perfect Stout" and lines[2] == "Talk to the innkeeper"
    and lines[3]:find("^Stop 1 of 3  ·  0 complete  ·  .* remaining$") and lines[4] == "Then: Find Shimmerweed, and 1 more stop.",
    "a journey: title, the current stop on its own line, where it is with stops done and time left, what comes next ("
      .. table.concat(lines, " / ") .. ")")
  continue, details = Box.Buttons()
  check(continue == "Continue journey" and details == "View details", "with Continue journey and View details")
  local a = ns.Nav.active
  check(Box.Progress().stopIndex == 1 and Box.Progress().total == 3 and Box.Progress().done == 0,
    "the local progress helper counts the stops")
  -- The first stop done, the journey moved on: the box follows on NAV_CHANGED.
  a.journey.stops[1].done = true
  for k, step in ipairs(a.route.steps) do
    if step.stop == a.journey.stops[1] then a.index = k + 1 end
  end
  ns.Fire("NAV_CHANGED")
  lines = Box.Lines()
  check(lines[2] == "Find Shimmerweed" and lines[3]:find("^Stop 2 of 3  ·  1 complete  ·  "),
    "a stop done: the box moves on (" .. lines[2] .. " / " .. lines[3] .. ")")
  -- The navigator's own Nav.Progress wins when it exists.
  local hadProgress = ns.Nav.Progress
  ns.Nav.Progress = function()
    return { done = 2, total = 5, seconds = 360, stopIndex = 3, stopText = "Find Shimmerweed in Dun Morogh" }
  end
  ns.Panel.Layout()
  lines = Box.Lines()
  check(lines[2] == "Find Shimmerweed in Dun Morogh" and lines[3] == "Stop 3 of 5  ·  2 complete  ·  ~6 min remaining",
    "with Nav.Progress, its numbers (" .. lines[2] .. " / " .. lines[3] .. ")")
  ns.Nav.Progress = hadProgress
  -- Continue journey closes the window and brings up the directions box.
  Box.Continue()
  check(not ns.Panel.IsShown() and ns.HUD.Frame() ~= nil and ns.HUD.Frame():IsShown(),
    "Continue journey closes the window and shows the directions box")
  ns.Panel.Toggle()
  Box.Frame().details.scripts.OnClick()
  check(ns.JourneyOverview.IsShown(), "View details opens the journey overview")
  ns.JourneyOverview.Toggle()

  -- Something to do next: the role tags, the why line, the facts, the button.
  local rows = {
    { title = "Continue questing in Redridge", kind = "zone", role = "continue", why = "Picks up where your log left off, 4 min away",
      goal = goal, route = route, journey = ns.Journey.Plan(here, { title = "Redridge", stops = { { node = goal, text = "Visit Camp" } } }),
      stats = { { "Where", "Nearby" }, { "Level", "8-10" }, { "Travel", "~4 min away" } }, details = { { text = "rank" } } },
    { title = "Explore Loch Modan", kind = "zone", role = "explore", why = "A zone you haven't seen, with 6 quests at your level",
      goal = goal, route = route, category = "Questing zone" },
    { title = "Run The Stockade  ·  level 23", kind = "dungeon", role = "alternative", goal = goal, route = route,
      details = { { text = "|cffffd200#3 of 5 by XP per minute|r" } } },
    { title = "Train new spells", kind = "train", role = "continue", category = "Due now", goal = goal, route = route },
    { title = "No role", category = "Questing zone", goal = goal, route = route },
    { title = "Nothing known", goal = goal, route = route },
  }
  ns.Cards.Show(rows, "", true)
  check(ns.Cards.Tag(1) == "QUESTING" and ns.Cards.Tag(2) == "EXPLORE" and ns.Cards.Tag(3) == "DUNGEON",
    "the tags say the activity, not the role: QUESTING, EXPLORE, DUNGEON (" .. ns.Cards.Tag(1) .. ", " .. ns.Cards.Tag(2)
      .. ", " .. ns.Cards.Tag(3) .. ")")
  check(ns.Cards.Why(1) == rows[1].why and ns.Cards.Why(3) == "#3 of 5 by XP per minute",
    "the why line, or the first detail without one: " .. tostring(ns.Cards.Why(3)))
  check(table.concat(ns.Cards.Stats(1), ",") == "WHERE=Nearby,LEVEL=8-10,TRAVEL=~4 min away",
    "the facts row: " .. table.concat(ns.Cards.Stats(1), ","))
  check(ns.Cards.Drawn()[1] == "Continue questing in Redridge|Start journey" and ns.Cards.Drawn()[2] == "Explore Loch Modan|Directions",
    "Start journey for a journey, Directions for a route: " .. table.concat(ns.Cards.Drawn(), ","))
  ns.Cards.Step(-1)
  check(ns.Cards.Tag(1) == "DUE NOW" and ns.Cards.Tag(2) == "QUESTING ZONE" and ns.Cards.Tag(3) == "SUGGESTION",
    "a kind without a tag of its own: its category; nothing at all: SUGGESTION ("
    .. ns.Cards.Tag(1) .. ", " .. ns.Cards.Tag(2) .. ", " .. ns.Cards.Tag(3) .. ")")
  check(ns.Cards.Stats(3)[1] ~= nil and (ns.Cards.Stats(3)[1]:find("^TRAVEL=") or ns.Cards.Stats(3)[1] == "NEARBY=Nearby"),
    "without stats, the facts come from the route: " .. table.concat(ns.Cards.Stats(3), ","))
  ns.Cards.Step(10)

  -- Start journey while a journey is on: Add as detour / Switch journey / Cancel.
  local shown
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which, now, label, data) shown = { which = which, now = now, label = label, data = data } end
  local hadNote, noted = ns.ForYou.NoteStarted, nil
  ns.ForYou.NoteStarted = function(r) noted = r.title end
  local function journeyRow(title, x, text)
    return { title = title, journey = ns.Journey.Plan(ns.Geo.PlayerNode(),
      { title = title, stops = { { node = ns.Geo.Node(1433, x, 0.52, text), text = text } } }) }
  end
  local shore = journeyRow("Shore camp", 0.55, "Visit Shore")
  ns.Panel.Activate(shore)
  check(shown and shown.which == "WAYWARD_SWITCH" and shown.now:find("The Perfect Stout", 1, true) and shown.label == "Shore camp"
    and ns.Nav.active.title == "The Perfect Stout" and noted == nil,
    "Start journey during a journey asks: detour, switch or cancel; nothing changes until you answer")
  StaticPopupDialogs.WAYWARD_SWITCH.OnAccept(nil, shown.data)
  check(stopTexts():find("Visit Shore", 1, true) and stopTexts():find("Find Shimmerweed", 1, true) and noted == nil,
    "Add as detour merges it into the journey on now: " .. stopTexts())
  local setAside = 0
  local hadSetAside = ns.Nav.SetAside
  ns.Nav.SetAside = function() setAside = setAside + 1; ns.Nav.Stop() end
  shown = nil
  local hill = journeyRow("Over the hill", 0.58, "Visit the hill")
  ns.Panel.Activate(hill)
  StaticPopupDialogs.WAYWARD_SWITCH.OnAlt(nil, shown.data)
  check(setAside == 1 and ns.Nav.active.title == "Over the hill" and noted == "Over the hill",
    "Switch journey sets the journey aside, starts the new one and tells For you: " .. tostring(ns.Nav.active.title))
  ns.Nav.SetAside = hadSetAside
  shown = nil
  local lake = journeyRow("Lake run", 0.61, "Visit the lake")
  ns.Panel.Activate(lake)
  StaticPopupDialogs.WAYWARD_SWITCH.OnAlt(nil, shown.data)
  check(ns.Nav.active.title == "Lake run" and stopTexts() == "Visit the lake",
    "without Nav.SetAside, Switch journey ends the old one: " .. stopTexts())
  StaticPopupDialogs, StaticPopup_Show = nil, nil
  ns.Panel.Activate(hill)
  check(ns.Nav.active.title == "Over the hill", "without the game's dialogs it switches straight away")
  if not ns.Panel.IsShown() then ns.Panel.Toggle() end
  ns.Panel.Search("foryou", "")

  -- Good to know: up to four tiles, highlights in gold, one action each.
  local repairStop = { node = ns.Geo.Node(1433, 0.51, 0.5, "Blacksmith"), text = "Repair at the blacksmith" }
  local handinStop = { node = ns.Geo.Node(1433, 0.53, 0.5, "Lakeshire"), text = "Hand in Wanted: Bellygrub" }
  local observations = {
    { id = "train", kind = "train", icon = "Interface\\Icons\\INV_Misc_Book_09", urgency = 0.5,
      text = "New class abilities become available at level 10 in Ironforge.", highlights = { "level 10" },
      action = { label = "Show trainers", kind = "show", page = "trainers" } },
    { id = "repair", kind = "repair", urgency = 0.9, text = "Your gear is at 81% durability. A repair vendor is <1 min away.",
      highlights = { "81%" }, action = { label = "Add detour", kind = "detour", stop = repairStop, title = "Repair" } },
    { id = "handin", kind = "handin", text = "You have 1 completed quest ready to hand in.", highlights = { "1 completed" },
      action = { kind = "detour", stop = handinStop } },
    { id = "vendors", kind = "vendor", text = "Food, drink and ammo vendors are nearby.",
      action = { kind = "go", goal = goal, route = route, title = "Vendors" } },
    { id = "fifth", kind = "other", text = "A fifth one that doesn't fit." },
  }
  local hadObservations = ns.ForYou.Observations
  ns.ForYou.Observations = function() return observations end
  ns.Panel.Refresh()
  local tiles = Obs.Tiles()
  check(#tiles == 4 and tiles[1].text == "New class abilities become available at |cffffd200level 10|r in Ironforge."
    and tiles[1].label == "Show trainers",
    "up to four tiles, the highlights in gold, the action as a button: " .. tostring(tiles[1] and tiles[1].text))
  check(tiles[2].text:find("|cffffd20081%|r", 1, true) ~= nil and tiles[2].label == "Add detour" and tiles[3].label == "Add detour"
    and tiles[4].label == "Go", "a button per action kind, named by the kind when the action has no label")
  local tile = Obs.Frame().tiles[1]
  tile.scripts.OnEnter(tile)
  check(GameTooltip:GetText() == tiles[1].text, "hovering a tile shows its full text")
  tile.scripts.OnLeave(tile)
  Obs.Act(1)
  check(ns.Panel.SideShown() and ns.Panel.SelectedTab() == "trainers", "Show opens the side page")
  ns.Panel.CloseSide()
  Obs.Act(2)
  check(stopTexts():find("Repair at the blacksmith", 1, true) and stopTexts():find("Visit the hill", 1, true),
    "Add detour puts the observation's stop into the journey on now: " .. stopTexts())
  ns.Nav.Stop()
  Obs.Act(3)
  check(ns.Nav.active and ns.Nav.active.journey and stopTexts() == "Hand in Wanted: Bellygrub",
    "with no journey on, Add detour starts one: " .. stopTexts())
  ns.Nav.Stop()
  Obs.Act(4)
  check(ns.Nav.active and not ns.Nav.active.journey and ns.Nav.active.title == "Vendors" and not ns.Panel.IsShown(),
    "Go starts plain directions and closes the window")
  ns.Nav.Stop()
  ns.ForYou.Observations = hadObservations
  ns.ForYou.NoteStarted = hadNote
  ns.Panel.Toggle()
  ns.Panel.Search("foryou", "")
  if hadObservations == nil then
    check(#Obs.Tiles() == 0 and Obs.Frame().none:IsShown(), "without ForYou.Observations the region says there's nothing")
  end
  check(Box.State() == "none", "and the journey box is back to its one line")
  ns.Panel.Toggle()
end
---------------------------------------------------------------- stream B: home screen (end)
-- ===== stream D: find =====
do
  io.write("stream D: find\n")
  ns.Nav.Stop()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local Search = ns.Search

  -- Fixtures: items to rank, an innkeeper flag, zones for C_Map, a flight
  -- master you met, a trainer reading with one spell to learn.
  ITEMS[9010] = { name = "Fin" }
  ITEMS[9011] = { name = "Fine Axe" }
  ITEMS[9002] = ITEMS[9002] or { name = "Murloc Fin", itemLevel = 15, npcDrops = { 9101, 9102, 9103 } }
  ITEMS[9005] = ITEMS[9005] or { name = "Fine Longbow", vendors = { 7004, 7001 }, npcDrops = { 9105 } }
  LibQuestieDB.Enum.npcFlags.INNKEEPER = 128
  QUESTS[10].finishedBy = { { 345 } }
  refreshData()
  local savedChildren = C_Map.GetMapChildrenInfo
  C_Map.GetMapChildrenInfo = function(mapID, mapType)
    if mapType ~= Enum.UIMapType.Zone then return savedChildren(mapID, mapType) end
    local out = {}
    for id, z in pairs(ZONES) do
      if z.cont == mapID then out[#out + 1] = { mapID = id, name = z.name } end
    end
    table.sort(out, function(a, b) return a.mapID < b.mapID end)
    return out
  end
  ns.db.npcs[990003] = { name = "Ariena Stormfeather", kinds = { flightMaster = true }, mapID = 1433, x = 0.515, y = 0.69 }
  local savedClassSpells = ns.charDB.classSpells
  ns.charDB.classSpells = { updated = 0, level = 20, services = {
    { name = "Life Tap", type = "available", levelReq = 20, cost = 1000, spellID = 1454 },
    { name = "Corruption", type = "unavailable", levelReq = 24, cost = 2700, spellID = 172 } } }
  ns.charDB.skippedSpells = nil
  fire("SPELLS_CHANGED")
  ns.Fire("DATA_CHANGED")

  -- Parsing.
  local function parse(text)
    local kind, id, name = Search.Parse(text)
    return tostring(kind) .. ":" .. tostring(id) .. ":" .. tostring(name)
  end
  check(parse("|cffffff00|Hquest:1:18|h[Redridge Goulash]|h|r") == "quest:1:Redridge Goulash", "Parse: a quest link")
  check(parse("|cffa335ee|Hitem:9001::::::::20:::::|h[Cruel Barb]|h|r") == "item:9001:Cruel Barb", "Parse: an item link")
  check(parse("|cff71d5ff|Hspell:1454:0|h[Life Tap]|h|r") == "spell:1454:Life Tap", "Parse: a spell link")
  check(parse("item:9002") == "item:9002:nil" and parse(" #12 ") == "nil:12:nil" and parse("12") == "nil:12:nil"
    and parse("Cruel Barb") == "nil:nil:nil", "Parse: item:N, #N, a bare number, plain text")
  check(parse("|cffffff00|hquest:1:18|h[redridge goulash]|h|r") == "quest:1:redridge goulash",
    "Parse: a lower-cased link (a command's text) still parses")

  -- Ranking and kinds.
  local function names(list)
    local t = {}
    for _, m in ipairs(list) do t[#t + 1] = m.name end
    return table.concat(t, " | ")
  end
  local found = Search.Find("fin", "item")
  check(names(found) == "Fin | Fine Axe | Fine Longbow | Murloc Fin" and found[1].score == 400 and found[2].score == 300
    and found[3].score == 300 and found[4].score == 200,
    "items ranked exact, prefix (shorter first), substring: " .. names(found))
  check(names(Search.Find("FIN", { "item" })) == names(found), "case doesn't matter, and kinds can be a list")
  found = Search.Find("warlock trainer", "npc")
  check(names(found):find("Demisette Cloyce", 1, true) and names(found):find("Ursula Deline", 1, true)
    and found[1].score == 100 and found[1].kind == "npc", "people by role: " .. names(found))
  found = Search.Find("demisette", "npc")
  check(#found == 1 and found[1].id == 461 and found[1].score == 300 and found[1].roles.classTrainer
    and found[1].class == "WARLOCK", "people by name, with their roles")
  found = Search.Find("armorer")
  check(found[1] and found[1].kind == "npc" and found[1].name == "Stormwind Armorer" and found[1].roles.vendor
    and found[1].roles.repair, "a vendor by its subtitle, with the repair flag: " .. names(found))
  found = Search.Find("lakeshire", "place")
  check(found[1] and found[1].name == "Lakeshire" and found[1].node, "flight-path towns are places")
  found = Search.Find("wetlands", "zone")
  check(#found == 1 and found[1].id == 1437 and found[1].kind == "zone", "zones from the continents' maps")
  found = Search.Find("deadmines", "dungeon")
  check(found[1] and found[1].name == "The Deadmines" and found[1].dungeon and found[1].dungeon.entrances[1],
    "dungeons from the catalogue")
  found = Search.Find("tailor", "profession")
  check(found[1] and found[1].name == "Tailoring" and found[1].score == 300, "professions: " .. names(found))
  found = Search.Find("life tap", "spell")
  check(found[1] and found[1].name == "Life Tap" and found[1].score == 400 and found[1].service,
    "your class's spells, from your trainer visit")
  found = Search.Find("chain part", "quest")
  check(#found == 2 and found[1].quest and found[1].kind == "quest", "quests: " .. names(found))
  found = Search.Find("fin")
  check(found[1] and found[1].name == "Fin" and found[1].kind == "item", "with no kinds, everything is searched")
  check(#Search.Find("") == 0 and #Search.Find("   ") == 0, "nothing for nothing")
  found = Search.Find("item:9002")
  check(#found == 1 and found[1].kind == "item" and found[1].id == 9002 and found[1].score == 400, "an ID finds that one thing")
  found = Search.Find("#1", { "quest", "item" })
  check(#found == 1 and found[1].kind == "quest" and found[1].id == 1, "#N takes the first kind that has it")
  local wrapped = ns.Quests.FindQuests("chain part")
  check(#wrapped == 2 and wrapped[1].id and wrapped[1].name:find("Chain part", 1, true),
    "Quests.FindQuests still answers quest rows, through Search")
  ITEMS[9012] = { name = "Finch Feather" }
  check(#Search.Find("finch", "item") == 0, "an index is kept until the data changes")
  refreshData()
  check(names(Search.Find("finch", "item")) == "Finch Feather", "and rebuilt after SOURCES_CHANGED")
  -- A quest handed in, an NPC met: the item and quest indexes (from the data
  -- sources) are kept, as rebuilding them mid-search runs too long; the NPCs
  -- are rebuilt in the background.
  local items, quests, npcs = Search.Index("item"), Search.Index("quest"), Search.Index("npc")
  ns.Fire("DATA_CHANGED", "npcs")
  check(Search.Index("item") == items and Search.Index("quest") == quests, "DATA_CHANGED keeps the item and quest indexes")
  local rebuilt = Search.Index("npc")
  check(rebuilt ~= npcs and #rebuilt == #npcs, "and rebuilds the NPCs")

  local here, net = ns.Geo.PlayerNode(), ns.Network.Build()
  local repair = Search.NearestNPC("repair", here, net)
  check(repair and repair.name == "Redridge Smith" and repair.route, "NearestNPC: the nearest repairer by travel time")
  local fm = Search.NearestNPC("flightMaster", here, net)
  check(fm and fm.name == "Ariena Stormfeather", "NearestNPC: a flight master you met")
  check(Search.RoleText(Search.Get("npc", 7002)) == "Armorer"
    and Search.RoleText({ roles = { vendor = true, repair = true } }) == "Vendor, Repairs", "RoleText")

  -- The Find page.
  local page, quests
  for _, p in ipairs(ns.pages) do
    if p.id == "find" then page = p end
    if p.id == "quests" then quests = p end
  end
  local labels = {}
  for _, c in ipairs(page.categories) do labels[#labels + 1] = c.label end
  check(page.order == 5 and page.searchable and page.icon:find("QuestionMark") and table.concat(labels, ",") == "All,Quests,Items,People,Places",
    "Find page: order 5, searchable, the ? icon, five views")
  check(quests and not quests.icon, "the Quests tab's icon comes from the panel (Find took the question mark)")
  local function visible()
    local t = {}
    for _, r in ipairs(ns.Panel.VisibleResults()) do t[#t + 1] = r.title end
    return table.concat(t, " | ")
  end
  local function byID(list, id)
    for _, r in ipairs(list) do if r.id == id then return r end end
  end
  ns.Panel.Search("find", "fin")
  check(ns.Panel.SideShown() and ns.Panel.SelectedTab() == "find" and visible():find("^Fin | Fine Axe | Fine Longbow"),
    "All: item matches as rows to pick: " .. visible())
  check(ns.Panel.VisibleResults()[1].actions[1].label == "Show" and page.SummaryText("fin"):find("matching \"fin\"", 1, true),
    "with a Show action and a summary: " .. page.SummaryText("fin"))
  ns.Find.Open("quests", "chain")
  check(ns.Panel.SelectedTab() == "find" and page.selected == 2 and visible():find("Chain part 1", 1, true),
    "Quests view: the Quests page's rows: " .. visible())
  SlashCmdList.WAYWARD("quest chain")
  check(page.selected == 2 and visible():find("Chain part 1", 1, true), "/ww quest opens Find on Quests")
  SlashCmdList.WAYWARD("item item:9002")
  check(page.selected == 3 and visible():find("Drops from Murloc Forager", 1, true), "/ww item opens Find on Items: " .. visible())
  SlashCmdList.WAYWARD("find murloc")
  check(page.selected == 1 and visible():find("Murloc Fin", 1, true), "/ww find searches everything: " .. visible())
  ns.Panel.Search("find", "|cffffff00|Hquest:1:18|h[Redridge Goulash]|h|r")
  check(visible():find("[18] Redridge Goulash", 1, true), "a quest link in All shows the quest's row: " .. visible())
  ns.Panel.Search("find", "x")
  check(#ns.Panel.VisibleResults() == 0 and page.EmptyText("x"):find("at least 2"), "one letter is too short")
  check(page.EmptyText("zzzz"):find("Nothing called \"zzzz\"", 1, true), "no match says so")

  -- People: your own trainer gets the Trainers row with its spells and a learn stop.
  ns.Find.Open("people", "warlock trainer")
  local rows = ns.Panel.VisibleResults()
  local v = visible()
  check(v:find("Demisette Cloyce", 1, true) and v:find("Ursula Deline", 1, true) and not v:find("Horde Warlock", 1, true),
    "People: trainers by role, the other faction's left out: " .. v)
  local demisette = byID(rows, 461)
  local stop = demisette and demisette.journey and demisette.journey.stops[1]
  check(demisette and demisette.route and stop and stop.action.kind == "learn" and stop.npc == "Demisette Cloyce"
    and stop.text == "Learn 1 new spell from Demisette Cloyce" and #stop.action.spells == 1,
    "your own trainer: the Trainers row, a journey ending in a learn stop: "
    .. tostring(stop and stop.text))
  local detail = {}
  for _, d in ipairs(demisette and demisette.details or {}) do detail[#detail + 1] = d.text end
  detail = table.concat(detail, " / ")
  check(detail:find("Life Tap  -  10s", 1, true) and detail:find("More at level 24", 1, true),
    "with the spells to learn in the details: " .. detail)
  ns.Journey.STOP_KINDS = { learn = true }
  local learn
  for _, r in ipairs(ns.Trainers.Results()) do
    if r.id == 461 then learn = r.journey and r.journey.stops[1] end
  end
  check(learn and learn.action.kind == "learn" and learn.action.spells[1] == 1454 and learn.action.npc == "Demisette Cloyce",
    "with Journey.STOP_KINDS.learn, a learn stop with the spells")
  ns.Journey.STOP_KINDS = nil
  ns.Find.Open("people", "life tap")
  local spell = ns.Panel.VisibleResults()[1]
  check(spell and spell.kind == "spell" and spell.title == "Life Tap" and spell.journey and spell.subtitle:find("^Learn it from"),
    "a spell: where to learn it: " .. tostring(spell and spell.subtitle))

  -- Places: a zone goes to its flight-path town, or to where the way crosses in; towns and dungeons.
  ns.Find.Open("places", "wetlands")
  local zone = ns.Panel.VisibleResults()[1]
  check(zone and zone.title == "Wetlands" and zone.kind == "zone" and zone.route
    and zone.goal.label == "Wetlands (Menethil Harbor)" and zone.subtitle:find("^Zone"),
    "a zone: directions to its flight-path town: " .. tostring(zone and zone.goal and zone.goal.label))
  ns.Find.Open("places", "elwynn")
  zone = ns.Panel.VisibleResults()[1]
  check(zone and zone.title == "Elwynn Forest" and zone.route and zone.goal.label == "Elwynn Forest"
    and zone.details[1].text:find("crosses into it", 1, true),
    "a zone without a flight path: to where the way crosses its border: " .. tostring(zone and zone.details[1].text))
  ns.Find.Open("places", "lakeshire")
  local town = ns.Panel.VisibleResults()[1]
  check(town and town.kind == "place" and town.title == "Lakeshire" and town.route and town.subtitle:find("^Town"),
    "a town: directions to its flight master")
  ns.Find.Open("places", "deadmines")
  local dungeon = ns.Panel.VisibleResults()[1]
  check(dungeon and dungeon.kind == "dungeon" and dungeon.title:find("^The Deadmines") and dungeon.goal and dungeon.dungeon,
    "a dungeon: the Dungeons page's row: " .. tostring(dungeon and dungeon.title))

  -- Where am I stuck? (no text)
  C_QuestLog.GetQuestObjectives = function(id)
    if id == 10 then return { { text = "Murloc Fin: 3/8", finished = false } } end
    return {}
  end
  ns.Find.Open("all", "")
  rows = ns.Panel.VisibleResults()
  v = visible()
  local objective = byID(rows, "objective10")
  check(objective and objective.title == "Where do I find Murloc Fin?" and objective.journey
    and objective.journey.stops[#objective.journey.stops].action.kind == "turnin"
    -- (Classic Era's log stub has no title: "Quest 10".)
    and (objective.subtitle:find("Already in log", 1, true) or objective.subtitle:find("Quest 10", 1, true)),
    "no text: a log quest with something left, as a journey for what's left: " .. v)
  local trainer = byID(rows, "trainer")
  check(trainer and trainer.title == "Where is my class trainer?" and trainer.journey and trainer.route
    and (trainer.subtitle:find("Cloyce", 1, true) or trainer.subtitle:find("Deline", 1, true)),
    "'Where is my class trainer?': " .. tostring(trainer and trainer.subtitle))
  local repairRow = byID(rows, "repair")
  check(repairRow and repairRow.title == "Nearest repair" and repairRow.subtitle:find("Redridge Smith", 1, true) and repairRow.route,
    "'Nearest repair': " .. tostring(repairRow and repairRow.subtitle))
  local flight = byID(rows, "flight")
  check(flight and flight.title == "Nearest flight master" and flight.goal.npc == "Ariena Stormfeather" and flight.route,
    "'Nearest flight master': " .. tostring(flight and flight.subtitle))
  check(not byID(rows, "stop") and page.SummaryText(""):find("Likely questions", 1, true),
    "no journey: no current-stop row; the summary says what the list is")
  ns.Find.Open("quests", "")
  check(byID(ns.Panel.VisibleResults(), "log10") and page.SummaryText(""):find("Your quest log", 1, true),
    "Quests with no text: the Journal (your log)")
  ns.Find.Open("items", "")
  check(#ns.Panel.VisibleResults() == 0 and page.EmptyText(""):find("dungeon drop", 1, true), "Items with no text: the Items hint")

  -- On a journey: the current stop comes first.
  local goulash
  for _, r in ipairs(ns.QuestsPage.Results("redridge goulash")) do
    if r.id == "quest1" then goulash = r end
  end
  ns.Nav.StartJourney(goulash.journey)
  ns.Find.Open("all", "")
  rows = ns.Panel.VisibleResults()
  check(rows[1] and rows[1].id == "stop" and rows[1].title == "Where is Magistrate Solomon?" and rows[1].route
    and rows[1].subtitle:find("Pick up Redridge Goulash from Magistrate Solomon", 1, true),
    "on a journey: the current stop comes first: " .. tostring(rows[1] and rows[1].title))
  ns.Find.Open("people", "")
  rows = ns.Panel.VisibleResults()
  check(rows[1] and rows[1].id == "stop" and byID(rows, "trainer") and byID(rows, "repair") and byID(rows, "flight")
    and not byID(rows, "objective10"), "People with no text: the stop (someone to talk to), trainer, repair, flight master")
  ns.Find.Open("places", "")
  rows = ns.Panel.VisibleResults()
  local inn = byID(rows, "inn")
  check(byID(rows, "flight") and inn and inn.subtitle:find("Innkeeper Farley", 1, true) and not byID(rows, "stop"),
    "Places with no text: the nearest flight master and inn: " .. tostring(inn and inn.subtitle))

  -- Add detour on every row kind while a journey is on.
  local function detourLabel(r) return r and r.actions and r.actions[1] and r.actions[1].label end
  check(detourLabel(byID(ns.QuestsPage.Results("lakeshire logs"), "quest7")) == "Add detour", "quest rows: Add detour")
  check(detourLabel(ns.Items.Results("item:9002")[1]) == "Add detour", "item source rows: Add detour")
  check(detourLabel(ns.Trainers.Results()[1]) == "Add detour", "trainer rows: Add detour")
  check(detourLabel(ns.Vendors.Results()[1]) == "Add detour", "vendor rows: Add detour")
  check(detourLabel(ns.QuestHubs.Results()[1]) == "Add detour", "hub rows: Add detour")
  local dm
  for _, d in ipairs(ns.Dungeons.Results()) do
    if d.title:find("^The Deadmines") then dm = d end
  end
  check(detourLabel(dm) == "Add detour" and dm.actions[2] and dm.actions[2].label == "Quests",
    "dungeon rows: Add detour first, Quests after")
  local itemDm = ns.Items.Results("item:9001")[1]
  check(detourLabel(itemDm) == "Add detour" and (not itemDm.actions[2] or itemDm.actions[2].label:find("^%+")),
    "an item's dungeon row keeps its +N quests action after")
  ns.Find.Open("people", "armorer")
  local armorer = ns.Panel.VisibleResults()[1]
  check(armorer and armorer.title == "Stormwind Armorer" and armorer.goal.npc == "Stormwind Armorer"
    and detourLabel(armorer) == "Add detour" and armorer.subtitle:find("^Armorer  ·  Stormwind City"),
    "an NPC row: directions to them, Add detour: " .. tostring(armorer and armorer.subtitle))
  ns.Find.Open("places", "wetlands")
  check(detourLabel(ns.Panel.VisibleResults()[1]) == "Add detour", "zone rows: Add detour")
  local before = #ns.Journey.OpenStops(ns.Nav.active.journey)
  armorer.actions[1].run(armorer)
  local talk
  for _, s in ipairs(ns.Journey.OpenStops(ns.Nav.active.journey)) do
    if s.npc == "Stormwind Armorer" then talk = s end
  end
  check(talk and talk.action.kind == "talk" and #ns.Journey.OpenStops(ns.Nav.active.journey) == before + 1,
    "Add detour on a person adds a talk stop to the journey")
  ns.Nav.Stop()
  for _, d in ipairs(ns.Dungeons.Results()) do
    if d.title:find("^The Deadmines") then dm = d end
  end
  check(detourLabel(ns.Vendors.Results()[1]) == nil and detourLabel(ns.QuestHubs.Results()[1]) == nil
    and detourLabel(dm) == "Quests", "with no journey: no Add detour on directions rows")
  check(detourLabel(byID(ns.QuestsPage.Results("lakeshire logs"), "quest7")) == "Start journey",
    "quest rows say Start journey instead, which starts one")

  -- The Items page's quest rules now live in Quests.lua.
  local codes = {}
  for _, id in ipairs({ 1, 10, 2, 3, 9, 4, 13, 12, 5 }) do codes[#codes + 1] = tostring(ns.Quests.RewardStatus(id)) end
  check(table.concat(codes, ",") == "available,inLog,done,nil,level,chain,chain,hard,low",
    "Quests.RewardStatus (the Items page's words for QuestStatus): " .. table.concat(codes, ","))
  local rewards = ns.Items.Results("item:9004")
  check(rewards[1] and rewards[1].title == "Reward from Redridge Goulash" and rewards[#rewards].title:find("done", 1, true),
    "the Items page's quest rows come out the same from the shared rules")

  -- Tooltips and help.
  check(ns.Items.TooltipLine(9002) == "Wayward: /ww find for directions"
    and ns.QuestsPage.TooltipLine(1) == "Wayward: /ww find for directions" and ns.QuestsPage.TooltipLine(424242) == nil,
    "item and quest tooltip lines point at /ww find")
  InCombatLockdown = function() return true end
  check(ns.QuestsPage.TooltipLine(1) == nil, "no quest tooltip line in combat")
  InCombatLockdown = nil
  local chatBefore = #chat
  SlashCmdList.WAYWARD("help")
  check(table.concat(chat, "\n", chatBefore + 1):find("/ww find <text>", 1, true), "/ww help lists /ww find")

  ns.Panel.Search("foryou", "")
  C_Map.GetMapChildrenInfo = savedChildren
  ns.db.npcs[990003] = nil
  ns.charDB.classSpells = savedClassSpells
  ITEMS[9010], ITEMS[9011], ITEMS[9012] = nil, nil, nil
  LibQuestieDB.Enum.npcFlags.INNKEEPER = nil
  refreshData()
end
---------------------------------------------------------------- screenshot review (begin)
-- ===== screenshot review: fixes from the first in-game pass =====
do
  io.write("screenshot review\n")
  ns.Nav.Stop()
  runTimers()
  local here = ns.Geo.PlayerNode()

  -- Journey names: an older save called "Your journey" is named after what it holds.
  local plain = ns.Journey.Plan(here, { title = "Your journey", stops = { { node = ns.Geo.Node(1433, 0.55, 0.5, "Camp"),
    text = "Grab the thing" } } })
  local saved = ns.Journey.Save(plain)
  saved.title = "Your journey"
  check(ns.Journey.Load(saved).title == "Grab the thing", "an old generic save is named after its first stop")
  local q6 = ns.Quests.Quest(6)
  if q6 and q6.name then
    check(ns.Journey.NameFor({ stops = { { action = { kind = "pickup", questID = 6 } }, { action = { kind = "turnin", questID = 6 } } } })
      == q6.name, "one quest: its name")
    check(ns.Journey.NameFor({ stops = { { action = { kind = "pickup", questID = 6 } }, { action = { kind = "pickup", questID = 999901 } },
      { action = { kind = "pickup", questID = 999902 } } } }) == q6.name, "quests without a name don't count")
  end
  check(ns.Journey.NameFor({ stops = { { text = "Done already", done = true }, { text = "Repair at Thrawn Boltar" } } })
    == "Repair at Thrawn Boltar", "no quests: the first stop still to do")

  -- Side-panel rows: one line each, the travel time in its own place.
  local function split(text) local a, b = ns.Panel.SplitTime(text) return a .. "|" .. tostring(b) end
  check(split("[9] Frostmane Hold  ·  Dun Morogh  ·  ~2 min") == "[9] Frostmane Hold  ·  Dun Morogh|~2 min"
    and split("Grif Wildheart  ·  Dun Morogh  ·  <1 min") == "Grif Wildheart  ·  Dun Morogh|<1 min"
    and split("Far  ·  ~1 h 5 min") == "Far|~1 h 5 min",
    "a subtitle's travel time is lifted out of it")
  check(split("Zone  ·  Dun Morogh  ·  no route found from here") == "Zone  ·  Dun Morogh  ·  no route found from here|nil"
    and split("Levels 17-19  ·  start at Lakeshire") == "Levels 17-19  ·  start at Lakeshire|nil",
    "anything else stays as it is")

  -- Places: where no flight path names a town, the subzone of an NPC you met there does.
  ns.db.npcs[990777] = { name = "Thrawn Boltar", kinds = { vendor = true }, faction = "Alliance", mapID = 1426,
    x = 0.32, y = 0.59, subZone = "Kharanos" }
  ns.Fire("DATA_CHANGED")
  check(ns.Places.NameFor(ns.Geo.Node(1426, 0.321, 0.59)) == "Kharanos", "a spot by an NPC you met takes their subzone's name")
  check(ns.Places.NameFor(ns.Geo.Node(1426, 0.9, 0.9)) ~= "Kharanos", "but not one across the zone")
  ns.db.npcs[990777] = nil
  ns.Fire("DATA_CHANGED")
  check(ns.Places.NameFor(ns.Geo.Node(1426, 0.321, 0.59)) ~= "Kharanos", "forgotten with the NPC")

  -- Good to know: fewer tiles share the row, so none stands empty beside a cut-off one.
  if ns.Observations.TileWidth then
    local savedObs = ns.ForYou.Observations
    local function tiles(n)
      local out = {}
      for i = 1, n do out[i] = { id = "t" .. i, kind = "x", text = "Tile " .. i, highlights = {}, urgency = 0.5 } end
      return out
    end
    ns.ForYou.Observations = function() return tiles(2) end
    ns.Observations.Update()
    local two = ns.Observations.TileWidth()
    ns.ForYou.Observations = function() return tiles(4) end
    ns.Observations.Update()
    local four = ns.Observations.TileWidth()
    check(two and four and two > four * 1.8, "two tiles are each about twice as wide as four: " .. tostring(two) .. " / " .. tostring(four))
    ns.ForYou.Observations = savedObs
    ns.Observations.Update()
  end

  -- Find's questions read as questions: no "slain", mobs in the plural.
  local Q = ns.Find.ObjectiveQuestion
  check(Q("3/8 Frostmane Headhunter slain") == "Where do I find Frostmane Headhunters?"
    and Q("Frostmane Headhunter slain: 3/8") == "Where do I find Frostmane Headhunters?",
    "a kill objective asks for the mobs: " .. Q("3/8 Frostmane Headhunter slain"))
  check(Q("Shimmerweed: 0/6") == "Where do I find Shimmerweed?" and Q("Kobold Vermin slain: 0/10") == "Where do I find Kobold Vermin?"
    and Q("Young Wolf slain") == "Where do I find Young Wolves?" and Q("Dark Iron Spy slain") == "Where do I find Dark Iron Spies?",
    "items as they are; a few plurals that aren't just an s")
  check(Q(nil, "The Perfect Stout") == "Where do I go for The Perfect Stout?", "no objective text: where to go for the quest")

  -- The switch question: Cancel last on screen, still the button Escape answers.
  local function fakeButton()
    local b = {}
    function b.ClearAllPoints(self) self.after = nil end
    function b.SetPoint(self, _, rel) self.after = rel end
    function b.IsShown() return true end
    return b
  end
  local dialog = { button1 = fakeButton(), button2 = fakeButton(), button3 = fakeButton() }
  ns.Nav.CancelLast(dialog)
  check(dialog.button3.after == dialog.button1 and dialog.button2.after == dialog.button3,
    "Add as detour, Switch journey, then Cancel")
  ns.Nav.CancelLast(nil)
  check(true, "no dialog: nothing to move")

  -- Walking to an objective area names the place, not the quest.
  local area = ns.Geo.Node(1426, 0.9, 0.9, "The Perfect Stout")
  local work = { node = area, text = "Do The Perfect Stout", action = { kind = "complete", questID = 777 } }
  local walk = { steps = { { mode = "walk", from = here, to = area, seconds = 30, stop = work } }, seconds = 30 }
  check(ns.Router.Describe(walk, 1, true) == "Walk to the area for The Perfect Stout",
    "no place name known: the area for the quest: " .. ns.Router.Describe(walk, 1, true))
  ns.db.npcs[990778] = { name = "Rejold", kinds = { vendor = true }, faction = "Alliance", mapID = 1426, x = 0.9, y = 0.9,
    subZone = "Shimmer Ridge" }
  ns.Fire("DATA_CHANGED")
  check(ns.Router.Describe(walk, 1, true) == "Walk to Shimmer Ridge", "a known place: its name: " .. ns.Router.Describe(walk, 1, true))
  ns.db.npcs[990778] = nil
  ns.Fire("DATA_CHANGED")

  -- Remaining time counts the quest work left, not only the travel.
  local savedObjectives = C_QuestLog.GetQuestObjectives
  C_QuestLog.GetQuestObjectives = function(id)
    if id == 777 then return { { numRequired = 6, numFulfilled = 3 } } end
    return {}
  end
  local work = ns.Nav.WorkSeconds({ stops = {
    { action = { kind = "complete", questID = 777 } }, { action = { kind = "complete", questID = 777 } },
    { action = { kind = "turnin", questID = 777 } }, { action = { kind = "complete", questID = 778 }, done = true } } })
  local perQuest = ns.QuestTimes.Seconds() or ns.ForYou.SECONDS_PER_QUEST
  check(math.abs(work - perQuest / 2) < 1, "half the objectives left: half your time per quest, once per quest: " .. work)
  C_QuestLog.GetQuestObjectives = function() return { { numRequired = 8, numFulfilled = 8, finished = true } } end
  check(math.abs(ns.Nav.WorkSeconds({ stops = { { action = { kind = "complete", questID = 779 } } } }) - perQuest / 4) < 1,
    "a quest all but done still counts a quarter")
  C_QuestLog.GetQuestObjectives = savedObjectives
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Walk", stops = { { node = ns.Geo.Node(1433, 0.56, 0.5, "Far"), text = "Far" } } }), true)
  local p = ns.Nav.Progress()
  check(p and p.seconds == p.travel, "with nothing to do but get there, remaining is the travel")
  ns.Nav.Stop()
  runTimers()
end
---------------------------------------------------------------- screenshot review (end)
-- ===== proto: shopping list (gathering as you go) =====
do
  io.write("proto: shopping list\n")
  ns.Nav.Stop()
  local saved = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives, time }
  local clock = 5000
  time = function() return clock end
  -- Redridge Stew: vultures and goretusks all over Redridge (five areas, ~800
  -- yards end to end), handed in to Foreman Oslow (36,30).
  NPCS[9601] = { name = "Stringy Vulture", minLevel = 16, maxLevel = 17, spawns = { [44] = { { 15, 15 }, { 15, 85 }, { 85, 15 } } } }
  NPCS[9602] = { name = "Goretusk", minLevel = 16, maxLevel = 17, spawns = { [44] = { { 50, 50 }, { 85, 85 } } } }
  QUESTS[4600] = { name = "Redridge Stew", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9601 }, { 9602 } } } }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  questKeys.finishedBy, questKeys.objectives = 3, 10
  refreshData()
  check(ns.Journey.Spread(4600) and #ns.Quests.ObjectiveAreas(4600) == 5, "objectives in five areas across the zone: spread")
  check(not ns.Journey.Spread(43), "the murlocs' three camps aren't")

  -- Not in the log yet: pick it up, then the hand-in, through an area on the
  -- way once you have it. The objectives aren't a stop to head for.
  local log, complete = {}, false
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return log[i] and { questID = log[i], isHeader = false } or nil end
  C_QuestLog.IsComplete = function() return complete end
  local objectives = { { text = "Stringy Vulture slain: 1/4", finished = false }, { text = "Goretusk slain: 0/3", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or {} end
  local function at(node, x, y) return node and math.abs(node.x - x) < 1e-6 and math.abs(node.y - y) < 1e-6 end
  player.mapID, player.x, player.y = 1433, 0.5, 0.95
  local here = ns.Geo.PlayerNode()
  local planned = ns.Journey.Plan(here, { title = "Redridge Stew", stops = ns.Journey.QuestStops(4600, here) })
  local kinds = {}
  for i, s in ipairs(planned.stops) do kinds[i] = s.action.kind end
  check(table.concat(kinds, ",") == "pickup,turnin", "planned: pickup, then hand-in; the objectives aren't headed for: "
    .. table.concat(kinds, ","))
  check(not planned.stops[1].via and planned.stops[2].via, "no area before you have it; one on the way to the hand-in")

  -- In the log: straight for Oslow, through the goretusks at 50,50 (on the way).
  log = { 4600 }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge Stew", stops = ns.Journey.QuestStops(4600, here) }), true)
  local step = ns.Nav.CurrentStep()
  check(ns.Nav.HeadingFor().action.kind == "turnin", "heading for the hand-in, not the objectives")
  check(step.via and not step.stop and at(step.to, 0.5, 0.5), "through the area on the way (50,50)")
  local text = ns.Router.Describe(ns.Nav.active.route, ns.Nav.active.index)
  check(text:find("^Through"), "the step says so: " .. text)
  check(step.via.needed and ns.Nav.Aim() == step.to,
    "the hand-in needs it: the arrow points at the area, not at a hand-in that can't be done yet")

  -- From far off, with your Hearthstone bound beside Oslow: the hearth
  -- still goes through an area on the way to the hand-in, as the walk did
  -- (leaving out the gathering isn't time saved).
  do
    local savedCount, savedTaxi, savedPos = GetItemCount, ns.charDB.knownTaxi, { player.mapID, player.x, player.y }
    GetItemCount = function(id) return id == 6948 and 1 or 0 end
    GetBindLocation = function() return "Lakeshire" end
    ns.charDB.knownTaxi = {}
    ns.charDB.hearth = { name = "Lakeshire", mapID = 1433, x = 0.36, y = 0.32 }
    player.mapID, player.x, player.y = 1437, 0.5, 0.5
    local far = ns.Geo.PlayerNode()
    local j = ns.Journey.Plan(far, { title = "Redridge Stew", stops = ns.Journey.QuestStops(4600, far) })
    local modes, hearthAt, viaAt = {}, nil, nil
    for i, st in ipairs(j.steps) do
      modes[i] = st.mode .. (st.via and "(via)" or "")
      if st.mode == "hearth" then hearthAt = i end
      if st.via then viaAt = i end
    end
    check(j.hearth and hearthAt and viaAt and viaAt > hearthAt and j.withoutHearth > j.seconds,
      "hearthing to the hand-in still goes through an area on the way: " .. table.concat(modes, ","))
    GetItemCount, GetBindLocation, ns.charDB.knownTaxi, ns.charDB.hearth = savedCount, nil, savedTaxi, nil
    player.mapID, player.x, player.y = savedPos[1], savedPos[2], savedPos[3]
  end

  -- The Journey window lists the objectives as a row gathered as you go.
  ns.JourneyOverview.Show()
  local gatherRow
  for _, r in ipairs(ns.JourneyOverview.Rows()) do if r.state == "gather" then gatherRow = r end end
  check(gatherRow and gatherRow.stop.action.kind == "complete", "the window lists the objectives as gathered as you go")

  -- The directions box: a toggle for the shopping list, hidden to start
  -- with, the toggle saying how many things are on it.
  ns.charDB.shopOpen = nil
  ns.HUD.Update()
  local shop = ns.HUD.Shop()
  check(shop.toggle and shop.count == "2" and not shop.open and shop.height == 0,
    "the box has a shopping list toggle; list hidden, the toggle says 2: " .. shop.count)
  local lines = ns.HUD.ShopLines()
  check(#lines == 2 and lines[1].entry and lines[2].entry and not lines[1].entry.near and not lines[2].entry.near,
    "far from every spawn: both things listed, nearest first, neither around you")
  ns.HUD.ToggleShop()
  shop = ns.HUD.Shop()
  check(shop.open and shop.count == "" and #shop.lines == 2 and shop.height == 2 * 14 + 10 and ns.charDB.shopOpen,
    string.format("opened: the list pops up above the box, a line each (%d high), no count on the toggle", shop.height))
  check(#shop.rows == 2 and shop.rows[1] == shop.lines[1] and shop.rows[2] == shop.lines[2],
    "every line shows, each on a row of its own (not one text that shows its first line only): " .. #shop.rows)

  -- Passing through the area: not waited in, on to Oslow.
  player.x, player.y = 0.5, 0.52
  ns.HUD.Update()
  step = ns.Nav.CurrentStep()
  check(not ns.Nav.Waiting() and not step.via and ns.Nav.HeadingFor().action.kind == "turnin",
    "in the area: passed through, not waited in; still heading for the hand-in")
  check(gatherRow.stop.worked and next(gatherRow.stop.worked) ~= nil, "the area counts as visited")
  lines = ns.HUD.ShopLines()
  check(lines[1].entry and lines[1].entry.name == "Goretusk" and lines[1].text:find("0/3", 1, true)
    and lines[2].entry and lines[2].entry.name == "Stringy Vulture" and not lines[2].entry.near,
    "around you: the goretusks first, with the count; then the vultures, farther off")
  check(ns.HUD.Shop().lines[1]:find("Goretusk", 1, true), "and the list above the box says so")

  -- Planned again while in the goretusks' area: you're gathering already,
  -- so the way isn't turned aside to another area: straight for Oslow.
  ns.Nav.Recalculate()
  step = ns.Nav.CurrentStep()
  check(ns.Nav.HeadingFor().action.kind == "turnin" and not step.via,
    "re-planned inside one of its areas: no redirect, straight for the hand-in")
  -- Out of it: through another area (the objectives aren't done), not back
  -- through the one just visited.
  player.x, player.y = 0.5, 0.4
  ns.Nav.Recalculate()
  step = ns.Nav.CurrentStep()
  check(ns.Nav.HeadingFor().action.kind == "turnin" and step.via and not at(step.to, 0.5, 0.5),
    string.format("re-planned: through another area (%.2f, %.2f), not the one just visited", step.to.x, step.to.y))

  -- Walking on: the list follows what's around you.
  player.x, player.y = 0.15, 0.17
  ns.HUD.Update()
  check(ns.HUD.Shop().lines[1]:find("Stringy Vulture", 1, true), "among the vultures: the list says so")
  local height = ns.HUD.Shop().height
  -- A third thing to gather, right here too: one line more, and the list
  -- grows (upward: its bottom is on the box's top edge; the box keeps its size).
  NPCS[9603] = { name = "Murloc Raider", minLevel = 16, maxLevel = 17, spawns = { [44] = { { 16, 20 } } } }
  QUESTS[4600].objectives[1][3] = { 9603 }
  objectives[3] = { text = "Murloc Raider slain: 0/2", finished = false }
  refreshData()
  fire("QUEST_LOG_UPDATE")
  ns.HUD.Update()
  shop = ns.HUD.Shop()
  check(#shop.lines == 3 and shop.height == height + 14,
    string.format("a longer list, a taller popup: %d lines, %d high", #shop.lines, shop.height))
  check(#shop.rows == 3 and shop.rows[3] == shop.lines[3], "all three lines show: " .. #shop.rows)
  ns.HUD.ToggleShop()
  shop = ns.HUD.Shop()
  check(not shop.open and shop.count == "3" and shop.height == 0 and not ns.charDB.shopOpen,
    "hidden again: the toggle shows the count, 3")
  QUESTS[4600].objectives[1][3], objectives[3], NPCS[9603] = nil, nil, nil
  refreshData()
  player.x, player.y = 0.5, 0.52
  -- Up to four things listed; the rest on one line.
  local many = {}
  for i = 1, 6 do many[i] = { name = "Thing " .. i, quest = "Redridge Stew", near = i <= 2, distance = i * 10 } end
  lines = ns.HUD.ShopLines(many)
  check(#lines == 5 and lines[4].entry and lines[4].entry.name == "Thing 4" and lines[5].entries
    and #lines[5].entries == 2 and lines[5].text:find("+2 more", 1, true),
    "six things: four listed, then \"+2 more\"")

  -- At the hand-in before it's all gathered (a plan with no area on the way:
  -- made while the quest wasn't in the log): sent on, not kept waiting.
  ns.Nav.Stop()
  here = ns.Geo.PlayerNode()
  local stewStops = ns.Journey.QuestStops(4600, here)
  log = {}
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge Stew", stops = stewStops }), true)
  log = { 4600 }
  check(not ns.Nav.CurrentStep().via, "a plan with no area on the way to the hand-in")
  player.x, player.y = 0.36, 0.3
  local before = #chat
  ns.HUD.Update()
  step = ns.Nav.CurrentStep()
  check(not ns.Nav.Waiting() and step.via and ns.Nav.HeadingFor().action.kind == "turnin",
    "at the hand-in, still gathering: not waiting, on through an area and back")
  check(table.concat(chat, "\n", before + 1):find("not everything for Redridge Stew yet", 1, true), "and says so")
  ns.HUD.Update()
  check(not ns.Nav.Waiting() and ns.Nav.CurrentStep().via, "standing there: the hand-in doesn't count as reached")

  -- Every area visited lately: the one visited longest ago, never the hand-in alone.
  local stew
  for _, s in ipairs(stewStops) do if s.action.kind == "complete" then stew = s end end
  stew.worked = { [1] = clock - 50, [2] = clock - 10, [3] = clock - 200, [4] = clock - 30, [5] = clock - 40 }
  planned = ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Redridge Stew", stops = stewStops })
  local turnin = planned.stops[#planned.stops]
  check(turnin.action.kind == "turnin" and turnin.via and turnin.via.index == 3,
    "all visited lately: through the one visited longest ago: " .. tostring(turnin.via and turnin.via.index))
  stew.worked = nil
  player.x, player.y = 0.5, 0.52

  -- Everything gathered: no more areas, straight to the hand-in, empty list.
  objectives[1] = { text = "Stringy Vulture slain: 4/4", finished = true }
  objectives[2] = { text = "Goretusk slain: 3/3", finished = true }
  complete = true
  fire("QUEST_LOG_UPDATE")
  step = ns.Nav.CurrentStep()
  local anyVia = false
  for k = ns.Nav.active.index, #ns.Nav.active.route.steps do
    if ns.Nav.active.route.steps[k].via then anyVia = true end
  end
  check(stew.done and not anyVia and ns.Nav.HeadingFor().action.kind == "turnin",
    "all gathered: straight to the hand-in")
  check(#ns.HUD.ShopLines() == 0, "and nothing on the list")
  ns.charDB.shopOpen = true
  ns.HUD.Update()
  shop = ns.HUD.Shop()
  check(not shop.toggle and not shop.open and shop.height == 0, "no toggle on the box, no list above it, even set open")
  ns.charDB.shopOpen = nil

  -- A stop elsewhere, nothing it needs: an area far off the way isn't a detour.
  objectives[1] = { text = "Stringy Vulture slain: 1/4", finished = false }
  objectives[2] = { text = "Goretusk slain: 0/3", finished = false }
  complete = false
  ns.Nav.Stop()
  player.x, player.y = 0.9, 0.5
  here = ns.Geo.PlayerNode()
  local docks = { node = ns.Geo.Node(1433, 0.9, 0.3, "Lakeshire docks"), text = "Go to Lakeshire docks" }
  local stops = ns.Journey.QuestStops(4600, here)
  stops[#stops + 1] = docks
  planned = ns.Journey.Plan(here, { title = "Redridge", stops = stops })
  check(planned.stops[1] == docks and not docks.via,
    "a stop that doesn't need it, no area close to the way: no detour through one")

  -- A stop that doesn't need it, an area right on the way: the step goes
  -- through it, but the arrow, the compass and the step point on to the
  -- stop (the area is passed, not headed for).
  player.x, player.y = 0.5, 0.95
  here = ns.Geo.PlayerNode()
  local onWay = {}
  for _, s in ipairs(ns.Journey.QuestStops(4600, here)) do
    if s.action.kind == "complete" then onWay[#onWay + 1] = s end
  end
  local north = { node = ns.Geo.Node(1433, 0.5, 0.2, "Redridge north"), text = "Go to Redridge north" }
  onWay[#onWay + 1] = north
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge", stops = onWay }), true)
  step = ns.Nav.CurrentStep()
  check(step.via and not step.via.needed and at(step.to, 0.5, 0.5),
    "a stop that doesn't need it, an area on the way: through the goretusks at 50,50")
  check(at(ns.Nav.Aim(), 0.5, 0.2), "the arrow points on to the stop, not at the area")
  text = ns.Router.Describe(ns.Nav.active.route, ns.Nav.active.index)
  check(text:find("^Go to Redridge north, through"), "the step says where it points, and what it's through: " .. text)
  check(ns.PlanReport.Build():find("the arrow points past it, on to", 1, true),
    "the plan report says where the arrow points")

  -- The goretusks finished on the way, then a re-plan that isn't taken up
  -- (a what-if, the plan report's fresh plan) runs first: it sets the stop's
  -- area on the way, the route still goes through the goretusks. Re-planning
  -- as you go goes by the route you're on, so it doesn't call that the same
  -- order and keep you headed for an area you've finished. (An Enticing
  -- Offer: through a bear area with the vials of blood in your bags.)
  local savedLiveTime, liveClock = GetTime, 9000
  GetTime = function() return liveClock end
  -- Still spread with the goretusks done (the vultures alone aren't, here):
  -- this is about the area on the way, not the quest becoming a stop.
  local realSpread = ns.Journey.Spread
  ns.Journey.Spread = function() return true end
  objectives[2] = { text = "Goretusk slain: 3/3", finished = true }
  local function throughGoretusks()
    for k = ns.Nav.active.index, #ns.Nav.active.route.steps do
      local s = ns.Nav.active.route.steps[k]
      if s.via and s.via.stop.action.questID == 4600 and at(s.to, 0.5, 0.5) then return true end
    end
    return false
  end
  check(throughGoretusks(), "setup: the route goes through the goretusks")
  ns.Journey.Replan(ns.Nav.active.journey, ns.Geo.PlayerNode())
  ns.PlanReport.Build()
  liveClock = liveClock + 10
  player.y = 0.9
  ns.HUD.Update()
  check(not throughGoretusks(), "goretusks done: re-planned off their area, though a re-plan not taken up came first")
  GetTime, ns.Journey.Spread = savedLiveTime, realSpread
  objectives[2] = { text = "Goretusk slain: 0/3", finished = false }
  ns.Nav.Stop()

  -- A stop a few dozen yards off, an area well behind you: under VIA_YARDS
  -- added, but it would make a short walk several times as long. Straight
  -- there; the next leg can go through it. (Seen on the way to Sara
  -- Timberlain, 32 yards away, routed out through a patch 127 yards back.)
  player.x, player.y = 0.85, 0.74
  here = ns.Geo.PlayerNode()
  local short = {}
  for _, s in ipairs(ns.Journey.QuestStops(4600, here)) do
    if s.action.kind == "complete" then short[#short + 1] = s end
  end
  local near = { node = ns.Geo.Node(1433, 0.85, 0.715, "Close by"), text = "Go to Close by" }
  short[#short + 1] = near
  local behind = ns.Geo.Node(1433, 0.85, 0.85)
  local direct = ns.Geo.Distance(here, near.node)
  local extra = ns.Geo.Distance(here, behind) + ns.Geo.Distance(behind, near.node) - direct
  check(direct < 60 and extra <= ns.Journey.VIA_YARDS and ns.Geo.Distance(here, behind) > ns.Journey.VIA_RADIUS,
    string.format("setup: %.0f yd to the stop, the area adds %.0f yd", direct, extra))
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge", stops = short }), true)
  check(not ns.Nav.CurrentStep().via and at(ns.Nav.Aim(), 0.85, 0.715),
    "a stop close by, an area behind you: straight there, not out through the area")
  ns.Nav.Stop()

  -- Heading for one area, you walk into another of theirs: you're
  -- gathering already, so the arrow goes on to the hand-in.
  player.x, player.y = 0.5, 0.95
  here = ns.Geo.PlayerNode()
  local fresh = ns.Journey.QuestStops(4600, here)
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge Stew", stops = fresh }), true)
  check(ns.Nav.CurrentStep().via and at(ns.Nav.CurrentStep().to, 0.5, 0.5), "heading through the goretusks at 50,50")
  player.x, player.y = 0.84, 0.85
  ns.HUD.Update()
  local freshGather
  for _, s in ipairs(fresh) do if s.action.kind == "complete" then freshGather = s end end
  local visited = 0
  for _ in pairs(freshGather.worked or {}) do visited = visited + 1 end
  check(not ns.Nav.CurrentStep().via and ns.Nav.HeadingFor().action.kind == "turnin" and visited == 1,
    "in another of their areas (85,85): passed, that area visited, on to the hand-in")

  -- In one of its areas, objectives open, nothing else to head for, and the
  -- hand-in nearer than the gathering left (your time per quest times the
  -- share left, with no pace seen yet): gather where you are. No arrow, no
  -- wait. A goretusk spawn beside Oslow puts the hand-in inside an area too
  -- (more far off keep it spread: no spot holds 40% of its spawns).
  for k, spot in ipairs({ { 37, 31 }, { 5, 65 }, { 5, 75 }, { 45, 95 }, { 85, 5 }, { 85, 55 } }) do
    NPCS[9602].spawns[44][k + 2] = spot
  end
  refreshData()
  check(ns.Journey.Spread(4600), "still spread with a spawn by Oslow: " .. ns.Journey.SpreadInfo(4600).share)
  ns.Journey.ResetPace()
  ns.Nav.Stop()
  player.x, player.y = 0.5, 0.52
  here = ns.Geo.PlayerNode()
  fresh = ns.Journey.QuestStops(4600, here)
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge Stew", stops = fresh }), true)
  ns.HUD.Update()
  local hudLines = ns.HUD.Lines()
  local gathering = ns.Nav.GatheringHere()
  check(gathering and not ns.Nav.CurrentStep().via and not ns.Nav.Waiting() and not ns.HUD.ArrowShown(),
    "in one of its areas, short of what the hand-in needs: gathering where you are, no arrow, no wait")
  check(hudLines[2] == "Gather here for Redridge Stew" and hudLines[3] == "Then: Hand in Redridge Stew to Foreman Oslow"
    and hudLines[4]:find("Gathering here", 1, true),
    "the box says so, and what's next: " .. tostring(hudLines[2]) .. " | " .. tostring(hudLines[3]) .. " | " .. hudLines[4])
  check(hudLines[5]:find("Goretusk slain: 0/3", 1, true), "with what's still needed: " .. hudLines[5])
  check(ns.Nav.Progress().stopText:find("^Gather for"), "the stop isn't called a hand-in elsewhere either (home screen)")
  check(ns.Nav.LiveBlocker() == "gathering where you are", "no re-plans while you gather: " .. tostring(ns.Nav.LiveBlocker()))
  local report = ns.PlanReport.Build()
  check(report:find("(quest 4600: in log", 1, true) and report:find("waits on gathering", 1, true)
    and report:find("gathering where you are", 1, true)
    and report:find("Gathered as you go (not headed for): Do Redridge Stew", 1, true)
    and report:find("Do Redridge Stew: 11 areas over", 1, true) and report:find("spread: gathered as you go", 1, true),
    "the plan report says which quest (its ID and state), that it's gathered, and where you are:\n" .. report)

  -- A stop with someone to see goes ahead of a hand-in that isn't ready.
  local docks2 = { node = ns.Geo.Node(1433, 0.9, 0.3, "Lakeshire docks"), text = "Go to Lakeshire docks" }
  local withDocks = ns.Journey.QuestStops(4600, here)
  withDocks[#withDocks + 1] = docks2
  planned = ns.Journey.Plan(here, { title = "Redridge", stops = withDocks })
  check(planned.stops[1] == docks2, "the docks first: the hand-in won't be ready for a while, though it's nearer")

  -- Your pace shows: 4 of 6 in half a minute, the last two ~15 s away, sooner
  -- than the walk to Oslow. You'll likely have them on the way: heading for
  -- the hand-in (still called gather until it's done), no redirect. (One of
  -- each left: with either finished, the other alone isn't spread here.)
  clock = clock + 30
  objectives[1] = { text = "Stringy Vulture slain: 3/4", finished = false }
  objectives[2] = { text = "Goretusk slain: 2/3", finished = false }
  fire("QUEST_LOG_UPDATE")
  ns.HUD.Update()
  hudLines = ns.HUD.Lines()
  check(math.abs(ns.Journey.GatherSeconds(4600) - 15) < 0.01, "your pace: ~15 s to go: " .. ns.Journey.GatherSeconds(4600))
  check(not ns.Nav.GatheringHere() and ns.Nav.HeadingFor().action.kind == "turnin" and not ns.Nav.CurrentStep().via
    and hudLines[2] == "Gather for Redridge Stew, then hand in to Foreman Oslow",
    "likely done on the way: heading for the hand-in: " .. tostring(hudLines[2]))

  -- At Oslow (in an area there) with the last two still to get: gathering
  -- there, not waiting on a hand-in that can't be done.
  player.x, player.y = 0.36, 0.3
  ns.HUD.Update()
  ns.HUD.Update()
  check(not ns.Nav.Waiting() and ns.Nav.GatheringHere() and ns.HUD.Lines()[2]:find("^Gather here"),
    "at the hand-in, in an area, two still to get: gathering there, not waiting")
  -- All gathered: now it's a hand-in, and you're there.
  objectives[1] = { text = "Stringy Vulture slain: 4/4", finished = true }
  objectives[2] = { text = "Goretusk slain: 3/3", finished = true }
  complete = true
  fire("QUEST_LOG_UPDATE")
  ns.HUD.Update()
  ns.HUD.Update()
  check(ns.Nav.Waiting() and ns.HUD.Lines()[2] == "Hand in Redridge Stew to Foreman Oslow",
    "all gathered: hand it in, here: " .. tostring(ns.HUD.Lines()[2]))
  objectives[1] = { text = "Stringy Vulture slain: 1/4", finished = false }
  objectives[2] = { text = "Goretusk slain: 0/3", finished = false }
  complete = false
  ns.Journey.ResetPace()
  for k = 8, 3, -1 do NPCS[9602].spawns[44][k] = nil end
  refreshData()

  -- Mobs crowded round one spot (five of eight within 350 yd of it), a few
  -- strays across the zone: as many areas and as wide as Redridge Stew, but
  -- not spread. That spot is a stop to go and do it, as ever.
  NPCS[9604] = { name = "Defias Smuggler", minLevel = 16, maxLevel = 17, spawns = { [44] = {
    { 60, 60 }, { 61, 62 }, { 63, 61 }, { 62, 64 }, { 64, 63 }, { 15, 15 }, { 85, 15 }, { 15, 85 } } } }
  QUESTS[4601] = { name = "Smuggler Sweep", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9604 } } } }
  refreshData()
  local info = ns.Journey.SpreadInfo(4601)
  check(info.areas >= 4 and info.span >= 400 and info.busiest == 5 and not info.spread,
    string.format("crowded round one spot: a stop, not gathered (%d areas, %.0f yd, %d of %d round the busiest)",
      info.areas, info.span, info.busiest, info.total))
  log = { 4600, 4601 }
  local smugglers = { { text = "Defias Smuggler slain: 0/6", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or id == 4601 and smugglers or {} end
  local both = ns.Journey.QuestStops(4600, here)
  for _, s in ipairs(ns.Journey.QuestStops(4601, here)) do both[#both + 1] = s end
  planned = ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Redridge", stops = both })
  local smuggleDo, stewDo
  for _, s in ipairs(both) do
    if s.action.kind == "complete" then
      if s.action.questID == 4601 then smuggleDo = s else stewDo = s end
    end
  end
  local smugglersPlanned = false
  for _, s in ipairs(planned.stops) do if s == smuggleDo then smugglersPlanned = true end end
  check(smugglersPlanned and not smuggleDo.gather and stewDo.gather,
    "with both: the smugglers' spot is a stop on the plan; the stew is still gathered as you go")
  log = { 4600 }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or {} end
  QUESTS[4601], NPCS[9604] = nil, nil
  refreshData()

  -- One objective all over the zone, another crowded in one patch (An
  -- Enticing Offer: animal blood from every boar in Elwynn, duskweed from one
  -- corner). Pooled, the patch is over 40% of the spawns round one spot;
  -- judged on their own, the boars are spread and hold most of the spawns:
  -- spread.
  NPCS[9605] = { name = "Field Boar", minLevel = 16, maxLevel = 17, spawns = { [44] = {
    { 2, 2 }, { 98, 2 }, { 2, 98 }, { 98, 98 } } } }
  NPCS[9606] = { name = "Bog Lurker", minLevel = 16, maxLevel = 17, spawns = { [44] = {
    { 50, 50 }, { 51, 52 }, { 52, 51 } } } }
  QUESTS[4604] = { name = "Blood and Bog", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9605 }, { 9606 } } } }
  refreshData()
  info = ns.Journey.SpreadInfo(4604)
  local boars, lurkers = info.objectives[1] or { share = -1 }, info.objectives[2] or { share = -1 }
  check(info.share >= 0.4 and #info.objectives == 2 and boars.share < 0.4 and lurkers.share == 1 and info.spread,
    string.format("a crowded patch doesn't make the rest a stop (%.0f%% pooled; %.0f%% and %.0f%% each)",
      info.share * 100, boars.share * 100, lurkers.share * 100))

  -- The boars done (the vials of blood in your bags): what's left is the
  -- patch, so the quest is a stop now. Judged on its open objectives, it
  -- says so once, and the next re-plan as you go puts it on the journey.
  do
  ns.Nav.Stop()
  local bog ={ { text = "Field Boar slain: 1/4", finished = false }, { text = "Bog Lurker slain: 0/3", finished = false } }
  local savedObjectives, savedLog, savedBogTime, bogClock = C_QuestLog.GetQuestObjectives, log, GetTime, 9500
  log = { 4604 }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4604 and bog or {} end
  GetTime = function() return bogClock end
  player.x, player.y = 0.9, 0.5
  here = ns.Geo.PlayerNode()
  local bogStops = ns.Journey.QuestStops(4604, here)
  local bogDocks = { node = ns.Geo.Node(1433, 0.9, 0.3, "Lakeshire docks"), text = "Go to Lakeshire docks" }
  bogStops[#bogStops + 1] = bogDocks
  local bogDo
  for _, s in ipairs(bogStops) do if s.action and s.action.kind == "complete" then bogDo = s end end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Bog", stops = bogStops }), true)
  check(bogDo and bogDo.gather, "boars and the patch both open: gathered as you go")
  bog[1] = { text = "Field Boar slain: 4/4", finished = true }
  info = ns.Journey.SpreadInfo(4604)
  check(not info.spread and info.areas == 1 and #info.objectives == 1 and info.finished[1] == "Field Boar",
    string.format("the boars done: only the patch left, one area, a stop (%d areas, finished: %s)",
      info.areas, table.concat(info.finished, ", ")))
  -- A plan not taken up (the report's fresh plan) comes first; the re-plan
  -- as you go still brings the stop in.
  check(ns.PlanReport.Build():find("finished, left out: Field Boar", 1, true),
    "the plan report says the finished objective is left out")
  before = #chat
  bogClock = bogClock + 10
  player.y = 0.47
  ns.HUD.Update()
  local bogPlanned = false
  for _, s in ipairs(ns.Nav.active.journey.stops) do if s == bogDo then bogPlanned = true end end
  check(bogPlanned and not bogDo.gather, "re-planned as you go: the quest is a stop on the journey")
  local said = table.concat(chat, "\n", before + 1)
  check(said:find("Blood and Bog: only Bog Lurker left, all in one place. It's a stop on your journey now.", 1, true)
    and not said:find("fits better", 1, true), "and it says why, once:\n" .. said)
  ns.Nav.Stop()
  C_QuestLog.GetQuestObjectives, log, GetTime = savedObjectives, savedLog, savedBogTime
  end
  -- A bigger patch: most of the spawns. A stop.
  NPCS[9606].spawns[44] = { { 50, 50 }, { 51, 52 }, { 52, 51 }, { 50, 53 }, { 53, 50 } }
  refreshData()
  check(not ns.Journey.Spread(4604), "most of the spawns in the patch: a stop")
  QUESTS[4604], NPCS[9605], NPCS[9606] = nil, nil, nil
  refreshData()

  -- A place to explore, one of four across the zone (How Big a Threat?:
  -- find a furbolg camp): as many areas and as wide as Redridge Stew, one
  -- spawn in each, but you don't pick it up in passing. It's a stop.
  QUESTS[4602] = { name = "Camp Count", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, triggerEnd = { "Locate a camp", { [44] = { { 15, 15 }, { 85, 15 }, { 15, 85 }, { 85, 85 } } } } }
  refreshData()
  info = ns.Journey.SpreadInfo(4602)
  check(info.areas == 4 and info.span >= 400 and info.share < 0.4 and info.explore and not info.spread,
    string.format("a place to explore over the zone: a stop, not gathered (%d areas, %.0f yd, %.0f%% round the busiest)",
      info.areas, info.span, info.share * 100))
  log = { 4600, 4602 }
  local camp = { { text = "Locate a camp", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or id == 4602 and camp or {} end
  local withCamp = ns.Journey.QuestStops(4600, here)
  for _, s in ipairs(ns.Journey.QuestStops(4602, here)) do withCamp[#withCamp + 1] = s end
  planned = ns.Journey.Plan(ns.Geo.PlayerNode(), { title = "Redridge", stops = withCamp })
  local campDo
  for _, s in ipairs(withCamp) do
    if s.action.kind == "complete" and s.action.questID == 4602 then campDo = s end
  end
  local campPlanned = false
  for _, s in ipairs(planned.stops) do if s == campDo then campPlanned = true end end
  check(campDo and campPlanned and not campDo.gather, "the camp is a stop on the plan, not gathered as you go")
  ns.Nav.StartJourney(planned, true)
  check(ns.PlanReport.Build():find("Do Camp Count: 4 areas over %d+ yd.-a place to explore: a stop"),
    "the plan report says why it's a stop")
  ns.Nav.Stop()
  log = { 4600 }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or {} end
  QUESTS[4602] = nil
  refreshData()

  -- Two quests on the same spots (the Militia's Defias drop the Bandanas
  -- too): one stop, "Do X and Y", both quests' objectives on the box.
  NPCS[9604] = { name = "Defias Smuggler", minLevel = 16, maxLevel = 17, spawns = { [44] = {
    { 60, 60 }, { 61, 62 }, { 63, 61 }, { 62, 64 }, { 64, 63 }, { 15, 15 }, { 85, 15 }, { 15, 85 } } } }
  QUESTS[4601] = { name = "Smuggler Sweep", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9604 } } } }
  QUESTS[4603] = { name = "Bandana Hunt", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9604 } } } }
  refreshData()
  log = { 4601, 4603 }
  local sweep = { { text = "Defias Smuggler slain: 0/6", finished = false } }
  local bandanas = { { text = "Defias Smuggler slain: 0/4", finished = false } }
  local doneIds = {}
  C_QuestLog.GetQuestObjectives = function(id) return id == 4601 and sweep or id == 4603 and bandanas or {} end
  C_QuestLog.IsComplete = function(id) return doneIds[id] == true end
  ns.Nav.Stop()
  player.x, player.y = 0.62, 0.62
  here = ns.Geo.PlayerNode()
  local pair = ns.Journey.QuestStops(4601, here)
  for _, s in ipairs(ns.Journey.QuestStops(4603, here)) do pair[#pair + 1] = s end
  local sweepDo, bandanaDo = pair[1], pair[3]
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Smugglers", stops = pair }), true)
  local js = ns.Nav.active.journey.stops
  check(js[1] == sweepDo and js[2] == bandanaDo and bandanaDo.joined == sweepDo,
    "the bandanas are done with the sweep: straight after it, joined to it")
  ns.HUD.Update()
  local boxLines = ns.HUD.Lines()
  check(ns.Nav.InArea() and boxLines[2] == "Do Smuggler Sweep and Bandana Hunt",
    "one stop on the box, both quests: " .. tostring(boxLines[2]))
  check(boxLines[5]:find("0/6", 1, true) and boxLines[5]:find("0/4", 1, true),
    "both quests' objectives under it: " .. boxLines[5]:gsub("%c", " | "))
  ns.JourneyOverview.Show()
  local nowRows = 0
  for _, r in ipairs(ns.JourneyOverview.Rows()) do if r.state == "now" then nowRows = nowRows + 1 end end
  check(nowRows == 2, "the Journey window shows both as now: " .. nowRows)
  check(ns.PlanReport.Build():find("done together with Do Smuggler Sweep", 1, true), "the plan report says so")
  -- Bandanas first: no reshuffle, it's the same stop.
  local before = #chat
  bandanas[1] = { text = "Defias Smuggler slain: 2/4", finished = false }
  fire("QUEST_LOG_UPDATE")
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop == sweepDo and not table.concat(chat, " ", before + 1):find("you're doing", 1, true),
    "progress on the bandanas: still the one stop, no reshuffle")
  -- The sweep done: the bandanas carry on, right here.
  sweep[1] = { text = "Defias Smuggler slain: 6/6", finished = true }
  doneIds[4601] = true
  fire("QUEST_LOG_UPDATE")
  ns.HUD.Update()
  check(ns.Nav.CurrentStep().stop == bandanaDo and ns.Nav.InArea() and ns.HUD.Lines()[2] == "Do Bandana Hunt",
    "the sweep done: the bandanas on their own, still in the area: " .. tostring(ns.HUD.Lines()[2]))
  -- The other way round: the bandanas finished on a loot (the bags change
  -- before the log is looked at), then the sweep. The way goes on to a
  -- hand-in, not to the bandanas' spot with nothing left to do there.
  ns.Nav.Stop()
  sweep[1] = { text = "Defias Smuggler slain: 0/6", finished = false }
  bandanas[1] = { text = "Defias Smuggler slain: 0/4", finished = false }
  doneIds = {}
  pair = ns.Journey.QuestStops(4601, here)
  for _, s in ipairs(ns.Journey.QuestStops(4603, here)) do pair[#pair + 1] = s end
  sweepDo, bandanaDo = pair[1], pair[3]
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Smugglers", stops = pair }), true)
  check(ns.Nav.active.journey.stops[2] == bandanaDo and bandanaDo.joined == sweepDo,
    "planned again with the bandanas joined to the sweep")
  -- In the camp, but not on the spot it's aimed at.
  player.x, player.y = bandanaDo.node.x + 0.04, bandanaDo.node.y
  local offSpot = ns.Geo.Distance(ns.Geo.PlayerNode(), bandanaDo.node)
  check(offSpot > 15 and offSpot < 60, string.format("in the camp, %.0f yd off the spot", offSpot))
  bandanas[1] = { text = "Defias Smuggler slain: 4/4", finished = true }
  doneIds[4603] = true
  fire("BAG_UPDATE_DELAYED")
  sweep[1] = { text = "Defias Smuggler slain: 6/6", finished = true }
  doneIds[4601] = true
  fire("QUEST_LOG_UPDATE")
  ns.HUD.Update()
  local onTo = ns.Nav.CurrentStep() and ns.Nav.CurrentStep().stop
  check(bandanaDo.done and onTo and not onTo.done and onTo.action.kind == "turnin",
    "both done, the bandanas first: on to a hand-in, not the bandanas' spot: " .. tostring(onTo and onTo.text))
  ns.Nav.Stop()
  ns.JourneyOverview.EnsureFrame():Hide()
  log = { 4600 }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or {} end
  C_QuestLog.IsComplete = function() return complete end
  QUESTS[4601], QUESTS[4603], NPCS[9604] = nil, nil, nil
  refreshData()

  -- In areas of two quests gathered as you go: "Gather here" names the one
  -- with the most of its spawns around you, not the first on the list. A
  -- vulture at 15,85; three murlocs right beside it (the rest spread out).
  NPCS[9606] = { name = "Murloc Raider", minLevel = 16, maxLevel = 17, spawns = { [44] = {
    { 18, 80 }, { 21, 83 }, { 18, 88 }, { 5, 5 }, { 5, 15 }, { 5, 25 }, { 55, 45 }, { 65, 5 } } } }
  QUESTS[4602] = { name = "Murloc Fins", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9606 } } } }
  refreshData()
  check(ns.Journey.Spread(4602), "the murlocs are spread too: " .. ns.Journey.SpreadInfo(4602).share)
  log = { 4600, 4602 }
  local fins = { { text = "Murloc Raider slain: 0/5", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or id == 4602 and fins or {} end
  ns.Nav.Stop()
  player.x, player.y = 0.15, 0.85
  here = ns.Geo.PlayerNode()
  local two = ns.Journey.QuestStops(4600, here)
  for _, s in ipairs(ns.Journey.QuestStops(4602, here)) do two[#two + 1] = s end
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Redridge", stops = two }), true)
  ns.HUD.Update()
  local g2 = ns.Nav.GatheringHere()
  check(g2 and g2.area.stop.action.questID == 4602 and ns.HUD.Lines()[2] == "Gather here for Murloc Fins",
    "in areas of both: gather here for the one with the most around you: " .. tostring(ns.HUD.Lines()[2]))
  ns.Nav.Stop()
  log = { 4600 }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or {} end
  QUESTS[4602], NPCS[9606] = nil, nil
  refreshData()
  ns.JourneyOverview.EnsureFrame():Hide()

  -- Quests in your log that aren't on the journey: what they still want is
  -- listed when it's on the way, spread or not, and the journey isn't
  -- changed for it. The smugglers crowd one spot (not spread) right on the
  -- walk to the docks; the dust devils are off in a corner, not on the way.
  NPCS[9604] = { name = "Defias Smuggler", minLevel = 16, maxLevel = 17, spawns = { [44] = {
    { 60, 60 }, { 61, 62 }, { 63, 61 }, { 62, 64 }, { 64, 63 }, { 15, 15 }, { 85, 15 }, { 15, 85 } } } }
  NPCS[9607] = { name = "Dust Devil", minLevel = 16, maxLevel = 17, spawns = { [44] = { { 95, 95 } } } }
  QUESTS[4601] = { name = "Smuggler Sweep", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9604 } } } }
  QUESTS[4605] = { name = "Dust Devils", questLevel = 17, requiredLevel = 12, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9607 } } } }
  refreshData()
  check(not ns.Journey.Spread(4601), "the smugglers aren't spread")
  log = { 4601, 4605 }
  local sweepLog = { { text = "Defias Smuggler slain: 0/6", finished = false } }
  local devils = { { text = "Dust Devil slain: 0/2", finished = false } }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4601 and sweepLog or id == 4605 and devils or {} end
  ns.Nav.Stop()
  player.x, player.y = 0.62, 0.9
  here = ns.Geo.PlayerNode()
  local docks3 = { node = ns.Geo.Node(1433, 0.62, 0.3, "Lakeshire docks"), text = "Go to Lakeshire docks" }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Docks", stops = { docks3 } }), true)
  ns.charDB.shopOpen = nil
  ns.HUD.Update()
  lines = ns.HUD.ShopLines()
  check(#lines == 1 and lines[1].entry.name == "Defias Smuggler" and lines[1].entry.fromLog
    and lines[1].entry.quest == "Smuggler Sweep" and lines[1].text:find("0/6", 1, true),
    "a log quest off the journey, its smugglers on the way: listed, though not spread; the dust devils aren't: "
    .. #lines)
  check(ns.HUD.Shop().toggle and ns.HUD.Shop().count == "1", "the box shows the toggle for it: " .. ns.HUD.Shop().count)
  check(ns.Nav.HeadingFor() == docks3 and not ns.Nav.CurrentStep().via, "the journey isn't changed for it")
  -- Walked on past the docks' way to the dust devils: around you, so listed.
  player.x, player.y = 0.94, 0.94
  lines = ns.HUD.ShopLines()
  local names = {}
  for i, l in ipairs(lines) do names[i] = l.entry and l.entry.name or "?" end
  check(#lines == 2 and lines[1].entry.name == "Dust Devil" and lines[1].entry.near,
    "among the dust devils: listed first, around you: " .. table.concat(names, ", "))
  -- Done with the dust devils: off the list.
  devils[1] = { text = "Dust Devil slain: 2/2", finished = true }
  lines = ns.HUD.ShopLines()
  check(#lines == 1 and lines[1].entry.name == "Defias Smuggler", "the dust devils done: off the list: " .. #lines)
  devils[1] = { text = "Dust Devil slain: 0/2", finished = false }

  -- On the journey, the sweep is a stop you head for: not on the list. Set
  -- aside, it stays off it.
  ns.Nav.Stop()
  player.x, player.y = 0.62, 0.9
  here = ns.Geo.PlayerNode()
  local withSweep = ns.Journey.QuestStops(4601, here)
  withSweep[#withSweep + 1] = { node = ns.Geo.Node(1433, 0.62, 0.3, "Lakeshire docks"), text = "Go to Lakeshire docks" }
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Sweep", stops = withSweep }), true)
  check(#ns.HUD.ShopLines() == 0, "the sweep on the journey (headed for): not listed; the dust devils still not on the way")
  local sweepStop
  for _, s in ipairs(withSweep) do if s.action and s.action.kind == "complete" then sweepStop = s end end
  sweepStop.skipped = true
  check(#ns.HUD.ShopLines() == 0, "set aside on the journey: still not listed")
  ns.Nav.Stop()
  log = { 4600 }
  C_QuestLog.GetQuestObjectives = function(id) return id == 4600 and objectives or {} end
  QUESTS[4601], QUESTS[4605], NPCS[9604], NPCS[9607] = nil, nil, nil, nil
  refreshData()

  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives, time =
    saved[1], saved[2], saved[3], saved[4], saved[5]
  QUESTS[4600], NPCS[9601], NPCS[9602] = nil, nil, nil
  refreshData()
  ns.Nav.Stop()
  runTimers()
end
-- ===== proto: shopping list (end) =====
-- ===== home screen feedback: activity tags, why lines, fewer tiles =====
do
  io.write("home screen feedback\n")
  ns.Nav.Stop()
  runTimers()
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local F = ns.ForYou
  local function obsFind(list, kind)
    for i, o in ipairs(list) do if o.kind == kind then return o, i end end
  end

  -- A card's tag is the activity, whichever role slot it filled.
  check(ns.Cards.TagFor({ kind = "dungeon", raid = true, role = "explore" }) == "RAID"
    and ns.Cards.TagFor({ kind = "profession", role = "continue", category = "Profession" }) == "PROFESSION"
    and ns.Cards.TagFor({ kind = "zone", lead = "novelty", role = "alternative" }) == "EXPLORE"
    and ns.Cards.TagFor({ kind = "zone", role = "alternative" }) == "QUESTING"
    and ns.Cards.TagFor({ kind = "handin", role = "explore" }) == "QUESTING",
    "tags: RAID, PROFESSION, EXPLORE for a zone that's new, QUESTING for quest things")

  -- Why lines read as reasons: no minutes (the facts row has those), no XP,
  -- no ranking, and the second reason joins the first without a second "with".
  F.Invalidate()
  local list = F.Results()
  local plainWhys, fits, seen = #list > 0, #list > 0, {}
  for _, r in ipairs(list) do
    local why = r.why or ""
    seen[#seen + 1] = why
    if why == "" or why:find("%d+ min") or why:find("XP") or why:find("#%d") or why:find("best")
      or select(2, why:gsub(" with ", "")) > 1 then
      plainWhys = false
    end
    local card = r.whyCard or ""
    if card == "" or (card ~= why and card ~= r.whyShort) or (card ~= r.whyShort and #card > 54) then fits = false end
  end
  check(plainWhys, "every why is a plain reason: " .. table.concat(seen, " | "))
  check(fits, "on the card, the whole why when it fits two lines, else its first reason alone")
  local long = { title = "Long", why = "A quest line that stands out a lot, with a reward you'd use",
    whyCard = "A quest line that stands out a lot", whyShort = "A quest line that stands out a lot" }
  check(ns.Cards.WhyFor(long) == "A quest line that stands out a lot", "the card draws the short form")

  -- A weapon master is never your class trainer: Woo Ping (11867) is in the
  -- bundled weapon master list.
  check(ns.Harvest.IsWeaponMaster(11867)
    and ns.Harvest.IsWeaponList({ { name = "One-Handed Swords" }, { name = "Staves" } })
    and not ns.Harvest.IsWeaponList({ { name = "Staves" }, { name = "Life Tap" } }),
    "the bundled list knows Woo Ping; One-Handed Swords is a weapon skill; a class spell isn't")
  local here = ns.Geo.PlayerNode()
  local savedSpells, savedGUID = ns.charDB.classSpells, UnitGUID
  -- What an older Wayward saved: Woo Ping as a warlock trainer, his list as your spells.
  ns.db.npcs[11867] = { name = "Woo Ping", kinds = { classTrainer = true }, class = "WARLOCK",
    mapID = here.mapID, x = here.x + 0.005, y = here.y }
  ns.charDB.classSpells = { updated = 0, level = 20,
    services = { { name = "Staves", type = "available", cost = 1000 }, { name = "Swords", type = "used" } } }
  local trainers = {}
  for _, r in ipairs(ns.Trainers.Results()) do trainers[#trainers + 1] = r.title end
  local woo = ns.db.npcs[11867]
  check(not table.concat(trainers, ","):find("Woo Ping", 1, true) and woo.kinds.weaponMaster and not woo.kinds.classTrainer
    and woo.class == nil and ns.charDB.classSpells == nil,
    "the old record is put right, and his list isn't your class spells: " .. table.concat(trainers, ", "))
  -- Talking to him again, whatever his list looks like: a weapon master.
  UnitGUID = function() return "Creature-0-1-0-2-11867-AB" end
  fire("TRAINER_SHOW")
  runTimers()
  fire("TRAINER_CLOSED")
  check(woo.kinds.weaponMaster and not woo.kinds.classTrainer and ns.charDB.classSpells == nil,
    "a visit records him as a weapon master, not a class trainer")
  UnitGUID, ns.charDB.classSpells, ns.db.npcs[11867] = savedGUID, savedSpells, nil
  ns.charDB.skippedSpells = nil

  -- Spells to train now and more at the next level: one tile for the one trainer.
  local savedSpells = ns.charDB.classSpells
  ns.charDB.classSpells = { updated = 0, level = 20, services = {
    { name = "Fireball", rank = "Rank 4", type = "available", levelReq = 20, cost = 100 },
    { name = "Shadow Bolt", rank = "Rank 5", type = "unavailable", levelReq = 22, cost = 2000 },
    { name = "Curse of Weakness", rank = "Rank 3", type = "unavailable", levelReq = 22, cost = 1500 } } }
  F.Invalidate()
  local obs = F.Observations()
  local train = obsFind(obs, "train")
  check(train and train.text:find("Then 2 new spells at level 22.", 1, true) and not obsFind(obs, "abilities")
    and train.highlights[#train.highlights] == "level 22",
    "training now and new spells at level 22: one tile (" .. tostring(train and train.text) .. ")")
  ns.charDB.classSpells = savedSpells
  F.Invalidate()
end
-- ===== home screen feedback (end) =====
-- ===== journey: buying what a quest wants (begin) =====
do
  io.write("journey: buying what a quest wants\n")
  ns.Nav.Stop()
  local savedLog = { C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete,
    C_QuestLog.GetQuestObjectives }
  local savedCount, savedInfo = GetItemCount, GetItemInfo
  GetItemInfo = nil
  local qs
  -- Rhapsody Malt: nothing drops it; an innkeeper in Redridge sells it, and a
  -- Horde vendor nearer by too.
  NPCS[7010] = { name = "Innkeeper Firebrew", subName = "Innkeeper", npcFlags = 4, friendlyToFaction = "A",
    spawns = { [44] = { { 40.0, 40.0 } } } }
  NPCS[7011] = { name = "Horde Brewer", subName = "Food & Drink", npcFlags = 4, friendlyToFaction = "H",
    spawns = { [44] = { { 50.5, 50.5 } } } }
  ITEMS[520] = { name = "Rhapsody Malt", vendors = { 7010, 7011 } }
  ITEMS[521] = { name = "Flask of Oil", vendors = { 7010 } }
  ITEMS[522] = { name = "Murloc Fin", npcDrops = { 9101 }, vendors = { 7010 } }
  QUESTS[60] = { name = "Thirst for Malt", questLevel = 18, requiredLevel = 14, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { nil, nil, { { 520 } } } }
  QUESTS[61] = { name = "Malt and Murlocs", questLevel = 18, requiredLevel = 14, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } }, nil, { { 520 } } } }
  QUESTS[62] = { name = "Oil the Torches", questLevel = 18, requiredLevel = 14, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { { { 9101 } } }, requiredSourceItems = { 521 } }
  QUESTS[63] = { name = "Fins", questLevel = 18, requiredLevel = 14, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { nil, nil, { { 522 } } } }
  refreshData()
  local bags = {}
  GetItemCount = function(id) return bags[id] or 0 end
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  local here = ns.Geo.PlayerNode()
  local function kindsOf(qs)
    local out = {}
    for _, st in ipairs(qs) do out[#out + 1] = st.action.kind end
    return table.concat(out, ",")
  end
  local function has(list, stop)
    for _, s in ipairs(list or {}) do if s == stop then return true end end
    return false
  end

  qs = ns.Journey.QuestStops(60, here)
  check(kindsOf(qs) == "pickup,item,turnin",
    "a quest that wants something you buy: pick up, buy it, hand in (nothing else to do): " .. kindsOf(qs))
  check(qs[2].text == "Buy Rhapsody Malt from Innkeeper Firebrew for Thirst for Malt" and qs[2].npc == "Innkeeper Firebrew",
    "the vendor of your faction, not the nearer Horde one: " .. tostring(qs[2].text))
  check(qs[2].after[1] == qs[1] and has(qs[3].after, qs[2]), "bought after the pickup, before the hand-in")

  qs = ns.Journey.QuestStops(61, here)
  check(kindsOf(qs) == "pickup,item,complete,turnin", "kill and buy: both stops: " .. kindsOf(qs))
  check(not has(qs[3].after, qs[2]) and has(qs[4].after, qs[2]) and has(qs[4].after, qs[3]),
    "the buying and the killing in either order; both before the hand-in")

  qs = ns.Journey.QuestStops(62, here)
  check(kindsOf(qs) == "pickup,item,complete,turnin" and qs[2].text == "Buy Flask of Oil from Innkeeper Firebrew for Oil the Torches"
    and has(qs[3].after, qs[2]), "an item the quest starts you with that you buy: bought before the objectives")

  qs = ns.Journey.QuestStops(63, here)
  check(kindsOf(qs) == "pickup,complete,turnin", "an item that drops is fought for, not bought: " .. kindsOf(qs))

  -- In the log: the objective says how many. Three aren't enough; five are.
  local log = { 60 }
  C_QuestLog.GetNumQuestLogEntries = function() return #log end
  C_QuestLog.GetInfo = function(i) return { questID = log[i], isHeader = false } end
  C_QuestLog.IsComplete = function() return false end
  C_QuestLog.GetQuestObjectives = function(id)
    return id == 60 and { { text = "Rhapsody Malt: " .. (bags[520] or 0) .. "/5", type = "item",
      numFulfilled = bags[520] or 0, numRequired = 5, finished = (bags[520] or 0) >= 5 } } or {}
  end
  qs = ns.Journey.QuestStops(60, here)
  check(kindsOf(qs) == "item,turnin" and qs[1].text == "Buy 5 Rhapsody Malt from Innkeeper Firebrew for Thirst for Malt",
    "in your log: how many to buy: " .. tostring(qs[1] and qs[1].text))
  ns.Nav.StartJourney(ns.Journey.Plan(here, { title = "Malt", stops = qs }))
  check(ns.Nav.CurrentStep().stop == qs[1], "first: the innkeeper")
  bags[520] = 3
  fire("BAG_UPDATE_DELAYED")
  check(not qs[1].done and ns.Nav.CurrentStep().stop == qs[1], "three of five: still buying")
  bags[520] = 5
  fire("BAG_UPDATE_DELAYED")
  check(qs[1].done and ns.Nav.CurrentStep().stop == qs[2], "five of five: on to the hand-in")
  ns.Nav.Stop()
  check(kindsOf(ns.Journey.QuestStops(60, here)) == "turnin", "already bought: nothing to buy again")
  ns.JourneyOverview.Toggle()
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsComplete, C_QuestLog.GetQuestObjectives =
    savedLog[1], savedLog[2], savedLog[3], savedLog[4]

  -- Like Dry Times: the Keg of Thunderbrew is the reward of a repeatable
  -- quest (5 Hops), from Grimbooze Thunderbrew, whom the data also lists as
  -- selling it. Earned, not bought.
  NPCS[7012] = { name = "Grimbooze Thunderbrew", npcFlags = 4 + 2, friendlyToFaction = "A",
    spawns = { [44] = { { 45.0, 80.0 } } } }
  ITEMS[530] = { name = "Keg of Thunderbrew", vendors = { 7012 }, questRewards = { 65 } }
  ITEMS[531] = { name = "Hops", vendors = { 7012 } }
  QUESTS[64] = { name = "Dry Times", questLevel = 18, requiredLevel = 14, startedBy = { { 344 } },
    finishedBy = { { 345 } }, objectives = { nil, nil, { { 530 } } } }
  QUESTS[65] = { name = "Thunderbrew Lager", questLevel = 14, requiredLevel = 10, startedBy = { { 7012 } },
    finishedBy = { { 7012 } }, objectives = { nil, nil, { { 531 } } }, specialFlags = 1 }
  local questKeys = LibQuestieDB.Meta.QuestMeta.questKeys
  local savedFlagsKey = questKeys.specialFlags
  questKeys.specialFlags = 24
  refreshData()
  qs = ns.Journey.QuestStops(64, here)
  local texts = {}
  for _, st in ipairs(qs) do texts[#texts + 1] = st.text end
  check(kindsOf(qs) == "pickup,pickup,item,turnin,turnin" and not table.concat(texts, "|"):find("Buy Keg", 1, true),
    "an item another quest rewards: that quest's stops, not a vendor: " .. table.concat(texts, " | "))
  check(qs[2].text == "Pick up Thunderbrew Lager from Grimbooze Thunderbrew" and qs[2].after[1] == qs[1]
    and qs[3].text == "Buy Hops from Grimbooze Thunderbrew for Thunderbrew Lager"
    and qs[4].text == "Hand in Thunderbrew Lager to Grimbooze Thunderbrew for Keg of Thunderbrew"
    and has(qs[4].after, qs[3]) and has(qs[5].after, qs[4]) and qs[5].action.questID == 64,
    "pick up the lager quest, buy the hops, hand it in for the keg, then hand in Dry Times")

  -- Done the lager quest before: it's repeatable, so it's planned again.
  local savedCompleted = C_QuestLog.GetAllCompletedQuestIDs
  C_QuestLog.GetAllCompletedQuestIDs = function() return { 2, 65 } end
  check(kindsOf(ns.Journey.QuestStops(64, here)) == "pickup,pickup,item,turnin,turnin",
    "a repeatable done before can be done again")
  C_QuestLog.GetAllCompletedQuestIDs = savedCompleted
  bags[530] = 1
  check(kindsOf(ns.Journey.QuestStops(64, here)) == "pickup,turnin", "keg in your bags: straight to the hand-in")
  bags[530] = nil
  questKeys.specialFlags = savedFlagsKey

  GetItemCount, GetItemInfo = savedCount, savedInfo
  QUESTS[60], QUESTS[61], QUESTS[62], QUESTS[63], QUESTS[64], QUESTS[65] = nil, nil, nil, nil, nil, nil
  ITEMS[520], ITEMS[521], ITEMS[522], NPCS[7010], NPCS[7011] = nil, nil, nil, nil, nil
  ITEMS[530], ITEMS[531], NPCS[7012] = nil, nil, nil
  refreshData()
end
-- ===== journey: buying what a quest wants (end) =====
-- ===== journey: snackbars (begin) =====
do
  io.write("snackbars\n")
  ns.Snackbar.Clear()
  local ran = 0
  ns.Snackbar.Show({ text = "First", actions = { { label = "Do it", run = function() ran = ran + 1 end } } })
  ns.Snackbar.Show({ text = "Second", note = "A note" })
  local f = ns.Snackbar.Frame()
  check(f and f.content and f.text and f.content:GetFrameStrata() == "DIALOG" and f:GetFrameStrata() == "HIGH",
    "the words and buttons sit a strata above the box, where no skin's frames can cover them")
  check(f.buttons[1]:IsShown() and not f.buttons[2]:IsShown() and f.buttons[1].kind == nil,
    "one action, one icon button (the add icon when it names none)")
  check(f.text:GetText() == "First" and ns.Snackbar.Current().text == "First" and #ns.Snackbar.Queued() == 1,
    "one at a time: the second waits")
  ns.Snackbar.Click(1)
  check(ran == 1 and f.text:GetText() == "Second" and f.note:GetText() == "A note",
    "its action runs, and the next one takes its place, note and all")
  ns.Snackbar.Click(1)
  check(ns.Snackbar.Current().text == "Second", "a snackbar without that action ignores the click")
  ns.Snackbar.Dismiss()
  check(ns.Snackbar.Current() == nil and ran == 1, "the x closes it and does nothing")

  -- Laid over the directions box, the bar behind the words draining as its time runs out.
  local anchors = {}
  rawset(f, "SetPoint", function(_, point, rel, relPoint)
    anchors[#anchors + 1] = { point, rel, relPoint }
  end)
  rawset(f, "GetWidth", function() return 300 end)
  ns.Snackbar.Show({ text = "Added X to your journey.", actions = {
    { label = "Undo", icon = "undo", run = function() end },
    { label = "New journey", icon = "journey", run = function() end } } })
  local hud = ns.HUD.Frame()
  check(#anchors == 2 and anchors[1][1] == "TOPLEFT" and anchors[1][2] == hud and anchors[2][1] == "TOPRIGHT"
    and anchors[2][2] == hud, "it sits over the directions box, as wide as it")
  check(f.buttons[1].kind == "undo" and f.buttons[2].kind == "journey" and f.buttons[2]:IsShown(),
    "each action is an icon: undo, new journey")
  check(ns.Snackbar.TimeLeft() == 1 and f.bar:IsShown(), "the bar starts full")
  f.scripts.OnUpdate(f, 4)
  local left = ns.Snackbar.TimeLeft()
  check(left > 0.4 and left < 0.6 and ns.Snackbar.Current(), "halfway through a note's 8 s, half the bar is left: " .. left)
  rawset(f, "IsMouseOver", function() return true end)
  f.scripts.OnUpdate(f, 30)
  check(ns.Snackbar.TimeLeft() == left and ns.Snackbar.Current(), "the mouse over it holds it, and the bar")
  rawset(f, "IsMouseOver", nil)
  f.scripts.OnUpdate(f, 5)
  check(ns.Snackbar.Current() == nil, "then it runs out and goes, having done nothing")
  rawset(f, "SetPoint", nil)
  rawset(f, "GetWidth", nil)
end
-- ===== journey: snackbars (end) =====
-- ===== routing: walking between zones =====
io.write("walking between zones\n")
do
  local W = ns.Walk
  -- The bundled links: well-formed, and the world hangs together as it should.
  local sane, group = #BUNDLED_ZONE_LINKS >= 40, {}
  local function find(z)
    while group[z] and group[z] ~= z do z = group[z] end
    return z
  end
  for _, l in ipairs(BUNDLED_ZONE_LINKS) do
    if not (l.a and l.b and l.a ~= l.b and (l.mapID == l.a or l.mapID == l.b) and l.x >= 0 and l.x <= 1 and l.y >= 0
      and l.y <= 1 and type(l.label) == "string") then sane = false end
    group[l.a], group[l.b] = group[l.a] or l.a, group[l.b] or l.b
    group[find(l.a)] = find(l.b)
  end
  check(sane, "every bundled link names two zones, a point on one of their maps and a label")
  check(find(1429) == find(1423) and find(1426) == find(1434) and find(1411) == find(1451) and find(1439) == find(1446),
    "the bundled links join each continent's zones (Elwynn to the Plaguelands, Durotar to Silithus)")
  check(find(1438) == find(1457) and find(1438) ~= find(1439) and find(1429) ~= find(1439),
    "Teldrassil is joined to Darnassus only: no walking to Darkshore")

  -- On foot: no flight paths, no boats (Stormwind's harbour would get you to Menethil).
  local known, recorded, where = ns.charDB.knownTaxi, ns.db.transports, { player.mapID, player.x, player.y }
  local boats = ns.data.transports
  ns.Nav.Stop()
  ns.charDB.knownTaxi, ns.db.transports, ns.data.transports = {}, {}, {}
  ns.data.zoneLinks = {
    { a = 1433, b = 1453, mapID = 1433, x = 0, y = 0.5, label = "the east gate" },
    { a = 1453, b = 1429, mapID = 1453, x = 0.5, y = 1, label = "the gates of Stormwind" },
    { a = 1437, b = 1426, mapID = 1437, x = 0, y = 1, label = "Dun Algaz" },
  }
  W.Reset()
  local redridge = ns.Geo.Node(1433, 0.5, 0.5, "Lakeshire")
  local elwynn = ns.Geo.Node(1429, 0.9, 0.1, "Eastvale")
  local straight = ns.Geo.Distance(redridge, elwynn)
  local yards, vias = W.Path(redridge, elwynn, true)
  check(yards and yards > straight * 1.2 and vias and #vias == 2 and vias[1].zone == 1453 and vias[2].zone == 1429
    and vias[1].label == "the east gate", "a walk into another zone goes through the links between them, not straight: "
    .. tostring(yards) .. " against " .. straight)
  check(W.Distance(elwynn, redridge) == yards, "and the same way back")
  local near = ns.Geo.Node(1433, 0.6, 0.6, "Close by")
  check(W.Distance(redridge, near) == ns.Geo.Distance(redridge, near) and select(2, W.Path(redridge, near, true)) == nil,
    "inside a zone a walk is a straight line")
  local nowhere = ns.Geo.Node(1415, 0.6, 0.3, "Off the map")
  check(W.Distance(redridge, nowhere) == ns.Geo.Distance(redridge, nowhere), "to a place with no links, a straight line as before")
  local wetlands = ns.Geo.Node(1437, 0.5, 0.5, "Wetlands camp")
  check(W.Distance(redridge, wetlands) == nil, "zones with links but no chain of them between the two: no walking there")
  check(W.Distance(redridge, ns.Geo.Node(1439, 0.5, 0.5, "Darkshore")) == nil, "nor to another continent")

  -- The router: no walk, so no route on foot; with the flight path, a flight.
  check(ns.Router.Plan(redridge, wetlands, ns.Network.Build()) == nil, "the router has no route where you can't walk")
  ns.charDB.knownTaxi = { [5] = true, [7] = true }
  ns.Fire("FLIGHTS_CHANGED")
  local flown = ns.Router.Plan(redridge, wetlands, ns.Network.Build())
  check(flown and ns.Router.Summary(flown):find("fly to Menethil Harbor", 1, true), "and flies instead when it can: "
    .. tostring(flown and ns.Router.Summary(flown)))
  ns.charDB.knownTaxi = {}
  ns.Fire("FLIGHTS_CHANGED")

  -- The steps: one per link, said with the link.
  local plain = ns.Router.Plan(redridge, elwynn, ns.Network.Build())
  local route = ns.Router.WithZoneSteps(plain)
  local total = 0
  for _, st in ipairs(route.steps) do total = total + st.seconds end
  check(#plain.steps == 1 and math.abs(plain.seconds - yards * ns.Router.WALK_FACTOR / ns.Router.RUN_SPEED) < 0.01,
    "the walk costs its way through the links")
  check(#route.steps == 3 and route.steps[1].link and route.steps[1].zoneEntry == 1453 and route.steps[2].zoneEntry == 1429
    and not route.steps[3].link and route.steps[3].to == elwynn and math.abs(total - plain.seconds) < 0.01,
    "each link is a step of the walk, and the time is shared out between them")
  check(ns.Router.Describe(route, 1) == "Walk to Stormwind City through the east gate"
    and ns.Router.Describe(route, 2) == "Walk to Elwynn Forest through the gates of Stormwind"
    and ns.Router.Describe(route, 3) == "Walk to Eastvale", "the steps name the link: " .. ns.Router.Describe(route, 1))
  check(ns.Router.Summary(route) == "on foot", "still on foot")

  -- Following it: in the zone the link leads to, wherever you crossed, the step is done.
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  ns.Nav.Start("Eastvale", elwynn, ns.Router.Plan(ns.Geo.PlayerNode(), elwynn, ns.Network.Build()))
  check(ns.Nav.CurrentStep().zoneEntry == 1453 and ns.Nav.Aim().pass == "the east gate", "the arrow points at the gate first")
  player.mapID, player.x, player.y = 1453, 0.9, 0.2
  ns.HUD.Update()
  check(ns.Nav.active and ns.Nav.CurrentStep().zoneEntry == 1429, "in the city, by whichever way: on to the next gate")
  ns.Nav.Stop()

  -- An area gathered in on the way is aimed past, but never past a link.
  local gate = { label = "Stormwind City", pass = "the east gate" }
  local aimed = { steps = {
    { mode = "walk", to = { label = "boars" }, via = { stop = {} } },
    { mode = "walk", to = gate, link = true, zoneEntry = 1453 },
    { mode = "walk", to = { label = "the hand-in" }, stop = {} } } }
  local aim, at = ns.Router.Aim(aimed, 1)
  check(aim == gate and at == 2, "past an area on the way the arrow points at the gate, not through the wall")

  -- Crossings you walk are recorded. Arathi, drawn north of the Wetlands.
  ZONES[1417] = { cont = 1415, x0 = 0.38, y0 = 0.32, w = 0.10, h = 0.10, name = "Arathi Highlands" }
  ns.Geo.ForgetZones()
  ns.db.zoneLinks = {}
  player.mapID, player.x, player.y = 1437, 0.5, 0.5
  fire("ZONE_CHANGED_NEW_AREA")
  player.mapID, player.x, player.y = 1433, 0.5, 0.5
  fire("ZONE_CHANGED_NEW_AREA")
  check(#ns.db.zoneLinks == 0, "turning up in a zone far from the one you were in (a hearthstone) records nothing")
  player.mapID, player.x, player.y = 1437, 0.5, 0.5
  fire("ZONE_CHANGED_NEW_AREA")
  local arathi = ns.Geo.Node(1417, 0.5, 0.5, "Refuge Pointe")
  check(W.Distance(wetlands, arathi) == ns.Geo.Distance(wetlands, arathi), "before: Arathi has no links, a straight line")
  player.mapID, player.x, player.y = 1417, 0.2, 0.995
  UnitOnTaxi = function() return true end
  fire("ZONE_CHANGED_NEW_AREA")
  UnitOnTaxi = nil
  check(#ns.db.zoneLinks == 0, "flying over a border records nothing")
  player.mapID, player.x, player.y = 1437, 0.5, 0.5
  fire("ZONE_CHANGED_NEW_AREA")
  player.mapID, player.x, player.y = 1417, 0.2, 0.995
  fire("ZONE_CHANGED_NEW_AREA")
  local l = ns.db.zoneLinks[1]
  check(#ns.db.zoneLinks == 1 and l.a == 1437 and l.b == 1417 and l.mapID == 1417 and l.x == 0.2,
    "walking from one zone into the next records where")
  yards, vias = W.Path(wetlands, arathi, true)
  check(yards > ns.Geo.Distance(wetlands, arathi) and vias and #vias == 1 and vias[1].zone == 1417,
    "and walks between the two go that way from then on")
  player.mapID, player.x, player.y = 1437, 0.21, 0.005
  fire("ZONE_CHANGED_NEW_AREA")
  check(#ns.db.zoneLinks == 1, "crossing back at the same place isn't a second crossing")
  -- A bundled point for the same two zones, a little off: what you walked replaces it.
  table.insert(ns.data.zoneLinks, { a = 1437, b = 1417, mapID = 1417, x = 0.4, y = 1, label = "the Thandol Span" })
  W.Reset()
  local _, replaced = W.Path(ns.Geo.Node(1437, 0.4, 0.1, "South of the span"), ns.Geo.Node(1417, 0.4, 0.9, "North of it"), true)
  check(replaced and #replaced == 1 and math.abs(replaced[1].node.x - 0.2) < 0.001,
    "a crossing you walked replaces the bundled point near it")
  check(W.LuaLine(l):find("a = 1437, b = 1417, mapID = 1417, x = 0.200, y = 0.995", 1, true), "/ww crossings: " .. W.LuaLine(l))

  ZONES[1417] = nil
  ns.Geo.ForgetZones()
  ns.data.zoneLinks, ns.db.zoneLinks = {}, {}
  W.Reset()
  ns.charDB.knownTaxi, ns.db.transports, ns.data.transports = known, recorded, boats
  ns.Fire("FLIGHTS_CHANGED")
  player.mapID, player.x, player.y = where[1], where[2], where[3]
  fire("ZONE_CHANGED_NEW_AREA")
end
-- ===== routing: walking between zones (end) =====
for _, line in ipairs(chat) do io.write("[chat] ", line, "\n") end
if failures > 0 then
  io.write(failures, " FAILED\n")
  os.exit(1)
end
io.write("WAYWARD SMOKE OK\n")
