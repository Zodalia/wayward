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
  "breadcrumbForQuestId", "zoneOrSort", "finishedBy", "objectives", "triggerEnd" }

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

-- Weapon masters are kept with the class trainers, under this key.
local WEAPON_MASTER = "WEAPON_MASTER"

local flightMasters -- { {name, nodes}, ... }, built with the trainers

local function buildTrainers()
  trainersByClass, flightMasters = {}, {}
  local started = now()
  local trainerFlag = lib.Enum.npcFlags and lib.Enum.npcFlags.TRAINER
  local flightFlag = lib.Enum.npcFlags and lib.Enum.npcFlags.FLIGHT_MASTER
  if not trainerFlag then return end
  for _, id in ipairs(NpcDB.GetAllIds()) do
    local flags = NpcDB.Get(id, "npcFlags") or 0
    if flightFlag and flags ~= 0 and hasBit(flags, flightFlag) then
      local name = NpcDB.Get(id, "name")
      flightMasters[#flightMasters + 1] = { name = name, nodes = spawnNodes(NpcDB.Get(id, "spawns"), name) }
    end
    if flags ~= 0 and hasBit(flags, trainerFlag) then
      local subName = NpcDB.GetRaw(id, "subName") or ""
      local class = CLASS_BY_TRAINER_TITLE[subName] or (subName == "Weapon Master" and WEAPON_MASTER) or nil
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

-- The name of the flight master within `radius` yards of a node (a flight
-- path), or nil.
function Bridge.FlightMasterNear(node, radius)
  if not Bridge.Available() then return nil end
  if not trainersByClass then buildTrainers() end
  local best, bestDistance
  for _, fm in ipairs(flightMasters or {}) do
    for _, n in ipairs(fm.nodes) do
      local d = ns.Geo.Distance(node, n)
      if d <= radius and d < (bestDistance or math.huge) then best, bestDistance = fm.name, d end
    end
  end
  return best
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

-- Weapon masters for your faction, the same shape.
function Bridge.WeaponMasters(faction, here)
  return Bridge.ClassTrainers(WEAPON_MASTER, faction, here)
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
local questByID -- [questID] = quest row (every quest, with or without a starter)
local nameIndex -- { {lowercase name, quest row}, ... }, built on the first search

-- Forever adds quests QuestieDB knows nothing about the chains of (e.g. a
-- second "Return the Statuette", 98189, after the original 286). For those
-- (IDs from FOREVER_QUEST_IDS; Era's stop well below) with no chain data at
-- all, the earlier quest is inferred (q.inferredAfter):
--   a quest of the same name with a lower ID (the highest such one), else
--   the quest one ID lower, when you hand that one in to whoever starts this.
-- Used only while you could ever do the earlier quest (see blocker).
local FOREVER_QUEST_IDS = 90000

local function noChainData(q)
  return not (q.preQuestSingle and #q.preQuestSingle > 0) and not (q.preQuestGroup and #q.preQuestGroup > 0)
    and not predecessors[q.id] and (q.parentQuest or 0) == 0 and (q.availableStartingWith or 0) == 0
end

local function npcSet(ends)
  local set = {}
  for _, id in ipairs(ends and ends[1] or {}) do set[id] = true end
  return set
end

local function inferChains()
  local byName = {}
  for id, q in pairs(questByID) do
    if type(q.name) == "string" then
      byName[q.name] = byName[q.name] or {}
      table.insert(byName[q.name], id)
    end
  end
  for id, q in pairs(questByID) do
    if id >= FOREVER_QUEST_IDS and noChainData(q) then
      local after
      for _, other in ipairs(byName[q.name] or {}) do
        if other < id and (not after or other > after) then after = other end
      end
      local prev = not after and questByID[id - 1]
      if prev then
        local finishers = npcSet(prev.finishedBy)
        for npc in pairs(npcSet(q.startedBy)) do
          if finishers[npc] then after = prev.id break end
        end
      end
      local exclusive = false
      for _, x in ipairs(q.exclusiveTo or {}) do
        if x == after then exclusive = true end
      end
      if after and not exclusive then q.inferredAfter = after end
    end
  end
end

local function buildQuestIndex()
  questIndex, predecessors, questByID, followers = {}, {}, {}, nil
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
      questByID[id] = q
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
  inferChains()
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

-- One read of your quests per moment: For you, Quest hubs and journeys all ask
-- many times in one refresh. Any quest event starts a fresh read. The sets are
-- shared, so treat them as read-only.
local QUEST_STATE_SECONDS = 1
local questState -- { done, inLog, at }

local function playerQuestState()
  local now = GetTime and GetTime()
  if questState and now and now - questState.at < QUEST_STATE_SECONDS then
    return questState.done, questState.inLog
  end
  local done, inLog = {}, {}
  for _, id in ipairs(C_QuestLog.GetAllCompletedQuestIDs() or {}) do done[id] = true end
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID then inLog[info.questID] = true end
  end
  questState = now and { done = done, inLog = inLog, at = now } or nil
  return done, inLog
end

-- Bumped whenever what you can take may have changed (quest events, levels).
local questVersion = 0

for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE" }) do
  ns.On(event, function()
    questState = nil
    questVersion = questVersion + 1
  end)
end
-- Quests a giver didn't offer you (see Navigator.lua) count as locked until you
-- hand something in or level up, when they may have opened.
function Bridge.MarkNotOffered(questID)
  ns.charDB.notOffered = ns.charDB.notOffered or {}
  ns.charDB.notOffered[questID] = true
  questVersion = questVersion + 1
end

local function forgetNotOffered()
  ns.charDB.notOffered = nil
  questVersion = questVersion + 1
end

ns.On("QUEST_TURNED_IN", forgetNotOffered)
ns.On("PLAYER_LEVEL_UP", forgetNotOffered)

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

-- An inferred earlier quest (see inferChains) you could do but haven't.
local function inferredOpen(q, p, done)
  local before = q.inferredAfter and questByID[q.inferredAfter]
  return before ~= nil and not done[before.id] and canEverDo(before, p)
end

local function active(id, done, inLog)
  return id ~= 0 and (done[id] or inLog[id])
end

local function questName(id)
  local q = questByID[id]
  return q and q.name or ("quest " .. id)
end

-- Why this character can't take the quest now, as a status and a reason, or
-- nil when nothing stops you (level fit aside, see fitsLevel). Statuses: done,
-- inLog, notForYou, tooLow, unavailable (closed to you for good or for now),
-- needsEarlier (an earlier quest first, see chainStart).
-- Field meanings: QuestieDB src/meta/questMeta.lua. Questie handles more
-- (holiday/event flags, reputation); quests needing a profession are left out.
local function blocker(q, p, done, inLog)
  if done[q.id] then return "done", "You have done this quest." end
  if inLog[q.id] then return "inLog", "In your quest log." end
  -- The game knows better than the data: its giver didn't offer it.
  local notOffered = ns.charDB and ns.charDB.notOffered
  if notOffered and notOffered[q.id] then return "needsEarlier", "Not offered yet: needs earlier quests." end
  if (q.requiredRaces or 0) ~= 0 and not hasBit(q.requiredRaces, p.raceMask) then
    return "notForYou", "Not for your race."
  end
  if (q.requiredClasses or 0) ~= 0 and not hasBit(q.requiredClasses, p.classMask) then
    return "notForYou", "Not for your class."
  end
  local required = q.requiredLevel or 0
  if required ~= 0 and required > p.level then return "tooLow", "Requires level " .. required .. "." end
  if (q.requiredMaxLevel or 0) ~= 0 and p.level > q.requiredMaxLevel then
    return "unavailable", "Only up to level " .. q.requiredMaxLevel .. "."
  end
  for _, id in ipairs(q.exclusiveTo or {}) do
    if done[id] then return "unavailable", "Closed by " .. questName(id) .. ", which you did." end
  end
  -- You have moved on: the next quest in the chain is active or completed.
  if active(q.nextQuestInChain or 0, done, inLog) then
    return "unavailable", "You have moved on to " .. questName(q.nextQuestInChain) .. "."
  end
  if active(q.breadcrumbForQuestId or 0, done, inLog) then
    return "unavailable", "Leads to " .. questName(q.breadcrumbForQuestId) .. ", which you already have."
  end
  if (q.availableUntilCompleted or 0) ~= 0 and done[q.availableUntilCompleted] then
    return "unavailable", "Closed by " .. questName(q.availableUntilCompleted) .. ", which you did."
  end
  if (q.disabledByQuest or 0) ~= 0 and inLog[q.disabledByQuest] then
    return "unavailable", "Not while " .. questName(q.disabledByQuest) .. " is in your log."
  end
  if (q.parentQuest or 0) ~= 0 and not inLog[q.parentQuest] and done[q.parentQuest] then
    return "unavailable", "Part of " .. questName(q.parentQuest) .. ", which you did."
  end
  if inferredOpen(q, p, done)
    or (q.preQuestSingle and #q.preQuestSingle > 0 and not anyDone(q.preQuestSingle, done))
    or (q.preQuestGroup and not allDone(q.preQuestGroup, done))
    or not chainReached(q, p, done)
    or ((q.parentQuest or 0) ~= 0 and not inLog[q.parentQuest])
    or ((q.availableStartingWith or 0) ~= 0 and not active(q.availableStartingWith, done, inLog)) then
    return "needsEarlier", "Needs earlier quests."
  end
  if q.requiredSkill then return "unavailable", "Needs a profession." end
  return nil
end

-- Hubs hide grey quests (little XP) and red ones (too hard).
local function fitsLevel(q, p)
  local questLevel = (q.questLevel or 0) ~= 0 and q.questLevel or q.requiredLevel or 0
  if questLevel <= 0 then return true, questLevel end
  if isTrivial(questLevel, p.level) then return false, questLevel, "grey" end
  if questLevel - p.level >= RED_LEVELS then return false, questLevel, "red" end
  return true, questLevel
end

-- The Quest hubs rules: nothing stops you and the level fits.
local function eligible(q, p, done, inLog)
  return blocker(q, p, done, inLog) == nil and (fitsLevel(q, p))
end

-- Earlier quests that `q` still waits for (the unmet requirements).
local function requirements(q, p, done, inLog)
  local out = {}
  for _, id in ipairs(q.preQuestGroup or {}) do
    if not done[id] then out[#out + 1] = id end
  end
  if not anyDone(q.preQuestSingle, done) then
    for _, id in ipairs(q.preQuestSingle or {}) do out[#out + 1] = id end
  end
  if not chainReached(q, p, done) then
    for _, prev in ipairs(predecessors[q.id]) do
      if canEverDo(prev, p) then out[#out + 1] = prev.id end
    end
  end
  if (q.parentQuest or 0) ~= 0 and not inLog[q.parentQuest] then out[#out + 1] = q.parentQuest end
  if inferredOpen(q, p, done) then out[#out + 1] = q.inferredAfter end
  local starting = q.availableStartingWith or 0
  if starting ~= 0 and not active(starting, done, inLog) then out[#out + 1] = starting end
  return out
end

-- The first quest on the way to `q` you can act on now: an earlier quest you
-- can take ("available", grey or red included) or one in your log to finish
-- first ("inLog"). Depth first, so the earliest takeable step of a chain wins.
local function chainStart(q, p, done, inLog, seen)
  seen[q.id] = true
  for _, id in ipairs(requirements(q, p, done, inLog)) do
    local prev = questByID[id]
    if prev and not seen[id] then
      local status = blocker(prev, p, done, inLog)
      if status == nil then return id, "available" end
      if status == "inLog" then return id, "inLog" end
      if status == "needsEarlier" then
        local stepID, state = chainStart(prev, p, done, inLog, seen)
        if stepID then return stepID, state end
      end
    end
  end
  return nil
end

-- status, reason[, stepID, stepState] for a quest row (see Bridge.QuestStatus).
local function questStatus(q, p, done, inLog)
  local status, reason = blocker(q, p, done, inLog)
  local notOffered = ns.charDB and ns.charDB.notOffered
  if status == "needsEarlier" and notOffered and notOffered[q.id] then return status, reason end
  if status == "needsEarlier" then
    local stepID, state = chainStart(q, p, done, inLog, {})
    if state == "available" then
      reason = "Needs earlier quests. Start the chain: " .. questName(stepID) .. "."
    elseif state == "inLog" then
      reason = "Needs earlier quests. Finish " .. questName(stepID) .. " first (in your log)."
    else
      reason = "Needs earlier quests you can't take yet."
    end
    return status, reason, stepID, state
  end
  if status then return status, reason end
  local _, questLevel, why = fitsLevel(q, p)
  if why == "grey" then return "available", "Grey for you: little XP." end
  if why == "red" then return "available", string.format("Level %d: hard for you.", questLevel) end
  return "available", "You can take this quest."
end

local function giverNode(kind, id, here, faction)
  local key = kind .. id
  if giverNodes[key] == nil then
    local db = kind == "npc" and NpcDB or ObjectDB
    local name = db.Get(id, "name")
    local ok = kind ~= "npc" or friendlyTo(db.Get(id, "friendlyToFaction"), faction)
    local nodes = ok and spawnNodes(db.Get(id, "spawns"), name) or {}
    -- Objects (a box, a sign, Buzzbox 323) can't be talked to or targeted.
    if kind == "object" then
      for _, n in ipairs(nodes) do n.object = true end
    end
    giverNodes[key] = ok and { name = name, nodes = nodes } or false
  end
  local giver = giverNodes[key]
  if not giver or #giver.nodes == 0 then return nil end
  return giver.name, Bridge.Nearest(giver.nodes, here)
end

-- Nearest of a quest's starters or finishers ({npcIDs, objectIDs}) you can talk
-- to: name, node, distance, key (or nil).
local function nearestOf(ends, here, faction)
  local bestName, bestNode, bestDistance, bestKey
  for kind, group in pairs({ npc = ends and ends[1], object = ends and ends[2] }) do
    for _, id in ipairs(group or {}) do
      local name, node, distance = giverNode(kind, id, here, faction)
      if node and (not bestDistance or distance < bestDistance) then
        bestName, bestNode, bestDistance, bestKey = name, node, distance, kind .. id
      end
    end
  end
  return bestName, bestNode, bestDistance, bestKey
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
      local bestName, bestNode, bestDistance, bestKey = nearestOf(q.startedBy, here, faction)
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

-- Where this character can quest, zone by zone (the zone of each quest's
-- nearest starter): quests you can take now, and the follow-ups their chains
-- unlock (a quest that needs earlier quests, the first of which you can take
-- or have in your log), all fitting your level. Built fresh each call; For
-- you caches its page.
--   { [zone uiMapID] = { mapID, quests = { {id, name, level, node, giver, chain}, ... } } }
local zoneCache -- { key, zones }: reused until your quests or level change

function Bridge.ZoneQuests(here)
  if not Bridge.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  local key = questVersion .. ":" .. UnitLevel("player") .. ":" .. tostring(questIndex)
  if zoneCache and zoneCache.key == key then return zoneCache.zones end
  local faction = UnitFactionGroup("player")
  local p = playerProfile()
  local done, inLog = playerQuestState()
  local zones = {}
  local function add(q, chain)
    local name, node = nearestOf(q.startedBy, here, faction)
    if not node then return end
    local zone = ns.Geo.ZoneAt(node.instance, node.wx, node.wy) or node.mapID
    local z = zones[zone]
    if not z then
      z = { mapID = zone, quests = {} }
      zones[zone] = z
    end
    z.quests[#z.quests + 1] = { id = q.id, name = q.name, level = displayLevel(q, p), node = node, giver = name,
      chain = chain }
  end
  for _, q in ipairs(questIndex) do
    if (fitsLevel(q, p)) then
      local status = blocker(q, p, done, inLog)
      if status == nil then
        add(q, false)
      elseif status == "needsEarlier" then
        local _, state = chainStart(q, p, done, inLog, {})
        if state then add(q, true) end
      end
    end
  end
  zoneCache = { key = key, zones = zones }
  return zones
end

-- Quests whose zoneOrSort is in `areaIDs` (a set; for a dungeon quest that is
-- the dungeon's AreaID): { [areaID] = { available = {...}, inLog = {...},
-- later = {...} } }. `later` are ones you can't take yet but will: too low a
-- level for them (with requiredLevel), too hard for now, or after earlier
-- quests of their chain.
function Bridge.QuestsForAreas(areaIDs)
  if not Bridge.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  local p = playerProfile()
  local done, inLog = playerQuestState()
  local out = {}
  for _, q in ipairs(questIndex) do
    local area = q.zoneOrSort
    if area and areaIDs[area] then
      local group = out[area] or { available = {}, inLog = {}, later = {} }
      out[area] = group
      local quest = { id = q.id, name = q.name, level = displayLevel(q, p), requiredLevel = q.requiredLevel }
      if inLog[q.id] then
        table.insert(group.inLog, quest)
      else
        local status = blocker(q, p, done, inLog)
        local fits, _, why = fitsLevel(q, p)
        if status == nil and fits then
          table.insert(group.available, quest)
        elseif status == "tooLow" or status == "needsEarlier" or (status == nil and why == "red") then
          table.insert(group.later, quest)
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------- shared quest helpers

-- For pages built on the bridge (Quests, Items, For you). Rows are the
-- QUEST_FIELDS above; treat them as read-only.

function Bridge.Quest(questID)
  if not Bridge.Available() then return nil end
  if not questIndex then buildQuestIndex() end
  return questByID[questID]
end

-- Every quest that has an NPC or object starter.
function Bridge.AllQuests()
  if not Bridge.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  return questIndex
end

-- done, inLog: sets of quest IDs for this character right now.
function Bridge.PlayerQuestState()
  return playerQuestState()
end

-- True when this character can pick the quest up now (same rules as Quest hubs).
function Bridge.IsQuestAvailable(questID, done, inLog)
  local q = Bridge.Quest(questID)
  if not q then return false end
  if not done then done, inLog = playerQuestState() end
  return eligible(q, playerProfile(), done, inLog)
end

-- Nearest starter of a quest you can talk to: name, node, distance (or nil).
function Bridge.QuestGiver(questID, here)
  local q = Bridge.Quest(questID)
  if not (q and q.startedBy) then return nil end
  local name, node, distance = nearestOf(q.startedBy, here, UnitFactionGroup("player"))
  return name, node, distance
end

-- Nearest NPC or object you hand the quest in to: name, node, distance (or nil).
function Bridge.QuestFinisher(questID, here)
  local q = Bridge.Quest(questID)
  if not (q and q.finishedBy) then return nil end
  local name, node, distance = nearestOf(q.finishedBy, here, UnitFactionGroup("player"))
  return name, node, distance
end

-- Where to work on a quest's objectives: the nearest place, as a route node.
-- In your log, the game's own quest-area marker (C_QuestLog.GetQuestsOnMap);
-- otherwise QuestieDB: creatures to kill, objects to use, mobs that drop the
-- items you need, and places to explore. Returns node, source or nil.
local MAX_DROPPERS = 6

local function logArea(questID, label)
  if not (C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)) then return nil end
  for _, continent in pairs(ns.Geo.Continents()) do
    for _, poi in ipairs(C_QuestLog.GetQuestsOnMap(continent) or {}) do
      if poi.questID == questID and poi.x and poi.y then
        local node = ns.Geo.Node(continent, poi.x, poi.y, label)
        if node then return node end
      end
    end
  end
  return nil
end

-- Places an item drops or can be picked up: its droppers' and objects' spawns.
local function itemNodes(itemID, label, nodes)
  nodes = nodes or {}
  if not ItemDB then return nodes end
  local function add(spawns)
    for _, node in ipairs(spawnNodes(spawns, label)) do nodes[#nodes + 1] = node end
  end
  for i, npcID in ipairs(ItemDB.Get(itemID, "npcDrops") or {}) do
    if i > MAX_DROPPERS then break end
    add(NpcDB.Get(npcID, "spawns"))
  end
  for i, objectID in ipairs(ItemDB.Get(itemID, "objectDrops") or {}) do
    if i > MAX_DROPPERS then break end
    add(ObjectDB.Get(objectID, "spawns"))
  end
  return nodes
end

-- A quest's objectives as named groups of places: { {name, nodes}, ... } —
-- creatures to kill (their spawns), objects to use, items (where they drop or
-- lie) and places to explore. `name` is matched against the quest log's
-- objective text to tell which are finished.
local function objectiveGroups(q, label)
  local groups = {}
  local objectives = type(q.objectives) == "table" and q.objectives or {}
  for _, creature in ipairs(objectives[1] or {}) do
    groups[#groups + 1] = { name = NpcDB.Get(creature[1], "name"), nodes = spawnNodes(NpcDB.Get(creature[1], "spawns"), label) }
  end
  for _, object in ipairs(objectives[2] or {}) do
    groups[#groups + 1] = { name = ObjectDB.Get(object[1], "name"), nodes = spawnNodes(ObjectDB.Get(object[1], "spawns"), label) }
  end
  for _, item in ipairs(objectives[3] or {}) do
    groups[#groups + 1] = { name = ItemDB and ItemDB.Get(item[1], "name"), nodes = itemNodes(item[1], label) }
  end
  if type(q.triggerEnd) == "table" then
    groups[#groups + 1] = { name = type(q.triggerEnd[1]) == "string" and q.triggerEnd[1] or nil,
      nodes = spawnNodes(q.triggerEnd[2], label) }
  end
  local out = {}
  for _, g in ipairs(groups) do
    if #g.nodes > 0 then out[#out + 1] = g end
  end
  return out
end

local function objectiveNodes(q, label)
  local nodes = {}
  for _, g in ipairs(objectiveGroups(q, label)) do
    for _, node in ipairs(g.nodes) do nodes[#nodes + 1] = node end
  end
  return nodes
end

-- QuestieDB's objective places don't change, so each quest's list is built
-- once; the game's own marker is read fresh every time.
local objectiveCache = {}

function Bridge.ObjectiveNode(questID, here)
  local q = Bridge.Quest(questID)
  local label = q and q.name or ("Quest " .. questID)
  local area = logArea(questID, label)
  if area then return area, "log" end
  if not q then return nil end
  local nodes = objectiveCache[questID]
  if not nodes then
    local ok, built = pcall(objectiveNodes, q, label)
    nodes = ok and built or {}
    objectiveCache[questID] = nodes
  end
  if #nodes == 0 then return nil end
  return Bridge.Nearest(nodes, here), "QuestieDB"
end

-- A quest field read on demand (not kept in the quest index), or nil.
local function questField(questID, field)
  local keys = lib and lib.Meta and lib.Meta.QuestMeta and lib.Meta.QuestMeta.questKeys
  if not (keys and keys[field]) then return nil end
  local ok, value = pcall(QuestDB.Get, questID, field)
  return ok and type(value) == "table" and value or nil
end

-- What a quest needs before its objectives can be done, from QuestieDB, in
-- order: items to collect first (its source items that drop or lie somewhere,
-- and that you don't have yet), then Questie's extra objectives (e.g. "Fill the
-- bowl at the moonwell"), each with its nearest place:
--   { {kind = "item", itemID, text, node} | {kind = "event", text, node}, ... }
function Bridge.QuestPrep(questID, here)
  if not Bridge.Available() then return {} end
  local q = Bridge.Quest(questID)
  if not q then return {} end
  local out, objectiveItems = {}, {}
  local groups = type(q.objectives) == "table" and q.objectives or {}
  for _, item in ipairs(groups[3] or {}) do objectiveItems[item[1]] = true end
  for _, itemID in ipairs(questField(questID, "requiredSourceItems") or {}) do
    local have = GetItemCount and (GetItemCount(itemID) or 0) > 0
    if type(itemID) == "number" and not objectiveItems[itemID] and not have then
      local name = (ItemDB and ItemDB.Get(itemID, "name")) or ("item " .. itemID)
      local node = Bridge.Nearest(itemNodes(itemID, name), here)
      if node then out[#out + 1] = { kind = "item", itemID = itemID, text = "Collect " .. name, node = node } end
    end
  end
  for _, extra in ipairs(questField(questID, "extraObjectives") or {}) do
    local spawns, text = extra[1], extra[3]
    if type(spawns) == "table" and type(text) == "string" then
      local node = Bridge.Nearest(spawnNodes(spawns, text), here)
      if node then out[#out + 1] = { kind = "event", text = text, node = node } end
    end
  end
  return out
end

-- The quests that follow `questID` in its chain (QuestieDB's links, quests
-- that need it, and inferred Forever links) that you could take once it's
-- done: your race and class, your level, not done yet. Quest rows.
local followers -- [questID] = { quest rows that come after it }

local function buildFollowers()
  followers = {}
  local function add(before, q)
    followers[before] = followers[before] or {}
    table.insert(followers[before], q)
  end
  for _, q in pairs(questByID) do
    if (q.nextQuestInChain or 0) ~= 0 and questByID[q.nextQuestInChain] then add(q.id, questByID[q.nextQuestInChain]) end
    for _, id in ipairs(q.preQuestSingle or {}) do add(id, q) end
    for _, id in ipairs(q.preQuestGroup or {}) do add(id, q) end
    if q.inferredAfter then add(q.inferredAfter, q) end
  end
end

function Bridge.FollowUps(questID)
  if not Bridge.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  if not followers then buildFollowers() end
  local p = playerProfile()
  local done, inLog = playerQuestState()
  local out, seen = {}, {}
  for _, q in ipairs(followers[questID] or {}) do
    if not seen[q.id] and not done[q.id] and not inLog[q.id] and canEverDo(q, p)
      and (q.requiredLevel or 0) <= p.level and q.startedBy then
      seen[q.id] = true
      out[#out + 1] = q
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- What QuestieDB says about a quest's place in its chain, for /wf debug quest.
function Bridge.Describe(questID)
  local q = Bridge.Quest(questID)
  if not q then return { "quest " .. questID .. ": not in QuestieDB" } end
  local function list(t)
    if type(t) ~= "table" or #t == 0 then return "-" end
    local out = {}
    for _, v in ipairs(t) do out[#out + 1] = tostring(v) end
    return table.concat(out, ",")
  end
  local before = {}
  for _, prev in ipairs(predecessors[questID] or {}) do before[#before + 1] = prev.id end
  local status, reason = Bridge.QuestStatus(questID)
  return {
    string.format("[%d] %s (id %d): level %s, requires %s", Bridge.QuestLevel(questID) or 0, q.name or "?", questID,
      tostring(q.questLevel), tostring(q.requiredLevel)),
    string.format("  after (preQuestSingle): %s  ·  after all (preQuestGroup): %s", list(q.preQuestSingle), list(q.preQuestGroup)),
    string.format("  chain: comes after %s, leads to %s  ·  parent %s  ·  breadcrumb for %s  ·  exclusive with %s",
      list(before), tostring(q.nextQuestInChain), tostring(q.parentQuest), tostring(q.breadcrumbForQuestId), list(q.exclusiveTo)),
    string.format("  inferred: comes after %s", q.inferredAfter and tostring(q.inferredAfter) or "-"),
    string.format("  status: %s (%s)%s", status, reason or "",
      ns.charDB.notOffered and ns.charDB.notOffered[questID] and "  ·  its giver didn't offer it" or ""),
  }
end

-- Where a quest's objectives are, as named groups of places (see
-- objectiveGroups), built once per quest. Empty without QuestieDB data.
local groupCache = {}

function Bridge.ObjectiveGroups(questID)
  if groupCache[questID] then return groupCache[questID] end
  local q = Bridge.Quest(questID)
  if not q then return {} end
  local ok, groups = pcall(objectiveGroups, q, q.name or ("Quest " .. questID))
  groupCache[questID] = ok and groups or {}
  return groupCache[questID]
end

-- The level shown for a quest (your level for quests that scale with you).
function Bridge.QuestLevel(questID)
  local q = Bridge.Quest(questID)
  return q and displayLevel(q, playerProfile()) or nil
end

-- Whether this character can take a quest, and why not:
--   status, reason[, stepID, stepState]
-- status is "available" (grey and red quests too; the reason says so), "inLog",
-- "done", "needsEarlier", "tooLow", "notForYou", "unavailable" or "unknown"
-- (not in QuestieDB). For "needsEarlier", stepID is the first quest of the
-- chain you can act on (see Bridge.ChainStart) and stepState "available" or
-- "inLog" (finish it first); both are nil when no earlier quest is open to you.
function Bridge.QuestStatus(questID, done, inLog)
  local q = Bridge.Quest(questID)
  if not q then return "unknown", "Unknown to QuestieDB." end
  if not done then done, inLog = playerQuestState() end
  return questStatus(q, playerProfile(), done, inLog)
end

-- The first quest on the way to `questID` you can act on now: stepID, stepState
-- ("available": take it; "inLog": finish it first), or nil.
function Bridge.ChainStart(questID, done, inLog)
  local q = Bridge.Quest(questID)
  if not q then return nil end
  if not done then done, inLog = playerQuestState() end
  return chainStart(q, playerProfile(), done, inLog, {})
end

-- Quests whose name contains `text` (case-insensitive), with or without a
-- starter, lowest ID first. The name index is built once, on the first search.
function Bridge.FindQuests(text)
  if not Bridge.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  if not nameIndex then
    nameIndex = {}
    for _, q in pairs(questByID) do
      if type(q.name) == "string" then nameIndex[#nameIndex + 1] = { q.name:lower(), q } end
    end
    table.sort(nameIndex, function(a, b) return a[2].id < b[2].id end)
  end
  local needle, out = text:lower(), {}
  for _, entry in ipairs(nameIndex) do
    if entry[1]:find(needle, 1, true) then out[#out + 1] = entry[2] end
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
