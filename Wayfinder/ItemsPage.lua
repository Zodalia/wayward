local _, ns = ...

-- "Items" page: shift-click an item into the search box (or `/wf item
-- <link>`), or type its name, and see where it comes from, each source with
-- directions: dungeon drops (to the entrance), mobs and objects in the world
-- (nearest spawn, one row per zone), quests that reward it and the nearest
-- vendor that sells it. Things you can do now come first, then shorter trips.
--
-- Sources come from QuestieDB's ItemDB (npcDrops, objectDrops, itemDrops,
-- questRewards, vendors), read at runtime like QuestieBridge.lua. Without
-- it, only vendors you visited that sold the item are known (Vendors.lua
-- records merchant goods).

local Items = {}
ns.Items = Items

local MAX_MATCHES = 20  -- name search results shown
local MIN_QUERY = 3     -- letters before a name search runs
local CANDIDATES = 4    -- nearest places (straight line) per row that get a full route
local ZONE_ROWS = 3     -- world-drop rows per kind (mobs, objects)
local DUNGEON_REACH = 3 -- a dungeon up to this many levels above you counts as "now"
local MOB_REACH = 4     -- mobs up to this many levels above you count as "now"
local RED_LEVELS = 5    -- a quest this many levels above you is too hard (as in QuestieBridge.lua)

-- Ranking tiers: every row of a tier comes before the next tier, then by trip time.
local NOW, LATER, INFO = 0, 1, 2
local TIER_SECONDS = 1e7

-- Which dropper names a dungeon row: bosses, then rare elites, elites, rares.
local RANK_ORDER = { [3] = 4, [2] = 3, [1] = 2, [4] = 1 }

local GREEN = { r = 0.5, g = 0.82, b = 0.68 }
local GREY = { r = 0.6, g = 0.6, b = 0.6 }
local ORANGE = { r = 1, g = 0.5, b = 0.25 }
local GOLD = { r = 1, g = 0.82, b = 0 }

local summary -- { query, text } from the last Results

local function now()
  return debugprofilestop and debugprofilestop() or 0
end

-- Masks can exceed 32 bits, so test bits arithmetically.
local function hasBit(mask, bit)
  return bit ~= nil and bit > 0 and math.floor(mask / bit) % 2 == 1
end

local function friendlyTo(friendly, faction)
  if friendly == nil or friendly == "" then return true end
  return friendly:find(faction == "Alliance" and "A" or "H", 1, true) ~= nil
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

local function trim(text)
  return ((text or ""):match("^%s*(.-)%s*$"))
end

local function list(value)
  return type(value) == "table" and value or {}
end

---------------------------------------------------------------- QuestieDB reads

local function entityDB(kind)
  local lib = LibQuestieDB or {}
  if kind == "item" then return lib.Item or ItemDB end
  if kind == "npc" then return lib.Npc or NpcDB end
  if kind == "object" then return lib.Object or ObjectDB end
  return lib.Quest or QuestDB
end

-- One field, or nil when the entity or the field is unknown.
local function field(kind, id, key)
  local db = entityDB(kind)
  if not db then return nil end
  local ok, value = pcall(db.Get, id, key)
  if ok then return value end
  return nil
end

local dungeonByArea -- [AreaID] = dungeon from ns.Dungeons.Catalogue()

local function dungeonAreas()
  if not dungeonByArea then
    dungeonByArea = {}
    for _, entry in ipairs(ns.Dungeons.Catalogue()) do
      for areaID in pairs(entry.areaIDs) do dungeonByArea[areaID] = entry end
    end
  end
  return dungeonByArea
end

local entityCache = {}

-- A mob, object or vendor and where it is: route nodes per world map
-- (byMap, and all of them in nodes), and the dungeons it is inside (spawns
-- in a dungeon's AreaID). Spawns don't change, so this is kept for the session.
local function entity(kind, id)
  local key = kind .. id
  if entityCache[key] == nil then
    local name = field(kind, id, "name")
    local e = false
    if type(name) == "string" then
      e = { id = id, kind = kind, name = name, byMap = {}, nodes = {}, dungeons = {} }
      if kind == "npc" then
        e.rank = field(kind, id, "rank")
        e.minLevel, e.maxLevel = field(kind, id, "minLevel"), field(kind, id, "maxLevel")
        e.friendly = field(kind, id, "friendlyToFaction")
      end
      local inside = {}
      for areaID, points in pairs(list(field(kind, id, "spawns"))) do
        local dungeon = dungeonAreas()[areaID]
        if dungeon then
          if not inside[dungeon] then
            inside[dungeon] = true
            e.dungeons[#e.dungeons + 1] = dungeon
          end
        else
          for _, node in ipairs(ns.Questie.SpawnNodes({ [areaID] = points }, name)) do
            e.byMap[node.mapID] = e.byMap[node.mapID] or {}
            table.insert(e.byMap[node.mapID], node)
            e.nodes[#e.nodes + 1] = node
          end
        end
      end
    end
    entityCache[key] = e
  end
  return entityCache[key] or nil
end

local function bossFirst(a, b)
  local ra, rb = RANK_ORDER[a.rank or 0] or 0, RANK_ORDER[b.rank or 0] or 0
  if ra ~= rb then return ra > rb end
  return a.name < b.name
end

local sourceCache = {}

-- What QuestieDB knows about an item, grouped into rows:
--   dungeons = { {entry, members = {entity, ...}}, ... }
--   zones = { {kind = "npc"|"object", mapID, members = { {entity, nodes}, ... }}, ... }
--   quests, containers, vendors = ID lists.
local function staticSources(itemID)
  if sourceCache[itemID] then return sourceCache[itemID] end
  local s = {
    dungeons = {}, zones = {},
    quests = list(field("item", itemID, "questRewards")),
    containers = list(field("item", itemID, "itemDrops")),
    vendors = list(field("item", itemID, "vendors")),
  }
  local dungeonIndex, zoneIndex = {}, {}
  local function add(kind, ids)
    for _, id in ipairs(ids) do
      local e = entity(kind, id)
      if e then
        for _, dungeon in ipairs(e.dungeons) do
          local d = dungeonIndex[dungeon]
          if not d then
            d = { entry = dungeon, members = {} }
            dungeonIndex[dungeon] = d
            s.dungeons[#s.dungeons + 1] = d
          end
          table.insert(d.members, e)
        end
        for mapID, nodes in pairs(e.byMap) do
          local z = zoneIndex[kind .. mapID]
          if not z then
            z = { kind = kind, mapID = mapID, members = {} }
            zoneIndex[kind .. mapID] = z
            s.zones[#s.zones + 1] = z
          end
          table.insert(z.members, { entity = e, nodes = nodes })
        end
      end
    end
  end
  add("npc", list(field("item", itemID, "npcDrops")))
  add("object", list(field("item", itemID, "objectDrops")))
  for _, d in ipairs(s.dungeons) do table.sort(d.members, bossFirst) end
  sourceCache[itemID] = s
  return s
end

---------------------------------------------------------------- item info

-- Item ID from a link ("|Hitem:2589:..."), "item:2589" or a bare number.
function Items.ParseID(text)
  text = trim(text)
  local id = text:match("|Hitem:(%d+)") or text:match("^item:(%d+)") or text:match("^#?(%d+)$")
  return tonumber(id)
end

local pending = {} -- item IDs the client is still loading

local function clientInfo(id)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local ok, name, link, _, itemLevel, requiredLevel = pcall(getInfo, id)
  if ok and type(name) == "string" then
    return { name = name, link = link, itemLevel = itemLevel, requiredLevel = requiredLevel }
  end
  if C_Item and C_Item.RequestLoadItemDataByID then
    pending[id] = true
    pcall(C_Item.RequestLoadItemDataByID, id)
  end
  return nil
end

ns.On("GET_ITEM_INFO_RECEIVED", function(itemID)
  if pending[itemID] then
    pending[itemID] = nil
    ns.Panel.Refresh()
  end
end)

-- name, link, itemLevel, requiredLevel: the client's when it has the item,
-- else QuestieDB's. `known` is false when neither has a name.
function Items.Info(id)
  local info = clientInfo(id) or {}
  if ns.Questie.Available() then
    info.name = info.name or field("item", id, "name")
    info.itemLevel = info.itemLevel or field("item", id, "itemLevel")
    info.requiredLevel = info.requiredLevel or field("item", id, "requiredLevel")
  end
  info.id = id
  info.known = info.name ~= nil
  info.name = info.name or ("Item " .. id)
  return info
end

-- What goes in the search box to look an item up.
local function searchText(info)
  return info.link or ("item:" .. info.id)
end

local function levelText(info)
  local parts = {}
  if (info.itemLevel or 0) > 0 then parts[#parts + 1] = "item level " .. info.itemLevel end
  if (info.requiredLevel or 0) > 1 then parts[#parts + 1] = "requires level " .. info.requiredLevel end
  return table.concat(parts, "  ·  ")
end

-- [itemID] = { {id, npc}, ... }: vendors of your faction you visited, by what they sold.
local function visitedGoods()
  local faction = UnitFactionGroup("player")
  local goods = {}
  for id, npc in pairs(ns.Harvest.AllNPCs()) do
    local friendly = npc.faction == nil or npc.faction == faction or npc.faction == "Neutral"
    if npc.kinds and npc.kinds.vendor and friendly then
      for _, itemID in ipairs(npc.goods or {}) do
        goods[itemID] = goods[itemID] or {}
        table.insert(goods[itemID], { id = id, npc = npc })
      end
    end
  end
  return goods
end

---------------------------------------------------------------- name search

local nameIndex -- { {id, name, key = lower-case name}, ... } over ItemDB, built on the first search

local function buildNameIndex()
  nameIndex = {}
  local started = now()
  local items = entityDB("item")
  local ok, ids = pcall(items and items.GetAllIds or error)
  for _, id in ipairs(ok and list(ids) or {}) do
    local name = field("item", id, "name")
    if type(name) == "string" and name ~= "" then
      nameIndex[#nameIndex + 1] = { id = id, name = name, key = name:lower() }
    end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.questieItems = now() - started
end

-- Items whose name contains `text` (any case): the exact name first, then
-- names starting with it, then shorter names. Up to MAX_MATCHES, and the total.
-- Without QuestieDB only the goods of vendors you visited are searched.
local function searchNames(text)
  local candidates = {}
  if ns.Questie.Available() then
    if not nameIndex then buildNameIndex() end
    candidates = nameIndex
  else
    for itemID in pairs(visitedGoods()) do
      local info = clientInfo(itemID)
      if info then candidates[#candidates + 1] = { id = itemID, name = info.name, key = info.name:lower() } end
    end
  end
  local key, found = text:lower(), {}
  for _, e in ipairs(candidates) do
    local at = e.key:find(key, 1, true)
    if at then
      found[#found + 1] = { id = e.id, name = e.name, rank = e.key == key and 0 or (at == 1 and 1 or 2) }
    end
  end
  table.sort(found, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if #a.name ~= #b.name then return #a.name < #b.name end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  local total = #found
  for i = total, MAX_MATCHES + 1, -1 do found[i] = nil end
  return found, total
end

---------------------------------------------------------------- routes

-- The quickest route to any of `nodes`, trying the CANDIDATES nearest in a
-- straight line. Returns goal, route (goal without a route when none is found).
local function quickest(start, nodes, net)
  local sorted = {}
  for _, node in ipairs(nodes) do sorted[#sorted + 1] = { node = node, distance = ns.Geo.Distance(start, node) } end
  table.sort(sorted, function(a, b) return a.distance < b.distance end)
  local goal, route
  for i = 1, math.min(CANDIDATES, #sorted) do
    local r = ns.Router.Plan(start, sorted[i].node, net)
    if r and (not route or r.seconds < route.seconds) then goal, route = sorted[i].node, r end
  end
  return goal or (sorted[1] and sorted[1].node), route
end

local function routeTo(row, node, ctx)
  if not node then return end
  row.goal, row.zone = node, ns.MapName(node.mapID)
  row.route = ns.Router.Plan(ctx.start, node, ctx.net)
end

---------------------------------------------------------------- drops

-- The level of a dungeon (or of its wing) nearest yours, and whether the client listed it.
local function dungeonLevel(entry, level)
  local best
  for _, l in ipairs(entry.levels or {}) do
    if l.level and (not best or math.abs(l.level - level) < math.abs(best - level)) then best = l.level end
  end
  return best or entry.dataLevel, best ~= nil
end

-- Pick up the dungeon's quests on the way, then go in.
local function dungeonJourney(entry, quests, entrance)
  local here = ns.Geo.PlayerNode()
  if not (here and entrance) then return nil end
  local stops = {}
  for _, quest in ipairs(quests) do
    local giver, node = ns.Questie.QuestGiver(quest.id, here)
    if node then
      stops[#stops + 1] = { node = node,
        text = string.format("Pick up %s from %s", quest.name or ("quest " .. quest.id), giver or "the quest giver"),
        action = { kind = "pickup", questID = quest.id } }
    end
  end
  if #stops == 0 then return nil end
  return ns.Journey.Plan(here, { title = entry.name .. " with its quests", stops = stops,
    finish = { node = entrance, text = "Enter " .. entry.name } })
end

local function npcLevels(e)
  if not (e.minLevel and e.minLevel > 0) then return nil end
  if e.maxLevel and e.maxLevel > e.minLevel then return e.minLevel .. "-" .. e.maxLevel end
  return tostring(e.minLevel)
end

local function memberText(e)
  local levels = npcLevels(e)
  return levels and (e.name .. ", level " .. levels) or e.name
end

local function othersText(name, count)
  if count <= 1 then return name end
  return string.format("%s and %s", name, plural(count - 1, "other"))
end

local function dungeonRows(s, ctx, out)
  for _, d in ipairs(s.dungeons) do
    local entry = d.entry
    local goal, route = quickest(ctx.start, entry.entrances or {}, ctx.net)
    local level, fromClient = dungeonLevel(entry, ctx.level)
    local row = {
      title = string.format("Drops from %s in %s", othersText(d.members[1].name, #d.members), entry.name),
      goal = goal, route = route, details = {},
      tier = (level and level - ctx.level > DUNGEON_REACH) and LATER or NOW,
    }
    if goal then row.zone = ns.MapName(goal.mapID) else row.subtitle = "Entrance not known" end
    local function line(text, color) row.details[#row.details + 1] = { text = text, color = color } end

    if level then
      line(string.format("%s level %d%s; you are level %d.", entry.raid and "Raid" or "Dungeon", level,
        fromClient and "" or " (Wayfinder estimate)", ctx.level), row.tier == NOW and GREEN or ORANGE)
    end
    for _, e in ipairs(d.members) do line(memberText(e), GREY) end
    if goal and not entry.fromQuestie then line("Entrance position is approximate.", GREY) end

    local quests = {}
    for _, group in pairs(ns.Questie.QuestsForAreas(entry.areaIDs)) do
      for _, quest in ipairs(group.available) do quests[#quests + 1] = quest end
    end
    if #quests > 0 and goal then
      table.sort(quests, function(a, b) return a.id < b.id end)
      line(string.format("Dungeon quests you can take (the %s button picks them up on the way):",
        "+" .. plural(#quests, "quest")), GOLD)
      for _, quest in ipairs(quests) do line(string.format("[%d] %s", quest.level, quest.name or quest.id)) end
      row.actions = { { label = "+" .. plural(#quests, "quest"), run = function()
        local journey = dungeonJourney(entry, quests, goal)
        if journey then
          ns.Nav.StartJourney(journey)
          if ns.Panel.IsShown() then ns.Panel.Toggle() end
        end
      end } }
    end
    out[#out + 1] = row
  end
end

-- Mobs and objects in the open world: one row per zone, nearest zones first.
local function zoneRows(s, ctx, out)
  local byKind = { npc = {}, object = {} }
  for _, z in ipairs(s.zones) do
    local nearest, nearestDistance, nodes = nil, math.huge, {}
    for _, m in ipairs(z.members) do
      local _, distance = ns.Questie.Nearest(m.nodes, ctx.start)
      if not nearest or distance < nearestDistance then nearest, nearestDistance = m.entity, distance end
      for _, node in ipairs(m.nodes) do nodes[#nodes + 1] = node end
    end
    table.insert(byKind[z.kind], { zone = z, nearest = nearest, distance = nearestDistance, nodes = nodes })
  end

  for _, kind in ipairs({ "npc", "object" }) do
    local groups = byKind[kind]
    table.sort(groups, function(a, b)
      if a.distance ~= b.distance then return a.distance < b.distance end
      return a.zone.mapID < b.zone.mapID
    end)
    local last
    for i = 1, math.min(ZONE_ROWS, #groups) do
      local g = groups[i]
      local goal, route = quickest(ctx.start, g.nodes, ctx.net)
      local name = othersText(g.nearest.name, #g.zone.members)
      local row = {
        title = kind == "npc" and ("Drops from " .. name) or ("Found in " .. name),
        zone = ns.MapName(g.zone.mapID), goal = goal, route = route, details = {}, tier = NOW,
      }
      local lowest
      for _, m in ipairs(g.zone.members) do
        row.details[#row.details + 1] = { text = memberText(m.entity), color = GREY }
        local minLevel = m.entity.minLevel
        if minLevel and minLevel > 0 and (not lowest or minLevel < lowest) then lowest = minLevel end
      end
      if lowest and lowest - ctx.level > MOB_REACH then
        row.tier = LATER
        table.insert(row.details, 1, { text = string.format("Level %d and up; you are level %d.", lowest, ctx.level),
          color = ORANGE })
      end
      out[#out + 1] = row
      last = row
    end
    if last and #groups > ZONE_ROWS then
      last.details[#last.details + 1] = { text = string.format("Also in %s farther away.",
        plural(#groups - ZONE_ROWS, "more zone")), color = GREY }
    end
  end
end

-- Containers ("comes in a clam"): look the container up instead.
local function containerRows(s, out)
  for _, containerID in ipairs(s.containers) do
    local info = Items.Info(containerID)
    out[#out + 1] = {
      title = "Comes in " .. info.name,
      subtitle = "Open one to get it. Look up shows where it comes from.",
      tier = INFO,
      actions = { { label = "Look up", run = function() ns.Panel.Search("items", searchText(Items.Info(containerID))) end } },
    }
  end
end

---------------------------------------------------------------- quests

local function anyDone(ids, done)
  for _, id in ipairs(ids or {}) do
    if done[id] then return true end
  end
  return false
end

local function allDone(ids, done)
  for _, id in ipairs(ids or {}) do
    if not done[id] then return false end
  end
  return true
end

-- Grey quests, with the thresholds QuestieBridge.lua uses. Quest hubs hide
-- them, but for a reward they are still worth it.
local function isGrey(questLevel, level)
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

-- Level <= 0 means "scales with you" in Questie data.
local function questLevel(q, level)
  local l = (q.questLevel or 0) ~= 0 and q.questLevel or q.requiredLevel or 0
  return l > 0 and l or level
end

local function profile(level)
  local enum = (LibQuestieDB and LibQuestieDB.Enum) or {}
  local _, class = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  return { level = level, raceMask = enum.raceMaskById and enum.raceMaskById[raceID],
    classMask = enum.classKeys and enum.classKeys[class] }
end

-- Where you stand with a reward quest: "available", "low" (grey, you can
-- still take it), "inLog", "done", "level" (you are too low), "hard" (red),
-- "chain" (needs earlier quests), or nil (never for you, or not any more).
local function questStatus(q, p, done, inLog)
  if done[q.id] then return "done" end
  if inLog[q.id] then return "inLog" end
  if (q.requiredRaces or 0) ~= 0 and not hasBit(q.requiredRaces, p.raceMask) then return nil end
  if (q.requiredClasses or 0) ~= 0 and not hasBit(q.requiredClasses, p.classMask) then return nil end
  if anyDone(q.exclusiveTo, done) then return nil end
  if (q.requiredMaxLevel or 0) ~= 0 and p.level > q.requiredMaxLevel then return nil end
  if (q.availableUntilCompleted or 0) ~= 0 and done[q.availableUntilCompleted] then return nil end
  local following = q.nextQuestInChain or 0
  if following ~= 0 and (done[following] or inLog[following]) then return nil end
  if ns.Questie.IsQuestAvailable(q.id, done, inLog) then return "available" end
  if (q.requiredLevel or 0) > p.level then return "level" end
  if (q.preQuestSingle and #q.preQuestSingle > 0 and not anyDone(q.preQuestSingle, done))
    or (q.preQuestGroup and not allDone(q.preQuestGroup, done)) then
    return "chain"
  end
  local l = questLevel(q, p.level)
  if l - p.level >= RED_LEVELS then return "hard" end
  if isGrey(l, p.level) then return "low" end
  -- What is left in the hub rules is mostly chains: a predecessor recorded
  -- only on the earlier quest, a breadcrumb or a parent quest.
  return "chain"
end

-- Nearest NPC or object that takes a quest in: name, node.
local function questFinisher(questID, ctx)
  local finishers = list(field("quest", questID, "finishedBy"))
  local bestName, bestNode, bestDistance
  for i, kind in ipairs({ "npc", "object" }) do
    for _, id in ipairs(list(finishers[i])) do
      local e = entity(kind, id)
      if e and (kind ~= "npc" or friendlyTo(e.friendly, ctx.faction)) then
        local node, distance = ns.Questie.Nearest(e.nodes, ctx.start)
        if node and (not bestDistance or distance < bestDistance) then
          bestName, bestNode, bestDistance = e.name, node, distance
        end
      end
    end
  end
  return bestName, bestNode
end

local function questRow(q, status, ctx)
  local name = q.name or ("Quest " .. q.id)
  local level = questLevel(q, ctx.level)
  local row = { title = "Reward from " .. name, details = {}, tier = NOW }
  local function line(text, color) row.details[#row.details + 1] = { text = text, color = color } end
  line(string.format("[%d] %s", level, name), GetQuestDifficultyColor and GetQuestDifficultyColor(level))

  if status == "done" then
    row.title, row.subtitle, row.tier = row.title .. "  ·  done", "You have done this quest already.", INFO
    return row
  end
  if status == "inLog" then
    local who, node = questFinisher(q.id, ctx)
    row.title = row.title .. "  ·  in your log"
    line(who and ("In your quest log. Directions go to where you hand it in: " .. who .. ".")
      or "In your quest log.", GREEN)
    routeTo(row, node, ctx)
    row.subtitle = not node and "In your quest log" or nil
    return row
  end

  local who, node = ns.Questie.QuestGiver(q.id, ctx.start)
  who = who or "the quest giver"
  if status == "available" then
    line("You can take it now from " .. who .. ".", GREEN)
  elseif status == "low" then
    line("Low level, but you can still take it from " .. who .. ".", GREEN)
  elseif status == "level" then
    row.title, row.tier = row.title .. "  ·  from level " .. q.requiredLevel, LATER
    line(string.format("You can take it at level %d from %s.", q.requiredLevel, who), ORANGE)
  elseif status == "hard" then
    row.title, row.tier = row.title .. "  ·  level " .. level, LATER
    line(string.format("Quest level %d: too hard for now. It starts at %s.", level, who), ORANGE)
  else
    -- TODO(quest chains): route to the first quest of the chain you still
    -- need once the Quests page's chain helper is on ns.Questie; until then
    -- directions go to this quest's own giver.
    row.title, row.tier = row.title .. "  ·  needs earlier quests", LATER
    line("Needs earlier quests first. Directions go to this quest's giver, " .. who .. ".", ORANGE)
  end
  routeTo(row, node, ctx)
  if not node then row.subtitle = "Quest giver location not known" end
  return row
end

local function questRows(s, ctx, out)
  if #s.quests == 0 then return end
  local done, inLog = ns.Questie.PlayerQuestState()
  local p = profile(ctx.level)
  for _, questID in ipairs(s.quests) do
    local q = ns.Questie.Quest(questID)
    local status = q and questStatus(q, p, done, inLog)
    if status then out[#out + 1] = questRow(q, status, ctx) end
  end
end

---------------------------------------------------------------- vendors

-- The nearest vendor that sells it: QuestieDB sellers and vendors you visited.
local function vendorRow(itemID, s, ctx, out)
  local sellers = {}
  for _, id in ipairs(s and s.vendors or {}) do
    local e = entity("npc", id)
    local node = e and friendlyTo(e.friendly, ctx.faction) and ns.Questie.Nearest(e.nodes, ctx.start)
    if node then sellers[id] = { name = e.name, node = node } end
  end
  -- Visited vendors: positions and goods measured in Forever win over QuestieDB.
  for _, v in ipairs(ctx.goods[itemID] or {}) do
    local node = ns.Geo.Node(v.npc.mapID, v.npc.x, v.npc.y, v.npc.name)
    if node then sellers[v.id] = { name = v.npc.name, node = node, visited = true } end
  end

  local nodes, byNode = {}, {}
  for _, seller in pairs(sellers) do
    nodes[#nodes + 1] = seller.node
    byNode[seller.node] = seller
  end
  if #nodes == 0 then return end
  local goal, route = quickest(ctx.start, nodes, ctx.net)
  local seller = byNode[goal]
  local row = { title = "Sold by " .. seller.name, zone = ns.MapName(goal.mapID), goal = goal, route = route,
    tier = NOW, details = {} }
  row.details[1] = seller.visited and { text = "Sold here when you last visited.", color = GREEN }
    or { text = "Sells it (QuestieDB).", color = GREEN }
  if #nodes > 1 then
    row.details[2] = { text = string.format("%s %s it too.", plural(#nodes - 1, "other vendor"),
      #nodes == 2 and "sells" or "sell"), color = GREY }
  end
  out[#out + 1] = row
end

---------------------------------------------------------------- page

local function score(r)
  return r.tier * TIER_SECONDS + (r.route and r.route.seconds or TIER_SECONDS - 1)
end

local function sourcesFor(id, query, alsoMatching)
  local info = Items.Info(id)
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local available = ns.Questie.Available()
  local ctx = { start = start, net = ns.Network.Build(), level = UnitLevel("player"),
    faction = UnitFactionGroup("player"), goods = visitedGoods() }

  local out = {}
  local s = available and staticSources(id) or nil
  if s then
    dungeonRows(s, ctx, out)
    zoneRows(s, ctx, out)
    questRows(s, ctx, out)
    containerRows(s, out)
  end
  vendorRow(id, s, ctx, out)
  table.sort(out, function(a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then return sa < sb end
    return a.title < b.title
  end)

  local parts = { info.link or info.name }
  local levels = levelText(info)
  if levels ~= "" then parts[#parts + 1] = levels end
  local text = table.concat(parts, "  ·  ")
  if alsoMatching and alsoMatching > 0 then
    text = text .. string.format(" (%s match too; type more of the name)", plural(alsoMatching, "other item"))
  end
  if not available then
    text = text .. ". Install QuestieDB to see where items drop and which quests reward them."
  end
  summary = { query = query, text = text }
  return out, nil, ctx.net
end

local function matchRows(matches, total, query)
  local out = {}
  for _, m in ipairs(matches) do
    local info = Items.Info(m.id)
    local levels = levelText(info)
    out[#out + 1] = {
      title = m.name,
      subtitle = levels ~= "" and levels or ("item " .. m.id),
      actions = { { label = "Show", run = function() ns.Panel.Search("items", searchText(Items.Info(m.id))) end } },
    }
  end
  local text = total > #matches
    and string.format("%d items match; the first %d are shown. Type more of the name, or pick one.", total, #matches)
    or string.format("%s match. Pick one to see where it comes from.", plural(total, "item"))
  summary = { query = query, text = text }
  return out
end

function Items.Results(query)
  local q = trim(query)
  summary = nil
  if q == "" then return {} end
  local id, alsoMatching = Items.ParseID(q), 0
  if not id then
    if #q < MIN_QUERY then return {} end
    local matches, total = searchNames(q)
    if total == 0 then return {} end
    local exact = matches[1].rank == 0 and not (matches[2] and matches[2].rank == 0)
    if total > 1 and not exact then return matchRows(matches, total, query) end
    id, alsoMatching = matches[1].id, total - 1
  end
  return sourcesFor(id, query, alsoMatching)
end

function Items.SummaryText(query)
  if summary and summary.query == query then return summary.text end
  if trim(query) == "" then
    return "Shift-click an item into the box (or type its name) to see where it comes from, with directions. "
      .. "In chat: /wf item <link>."
  end
  return ""
end

function Items.EmptyText(query)
  local q = trim(query)
  local available = ns.Questie.Available()
  if q == "" then return "Try a dungeon drop or a quest reward linked in chat." end
  if Items.ParseID(q) then
    if available then return "QuestieDB knows no source of this item that is open to you." end
    return "Without QuestieDB, Wayfinder only knows vendors you visited, and none of them sold this item. "
      .. "Install QuestieDB to see where items drop and which quests reward them."
  end
  if #q < MIN_QUERY then return string.format("Type at least %d letters of the item's name.", MIN_QUERY) end
  if available then return string.format('No item called "%s".', q) end
  return string.format('No item called "%s" among the goods of vendors you visited. Shift-click the item '
    .. "instead, or install QuestieDB to search every item.", q)
end

ns.RegisterPage({
  id = "items", label = "Items", order = 40, searchable = true,
  placeholder = "Shift-click an item, or type its name",
  SummaryText = function(q) return Items.SummaryText(q) end,
  EmptyText = function(q) return Items.EmptyText(q) end,
  Results = function(q) return Items.Results(q) end,
})

ns.RegisterCommand("item", "/wf item <item link or name> - where an item comes from, with directions",
  function(rest) ns.Panel.Search("items", rest) end)

---------------------------------------------------------------- tooltip

-- True when Wayfinder knows where an item comes from.
function Items.HasSources(itemID)
  if ns.Questie.Available() then
    for _, key in ipairs({ "npcDrops", "objectDrops", "itemDrops", "questRewards", "vendors" }) do
      if next(list(field("item", itemID, key))) then return true end
    end
  end
  return visitedGoods()[itemID] ~= nil
end

-- The line for an item's tooltip, or nil. Never in combat.
function Items.TooltipLine(itemID)
  if InCombatLockdown and InCombatLockdown() then return nil end
  if type(issecretvalue) == "function" and issecretvalue(itemID) then return nil end
  if type(itemID) ~= "number" or not Items.HasSources(itemID) then return nil end
  return "Wayfinder: /wf item for directions"
end

if type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
  and type(Enum) == "table" and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    local ok, line = pcall(Items.TooltipLine, data and data.id)
    if ok and line then pcall(tooltip.AddLine, tooltip, line, GREEN.r, GREEN.g, GREEN.b) end
  end)
end
