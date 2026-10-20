local _, ns = ...

-- Human names for places ("Auberdine", "Lakeshire"). The client has no
-- "subzone at this position" lookup, so: the nearest flight path's town, then
-- an explored map area at that spot, else nothing.

local Places = {}
ns.Places = Places

local TOWN_RADIUS = 350 -- yards from a flight master that still count as its town

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

function Places.NameFor(node)
  if not towns then loadTowns() end
  local best, bestDistance = nil, TOWN_RADIUS
  for _, town in ipairs(towns) do
    local d = ns.Geo.Distance(node, town)
    if d <= bestDistance then best, bestDistance = town, d end
  end
  if best then return best.label end
  return exploredAreaName(node)
end
