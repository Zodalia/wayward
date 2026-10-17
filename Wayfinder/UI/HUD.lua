local _, ns = ...

-- Directions box shown while navigating: current step, distance, and our own
-- arrow. Blizzard's on-screen navigation is off by default in Forever
-- (showInGameNavigation = 0), so we don't rely on it.

local HUD = {}
ns.HUD = HUD

local frame
local UPDATE_INTERVAL = 0.1
local WIDTH = 330
local MIN_HEIGHT = 84
local PADDING = 10
local CIRCLE = 42
local TEXT_LEFT = PADDING + CIRCLE + 10

-- What's at a stop, shown in the circle when there's no arrow to show.
local STOP_ICONS = {
  pickup = "Interface\\GossipFrame\\AvailableQuestIcon",
  turnin = "Interface\\GossipFrame\\ActiveQuestIcon",
  complete = "Interface\\Icons\\INV_Sword_04",
}
local MODE_ICONS = {
  fly = "Interface\\Icons\\Ability_Hunter_EagleEye",
  transport = "Interface\\Icons\\INV_Misc_Map_01",
  walk = "Interface\\Icons\\Ability_Rogue_Sprint",
}
local DISTANCE_ICON = "|TInterface\\Icons\\Ability_Tracking:13:13:0:0:64:64:5:59:5:59|t"
local TIME_ICON = "|TInterface\\Icons\\INV_Misc_PocketWatch_01:13:13:0:0:64:64:5:59:5:59|t"

local function tooltip(b, text)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(text)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Blizzard's square button with an arrow (`arrow`: LEFT, RIGHT, ...) or an
-- icon file on it; a text button when this client lacks the template.
local function squareButton(parent, arrow, iconFile, fallback, onClick, tip)
  local b, templated = ns.Skin.Create("Button", nil, parent, "UIPanelSquareButton", "UIPanelButtonTemplate", { "icon" })
  b:SetSize(22, 22)
  if templated then
    if arrow and SquareButton_SetIcon then
      SquareButton_SetIcon(b, arrow)
    else
      b.icon:SetTexture(iconFile)
      b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      b.icon:SetSize(14, 14)
    end
  else
    b:SetText(fallback)
    ns.Skin.Button(b)
  end
  b:SetScript("OnClick", onClick)
  tooltip(b, tip)
  return b
end

local function create()
  local f = ns.Skin.CreateBox("WayfinderHUD")
  f:SetSize(WIDTH, MIN_HEIGHT)
  f:SetPoint("TOP", 0, -140)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "hudPos")
  end)
  f:SetBackdropColor(0, 0, 0, 0.8)
  ns.RestorePosition(f, "hudPos")

  -- The arrow (or the stop's icon) in a dark circle, on its own frame: skins
  -- fade every texture of the box itself.
  local holder = CreateFrame("Frame", nil, f)
  holder:SetSize(CIRCLE, CIRCLE)
  holder:SetPoint("TOPLEFT", PADDING, -PADDING)
  local circle = holder:CreateTexture(nil, "BACKGROUND")
  circle:SetAllPoints()
  circle:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
  circle:SetVertexColor(0, 0, 0, 0.55)
  f.arrow = holder:CreateTexture(nil, "ARTWORK")
  f.arrow:SetSize(CIRCLE - 4, CIRCLE - 4)
  f.arrow:SetPoint("CENTER")
  f.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
  f.icon = holder:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(CIRCLE - 8, CIRCLE - 8)
  f.icon:SetPoint("CENTER")
  if f.icon.SetMask then pcall(f.icon.SetMask, f.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  f.icon:Hide()

  -- Buttons top right: previous / next step, all stops, recalculate, stop.
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetSize(24, 24)
  f.close:SetPoint("TOPRIGHT", -3, -3)
  f.close:SetScript("OnClick", function() ns.Nav.Stop() end)
  tooltip(f.close, "Stop directions")
  ns.Skin.CloseButton(f.close)
  f.recalc = squareButton(f, nil, "Interface\\Buttons\\UI-RefreshButton", "R", function() ns.Nav.Recalculate() end,
    "Recalculate from here")
  f.recalc:SetPoint("RIGHT", f.close, "LEFT", -2, 0)
  f.list = squareButton(f, nil, "Interface\\Icons\\INV_Misc_Book_08", "=", function() ns.JourneyOverview.Toggle() end,
    "All stops of this trip")
  f.list:SetPoint("RIGHT", f.recalc, "LEFT", -2, 0)
  f.next = squareButton(f, "RIGHT", nil, ">", function() ns.Nav.Next() end, "Skip to the next step")
  f.prev = squareButton(f, "LEFT", nil, "<", function() ns.Nav.Prev() end, "Previous step")
  f.prev:SetPoint("RIGHT", f.next, "LEFT", -2, 0)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", TEXT_LEFT, -PADDING - 2)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)

  -- Stops done, as a thin bar under the title (trips only).
  f.progress = CreateFrame("StatusBar", nil, f)
  f.progress:SetHeight(4)
  f.progress:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -5)
  f.progress:SetPoint("RIGHT", -PADDING, 0)
  f.progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.progress:SetStatusBarColor(1, 0.82, 0)
  f.progress:SetMinMaxValues(0, 1)
  local track = f.progress:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(1, 1, 1, 0.12)

  f.step = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.step:SetPoint("RIGHT", -PADDING, 0)
  f.step:SetJustifyH("LEFT")
  f.step:SetWordWrap(true)

  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.sub:SetPoint("TOPLEFT", f.step, "BOTTOMLEFT", 0, -3)
  f.sub:SetPoint("RIGHT", -PADDING, 0)
  f.sub:SetJustifyH("LEFT")

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.info:SetPoint("TOPLEFT", f.sub, "BOTTOMLEFT", 0, -5)
  f.info:SetPoint("RIGHT", -PADDING, 0)
  f.info:SetJustifyH("LEFT")
  for _, fs in ipairs({ f.title, f.step, f.sub, f.info }) do ns.Skin.Text(fs) end

  local elapsed = 0
  f:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= UPDATE_INTERVAL then
      elapsed = 0
      HUD.Update()
    end
  end)
  ns.Skin.Box(f)
  return f
end

local function facing()
  local value = GetPlayerFacing and GetPlayerFacing()
  if value == nil or (type(issecretvalue) == "function" and issecretvalue(value)) then return nil end
  return value
end

-- The first unfinished objective of a quest in your log, e.g. "4/8 Wolf Meat".
function HUD.ObjectiveText(questID)
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  for _, o in ipairs(objectives or {}) do
    if not o.finished and o.text then return o.text end
  end
  return nil
end

-- The stop a step leads to, and its number among the trip's stops.
local function stopAhead(a)
  for k = a.index, #a.route.steps do
    local stop = a.route.steps[k].stop
    if stop then
      for i, s in ipairs(a.journey.stops) do
        if s == stop then return stop, i end
      end
      return stop, nil
    end
  end
  return nil, nil
end

-- Lays the text out under the title, or under the progress bar on a trip.
local function place(trip)
  frame.progress:SetShown(trip)
  frame.step:ClearAllPoints()
  frame.step:SetPoint("TOPLEFT", trip and frame.progress or frame.title, "BOTTOMLEFT", 0, trip and -7 or -5)
  frame.step:SetPoint("RIGHT", -PADDING, 0)
  -- The title stops short of the buttons.
  frame.title:SetPoint("RIGHT", frame.prev, "LEFT", -6, 0)
end

function HUD.Update()
  if not frame then return end
  local here, step = ns.Nav.Tick()
  local a = ns.Nav.active
  if not (a and step) then
    frame:Hide()
    return
  end
  local trip = a.journey ~= nil
  frame.next:ClearAllPoints()
  frame.next:SetPoint("RIGHT", trip and frame.list or frame.recalc, "LEFT", -2, 0)
  frame.list:SetShown(trip)
  place(trip)

  local stop, stopNumber
  if trip then
    local done, total = ns.Journey.StopsDone(a.journey), #a.journey.stops
    frame.title:SetText(string.format("%s  |cff9d9d9d(%d/%d stops)|r", a.title, done, total))
    frame.progress:SetValue(total > 0 and done / total or 0)
    stop, stopNumber = stopAhead(a)
  else
    frame.title:SetText(a.title)
  end
  frame.step:SetText(ns.Router.Describe(a.route, a.index))
  local steps = #a.route.steps
  if stopNumber then
    frame.sub:SetText(string.format("Stop %d of %d  ·  step %d of %d", stopNumber, #a.journey.stops, a.index, steps))
  else
    frame.sub:SetText(string.format("Step %d of %d", a.index, steps))
  end

  local distance = here and ns.Geo.Distance(here, step.to) or math.huge
  local remaining = TIME_ICON .. " " .. ns.FormatDuration(ns.Nav.RemainingSeconds(here))
  local objective = step.stop and step.stop.action and step.stop.action.kind == "complete"
    and HUD.ObjectiveText(step.stop.action.questID)
  if objective then
    frame.info:SetText(objective .. "     " .. remaining)
  elseif ns.Nav.Waiting() then
    frame.info:SetText("|cff7fd1aeYou're here|r     " .. remaining)
  elseif distance < math.huge and step.mode == "walk" then
    frame.info:SetText(string.format("%s %d yd     %s", DISTANCE_ICON, math.floor(distance), remaining))
  else
    frame.info:SetText(remaining)
  end

  -- Grow to fit the text (titles and steps can wrap).
  local function height(fs) return fs:GetStringHeight() or 12 end
  frame:SetHeight(math.max(MIN_HEIGHT, PADDING * 2 + height(frame.title) + (trip and 16 or 5) + height(frame.step)
    + 3 + height(frame.sub) + 5 + height(frame.info)))

  local heading = facing()
  -- TomTom draws the arrow when it's in use; then the circle shows what's ahead.
  if ns.db.settings.showArrow and not ns.Nav.UsingTomTom() and step.mode == "walk" and distance < math.huge
    and heading and not ns.Nav.Waiting() then
    frame.arrow:SetRotation(ns.Geo.Bearing(here, step.to) - heading)
    frame.arrow:Show()
    frame.icon:Hide()
  else
    frame.arrow:Hide()
    local action = (step.stop or stop or {}).action
    frame.icon:SetTexture(action and STOP_ICONS[action.kind] or MODE_ICONS[step.mode] or MODE_ICONS.walk)
    frame.icon:Show()
  end
end

-- The directions box's text, top to bottom (for tests).
function HUD.Lines()
  if not frame then return {} end
  return { frame.title:GetText(), frame.step:GetText(), frame.sub:GetText(), frame.info:GetText() }
end

ns.Listen("NAV_CHANGED", function()
  if ns.Nav.active then
    frame = frame or create()
    frame:Show()
    HUD.Update()
  elseif frame then
    frame:Hide()
  end
end)
