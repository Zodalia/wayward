local _, ns = ...

-- Game data from outside the game, through one interface. Wayward bundles
-- none: a companion addon registers a source, and without one every page runs
-- on what you learned in game (Harvest.lua) and the client's own API.
--
-- A companion adds `## Dependencies: Wayward` to its TOC and calls
--   Wayward.RegisterSource(source)
-- while it loads (Wayward.UnregisterSource(id) takes it away again). A
-- source is a table; only `id` and `label` are required.
-- Every function is optional and answers nil when it doesn't know:
--
--   id, label          "questie", "QuestieDB"
--   priority           higher wins when two sources know the same thing (default 0)
--   Status()           extra text for /ww debug and the panel footer, or nil
--   QuestIDs()         { questID, ... }
--   Quest(id)          quest record (below)
--   Npc(id)            NPC record
--   NpcIDs(flag)       { npcID, ... } with that flag: "trainer", "vendor", "repair", "flightMaster"
--   Object(id)         object record
--   Item(id)           item record
--   ItemIDs()          { itemID, ... }
--   QuestRewards()     { [questID] = { itemID, ... } }: the items each quest rewards
--                      (optional: else built from ItemIDs and the items' questRewards)
--   Dungeons()         { {areaID, name, alternativeAreaIds = {areaID, ...}, positions}, ... }
--   QuestXP()          { [questID] = {questLevel, xp} }: full reward before the level penalty
--   EraToForever(mapID, x, y)   an Era (vanilla) map point in Forever: x, y (0-1)
--   ClassSpells(class) { {spellID, level, cost?, requires = {spellID, ...}?, replaces = spellID?,
--                        talent = spellID? (only with that talent), races = {[raceID] = true}?,
--                        faction = "Alliance"|"Horde"?}, ... }
--   TrainerSpells(npcID)        { {spellID, level, cost?, skill?, skillValue?}, ... }
--   TaxiCost(fromNodeID, toNodeID)  copper
--
-- Records are read-only. A position is { mapID = uiMapID, x, y, areaID }:
-- x and y 0-1 on that map in Forever coordinates; mapID is nil for a place
-- with no world map (inside a dungeon), areaID (AreaTable) when known.
--
-- Quest record:
--   id, name, questLevel, requiredLevel, requiredMaxLevel (0 or nil: none)
--   races = { [raceID] = true }, classes = { [CLASS] = true } (nil: anyone)
--   startedBy, finishedBy = { {npcID, ...}, {objectID, ...}, {itemID, ...} }
--   preQuestSingle (any one first), preQuestGroup (all first), exclusiveTo = { questID, ... }
--   nextQuestInChain, parentQuest, breadcrumbForQuestId, availableUntilCompleted,
--     availableStartingWith, disabledByQuest = questID (0 or nil: none)
--   requiredSkill = { skillID, value } (nil: none)
--   zoneOrSort         signed: > 0 the AreaID it belongs to (for a dungeon quest,
--                      the dungeon's); < 0 a QuestSort (QuestieDB's sortKeys:
--                      class -61 Warlock ..., -344 Legendary, -1 Epic,
--                      professions, holidays); 0 or nil: unknown
--   questFlags         bit mask (optional): 32 epic, 64 raid, 4096 daily, ...
--   specialFlags       bit mask (optional): 1 repeatable
--   reputationReward = { {factionID, value}, ... } (optional)
--   childQuests = { questID, ... } (optional)
--   objectives = { { {npcID}, ... }, { {objectID}, ... }, { {itemID}, ... } }
--   triggerEnd = { text, {position, ...} }   a place to explore
--   requiredSourceItems = { itemID, ... }
--   extraObjectives = { { {position, ...}, icon, text }, ... }
-- NPC record: id, name, subName ("Warlock Trainer"), faction ("A", "H", "AH"; nil:
--   anyone), rank, minLevel, maxLevel, flags = { trainer = true, ... }, positions
-- Object record: id, name, positions
-- Item record: id, name, itemLevel, requiredLevel, and where it comes from as ID
--   lists: npcDrops, objectDrops, itemDrops (containers), questRewards, vendors;
--   class, subClass (optional): the item class IDs (2 weapon, 4 armour, ...)

local Data = {}
ns.Data = Data

local sources = {} -- registered, highest priority first

-- A source's own error must not take a page down: report it, answer nil.
local function call(source, name, ...)
  local fn = source[name]
  if type(fn) ~= "function" then return nil end
  local ok, a, b = pcall(fn, ...)
  if ok then return a, b end
  geterrorhandler()(string.format("Wayward data source %s: %s", tostring(source.id), tostring(a)))
  return nil
end

local npcCache, kindIndex, idLists, nodeCache = {}, nil, {}, setmetatable({}, { __mode = "k" })

local function forget()
  npcCache, kindIndex, idLists = {}, nil, {}
end

local function register(source)
  if type(source) ~= "table" or type(source.id) ~= "string" then
    error("Wayward.RegisterSource: a source needs an id", 2)
  end
  for i, s in ipairs(sources) do
    if s.id == source.id then table.remove(sources, i) break end
  end
  sources[#sources + 1] = source
  table.sort(sources, function(a, b) return (a.priority or 0) > (b.priority or 0) end)
  forget()
  ns.Fire("SOURCES_CHANGED")
end

local function unregister(id)
  for i, s in ipairs(sources) do
    if s.id == id then
      table.remove(sources, i)
      forget()
      ns.Fire("SOURCES_CHANGED")
      return true
    end
  end
  return false
end

-- The one global: for companion addons. Registering an id again replaces it.
Wayward = Wayward or {}
Wayward.API = 1
Wayward.RegisterSource = register
Wayward.UnregisterSource = unregister
-- The addon was called Wayfinder before it was published. Companions built
-- against that name still register through this alias; drop it one release
-- after the first one shipped as Wayward.
Wayfinder = Wayward

function Data.Sources()
  return sources
end

-- How hints name a data source, in one place ("install a Wayward data addon").
Data.ADDON = "a Wayward data addon"

-- True when a registered source has this function ("Quest", "ClassSpells", ...).
function Data.Has(capability)
  for _, s in ipairs(sources) do
    if type(s[capability]) == "function" then return true end
  end
  return false
end

-- "QuestieDB (baked), Class spells", or nil without sources.
function Data.Status()
  if #sources == 0 then return nil end
  local parts = {}
  for _, s in ipairs(sources) do
    local extra = call(s, "Status")
    parts[#parts + 1] = (s.label or s.id) .. (extra and (" (" .. extra .. ")") or "")
  end
  return table.concat(parts, ", ")
end

local function first(name, ...)
  for _, s in ipairs(sources) do
    local value = call(s, name, ...)
    if value ~= nil then return value end
  end
  return nil
end

-- IDs from every source, without repeats, kept until the sources change.
local function union(name, arg)
  local key = name .. ":" .. tostring(arg)
  if idLists[key] then return idLists[key] end
  local out, seen = {}, {}
  for _, s in ipairs(sources) do
    for _, id in ipairs(call(s, name, arg) or {}) do
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  idLists[key] = out
  return out
end

function Data.Quest(id) return first("Quest", id) end
function Data.QuestIDs() return union("QuestIDs") end
function Data.Object(id) return first("Object", id) end
function Data.Item(id) return first("Item", id) end
function Data.ItemIDs() return union("ItemIDs") end
function Data.QuestRewards() return first("QuestRewards") end
function Data.NpcIDs(flag) return union("NpcIDs", flag) end
function Data.QuestXP() return first("QuestXP") end
function Data.TrainerSpells(npcID) return first("TrainerSpells", npcID) end
function Data.TaxiCost(from, to) return first("TaxiCost", from, to) end

-- NPCs merge field by field: a higher-priority source wins each field it has.
function Data.Npc(id)
  if npcCache[id] ~= nil then return npcCache[id] or nil end
  local merged
  for i = #sources, 1, -1 do
    local record = call(sources[i], "Npc", id)
    if type(record) == "table" then
      merged = merged or {}
      for k, v in pairs(record) do merged[k] = v end
    end
  end
  npcCache[id] = merged or false
  return merged
end

function Data.Dungeons()
  local out = {}
  for _, s in ipairs(sources) do
    for _, d in ipairs(call(s, "Dungeons") or {}) do out[#out + 1] = d end
  end
  return out
end

-- An Era point in Forever coordinates: x, y, converted (false: unchanged).
function Data.EraToForever(mapID, x, y)
  for _, s in ipairs(sources) do
    local fx, fy = call(s, "EraToForever", mapID, x, y)
    if type(fx) == "number" and type(fy) == "number" then return fx, fy, true end
  end
  return x, y, false
end

-- Class spells from every source, merged by spell ID (higher priority wins
-- each field): { {spellID, level, cost?, requires?, replaces?, talent?, races?,
-- faction?}, ... } by level.
function Data.ClassSpells(class)
  local bySpell, order = {}, {}
  for i = #sources, 1, -1 do
    for _, spell in ipairs(call(sources[i], "ClassSpells", class) or {}) do
      local id = spell.spellID
      if id then
        local s = bySpell[id]
        if not s then
          s = {}
          bySpell[id] = s
          order[#order + 1] = s
        end
        for k, v in pairs(spell) do s[k] = v end
      end
    end
  end
  table.sort(order, function(a, b)
    if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
    return a.spellID < b.spellID
  end)
  return order
end

---------------------------------------------------------------- places

-- Route nodes for a list of positions (those on a world map), kept for the
-- session per list.
function Data.Nodes(positions, label)
  if type(positions) ~= "table" then return {} end
  local cached = nodeCache[positions]
  if cached and cached.label == label then return cached.nodes end
  local nodes = {}
  for _, p in ipairs(positions) do
    if p.mapID and type(p.x) == "number" and p.x >= 0 then
      local node = ns.Geo.Node(p.mapID, p.x, p.y, label)
      if node then nodes[#nodes + 1] = node end
    end
  end
  nodeCache[positions] = { label = label, nodes = nodes }
  return nodes
end

-- The nearest node to `here` and its distance (yards).
function Data.Nearest(nodes, here)
  local best, bestDistance = nodes[1], math.huge
  for _, node in ipairs(nodes) do
    local d = ns.Geo.Distance(here, node)
    if d < bestDistance then best, bestDistance = node, d end
  end
  return best, bestDistance
end

-- Is an NPC with this faction ("A", "H", "AH" or nil) friendly to yours?
function Data.FriendlyTo(npcFaction, faction)
  if npcFaction == nil or npcFaction == "" then return true end
  return npcFaction:find(faction == "Alliance" and "A" or "H", 1, true) ~= nil
end

---------------------------------------------------------------- NPCs by role

-- English trainer subtitles. Sources keep subtitles in English; the client
-- translates names, not data.
local CLASS_BY_TRAINER_TITLE = {
  ["Warrior Trainer"] = "WARRIOR", ["Paladin Trainer"] = "PALADIN", ["Hunter Trainer"] = "HUNTER",
  ["Rogue Trainer"] = "ROGUE", ["Priest Trainer"] = "PRIEST", ["Shaman Trainer"] = "SHAMAN",
  ["Mage Trainer"] = "MAGE", ["Warlock Trainer"] = "WARLOCK", ["Druid Trainer"] = "DRUID",
}

local function now()
  return debugprofilestop and debugprofilestop() or 0
end

-- One pass over trainers and flight masters, kept until the sources change:
-- [kind] = { {id, name, faction, nodes, class?, profession?, rank?}, ... }.
local function buildKinds()
  kindIndex = { classTrainer = {}, weaponMaster = {}, professionTrainer = {}, flightMaster = {} }
  local started = now()
  local function add(kind, id, npc, extra)
    local entry = { id = id, name = npc.name, faction = npc.faction, nodes = Data.Nodes(npc.positions, npc.name) }
    for k, v in pairs(extra or {}) do entry[k] = v end
    table.insert(kindIndex[kind], entry)
  end
  for _, id in ipairs(Data.NpcIDs("trainer")) do
    local npc = Data.Npc(id)
    if npc and npc.name then
      local subName = npc.subName or ""
      local class = CLASS_BY_TRAINER_TITLE[subName]
      local profession, rank
      if ns.Professions and ns.Professions.FromSubtitle then profession, rank = ns.Professions.FromSubtitle(subName) end
      if class then
        add("classTrainer", id, npc, { class = class })
      elseif subName == "Weapon Master" then
        add("weaponMaster", id, npc)
      elseif profession then
        add("professionTrainer", id, npc, { profession = profession, rank = rank })
      end
    end
  end
  for _, id in ipairs(Data.NpcIDs("flightMaster")) do
    local npc = Data.Npc(id)
    if npc and npc.name then add("flightMaster", id, npc) end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.sourceNPCs = now() - started
end

-- NPCs of one kind ("classTrainer", "weaponMaster", "professionTrainer",
-- "flightMaster") from the sources that are friendly to `faction` (nil: all):
-- { {id, name, nodes, class?, profession?, rank?}, ... }.
function Data.NPCsOfKind(kind, faction)
  if not kindIndex then buildKinds() end
  local out = {}
  for _, e in ipairs(kindIndex[kind] or {}) do
    if #e.nodes > 0 and (not faction or Data.FriendlyTo(e.faction, faction)) then out[#out + 1] = e end
  end
  return out
end

-- The same, each at its spawn nearest to `here`, and only those `fits(entry)`
-- accepts: { {id, name, node, class?, profession?, rank?}, ... }.
function Data.NearestOfKind(kind, faction, here, fits)
  local out = {}
  for _, e in ipairs(Data.NPCsOfKind(kind, faction)) do
    if not fits or fits(e) then
      out[#out + 1] = { id = e.id, name = e.name, node = (Data.Nearest(e.nodes, here)), class = e.class,
        profession = e.profession, rank = e.rank }
    end
  end
  return out
end
