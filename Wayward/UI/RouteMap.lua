local _, ns = ...

-- A small map under a result's tooltip (cards and side panel rows) with its
-- route drawn on it: the smallest map that holds the whole route (a zone,
-- else the continent, else the world map), from the game's own map art,
-- zoomed in on the route (with some room around it).
-- Walking is white, flights light blue, boats and the like deeper blue, a
-- hearthstone purple (each with its icon mid-leg), with chevrons along
-- each leg pointing the way; you're an arrow facing your way, and the stops
-- and destination are numbered badges in the order you reach them. Shown
-- only when the client has the map art API.

local RouteMap = {}
ns.RouteMap = RouteMap

local AZEROTH = 947
local WIDTH = 280
local ZOOM_MARGIN = 1.5  -- the shown area is this much bigger than the route
local MIN_VIEW = 0.12    -- the closest zoom: this share of the map's width
local LINE_COLOR = { walk = { 1, 1, 1, 0.9 }, fly = { 0.45, 0.8, 1, 1 }, transport = { 0.25, 0.5, 1, 1 },
  hearth = { 0.75, 0.5, 1, 0.6 } }
local MARK_COLOR = { start = { 0.3, 1, 0.3 }, stop = { 1, 0.82, 0 }, goal = { 1, 0.3, 0.2 } }
-- An icon for each way of travel (by faction where it differs), best first:
-- not every client has every icon, so the first that loads is used.
local ICONS = "Interface\\Icons\\"
local MODE_ICONS = {
  fly = { Alliance = { ICONS .. "Ability_Mount_Gryphon_01", "Interface\\GossipFrame\\TaxiGossipIcon" },
    Horde = { ICONS .. "Ability_Mount_Wyvern_01", "Interface\\GossipFrame\\TaxiGossipIcon" } },
  hearth = { ICONS .. "INV_Misc_Rune_01" },
  -- Classic Era has no ship or zeppelin icon: there, a spyglass and the Horde airship.
  boat = { ICONS .. "INV_AllianceShipMountClassic", ICONS .. "INV_AllianceShipMount", ICONS .. "INV_Misc_Anchor",
    ICONS .. "INV_Misc_Spyglass_02", ICONS .. "INV_Misc_Map_01" },
  zeppelin = { ICONS .. "INV_HordeZeppelinMountClassic", ICONS .. "INV_HordeZeppelinMount",
    ICONS .. "Achievement_Dungeon_HordeAirship", ICONS .. "Ability_Mount_Gyrocoptor", ICONS .. "INV_Misc_Map_01" },
  tram = { ICONS .. "Trade_Engineering" },
  portal = { Alliance = { ICONS .. "Spell_Arcane_PortalStormwind", ICONS .. "Spell_Arcane_Blink" },
    Horde = { ICONS .. "Spell_Arcane_PortalOrgrimmar", ICONS .. "Spell_Arcane_Blink" } },
  transport = { ICONS .. "INV_Misc_Map_01" },
}
local MODE_ICON_SIZE = 14

-- A step's travel icon (the HUD's too), or nil for walking: by its mode, or
-- what carries you (boat, zeppelin, ...), for your faction where they
-- differ. The first this client has (SetTexture takes a missing file
-- without a word and shows nothing); the last is the one to fall back on.
function RouteMap.TravelIcon(step)
  local icons = MODE_ICONS[step.mode == "transport" and step.kind or step.mode]
    or (step.mode == "transport" and MODE_ICONS.transport)
  if not icons then return nil end
  if not icons[1] then
    icons = icons[UnitFactionGroup and UnitFactionGroup("player") or "Alliance"] or icons.Alliance
  end
  for _, file in ipairs(icons) do
    if not GetFileIDFromPath or GetFileIDFromPath(file) then return file end
  end
  return icons[#icons]
end
-- Lines and chevrons are solid colour over a dark outline, which reads on
-- any map art. Classic's own art for the rest: the minimap's player arrow,
-- and for badges a round portrait mask as the disc inside the minimap
-- tracking button's gold ring.
local LINE_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local LINE_THICKNESS = 2
local OUTLINE = 2        -- pixels of dark outline either side
local OUTLINE_COLOR = { 0, 0, 0, 0.85 }
local CHEVRON_EVERY = 45 -- pixels of line per chevron
local CHEVRON_MIN = 20   -- legs shorter than this get none
local CHEVRON_LENGTH, CHEVRON_SPREAD = 4, 5 -- a chevron's depth and half width
local PLAYER_ARROW = "Interface\\Minimap\\MinimapArrow"
local BADGE_DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local BADGE_RING = "Interface\\Minimap\\MiniMap-TrackingBorder"
local BADGE_DISC_SIZE = 13
-- The ring's art is off-centre in its file: drawn 53 wide it rings a 31-wide
-- button from the top left, round the point (17, 15) (as LibDBIcon does).
local RING_SIZE = 34
local RING_CENTER_X, RING_CENTER_Y = 17 / 53, 15 / 53

local frame -- the tooltip's map
local unpack = unpack or table.unpack

local function available()
  return C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures and C_Map.GetMapPosFromWorldPos
end

-- A map view: a clipped canvas `width` wide on `parent`, with its own pools.
function RouteMap.NewView(parent, width)
  local v = { width = width, tiles = {}, edges = {}, lines = {}, chevronEdges = {}, chevronLines = {}, modeIcons = {}, marks = {} }
  v.canvas = CreateFrame("Frame", nil, parent)
  v.canvas:SetSize(width, math.floor(width * 2 / 3))
  if v.canvas.SetClipsChildren then v.canvas:SetClipsChildren(true) end
  -- Badges sit on their own layer, over the lines and chevrons.
  v.pins = CreateFrame("Frame", nil, v.canvas)
  v.pins:SetAllPoints(v.canvas)
  v.pins:SetFrameLevel((v.canvas:GetFrameLevel() or 0) + 2)
  v.label = v.canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.label:SetPoint("TOPLEFT", 4, -3)
  return v
end

local function create()
  local f = ns.Skin.CreateBox("WaywardRouteMap")
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

local function art(mapID)
  local layers = mapID and C_Map.GetMapArtLayers(mapID)
  local layer = layers and layers[1]
  local textures = layer and C_Map.GetMapArtLayerTextures(mapID, 1)
  if not (layer and textures and #textures > 0 and layer.layerWidth and layer.layerWidth > 0) then return nil end
  return layer, textures
end

-- Whether every point is on map `mapID`.
local function holds(mapID, points)
  for _, p in ipairs(points) do
    local x, y = ns.Geo.MapPos(p, mapID)
    if not (x and x >= 0 and x <= 1 and y >= 0 and y <= 1) then return false end
  end
  return true
end

-- A zone map that holds the whole route, else its continent, else the world.
-- The zones tried are the ones the points are in or were placed on,
-- destination first: a route can pass a point between zones, or one the
-- client can't place, and still be all on one zone's map.
local function chooseMap(points)
  local instance = points[1].instance
  for _, p in ipairs(points) do
    if p.instance ~= instance then return AZEROTH end
  end
  local continent = ns.Geo.Continents()[instance]
  local tried = { [AZEROTH] = true }
  if continent then tried[continent] = true end
  for i = #points, 1, -1 do
    local p = points[i]
    for _, zone in ipairs({ ns.Geo.ZoneAt(p.instance, p.wx, p.wy) or false, p.mapID or false }) do
      if zone and not tried[zone] then
        tried[zone] = true
        if holds(zone, points) and art(zone) then return zone end
      end
    end
  end
  return continent
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

local function line(v, pool, i, sublevel)
  local l = pool[i]
  if not l then
    l = v.canvas.CreateLine and v.canvas:CreateLine(nil, "ARTWORK", nil, sublevel)
    if not l then return nil end
    l:SetTexture(LINE_TEXTURE)
    pool[i] = l
  end
  l:Show()
  return l
end

-- A travel icon in a thin dark frame, under the badges.
local function modeIcon(v, i)
  local m = v.modeIcons[i]
  if not m then
    m = {}
    m.border = v.pins:CreateTexture(nil, "BACKGROUND")
    m.border:SetColorTexture(0, 0, 0, 0.9)
    m.border:SetSize(MODE_ICON_SIZE + 2, MODE_ICON_SIZE + 2)
    m.icon = v.pins:CreateTexture(nil, "BORDER")
    m.icon:SetSize(MODE_ICON_SIZE, MODE_ICON_SIZE)
    m.icon:SetPoint("CENTER", m.border, "CENTER")
    v.modeIcons[i] = m
  end
  m.border:Show(); m.icon:Show()
  return m
end

-- A numbered badge: a disc in the mark's colour inside the minimap's gold
-- tracking ring, over the lines.
local function badge(v, i)
  local b = v.marks[i]
  if not b then
    b = {}
    b.disc = v.pins:CreateTexture(nil, "ARTWORK")
    b.disc:SetTexture(BADGE_DISC)
    b.disc:SetSize(BADGE_DISC_SIZE, BADGE_DISC_SIZE)
    b.ring = v.pins:CreateTexture(nil, "ARTWORK", nil, 2)
    b.ring:SetTexture(BADGE_RING)
    b.ring:SetSize(RING_SIZE, RING_SIZE)
    b.number = v.pins:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if b.number.SetFont and STANDARD_TEXT_FONT then b.number:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE") end
    v.marks[i] = b
  end
  b.disc:Show(); b.ring:Show(); b.number:Show()
  return b
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

  -- What you've explored: a zone's base art is bare parchment, and the
  -- terrain comes in pieces as you uncover it, as on the world map. Each
  -- piece is cut into tiles; edge tiles sit in power-of-two files.
  local explored = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
    and C_MapExplorationInfo.GetExploredMapTextures(mapID)
  v.overlays = v.overlays or {}
  local overlays = 0
  local function fileSize(pixels)
    local size = 16
    while size < pixels do size = size * 2 end
    return size
  end
  for _, piece in ipairs(explored or {}) do
    if not piece.isShownByMouseOver and piece.fileDataIDs then
      local wide = math.ceil(piece.textureWidth / layer.tileWidth)
      local tall = math.ceil(piece.textureHeight / layer.tileHeight)
      for row = 1, tall do
        local h, fileH = layer.tileHeight, layer.tileHeight
        if row == tall then
          h = piece.textureHeight % layer.tileHeight
          if h == 0 then h = layer.tileHeight end
          fileH = fileSize(h)
        end
        for col = 1, wide do
          local w, fileW = layer.tileWidth, layer.tileWidth
          if col == wide then
            w = piece.textureWidth % layer.tileWidth
            if w == 0 then w = layer.tileWidth end
            fileW = fileSize(w)
          end
          local file = piece.fileDataIDs[(row - 1) * wide + col]
          if file then
            overlays = overlays + 1
            local t = texture(v, v.overlays, overlays, "BORDER")
            t:SetTexture(file)
            t:SetTexCoord(0, w / fileW, 0, h / fileH)
            t:SetSize(w * scale, h * scale)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", (piece.offsetX + layer.tileWidth * (col - 1)) * scale - offsetX,
              -(piece.offsetY + layer.tileHeight * (row - 1)) * scale + offsetY)
          end
        end
      end
    end
  end
  hideFrom(v.overlays, overlays + 1)

  local function at(node)
    local x, y = ns.Geo.MapPos(node, mapID)
    if not x then return nil end
    local px, py = (x - x0) / view * WIDTH, (y - y0) / view * height
    if px < 0 or px > WIDTH or py < 0 or py > height then return nil end
    return px, -py
  end

  -- A stroke from (ax, ay) to (bx, by) in colour c over its outline; the
  -- route's legs are on sublevels 1-2, chevrons over them on 3-4.
  local function stroke(edges, cores, i, sublevel, ax, ay, bx, by, c)
    local edge, core = line(v, edges, i, sublevel), line(v, cores, i, sublevel + 1)
    if not core then return end
    edge:SetThickness(LINE_THICKNESS + 2 * OUTLINE)
    edge:SetVertexColor(unpack(OUTLINE_COLOR))
    core:SetThickness(LINE_THICKNESS)
    core:SetVertexColor(c[1], c[2], c[3], 1)
    for _, seg in ipairs({ edge, core }) do
      seg:SetStartPoint("TOPLEFT", v.canvas, ax, ay)
      seg:SetEndPoint("TOPLEFT", v.canvas, bx, by)
    end
  end

  -- Each leg, with chevrons along it pointing the way you go.
  local drawn, chevrons, icons = 0, 0, 0
  RouteMap.hearthShown, RouteMap.iconFiles = false, {}
  for _, step in ipairs(steps) do
    local x1, y1 = at(step.from)
    local x2, y2 = at(step.to)
    if x1 and x2 then
      drawn = drawn + 1
      local c = LINE_COLOR[step.mode] or LINE_COLOR.walk
      stroke(v.edges, v.lines, drawn, 1, x1, y1, x2, y2, c)
      local dx, dy = x2 - x1, y2 - y1
      local length = math.sqrt(dx * dx + dy * dy)
      -- A flight, hearthstone or boat says so with its icon mid-leg; its
      -- chevrons go either side of it.
      local icon = RouteMap.TravelIcon(step)
      if icon then
        icons = icons + 1
        local ic = modeIcon(v, icons)
        ic.icon:SetTexture(icon)
        -- Icons have a border baked in to trim; the gossip one doesn't.
        if icon:find(ICONS, 1, true) then ic.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else ic.icon:SetTexCoord(0, 1, 0, 1) end
        RouteMap.iconFiles[icons] = icon
        ic.border:ClearAllPoints()
        ic.border:SetPoint("CENTER", v.pins, "TOPLEFT", x1 + dx / 2, y1 + dy / 2)
        if step.mode == "hearth" then RouteMap.hearthShown = true end
      end
      local n = math.floor(length / CHEVRON_EVERY)
      if length >= CHEVRON_MIN then n = math.max(n, icon and 2 or 1) end
      if n > 0 then
        local ux, uy = dx / length, dy / length -- along the leg
        local nx, ny = -uy, ux                  -- across it
        for k = 1, n do
          local along = length * (k - 0.5) / n
          if not (icon and math.abs(along - length / 2) < MODE_ICON_SIZE) then
            local px, py = x1 + ux * along, y1 + uy * along
            local tx, ty = px + ux * CHEVRON_LENGTH, py + uy * CHEVRON_LENGTH
            local bx, by = px - ux * CHEVRON_LENGTH, py - uy * CHEVRON_LENGTH
            for _, side in ipairs({ 1, -1 }) do
              chevrons = chevrons + 1
              stroke(v.chevronEdges, v.chevronLines, chevrons, 3,
                bx + nx * CHEVRON_SPREAD * side, by + ny * CHEVRON_SPREAD * side, tx, ty, c)
            end
          end
        end
      end
    end
  end
  for i = icons + 1, #v.modeIcons do v.modeIcons[i].border:Hide(); v.modeIcons[i].icon:Hide() end
  RouteMap.modeIcons = icons
  hideFrom(v.edges, drawn + 1)
  hideFrom(v.lines, drawn + 1)
  hideFrom(v.chevronEdges, chevrons + 1)
  hideFrom(v.chevronLines, chevrons + 1)
  chevrons = chevrons / 2

  -- You (the minimap arrow, facing your way), then each stop numbered in
  -- order (a journey's stops are on their last step) up to the destination.
  local marked, numbers = 0, {}
  local function mark(node, kind, number)
    local x, y = at(node)
    if not x then return end
    marked = marked + 1
    numbers[marked] = number or false
    local b = badge(v, marked)
    local c = MARK_COLOR[kind]
    b.disc:SetVertexColor(c[1] * 0.55, c[2] * 0.55, c[3] * 0.55, 1)
    b.ring:ClearAllPoints()
    b.ring:SetPoint("TOPLEFT", v.pins, "TOPLEFT", x - RING_CENTER_X * RING_SIZE, y + RING_CENTER_Y * RING_SIZE)
    b.disc:ClearAllPoints()
    b.disc:SetPoint("CENTER", v.pins, "TOPLEFT", x, y)
    b.number:SetText(number and tostring(number) or "")
    b.number:ClearAllPoints()
    b.number:SetPoint("CENTER", v.pins, "TOPLEFT", x + 0.5, y)
  end
  local facing = points[1].label == "You" and GetPlayerFacing and GetPlayerFacing()
  v.you = v.you or v.pins:CreateTexture(nil, "OVERLAY")
  v.you:Hide()
  local yx, yy = at(points[1])
  if facing and yx then
    v.you:SetTexture(PLAYER_ARROW)
    v.you:SetSize(18, 18)
    if v.you.SetRotation then v.you:SetRotation(facing) end
    v.you:ClearAllPoints()
    v.you:SetPoint("CENTER", v.pins, "TOPLEFT", yx, yy)
    v.you:Show()
  else
    mark(points[1], "start")
  end
  local number = 0
  for i, step in ipairs(steps) do
    if step.stop and i < #steps then
      number = number + 1
      mark(step.to, "stop", number)
    end
  end
  mark(points[#points], "goal", number > 0 and number + 1 or nil)
  for i = marked + 1, #v.marks do
    local b = v.marks[i]
    b.disc:Hide(); b.ring:Hide(); b.number:Hide()
  end
  RouteMap.youShown, RouteMap.chevrons, RouteMap.numbers = v.you:IsShown(), chevrons, numbers


  v.label:SetText(ns.MapName(mapID) or "")
  RouteMap.mapID, RouteMap.lines, RouteMap.marks, RouteMap.view = mapID, drawn, marked, view
  RouteMap.overlays = overlays
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
