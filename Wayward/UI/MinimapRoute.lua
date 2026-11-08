local _, ns = ...

-- Your journey on the minimap: the step you're on and the next, drawn
-- as on the world map (UI/WorldMapRoute.lua: a colour for each way of
-- travel, chevrons pointing the way, travel icons, the stops numbered in
-- order), smaller, round the minimap's own arrow; the next step fainter. The
-- rest of the journey is the world map's to show. It
-- follows you as you walk, turns with a minimap that turns, keeps to the
-- minimap's zoom (indoors too) and is cut at its rim, round or square. Plain
-- directions show too. Once you're in the area of the objectives you're on,
-- the line there goes (you're there: the minimap shows the area); the stop's
-- badge and the way on stay.
-- The options or /ww minimap journey turn it off.

local MinimapRoute = {}
ns.MinimapRoute = MinimapRoute

local SIZE = 0.8      -- lines and badges this much of their size on the small maps
local RIM = 3         -- pixels kept clear inside a round minimap's rim
local EVERY = 1 / 30  -- seconds between looks at where you are
local MOVED = 0.25    -- yards you move before it's drawn again
local TURNED = 0.01   -- radians a turning minimap turns before it's drawn again
local SHOWN = 2       -- steps drawn: the one you're on and the next
local FADE_PER_STEP = 0.15 -- each step after the one you're on this much fainter
local FAINTEST = 0.3       -- the furthest steps fade no further than this

-- How opaque the i-th step still to go is drawn: the one you're on in full,
-- the ones after fading step by step (sooner than on the world map: the
-- minimap is small, and the step you're on is what it's for).
function MinimapRoute.Alpha(i)
  return math.max(FAINTEST, 1 - FADE_PER_STEP * math.max(0, i - 1))
end

-- How many yards across the minimap shows at each zoom, outdoors and in (as
-- HereBeDragons measures it).
local YARDS = {
  outdoor = { [0] = 466 + 2 / 3, [1] = 400, [2] = 333 + 1 / 3, [3] = 266 + 2 / 3, [4] = 200, [5] = 133 + 1 / 3 },
  indoor = { [0] = 300, [1] = 240, [2] = 180, [3] = 120, [4] = 80, [5] = 50 },
}

local driver, view
local drawn -- what the last drawing was drawn for: where you were, facing, the minimap's scale and shape
local since = 0

local function enabled()
  return ns.db and ns.db.settings.minimapRoute ~= false
end

local function cvar(name)
  local get = (C_CVar and C_CVar.GetCVar) or GetCVar
  return get and get(name)
end

-- Whether the minimap is showing the indoor view. Its zoom is kept apart
-- indoors and out; when the two differ, the zoom it's at says which, else the
-- game's word for where you are.
local function indoors()
  local zoom = Minimap.GetZoom and Minimap:GetZoom()
  local outside, inside = tonumber(cvar("minimapZoom")), tonumber(cvar("minimapInsideZoom"))
  if zoom and outside and inside and outside ~= inside then return zoom == inside end
  return IsIndoors and IsIndoors() and true or false
end

-- How many yards across the minimap shows now.
function MinimapRoute.Yards()
  local sizes = indoors() and YARDS.indoor or YARDS.outdoor
  local zoom = Minimap.GetZoom and Minimap:GetZoom() or 0
  return sizes[zoom] or sizes[0]
end

-- Which way up the minimap is: 0 (north up) unless it turns with you.
local function turn()
  if cvar("rotateMinimap") ~= "1" then return 0 end
  local facing = GetPlayerFacing and GetPlayerFacing()
  if facing == nil or (type(issecretvalue) == "function" and issecretvalue(facing)) then return 0 end
  return facing
end

-- Square for addons that make it so (they say with GetMinimapShape), else round.
local function round()
  local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
  return shape ~= "SQUARE"
end

-- Whether you're in the area of the stop you're on (Nav.InArea).
local function inArea()
  return ns.Nav and ns.Nav.InArea and ns.Nav.InArea() or false
end

-- The minimap as it is now: its size, how far it sees, which way up, its
-- shape, and whether you're in the area of the stop you're on.
local function look(here)
  local w, h = Minimap:GetWidth(), Minimap:GetHeight()
  return { here = here, w = w, h = h, yards = MinimapRoute.Yards(), turn = turn(), round = round(),
    inArea = inArea() }
end

local function changed(now)
  local was = drawn
  if not was then return now.here ~= nil end
  if (was.here == nil) ~= (now.here == nil) then return true end
  if now.here and (now.here.instance ~= was.here.instance or ns.Geo.Distance(now.here, was.here) >= MOVED) then
    return true
  end
  return math.abs(now.turn - was.turn) >= TURNED or now.yards ~= was.yards or now.w ~= was.w or now.h ~= was.h
    or now.round ~= was.round or now.inArea ~= was.inArea
end

local function newView()
  local v = ns.RouteMap.NewView(Minimap, Minimap:GetWidth() or 140)
  v.canvas:ClearAllPoints()
  v.canvas:SetAllPoints(Minimap)
  local level = (Minimap:GetFrameLevel() or 0) + 1
  v.canvas:SetFrameLevel(level)
  v.pins:SetFrameLevel(level + 2)
  v.label:Hide()
  return v
end

local function clear()
  drawn = nil
  if view then view.canvas:Hide() end
end

-- Draws the route round where you are (`here`), or takes it off when there's
-- nothing to draw; returns what was drawn (RouteMap.DrawRoute's stats), or nil.
local function draw(here)
  if not (Minimap and ns.RouteMap and ns.RouteMap.DrawRoute) then return nil end
  local steps
  if enabled() and here then steps = ns.RouteMap.Rest(here) end
  local now = look(here)
  local w, h = now.w, now.h
  if not (steps and w and w > 0 and h and h > 0) then
    clear()
    drawn = now
    return nil
  end
  view = view or newView()
  local points = { steps[1].from }
  for _, step in ipairs(steps) do points[#points + 1] = step.to end
  -- World X is north and Y west; on the minimap x is east and y north (down
  -- negative), turned with you when it turns.
  local perYard = math.min(w, h) / now.yards
  local cos, sin = math.cos(now.turn), math.sin(now.turn)
  local function at(node)
    if node.instance ~= here.instance then return nil end
    local east, north = here.wy - node.wy, node.wx - here.wx
    local x, y = east * cos + north * sin, north * cos - east * sin
    return w / 2 + x * perYard, -h / 2 + y * perYard
  end
  local clip = { w = w, h = h }
  if now.round then clip.radius = math.min(w, h) / 2 - RIM end
  view.canvas:Show()
  local stats = ns.RouteMap.DrawRoute(view, steps, points, at,
    { size = SIZE, clip = clip, you = false, alpha = MinimapRoute.Alpha,
      skipLeg = now.inArea and 1 or nil, limit = SHOWN })
  drawn = now
  return stats
end

function MinimapRoute.Refresh()
  if not Minimap then return nil end
  return draw(ns.Geo.PlayerNodeExact())
end

-- One look at where you are (every frame while there's a journey to draw):
-- drawn again when you've moved, turned it, or the minimap has changed.
-- Returns whether it was.
function MinimapRoute.Tick(elapsed)
  since = since + (elapsed or 0)
  if since < EVERY or not Minimap then return false end
  since = 0
  local now = look(ns.Geo.PlayerNodeExact())
  if not changed(now) then return false end
  draw(now.here)
  return true
end

-- Starts or stops following you: on while the option is and there's a
-- journey (or directions), and draws it now.
function MinimapRoute.Update()
  if not Minimap then return nil end
  local on = enabled() and ns.Nav.active ~= nil
  if on and not driver then
    driver = CreateFrame("Frame", nil, Minimap)
    driver:SetScript("OnUpdate", function(_, elapsed) MinimapRoute.Tick(elapsed) end)
  end
  if driver then driver:SetShown(on) end
  since = 0
  return MinimapRoute.Refresh()
end

-- What's drawn now (for tests): RouteMap.DrawRoute's stats, or nil.
function MinimapRoute.Stats()
  return view and view.canvas:IsShown() and view.stats or nil
end

function MinimapRoute.Toggle()
  ns.SetSetting("minimapRoute", not enabled())
  ns.print("journey on the minimap " .. (enabled() and "on" or "off"))
end

ns.On("PLAYER_LOGIN", MinimapRoute.Update)
ns.Listen("NAV_CHANGED", MinimapRoute.Update)
ns.Listen("JOURNEY_EXTENDED", MinimapRoute.Update)
ns.Listen("SETTINGS_CHANGED", function(key) if key == "minimapRoute" then MinimapRoute.Update() end end)
