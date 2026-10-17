local _, ns = ...

-- "Dungeons" category: dungeons that fit your level, ranked by level fit and
-- travel time to the entrance.
--
-- Levels come from the client's dungeon finder list (GetLFGDungeonInfo, one
-- level per dungeon or wing). It has no area IDs, so it is matched to our
-- dungeons by name. Entrances come from QuestieDB when installed, else from
-- Data/Dungeons.lua. Dungeon quests need QuestieDB.

local Dungeons = { id = "dungeons", label = "Dungeons" }
ns.Dungeons = Dungeons

local MAX_LEVEL = 60          -- Forever's level cap; higher entries are later expansions
local LFG_SCAN = 3000         -- dungeon finder IDs to read (WFProbe saw vanilla in 1..~100)
local TYPE_WORLD, TYPE_BATTLEGROUND = 4, 5
local UNDER, OVER = 3, 6      -- a dungeon fits from 3 levels under its level to 6 over
local SECONDS_PER_LEVEL = 150 -- ranking: each level away from a dungeon's level weighs like 2.5 min of travel

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
    local x, y = ns.Questie.EraToForever(e.mapID, e.x, e.y)
    local node = ns.Geo.Node(e.mapID, x, y, e.label or (d.name .. " entrance"))
    if node then nodes[#nodes + 1] = node end
  end
  return nodes
end

-- Our dungeons, QuestieDB's, and the client's levels merged into one list.
local function catalogue()
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
      dataLevel = d.level, entrances = fallbackNodes(d), questieNodes = {}, levels = {} })
  end

  -- A QuestieDB dungeon joins ours by area ID, else by name (it has several
  -- "Dire Maul" wings). The rest only show if the client lists them, because
  -- QuestieDB also covers later expansions and battlegrounds.
  for _, q in ipairs(ns.Questie.Dungeons()) do
    local entry = byArea[q.areaID] or byKey[normalize(q.name)]
    if not entry then
      entry = { name = q.name, keys = { normalize(q.name) }, areaIDs = {}, questieNodes = {}, levels = {},
        entrances = {}, questieOnly = true }
      add(entry)
    end
    entry.areaIDs[q.areaID] = true
    byArea[q.areaID] = entry
    for _, alt in ipairs(q.alternativeAreaIds) do entry.areaIDs[alt] = true end
    for _, node in ipairs(q.nodes) do table.insert(entry.questieNodes, node) end
  end

  -- Wings ("Scarlet Monastery - Armory") match by prefix; the longest name wins.
  for _, c in ipairs(clientDungeons()) do
    local best, bestLength = nil, 0
    for _, entry in ipairs(list) do
      for _, key in ipairs(entry.keys) do
        if #key > bestLength and c.key:sub(1, #key) == key then best, bestLength = entry, #key end
      end
    end
    if best then
      table.insert(best.levels, c)
      best.raid = best.raid or c.raid
    end
  end

  local out = {}
  for _, entry in ipairs(list) do
    if #entry.questieNodes > 0 then entry.entrances, entry.fromQuestie = entry.questieNodes, true end
    if not entry.questieOnly or #entry.levels > 0 then out[#out + 1] = entry end
  end
  return out
end

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
  return string.format("No dungeon with a known entrance fits level %d. Dungeons show from %d levels under "
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
    if fit and #entry.entrances > 0 and (entry.faction == nil or entry.faction == faction) then
      fitting[#fitting + 1] = { entry = entry, fit = fit, penalty = penalty }
      for areaID in pairs(entry.areaIDs) do areaIDs[areaID] = true end
    end
  end
  local quests = ns.Questie.QuestsForAreas(areaIDs)

  local results = {}
  for _, f in ipairs(fitting) do
    local entry = f.entry
    local goal, route
    for _, node in ipairs(entry.entrances) do
      local r = ns.Router.Plan(start, node, net)
      if r and (not route or r.seconds < route.seconds) then goal, route = node, r end
    end
    goal = goal or entry.entrances[1]

    local available, inLog = {}, {}
    for areaID in pairs(entry.areaIDs) do
      local q = quests[areaID]
      if q then
        for _, quest in ipairs(q.available) do available[#available + 1] = quest end
        for _, quest in ipairs(q.inLog) do inLog[#inLog + 1] = quest end
      end
    end

    -- Why go: the level in the title, quests for it on the second line.
    local why = { ns.MapName(goal.mapID) }
    if #available > 0 then
      why[#why + 1] = string.format("%d quest%s for you", #available, #available == 1 and "" or "s")
    end
    if #inLog > 0 then why[#why + 1] = #inLog .. " in your log" end

    local gap = level - f.fit.level
    local details = { {
      text = string.format("%s level %d%s; you are %s.", entry.raid and "Raid" or "Dungeon", f.fit.level,
        #entry.levels > 0 and "" or " (Wayfinder estimate)",
        gap == 0 and "the same level" or string.format("%d level%s %s", math.abs(gap),
          math.abs(gap) == 1 and "" or "s", gap > 0 and "above it" or "below it")),
    } }
    if #entry.levels > 1 then
      for _, l in ipairs(entry.levels) do
        details[#details + 1] = { text = string.format("  %s: level %d", l.name, l.level), color = { r = 0.7, g = 0.7, b = 0.7 } }
      end
    end
    if not entry.fromQuestie then
      details[#details + 1] = { text = "Entrance position is approximate.", color = { r = 0.6, g = 0.6, b = 0.6 } }
    end
    questLines(details, "Quests you can take for it:", available)
    questLines(details, "In your quest log:", inLog)

    results[#results + 1] = {
      id = "dungeon" .. normalize(entry.name),
      title = string.format("%s%s  ·  level %d", entry.name, entry.raid and " (raid)" or "", f.fit.level),
      zone = table.concat(why, "  ·  "),
      goal = goal,
      route = route,
      details = details,
      score = (route and route.seconds or math.huge) + f.penalty,
    }
  end

  table.sort(results, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return a.title < b.title
  end)
  summary = string.format("Dungeons for level %d, best level fit and shortest trip first.", level)
  if not ns.Questie.Available() then
    summary = summary .. " Install QuestieDB for exact entrances and dungeon quests."
  end
  return results, nil, net
end

-- For other pages: every known dungeon/raid as
-- { name, areaIDs = set, raid, faction, entrances = {route nodes}, fromQuestie, levels = {{name, level}} }.
function Dungeons.Catalogue()
  return catalogue()
end

-- The dungeon an AreaID belongs to (e.g. where a boss spawns), or nil.
function Dungeons.ForArea(areaID)
  for _, entry in ipairs(catalogue()) do
    if entry.areaIDs[areaID] then return entry end
  end
  return nil
end
