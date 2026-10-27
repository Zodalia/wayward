local _, ns = ...

-- "Your journey", the top region of the main window: what the player chose.
-- On a journey: its icon, title, the current stop ("Stop 3 of 5 · Find
-- Shimmerweed in Dun Morogh"), stops done and time remaining, a progress bar,
-- a line of description, Continue journey (closes the window and makes sure
-- the directions box shows) and View details (the journey overview), with a
-- map of the rest of the journey on the right. With plain directions: the
-- destination and "Directions", and Continue. With nothing active the region
-- is one line, so the suggestions move up.

local Box = {}
ns.JourneyBox = Box

local FULL_HEIGHT = 156
local LINE_HEIGHT = 26
local ICON = 56
local MAP_WIDTH = 220
local PAD = 10
local LEFT = PAD + ICON + 14
local GOLD = { 1, 0.82, 0 }
local GREY = { 0.62, 0.62, 0.62 }
local NONE_TEXT = "No journey on the go. Pick something below."
local DESCRIPTION = "A flexible plan you can continue, reorder or expand."
local DIRECTIONS_DESCRIPTION = "Directions to one place. Starting a journey folds it in as a stop."

local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Map_01"
local KIND_ICONS = {
  quest = "Interface\\Icons\\INV_Scroll_03", zone = "Interface\\Icons\\INV_Misc_Spyglass_03",
  dungeon = "Interface\\Icons\\INV_Misc_Key_14", raid = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
  ["hand-in"] = "Interface\\Icons\\INV_Letter_15", handin = "Interface\\Icons\\INV_Letter_15",
  finish = "Interface\\Icons\\INV_Sword_04", profession = "Interface\\Icons\\Trade_Engineering",
  custom = "Interface\\Icons\\INV_Misc_Note_01", directions = "Interface\\Icons\\Ability_Hunter_Pathfinding",
}

local frame

---------------------------------------------------------------- progress

-- The stop the current step leads to, and its position among the stops.
local function currentStop(a)
  local steps = a.route and a.route.steps or {}
  local stop
  for k = a.index or 1, #steps do
    if steps[k].stop then
      stop = steps[k].stop
      break
    end
  end
  if not stop then return nil end
  for i, s in ipairs(a.journey.stops) do
    if s == stop then return stop, i end
  end
  return stop, nil
end

-- { done, total, seconds, stopIndex, stopText } for the journey on now:
-- the navigator's own when it has one, else from the journey's stops.
function Box.Progress()
  if ns.Nav.Progress then
    local ok, p = pcall(ns.Nav.Progress)
    if ok and p then return p end
  end
  local a = ns.Nav.active
  if not (a and a.journey) then return nil end
  local done, total = ns.Journey.StopsDone(a.journey), #a.journey.stops
  local stop, index = currentStop(a)
  local seconds = a.route and a.route.seconds
  if ns.Nav.RemainingSeconds then
    local ok, left = pcall(ns.Nav.RemainingSeconds, ns.Geo.PlayerNode())
    if ok and left then seconds = left end
  end
  return { done = done, total = total, seconds = seconds, stopIndex = index,
    stopText = stop and (stop.text or (stop.node and stop.node.label)) or nil }
end

local function iconFor(a)
  local def = a.journey and (a.journey.root or a.journey.def)
  if def and def.icon then return def.icon end
  if not a.journey then return KIND_ICONS.directions end
  local kind = def and def.kind
  if kind == "dungeon" and def.raid then return KIND_ICONS.raid end
  return KIND_ICONS[kind] or DEFAULT_ICON
end

---------------------------------------------------------------- the box

local function label(parent, template, size, color)
  local fs = parent:CreateFontString(nil, "OVERLAY", template)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  if color then fs:SetTextColor(color[1], color[2], color[3]) end
  ns.Skin.Text(fs)
  return fs
end

local function actionButton(parent, width, text, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  ns.Skin.Button(b)
  return b
end

-- Closes the window and makes sure the directions box is up for the
-- current step.
local function continueJourney()
  if not ns.Nav.active then return end
  if ns.Panel.Hide then ns.Panel.Hide() end
  if ns.HUD and ns.HUD.EnsureFrame then
    local hud = ns.HUD.EnsureFrame()
    hud:Show()
    ns.HUD.Update()
  end
end

-- A dark translucent panel with a thin edge, from plain textures (no
-- template, so it looks the same on every client and under every skin).
function Box.Backdrop(f)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.35)
  for _, edge in ipairs({ { "TOPLEFT", "TOPRIGHT", 0, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 1 },
    { "TOPLEFT", "BOTTOMLEFT", 1, 0 }, { "TOPRIGHT", "BOTTOMRIGHT", 1, 0 } }) do
    local line = f:CreateTexture(nil, "BORDER")
    line:SetColorTexture(0.6, 0.5, 0.3, 0.7)
    line:SetPoint(edge[1])
    line:SetPoint(edge[2])
    if edge[3] == 1 then line:SetWidth(1) else line:SetHeight(1) end
  end
end

function Box.Create(parent, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(width, FULL_HEIGHT)
  f.width = width
  Box.Backdrop(f)

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(ICON, ICON)
  f.icon:SetPoint("TOPLEFT", PAD + 2, -PAD - 2)
  if f.icon.SetMask then pcall(f.icon.SetMask, f.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  f.ring = f:CreateTexture(nil, "OVERLAY")
  f.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  f.ring:SetSize(ICON * 1.12, ICON * 1.12)
  f.ring:SetPoint("CENTER", f.icon, "CENTER", 10, -10)

  f.title = label(f, "GameFontNormalLarge", 16, GOLD)
  f.title:SetPoint("TOPLEFT", LEFT, -PAD - 2)
  f.stop = label(f, "GameFontHighlight", 12)
  f.stop:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
  f.done = label(f, "GameFontHighlightSmall", 11, GREY)
  f.done:SetPoint("TOPLEFT", f.stop, "BOTTOMLEFT", 0, -3)

  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetHeight(8)
  f.bar:SetPoint("TOPLEFT", f.done, "BOTTOMLEFT", 0, -6)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetStatusBarColor(0.25, 0.85, 0.3)
  f.bar:SetMinMaxValues(0, 1)
  local track = f.bar:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0, 0, 0, 0.5)

  f.description = label(f, "GameFontDisableSmall", 11)
  f.description:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 0, -6)

  f.continue = actionButton(f, 130, "Continue journey", continueJourney)
  f.continue:SetPoint("BOTTOMLEFT", LEFT - 2, PAD)
  f.details = actionButton(f, 100, "View details", function() ns.JourneyOverview.Show() end)
  f.details:SetPoint("LEFT", f.continue, "RIGHT", 6, 0)

  -- The map of what's left, at the right.
  f.map = ns.RouteMap.NewView(f, MAP_WIDTH)
  f.map.canvas:SetPoint("TOPRIGHT", -PAD, -PAD)
  f.map.canvas:Hide()
  local textRight = width - MAP_WIDTH - 2 * PAD - LEFT
  for _, fs in ipairs({ f.title, f.stop, f.done, f.description }) do fs:SetWidth(textRight) end
  f.bar:SetWidth(textRight)

  -- The one line when nothing is on.
  f.none = label(f, "GameFontDisable", 12)
  f.none:SetPoint("LEFT", PAD + 4, 0)
  f.none:SetWidth(width - 2 * PAD - 8)
  f.none:SetText(NONE_TEXT)

  frame = f
  return f
end

local function setShown(f, shown)
  for _, part in ipairs({ f.icon, f.ring, f.title, f.stop, f.done, f.bar, f.description, f.continue, f.details }) do
    part:SetShown(shown)
  end
end

-- What's left of the route, as a result the map can draw.
local function remaining(a)
  local steps = {}
  for k = a.index or 1, #a.route.steps do steps[#steps + 1] = a.route.steps[k] end
  return { title = a.title, route = { steps = steps } }
end

-- Brings the box up to date; returns its height, which the window lays the
-- regions below out by.
function Box.Update()
  if not frame then return 0 end
  local f = frame
  local a = ns.Nav.active
  f.map.canvas:Hide()
  if not a then
    setShown(f, false)
    f.none:Show()
    f.state = "none"
    f:SetHeight(LINE_HEIGHT)
    f.height = LINE_HEIGHT
    return LINE_HEIGHT
  end
  f.none:Hide()
  setShown(f, true)
  f.icon:SetTexture(iconFor(a))
  f.title:SetText(a.title or "")
  if a.journey then
    f.state = "journey"
    local p = Box.Progress() or { done = 0, total = #a.journey.stops }
    if p.stopIndex and p.stopText then
      f.stop:SetText(string.format("Stop %d of %d  ·  %s", p.stopIndex, p.total, p.stopText))
    elseif p.stopText then
      f.stop:SetText(p.stopText)
    else
      f.stop:SetText(string.format("%d stops", p.total))
    end
    f.done:SetText(string.format("%d of %d stop%s complete  ·  %s remaining", p.done, p.total,
      p.total == 1 and "" or "s", ns.FormatDuration(p.seconds)))
    f.bar:SetValue(p.total > 0 and p.done / p.total or 0)
    f.bar:Show()
    local def = a.journey.root or a.journey.def
    f.description:SetText(def and def.description or DESCRIPTION)
    f.continue:SetText("Continue journey")
    f.details:Show()
  else
    f.state = "directions"
    f.stop:SetText("Directions" .. (a.goal and a.goal.label and ("  ·  " .. a.goal.label) or ""))
    local seconds = a.route and a.route.seconds
    if ns.Nav.RemainingSeconds then
      local ok, left = pcall(ns.Nav.RemainingSeconds, ns.Geo.PlayerNode())
      if ok and left then seconds = left end
    end
    f.done:SetText(string.format("%d step%s  ·  %s remaining", #a.route.steps, #a.route.steps == 1 and "" or "s",
      ns.FormatDuration(seconds)))
    f.bar:Hide()
    f.description:SetText(DIRECTIONS_DESCRIPTION)
    f.continue:SetText("Continue")
    f.details:Hide()
  end
  if a.route and a.route.steps then
    local ok, height = pcall(ns.RouteMap.Draw, f.map, remaining(a))
    f.map.canvas:SetShown(ok and height ~= nil)
  end
  f:SetHeight(FULL_HEIGHT)
  f.height = FULL_HEIGHT
  return FULL_HEIGHT
end

-- "journey", "directions" or "none" (for tests).
function Box.State() return frame and frame.state end

-- The text drawn, top to bottom (for tests).
function Box.Lines()
  if not frame then return {} end
  if frame.state == "none" then return { frame.none:GetText() } end
  return { frame.title:GetText(), frame.stop:GetText(), frame.done:GetText(), frame.description:GetText() }
end

-- The buttons' labels as drawn, or nil when hidden (for tests).
function Box.Buttons()
  if not (frame and frame.state ~= "none") then return nil, nil end
  return frame.continue:GetText(), frame.details:IsShown() and frame.details:GetText() or nil
end

-- Clicks Continue (for tests).
function Box.Continue() continueJourney() end

function Box.Frame() return frame end

-- The journey changed: the box follows while the window is open.
local function changed()
  if frame and ns.Panel.IsShown() then ns.Panel.Layout() end
end
ns.Listen("NAV_CHANGED", changed)
ns.Listen("JOURNEY_STARTED", changed)
ns.Listen("JOURNEY_EXTENDED", changed)
