local _, ns = ...

-- The installed QuestieDB (github.com/Questie/QuestieDB), read through its
-- public consumer API (docs/api.md, contract 4), which is written for
-- third-party addons; nothing of it is copied or shipped. Registered only
-- when a QuestieDB this speaks is loaded (## OptionalDeps: QuestieDB puts it
-- first); without one, quests, items and most NPCs are unknown and the
-- pages say so.

local CONTRACT = 4

local lib = _G.LibQuestieDB
if type(lib) ~= "table" or type(lib.RequireContract) ~= "function" then return end
local ok, accepted, message = pcall(lib.RequireContract, CONTRACT)
if not (ok and accepted) then
  ns.print("QuestieDB is too old or too new for this Wayward: " .. tostring(message or accepted))
  return
end
ns.questieLive = true

local entities = { quest = lib.Quest, npc = lib.Npc, object = lib.Object, item = lib.Item }

local function get(kind, id, field)
  local entity = entities[kind]
  if not entity then return nil end
  local okGet, value = pcall(entity.Get, id, field)
  if okGet then return value end
  return nil
end

local function support(name)
  local okSupport, module = pcall(lib.Support.Get, name)
  return okSupport and type(module) == "table" and module or nil
end

local areaToUiMap
local function uiMapFor(areaID)
  if not areaToUiMap then
    areaToUiMap = {}
    local zone = support("ZoneDB")
    local src = zone and zone.private and zone.private.areaIdToUiMapId
    if type(src) == "string" then
      local chunk = loadstring(src)
      local loaded, value = pcall(chunk or error)
      if loaded and type(value) == "table" then areaToUiMap = value end
    elseif type(src) == "table" then
      areaToUiMap = src
    end
  end
  return areaToUiMap[areaID]
end

local questFields = {}
for field in pairs(lib.Meta and lib.Meta.QuestMeta and lib.Meta.QuestMeta.questKeys or {}) do
  questFields[field] = true
end

local reader = {
  get = get,
  getAll = function(kind, id, fields)
    local entity = entities[kind]
    if not (entity and entity.GetAll) then return nil end
    local okAll, values = pcall(entity.GetAll, id, fields)
    return okAll and type(values) == "table" and values or nil
  end,
  exists = function(kind, id)
    local entity = entities[kind]
    if not entity then return false end
    if entity.Exists then
      local okExists, exists = pcall(entity.Exists, id)
      return okExists and exists or false
    end
    return get(kind, id, "name") ~= nil
  end,
  ids = function(kind)
    local entity = entities[kind]
    local okIds, ids = pcall(entity and entity.GetAllIds or error)
    return okIds and type(ids) == "table" and ids or {}
  end,
  uiMapFor = uiMapFor,
  raceMasks = lib.Enum.raceMaskById or {},
  classKeys = lib.Enum.classKeys or {},
  npcFlags = lib.Enum.npcFlags or {},
  questFields = questFields,
  dungeons = function()
    local zone = support("ZoneDB")
    return zone and zone.private and zone.private.dungeons
  end,
  questXP = function()
    local xp = support("QuestXP")
    return xp and type(xp.db) == "table" and xp.db or nil
  end,
}

-- Only for Wayward's hand-made Era points; QuestieDB's own data is already
-- in Forever coordinates.
if type(lib.EraToForeverByUiMapId) == "function" then
  reader.eraToForever = function(mapID, x, y)
    local okConvert, fx, fy = pcall(lib.EraToForeverByUiMapId, mapID, x, y)
    if okConvert then return fx, fy end
    return nil
  end
end

Wayward.RegisterSource(ns.QuestieShape.New({
  id = "questie", label = "QuestieDB", priority = 50, reader = reader,
  status = function() return lib.readMode end,
}))
