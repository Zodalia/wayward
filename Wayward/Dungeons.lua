local _, ns = ...

-- "Dungeons" category: dungeons that fit your level, ranked by level fit and
-- travel time to the entrance.
--
-- Levels come from the client's dungeon finder list (GetLFGDungeonInfo, one
-- level per dungeon or wing). It has no area IDs, so it is matched to our
-- dungeons by name; a dungeon only it lists (Forever's new ones) is kept too.
-- Entrances: where you walked in yourself (recorded when you enter an
-- instance), else the data sources', else Data/Dungeons.lua. A dungeon with
-- none of those is listed without directions. Dungeon quests need quest data.

local Dungeons = { id = "dungeons", label = "Dungeons" }
ns.Dungeons = Dungeons

local MAX_LEVEL = 60          -- Forever's level cap; higher entries are later expansions
local LFG_SCAN = 10000        -- dungeon finder IDs to read (vanilla 1..131, Forever's new ones from 3271)
local TYPE_WORLD, TYPE_BATTLEGROUND = 4, 5
local UNDER, OVER = 3, 6      -- a dungeon fits from 3 levels under its level to 6 over
local SECONDS_PER_LEVEL = 150 -- ranking: each level away from a dungeon's level weighs like 2.5 min of travel
local NO_ENTRANCE = 1e6       -- ranking: a dungeon without a known entrance comes after those with one
local SAME_ENTRANCE = 60      -- yards: a recorded entrance this close to a known one is the same
local ENTRY_WINDOW = 120      -- seconds: an instance entered this soon after leaving a place was entered there

local clientList, summary

-- "The Deadmines" and "Deadmines" match, as do "Lower Blackrock Spire" aliases.
local function normalize(name)
  return ((name or ""):lower():gsub("^the ", ""):gsub("[^%w]", ""))
end

-- Dungeon finder entries up to the level cap. They don't change in a session.
local function clientDungeons()
  if clientList then return clientList end
  clientList = {}
  if type(GetLFGDungeonInfo) ~= "function" then return clientList end
  local started = debugprofilestop and debugprofilestop() or 0
  for id = 1, LFG_SCAN do
    local ok, name, typeID, _, minLevel, _, recLevel, _, _, _, _, _, _, maxPlayers = pcall(GetLFGDungeonInfo, id)
    local level = ok and (type(recLevel) == "number" and recLevel > 0 and recLevel or minLevel)
    if type(name) == "string" and type(level) == "number" and level > 0 and level <= MAX_LEVEL
      and typeID ~= TYPE_WORLD and typeID ~= TYPE_BATTLEGROUND then
      clientList[#clientList + 1] = { name = name, key = normalize(name), level = level,
        raid = type(maxPlayers) == "number" and maxPlayers > 5 }
    end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.dungeonFinder = (debugprofilestop and debugprofilestop() or 0) - started
  return clientList
end

local function fallbackNodes(d)
  local nodes = {}
  for _, e in ipairs(d.entrances or {}) do
    local x, y = ns.Data.EraToForever(e.mapID, e.x, e.y)
    local node = ns.Geo.Node(e.mapID, x, y, e.label or (d.name .. " entrance"))
    if node then nodes[#nodes + 1] = node end
  end
  return nodes
end

---------------------------------------------------------------- learned entrances

-- Where you were when the loading screen started (PLAYER_LEAVING_WORLD); when
-- the next world you arrive in is a dungeon or raid instance, that spot is its
-- entrance. Dungeon finder teleports aren't counted (you didn't walk in).
-- WaywardDB.dungeonEntrances[key] = { name, instanceID, points = { {mapID, x, y, seen}, ... } }
local leftFrom -- { mapID, x, y, at }

local function playerSpot()
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return nil end
  local x, y = pos:GetXY()
  return { mapID = mapID, x = x, y = y }
end

ns.On("PLAYER_LEAVING_WORLD", function()
  leftFrom = nil
  if IsInInstance and IsInInstance() then return end
  if UnitOnTaxi and UnitOnTaxi("player") then return end
  local spot = playerSpot()
  if spot then
    spot.at = GetTime and GetTime() or 0
    leftFrom = spot
  end
end)

ns.On("PLAYER_ENTERING_WORLD", function()
  local spot = leftFrom
  leftFrom = nil
  if not (spot and IsInInstance and GetInstanceInfo) then return end
  local inside, kind = IsInInstance()
  if not inside or (kind ~= "party" and kind ~= "raid") then return end
  if (IsPartyLFG and IsPartyLFG()) or (IsInLFGDungeon and IsInLFGDungeon()) then return end
  if GetTime and GetTime() - spot.at > ENTRY_WINDOW then return end
  local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
  if type(name) ~= "string" or name == "" then return end
  Dungeons.RecordEntrance(name, instanceID, spot.mapID, spot.x, spot.y)
end)

-- Remembers an instance's entrance (a new point unless one is this close).
function Dungeons.RecordEntrance(name, instanceID, mapID, x, y)
  local key = normalize(name)
  local all = ns.db.dungeonEntrances or {}
  ns.db.dungeonEntrances = all
  local record = all[key] or { name = name, instanceID = instanceID, points = {} }
  all[key] = record
  local node = ns.Geo.Node(mapID, x, y, name)
  for _, p in ipairs(record.points) do
    local known = ns.Geo.Node(p.mapID, p.x, p.y, name)
    if node and known and ns.Geo.Distance(node, known) <= SAME_ENTRANCE then
      p.seen = time and time() or 0
      return false
    end
  end
  table.insert(record.points, { mapID = mapID, x = x, y = y, seen = time and time() or 0 })
  ns.print(string.format("learned the entrance of %s.", name))
  Dungeons.Forget()
  ns.Fire("DATA_CHANGED")
  return true
end

local function learnedNodes(record)
  local nodes = {}
  for _, p in ipairs(record.points) do
    local node = ns.Geo.Node(p.mapID, p.x, p.y, record.name .. " entrance")
    if node then nodes[#nodes + 1] = node end
  end
  return nodes
end

-- Our dungeons, the data's, and the client's levels merged into one list,
-- kept until a data source or a learned entrance changes it (Dungeons.Forget):
-- pages ask for it many times per refresh (For you once per quest).
local catalogueCache, byAreaCache

local function build()
  local list, byArea, byKey = {}, {}, {}
  local function add(entry)
    list[#list + 1] = entry
    byKey[entry.keys[1]] = entry
    for areaID in pairs(entry.areaIDs) do byArea[areaID] = entry end
  end

  for _, d in ipairs(ns.data.dungeons) do
    local keys = { normalize(d.name) }
    for _, alias in ipairs(d.aliases or {}) do keys[#keys + 1] = normalize(alias) end
    add({ name = d.name, keys = keys, areaIDs = { [d.areaID] = true }, faction = d.faction, raid = d.raid,
      dataLevel = d.level, entrances = fallbackNodes(d), sourceNodes = {}, levels = {} })
  end

  -- A data dungeon joins ours by area ID, else by name (there are several
  -- "Dire Maul" wings). The rest only show if the client lists them, because
  -- data can also cover later expansions and battlegrounds.
  for _, q in ipairs(ns.Data.Dungeons()) do
    local entry = byArea[q.areaID] or byKey[normalize(q.name)]
    if not entry then
      entry = { name = q.name, keys = { normalize(q.name) }, areaIDs = {}, sourceNodes = {}, levels = {},
        entrances = {}, sourceOnly = true }
      add(entry)
    end
    entry.areaIDs[q.areaID] = true
    byArea[q.areaID] = entry
    for _, alt in ipairs(q.alternativeAreaIds or {}) do entry.areaIDs[alt] = true end
    for _, node in ipairs(ns.Data.Nodes(q.positions, q.name .. " entrance")) do table.insert(entry.sourceNodes, node) end
  end

  -- The longest of an entry's names that `key` starts with ("Scarlet
  -- Monastery - Armory" is a wing of "Scarlet Monastery"), or nil.
  local function owner(key)
    local best, bestLength = nil, 0
    for _, entry in ipairs(list) do
      for _, k in ipairs(entry.keys) do
        if #k > bestLength and key:sub(1, #k) == k then best, bestLength = entry, #k end
      end
    end
    return best
  end

  -- A dungeon only the client lists (one Forever added) becomes an entry of
  -- its own, without an entrance until you walk in once.
  for _, c in ipairs(clientDungeons()) do
    local best = owner(c.key)
    if not best then
      best = { name = c.name, keys = { c.key }, areaIDs = {}, sourceNodes = {}, levels = {}, entrances = {},
        clientOnly = true }
      add(best)
    end
    table.insert(best.levels, c)
    best.raid = best.raid or c.raid
  end

  -- Entrances you walked through win over everything else.
  for key, record in pairs(ns.db and ns.db.dungeonEntrances or {}) do
    local entry = owner(key)
    if entry then
      local nodes = learnedNodes(record)
      if #nodes > 0 then entry.learnedNodes = nodes end
    end
  end

  local out = {}
  for _, entry in ipairs(list) do
    if entry.learnedNodes then
      entry.entrances, entry.learned = entry.learnedNodes, true
    elseif #entry.sourceNodes > 0 then
      entry.entrances, entry.fromSource = entry.sourceNodes, true
    end
    if not entry.sourceOnly or #entry.levels > 0 then out[#out + 1] = entry end
  end
  return out
end

local function catalogue()
  if not catalogueCache then
    catalogueCache, byAreaCache = build(), {}
    for _, entry in ipairs(catalogueCache) do
      for areaID in pairs(entry.areaIDs) do byAreaCache[areaID] = byAreaCache[areaID] or entry end
    end
  end
  return catalogueCache
end

-- Drops the merged list; the next ask builds it again.
function Dungeons.Forget()
  catalogueCache, byAreaCache = nil, nil
end

ns.Listen("SOURCES_CHANGED", Dungeons.Forget)

-- The level that fits you best and its ranking penalty in seconds, or nil.
local function bestFit(entry, playerLevel)
  local levels = #entry.levels > 0 and entry.levels or { { level = entry.dataLevel } }
  local best, bestPenalty
  for _, l in ipairs(levels) do
    local gap = playerLevel - (l.level or 0)
    if l.level and gap >= -UNDER and gap <= OVER and not (entry.raid and gap < 0) then
      local penalty = math.abs(gap) * SECONDS_PER_LEVEL
      if not bestPenalty or penalty < bestPenalty then best, bestPenalty = l, penalty end
    end
  end
  return best, bestPenalty
end

local function questLines(details, header, quests)
  if #quests == 0 then return end
  details[#details + 1] = { text = header, color = { r = 1, g = 0.82, b = 0 } }
  for _, q in ipairs(quests) do
    details[#details + 1] = {
      text = string.format("[%d] %s", q.level, q.name or ("Quest " .. q.id)),
      color = GetQuestDifficultyColor and GetQuestDifficultyColor(q.level),
    }
  end
end

function Dungeons.SummaryText()
  return summary or "Dungeons for your level, best level fit and shortest trip first."
end

function Dungeons.EmptyText()
  return string.format("No dungeon fits level %d. Dungeons show from %d levels under "
    .. "their level to %d over.", UnitLevel("player"), UNDER, OVER)
end

function Dungeons.Results()
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local level = UnitLevel("player")
  local faction = UnitFactionGroup("player")

  local fitting, areaIDs = {}, {}
  for _, entry in ipairs(catalogue()) do
    local fit, penalty = bestFit(entry, level)
    if fit and (entry.faction == nil or entry.faction == faction) then
      fitting[#fitting + 1] = { entry = entry, fit = fit, penalty = penalty }
      for areaID in pairs(entry.areaIDs) do areaIDs[areaID] = true end
    end
  end
  local quests = ns.Quests.QuestsForAreas(areaIDs)

  local results = {}
  for _, f in ipairs(fitting) do
    local entry = f.entry
    local goal, route
    for _, node in ipairs(entry.entrances) do
      local r = ns.Router.Plan(start, node, net)
      if r and (not route or r.seconds < route.seconds) then goal, route = node, r end
    end
    goal = goal or entry.entrances[1]
    local unknown = goal == nil

    local available, inLog, later = {}, {}, {}
    for areaID in pairs(entry.areaIDs) do
      local q = quests[areaID]
      if q then
        for _, quest in ipairs(q.available) do available[#available + 1] = quest end
        for _, quest in ipairs(q.inLog) do inLog[#inLog + 1] = quest end
        for _, quest in ipairs(q.later or {}) do later[#later + 1] = quest end
      end
    end

    -- Why go: the level in the title, quests for it on the second line.
    local why = { unknown and "entrance not known yet" or ns.MapName(goal.mapID) }
    if #available > 0 then
      why[#why + 1] = string.format("%d quest%s for you", #available, #available == 1 and "" or "s")
    end
    if #inLog > 0 then why[#why + 1] = #inLog .. " in your log" end

    local gap = level - f.fit.level
    local details = { {
      text = string.format("%s level %d%s; you are %s.", entry.raid and "Raid" or "Dungeon", f.fit.level,
        #entry.levels > 0 and "" or " (Wayward estimate)",
        gap == 0 and "the same level" or string.format("%d level%s %s", math.abs(gap),
          math.abs(gap) == 1 and "" or "s", gap > 0 and "above it" or "below it")),
    } }
    if #entry.levels > 1 then
      for _, l in ipairs(entry.levels) do
        details[#details + 1] = { text = string.format("  %s: level %d", l.name, l.level), color = { r = 0.7, g = 0.7, b = 0.7 } }
      end
    end
    if unknown then
      details[#details + 1] = { text = "Wayward doesn't know where its entrance is yet. Walk in once (not through "
        .. "the dungeon finder) and it remembers.", color = { r = 1, g = 0.5, b = 0.25 } }
    elseif not (entry.fromSource or entry.learned) then
      details[#details + 1] = { text = "Entrance position is approximate.", color = { r = 0.6, g = 0.6, b = 0.6 } }
    end
    questLines(details, "Quests you can take for it:", available)
    questLines(details, "In your quest log:", inLog)

    results[#results + 1] = {
      id = "dungeon" .. normalize(entry.name),
      title = string.format("%s%s  ·  level %d", entry.name, entry.raid and " (raid)" or "", f.fit.level),
      titleColor = ns.DifficultyColor(f.fit.level),
      zone = table.concat(why, "  ·  "),
      goal = goal,
      route = route,
      details = details,
      score = (route and route.seconds or NO_ENTRANCE) + f.penalty,
      -- For other pages (For you): the dungeon and its quests behind this row.
      dungeon = entry,
      quests = { available = available, inLog = inLog, later = later },
      -- Pick up the quests you can take, then go in (QuestsPage.lua).
      actions = #available > 0 and goal and { { label = "Quests", run = function()
        ns.QuestsPage.StartDungeonRun(entry.name, goal, available)
      end } } or nil,
    }
  end

  table.sort(results, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return a.title < b.title
  end)
  summary = string.format("Dungeons for level %d, best level fit and shortest trip first.", level)
  if not ns.Quests.Available() then
    summary = summary .. " Install a Wayward data addon for exact entrances and dungeon quests."
  end
  return results, nil, net
end

-- For other pages: every known dungeon/raid as
-- { name, areaIDs = set, raid, faction, entrances = {route nodes}, fromSource, learned, clientOnly,
--   levels = {{name, level}} }.
function Dungeons.Catalogue()
  return catalogue()
end

-- The dungeon an AreaID belongs to (e.g. where a boss spawns), or nil.
function Dungeons.ForArea(areaID)
  catalogue()
  return byAreaCache[areaID]
end
