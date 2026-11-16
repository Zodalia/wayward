local _, ns = ...

-- Your journey on the world map: the next three steps from the one you're
-- on, drawn as on the route maps (UI/RouteMap.lua: a colour for each way of
-- travel, chevrons pointing the way, travel icons, the stops numbered in
-- order) on whichever map you're looking at, as much of them as that map
-- holds. The map's own arrow is you, so a walk you're on starts where you
-- stand and follows you while the map is open. The step you're on is drawn
-- in full and the next two fade out, so the way ahead stands out; the
-- whole journey is on the overview's map. Plain directions show too.
-- The options or /ww worldmap turn it off. UI/MinimapRoute.lua draws the
-- same on the minimap. With OpenMap's seamless map it's drawn over its art
-- and on past the zone underneath.

local WorldMapRoute = {}
ns.WorldMapRoute = WorldMapRoute

local AZEROTH = 947
local SIZE = 1.3       -- lines and badges this much bigger on screen than on the small maps
local MOVED = 5         -- yards you walk before the line's start catches up with you
local CHECK_EVERY = 0.5 -- seconds between looks at where you are while the map is open
local SHOWN_STEPS = 3    -- steps drawn, the one you're on first; none after them
local STEP_ALPHA = { 1, 0.55, 0.3 } -- the one you're on in full, the next two fading out

-- How opaque the i-th step still to go is drawn (0: not drawn).
function WorldMapRoute.Alpha(i)
  return STEP_ALPHA[i] or 0
end

local map, view
local drawnFrom -- where you stood when the line was last drawn from you
local since = 0

local function enabled()
  return ns.db and ns.db.settings.worldMapRoute ~= false
end

-- The steps still to go, and where you are when they start from you.
local function remaining()
  local here = ns.Geo.PlayerNodeExact()
  local steps, fromHere = ns.RouteMap.Rest(here)
  return steps, fromHere and here or nil
end

-- OpenMap (another addon) paints its own seamless map on the same canvas,
-- in the levels just above the explored terrain, and shows the zones round
-- the one underneath too (docs/api.md in OpenMap: OpenMapAPI).
local function openMap()
  local api = OpenMapAPI
  return type(api) == "table" and api or nil
end

-- Whether OpenMap's seamless map is the one showing.
local function stitched()
  local api = openMap()
  if not (api and type(api.IsStitched) == "function") then return false end
  local ok, on = pcall(api.IsStitched)
  return ok and on == true
end

-- The map's own layers: over the explored terrain (and over OpenMap's art,
-- which it builds once the map first opens), under the game's pins where
-- the map says where they go.
local function frameLevel(canvas)
  local ok, level = pcall(function()
    return map:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_MAP_EXPLORATION")
  end)
  level = (ok and type(level) == "number") and level + 1 or (canvas:GetFrameLevel() or 0) + 1
  local api = openMap()
  if api and type(api.ArtTopLevel) == "function" then
    local got, top = pcall(api.ArtTopLevel)
    if got and type(top) == "number" and top >= level then level = top + 1 end
  end
  return level
end

-- Puts the route on its layer, again when that moved (not in combat:
-- PLAYER_REGEN_ENABLED tries again).
local function layer(v, canvas)
  local level = frameLevel(canvas)
  if v.layer == level or (InCombatLockdown and InCombatLockdown()) then return end
  v.layer = level
  v.canvas:SetFrameLevel(level)
  v.pins:SetFrameLevel(level + 2)
end

local function newView(canvas)
  local v = ns.RouteMap.NewView(canvas, canvas:GetWidth() or 1)
  v.canvas:ClearAllPoints()
  v.canvas:SetAllPoints(canvas)
  v.label:Hide()
  v.canvas:SetScript("OnUpdate", function(_, elapsed)
    since = since + (elapsed or 0)
    if since < CHECK_EVERY or not drawnFrom then return end
    since = 0
    local here = ns.Geo.PlayerNodeExact()
    if here and (here.instance ~= drawnFrom.instance or ns.Geo.Distance(here, drawnFrom) >= MOVED) then
      WorldMapRoute.Refresh()
    end
  end)
  return v
end

local function clear()
  drawnFrom = nil
  if view then view.canvas:Hide() end
end

-- Draws the route on the map being looked at (or takes it off); returns
-- what was drawn (RouteMap.DrawRoute's stats), or nil.
function WorldMapRoute.Refresh()
  if not map then return nil end
  local steps, from
  if enabled() then steps, from = remaining() end
  local canvas = map:GetCanvas()
  local mapID = map:GetMapID()
  local w, h = canvas and canvas:GetWidth(), canvas and canvas:GetHeight()
  if not (steps and mapID and w and w > 0 and h and h > 0) then
    clear()
    return nil
  end
  view = view or newView(canvas)
  layer(view, canvas)
  -- OpenMap's seamless map runs on past the map underneath, so the route does too.
  local seamless = stitched()
  if view.canvas.SetClipsChildren then view.canvas:SetClipsChildren(not seamless) end
  local points = { steps[1].from }
  for _, step in ipairs(steps) do points[#points + 1] = step.to end
  -- Where a node is on this map, even beyond its edges: legs are cut where
  -- the map ends, so one that runs off it still shows as far as the edge.
  -- Nowhere on a map of another continent (the world map holds them all).
  local instance = mapID ~= AZEROTH and ns.Geo.ToWorld(mapID, 0.5, 0.5) or nil
  local function at(node)
    if instance and node.instance ~= instance then return nil end
    local x, y = ns.Geo.MapPos(node, mapID)
    if not x then return nil end
    return x * w, -y * h
  end
  local scale = map.GetCanvasScale and map:GetCanvasScale() or 1
  if not (scale and scale > 0) then scale = 1 end
  view.canvas:Show()
  local stats = ns.RouteMap.DrawRoute(view, steps, points, at,
    { size = SIZE / scale, clip = not seamless and { w = w, h = h } or nil, you = false, gap = from ~= nil,
      alpha = WorldMapRoute.Alpha, limit = SHOWN_STEPS })
  drawnFrom = from
  since = 0
  WorldMapRoute.mapID = mapID
  return stats
end

-- What's drawn now (for tests): RouteMap.DrawRoute's stats, or nil.
function WorldMapRoute.Stats()
  return view and view.canvas:IsShown() and view.stats or nil
end

-- The frame level the route is drawn at (for tests), or nil.
function WorldMapRoute.Level()
  return view and view.canvas:GetFrameLevel()
end

local function refreshIfOpen()
  if map and map:IsShown() then WorldMapRoute.Refresh() end
end

-- Joins the world map as one of its data providers, so the route is redrawn
-- whenever it changes map, zooms or resizes.
function WorldMapRoute.Hook()
  if map then return true end
  if not (WorldMapFrame and WorldMapFrame.AddDataProvider and WorldMapFrame.GetCanvas
    and MapCanvasDataProviderMixin and CreateFromMixins and ns.RouteMap and ns.RouteMap.DrawRoute) then
    return false
  end
  map = WorldMapFrame
  local provider = CreateFromMixins(MapCanvasDataProviderMixin)
  function provider:RemoveAllData() clear() end
  function provider:RefreshAllData() WorldMapRoute.Refresh() end
  function provider:OnMapChanged() WorldMapRoute.Refresh() end
  function provider:OnCanvasScaleChanged() WorldMapRoute.Refresh() end
  function provider:OnCanvasSizeChanged() WorldMapRoute.Refresh() end
  map:AddDataProvider(provider)
  if map.HookScript then map:HookScript("OnShow", WorldMapRoute.Refresh) end
  return true
end

ns.On("PLAYER_LOGIN", WorldMapRoute.Hook)
ns.On("ADDON_LOADED", function(name)
  if name == "Blizzard_WorldMap" then WorldMapRoute.Hook() end
end)
ns.On("PLAYER_REGEN_ENABLED", refreshIfOpen)
ns.Listen("NAV_CHANGED", refreshIfOpen)
ns.Listen("JOURNEY_EXTENDED", refreshIfOpen)
ns.Listen("SETTINGS_CHANGED", function(key) if key == "worldMapRoute" then refreshIfOpen() end end)

ns.RegisterCommand("worldmap", "/ww worldmap - your journey drawn on the world map, on or off", function()
  ns.SetSetting("worldMapRoute", not enabled())
  ns.print("journey on the world map " .. (enabled() and "on" or "off"))
end)
