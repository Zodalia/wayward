local _, ns = ...

-- Learns the world as you play: NPC IDs and positions when you interact with
-- them, your class's trainer spells, and which flight paths you know. The
-- Forever client has no API for "where are the trainers", so this (plus
-- Data/Seed.lua) is the trainer database.

local Harvest = {}
ns.Harvest = Harvest

local KIND_BY_INTERACTION = {
  Merchant = "vendor", TaxiNode = "flightMaster", Binder = "innkeeper",
  Banker = "banker", CharacterBanker = "banker", AccountBanker = "banker",
  Auctioneer = "auctioneer", StableMaster = "stableMaster", Trainer = "trainer",
}

-- English names only; a weapon master on other locales is stored as a class trainer.
local WEAPON_SKILLS = {
  ["Axes"] = true, ["Two-Handed Axes"] = true, ["Swords"] = true, ["Two-Handed Swords"] = true,
  ["Maces"] = true, ["Two-Handed Maces"] = true, ["Polearms"] = true, ["Staves"] = true,
  ["Daggers"] = true, ["Fist Weapons"] = true, ["Bows"] = true, ["Guns"] = true,
  ["Crossbows"] = true, ["Thrown"] = true,
}

local SERVICE_TYPES = { available = true, unavailable = true, used = true, header = true }

local function isSecret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

local function npcID()
  local guid = UnitGUID("npc")
  if not guid or isSecret(guid) then return nil end
  local unitType, _, _, _, _, id = strsplit("-", guid)
  if unitType ~= "Creature" then return nil end
  return tonumber(id)
end

-- Records the NPC you are talking to at your current position.
-- DATA_CHANGED(kind) goes out only when something about them changed (a new
-- NPC, a new role, a new name, a move, extra details): the same vendor
-- window opens many times a session.
local MOVED = 0.002 -- map fraction: a few yards
function Harvest.RecordNPC(kind, extra)
  local id = npcID()
  local here = ns.Geo.PlayerNode()
  if not (id and here) then return nil end
  local npc = ns.db.npcs[id]
  local changed = npc == nil or not npc.kinds[kind] or extra ~= nil
  npc = npc or { kinds = {} }
  local name = UnitName("npc")
  if name and name ~= npc.name then npc.name, changed = name, true end
  npc.faction = UnitFactionGroup("npc")
  if npc.mapID ~= here.mapID or math.abs((npc.x or 0) - here.x) > MOVED or math.abs((npc.y or 0) - here.y) > MOVED then
    npc.mapID, npc.x, npc.y = here.mapID, here.x, here.y
    changed = true
  end
  local subZone = GetSubZoneText and GetSubZoneText()
  npc.subZone = subZone ~= "" and subZone or nil
  npc.kinds[kind] = true
  npc.seen = time()
  for k, v in pairs(extra or {}) do npc[k] = v end
  ns.db.npcs[id] = npc
  if changed then ns.Fire("DATA_CHANGED", kind) end
  return npc
end

-- The recorded NPCs of `kind` with their nodes: { {npc, node}, ... }, built
-- once per kind until an NPC is recorded (Network asks per flight path).
local nodesOf = {}
function Harvest.NodesOf(kind)
  if nodesOf[kind] then return nodesOf[kind] end
  local out = {}
  for _, npc in pairs(Harvest.AllNPCs()) do
    if npc.kinds and npc.kinds[kind] then
      local at = ns.Geo.Node(npc.mapID, npc.x, npc.y)
      if at then out[#out + 1] = { npc = npc, node = at } end
    end
  end
  nodesOf[kind] = out
  return out
end
ns.Listen("DATA_CHANGED", function() nodesOf = {} end)

-- The name of a recorded NPC of `kind` within `radius` yards of a node, or nil.
function Harvest.NPCNear(kind, node, radius)
  local best, bestDistance
  for _, entry in ipairs(Harvest.NodesOf(kind)) do
    local d = ns.Geo.Distance(node, entry.node)
    if d and d <= radius and d < (bestDistance or math.huge) then best, bestDistance = entry.npc.name, d end
  end
  return best
end

function Harvest.AllNPCs()
  local all = {}
  -- Seed positions were measured in Forever (some of its maps moved since vanilla).
  if ns.IsForever() then
    for id, npc in pairs(ns.data.seedNPCs) do all[id] = npc end
  end
  for id, npc in pairs(ns.db.npcs) do all[id] = npc end
  return all
end

---------------------------------------------------------------- trainers

-- GetTrainerServiceInfo's return order differs between clients (WFProbe saw
-- name, type, icon in Forever), so pick values out by shape.
local function readService(index)
  local r = { n = select("#", GetTrainerServiceInfo(index)), GetTrainerServiceInfo(index) }
  local s = {}
  for i = 1, r.n do
    local v = r[i]
    if type(v) == "string" then
      if SERVICE_TYPES[v] then
        s.type = v
      elseif not s.name then
        s.name = v
      elseif not s.rank and v:find("%d") then
        s.rank = v
      end
    elseif type(v) == "number" and not s.icon then
      s.icon = v
    end
  end
  s.levelReq = GetTrainerServiceLevelReq(index)
  s.cost = GetTrainerServiceCost(index)
  if GetTrainerServiceSkillLine then s.skillLine = GetTrainerServiceSkillLine(index) end
  return s
end

local MIN_CLASS_SERVICES = 20

local function classify(services)
  local trainerType = C_Trainer and C_Trainer.GetTrainerType and C_Trainer.GetTrainerType()
  local T = Enum.TrainerType or {}
  if trainerType ~= nil and trainerType == T.Pet then return "petTrainer" end
  if (trainerType ~= nil and trainerType == T.Tradeskills) or (IsTradeskillTrainer and IsTradeskillTrainer()) then
    return "professionTrainer"
  end
  -- Recipes and "Journeyman Tailoring": a profession trainer.
  if ns.Professions and ns.Professions.FromServices(services) then return "professionTrainer" end
  local allWeapons = true
  for _, s in ipairs(services) do
    if not WEAPON_SKILLS[s.name] then allWeapons = false break end
  end
  if allWeapons then return "weaponMaster" end
  -- On other locales the weapon names don't match: a class trainer lists
  -- your whole class (a hundred and more services), a weapon master a dozen.
  local locale = GetLocale and GetLocale()
  if locale and locale ~= "enUS" and locale ~= "enGB" and #services < MIN_CLASS_SERVICES then return "weaponMaster" end
  return "classTrainer"
end

local classTrainerOpen = false
local lastServicesKey

-- The service list is empty at TRAINER_SHOW and fills in shortly after.
local function readTrainer()
  local n = GetNumTrainerServices and GetNumTrainerServices() or 0
  if n == 0 then return end
  local services = {}
  for i = 1, n do
    local s = readService(i)
    if s.name and s.type ~= "header" then services[#services + 1] = s end
  end
  if #services == 0 then return end
  local kind = classify(services)
  local _, class = UnitClass("player")
  local extra
  if kind == "classTrainer" then
    extra = { class = class }
  elseif kind == "professionTrainer" then
    -- Which profession, and the ranks on offer ("Journeyman Tailoring").
    local profession = ns.Professions and ns.Professions.FromServices(services)
    local ranks = {}
    for _, s in ipairs(services) do
      for _, r in ipairs(ns.Professions and ns.Professions.RANKS or {}) do
        if profession and s.name == r.name .. " " .. profession then ranks[#ranks + 1] = r.name end
      end
    end
    extra = { profession = profession, ranks = #ranks > 0 and ranks or nil }
  elseif kind == "weaponMaster" then
    -- What they teach depends on your class (the list only has what you can
    -- learn), so it's kept per class, with the cost and whether you know it.
    local weapons, list = {}, {}
    for _, s in ipairs(services) do
      weapons[#weapons + 1] = s.name
      list[#list + 1] = { name = s.name, cost = s.cost, type = s.type }
    end
    local id = npcID()
    local known = id and ns.db.npcs[id]
    local teaches = known and known.teaches and CopyTable(known.teaches) or {}
    teaches[class] = list
    extra = { weapons = weapons, teaches = teaches }
  end
  -- TRAINER_UPDATE fires on every click in the window: one reading per list.
  local key = #services
  for _, s in ipairs(services) do key = key .. "|" .. tostring(s.type) end
  if kind == "classTrainer" and classTrainerOpen and lastServicesKey == key then return end
  lastServicesKey = key
  Harvest.RecordNPC(kind, extra)
  classTrainerOpen = kind == "classTrainer"
  if kind == "classTrainer" then
    ns.charDB.classSpells = { updated = time(), level = UnitLevel("player"), services = services }
    ns.Fire("DATA_CHANGED")
  end
end

ns.On("TRAINER_SHOW", function() ns.After(0.5, readTrainer) end)
ns.On("TRAINER_UPDATE", readTrainer)
-- What you could have learned and didn't, you left there on purpose.
ns.On("TRAINER_CLOSED", function()
  if not classTrainerOpen then return end
  classTrainerOpen = false
  local cs = ns.charDB.classSpells
  if cs then ns.Trainers.RecordSkipped(cs.services) end
end)

---------------------------------------------------------------- flight paths

-- A flight map only lists the flight paths of the continent you're on, so
-- what you know is tracked per continent (continent uiMapID).
local function playerContinent()
  local here = ns.Geo.PlayerNode()
  return here and ns.Geo.Continents()[here.instance], here
end

-- True once Wayward knows your flight paths on a continent: a flight map was
-- opened there, or (older saved data) a flight path there is already known.
function Harvest.FlightsKnownOn(continent)
  if not continent then return false end
  ns.charDB.taxiSeen = ns.charDB.taxiSeen or {}
  if ns.charDB.taxiSeen[continent] then return true end
  for _, t in ipairs(C_TaxiMap.GetTaxiNodesForMap(continent) or {}) do
    if ns.charDB.knownTaxi[t.nodeID] then
      ns.charDB.taxiSeen[continent] = true
      return true
    end
  end
  return false
end

local function readTaxi()
  local taxiMapID = GetTaxiMapID and GetTaxiMapID()
  local nodes = taxiMapID and C_TaxiMap.GetAllTaxiNodes(taxiMapID)
  if type(nodes) ~= "table" then return end
  local continent = playerContinent()
  local newContinent = false
  if continent then
    ns.charDB.taxiSeen = ns.charDB.taxiSeen or {}
    newContinent = not ns.charDB.taxiSeen[continent]
    ns.charDB.taxiSeen[continent] = true
  end
  local S = Enum.FlightPathState or { Current = 0, Reachable = 1 }
  local learned = 0
  for _, n in ipairs(nodes) do
    if (n.state == S.Current or n.state == S.Reachable) and not ns.charDB.knownTaxi[n.nodeID] then
      ns.charDB.knownTaxi[n.nodeID] = true
      learned = learned + 1
    end
  end
  if learned > 0 then ns.Fire("FLIGHTS_CHANGED", learned) end
  if learned > 0 or newContinent then ns.Fire("DATA_CHANGED") end
end

ns.On("TAXIMAP_OPENED", readTaxi)

-- "New flight path discovered!": the nearest flight path is now known.
local NEW_PATH_RADIUS = 150

ns.On("UI_INFO_MESSAGE", function(_, message)
  if not (ERR_NEWTAXIPATH and message == ERR_NEWTAXIPATH) then return end
  local continent, here = playerContinent()
  if not continent then return end
  local best, bestDistance
  for _, t in ipairs(C_TaxiMap.GetTaxiNodesForMap(continent) or {}) do
    local node = t.position and ns.Geo.Node(continent, t.position.x, t.position.y, t.name)
    local d = node and ns.Geo.Distance(here, node)
    if d and d <= NEW_PATH_RADIUS and d < (bestDistance or math.huge) then best, bestDistance = t, d end
  end
  if best and not ns.charDB.knownTaxi[best.nodeID] then
    ns.charDB.knownTaxi[best.nodeID] = true
    ns.Fire("FLIGHTS_CHANGED", 1)
    ns.Fire("DATA_CHANGED")
  end
end)

---------------------------------------------------------------- quest givers

-- The quests a quest giver offers you right now, from their gossip or
-- greeting window: a set of quest IDs, or nil when this client doesn't say.
local function offeredQuests(event)
  local ids = {}
  if event == "GOSSIP_SHOW" then
    if not (C_GossipInfo and C_GossipInfo.GetAvailableQuests) then return nil end
    for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
      if type(q) == "table" and q.questID then ids[q.questID] = true end
    end
  else
    if not (GetNumAvailableQuests and GetAvailableQuestInfo) then return nil end
    for i = 1, GetNumAvailableQuests() or 0 do
      local id = select(5, GetAvailableQuestInfo(i))
      if type(id) ~= "number" then return nil end
      ids[id] = true
    end
  end
  return ids
end

-- QUESTS_OFFERED(npcName, ids): someone you're talking to lists their quests.
for _, event in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING" }) do
  ns.On(event, function()
    local ids = offeredQuests(event)
    if ids then ns.Fire("QUESTS_OFFERED", UnitName("npc"), ids) end
  end)
end

---------------------------------------------------------------- other NPCs

ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(interactionType)
  local kind = KIND_BY_INTERACTION[ns.EnumName(Enum.PlayerInteractionType, interactionType)]
  if kind then Harvest.RecordNPC(kind) end
end)

ns.On("PLAYER_LEVEL_UP", function() ns.Fire("DATA_CHANGED") end)
