local _, ns = ...

-- Quests from the data sources (Sources.lua): which ones you can take, where
-- their givers and objectives are, quest hubs, chains and follow-ups. Without
-- a source that has quests, every function answers "nothing" and the pages
-- say so.

local Quests = {}
ns.Quests = Quests

local Data = ns.Data
local HUB_RADIUS = 120 -- yards between neighbouring quest givers in one hub

local questIndex
local giverNodes = {}

local function now()
  return debugprofilestop and debugprofilestop() or 0
end

-- True when a data source has quests.
function Quests.Available()
  return Data.Has("Quest")
end


---------------------------------------------------------------- quests

local predecessors -- [questID] = { quests whose nextQuestInChain is questID }
local questByID -- [questID] = quest row (every quest, with or without a starter)

-- Forever adds quests the data knows nothing about the chains of (e.g. a
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

-- Only in Forever: Classic Era's own high IDs (Season of Discovery's) aren't
-- Forever's additions.
local function inferChains()
  local forever = ns.IsForever()
  local byName = {}
  for id, q in pairs(questByID) do
    if type(q.name) == "string" then
      byName[q.name] = byName[q.name] or {}
      table.insert(byName[q.name], id)
    end
  end
  for id, q in pairs(questByID) do
    if id >= FOREVER_QUEST_IDS and forever and noChainData(q) then
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

-- Rows are copies of the source's records, so inferred links stay ours.
-- Built into locals and kept at the end: built by Quests.Warm a slice at a
-- time, a half-built index is never seen, and one built directly meanwhile
-- (or for other sources) wins.
local generation = 0

local function buildQuestIndex()
  local built = generation
  local index, before, byID = {}, {}, {}
  local started = now()
  for _, id in ipairs(Data.QuestIDs()) do
    ns.WarmStep()
    local record = Data.Quest(id)
    if type(record) == "table" then
      local q = {}
      for k, v in pairs(record) do q[k] = v end
      q.id = id
      byID[id] = q
      local nextID = q.nextQuestInChain or 0
      if nextID ~= 0 then
        before[nextID] = before[nextID] or {}
        table.insert(before[nextID], q)
      end
      local starters = q.startedBy or {}
      if (starters[1] and #starters[1] > 0) or (starters[2] and #starters[2] > 0) then
        index[#index + 1] = q
      end
    end
  end
  if questIndex or built ~= generation then return end
  questIndex, predecessors, questByID = index, before, byID
  inferChains()
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.quests = now() - started
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
  -- tooHard: read once per profile, not once per quest.
  return { level = UnitLevel("player"), raceID = raceID, class = class, tooHard = ns.TooHardLevels() }
end

-- Level <= 0 means "scales with you" in quest data; show your level.
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
  for _, id in ipairs(ns.QuestLog.CompletedIDs()) do done[id] = true end
  for _, info in ns.QuestLog.Entries() do
    if not info.isHeader and info.questID then inLog[info.questID] = true end
  end
  questState = now and { done = done, inLog = inLog, at = now } or nil
  return done, inLog
end

-- Bumped whenever what you can take may have changed (quest events, levels).
local questVersion = 0

for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED" }) do
  ns.On(event, function()
    questState = nil
    questVersion = questVersion + 1
  end)
end
-- Abandoning a quest: QUEST_REMOVED fires for a hand-in too, so a moment
-- later, a quest that wasn't handed in and isn't back in your log was dropped:
-- QUEST_ABANDONED(questID) for the journey, For you and quest times.
local ABANDON_CHECK = 0.5
local handedIn = {}

ns.On("QUEST_TURNED_IN", function(questID) if questID then handedIn[questID] = true end end)
ns.On("QUEST_REMOVED", function(questID)
  if not questID then return end
  ns.After(ABANDON_CHECK, function()
    if handedIn[questID] then
      handedIn[questID] = nil
      return
    end
    questState = nil
    local done, inLog = playerQuestState()
    if done[questID] or inLog[questID] then return end
    ns.Fire("QUEST_ABANDONED", questID)
  end)
end)

-- QUEST_LOG_UPDATE fires on every kill and loot: the log is read again (once
-- per QUEST_STATE_SECONDS at most), but what you can take hasn't changed, so
-- the lists built per version stay.
ns.On("QUEST_LOG_UPDATE", function() questState = nil end)
-- Quests a giver didn't offer you (see Navigator.lua) count as locked until you
-- hand something in or level up, when they may have opened.
function Quests.MarkNotOffered(questID)
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
  if q.races and not q.races[p.raceID] then return false end
  if q.classes and not q.classes[p.class] then return false end
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
-- Field meanings: the quest record in Sources.lua. Questie handles more
-- (holiday/event flags, reputation); quests needing a profession are left out.
local function blocker(q, p, done, inLog)
  if done[q.id] then return "done", "You have done this quest." end
  if inLog[q.id] then return "inLog", "In your quest log." end
  -- The game knows better than the data: its giver didn't offer it.
  local notOffered = ns.charDB and ns.charDB.notOffered
  if notOffered and notOffered[q.id] then return "needsEarlier", "Not offered yet: needs earlier quests." end
  if q.races and not q.races[p.raceID] then
    return "notForYou", "Not for your race."
  end
  if q.classes and not q.classes[p.class] then
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

-- Hubs hide grey quests (little XP) and red ones (too hard; orange too on
-- Hardcore: ns.TooHardLevels).
local function fitsLevel(q, p)
  local questLevel = (q.questLevel or 0) ~= 0 and q.questLevel or q.requiredLevel or 0
  if questLevel <= 0 then return true, questLevel end
  if isTrivial(questLevel, p.level) then return false, questLevel, "grey" end
  if questLevel - p.level >= (p.tooHard or ns.TooHardLevels()) then return false, questLevel, "red" end
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

-- status, reason[, stepID, stepState] for a quest row (see Quests.QuestStatus).
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
    local record = kind == "npc" and Data.Npc(id) or (kind == "object" and Data.Object(id)) or nil
    local name = record and record.name
    local ok = record ~= nil and (kind ~= "npc" or Data.FriendlyTo(record.faction, faction))
    local nodes = ok and Data.Nodes(record.positions, name) or {}
    -- Objects (a box, a sign, Buzzbox 323) can't be talked to or targeted.
    if kind == "object" then
      local flagged = {}
      for i, n in ipairs(nodes) do
        local copy = {}
        for k, v in pairs(n) do copy[k] = v end
        copy.object = true
        flagged[i] = copy
      end
      nodes = flagged
    end
    giverNodes[key] = ok and { name = name, nodes = nodes } or false
  end
  local giver = giverNodes[key]
  if not giver or #giver.nodes == 0 then return nil end
  return giver.name, Data.Nearest(giver.nodes, here)
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

-- The quests you can take now (the Quest hubs rules), kept until your quests
-- or level change: checking every quest is the slow part, and For you and the
-- Quests page both ask in one refresh. Where you stand only changes the order.
local takeable -- { key, quests = { quest row, ... } }

local function takeableQuests(p)
  local key = questVersion .. ":" .. p.level .. ":" .. tostring(questIndex)
  if takeable and takeable.key == key then return takeable.quests end
  local done, inLog = playerQuestState()
  local quests = {}
  for _, q in ipairs(questIndex) do
    ns.WarmStep()
    if eligible(q, p, done, inLog) then quests[#quests + 1] = q end
  end
  takeable = { key = key, quests = quests }
  return quests
end

-- Hubs of quest givers you can take quests from, nearest first (straight line).
function Quests.QuestHubs(here, limit)
  if not Quests.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  local faction = UnitFactionGroup("player")
  local p = playerProfile()

  local givers, order = {}, {}
  for _, q in ipairs(takeableQuests(p)) do
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

  table.sort(order, function(a, b) return a.distance < b.distance end)
  return Quests.Cluster(order, limit or 12)
end

-- Where this character can quest, zone by zone (the zone of each quest's
-- nearest starter): quests you can take now, and the follow-ups their chains
-- unlock (a quest that needs earlier quests, the first of which you can take
-- or have in your log), all fitting your level. Built fresh each call; For
-- you caches its page.
--   { [zone uiMapID] = { mapID, quests = { {id, name, level, node, giver, chain}, ... } } }
local zoneCache -- { key, zones }: reused until your quests or level change

function Quests.ZoneQuests(here)
  if not Quests.Available() then return {} end
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
    ns.WarmStep()
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

-- The AreaID a quest belongs to (zoneOrSort > 0), or nil: a negative
-- zoneOrSort is a QuestSort (class, profession, holiday...), not a place.
function Quests.QuestArea(q)
  local area = q and tonumber(q.zoneOrSort)
  return area and area > 0 and area or nil
end

-- Quests whose AreaID (Quests.QuestArea) is in `areaIDs` (a set; for a dungeon quest that is
-- the dungeon's AreaID): { [areaID] = { available = {...}, inLog = {...},
-- later = {...} } }. `later` are ones you can't take yet but will: too low a
-- level for them (with requiredLevel), too hard for now, or after earlier
-- quests of their chain.
function Quests.QuestsForAreas(areaIDs)
  if not Quests.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  local p = playerProfile()
  local done, inLog = playerQuestState()
  local out = {}
  for _, q in ipairs(questIndex) do
    ns.WarmStep()
    local area = Quests.QuestArea(q)
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

-- For pages built on quests (Quests, Items, For you). Rows are copies of the
-- quest records (Sources.lua) plus inferredAfter; treat them as read-only.

function Quests.Quest(questID)
  if not Quests.Available() then return nil end
  if not questIndex then buildQuestIndex() end
  return questByID[questID]
end

-- Every quest that has an NPC or object starter.
function Quests.AllQuests()
  if not Quests.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  return questIndex
end

-- done, inLog: sets of quest IDs for this character right now.
function Quests.PlayerQuestState()
  return playerQuestState()
end

-- True when this character can pick the quest up now (same rules as Quest hubs).
function Quests.IsQuestAvailable(questID, done, inLog)
  local q = Quests.Quest(questID)
  if not q then return false end
  if not done then done, inLog = playerQuestState() end
  return eligible(q, playerProfile(), done, inLog)
end

-- Nearest starter of a quest you can talk to: name, node, distance (or nil).
function Quests.QuestGiver(questID, here)
  local q = Quests.Quest(questID)
  if not (q and q.startedBy) then return nil end
  local name, node, distance = nearestOf(q.startedBy, here, UnitFactionGroup("player"))
  return name, node, distance
end

-- Nearest NPC or object you hand the quest in to: name, node, distance (or nil).
function Quests.QuestFinisher(questID, here)
  local q = Quests.Quest(questID)
  if not (q and q.finishedBy) then return nil end
  local name, node, distance = nearestOf(q.finishedBy, here, UnitFactionGroup("player"))
  return name, node, distance
end

-- Where to work on a quest's objectives: the nearest place, as a route node.
-- In your log, the game's own quest-area marker (C_QuestLog.GetQuestsOnMap);
-- otherwise the quest data: creatures to kill, objects to use, mobs that drop the
-- items you need, and places to explore. Returns node, source or nil.
local MAX_DROPPERS = 6

local function logArea(questID, label)
  if not (C_QuestLog.GetQuestsOnMap and ns.QuestLog.LogIndex(questID)) then return nil end
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
  local item = Data.Item(itemID)
  if not item then return nodes end
  local function add(record)
    for _, node in ipairs(record and Data.Nodes(record.positions, label) or {}) do nodes[#nodes + 1] = node end
  end
  for i, npcID in ipairs(item.npcDrops or {}) do
    if i > MAX_DROPPERS then break end
    add(Data.Npc(npcID))
  end
  for i, objectID in ipairs(item.objectDrops or {}) do
    if i > MAX_DROPPERS then break end
    add(Data.Object(objectID))
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
    local npc = Data.Npc(creature[1])
    groups[#groups + 1] = { name = npc and npc.name, nodes = npc and Data.Nodes(npc.positions, label) or {} }
  end
  for _, object in ipairs(objectives[2] or {}) do
    local o = Data.Object(object[1])
    groups[#groups + 1] = { name = o and o.name, nodes = o and Data.Nodes(o.positions, label) or {} }
  end
  for _, item in ipairs(objectives[3] or {}) do
    local i = Data.Item(item[1])
    groups[#groups + 1] = { name = i and i.name, nodes = itemNodes(item[1], label) }
  end
  if type(q.triggerEnd) == "table" then
    groups[#groups + 1] = { name = type(q.triggerEnd[1]) == "string" and q.triggerEnd[1] or nil,
      nodes = Data.Nodes(q.triggerEnd[2], label) }
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

-- The data's objective places don't change, so each quest's list is built
-- once; the game's own marker is read fresh every time.
local objectiveCache = {}

function Quests.ObjectiveNode(questID, here)
  local q = Quests.Quest(questID)
  local label = q and q.name or ("Quest " .. questID)
  local area = logArea(questID, label)
  if area then return area, "log" end
  if not q then return nil end
  local nodes = objectiveCache[questID]
  if not nodes then
    local ok, built = ns.Protect(objectiveNodes, q, label)
    nodes = ok and built or {}
    objectiveCache[questID] = nodes
  end
  if #nodes == 0 then return nil end
  return Data.Nearest(nodes, here), "data"
end

-- What a quest needs before its objectives can be done, from the data, in
-- order: items to collect first (its source items that drop or lie somewhere,
-- and that you don't have yet), then its extra objectives (e.g. "Fill the
-- bowl at the moonwell"), each with its nearest place:
--   { {kind = "item", itemID, text, node} | {kind = "event", text, node}, ... }
function Quests.QuestPrep(questID, here)
  if not Quests.Available() then return {} end
  local q = Quests.Quest(questID)
  if not q then return {} end
  local out, objectiveItems = {}, {}
  local groups = type(q.objectives) == "table" and q.objectives or {}
  for _, item in ipairs(groups[3] or {}) do objectiveItems[item[1]] = true end
  for _, itemID in ipairs(type(q.requiredSourceItems) == "table" and q.requiredSourceItems or {}) do
    local have = ns.ItemCount(itemID) > 0
    if type(itemID) == "number" and not objectiveItems[itemID] and not have then
      local item = Data.Item(itemID)
      local name = item and item.name or ("item " .. itemID)
      local node = Data.Nearest(itemNodes(itemID, name), here)
      if node then out[#out + 1] = { kind = "item", itemID = itemID, text = "Collect " .. name, node = node } end
    end
  end
  for _, extra in ipairs(type(q.extraObjectives) == "table" and q.extraObjectives or {}) do
    local positions, text = extra[1], extra[3]
    if type(positions) == "table" and type(text) == "string" then
      local node = Data.Nearest(Data.Nodes(positions, text), here)
      if node then out[#out + 1] = { kind = "event", text = text, node = node } end
    end
  end
  return out
end

-- The quests that follow `questID` in its chain (the data's links, quests
-- that need it, and inferred Forever links) that you could take once it's
-- done: your race and class, your level, not done yet. Quest rows.
local followers -- [questID] = { quest rows that come after it }

local function buildFollowers()
  local built = {}
  local function add(before, q)
    built[before] = built[before] or {}
    table.insert(built[before], q)
  end
  for _, q in pairs(questByID) do
    ns.WarmStep()
    if (q.nextQuestInChain or 0) ~= 0 and questByID[q.nextQuestInChain] then add(q.id, questByID[q.nextQuestInChain]) end
    for _, id in ipairs(q.preQuestSingle or {}) do add(id, q) end
    for _, id in ipairs(q.preQuestGroup or {}) do add(id, q) end
    if q.inferredAfter then add(q.inferredAfter, q) end
  end
  followers = followers or built
end

function Quests.FollowUps(questID)
  if not Quests.Available() then return {} end
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

-- The quests that come after `questID` in its chain, whoever you are (quest
-- rows; see FollowUps for the ones this character could take).
function Quests.After(questID)
  if not Quests.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  if not followers then buildFollowers() end
  return followers[questID] or {}
end

-- The whole chain ahead of a quest, from the data alone (not what you have
-- done): every quest that follows it, step by step over `followers`, up to
-- CHAIN_DEPTH steps. Quests that close each other (exclusiveTo) are one step
-- with alternatives. Built once per quest, until the data or your level changes.
--   { steps = { quest row, ... } (in order), alternatives = { [stepID] = { quest row, ... } },
--     count, reachable (steps your race, class and level can ever do),
--     levelSpan = {min, max} or nil, dungeons = { {name, areaID, questID}, ... },
--     endsAt = {name, dungeon} or nil, items = Quests.RewardItems of the steps (when it exists) }
-- levelSpan, dungeons, endsAt and items count only the steps you can do.
local CHAIN_DEPTH = 12
local CHAIN_MAX_STEPS = 30
local LONG_CHAIN = 3 -- this many steps ahead make a quest worth pointing out
local chainCache = {}

local function canEverReach(q, p)
  return canEverDo(q, p) and ((q.requiredMaxLevel or 0) == 0 or p.level <= q.requiredMaxLevel)
end

local function closes(a, b)
  for _, id in ipairs(a.exclusiveTo or {}) do
    if id == b.id then return true end
  end
  return false
end

-- The quests of one step, grouped: quests that close each other are one group.
local function exclusiveGroups(quests)
  local groups = {}
  for _, q in ipairs(quests) do
    local home
    for _, g in ipairs(groups) do
      for _, other in ipairs(g) do
        if closes(q, other) or closes(other, q) then home = g break end
      end
      if home then break end
    end
    if home then table.insert(home, q) else groups[#groups + 1] = { q } end
  end
  return groups
end

local function areaName(areaID)
  local name = C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(areaID)
  return type(name) == "string" and name ~= "" and name or nil
end

-- A spawn of whoever takes the quest in (else gives it out).
local function questEndNode(q)
  for _, ends in ipairs({ q.finishedBy or {}, q.startedBy or {} }) do
    for _, id in ipairs(ends[1] or {}) do
      local npc = Data.Npc(id)
      local node = npc and Data.Nodes(npc.positions, npc.name)[1]
      if node then return node end
    end
  end
  return nil
end

-- Where the chain finishes: a dungeon, the town or zone of the last hand-in,
-- or the quest's own zone.
local function chainEnd(q)
  local area = q.zoneOrSort
  local dungeon = type(area) == "number" and area > 0 and ns.Dungeons and ns.Dungeons.ForArea(area)
  if dungeon then return { name = dungeon.name, dungeon = true } end
  local node = questEndNode(q)
  if node then
    local ok, place = pcall(ns.Places.NameFor, node)
    if ok and place then return { name = place } end
    local zone = ns.Geo.ZoneAt(node.instance, node.wx, node.wy)
    if zone then return { name = ns.MapName(zone) } end
  end
  local name = type(area) == "number" and area > 0 and areaName(area)
  return name and { name = name } or nil
end

local function chainAhead(start, p)
  ns.WarmStep()
  local ahead = { steps = {}, alternatives = {}, count = 0, reachable = 0, dungeons = {} }
  local seen, frontier = { [start.id] = true }, { start }
  local lastReachable
  for _ = 1, CHAIN_DEPTH do
    local nextQuests = {}
    for _, q in ipairs(frontier) do
      for _, f in ipairs(followers[q.id] or {}) do
        if not seen[f.id] then
          seen[f.id] = true
          nextQuests[#nextQuests + 1] = f
        end
      end
    end
    if #nextQuests == 0 or #ahead.steps >= CHAIN_MAX_STEPS then break end
    table.sort(nextQuests, function(a, b) return a.id < b.id end)
    for _, group in ipairs(exclusiveGroups(nextQuests)) do
      -- The step is the first alternative you can do; the rest are listed with it.
      local step = group[1]
      for _, q in ipairs(group) do
        if canEverReach(q, p) then step = q break end
      end
      ahead.steps[#ahead.steps + 1] = step
      if #group > 1 then
        local others = {}
        for _, q in ipairs(group) do
          if q ~= step then others[#others + 1] = q end
        end
        ahead.alternatives[step.id] = others
      end
      if canEverReach(step, p) then
        ahead.reachable = ahead.reachable + 1
        lastReachable = step
      end
    end
    frontier = nextQuests
  end
  ahead.count = #ahead.steps

  local dungeonSeen, items = {}, {}
  for _, q in ipairs(ahead.steps) do
    if canEverReach(q, p) then
      local level = (q.questLevel or 0) > 0 and q.questLevel or q.requiredLevel or 0
      if level > 0 then
        ahead.levelSpan = ahead.levelSpan or { level, level }
        ahead.levelSpan[1] = math.min(ahead.levelSpan[1], level)
        ahead.levelSpan[2] = math.max(ahead.levelSpan[2], level)
      end
      local area = q.zoneOrSort
      local dungeon = type(area) == "number" and area > 0 and ns.Dungeons and ns.Dungeons.ForArea(area)
      if dungeon and not dungeonSeen[dungeon.name] then
        dungeonSeen[dungeon.name] = true
        ahead.dungeons[#ahead.dungeons + 1] = { name = dungeon.name, areaID = area, questID = q.id }
      end
      if Quests.RewardItems then
        for _, item in ipairs(Quests.RewardItems(q.id) or {}) do items[#items + 1] = item end
      end
    end
  end
  if Quests.RewardItems then ahead.items = items end
  ahead.endsAt = lastReachable and chainEnd(lastReachable) or nil
  return ahead
end

function Quests.ChainAhead(questID)
  if not Quests.Available() then return nil end
  if not questIndex then buildQuestIndex() end
  local q = questByID[questID]
  if not q then return nil end
  if not followers then buildFollowers() end
  if not chainCache[questID] then chainCache[questID] = chainAhead(q, playerProfile()) end
  return chainCache[questID]
end

local function itemName(item)
  if type(item) == "table" then return item.name end
  local record = type(item) == "number" and Data.Item(item)
  return record and record.name or nil
end

local function namesList(names)
  if #names <= 1 then return names[1] or "" end
  return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- One or two short lines on what a quest leads to, or nil when nothing you
-- can do follows it:
--   "Chain: 4 more quests (levels 18-24), ends in The Deadmines"
--   "Leads to a Shadowfang Keep quest"
function Quests.ChainText(questID)
  local ahead = Quests.ChainAhead(questID)
  if not (ahead and ahead.reachable > 0) then return nil end
  -- "a Deadmines quest", not "a The Deadmines quest".
  local dungeonNames = {}
  for _, d in ipairs(ahead.dungeons) do dungeonNames[#dungeonNames + 1] = (d.name:gsub("^The ", "")) end
  local lines = {}
  if ahead.reachable == 1 and #dungeonNames == 1 then
    lines[1] = "Leads to a " .. dungeonNames[1] .. " quest"
  else
    local span = ahead.levelSpan
    local levels = span and (span[1] == span[2] and string.format(" (level %d)", span[1])
      or string.format(" (levels %d-%d)", span[1], span[2])) or ""
    local text = string.format("Chain: %d more quest%s%s", ahead.reachable, ahead.reachable == 1 and "" or "s", levels)
    local endsInDungeon = ahead.endsAt and ahead.endsAt.dungeon
    if ahead.endsAt then text = text .. ", ends in " .. ahead.endsAt.name end
    lines[1] = text
    if #dungeonNames > 0 and not (endsInDungeon and #dungeonNames == 1) then
      lines[2] = #dungeonNames == 1 and ("Leads to a " .. dungeonNames[1] .. " quest")
        or ("Leads to " .. namesList(dungeonNames) .. " quests")
    end
  end
  local itemNames = {}
  for _, item in ipairs(ahead.items or {}) do
    local name = itemName(item)
    if name and #itemNames < 3 then itemNames[#itemNames + 1] = name end
  end
  if #itemNames > 0 and #lines < 2 then lines[#lines + 1] = "Rewards on the way: " .. namesList(itemNames) end
  return table.concat(lines, "\n")
end

-- The dungeon a quest's chain leads to (the first), or nil.
function Quests.ChainDungeon(questID)
  local ahead = Quests.ChainAhead(questID)
  local d = ahead and ahead.dungeons[1]
  return d and d.name or nil
end

-- ChainText, only when the chain is worth pointing out on its own (it leads
-- to a dungeon quest, or LONG_CHAIN or more quests follow).
function Quests.ChainHighlight(questID)
  local ahead = Quests.ChainAhead(questID)
  if not (ahead and (#ahead.dungeons > 0 or ahead.reachable >= LONG_CHAIN)) then return nil end
  return Quests.ChainText(questID)
end

-- The chain ahead as lines, for /ww debug quest.
function Quests.DescribeChain(questID)
  local ahead = Quests.ChainAhead(questID)
  if not ahead or ahead.count == 0 then return { "  chain ahead: nothing follows" } end
  local p = playerProfile()
  local out = { string.format("  chain ahead: %d step%s, %d you can do%s", ahead.count, ahead.count == 1 and "" or "s",
    ahead.reachable, ahead.endsAt and (", ends in " .. ahead.endsAt.name) or "") }
  for i, q in ipairs(ahead.steps) do
    local others = {}
    for _, alt in ipairs(ahead.alternatives[q.id] or {}) do others[#others + 1] = alt.name .. " (" .. alt.id .. ")" end
    local area = q.zoneOrSort
    local dungeon = type(area) == "number" and area > 0 and ns.Dungeons and ns.Dungeons.ForArea(area)
    out[#out + 1] = string.format("    %d. [%d] %s (id %d)%s%s%s", i, (q.questLevel or 0) > 0 and q.questLevel
      or q.requiredLevel or 0, q.name or "?", q.id, dungeon and ("  ·  " .. dungeon.name) or "",
      canEverReach(q, p) and "" or "  ·  not for you",
      #others > 0 and ("  ·  or " .. table.concat(others, ", ")) or "")
  end
  local text = Quests.ChainText(questID)
  if text then out[#out + 1] = "    " .. text:gsub("\n", "  ·  ") end
  return out
end

-- What the data says about a quest's place in its chain, for /ww debug quest.
function Quests.Describe(questID)
  local q = Quests.Quest(questID)
  if not q then return { "quest " .. questID .. ": not in the quest data" } end
  local function list(t)
    if type(t) ~= "table" or #t == 0 then return "-" end
    local out = {}
    for _, v in ipairs(t) do out[#out + 1] = tostring(v) end
    return table.concat(out, ",")
  end
  local before = {}
  for _, prev in ipairs(predecessors[questID] or {}) do before[#before + 1] = prev.id end
  local status, reason = Quests.QuestStatus(questID)
  return {
    string.format("[%d] %s (id %d): level %s, requires %s", Quests.QuestLevel(questID) or 0, q.name or "?", questID,
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
-- objectiveGroups), built once per quest. Empty without quest data.
local groupCache = {}

function Quests.ObjectiveGroups(questID)
  if groupCache[questID] then return groupCache[questID] end
  local q = Quests.Quest(questID)
  if not q then return {} end
  local ok, groups = ns.Protect(objectiveGroups, q, q.name or ("Quest " .. questID))
  groupCache[questID] = ok and groups or {}
  return groupCache[questID]
end

-- The mobs a quest's objectives want: creatures to kill and those that drop
-- the items it needs, by NPC ID and by name ({ ids = set, names = set }), for
-- telling them apart on nameplates. Built once per quest.
local mobCache = {}

function Quests.ObjectiveMobs(questID)
  if mobCache[questID] then return mobCache[questID] end
  local mobs = { ids = {}, names = {} }
  local function add(npcID)
    if type(npcID) ~= "number" then return end
    mobs.ids[npcID] = true
    local npc = Data.Npc(npcID)
    if npc and type(npc.name) == "string" then mobs.names[npc.name] = true end
  end
  local q = Quests.Quest(questID)
  local objectives = q and type(q.objectives) == "table" and q.objectives or {}
  for _, creature in ipairs(objectives[1] or {}) do add(creature[1]) end
  for _, entry in ipairs(objectives[3] or {}) do
    local item = Data.Item(entry[1])
    for i, npcID in ipairs(item and item.npcDrops or {}) do
      if i > MAX_DROPPERS then break end
      add(npcID)
    end
  end
  mobCache[questID] = mobs
  return mobs
end

-- How many kills or items a quest in your log still needs, summed over its
-- unfinished objectives ("Murloc Forager slain: 2/8" needs 6), or nil when
-- the log doesn't say.
function Quests.ObjectivesLeft(questID)
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  if type(objectives) ~= "table" then return nil end
  local left, known = 0, false
  for _, o in ipairs(objectives) do
    local have, need = o.numFulfilled, o.numRequired
    if not (type(have) == "number" and type(need) == "number") and type(o.text) == "string" then
      local a, b = o.text:match("(%d+)%s*/%s*(%d+)")
      have, need = tonumber(a), tonumber(b)
    end
    if type(have) == "number" and type(need) == "number" then
      known = true
      if not o.finished then left = left + math.max(0, need - have) end
    end
  end
  return known and left or nil
end

-- The same places as areas: spawns within AREA_LINK yards of each other (in a
-- chain) are one area, e.g. one murloc camp up the coast from the next. Each
-- area is a list of { node, group } (group: its index in ObjectiveGroups);
-- the order is stable, so an area's index names it. Built once per quest.
local AREA_LINK = 70
local areaCache = {}

local function buildAreas(questID)
  local members = {}
  for g, group in ipairs(Quests.ObjectiveGroups(questID)) do
    for _, node in ipairs(group.nodes) do members[#members + 1] = { node = node, group = g } end
  end
  -- Single linkage over a grid of AREA_LINK cells: only neighbouring cells are compared.
  local parent, cells = {}, {}
  local function find(i)
    while parent[i] ~= i do
      parent[i] = parent[parent[i]]
      i = parent[i]
    end
    return i
  end
  local function cell(node, dx, dy)
    return node.instance .. ":" .. (math.floor(node.wx / AREA_LINK) + dx) .. ":" .. (math.floor(node.wy / AREA_LINK) + dy)
  end
  for i, m in ipairs(members) do
    parent[i] = i
    for dx = -1, 1 do
      for dy = -1, 1 do
        for _, j in ipairs(cells[cell(m.node, dx, dy)] or {}) do
          if ns.Geo.Distance(m.node, members[j].node) <= AREA_LINK then
            local a, b = find(i), find(j)
            if a ~= b then parent[a] = b end
          end
        end
      end
    end
    local key = cell(m.node, 0, 0)
    cells[key] = cells[key] or {}
    table.insert(cells[key], i)
  end
  local byRoot, areas = {}, {}
  for i, m in ipairs(members) do
    local root = find(i)
    if not byRoot[root] then
      byRoot[root] = {}
      areas[#areas + 1] = byRoot[root]
    end
    table.insert(byRoot[root], m)
  end
  return areas
end

function Quests.ObjectiveAreas(questID)
  if areaCache[questID] then return areaCache[questID] end
  local ok, areas = ns.Protect(buildAreas, questID)
  areaCache[questID] = ok and areas or {}
  return areaCache[questID]
end

-- The level shown for a quest (your level for quests that scale with you).
function Quests.QuestLevel(questID)
  local q = Quests.Quest(questID)
  return q and displayLevel(q, playerProfile()) or nil
end

-- Whether this character can take a quest, and why not:
--   status, reason[, stepID, stepState]
-- status is "available" (grey and red quests too; the reason says so), "inLog",
-- "done", "needsEarlier", "tooLow", "notForYou", "unavailable" or "unknown"
-- (not in the quest data). For "needsEarlier", stepID is the first quest of the
-- chain you can act on (see Quests.ChainStart) and stepState "available" or
-- "inLog" (finish it first); both are nil when no earlier quest is open to you.
function Quests.QuestStatus(questID, done, inLog)
  local q = Quests.Quest(questID)
  if not q then return "unknown", "Not in the quest data." end
  if not done then done, inLog = playerQuestState() end
  return questStatus(q, playerProfile(), done, inLog)
end

-- The first quest on the way to `questID` you can act on now: stepID, stepState
-- ("available": take it; "inLog": finish it first), or nil.
function Quests.ChainStart(questID, done, inLog)
  local q = Quests.Quest(questID)
  if not q then return nil end
  if not done then done, inLog = playerQuestState() end
  return chainStart(q, playerProfile(), done, inLog, {})
end

-- Where you stand with a quest whose reward you want (the Items page):
-- "available", "low" (grey, you can still take it), "inLog", "done", "level"
-- (you are too low), "hard" (red, or orange on Hardcore), "chain" (needs
-- earlier quests), or nil (never for you, or not any more). The same rules
-- as QuestStatus, in the Items page's words.
function Quests.RewardStatus(questID, done, inLog)
  local q = Quests.Quest(questID)
  if not q then return nil end
  if not done then done, inLog = playerQuestState() end
  local p = playerProfile()
  local status = blocker(q, p, done, inLog)
  if status == "done" or status == "inLog" then return status end
  if status == "tooLow" then return "level" end
  if status == "needsEarlier" then return "chain" end
  if status then return nil end
  local _, _, why = fitsLevel(q, p)
  if why == "red" then return "hard" end
  if why == "grey" then return "low" end
  return "available"
end

-- Every quest the data knows, by ID (with or without a starter), for indexes
-- built over all of them (Search.lua). Read-only.
function Quests.Index()
  if not Quests.Available() then return {} end
  if not questIndex then buildQuestIndex() end
  return questByID
end

-- Quests whose name contains `text` (case-insensitive), with or without a
-- starter, best match first (Search.lua does the matching).
function Quests.FindQuests(text)
  if not Quests.Available() then return {} end
  local out = {}
  for _, m in ipairs(ns.Search.Find(text, "quest")) do out[#out + 1] = m.quest end
  return out
end

local function addGiver(hub, g)
  table.insert(hub.givers, g)
  hub.count = hub.count + #g.quests
  if #g.quests > #hub.anchor.quests then hub.anchor = g end
end

-- Single linkage: a giver joins every hub it is near any member of, and the
-- hubs it bridges merge. Past `limit`, givers can still join existing hubs.
function Quests.Cluster(givers, limit)
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

-- Indexes are rebuilt when a source registers (a companion loading later).
ns.Listen("SOURCES_CHANGED", function()
  generation = generation + 1
  questIndex, predecessors, questByID, followers = nil, nil, nil, nil
  giverNodes, objectiveCache, groupCache, areaCache, mobCache, zoneCache, takeable = {}, {}, {}, {}, {}, nil, nil
  questState, questVersion = nil, questVersion + 1
  chainCache = {}
end)
-- The quest index (and the reward items, Notable.lua) built a slice per frame
-- (ns.Warm) after a login and when the sources change, so no page builds it
-- all at once. True while that's still going: pages wait for it (and get
-- DATA_CHANGED when it's done).
local warmQueued, warmPending = {}, 0
local warmers = { quests = function() if not questIndex then buildQuestIndex() end end }

function Quests.AddWarmer(name, fn)
  warmers[name] = fn
end

function Quests.Warm()
  if Quests.Available() then
    for name, fn in pairs(warmers) do
      if warmQueued[name] ~= generation then
        warmQueued[name] = generation
        warmPending = warmPending + 1
        ns.Warm(fn, function()
          warmPending = warmPending - 1
          if warmPending == 0 then ns.Fire("DATA_CHANGED") end
        end)
      end
    end
  end
  return warmPending > 0
end

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if isLogin or isReload then ns.After(2, Quests.Warm) end
end)
ns.Listen("SOURCES_CHANGED", function() ns.After(1, Quests.Warm) end)

-- Chains ahead count what your level can do, and name dungeons and places
-- learned while playing.
ns.Listen("DATA_CHANGED", function() chainCache = {} end)
