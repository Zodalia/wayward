local _, ns = ...

-- "Items" page: shift-click an item into the search box (or `/ww item
-- <link>`), or type its name, and see where it comes from, each source with
-- directions: dungeon drops (to the entrance), mobs and objects in the world
-- (nearest spawn, one row per zone), quests that reward it and the nearest
-- vendor that sells it. Things you can do now come first, then the nearest.
--
-- Sources come from the data sources' item records (npcDrops, objectDrops,
-- itemDrops, questRewards, vendors; see Sources.lua). Without one, only
-- vendors you visited that sold the item are known (Vendors.lua records
-- merchant goods). Name matching is Search.lua's; the quest rules are
-- Quests.lua's (Quests.RewardStatus, QuestGiver, QuestFinisher) and dungeon
-- runs QuestsPage's, the same as on the Quests page.

local Items = {}
ns.Items = Items

local MAX_MATCHES = 20  -- name search results shown
local MIN_QUERY = 3     -- letters before a name search runs
local CANDIDATES = 4    -- nearest places (straight line) per row that get a full route
local ZONE_ROWS = 3     -- world-drop rows per kind (mobs, objects)
local DUNGEON_REACH = 3 -- a dungeon up to this many levels above you counts as "now"
local MOB_REACH = 4     -- mobs up to this many levels above you count as "now"

-- Ranking tiers: every row of a tier comes before the next tier, then by travel time.
local NOW, LATER, INFO = 0, 1, 2
local TIER_SECONDS = 1e7

-- Which dropper names a dungeon row: bosses, then rare elites, elites, rares.
local RANK_ORDER = { [3] = 4, [2] = 3, [1] = 2, [4] = 1 }

local GREEN = { r = 0.5, g = 0.82, b = 0.68 }
local GREY = { r = 0.6, g = 0.6, b = 0.6 }
local ORANGE = { r = 1, g = 0.5, b = 0.25 }
local GOLD = { r = 1, g = 0.82, b = 0 }

local summary -- { query, text } from the last Results

local friendlyTo = ns.Data.FriendlyTo

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

local function trim(text)
  return ((text or ""):match("^%s*(.-)%s*$"))
end

local function list(value)
  return type(value) == "table" and value or {}
end

---------------------------------------------------------------- data reads

local function record(kind, id)
  if kind == "item" then return ns.Data.Item(id) end
  if kind == "npc" then return ns.Data.Npc(id) end
  if kind == "object" then return ns.Data.Object(id) end
  return ns.Data.Quest(id)
end

-- One field, or nil when the entity or the field is unknown.
local function field(kind, id, key)
  local r = record(kind, id)
  return r and r[key]
end

-- A mob, object or vendor and where it is: route nodes per world map
-- (byMap, and all of them in nodes; Data.Nodes keeps them per record), and
-- the dungeons it is inside (spawns in a dungeon's AreaID, Dungeons.ForArea).
local function entity(kind, id)
  local name = field(kind, id, "name")
  if type(name) ~= "string" then return nil end
  local e = { id = id, kind = kind, name = name, byMap = {}, nodes = {}, dungeons = {} }
  if kind == "npc" then
    e.rank = field(kind, id, "rank")
    e.minLevel, e.maxLevel = field(kind, id, "minLevel"), field(kind, id, "maxLevel")
    e.friendly = field(kind, id, "faction")
  end
  local positions = list(field(kind, id, "positions"))
  local inside = {}
  for _, p in ipairs(positions) do
    local dungeon = p.areaID and ns.Dungeons.ForArea(p.areaID)
    if dungeon and not inside[dungeon] then
      inside[dungeon] = true
      e.dungeons[#e.dungeons + 1] = dungeon
    end
  end
  -- Spawns inside a dungeon have no world map, so Data.Nodes leaves them out.
  for _, node in ipairs(ns.Data.Nodes(positions, name)) do
    e.byMap[node.mapID] = e.byMap[node.mapID] or {}
    table.insert(e.byMap[node.mapID], node)
    e.nodes[#e.nodes + 1] = node
  end
  return e
end

local function bossFirst(a, b)
  local ra, rb = RANK_ORDER[a.rank or 0] or 0, RANK_ORDER[b.rank or 0] or 0
  if ra ~= rb then return ra > rb end
  return a.name < b.name
end

local sourceCache = {}
ns.Listen("SOURCES_CHANGED", function() sourceCache = {} end)

-- What the data knows about an item, grouped into rows:
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

-- Item ID from a link ("|Hitem:2589:..."), "item:2589" or a bare number
-- (Search.Parse; a quest or spell link is not an item).
function Items.ParseID(text)
  local kind, id = ns.Search.Parse(text)
  if kind and kind ~= "item" then return nil end
  return id
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
    ns.Panel.RefreshSoon()
  end
end)

-- name, link, itemLevel, requiredLevel: the client's when it has the item,
-- else the data's. `known` is false when neither has a name.
function Items.Info(id)
  local info = clientInfo(id) or {}
  if ns.Data.Has("Item") then
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
function Items.SearchText(id)
  local info = Items.Info(id)
  return info.link or ("item:" .. info.id)
end

local function levelText(info)
  local parts = {}
  if (info.itemLevel or 0) > 0 then parts[#parts + 1] = "item level " .. info.itemLevel end
  if (info.requiredLevel or 0) > 1 then parts[#parts + 1] = "requires level " .. info.requiredLevel end
  return table.concat(parts, "  ·  ")
end

-- Opens an item's sources: on the Items tab when that's where you are, else
-- on Find's Items view.
local function open(id)
  local text = Items.SearchText(id)
  if ns.Find and ns.Panel.SelectedTab() ~= "items" then return ns.Find.Open("items", text) end
  ns.Panel.Search("items", text)
end

-- [itemID] = { {id, npc}, ... }: vendors of your faction you visited, by what they sold.
local goodsCache -- until a vendor is recorded (item tooltips ask on every hover)
local function visitedGoods()
  if goodsCache then return goodsCache end
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
  goodsCache = goods
  return goods
end
ns.Listen("DATA_CHANGED", function() goodsCache = nil end)
ns.Listen("SOURCES_CHANGED", function() goodsCache = nil end)

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

-- A journey through a whole quest: pick it up, do the objectives, hand it in
-- (only the parts still open). True when there is one.
local function trackQuest(row, questID, title, ctx)
  if not questID then return false end
  local stops = ns.Journey.QuestStops(questID, ctx.start)
  local journey = #stops > 0 and ns.Journey.Plan(ctx.start, { title = title, stops = stops }, ctx.net)
  if not journey then return false end
  row.journey, row.zone = journey, ns.MapName(journey.stops[1].node.mapID)
  return true
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
        fromClient and "" or " (Wayward estimate)", ctx.level), row.tier == NOW and GREEN or ORANGE)
    end
    for _, e in ipairs(d.members) do line(memberText(e), GREY) end
    if goal and not entry.fromSource then line("Entrance position is approximate.", GREY) end

    local quests = {}
    for _, group in pairs(ns.Quests.QuestsForAreas(entry.areaIDs)) do
      for _, quest in ipairs(group.available) do quests[#quests + 1] = quest end
    end
    if #quests > 0 and goal then
      table.sort(quests, function(a, b) return a.id < b.id end)
      line(string.format("Dungeon quests you can take (the %s button picks them up on the way):",
        "+" .. plural(#quests, "quest")), GOLD)
      for _, quest in ipairs(quests) do line(string.format("[%d] %s", quest.level, quest.name or quest.id)) end
      -- Pick up the dungeon's quests on the way, then go in (the Quests page's journey).
      row.actions = { { label = "+" .. plural(#quests, "quest"), run = function()
        local here = ns.Geo.PlayerNode()
        local journey = here and ns.QuestsPage.DungeonJourney(entry.name, goal, quests, here)
        if journey then
          ns.Nav.StartJourney(journey)
          if ns.Panel.IsShown() then ns.Panel.Toggle() end
        else
          ns.print("no quest giver for " .. entry.name .. " can be reached from here.")
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
      local _, distance = ns.Data.Nearest(m.nodes, ctx.start)
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
      actions = { { label = "Look up", run = function() open(containerID) end } },
    }
  end
end

---------------------------------------------------------------- quests

local function questRow(q, status, ctx)
  local name = q.name or ("Quest " .. q.id)
  local level = ns.Quests.QuestLevel(q.id) or ctx.level
  local row = { title = "Reward from " .. name, details = {}, tier = NOW, kind = "quest", questID = q.id }
  local function line(text, color) row.details[#row.details + 1] = { text = text, color = color } end
  line(string.format("[%d] %s", level, name), GetQuestDifficultyColor and GetQuestDifficultyColor(level))

  if status == "done" then
    row.title, row.subtitle, row.tier = row.title .. "  ·  done", "You have done this quest already.", INFO
    return row
  end
  if status == "inLog" then
    local who, node = ns.Quests.QuestFinisher(q.id, ctx.start)
    row.title = row.title .. "  ·  in your log"
    line(who and ("In your quest log. Directions go to where you hand it in: " .. who .. ".")
      or "In your quest log.", GREEN)
    if not trackQuest(row, q.id, name, ctx) then routeTo(row, node, ctx) end
    row.subtitle = not node and "In your quest log" or nil
    return row
  end

  local who, node = ns.Quests.QuestGiver(q.id, ctx.start)
  who = who or "the quest giver"
  -- The quest to track from start to hand-in (nil: just directions to the giver).
  local track = (status == "available" or status == "low") and q.id or nil
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
    -- Directions go to the first quest of the chain you can act on now.
    row.title, row.tier = row.title .. "  ·  needs earlier quests", LATER
    local stepID, stepState = ns.Quests.ChainStart(q.id)
    local step = stepID and ns.Quests.Quest(stepID)
    local stepName = step and step.name or (stepID and ("Quest " .. stepID))
    track = stepID
    if stepState == "inLog" then
      local finisher
      finisher, node = ns.Quests.QuestFinisher(stepID, ctx.start)
      line(string.format("Needs earlier quests first. Finish %s: hand it in to %s.", stepName,
        finisher or "its quest giver"), ORANGE)
    elseif stepID then
      local giver
      giver, node = ns.Quests.QuestGiver(stepID, ctx.start)
      line(string.format("Needs earlier quests first. Start the chain: pick up %s from %s.", stepName,
        giver or "its quest giver"), ORANGE)
    else
      node = nil
      row.subtitle = "Needs earlier quests you can't take yet"
      line("Needs earlier quests that you can't take yet.", ORANGE)
    end
  end
  if not trackQuest(row, track, name, ctx) then routeTo(row, node, ctx) end
  if not node then row.subtitle = row.subtitle or "Quest giver location not known" end
  return row
end

local function questRows(s, ctx, out)
  if #s.quests == 0 then return end
  local done, inLog = ns.Quests.PlayerQuestState()
  for _, questID in ipairs(s.quests) do
    local q = ns.Quests.Quest(questID)
    local status = q and ns.Quests.RewardStatus(questID, done, inLog)
    if status then out[#out + 1] = questRow(q, status, ctx) end
  end
end

---------------------------------------------------------------- vendors

-- The nearest vendor that sells it: sellers in the data and vendors you visited.
local function vendorRow(itemID, s, ctx, out)
  local sellers = {}
  for _, id in ipairs(s and s.vendors or {}) do
    local e = entity("npc", id)
    local node = e and friendlyTo(e.friendly, ctx.faction) and ns.Data.Nearest(e.nodes, ctx.start)
    if node then sellers[id] = { name = e.name, node = node } end
  end
  -- Visited vendors: positions and goods measured in Forever win over the data.
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
  goal.npc = seller.name
  local row = { title = "Sold by " .. seller.name, zone = ns.MapName(goal.mapID), goal = goal, route = route,
    tier = NOW, details = {} }
  row.details[1] = seller.visited and { text = "Sold here when you last visited.", color = GREEN }
    or { text = "Sells it (data).", color = GREEN }
  if #nodes > 1 then
    row.details[2] = { text = string.format("%s %s it too.", plural(#nodes - 1, "other vendor"),
      #nodes == 2 and "sells" or "sell"), color = GREY }
  end
  out[#out + 1] = row
end

---------------------------------------------------------------- page

local function score(r)
  local seconds = (r.route and r.route.seconds) or (r.journey and r.journey.seconds)
  return r.tier * TIER_SECONDS + (seconds or TIER_SECONDS - 1)
end

-- Every source of one item as rows, best first. `alsoMatching`: other items
-- the typed name matched (named in the summary).
function Items.SourcesFor(id, query, alsoMatching)
  local info = Items.Info(id)
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local available = ns.Data.Has("Item")
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
  for i, row in ipairs(out) do
    row.id = row.id or ("item" .. id .. "/" .. i)
    row.itemID = id
    ns.Search.WithDetour(row)
  end

  local parts = { info.link or info.name }
  local levels = levelText(info)
  if levels ~= "" then parts[#parts + 1] = levels end
  local text = table.concat(parts, "  ·  ")
  if alsoMatching and alsoMatching > 0 then
    text = text .. string.format(" (%s match too; type more of the name)", plural(alsoMatching, "other item"))
  end
  if not available then
    text = text .. ". Install " .. ns.Data.ADDON .. " to see where items drop and which quests reward them."
  end
  summary = { query = query, text = text }
  return out, nil, ctx.net
end

-- A row for an item a name search matched: pick it to see its sources.
function Items.MatchRow(id, name)
  local info = Items.Info(id)
  local levels = levelText(info)
  return {
    id = "pick" .. id, kind = "item", itemID = id,
    title = name or info.name,
    subtitle = levels ~= "" and levels or ("item " .. id),
    actions = { { label = "Show", run = function() open(id) end } },
  }
end

local function matchRows(matches, total, query)
  local out = {}
  for _, m in ipairs(matches) do out[#out + 1] = Items.MatchRow(m.id, m.name) end
  local text = total > #matches
    and string.format("%d items match; the first %d are shown. Type more of the name, or pick one.", total, #matches)
    or string.format("%s match. Pick one to see where it comes from.", plural(total, "item"))
  summary = { query = query, text = text }
  return out
end

-- Items whose name matches `text` (Search.lua: the exact name first, then
-- names starting with it, then shorter names): up to MAX_MATCHES, and the
-- total. Without item data only the goods of vendors you visited are searched.
local function searchNames(text)
  local found = ns.Search.Find(text, "item")
  local total = #found
  for i = total, MAX_MATCHES + 1, -1 do found[i] = nil end
  return found, total
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
    local exact = matches[1].score >= 400 and not (matches[2] and matches[2].score >= 400)
    if total > 1 and not exact then return matchRows(matches, total, query) end
    id, alsoMatching = matches[1].id, total - 1
  end
  return Items.SourcesFor(id, query, alsoMatching)
end

function Items.SummaryText(query)
  if summary and summary.query == query then return summary.text end
  if trim(query) == "" then
    return "Shift-click an item into the box (or type its name) to see where it comes from, with directions. "
      .. "In chat: /ww item <link>."
  end
  return ""
end

function Items.EmptyText(query)
  local q = trim(query)
  local available = ns.Data.Has("Item")
  if q == "" then return "Try a dungeon drop or a quest reward linked in chat." end
  if Items.ParseID(q) then
    if available then return "The data knows no source of this item that is open to you." end
    return "Without item data, Wayward only knows vendors you visited, and none of them sold this item. "
      .. "Install " .. ns.Data.ADDON .. " to see where items drop and which quests reward them."
  end
  if #q < MIN_QUERY then return string.format("Type at least %d letters of the item's name.", MIN_QUERY) end
  if available then return string.format('No item called "%s".', q) end
  return string.format('No item called "%s" among the goods of vendors you visited. Shift-click the item '
    .. "instead, or install " .. ns.Data.ADDON .. " to search every item.", q)
end

ns.RegisterPage({
  id = "items", label = "Items", order = 60, searchable = true,
  placeholder = "Shift-click an item, or type its name",
  SummaryText = function(q) return Items.SummaryText(q) end,
  EmptyText = function(q) return Items.EmptyText(q) end,
  Results = function(q) return Items.Results(q) end,
})

-- /ww item opens Find on its Items view (Find.lua), which shows these rows.
ns.RegisterCommand("item", "/ww item <item link or name> - where an item comes from, with directions",
  function(rest)
    if ns.Find then ns.Find.Open("items", rest) else ns.Panel.Search("items", rest) end
  end)

---------------------------------------------------------------- tooltip

-- True when Wayward knows where an item comes from.
function Items.HasSources(itemID)
  if visitedGoods()[itemID] ~= nil then return true end
  if ns.Data.Has("Item") then
    for _, key in ipairs({ "npcDrops", "objectDrops", "itemDrops", "questRewards", "vendors" }) do
      if next(list(field("item", itemID, key))) then return true end
    end
  end
  return false
end

-- The line for an item's tooltip, or nil. Never in combat.
function Items.TooltipLine(itemID)
  if InCombatLockdown and InCombatLockdown() then return nil end
  if type(issecretvalue) == "function" and issecretvalue(itemID) then return nil end
  if type(itemID) ~= "number" or not Items.HasSources(itemID) then return nil end
  return "Wayward: /ww find for directions"
end

if type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
  and type(Enum) == "table" and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    local ok, line = pcall(Items.TooltipLine, data and data.id)
    if ok and line then pcall(tooltip.AddLine, tooltip, line, GREEN.r, GREEN.g, GREEN.b) end
  end)
end
