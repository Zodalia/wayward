local _, ns = ...

-- A small map under a result's tooltip (cards and list rows) with its
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
-- Legs that run between the same two places (there and back on one flight
-- path) sit side by side this far apart, their chevrons and icons staggered.
local LANE_GAP = LINE_THICKNESS + 2 * OUTLINE + 1
local SAME_PLACE = 3     -- pixels apart at most for two ends to be one place
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

-- The part of segment (x1, y1)-(x2, y2) inside the box 0..w across and
-- 0..-h down (Liang-Barsky), or nil when none of it is.
local function clipped(x1, y1, x2, y2, w, h)
  local t0, t1 = 0, 1
  local dx, dy = x2 - x1, y2 - y1
  for _, e in ipairs({ { -dx, x1 }, { dx, w - x1 }, { -dy, y1 + h }, { dy, -y1 } }) do
    local p, q = e[1], e[2]
    if p == 0 then
      if q < 0 then return nil end
    else
      local t = q / p
      if p < 0 then
        if t > t1 then return nil elseif t > t0 then t0 = t end
      else
        if t < t0 then return nil elseif t < t1 then t1 = t end
      end
    end
  end
  return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
end

-- The part of segment (x1, y1)-(x2, y2) inside the circle of radius r round
-- (cx, cy), or nil when none of it is.
local function clippedRound(x1, y1, x2, y2, cx, cy, r)
  local dx, dy = x2 - x1, y2 - y1
  local fx, fy = x1 - cx, y1 - cy
  local a = dx * dx + dy * dy
  local c = fx * fx + fy * fy - r * r
  if a == 0 then
    if c > 0 then return nil end
    return x1, y1, x2, y2
  end
  local b = 2 * (fx * dx + fy * dy)
  local d = b * b - 4 * a * c
  if d < 0 then return nil end
  d = math.sqrt(d)
  local t0, t1 = math.max(0, (-b - d) / (2 * a)), math.min(1, (-b + d) / (2 * a))
  if t0 > t1 then return nil end
  return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
end

-- The steps of the active journey (or directions) still to go, from the one
-- you're on, and whether they start from `here` (where you stand): a walk
-- you're on starts where you stand, not where the step began. Nil when
-- there's nothing to go.
function RouteMap.Rest(here)
  local a = ns.Nav.active
  local steps = a and a.route and a.route.steps
  if not steps then return nil end
  local out = {}
  for k = a.index or 1, #steps do out[#out + 1] = steps[k] end
  if #out == 0 then return nil end
  local first = out[1]
  if first.mode == "walk" and here and first.from and here.instance == first.from.instance then
    local copy = {}
    for key, value in pairs(first) do copy[key] = value end
    copy.from = here
    out[1] = copy
    return out, true
  end
  return out, false
end

-- The number each of `steps` gets on the maps, { [i] = number }: each stop
-- (a journey's stops are on their last step) in order, then the destination;
-- a destination with no stop before it has none. The journey overview
-- numbers its stops the same way, so the list and the maps agree.
function RouteMap.StepNumbers(steps)
  local out, number = {}, 0
  for i, step in ipairs(steps) do
    if step.stop and i < #steps then
      number = number + 1
      out[i] = number
    end
  end
  if #steps > 0 and number > 0 then out[#steps] = number + 1 end
  return out
end

-- Draws the route through `points` (`steps`' legs, start first) in view `v`:
-- the legs with their chevrons and travel icons, you, and the numbered stops.
-- `at(node)` places a node on v's canvas (x right, y down as negative), or
-- nil when it isn't there. `opts`:
--   size  everything this many times its size on the small maps (1)
--   clip  { w, h }: legs are cut at this box, and nothing outside it marked
--         (for an `at` that places nodes beyond what shows); with `radius`,
--         at the circle that wide round the box's middle instead (a round
--         minimap)
--   you   false: no arrow or start badge (a map that shows you already)
--   alpha function(i): how opaque steps[i]'s leg, chevrons and icon are (1);
--         a stop's badge fades less (the square root of its step's)
--   skipLeg  steps[skipLeg]'s leg isn't drawn (its stop is still marked)
--   limit    only the first `limit` steps are drawn and their stops marked
--            (numbered as in the whole route; the destination only if it's
--            among them)
-- Legs between the same two places, either way, are drawn side by side.
-- Returns what it drew (lines, chevrons, marks, numbers, lanes, ...), also
-- kept as v.stats, for tests.
function RouteMap.DrawRoute(v, steps, points, at, opts)
  opts = opts or {}
  local k = opts.size or 1
  local box = opts.clip
  local limit = opts.limit or #steps
  local cx, cy = box and box.w / 2, box and -box.h / 2
  local function inside(x, y)
    if not (x and box) then return x ~= nil end
    if box.radius then return (x - cx) ^ 2 + (y - cy) ^ 2 <= box.radius ^ 2 end
    return x >= 0 and x <= box.w and y <= 0 and y >= -box.h
  end

  local function alphaOf(i)
    local a = opts.alpha and opts.alpha(i) or 1
    return math.max(0, math.min(1, a))
  end

  -- A stroke from (ax, ay) to (bx, by) in colour c over its outline, `a`
  -- opaque; the route's legs are on sublevels 1-2, chevrons over them on 3-4.
  local function stroke(edges, cores, i, sublevel, ax, ay, bx, by, c, a)
    local edge, core = line(v, edges, i, sublevel), line(v, cores, i, sublevel + 1)
    if not core then return end
    edge:SetThickness((LINE_THICKNESS + 2 * OUTLINE) * k)
    edge:SetVertexColor(OUTLINE_COLOR[1], OUTLINE_COLOR[2], OUTLINE_COLOR[3], OUTLINE_COLOR[4] * a)
    core:SetThickness(LINE_THICKNESS * k)
    core:SetVertexColor(c[1], c[2], c[3], a)
    for _, seg in ipairs({ edge, core }) do
      seg:SetStartPoint("TOPLEFT", v.canvas, ax, ay)
      seg:SetEndPoint("TOPLEFT", v.canvas, bx, by)
    end
  end

  -- Where each leg runs, before any clipping.
  local ends = {}
  for i, step in ipairs(steps) do
    local x1, y1 = at(step.from)
    local x2, y2 = at(step.to)
    if x1 and x2 and i ~= opts.skipLeg and i <= limit then ends[i] = { x1, y1, x2, y2 } end
  end

  -- Legs between the same two places, either way round, share the way in
  -- lanes side by side: each has its lane's offset across the first one's
  -- direction, a `shift` (-0.5..0.5 of the chevron spacing) and a `spread`
  -- (in icon widths) to stagger its chevrons and icon along its own way.
  local near = SAME_PLACE * k
  local function same(ax, ay, bx, by)
    return math.abs(ax - bx) <= near and math.abs(ay - by) <= near
  end
  local lanes, laned = {}, 0
  for i = 1, #steps do
    local e = ends[i]
    if e and not lanes[i] and not same(e[1], e[2], e[3], e[4]) then
      local group = { { i = i, flip = false } }
      for j = i + 1, #steps do
        local o = ends[j]
        if o and not lanes[j] then
          if same(e[1], e[2], o[1], o[2]) and same(e[3], e[4], o[3], o[4]) then
            group[#group + 1] = { i = j, flip = false }
          elseif same(e[1], e[2], o[3], o[4]) and same(e[3], e[4], o[1], o[2]) then
            group[#group + 1] = { i = j, flip = true }
          end
        end
      end
      if #group > 1 then
        local dx, dy = e[3] - e[1], e[4] - e[2]
        local length = math.sqrt(dx * dx + dy * dy)
        local nx, ny = -dy / length, dx / length
        local n = #group
        for m, g in ipairs(group) do
          local place = m - (n + 1) / 2
          local sign = g.flip and -1 or 1
          lanes[g.i] = { dx = nx * place * LANE_GAP * k, dy = ny * place * LANE_GAP * k,
            shift = sign * (m / (n + 1) - 0.5), spread = sign * place }
          laned = laned + 1
        end
      end
    end
  end

  -- Each leg, with chevrons along it pointing the way you go.
  local drawn, chevrons, icons = 0, 0, 0
  local stats = { hearthShown = false, iconFiles = {}, alphas = {}, legs = {}, iconAt = {}, chevronAt = {} }
  local iconSize = MODE_ICON_SIZE * k
  for i, step in ipairs(steps) do
    local e, lane = ends[i], lanes[i]
    local x1, y1, x2, y2
    if e then
      x1, y1, x2, y2 = e[1], e[2], e[3], e[4]
      if lane then
        x1, y1, x2, y2 = x1 + lane.dx, y1 + lane.dy, x2 + lane.dx, y2 + lane.dy
      end
      if box and box.radius then x1, y1, x2, y2 = clippedRound(x1, y1, x2, y2, cx, cy, box.radius)
      elseif box then x1, y1, x2, y2 = clipped(x1, y1, x2, y2, box.w, box.h) end
    end
    if x1 and x2 then
      drawn = drawn + 1
      local a = alphaOf(i)
      stats.alphas[drawn], stats.legs[drawn] = a, { x1, y1, x2, y2 }
      local c = LINE_COLOR[step.mode] or LINE_COLOR.walk
      stroke(v.edges, v.lines, drawn, 1, x1, y1, x2, y2, c, a)
      local dx, dy = x2 - x1, y2 - y1
      local length = math.sqrt(dx * dx + dy * dy)
      -- A flight, hearthstone or boat says so with its icon mid-leg (legs
      -- sharing the way have theirs a little apart); its chevrons go either
      -- side of it.
      local icon = RouteMap.TravelIcon(step)
      local iconAt = length / 2
      if lane then
        iconAt = math.max(0, math.min(length, iconAt + lane.spread * (iconSize + 4)))
      end
      if icon and length > 0 then
        icons = icons + 1
        local ic = modeIcon(v, icons)
        ic.border:SetSize(iconSize + 2, iconSize + 2)
        ic.icon:SetSize(iconSize, iconSize)
        ic.icon:SetTexture(icon)
        -- Icons have a border baked in to trim; the gossip one doesn't.
        if icon:find(ICONS, 1, true) then ic.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        else ic.icon:SetTexCoord(0, 1, 0, 1) end
        stats.iconFiles[icons] = icon
        ic.border:ClearAllPoints()
        local ix, iy = x1 + dx * iconAt / length, y1 + dy * iconAt / length
        ic.border:SetPoint("CENTER", v.pins, "TOPLEFT", ix, iy)
        stats.iconAt[icons] = { ix, iy }
        ic.border:SetAlpha(a)
        ic.icon:SetAlpha(a)
        if step.mode == "hearth" then stats.hearthShown = true end
      end
      local n = math.floor(length / (CHEVRON_EVERY * k))
      if length >= CHEVRON_MIN * k then n = math.max(n, icon and 2 or 1) end
      if n > 0 then
        local ux, uy = dx / length, dy / length -- along the leg
        local nx, ny = -uy, ux                  -- across it
        local depth, spread = CHEVRON_LENGTH * k, CHEVRON_SPREAD * k
        -- Sharing the way, each lane's chevrons fall between the others'.
        local shift = lane and lane.shift or 0
        for j = 1, n do
          local along = length * (j - 0.5 + shift) / n
          if not (icon and math.abs(along - iconAt) < iconSize) then
            local px, py = x1 + ux * along, y1 + uy * along
            local tx, ty = px + ux * depth, py + uy * depth
            local bx, by = px - ux * depth, py - uy * depth
            stats.chevronAt[#stats.chevronAt + 1] = { px, py }
            for _, side in ipairs({ 1, -1 }) do
              chevrons = chevrons + 1
              stroke(v.chevronEdges, v.chevronLines, chevrons, 3,
                bx + nx * spread * side, by + ny * spread * side, tx, ty, c, a)
            end
          end
        end
      end
    end
  end
  for i = icons + 1, #v.modeIcons do v.modeIcons[i].border:Hide(); v.modeIcons[i].icon:Hide() end
  hideFrom(v.edges, drawn + 1)
  hideFrom(v.lines, drawn + 1)
  hideFrom(v.chevronEdges, chevrons + 1)
  hideFrom(v.chevronLines, chevrons + 1)

  -- You (the minimap arrow, facing your way), then each stop numbered in
  -- order (a journey's stops are on their last step) up to the destination.
  local marked, numbers = 0, {}
  local fontSize = math.floor(9 * k + 0.5)
  local function mark(node, kind, number, a)
    local x, y = at(node)
    if not inside(x, y) then return end
    marked = marked + 1
    numbers[marked] = number or false
    local b = badge(v, marked)
    a = a or 1
    b.disc:SetAlpha(a); b.ring:SetAlpha(a); b.number:SetAlpha(a)
    local c = MARK_COLOR[kind]
    b.disc:SetSize(BADGE_DISC_SIZE * k, BADGE_DISC_SIZE * k)
    b.disc:SetVertexColor(c[1] * 0.55, c[2] * 0.55, c[3] * 0.55, 1)
    b.ring:SetSize(RING_SIZE * k, RING_SIZE * k)
    b.ring:ClearAllPoints()
    b.ring:SetPoint("TOPLEFT", v.pins, "TOPLEFT", x - RING_CENTER_X * RING_SIZE * k, y + RING_CENTER_Y * RING_SIZE * k)
    b.disc:ClearAllPoints()
    b.disc:SetPoint("CENTER", v.pins, "TOPLEFT", x, y)
    if b.fontSize ~= fontSize and b.number.SetFont and STANDARD_TEXT_FONT then
      b.number:SetFont(STANDARD_TEXT_FONT, fontSize, "OUTLINE")
      b.fontSize = fontSize
    end
    b.number:SetText(number and tostring(number) or "")
    b.number:ClearAllPoints()
    b.number:SetPoint("CENTER", v.pins, "TOPLEFT", x + 0.5 * k, y)
  end
  v.you = v.you or v.pins:CreateTexture(nil, "OVERLAY")
  v.you:Hide()
  if opts.you ~= false then
    local facing = points[1].label == "You" and GetPlayerFacing and GetPlayerFacing()
    local yx, yy = at(points[1])
    if facing and inside(yx, yy) then
      v.you:SetTexture(PLAYER_ARROW)
      v.you:SetSize(18 * k, 18 * k)
      if v.you.SetRotation then v.you:SetRotation(facing) end
      v.you:ClearAllPoints()
      v.you:SetPoint("CENTER", v.pins, "TOPLEFT", yx, yy)
      v.you:Show()
    else
      mark(points[1], "start")
    end
  end
  local numberOf = RouteMap.StepNumbers(steps)
  for i, step in ipairs(steps) do
    if step.stop and i < #steps and i <= limit then
      mark(step.to, "stop", numberOf[i], math.sqrt(alphaOf(i)))
    end
  end
  if #steps <= limit then
    mark(points[#points], "goal", numberOf[#steps], math.sqrt(alphaOf(#steps)))
  end
  for i = marked + 1, #v.marks do
    local b = v.marks[i]
    b.disc:Hide(); b.ring:Hide(); b.number:Hide()
  end
  stats.lines, stats.chevrons, stats.modeIcons, stats.marks, stats.numbers = drawn, chevrons / 2, icons, marked, numbers
  stats.lanes = laned
  stats.youShown = v.you:IsShown()
  v.stats = stats
  return stats
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
  local stats = RouteMap.DrawRoute(v, steps, points, at)
  RouteMap.hearthShown, RouteMap.iconFiles, RouteMap.modeIcons = stats.hearthShown, stats.iconFiles, stats.modeIcons
  RouteMap.youShown, RouteMap.chevrons, RouteMap.numbers = stats.youShown, stats.chevrons, stats.numbers

  v.label:SetText(ns.MapName(mapID) or "")
  RouteMap.mapID, RouteMap.lines, RouteMap.marks, RouteMap.view = mapID, stats.lines, stats.marks, view
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
