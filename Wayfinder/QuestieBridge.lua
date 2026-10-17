local _, ns = ...

-- Optional bridge to QuestieDB (github.com/Questie/QuestieDB), read at runtime
-- through its public API. Nothing is copied into Wayfinder: QuestieDB has no
-- licence file, so we only read what the player has installed. Without it,
-- Wayfinder falls back to the NPCs it has learned (Harvest.lua).
--
-- API reference: QuestieDB docs/api.md (contract 4 adds Enum.npcFlags/classKeys).

local Bridge = {}
ns.Questie = Bridge

local CONTRACT = 4
local HUB_RADIUS = 120 -- yards between neighbouring quest givers in one hub

-- English trainer subtitles (read with GetRaw, which skips localisation).
local CLASS_BY_TRAINER_TITLE = {
  ["Warrior Trainer"] = "WARRIOR", ["Paladin Trainer"] = "PALADIN", ["Hunter Trainer"] = "HUNTER",
  ["Rogue Trainer"] = "ROGUE", ["Priest Trainer"] = "PRIEST", ["Shaman Trainer"] = "SHAMAN",
  ["Mage Trainer"] = "MAGE", ["Warlock Trainer"] = "WARLOCK", ["Druid Trainer"] = "DRUID",
}

local QUEST_FIELDS = { "name", "questLevel", "requiredLevel", "requiredRaces", "requiredClasses",
  "preQuestSingle", "preQuestGroup", "exclusiveTo", "startedBy", "requiredSkill", "nextQuestInChain",
  "parentQuest", "requiredMaxLevel", "availableUntilCompleted", "availableStartingWith", "disabledByQuest",
  "breadcrumbForQuestId", "zoneOrSort" }

local RED_LEVELS = 5 -- a quest this many levels above you shows red

local lib, failure
local areaToUiMap, trainersByClass, questIndex, dungeonList
local giverNodes = {}

-- Masks can exceed 32 bits (Skyborne), so test bits arithmetically.
local function hasBit(mask, bit)
  return bit ~= nil and bit > 0 and math.floor(mask / bit) % 2 == 1
end

local function now()
  return debugprofilestop and debugprofilestop() or 0
end

-- True when QuestieDB is installed and speaks a contract we understand.
function Bridge.Available()
  if lib then return true end
  if failure then return false, failure end
  local candidate = _G.LibQuestieDB
  if type(candidate) ~= "table" or type(candidate.RequireContract) ~= "function" then
    return false, "QuestieDB is not installed"
  end
  local ok, accepted, message = pcall(candidate.RequireContract, CONTRACT)
  if ok and accepted then
    lib = candidate
    return true
  end
  failure = "QuestieDB is too old or too new for Wayfinder: " .. tostring(message or accepted)
  ns.print(failure)
  return false, failure
end

function Bridge.StatusText()
  if not Bridge.Available() then return nil end
  local mode = lib.readMode == "source" and "SOURCE MODE" or (lib.readMode or "?")
  return "QuestieDB (" .. mode .. ")"
end

---------------------------------------------------------------- locations

local function uiMapForArea(areaID)
  if not areaToUiMap then
    areaToUiMap = {}
    local ok, zoneDB = pcall(lib.Support.Get, "ZoneDB")
    local source = ok and zoneDB and zoneDB.private and zoneDB.private.areaIdToUiMapId
    if type(source) == "string" then
      local chunk = loadstring(source)
      local loaded, value = pcall(chunk or error)
      if loaded and type(value) == "table" then areaToUiMap = value end
    elseif type(source) == "table" then
      areaToUiMap = source
    end
  end
  return areaToUiMap[areaID]
end

-- spawns = { [areaID] = { {x, y[, phase]}, ... } } in 0-100 map percentages.
local function spawnNodes(spawns, label)
  local nodes = {}
  for areaID, points in pairs(spawns or {}) do
    local uiMap = uiMapForArea(areaID)
    if uiMap then
      for _, p in ipairs(points) do
        if type(p[1]) == "number" and p[1] >= 0 then
          local node = ns.Geo.Node(uiMap, p[1] / 100, p[2] / 100, label)
          if node then nodes[#nodes + 1] = node end
        end
      end
    end
  end
  return nodes
end
Bridge.SpawnNodes = spawnNodes
Bridge.UiMapForArea = uiMapForArea

function Bridge.Nearest(nodes, here)
  local best, bestDistance = nodes[1], math.huge
  for _, node in ipairs(nodes) do
    local d = ns.Geo.Distance(here, node)
    if d < bestDistance then best, bestDistance = node, d end
  end
  return best, bestDistance
end

local function friendlyTo(friendly, faction)
  if friendly == nil or friendly == "" then return true end
  return friendly:find(faction == "Alliance" and "A" or "H", 1, true) ~= nil
end

---------------------------------------------------------------- trainers

local function buildTrainers()
  trainersByClass = {}
  local started = now()
  local trainerFlag = lib.Enum.npcFlags and lib.Enum.npcFlags.TRAINER
  if not trainerFlag then return end
  for _, id in ipairs(NpcDB.GetAllIds()) do
    local flags = NpcDB.Get(id, "npcFlags") or 0
    if flags ~= 0 and hasBit(flags, trainerFlag) then
      local class = CLASS_BY_TRAINER_TITLE[NpcDB.GetRaw(id, "subName") or ""]
      if class then
        trainersByClass[class] = trainersByClass[class] or {}
        table.insert(trainersByClass[class], { id = id, name = NpcDB.Get(id, "name"),
          friendly = NpcDB.Get(id, "friendlyToFaction") })
      end
    end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.questieTrainers = now() - started
end

-- { {id, name, node}, ... } for your class and faction, nearest spawn each.
function Bridge.ClassTrainers(class, faction, here)
  if not Bridge.Available() then return {} end
  if not trainersByClass then buildTrainers() end
  local out = {}
  for _, t in ipairs(trainersByClass[class] or {}) do
    if friendlyTo(t.friendly, faction) then
      local node = Bridge.Nearest(spawnNodes(NpcDB.Get(t.id, "spawns"), t.name), here)
      if node then out[#out + 1] = { id = t.id, name = t.name, node = node } end
    end
  end
  return out
end

---------------------------------------------------------------- dungeons

-- Entrances from ZoneDB.private.dungeons, keyed by the dungeon's AreaID:
-- { {areaID, name, alternativeAreaIds, nodes}, ... }. The Forever flavor
-- stores them already converted to Forever maps, so they are not converted
-- again (EraToForever is only for our own Era points, below).
function Bridge.Dungeons()
  if not Bridge.Available() then return {} end
  if dungeonList then return dungeonList end
  dungeonList = {}
  local ok, zoneDB = pcall(lib.Support.Get, "ZoneDB")
  local source = ok and zoneDB and zoneDB.private and zoneDB.private.dungeons
  for areaID, d in pairs(type(source) == "table" and source or {}) do
    if type(d) == "table" and type(d[1]) == "string" then
      local spawns = {}
      for _, loc in ipairs(type(d[4]) == "table" and d[4] or {}) do
        if type(loc) == "table" and loc[1] then
          spawns[loc[1]] = spawns[loc[1]] or {}
          table.insert(spawns[loc[1]], { loc[2], loc[3] })
        end
      end
      dungeonList[#dungeonList + 1] = { areaID = areaID, name = d[1],
        alternativeAreaIds = type(d[2]) == "table" and d[2] or {}, nodes = spawnNodes(spawns, d[1] .. " entrance") }
    end
  end
  return dungeonList
end

-- An Era (vanilla) map point in Forever coordinates (0-1), through QuestieDB's
-- helper when it has one. Only Mulgore, Eastern Plaguelands, Redridge and
-- Stormwind City change. Returns x, y, converted.
function Bridge.EraToForever(uiMapID, x, y)
  local convert = Bridge.Available() and lib.EraToForeverByUiMapId
  if type(convert) ~= "function" then return x, y, false end
  local ok, fx, fy = pcall(convert, uiMapID, x * 100, y * 100)
  if not (ok and type(fx) == "number" and type(fy) == "number") then return x, y, false end
  return fx / 100, fy / 100, true
end

---------------------------------------------------------------- quests

local predecessors -- [questID] = { quests whose nextQuestInChain is questID }

local function buildQuestIndex()
  questIndex, predecessors = {}, {}
  local started = now()
  local keys = {}
  local questKeys = lib.Meta.QuestMeta.questKeys
  for _, field in ipairs(QUEST_FIELDS) do
    if questKeys[field] then keys[#keys + 1] = field end
  end
  for _, id in ipairs(QuestDB.GetAllIds()) do
    local values = QuestDB.GetAll(id, keys)
    if values then
      local q = { id = id }
      for i, field in ipairs(keys) do q[field] = values[i] end
      local nextID = q.nextQuestInChain or 0
      if nextID ~= 0 then
        predecessors[nextID] = predecessors[nextID] or {}
        table.insert(predecessors[nextID], q)
      end
      local starters = q.startedBy or {}
      if (starters[1] and #starters[1] > 0) or (starters[2] and #starters[2] > 0) then
        questIndex[#questIndex + 1] = q
      end
    end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.questieQuests = now() - started
end

local function anyDone(list, done)
  for _, id in ipairs(list or {}) do
    if done[id] then return true end
  end
  return false
end

local function allDone(list, done)
  for _, id in ipairs(list or {}) do
    if not done[id] then return false end
  end
  return true
end

-- Grey ("trivial") quests give little XP; hide them.
local function isTrivial(questLevel, level)
  if UnitQuestTrivialLevelRange then
    local range = UnitQuestTrivialLevelRange("player")
    if type(range) == "number" then return level - questLevel > range end
  end
  local gray
  if level <= 5 then gray = 0
  elseif level <= 39 then gray = level - 5 - math.floor(level / 10)
  elseif level <= 59 then gray = level - 1 - math.floor(level / 5)
  else gray = level - 9 end
  return questLevel <= gray
end

local function playerProfile()
  local _, class = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  return {
    level = UnitLevel("player"),
    raceMask = lib.Enum.raceMaskById and lib.Enum.raceMaskById[raceID],
    classMask = lib.Enum.classKeys and lib.Enum.classKeys[class],
  }
end

-- Level <= 0 means "scales with you" in Questie data; show your level.
local function displayLevel(q, p)
  local level = (q.questLevel or 0) ~= 0 and q.questLevel or q.requiredLevel or 0
  return level > 0 and level or p.level
end

local function playerQuestState()
  local done, inLog = {}, {}
  for _, id in ipairs(C_QuestLog.GetAllCompletedQuestIDs() or {}) do done[id] = true end
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID then inLog[info.questID] = true end
  end
  return done, inLog
end

local function canEverDo(q, p)
  if (q.requiredRaces or 0) ~= 0 and not hasBit(q.requiredRaces, p.raceMask) then return false end
  if (q.requiredClasses or 0) ~= 0 and not hasBit(q.requiredClasses, p.classMask) then return false end
  return true
end

-- A follow-up quest is only recorded on its predecessor (nextQuestInChain), so
-- it stays hidden until one predecessor you could ever do is completed.
local function chainReached(q, p, done)
  local before = predecessors[q.id]
  if not before then return true end
  local possible = false
  for _, prev in ipairs(before) do
    if done[prev.id] then return true end
    if canEverDo(prev, p) then possible = true end
  end
  return not possible
end

local function active(id, done, inLog)
  return id ~= 0 and (done[id] or inLog[id])
end

-- Field meanings: QuestieDB src/meta/questMeta.lua. Questie handles more
-- (holiday/event flags, reputation); quests needing a profession are left out.
local function eligible(q, p, done, inLog)
  if done[q.id] or inLog[q.id] then return false end
  local required = q.requiredLevel or 0
  if required ~= 0 and required > p.level then return false end
  if (q.requiredMaxLevel or 0) ~= 0 and p.level > q.requiredMaxLevel then return false end
  local questLevel = (q.questLevel or 0) ~= 0 and q.questLevel or required
  if questLevel > 0 and (isTrivial(questLevel, p.level) or questLevel - p.level >= RED_LEVELS) then return false end
  if not canEverDo(q, p) then return false end
  if q.preQuestSingle and #q.preQuestSingle > 0 and not anyDone(q.preQuestSingle, done) then return false end
  if q.preQuestGroup and not allDone(q.preQuestGroup, done) then return false end
  if not chainReached(q, p, done) then return false end
  if anyDone(q.exclusiveTo, done) then return false end
  -- You have moved on: the next quest in the chain is active or completed.
  if active(q.nextQuestInChain or 0, done, inLog) then return false end
  if active(q.breadcrumbForQuestId or 0, done, inLog) then return false end
  if (q.parentQuest or 0) ~= 0 and not inLog[q.parentQuest] then return false end
  if (q.availableStartingWith or 0) ~= 0 and not active(q.availableStartingWith, done, inLog) then return false end
  if (q.availableUntilCompleted or 0) ~= 0 and done[q.availableUntilCompleted] then return false end
  if (q.disabledByQuest or 0) ~= 0 and inLog[q.disabledByQuest] then return false end
  if q.requiredSkill then return false end
  return true
end

local function giverNode(kind, id, here, faction)
  local key = kind .. id
  if giverNodes[key] == nil then
    local db = kind == "npc" and NpcDB or ObjectDB
    local name = db.Get(id, "name")
    local ok = kind ~= "npc" or friendlyTo(db.Get(id, "friendlyToFaction"), faction)
    giverNodes[key] = ok and { name = name, nodes = spawnNodes(db.Get(id, "spawns"), name) } or false
  end
  local giver = giverNodes[key]
  if not giver or #giver.nodes == 0 then return nil end
  return giver.name, Bridge.Nearest(giver.nodes, here)
end

-- Hubs of quest givers you can take quests from, nearest first (straight line).
function Bridge.QuestHubs(here, limit)
  if not Bridge.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  local faction = UnitFactionGroup("player")
  local p = playerProfile()
  local done, inLog = playerQuestState()

  local givers, order = {}, {}
  for _, q in ipairs(questIndex) do
    if eligible(q, p, done, inLog) then
      local bestName, bestNode, bestDistance, bestKey
      for kind, group in pairs({ npc = q.startedBy[1], object = q.startedBy[2] }) do
        for _, id in ipairs(group or {}) do
          local name, node, distance = giverNode(kind, id, here, faction)
          if node and (not bestDistance or distance < bestDistance) then
            bestName, bestNode, bestDistance, bestKey = name, node, distance, kind .. id
          end
        end
      end
      if bestNode then
        local g = givers[bestKey]
        if not g then
          g = { name = bestName, node = bestNode, distance = bestDistance, quests = {} }
          givers[bestKey] = g
          order[#order + 1] = g
        end
        g.quests[#g.quests + 1] = { id = q.id, name = q.name, level = displayLevel(q, p) }
      end
    end
  end

  table.sort(order, function(a, b) return a.distance < b.distance end)
  return Bridge.Cluster(order, limit or 12)
end

-- Quests whose zoneOrSort is in `areaIDs` (a set; for a dungeon quest that is
-- the dungeon's AreaID): { [areaID] = { available = {...}, inLog = {...} } }.
function Bridge.QuestsForAreas(areaIDs)
  if not Bridge.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  local p = playerProfile()
  local done, inLog = playerQuestState()
  local out = {}
  for _, q in ipairs(questIndex) do
    local area = q.zoneOrSort
    if area and areaIDs[area] then
      local group = out[area] or { available = {}, inLog = {} }
      out[area] = group
      local quest = { id = q.id, name = q.name, level = displayLevel(q, p) }
      if inLog[q.id] then
        table.insert(group.inLog, quest)
      elseif eligible(q, p, done, inLog) then
        table.insert(group.available, quest)
      end
    end
  end
  return out
end

local function addGiver(hub, g)
  table.insert(hub.givers, g)
  hub.count = hub.count + #g.quests
  if #g.quests > #hub.anchor.quests then hub.anchor = g end
end

-- Single linkage: a giver joins every hub it is near any member of, and the
-- hubs it bridges merge. Past `limit`, givers can still join existing hubs.
function Bridge.Cluster(givers, limit)
  local hubs = {}
  for _, g in ipairs(givers) do
    local near = {}
    for i, h in ipairs(hubs) do
      for _, member in ipairs(h.givers) do
        if ns.Geo.Distance(member.node, g.node) <= HUB_RADIUS then
          near[#near + 1] = i
          break
        end
      end
    end
    if #near == 0 then
      if #hubs < limit then
        local hub = { anchor = g, givers = {}, count = 0 }
        addGiver(hub, g)
        hubs[#hubs + 1] = hub
      end
    else
      local target = hubs[near[1]]
      addGiver(target, g)
      for k = #near, 2, -1 do
        for _, member in ipairs(hubs[near[k]].givers) do addGiver(target, member) end
        table.remove(hubs, near[k])
      end
    end
  end
  return hubs
end
