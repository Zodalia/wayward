local _, ns = ...

-- QuestieDB-shaped rows (spawns per AreaID in map percent, race and class bit
-- masks, NPC flag masks) as a Wayward source with Wayward's records.
-- Sources/QuestieLive.lua reads the installed QuestieDB through its public
-- API and hands this a reader (a companion addon with another QuestieDB-shaped
-- store can do the same):
--
--   reader.get(kind, id, field)    kind "quest", "npc", "object", "item"; nil when unknown
--   reader.getAll(kind, id, fields)  optional: { value, ... } for several fields in one read
--   reader.exists(kind, id)
--   reader.ids(kind)               { id, ... }
--   reader.uiMapFor(areaID)        uiMapID or nil
--   reader.raceMasks               { [raceID] = mask }
--   reader.classKeys               { [CLASS] = bit }
--   reader.npcFlags                { VENDOR = bit, TRAINER = bit, ... }
--   reader.questFields             the quest fields it has (a set)
--   reader.dungeons()              ZoneDB.private.dungeons: { [areaID] = {name, altIDs, parent, { {areaID, x, y} }} }
--   reader.questXP()               { [questID] = {questLevel, xp} }
--   reader.eraToForever(uiMapID, x, y)   percent in, percent out (optional)

local Q = {}
ns.QuestieShape = Q

-- Masks can exceed 32 bits (Skyborne), so test bits arithmetically.
local function hasBit(mask, bit)
  return bit ~= nil and bit > 0 and math.floor(mask / bit) % 2 == 1
end

local QUEST_FIELDS = { "name", "questLevel", "requiredLevel", "requiredRaces", "requiredClasses",
  "preQuestSingle", "preQuestGroup", "exclusiveTo", "startedBy", "requiredSkill", "nextQuestInChain",
  "parentQuest", "requiredMaxLevel", "availableUntilCompleted", "availableStartingWith", "disabledByQuest",
  "breadcrumbForQuestId", "zoneOrSort", "finishedBy", "objectives", "triggerEnd", "requiredSourceItems",
  "extraObjectives", "questFlags", "specialFlags", "reputationReward", "childQuests" }

local FLAG_NAMES = { VENDOR = "vendor", REPAIR = "repair", TRAINER = "trainer", FLIGHT_MASTER = "flightMaster",
  QUEST_GIVER = "questGiver", INNKEEPER = "innkeeper", BANKER = "banker", AUCTIONEER = "auctioneer",
  STABLEMASTER = "stableMaster" }

local ITEM_FIELDS = { "name", "itemLevel", "requiredLevel", "npcDrops", "objectDrops", "itemDrops",
  "questRewards", "vendors", "class", "subClass" }

-- { [key] = true } for the keys whose bit is set in `mask`, or nil for 0.
local function set(mask, bitByKey)
  if type(mask) ~= "number" or mask == 0 then return nil end
  local out, any = {}, false
  for key, bit in pairs(bitByKey or {}) do
    if type(bit) == "number" and hasBit(mask, bit) then
      out[key], any = true, true
    end
  end
  return any and out or nil
end
Q.Set = set

function Q.New(spec)
  local reader = spec.reader
  local positionsCache = setmetatable({}, { __mode = "k" })

  -- spawns = { [areaID] = { {x, y[, phase]}, ... } } (percent; x < 0: unknown)
  local function positions(spawns)
    if type(spawns) ~= "table" then return {} end
    if positionsCache[spawns] then return positionsCache[spawns] end
    local out = {}
    for areaID, points in pairs(spawns) do
      local mapID = reader.uiMapFor(areaID)
      for _, p in ipairs(type(points) == "table" and points or {}) do
        if type(p[1]) == "number" and p[1] >= 0 and type(p[2]) == "number" then
          out[#out + 1] = { mapID = mapID, x = p[1] / 100, y = p[2] / 100, areaID = areaID }
        end
      end
    end
    positionsCache[spawns] = out
    return out
  end

  local function flags(mask)
    local out = {}
    if type(mask) ~= "number" or mask == 0 then return out end
    for enumName, flag in pairs(FLAG_NAMES) do
      if hasBit(mask, reader.npcFlags[enumName]) then out[flag] = true end
    end
    return out
  end

  -- Several fields of one entity, in one read when the reader can.
  local function values(kind, id, fields)
    if reader.getAll then
      local all = reader.getAll(kind, id, fields)
      if all then return all end
    end
    local out = {}
    for i, field in ipairs(fields) do out[i] = reader.get(kind, id, field) end
    return out
  end

  local questFields -- the QUEST_FIELDS this reader has, built on the first quest
  local NPC_FIELDS = { "name", "subName", "friendlyToFaction", "rank", "minLevel", "maxLevel", "npcFlags", "spawns" }

  local source = { id = spec.id, label = spec.label, priority = spec.priority, Status = spec.status }

  function source.QuestIDs() return reader.ids("quest") end

  function source.Quest(id)
    if not reader.exists("quest", id) then return nil end
    if not questFields then
      questFields = {}
      for _, field in ipairs(QUEST_FIELDS) do
        if reader.questFields[field] then questFields[#questFields + 1] = field end
      end
    end
    local q = { id = id }
    local v = values("quest", id, questFields)
    for i, field in ipairs(questFields) do q[field] = v[i] end
    q.races = set(q.requiredRaces, reader.raceMasks)
    q.classes = set(q.requiredClasses, reader.classKeys)
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
    if not reader.exists("npc", id) then return nil end
    local v = values("npc", id, NPC_FIELDS)
    return { id = id, name = v[1], subName = v[2], faction = v[3], rank = v[4], minLevel = v[5], maxLevel = v[6],
      flags = flags(v[7]), positions = positions(v[8]) }
  end

  -- [flag] = { npcID, ... }, one pass over every NPC on the first ask.
  local byFlag
  function source.NpcIDs(flag)
    if not byFlag then
      byFlag = {}
      for _, id in ipairs(reader.ids("npc")) do
        for f in pairs(flags(reader.get("npc", id, "npcFlags"))) do
          byFlag[f] = byFlag[f] or {}
          table.insert(byFlag[f], id)
        end
      end
    end
    return byFlag[flag] or {}
  end

  function source.Object(id)
    if not reader.exists("object", id) then return nil end
    return { id = id, name = reader.get("object", id, "name"), positions = positions(reader.get("object", id, "spawns")) }
  end

  function source.ObjectIDs(name)
    local ids = reader.ids("object")
    if not name then return ids end
    local out = {}
    for _, id in ipairs(ids) do
      if reader.get("object", id, "name") == name then out[#out + 1] = id end
    end
    return out
  end

  function source.Item(id)
    if not reader.exists("item", id) then return nil end
    local item = { id = id }
    local v = values("item", id, ITEM_FIELDS)
    for i, field in ipairs(ITEM_FIELDS) do item[field] = v[i] end
    return item
  end

  function source.ItemIDs() return reader.ids("item") end
  -- One item's quests, for building the index below a slice at a time.
  function source.ItemQuestRewards(id) return reader.get("item", id, "questRewards") end

  -- [questID] = { itemID, ... }, one pass over the items' questRewards on the
  -- first ask (cheaper than Wayward reading every item record).
  local rewardIndex
  function source.QuestRewards()
    if rewardIndex then return rewardIndex end
    rewardIndex = {}
    for _, id in ipairs(reader.ids("item")) do
      local quests = reader.get("item", id, "questRewards")
      for _, questID in ipairs(type(quests) == "table" and quests or {}) do
        rewardIndex[questID] = rewardIndex[questID] or {}
        table.insert(rewardIndex[questID], id)
      end
    end
    return rewardIndex
  end

  local dungeonList
  function source.Dungeons()
    if dungeonList then return dungeonList end
    dungeonList = {}
    for areaID, d in pairs(reader.dungeons() or {}) do
      if type(d) == "table" and type(d[1]) == "string" then
        local spawns = {}
        for _, loc in ipairs(type(d[4]) == "table" and d[4] or {}) do
          if type(loc) == "table" and loc[1] then
            spawns[loc[1]] = spawns[loc[1]] or {}
            table.insert(spawns[loc[1]], { loc[2], loc[3] })
          end
        end
        dungeonList[#dungeonList + 1] = { areaID = areaID, name = d[1],
          alternativeAreaIds = type(d[2]) == "table" and d[2] or {}, positions = positions(spawns) }
      end
    end
    return dungeonList
  end

  function source.QuestXP() return reader.questXP() end

  if reader.eraToForever then
    function source.EraToForever(mapID, x, y)
      local fx, fy = reader.eraToForever(mapID, x * 100, y * 100)
      if type(fx) ~= "number" or type(fy) ~= "number" then return nil end
      return fx / 100, fy / 100
    end
  end

  return source
end
