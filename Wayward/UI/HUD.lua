local _, ns = ...

-- Directions box shown while navigating: current step, distance, and our own
-- compass (an arrow in a circle; /ww compass or the options turn it off, and
-- the box gets narrower), and a + button for what's on the way: the drawer
-- (UI/Drawer.lua) with what you could add and a stop of your own (repair,
-- mail, ...). The + carries a count of the offers while it's closed.
-- Above the box, a section of its own: "Gathering as you go", what the
-- journey takes in on the way, shown whenever there's something.
-- Blizzard's on-screen navigation is off by default in Forever
-- (showInGameNavigation = 0), so we don't rely on it.
-- Detail on demand (Nav.Detail): "steps" shows each step to the next stop
-- with a count; "stops" shows only the stop you're heading for and the
-- compass, and the step when you hover the box.
-- With no journey and no directions, the box stays as a small bar (unless
-- the options or /ww idle turn that off): open Wayward, or have it suggest a
-- journey from your quest log and where you are (For you's best hand-in or
-- "Finish N quests near X"; its title and why on hover).

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
local ADD_SIZE = 20
local INFO_RIGHT = -(PADDING + ADD_SIZE + 2) -- the last line stops short of the + button
local HOME = { "TOP", "TOP", 0, -140 }
local FLASH_PERIOD = 0.8 -- seconds per pulse of the book button when the journey gains stops
local FLASH_PULSES = 3
local MAX_OBJECTIVES = 4 -- lines of objectives under the step; past that, "+N more"
local OTHER_WIDTH, OTHER_HEIGHT = 92, 20 -- the Another spot button, right of the objectives
local WAYSIDE_EVERY = 1    -- seconds between looks at what's on the way
local GATHER_ROWS = 5      -- lines in "Gathering as you go": four things and "+N more" (Wayside.lua)
local GATHER_GAP = 3       -- the section sits this far above the box
local GATHER_PAD = 6       -- inside its background
local GATHER_LINE = 14     -- a line's height
local GATHER_FADE = 0.45   -- its background's alpha
local GATHER_HEADING = "Gathering as you go"
local IDLE_HEIGHT = 34     -- the small bar with no journey on
local IDLE_ICON = 20
local SUGGEST_WIDTH, OPEN_WIDTH, IDLE_BUTTON_HEIGHT = 124, 96, 22
local IDLE_WIDTH = PADDING + IDLE_ICON + 6 + SUGGEST_WIDTH + 4 + OPEN_WIDTH + 4 + 24 + 4
local ICON = "Interface\\AddOns\\Wayward\\Media\\Icon"
-- For you's suggestions made from your quest log: hand-ins ready, and
-- unfinished log quests close together.
local LOG_KINDS = { handin = true, finish = true }
local NOTHING_TO_SUGGEST = "Nothing in your quest log to go on from here. Open Wayward (/ww) for other ideas."

-- What's at a stop, shown in the circle when there's no arrow to show.
local STOP_ICONS = {
  pickup = "Interface\\GossipFrame\\AvailableQuestIcon",
  turnin = "Interface\\GossipFrame\\ActiveQuestIcon",
  complete = "Interface\\Icons\\INV_Sword_04",
  item = "Interface\\Icons\\INV_Misc_Bag_10",
  manual = "Interface\\Icons\\INV_Misc_Note_01",
  talk = "Interface\\GossipFrame\\GossipGossipIcon",
  train = "Interface\\GossipFrame\\TrainerGossipIcon",
  learn = "Interface\\GossipFrame\\TrainerGossipIcon",
  explore = "Interface\\Icons\\INV_Misc_Map_01",
  enter = "Interface\\Icons\\INV_Misc_Key_03",
}
-- Travel icons are the route map's (RouteMap.TravelIcon); walking is this.
local WALK_ICON = "Interface\\Icons\\Ability_Rogue_Sprint"
local DISTANCE_ICON = "|TInterface\\Icons\\Ability_Tracking:13:13:0:0:64:64:5:59:5:59|t"
local TIME_ICON = "|TInterface\\Icons\\INV_Misc_PocketWatch_01:13:13:0:0:64:64:5:59:5:59|t"

-- A button's tooltip; `b.tip` can change later (the x says what it ends).
local function tooltip(b, text)
  b.tip = text
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self.tip)
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

  -- Buttons top right: skip and move on (journeys), all stops, stop. No
  -- recalculate: the journey re-plans itself as you go (Navigator, liveCheck).
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetSize(24, 24)
  f.close:SetPoint("TOPRIGHT", -3, -3)
  -- With no journey on, the x hides the small bar (the options bring it back).
  f.close:SetScript("OnClick", function()
    if ns.Nav.active then ns.Nav.End() else HUD.HideIdle() end
  end)
  tooltip(f.close, "Stop directions")
  ns.Skin.CloseButton(f.close)
  f.list = squareButton(f, nil, "Interface\\Icons\\INV_Misc_Book_08", "=", function() ns.JourneyOverview.Toggle() end,
    "View details")
  f.list:SetPoint("RIGHT", f.close, "LEFT", -2, 0)
  -- A glow over the book button, pulsed when the journey gains stops (HUD.FlashJourney).
  f.listGlow = f.list:CreateTexture(nil, "OVERLAY")
  f.listGlow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  f.listGlow:SetBlendMode("ADD")
  f.listGlow:SetPoint("TOPLEFT", -2, 2)
  f.listGlow:SetPoint("BOTTOMRIGHT", 2, -2)
  f.listGlow:SetAlpha(0)
  f.moveOn = squareButton(f, "RIGHT", nil, ">>", function() ns.Nav.MoveOn() end, "Do this stop later")
  fastForward(f.moveOn)
  f.moveOn:SetPoint("RIGHT", f.list, "LEFT", -2, 0)
  f.skip = squareButton(f, nil, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "x", function() ns.Nav.Skip() end,
    "Skip this stop")
  f.skip:SetPoint("RIGHT", f.moveOn, "LEFT", -2, 0)
  -- Bottom right, beside the last line: what's on the way (UI/Drawer.lua).
  -- Closed, it says how many offers there are; nothing else asks for a look.
  f.add = squareButton(f, nil, "Interface\\Icons\\Spell_ChargePositive", "+", function() ns.Drawer.Toggle() end,
    "On the way")
  f.add:SetSize(ADD_SIZE, ADD_SIZE)
  f.add:SetPoint("BOTTOMRIGHT", -6, 6)
  f.add:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("On the way")
    local n = frame and frame.waysideCount or 0
    if n > 0 then
      GameTooltip:AddLine(string.format("%d thing%s you could add on the way.", n, n == 1 and "" or "s"), 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddLine("And a detour of your own: repair, vendor, mailbox, bank...", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  f.add.count = f.add:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  f.add.count:SetPoint("BOTTOMRIGHT", 3, -3)
  -- Gathering as you go: a section of its own on the box's top edge, as wide
  -- as the box, growing upward. Not part of the box: the box keeps its size.
  -- A faint background on its own frame (skins fade the box's textures);
  -- hover a line for what it's for and where.
  f.gathering = CreateFrame("Frame", nil, f)
  f.gathering:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, GATHER_GAP)
  f.gathering:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, GATHER_GAP)
  f.gathering:SetHeight(1)
  local gatherBg = f.gathering:CreateTexture(nil, "BACKGROUND")
  gatherBg:SetAllPoints()
  gatherBg:SetColorTexture(0, 0, 0, GATHER_FADE)
  f.gathering.heading = f.gathering:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.gathering.heading:SetPoint("TOPLEFT", GATHER_PAD, -GATHER_PAD)
  f.gathering.heading:SetPoint("RIGHT", -GATHER_PAD, 0)
  f.gathering.heading:SetHeight(GATHER_LINE)
  f.gathering.heading:SetJustifyH("LEFT")
  f.gathering.heading:SetText(GATHER_HEADING)
  ns.Skin.Text(f.gathering.heading)
  -- A frame a line, for its tooltip; a font string that doesn't wrap shows
  -- one line only, so the lines can't share one.
  f.gathering.rows = {}
  for i = 1, GATHER_ROWS do
    local r = CreateFrame("Frame", nil, f.gathering)
    r:SetPoint("TOPLEFT", GATHER_PAD, -GATHER_PAD - i * GATHER_LINE)
    r:SetPoint("RIGHT", -GATHER_PAD, 0)
    r:SetHeight(GATHER_LINE)
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetAllPoints()
    r.text:SetJustifyH("LEFT")
    r.text:SetJustifyV("MIDDLE")
    r.text:SetWordWrap(false)
    ns.Skin.Text(r.text)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      local tip = self.row and self.row.tip
      if not tip then return end
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(tip[1])
      for k = 2, #tip do GameTooltip:AddLine(tip[k], 0.6, 0.6, 0.6, true) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:Hide()
    f.gathering.rows[i] = r
  end
  f.gathering:Hide()
  -- Beside the objectives, when they're in more than one area: another spot
  -- for them (this one's camped, respawning, too busy). A labelled button,
  -- since it's the one you reach for in a hurry. Placed by HUD.Update.
  f.otherArea = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.otherArea:SetSize(OTHER_WIDTH, OTHER_HEIGHT)
  f.otherArea:SetText("Another spot")
  f.otherArea:SetScript("OnClick", function() ns.Nav.OtherArea() end)
  f.otherArea:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Another spot")
    GameTooltip:AddLine("Camped, respawning or too busy? Head for another place to do this quest. "
      .. "This one's left alone for a while, like a camp you've cleared.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  f.otherArea:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Button(f.otherArea)
  f.otherArea:Hide()

  -- No journey on: Wayward's icon, Suggest a journey, Open Wayward (and the x).
  f.idle = CreateFrame("Frame", nil, f)
  f.idle:SetAllPoints()
  f.idle.icon = f.idle:CreateTexture(nil, "ARTWORK")
  f.idle.icon:SetSize(IDLE_ICON, IDLE_ICON)
  f.idle.icon:SetPoint("LEFT", PADDING, 0)
  f.idle.icon:SetTexture(ICON)
  f.idle.suggest = CreateFrame("Button", nil, f.idle, "UIPanelButtonTemplate")
  f.idle.suggest:SetSize(SUGGEST_WIDTH, IDLE_BUTTON_HEIGHT)
  f.idle.suggest:SetPoint("LEFT", f.idle.icon, "RIGHT", 6, 0)
  f.idle.suggest:SetText("Suggest a journey")
  f.idle.suggest:SetScript("OnClick", function() HUD.SuggestJourney() end)
  f.idle.suggest:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    for i, line in ipairs(HUD.SuggestTooltip()) do
      if i == 1 then GameTooltip:SetText(line) else GameTooltip:AddLine(line, 0.6, 0.6, 0.6, true) end
    end
    GameTooltip:Show()
  end)
  f.idle.suggest:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Button(f.idle.suggest)
  f.idle.open = CreateFrame("Button", nil, f.idle, "UIPanelButtonTemplate")
  f.idle.open:SetSize(OPEN_WIDTH, IDLE_BUTTON_HEIGHT)
  f.idle.open:SetPoint("LEFT", f.idle.suggest, "RIGHT", 4, 0)
  f.idle.open:SetText("Open Wayward")
  f.idle.open:SetScript("OnClick", function() if not ns.Panel.IsShown() then ns.Panel.Toggle() end end)
  tooltip(f.idle.open, "Open Wayward: suggestions, quests, places and more")
  ns.Skin.Button(f.idle.open)
  f.idle:Hide()

  -- With the detail on "stops", the step is in a tooltip over the box.
  f:SetScript("OnEnter", function(self)
    if self.idleMode then return end
    local lines = HUD.StepTooltip()
    if not lines then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(lines[1])
    for i = 2, #lines do GameTooltip:AddLine(lines[i], 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", TEXT_LEFT, -PADDING - 2)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)

  -- Stops done, as a thin bar under the title (journeys only).
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

  -- What a quest still needs, one objective a line, while you're doing it.
  f.objectives = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.objectives:SetPoint("RIGHT", -PADDING, 0)
  f.objectives:SetJustifyH("LEFT")
  f.objectives:SetSpacing(2)

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.info:SetPoint("TOPLEFT", f.sub, "BOTTOMLEFT", 0, -5)
  f.info:SetPoint("RIGHT", INFO_RIGHT, 0)
  f.info:SetJustifyH("LEFT")
  for _, fs in ipairs({ f.title, f.step, f.sub, f.objectives, f.info }) do ns.Skin.Text(fs) end
  -- What the small bar hides; HUD.Update shows them again as each needs.
  f.journeyParts = { f.holder, f.title, f.progress, f.step, f.sub, f.objectives, f.info, f.list, f.moveOn, f.skip,
    f.add, f.gathering, f.otherArea }

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
        -- Reported once, and the journey stops rather than failing ten times a second.
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

-- The unfinished objectives of a quest in your log, e.g. { "4/8 Wolf Meat", "0/1 Wolf Pelt" }.
function HUD.Objectives(questID)
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  local out = {}
  for _, o in ipairs(objectives or {}) do
    if not o.finished and o.text then out[#out + 1] = o.text end
  end
  return out
end

-- The first unfinished objective of a quest in your log, e.g. "4/8 Wolf Meat".
function HUD.ObjectiveText(questID)
  return HUD.Objectives(questID)[1]
end

-- The objectives as the box's lines: as many as fit, then how many more.
local function objectiveLines(list)
  if #list <= MAX_OBJECTIVES then return table.concat(list, "\n") end
  local shown = {}
  for i = 1, MAX_OBJECTIVES - 1 do shown[i] = list[i] end
  shown[#shown + 1] = string.format("|cff9d9d9d+%d more|r", #list - #shown)
  return table.concat(shown, "\n")
end

-- Where the current step is among the steps to the next stop (a journey) or
-- to the destination: position and count.
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

-- Lays the text out under the title, or under the progress bar on a journey.
local function place(trip)
  frame.progress:SetShown(trip)
  frame.step:ClearAllPoints()
  frame.step:SetPoint("TOPLEFT", trip and frame.progress or frame.title, "BOTTOMLEFT", 0, trip and -7 or -5)
  frame.step:SetPoint("RIGHT", -PADDING, 0)
  -- The title stops short of the buttons.
  local leftmost = trip and frame.skip or frame.close
  frame.title:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
end

---------------------------------------------------------------- on the way

-- Gathering as you go, above the box: shown while the journey has things
-- to gather, sized to its lines. The box's clamp counts it, so it stays on
-- screen with the box.
local function showGathering(rows)
  local section = frame.gathering
  local n = math.min(#rows, GATHER_ROWS)
  for i, r in ipairs(section.rows) do
    local row = i <= n and rows[i] or nil
    r.row = row
    r.text:SetText(row and row.text or "")
    r:SetShown(row ~= nil)
  end
  frame.gatheringHeight = n > 0 and ((n + 1) * GATHER_LINE + 2 * GATHER_PAD) or 0
  section:SetHeight(math.max(frame.gatheringHeight, 1))
  section:SetShown(n > 0)
  if frame.SetClampRectInsets then
    frame:SetClampRectInsets(0, 0, n > 0 and (frame.gatheringHeight + GATHER_GAP) or 0, 0)
  end
end

-- Looks again at what's on the way (every WAYSIDE_EVERY seconds, or now
-- when `force`): Gathering as you go above the box, the count of offers on
-- the + button while the drawer is closed, and the drawer itself while it's
-- open (or when you left it open).
local function refreshWayside(force)
  local now = GetTime and GetTime()
  if not force and now and frame.waysideAt and now - frame.waysideAt < WAYSIDE_EVERY then return end
  frame.waysideAt = now
  local ok, w = pcall(ns.Wayside.Get, false)
  if not ok then w = { gathering = {}, offers = {}, more = 0 } end
  frame.waysideCount = #w.offers + (w.more or 0)
  showGathering(w.gathering)
  ns.Drawer.Sync()
  local open = ns.Drawer.IsShown()
  frame.add.count:SetText((frame.waysideCount > 0 and not open) and tostring(frame.waysideCount) or "")
  if open and frame.add.LockHighlight then
    frame.add:LockHighlight()
  elseif frame.add.UnlockHighlight then
    frame.add:UnlockHighlight()
  end
end

-- The + button's count as shown, and the count behind it (for tests).
function HUD.Wayside()
  if not frame then return {} end
  return { badge = frame.add.count:GetText() or "", count = frame.waysideCount or 0 }
end

-- Gathering as you go, above the box (for tests): { shown, heading, rows =
-- the lines' text, top to bottom }.
function HUD.Gathering()
  if not frame then return { rows = {} } end
  local rows = {}
  for _, r in ipairs(frame.gathering.rows) do
    if r:IsShown() then rows[#rows + 1] = r.text:GetText() end
  end
  return { shown = frame.gathering:IsShown(), heading = frame.gathering.heading:GetText(), rows = rows }
end

-- What the drawer opens above when there's no room under the box: the
-- section above it when that shows, else the box.
function HUD.Top()
  if frame and frame.gathering:IsShown() then return frame.gathering end
  return frame
end

-- The step and its count, for the tooltip when the box shows only the stop
-- (nil when it shows them itself).
function HUD.StepTooltip()
  if not (frame and frame.stepHidden) then return nil end
  return { frame.stepText, frame.subText ~= "" and frame.subText or nil }
end

---------------------------------------------------------------- no journey on

-- Whether the small bar shows with no journey on (the options, /ww idle).
function HUD.IdleWanted()
  return ns.db ~= nil and ns.db.settings.idleBox ~= false
end

-- The best suggestion from your quest log among For you's results (most
-- relevant first; not XP), or nil.
local function logSuggestion(results)
  local best
  for _, r in ipairs(results or {}) do
    if LOG_KINDS[r.kind] and (r.journey or r.route) and (not best or (r.relevance or 0) > (best.relevance or 0)) then
      best = r
    end
  end
  return best
end
HUD.LogSuggestion = logSuggestion

-- The suggestion as For you has it now, without asking for a new build.
local function currentSuggestion()
  if not (ns.ForYou and ns.ForYou.Results) then return nil end
  local ok, results = pcall(ns.ForYou.Results)
  return ok and logSuggestion(results) or nil
end

-- The Suggest a journey button's tooltip: what it would start, and why.
function HUD.SuggestTooltip()
  local r = currentSuggestion()
  if not r then
    return { "Suggest a journey", "Starts a journey from your quest log and where you are: quests to hand in, "
      .. "or quests to finish close together." }
  end
  local lines = { r.title or "Suggest a journey" }
  if r.why then lines[#lines + 1] = r.why end
  lines[#lines + 1] = "Click to start it. Open Wayward for other ideas."
  return lines
end

-- Starts the best journey from your quest log, worked out afresh from here
-- (now, or when For you's build under way is done). Nothing to go on: says so.
function HUD.SuggestJourney()
  if not (ns.ForYou and ns.ForYou.WhenReady) or (frame and frame.suggesting) then return end
  if frame then frame.suggesting = true end
  ns.ForYou.WhenReady(function(results)
    if frame then frame.suggesting = nil end
    if ns.Nav.active then return end -- something else started meanwhile
    local r = logSuggestion(results)
    if r then
      ns.Panel.Activate(r)
    else
      ns.print(NOTHING_TO_SUGGEST)
    end
  end)
end

-- The x on the small bar: hidden until turned on again in the options.
function HUD.HideIdle()
  ns.SetSetting("idleBox", false)
  ns.print("The directions box now shows only while you're on a journey. /ww idle or the options bring the small bar back.")
end

-- The box as the small bar: the journey's parts hidden, the bar's shown.
local function showIdle()
  if not frame.idleMode then
    frame.idleMode = true
    for _, part in ipairs(frame.journeyParts) do part:Hide() end
    frame.idle:Show()
    frame.compass = nil -- applyCompass lays the box out again for the next journey
    frame.stepHidden = false
    frame:SetSize(IDLE_WIDTH, IDLE_HEIGHT)
    frame.width = IDLE_WIDTH
    if frame.SetClampRectInsets then frame:SetClampRectInsets(0, 0, 0, 0) end
    frame.close.tip = "Hide this bar while there's no journey (the options bring it back)"
  end
  frame:Show()
end

-- Back from the small bar to the directions box: Update shows what's needed.
local function leaveIdle()
  if not frame.idleMode then return end
  frame.idleMode = nil
  frame.idle:Hide()
  for _, part in ipairs({ frame.title, frame.step, frame.sub, frame.info, frame.add }) do part:Show() end
  frame.waysideAt = nil
end

-- Shows the box as it should be now: the directions, the small bar or nothing.
function HUD.Refresh()
  if not (ns.Nav.active or HUD.IdleWanted()) then
    if frame then frame:Hide() end
    return
  end
  frame = frame or create()
  frame:Show()
  HUD.Update()
end

-- Whether the small bar shows (for tests).
function HUD.IdleShown() return frame ~= nil and frame:IsShown() and frame.idleMode == true end

function HUD.Update()
  if not frame then return end
  local here, step = ns.Nav.Tick()
  local a = ns.Nav.active
  if not (a and step) then
    if not a and HUD.IdleWanted() then showIdle() else frame:Hide() end
    return
  end
  leaveIdle()
  applyCompass()
  local trip = a.journey ~= nil
  frame.list:SetShown(trip)
  frame.moveOn:SetShown(trip)
  frame.skip:SetShown(trip)
  frame.close.tip = trip and "End journey" or "Stop directions"
  refreshWayside()
  place(trip)

  -- One count each: stops done in the title, steps to the next stop (or to
  -- the destination) under the step, only when there's more than one.
  local progress = ns.Nav.Progress()
  if trip then
    frame.title:SetText(string.format("%s  |cff9d9d9d%d of %d done|r", progress.title or "", progress.done,
      progress.total))
    frame.progress:SetValue(progress.total > 0 and progress.done / progress.total or 0)
  else
    frame.title:SetText(a.title or "")
  end
  local position, count = legPosition(a)
  frame.stepText = ns.Router.Describe(a.route, a.index)
  frame.subText = count > 1 and string.format(trip and "Step %d of %d to get there" or "Step %d of %d", position, count)
    or ""
  -- Detail on demand: just the stop (and the compass), the step on hover.
  frame.stepHidden = ns.Nav.Detail() == "stops" and frame.stepText ~= progress.stopText
  local sub = frame.stepHidden and "" or frame.subText
  -- Gathering where you are (prototype): what for, and what's next once it's done.
  local gatherHere = ns.Nav.GatheringHere()
  if gatherHere then
    local q = ns.Quests.Quest(gatherHere.area.stop.action.questID)
    frame.stepText = "Gather here for " .. (q and q.name or "your quest")
    frame.stepHidden = false
    sub = "Then: " .. (gatherHere.stop.text or "the hand-in")
  end
  frame.step:SetText(frame.stepHidden and progress.stopText or frame.stepText)
  frame.sub:SetText(sub)

  -- A quest's objectives get their own lines between the step and the status.
  -- So does a hand-in still waiting on gathering: what it still needs.
  local gathering = ns.Journey.WaitsOnGathering(step.stop)
  local objectives = step.stop and step.stop.action and (step.stop.action.kind == "complete" or gathering)
    and HUD.Objectives(step.stop.action.questID) or {}
  -- Quests done together on these spots: theirs too, under the one stop.
  for i, s in ipairs(ns.Journey.Together(step.stop) or {}) do
    if i > 1 then
      for _, text in ipairs(HUD.Objectives(s.action.questID)) do objectives[#objectives + 1] = text end
    end
  end
  local objective = objectives[1]
  local above = sub ~= "" and frame.sub or frame.step
  -- Another spot, right of the objectives (or of where they'd be).
  local other = trip and not gatherHere and step.stop ~= nil and step.stop == ns.Nav.HeadingFor() and ns.Nav.CanOtherArea()
  frame.otherArea:SetShown(other)
  frame.otherArea:ClearAllPoints()
  frame.otherArea:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -3)
  frame.objectives:SetText(objectiveLines(objectives))
  frame.objectives:SetShown(objective ~= nil)
  frame.objectives:ClearAllPoints()
  frame.objectives:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -5)
  if other then
    frame.objectives:SetPoint("RIGHT", frame.otherArea, "LEFT", -6, 0)
  else
    frame.objectives:SetPoint("RIGHT", -PADDING, 0)
  end
  local function height(fs) return fs:GetStringHeight() or 12 end
  -- The objectives' lines, or the button beside them when that's taller.
  local besideHeight = objective and height(frame.objectives) or 0
  if other then besideHeight = math.max(besideHeight, OTHER_HEIGHT - 2) end
  frame.info:ClearAllPoints()
  frame.info:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -5 - besideHeight - (besideHeight > 0 and 5 or 0))
  frame.info:SetPoint("RIGHT", INFO_RIGHT, 0)

  -- To where the arrow points (past an area gathered in on the way).
  local aim = ns.Nav.Aim() or step.to
  local distance = here and ns.Geo.Distance(here, aim) or math.huge
  local remaining = TIME_ICON .. " " .. ns.FormatDuration(ns.Nav.RemainingSeconds(here))
  if gatherHere then
    -- Nothing waits for you here: walk on whenever you like.
    frame.info:SetText(string.format("|cff7fd1aeGathering here|r  ·  %s to go at your pace     %s",
      ns.FormatDuration(gatherHere.seconds), remaining))
  elseif objective and ns.Nav.InArea() then
    -- Among what you need: no arrow, just how it's going (and how long, at your pace here).
    if ns.Camps.LooksCleared(step.stop) then
      frame.info:SetText("|cffffd100Camp looks cleared|r     " .. remaining)
    else
      local left = ns.Camps.TimeLeft(step.stop)
      frame.info:SetText("|cff7fd1aeIn the area|r"
        .. (left and ("  ·  " .. ns.FormatDuration(left) .. " left here") or "") .. "     " .. remaining)
    end
  elseif objective and not gathering then
    -- On the way from a spot you've cleared to the next, or back to one respawning.
    local respawn = ns.Journey.RespawnIn(step.stop)
    local lead = respawn > 0 and ("|cff9d9d9dRespawns in " .. ns.FormatDuration(respawn) .. "|r     ")
      or ns.Journey.ClearedAreas(step.stop) > 0 and "|cff9d9d9dNext spot|r     " or ""
    frame.info:SetText(lead .. remaining)
  elseif ns.Nav.Interaction() == "fly" then
    frame.info:SetText(string.format("Pick %s on the flight map     %s", step.to.label or "your destination", remaining))
  elseif ns.Nav.Interaction() == "hearth" then
    frame.info:SetText(string.format("Use your Hearthstone     %s", remaining))
  elseif ns.Nav.Interaction() == "use" then
    frame.info:SetText(string.format("|cff7fd1aeYou're here:|r use %s     %s", (ns.Nav.TargetObject()), remaining))
  elseif ns.Nav.Interaction() == "enter" then
    frame.info:SetText("|cff7fd1aeYou're here:|r go in     " .. remaining)
  elseif ns.Nav.Interaction() == "talk" and not (step.stop and step.stop.action and step.stop.action.kind == "manual") then
    local name = ns.Nav.TargetNPC()
    local action = step.stop and step.stop.action
    local kind = action and action.kind
    frame.info:SetText(string.format("|cff7fd1aeYou're here:|r talk to %s%s     %s", name or "them",
      kind == "train" and (action.book and ", buy the book and read it" or " and train it")
        or kind == "learn" and " and train your spells" or "", remaining))
  elseif ns.Nav.Waiting() then
    -- A quest step only you can tell is done; spells to train.
    local kind = step.stop and step.stop.action and step.stop.action.kind
    frame.info:SetText((kind == "manual" and "|cff7fd1aeYou're here:|r do it, then move on (>>)"
      or kind == "learn" and "|cff7fd1aeYou're here:|r train your spells" or "|cff7fd1aeYou're here|r")
      .. "     " .. remaining)
  elseif distance < math.huge and step.mode == "walk" then
    frame.info:SetText(string.format("%s %d yd     %s", DISTANCE_ICON, math.floor(distance), remaining))
  else
    frame.info:SetText(remaining)
  end

  -- Grow to fit the text (titles and steps can wrap).
  local subHeight = sub ~= "" and (3 + height(frame.sub)) or 0
  local objectivesHeight = besideHeight > 0 and (5 + besideHeight) or 0
  frame:SetHeight(math.max(MIN_HEIGHT, PADDING * 2 + height(frame.title) + (trip and 16 or 5) + height(frame.step)
    + subHeight + objectivesHeight + 5 + height(frame.info)))

  local heading = facing()
  -- The compass points the way while you walk; otherwise its circle shows what's ahead.
  if step.mode == "walk" and distance < math.huge and heading and not ns.Nav.Waiting() and not ns.Nav.Flying()
      and not gatherHere then
    frame.arrow:SetRotation(ns.Geo.Bearing(here, aim) - heading)
    frame.arrow:Show()
    frame.icon:Hide()
  else
    frame.arrow:Hide()
    local action = (step.stop or {}).action
    local kind = gatherHere and "complete" or action and action.kind
    frame.icon:SetTexture(kind and STOP_ICONS[kind] or ns.RouteMap.TravelIcon(step) or WALK_ICON)
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
    if ns.Nav.active or HUD.IdleWanted() then HUD.Update() else frame:Hide() end
  end
  return frame
end

ns.Movers.Add({ key = "Directions", label = "Directions", posKey = "hudPos", home = HOME,
  frame = HUD.EnsureFrame, moved = function() ns.Fire("HUD_MOVED") end })

-- Whether the compass circle shows, and the box's width (for tests).
function HUD.CompassShown() return frame ~= nil and frame.holder:IsShown() end
function HUD.Width() return frame and frame.width end

-- The directions box's text: title, step, step count, status line, then the
-- objectives (shown between the step and the status; for tests).
function HUD.Lines()
  if not frame then return {} end
  return { frame.title:GetText(), frame.step:GetText(), frame.sub:GetText(), frame.info:GetText(),
    frame.objectives:IsShown() and frame.objectives:GetText() or "" }
end

-- Pulses the book button a few times: the journey has changed, its overview is a click away.
function HUD.FlashJourney()
  if frame then frame.flashLeft = FLASH_PERIOD * FLASH_PULSES end
end

-- Whether the book button is pulsing (for tests).
function HUD.Flashing() return frame ~= nil and frame.flashLeft ~= nil end

ns.Listen("SETTINGS_CHANGED", function(key)
  if (key == "showArrow" or key == "detail") and frame then HUD.Update() end
  if key == "idleBox" then HUD.Refresh() end
end)

-- With no journey to restore, the small bar from the start.
ns.On("PLAYER_LOGIN", function() HUD.Refresh() end)

ns.RegisterCommand("idle", "/ww idle - the small directions bar while there's no journey on or off", function()
  ns.SetSetting("idleBox", not HUD.IdleWanted())
  ns.print("small bar with no journey " .. (HUD.IdleWanted() and "on" or "off"))
end)

-- What's on the way: looked at again on the next update.
ns.On("QUEST_LOG_UPDATE", function() if frame then frame.waysideAt = nil end end)
ns.Listen("WAYSIDE_CHANGED", function() if frame then frame.waysideAt = nil end end)

ns.Listen("JOURNEY_EXTENDED", function()
  if not ns.JourneyOverview.IsShown() then HUD.FlashJourney() end
end)

ns.Listen("NAV_CHANGED", HUD.Refresh)
