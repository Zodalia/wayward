local _, ns = ...

-- Human names for places ("Auberdine", "Lakeshire"). The client has no
-- "subzone at this position" lookup, so: the nearest flight path's town, then
-- an explored map area at that spot, then the subzone of an NPC you've met
-- close by (Harvest records it: "Kharanos" has no flight path), else nothing.

local Places = {}
ns.Places = Places

local TOWN_RADIUS = 350 -- yards from a flight master that still count as its town
local MET_RADIUS = 120  -- yards from an NPC you've met that still count as their subzone

local towns

-- Every flight path (known or not) is a named town with a position.
local function loadTowns()
  towns = {}
  for _, continent in pairs(ns.Geo.Continents()) do
    for _, t in ipairs(C_TaxiMap.GetTaxiNodesForMap(continent) or {}) do
      if t.position and t.name then
        local node = ns.Geo.Node(continent, t.position.x, t.position.y, t.name:match("^([^,]+)") or t.name)
        if node then towns[#towns + 1] = node end
      end
    end
  end
end

local function exploredAreaName(node)
  local mapID, x, y = ns.Geo.ZonePoint(node)
  local lookup = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition
  if not (lookup and mapID) then return nil end
  local ok, areaIDs = pcall(lookup, mapID, CreateVector2D(x, y))
  local areaID = ok and type(areaIDs) == "table" and areaIDs[1]
  local name = areaID and C_Map.GetAreaInfo and C_Map.GetAreaInfo(areaID)
  return type(name) == "string" and name ~= "" and name or nil
end

-- The NPCs you've met with the subzone they stood in, as places (rebuilt
-- when what you know changes).
local met
local function loadMet()
  met = {}
  for _, npc in pairs(ns.Harvest and ns.Harvest.AllNPCs() or {}) do
    if npc.subZone and npc.subZone ~= "" and npc.mapID then
      local node = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.subZone)
      if node then met[#met + 1] = node end
    end
  end
end

local function metAreaName(node)
  if not met then loadMet() end
  local best, bestDistance = nil, MET_RADIUS
  for _, place in ipairs(met) do
    if place.mapID == node.mapID or place.instance == node.instance then
      local d = ns.Geo.Distance(node, place)
      if d <= bestDistance then best, bestDistance = place, d end
    end
  end
  return best and best.label
end

ns.Listen("DATA_CHANGED", function() met = nil end)

function Places.NameFor(node)
  if not towns then loadTowns() end
  local best, bestDistance = nil, TOWN_RADIUS
  for _, town in ipairs(towns) do
    local d = ns.Geo.Distance(node, town)
    if d <= bestDistance then best, bestDistance = town, d end
  end
  if best then return best.label end
  return exploredAreaName(node) or metAreaName(node)
end
