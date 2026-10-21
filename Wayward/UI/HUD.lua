local _, ns = ...

-- Directions box shown while navigating: current step, distance, and our own
-- compass (an arrow in a circle; /ww compass or the options turn it off, and
-- the box gets narrower). Blizzard's on-screen navigation is off by default in Forever
-- (showInGameNavigation = 0), so we don't rely on it.

local HUD = {}
ns.HUD = HUD

local frame
local unpack = unpack or table.unpack
local UPDATE_INTERVAL = 0.1
local WIDTH = 330
local MIN_HEIGHT = 84
local PADDING = 10
local CIRCLE = 42
local TEXT_LEFT = PADDING + CIRCLE + 10
local HOME = { "TOP", "TOP", 0, -140 }
local FLASH_PERIOD = 0.8 -- seconds per pulse of the book button when the trip gains stops
local FLASH_PULSES = 3

-- What's at a stop, shown in the circle when there's no arrow to show.
local STOP_ICONS = {
  pickup = "Interface\\GossipFrame\\AvailableQuestIcon",
  turnin = "Interface\\GossipFrame\\ActiveQuestIcon",
  complete = "Interface\\Icons\\INV_Sword_04",
  item = "Interface\\Icons\\INV_Misc_Bag_10",
  manual = "Interface\\Icons\\INV_Misc_Note_01",
}
local MODE_ICONS = {
  fly = "Interface\\Icons\\Ability_Hunter_EagleEye",
  hearth = "Interface\\Icons\\INV_Misc_Rune_01",
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

-- Two of the square button's arrows side by side: fast forward. Our own
-- textures, so the template's press nudge (which re-anchors its icon) can't
-- pull them together; they're nudged the same way here.
local function fastForward(b)
  local icon = b.icon
  if not (icon and icon.GetTexCoord and icon:GetTexture()) then return end
  local coords = { icon:GetTexCoord() }
  local arrows = {}
  for i, dx in ipairs({ -3, 3 }) do
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetTexture(icon:GetTexture())
    t:SetTexCoord(unpack(coords))
    t:SetSize(icon:GetSize())
    t:SetPoint("CENTER", dx, 0)
    arrows[i] = { t, dx }
  end
  icon:SetAlpha(0)
  local function nudge(by)
    for _, a in ipairs(arrows) do
      a[1]:ClearAllPoints()
      a[1]:SetPoint("CENTER", a[2] + by, -by)
    end
  end
  b:HookScript("OnMouseDown", function(self) if self:IsEnabled() then nudge(-1) end end)
  b:HookScript("OnMouseUp", function() nudge(0) end)
  b.fastForward = arrows
end

local function create()
  local f = ns.Skin.CreateBox("WaywardHUD")
  f:SetSize(WIDTH, MIN_HEIGHT)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "hudPos")
    ns.Fire("HUD_MOVED")
  end)
  f:SetBackdropColor(0, 0, 0, 0.8)
  ns.RestorePosition(f, "hudPos", HOME)

  -- The arrow (or the stop's icon) in a dark circle, on its own frame: skins
  -- fade every texture of the box itself.
  local holder = CreateFrame("Frame", nil, f)
  f.holder = holder
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

  -- Buttons top right: skip and move on (trips), all stops, recalculate, stop.
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
    "See full journey")
  f.list:SetPoint("RIGHT", f.recalc, "LEFT", -2, 0)
  -- A glow over the book button, pulsed when the trip gains stops (HUD.FlashJourney).
  f.listGlow = f.list:CreateTexture(nil, "OVERLAY")
  f.listGlow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  f.listGlow:SetBlendMode("ADD")
  f.listGlow:SetPoint("TOPLEFT", -2, 2)
  f.listGlow:SetPoint("BOTTOMRIGHT", 2, -2)
  f.listGlow:SetAlpha(0)
  f.moveOn = squareButton(f, "RIGHT", nil, ">>", function() ns.Nav.MoveOn() end,
    "Move to the next step and do this later")
  fastForward(f.moveOn)
  f.moveOn:SetPoint("RIGHT", f.list, "LEFT", -2, 0)
  f.skip = squareButton(f, nil, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "x", function() ns.Nav.Skip() end,
    "Skip this step")
  f.skip:SetPoint("RIGHT", f.moveOn, "LEFT", -2, 0)

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
    if f.flashLeft then
      f.flashLeft = f.flashLeft - dt
      if f.flashLeft > 0 then
        f.listGlow:SetAlpha(math.abs(math.sin(f.flashLeft / FLASH_PERIOD * math.pi)))
      else
        f.flashLeft = nil
        f.listGlow:SetAlpha(0)
      end
    end
    elapsed = elapsed + dt
    if elapsed >= UPDATE_INTERVAL then
      elapsed = 0
      local ok, err = pcall(HUD.Update)
      if not ok then
        -- Reported once, and the trip stops rather than failing ten times a second.
        pcall(ns.Nav.Stop)
        f:Hide()
        geterrorhandler()(err)
      end
    end
  end)
  ns.Skin.Box(f)
  return f
end

-- With the compass off there's no circle: the text starts at the edge and the
-- box is that much narrower.
local function applyCompass()
  local on = ns.db.settings.showArrow ~= false
  if frame.compass == on then return end
  frame.compass = on
  frame.holder:SetShown(on)
  frame.width = on and WIDTH or WIDTH - (TEXT_LEFT - PADDING)
  frame:SetWidth(frame.width)
  frame.title:ClearAllPoints()
  frame.title:SetPoint("TOPLEFT", on and TEXT_LEFT or PADDING, -PADDING - 2)
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

-- Where the current step is among the steps to the next stop (a trip) or to
-- the destination: position and count.
local function legPosition(a)
  local steps = a.route.steps
  if not a.journey then return a.index, #steps end
  local first, last = 1, #steps
  for k = a.index - 1, 1, -1 do
    if steps[k].stop then first = k + 1 break end
  end
  for k = a.index, #steps do
    if steps[k].stop then last = k break end
  end
  return a.index - first + 1, last - first + 1
end

-- Lays the text out under the title, or under the progress bar on a trip.
local function place(trip)
  frame.progress:SetShown(trip)
  frame.step:ClearAllPoints()
  frame.step:SetPoint("TOPLEFT", trip and frame.progress or frame.title, "BOTTOMLEFT", 0, trip and -7 or -5)
  frame.step:SetPoint("RIGHT", -PADDING, 0)
  -- The title stops short of the buttons.
  frame.title:SetPoint("RIGHT", trip and frame.skip or frame.recalc, "LEFT", -6, 0)
end

function HUD.Update()
  if not frame then return end
  local here, step = ns.Nav.Tick()
  local a = ns.Nav.active
  if not (a and step) then
    frame:Hide()
    return
  end
  applyCompass()
  local trip = a.journey ~= nil
  frame.list:SetShown(trip)
  frame.moveOn:SetShown(trip)
  frame.skip:SetShown(trip)
  place(trip)

  -- One count each: stops done in the title, steps to the next stop (or to
  -- the destination) under the step, only when there's more than one.
  if trip then
    local done, total = ns.Journey.StopsDone(a.journey), #a.journey.stops
    frame.title:SetText(string.format("%s  |cff9d9d9d%d of %d done|r", a.title or "", done, total))
    frame.progress:SetValue(total > 0 and done / total or 0)
  else
    frame.title:SetText(a.title or "")
  end
  frame.step:SetText(ns.Router.Describe(a.route, a.index))
  local position, count = legPosition(a)
  local sub = count > 1 and string.format(trip and "Step %d of %d to get there" or "Step %d of %d", position, count)
    or ""
  frame.sub:SetText(sub)
  frame.info:ClearAllPoints()
  frame.info:SetPoint("TOPLEFT", sub ~= "" and frame.sub or frame.step, "BOTTOMLEFT", 0, -5)
  frame.info:SetPoint("RIGHT", -PADDING, 0)

  local distance = here and ns.Geo.Distance(here, step.to) or math.huge
  local remaining = TIME_ICON .. " " .. ns.FormatDuration(ns.Nav.RemainingSeconds(here))
  local objective = step.stop and step.stop.action and step.stop.action.kind == "complete"
    and HUD.ObjectiveText(step.stop.action.questID)
  if objective and ns.Nav.InArea() then
    -- Among what you need: no arrow, just how it's going (and how long, at your pace here).
    if ns.Camps.LooksCleared(step.stop) then
      frame.info:SetText("|cffffd100Camp looks cleared|r  ·  " .. objective .. "     " .. remaining)
    else
      local left = ns.Camps.TimeLeft(step.stop)
      frame.info:SetText("|cff7fd1aeIn the area|r  ·  " .. objective
        .. (left and ("  ·  " .. ns.FormatDuration(left) .. " left here") or "") .. "     " .. remaining)
    end
  elseif objective then
    -- On the way from a spot you've cleared to the next, or back to one respawning.
    local respawn = ns.Journey.RespawnIn(step.stop)
    local lead = respawn > 0 and ("|cff9d9d9dRespawns in " .. ns.FormatDuration(respawn) .. "|r  ·  ")
      or ns.Journey.ClearedAreas(step.stop) > 0 and "|cff9d9d9dNext spot|r  ·  " or ""
    frame.info:SetText(lead .. objective .. "     " .. remaining)
  elseif ns.Nav.Interaction() == "fly" then
    frame.info:SetText(string.format("Pick %s on the flight map     %s", step.to.label or "your destination", remaining))
  elseif ns.Nav.Interaction() == "hearth" then
    frame.info:SetText(string.format("Use your Hearthstone     %s", remaining))
  elseif ns.Nav.Interaction() == "use" then
    frame.info:SetText(string.format("|cff7fd1aeYou're here:|r use %s     %s", (ns.Nav.TargetObject()), remaining))
  elseif ns.Nav.Interaction() == "talk" and not (step.stop and step.stop.action and step.stop.action.kind == "manual") then
    local name = ns.Nav.TargetNPC()
    local training = step.stop and step.stop.action and step.stop.action.kind == "train"
    frame.info:SetText(string.format("|cff7fd1aeYou're here:|r talk to %s%s     %s", name or "them",
      training and " and train it" or "", remaining))
  elseif ns.Nav.Waiting() then
    -- A quest step only you can tell is done.
    local manual = step.stop and step.stop.action and step.stop.action.kind == "manual"
    frame.info:SetText((manual and "|cff7fd1aeYou're here:|r do it, then move on (>>)" or "|cff7fd1aeYou're here|r")
      .. "     " .. remaining)
  elseif distance < math.huge and step.mode == "walk" then
    frame.info:SetText(string.format("%s %d yd     %s", DISTANCE_ICON, math.floor(distance), remaining))
  else
    frame.info:SetText(remaining)
  end

  -- Grow to fit the text (titles and steps can wrap).
  local function height(fs) return fs:GetStringHeight() or 12 end
  local subHeight = sub ~= "" and (3 + height(frame.sub)) or 0
  frame:SetHeight(math.max(MIN_HEIGHT, PADDING * 2 + height(frame.title) + (trip and 16 or 5) + height(frame.step)
    + subHeight + 5 + height(frame.info)))

  local heading = facing()
  -- The compass points the way while you walk; otherwise its circle shows what's ahead.
  if step.mode == "walk" and distance < math.huge and heading and not ns.Nav.Waiting() and not ns.Nav.Flying() then
    frame.arrow:SetRotation(ns.Geo.Bearing(here, step.to) - heading)
    frame.arrow:Show()
    frame.icon:Hide()
  else
    frame.arrow:Hide()
    local action = (step.stop or {}).action
    frame.icon:SetTexture(action and STOP_ICONS[action.kind] or MODE_ICONS[step.mode] or MODE_ICONS.walk)
    frame.icon:Show()
  end
end

-- Whether the compass arrow shows right now (for tests).
function HUD.ArrowShown() return frame ~= nil and frame.arrow:IsShown() end

-- The directions box (the target button sits beside it).
function HUD.Frame() return frame end

-- The box, made (hidden) if there isn't one yet: edit modes move it anyway.
function HUD.EnsureFrame()
  if not frame then
    frame = create()
    if not ns.Nav.active then frame:Hide() end
  end
  return frame
end

ns.Movers.Add({ key = "Directions", label = "Directions", posKey = "hudPos", home = HOME,
  frame = HUD.EnsureFrame, moved = function() ns.Fire("HUD_MOVED") end })

-- Whether the compass circle shows, and the box's width (for tests).
function HUD.CompassShown() return frame ~= nil and frame.holder:IsShown() end
function HUD.Width() return frame and frame.width end

-- The directions box's text, top to bottom (for tests).
function HUD.Lines()
  if not frame then return {} end
  return { frame.title:GetText(), frame.step:GetText(), frame.sub:GetText(), frame.info:GetText() }
end

-- Pulses the book button a few times: the trip has changed, its overview is a click away.
function HUD.FlashJourney()
  if frame then frame.flashLeft = FLASH_PERIOD * FLASH_PULSES end
end

-- Whether the book button is pulsing (for tests).
function HUD.Flashing() return frame ~= nil and frame.flashLeft ~= nil end

ns.Listen("SETTINGS_CHANGED", function(key)
  if key == "showArrow" and frame then HUD.Update() end
end)

ns.Listen("JOURNEY_EXTENDED", function()
  if not ns.JourneyOverview.IsShown() then HUD.FlashJourney() end
end)

ns.Listen("NAV_CHANGED", function()
  if ns.Nav.active then
    frame = frame or create()
    frame:Show()
    HUD.Update()
  elseif frame then
    frame:Hide()
  end
end)
