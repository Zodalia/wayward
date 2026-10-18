local _, ns = ...

-- A small map under a result's tooltip (cards and side panel rows) with its
-- route drawn on it: the smallest map that holds the whole route (the zone,
-- else the continent, else the world map), from the game's own map art,
-- zoomed in on the route (with some room around it).
-- Walking is white, flights light blue, boats and the like deeper blue; you,
-- each stop and the destination are marked. Shown only when the client has
-- the map art API.

local RouteMap = {}
ns.RouteMap = RouteMap

local AZEROTH = 947
local WIDTH = 280
local ZOOM_MARGIN = 1.5  -- the shown area is this much bigger than the route
local MIN_VIEW = 0.12    -- the closest zoom: this share of the map's width
local LINE_COLOR = { walk = { 1, 1, 1, 0.9 }, fly = { 0.45, 0.8, 1, 1 }, transport = { 0.25, 0.5, 1, 1 } }
local MARK_COLOR = { start = { 0.3, 1, 0.3 }, stop = { 1, 0.82, 0 }, goal = { 1, 0.3, 0.2 } }

local frame -- the tooltip's map
local unpack = unpack or table.unpack

local function available()
  return C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures and C_Map.GetMapPosFromWorldPos
end

-- A map view: a clipped canvas `width` wide on `parent`, with its own pools.
function RouteMap.NewView(parent, width)
  local v = { width = width, tiles = {}, lines = {}, marks = {} }
  v.canvas = CreateFrame("Frame", nil, parent)
  v.canvas:SetSize(width, math.floor(width * 2 / 3))
  if v.canvas.SetClipsChildren then v.canvas:SetClipsChildren(true) end
  v.label = v.canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.label:SetPoint("TOPLEFT", 4, -3)
  return v
end

local function create()
  local f = ns.Skin.CreateBox("WayfinderRouteMap")
  f:SetFrameStrata("TOOLTIP")
  f:SetSize(WIDTH + 12, 200)
  f:SetBackdropColor(0, 0, 0, 0.9)
  f.view = RouteMap.NewView(f, WIDTH)
  f.view.canvas:SetPoint("TOPLEFT", 6, -6)
  ns.Skin.Box(f)
  f:Hide()
  -- Goes away with the tooltip it belongs to.
  if GameTooltip.HookScript then GameTooltip:HookScript("OnHide", function() f:Hide() end) end
  return f
end

-- The route's steps and the points it passes, start first.
local function routeOf(r)
  local steps = (r.journey and r.journey.steps) or (r.route and r.route.steps)
  if not (steps and #steps > 0) then return nil end
  local points = { steps[1].from }
  for _, step in ipairs(steps) do points[#points + 1] = step.to end
  return steps, points
end

-- The zone if the whole route is in one, else its continent, else the world.
local function chooseMap(points)
  local instance, sameInstance = points[1].instance, true
  for _, p in ipairs(points) do
    if p.instance ~= instance then sameInstance = false end
  end
  if not sameInstance then return AZEROTH end
  local zone
  for i, p in ipairs(points) do
    local z = ns.Geo.ZoneAt(p.instance, p.wx, p.wy)
    if i == 1 then zone = z elseif z ~= zone then zone = nil end
    if not zone then break end
  end
  return zone or ns.Geo.Continents()[instance]
end

local function art(mapID)
  local layers = mapID and C_Map.GetMapArtLayers(mapID)
  local layer = layers and layers[1]
  local textures = layer and C_Map.GetMapArtLayerTextures(mapID, 1)
  if not (layer and textures and #textures > 0 and layer.layerWidth and layer.layerWidth > 0) then return nil end
  return layer, textures
end

local function texture(v, pool, i, layer)
  local t = pool[i]
  if not t then
    t = v.canvas:CreateTexture(nil, layer)
    pool[i] = t
  end
  t:Show()
  return t
end

local function line(v, i)
  local l = v.lines[i]
  if not l then
    l = v.canvas.CreateLine and v.canvas:CreateLine(nil, "OVERLAY")
    if not l then return nil end
    l:SetThickness(2)
    v.lines[i] = l
  end
  l:Show()
  return l
end

local function hideFrom(pool, n)
  for i = n, #pool do pool[i]:Hide() end
end

-- Draws `r`'s route (its journey or route) in view `v`; returns the map's
-- height when it did, else nil.
function RouteMap.Draw(v, r)
  if not (r and available()) then return nil end
  local steps, points = routeOf(r)
  if not steps then return nil end
  local WIDTH = v.width
  local mapID = chooseMap(points)
  local layer, textures = art(mapID)
  if not layer and mapID == AZEROTH then
    -- No world map art: the destination's continent, with what's on it.
    mapID = ns.Geo.Continents()[points[#points].instance]
    layer, textures = art(mapID)
  end
  if not layer then return nil end

  -- The area shown: a square (in map terms) around the route, at least
  -- MIN_VIEW of the map, kept inside the map.
  local xs, ys = {}, {}
  for _, p in ipairs(points) do
    local x, y = ns.Geo.MapPos(p, mapID)
    if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
      xs[#xs + 1], ys[#ys + 1] = x, y
    end
  end
  local view, x0, y0 = 1, 0, 0
  if #xs > 0 then
    local minX, maxX, minY, maxY = math.min(unpack(xs)), math.max(unpack(xs)), math.min(unpack(ys)), math.max(unpack(ys))
    view = math.min(1, math.max(MIN_VIEW, (maxX - minX) * ZOOM_MARGIN, (maxY - minY) * ZOOM_MARGIN))
    x0 = math.max(0, math.min(1 - view, (minX + maxX) / 2 - view / 2))
    y0 = math.max(0, math.min(1 - view, (minY + maxY) / 2 - view / 2))
  end

  local height = math.floor(WIDTH * layer.layerHeight / layer.layerWidth + 0.5)
  v.canvas:SetSize(WIDTH, height)
  -- The whole map at this zoom, shifted so the area shows; the canvas clips the rest.
  local scale = WIDTH / view / layer.layerWidth
  local offsetX, offsetY = x0 * layer.layerWidth * scale, y0 * layer.layerHeight * scale
  local columns = math.ceil(layer.layerWidth / layer.tileWidth)
  for i, file in ipairs(textures) do
    local t = texture(v, v.tiles, i, "BACKGROUND")
    t:SetTexture(file)
    t:SetSize(layer.tileWidth * scale, layer.tileHeight * scale)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", ((i - 1) % columns) * layer.tileWidth * scale - offsetX,
      -math.floor((i - 1) / columns) * layer.tileHeight * scale + offsetY)
  end
  hideFrom(v.tiles, #textures + 1)

  local function at(node)
    local x, y = ns.Geo.MapPos(node, mapID)
    if not x then return nil end
    local px, py = (x - x0) / view * WIDTH, (y - y0) / view * height
    if px < 0 or px > WIDTH or py < 0 or py > height then return nil end
    return px, -py
  end

  local drawn = 0
  for _, step in ipairs(steps) do
    local x1, y1 = at(step.from)
    local x2, y2 = at(step.to)
    if x1 and x2 then
      drawn = drawn + 1
      local l = line(v, drawn)
      if l then
        local c = LINE_COLOR[step.mode] or LINE_COLOR.walk
        l:SetColorTexture(c[1], c[2], c[3], c[4])
        l:SetStartPoint("TOPLEFT", v.canvas, x1, y1)
        l:SetEndPoint("TOPLEFT", v.canvas, x2, y2)
      end
    end
  end
  hideFrom(v.lines, drawn + 1)

  -- You, every stop (a journey's stops are on their last step), the destination.
  local marked = 0
  local function mark(node, kind)
    local x, y = at(node)
    if not x then return end
    marked = marked + 1
    local m = texture(v, v.marks, marked, "OVERLAY")
    local c = MARK_COLOR[kind]
    m:SetColorTexture(c[1], c[2], c[3], 1)
    local size = kind == "stop" and 5 or 7
    m:SetSize(size, size)
    m:ClearAllPoints()
    m:SetPoint("CENTER", v.canvas, "TOPLEFT", x, y)
  end
  mark(points[1], "start")
  for i, step in ipairs(steps) do
    if step.stop and i < #steps then mark(step.to, "stop") end
  end
  mark(points[#points], "goal")
  hideFrom(v.marks, marked + 1)

  v.label:SetText(ns.MapName(mapID) or "")
  RouteMap.mapID, RouteMap.lines, RouteMap.marks, RouteMap.view = mapID, drawn, marked, view
  return height
end

-- Draws `r`'s route under the tooltip; returns true when it did.
function RouteMap.Show(r, tooltip)
  if not (r and available()) then return false end
  frame = frame or create()
  local height = RouteMap.Draw(frame.view, r)
  if not height then
    frame:Hide()
    return false
  end
  frame:SetSize(WIDTH + 12, height + 12)
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", tooltip or GameTooltip, "BOTTOMLEFT", 0, -2)
  frame:Show()
  return true
end

function RouteMap.Hide()
  if frame then frame:Hide() end
end
