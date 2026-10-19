local _, ns = ...

-- Coordinate helpers. Map positions are 0-1 per uiMap (x east, y south).
-- World positions are yards per instance (continent): world X points north,
-- world Y points west. Both conventions were confirmed by WFProbe in the beta.

local Geo = {}
ns.Geo = Geo

local AZEROTH = 947
local atan2 = math.atan2 or math.atan

local function vec(x, y)
  return CreateVector2D(x, y)
end

function Geo.ToWorld(mapID, x, y)
  if not (mapID and x and y) then return nil end
  local instance, world = C_Map.GetWorldPosFromMapPos(mapID, vec(x, y))
  if not (instance and world) then return nil end
  local wx, wy = world:GetXY()
  return instance, wx, wy
end

-- A route node: where something is, in both map and world terms.
function Geo.Node(mapID, x, y, label)
  local instance, wx, wy = Geo.ToWorld(mapID, x, y)
  if not instance then return nil end
  return { label = label, mapID = mapID, x = x, y = y, instance = instance, wx = wx, wy = wy }
end

function Geo.PlayerNode()
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return nil end
  local x, y = pos:GetXY()
  return Geo.Node(mapID, x, y, "You")
end

function Geo.Distance(a, b)
  if not (a and b) or a.instance ~= b.instance then return math.huge end
  local dx, dy = a.wx - b.wx, a.wy - b.wy
  return math.sqrt(dx * dx + dy * dy)
end

-- Radians counter-clockwise from north: the same convention as GetPlayerFacing.
function Geo.Bearing(from, to)
  return atan2(to.wy - from.wy, to.wx - from.wx)
end

local continents

-- Continent uiMaps (including any new Forever continents), keyed by instance.
function Geo.Continents()
  if continents then return continents end
  continents = {}
  local children = C_Map.GetMapChildrenInfo(AZEROTH, Enum.UIMapType.Continent, false) or {}
  for _, info in ipairs(children) do
    local instance = Geo.ToWorld(info.mapID, 0.5, 0.5)
    if instance and not continents[instance] then continents[instance] = info.mapID end
  end
  return continents
end

-- Zone-level map point for a world position, for placing a user waypoint.
function Geo.ZonePoint(node)
  local continent = Geo.Continents()[node.instance]
  local world = vec(node.wx, node.wy)
  if continent then
    local _, cpos = C_Map.GetMapPosFromWorldPos(node.instance, world, continent)
    if cpos then
      local cx, cy = cpos:GetXY()
      local info = C_Map.GetMapInfoAtPosition(continent, cx, cy)
      if info and info.mapID then
        local _, zpos = C_Map.GetMapPosFromWorldPos(node.instance, world, info.mapID)
        if zpos then
          local zx, zy = zpos:GetXY()
          return info.mapID, zx, zy
        end
      end
      return continent, cx, cy
    end
  end
  return node.mapID, node.x, node.y
end

-- Where a node is on a given map (0-1), or nil when that map doesn't hold it.
function Geo.MapPos(node, mapID)
  if not (node and node.instance and mapID) then return nil end
  local _, pos = C_Map.GetMapPosFromWorldPos(node.instance, vec(node.wx, node.wy), mapID)
  if not pos then return nil end
  return pos:GetXY()
end

-- The zone (not continent) at a world position, or nil in between zones.
-- Zones don't move, so answers are kept per yard (the map calls behind them
-- are slow, and quest lists and route planning ask about the same points
-- again on every refresh).
local ZONE_CACHE_LIMIT = 20000
local zoneCache, zoneCached = {}, 0

function Geo.ZoneAt(instance, wx, wy)
  local key = instance .. ":" .. math.floor(wx + 0.5) .. ":" .. math.floor(wy + 0.5)
  local cached = zoneCache[key]
  if cached ~= nil then return cached or nil end
  local mapID = Geo.ZonePoint({ instance = instance, wx = wx, wy = wy })
  if not mapID or Geo.Continents()[instance] == mapID then mapID = nil end
  if zoneCached >= ZONE_CACHE_LIMIT then zoneCache, zoneCached = {}, 0 end
  zoneCache[key] = mapID or false
  zoneCached = zoneCached + 1
  return mapID
end
