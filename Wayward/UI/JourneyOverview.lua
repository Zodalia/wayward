local _, ns = ...

-- The whole journey at a glance (View Journey): every stop with done / now /
-- next, opened from the directions box (View Journey) and when a journey
-- with several stops starts.
-- At the top, a walkthrough: the selected stop and one of its steps, with
-- < and > to go back and forth along the steps, stop after stop (done ones
-- too, marked done). The steps are shown there only, not in the list. It
-- opens on the step you're on; a click on a stop in the list selects it,
-- and a click on the selected stop (or Now) goes back. The map under the
-- list draws the step you're on bold and the others faded; with another
-- stop or step selected, it zooms in on just that, so you can walk the
-- journey and see where each step takes you.
-- Its "..." menu (UI/Menu.lua) has what you do to a stop now and then: pin
-- it, move it up or down (the same as dragging, without the drag), do the
-- one you're on later (the directions box's >>), remove it (stops that need
-- it go with it). The stop you're on is lit: a faint gold band and a bar
-- down its left edge. Stops you've skipped or removed aren't listed.
-- Each stop still to go has the number its badge has on the maps (the
-- one here, the minimap's and the world map's), so you can find it there.
-- Drag an open stop up or down by its handle (or the row) to reorder the
-- journey, or pin one so re-plans as you go leave it where it is
-- (Nav.TogglePin); a pinned stop shows a lock, and clicking the lock unpins
-- it.
-- Finished stops fold into one line you can open;
-- they fold by themselves once there are AUTO_FOLD of them, or when showing
-- them would push open stops off the list.
-- Under the stops: an On the way button that opens that pane (UI/Drawer.lua:
-- what's around you to add, and a stop of your own), the journeys you set
-- aside (Nav.SetAside) with Resume and Forget, and a map of the rest under
-- a "Map" line that folds it (per character).
-- "Set aside" at the top sets the journey on now aside. With no journey on,
-- the window lists just the journeys set aside (the home screen's button).

local Overview = {}
ns.JourneyOverview = Overview

local MAX_ROWS = 10        -- the list is this many stop rows tall
local ROW_HEIGHT = 30
local POOL = MAX_ROWS      -- rows drawn at most
local SUGGEST_HEIGHT = 18  -- a set-aside row
local WAY_WIDTH = 96       -- the On the way button
local WAY_HEIGHT = 20
local SET_ASIDE = 5        -- set-aside journey rows (Nav keeps that many)
local HANDLE_WIDTH = 16
local NUMBER_WIDTH = 16    -- the stop's map number, before its name
-- The map badges' colours (RouteMap's MARK_COLOR): stops gold, the destination red.
local NUMBER_COLOR = { stop = "ffffd200", goal = "ffff4d33" }
local GRIP_COLOR = { 0.6, 0.6, 0.6, 0.8 }
local AUTO_FOLD = 3
local PIN_TEXTURE = "Interface\\Buttons\\LockButton-Locked-Up" -- on a pinned stop only

local TOP = -44            -- under the title and info line
local WALK_HEIGHT = 78     -- the walkthrough at the top, with the gap under it
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local DONE_COLOR, NOW_COLOR = { 0.5, 0.82, 0.68 }, { 1, 0.82, 0 } -- LOOK's done and now
-- On the map, the step the walkthrough shows, the rest of its stop's steps, the others.
local FOCUS_ALPHA = { step = 1, stop = 0.6, rest = 0.35 }

local frame
local HOME = { "TOPLEFT", "TOP", 170, -140 }
local focus -- the walkthrough's { stop, step } (step nil on a stop with none); nil: the step you're on
local unfolded -- nil: fold by the rule above; true / false: the player's choice for this journey
local scroll = 0 -- lines scrolled past at the top (the mouse wheel)
local dragging -- the row being dragged

-- The row under the cursor that a dragged stop can go to.
local function rowUnderCursor()
  for _, row in ipairs(frame.rows) do
    if row:IsShown() and row.movable and row:IsMouseOver() then return row end
  end
  return nil
end

local function endDrag()
  if not dragging then return end
  local from = dragging
  dragging = nil
  frame:SetScript("OnUpdate", nil)
  from.text:SetAlpha(1)
  frame.marker:Hide()
  local target = rowUnderCursor()
  if target and target ~= from then Overview.Move(from.rowIndex, target.rowIndex) end
end

-- While dragging, a line shows where the stop will go.
local function trackDrag()
  local target = rowUnderCursor()
  if not target or target == dragging then
    frame.marker:Hide()
    return
  end
  frame.marker:ClearAllPoints()
  local below = target.rowIndex > dragging.rowIndex
  frame.marker:SetPoint(below and "TOPLEFT" or "BOTTOMLEFT", target, below and "BOTTOMLEFT" or "TOPLEFT", 0, 0)
  frame.marker:SetPoint(below and "TOPRIGHT" or "BOTTOMRIGHT", target, below and "BOTTOMRIGHT" or "TOPRIGHT", 0, 0)
  frame.marker:Show()
end

local function create()
  local f = ns.Skin.CreateBox("WaywardJourneyOverview")
  f:SetSize(380, 64 + MAX_ROWS * ROW_HEIGHT)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "overviewPos")
  end)
  f:SetBackdropColor(0, 0, 0, 0.85)
  ns.RestorePosition(f, "overviewPos", HOME)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta) Overview.Scroll(delta) end)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 12, -10)
  f.title:SetPoint("RIGHT", -104, 0)
  f.title:SetJustifyH("LEFT")

  -- Set the journey on now aside: kept in the list below, to resume later.
  f.setAside = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.setAside:SetSize(70, 18)
  f.setAside:SetPoint("TOPRIGHT", -30, -8)
  f.setAside:SetText("Set aside")
  f.setAside:SetScript("OnClick", function()
    if ns.Nav.SetAside() then Overview.Show() end
  end)
  f.setAside:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Set this journey aside")
    GameTooltip:AddLine("It's kept with the stops you've done, to resume whenever you like.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  f.setAside:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Button(f.setAside)

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.info:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close = close
  close:SetPoint("TOPRIGHT", -2, -2)
  ns.Skin.CloseButton(close)
  ns.Skin.Text(f.title)
  ns.Skin.Text(f.info)

  -- The walkthrough: the selected stop, one of its steps, and < > along them.
  local w = CreateFrame("Frame", nil, f)
  w:SetSize(356, WALK_HEIGHT - 8)
  w:SetPoint("TOPLEFT", 12, TOP)
  w.band = w:CreateTexture(nil, "BACKGROUND")
  w.band:SetAllPoints()
  w.band:SetColorTexture(1, 1, 1, 0.04)
  -- Down its left edge, in the colour of what it shows: gold now, green done.
  w.bar = w:CreateTexture(nil, "ARTWORK")
  w.bar:SetPoint("TOPLEFT", -4, 0)
  w.bar:SetPoint("BOTTOMLEFT", -4, 0)
  w.bar:SetWidth(2)
  w.heading = w:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  w.heading:SetPoint("TOPLEFT", 6, -5)
  w.heading:SetJustifyH("LEFT")
  local function walkButton(label, width, tip, onClick)
    local b = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
    b:SetSize(width, 18)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(tip)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ns.Skin.Button(b)
    return b
  end
  w.next = walkButton(">", 24, "Next step", function() Overview.WalkBy(1) end)
  w.next:SetPoint("TOPRIGHT", -4, -3)
  w.prev = walkButton("<", 24, "Previous step", function() Overview.WalkBy(-1) end)
  w.prev:SetPoint("RIGHT", w.next, "LEFT", -2, 0)
  w.now = walkButton("Now", 40, "Back to the step you're on", function() Overview.FocusNow() end)
  w.now:SetPoint("RIGHT", w.prev, "LEFT", -6, 0)
  w.title = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  w.title:SetPoint("TOPLEFT", 6, -22)
  w.title:SetPoint("RIGHT", -6, 0)
  w.title:SetJustifyH("LEFT")
  w.title:SetWordWrap(false)
  w.zone = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  w.zone:SetPoint("TOPLEFT", w.title, "BOTTOMLEFT", 0, -2)
  w.zone:SetPoint("RIGHT", -6, 0)
  w.zone:SetJustifyH("LEFT")
  w.zone:SetWordWrap(false)
  -- The step: how you travel it (no icon for walking), what to do, and done / now.
  w.icon = w:CreateTexture(nil, "ARTWORK")
  w.icon:SetSize(14, 14)
  w.icon:SetPoint("TOPLEFT", 6, -50)
  w.state = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  w.state:SetPoint("TOPRIGHT", -6, -51)
  w.state:SetJustifyH("RIGHT")
  w.step = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  w.step:SetPoint("RIGHT", -52, 0)
  w.step:SetJustifyH("LEFT")
  w.step:SetJustifyV("TOP")
  w.step:SetWordWrap(true)
  if w.step.SetMaxLines then w.step:SetMaxLines(2) end
  for _, text in ipairs({ w.heading, w.title, w.zone, w.state, w.step }) do ns.Skin.Text(text) end
  w:Hide()
  f.walk = w

  f.rows = {}
  for i = 1, POOL do
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(356, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 12, -44 - (i - 1) * ROW_HEIGHT)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("TOPLEFT", HANDLE_WIDTH + 4, -2)
    row.text:SetPoint("RIGHT", -44, 0) -- short of the lock and "..."
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    -- The stop's number on the maps, in a column of its own.
    row.number = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.number:SetPoint("TOPLEFT", HANDLE_WIDTH + 2, -2)
    row.number:SetWidth(NUMBER_WIDTH)
    row.number:SetJustifyH("RIGHT")
    ns.Skin.Text(row.number)
    -- Where the stop is, so a journey across several zones reads at a glance.
    row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.zone:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -2)
    row.zone:SetPoint("RIGHT", -44, 0)
    row.zone:SetJustifyH("LEFT")
    ns.Skin.Text(row.zone)
    -- More: pin, move up or down, remove (Overview.StopMenu).
    row.more = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.more:SetSize(24, 16)
    row.more:SetPoint("RIGHT", 0, 0)
    row.more:SetText("...")
    row.more:SetScript("OnClick", function(self) ns.Menu.Show(self, Overview.StopMenu(row.stop)) end)
    row.more:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("More: pin, move or remove this stop")
      GameTooltip:Show()
    end)
    row.more:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ns.Skin.Button(row.more)
    -- A lock on a pinned stop (Nav.TogglePin), so you can see why it stays
    -- put; click it to unpin. Pinning is in the "..." menu.
    row.pin = CreateFrame("Button", nil, row)
    row.pin:SetSize(14, 14)
    row.pin:SetPoint("RIGHT", row.more, "LEFT", -6, 0)
    row.pin:SetNormalTexture(PIN_TEXTURE)
    row.pin:SetScript("OnClick", function()
      GameTooltip:Hide()
      ns.Nav.TogglePin(row.stop)
    end)
    row.pin:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Pinned: click to unpin")
      GameTooltip:AddLine("It keeps its place when the journey re-plans. Unpinned, re-plans can move it again.",
        0.6, 0.6, 0.6, true)
      GameTooltip:Show()
    end)
    row.pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.pin:Hide()
    ns.Skin.Text(row.text)
    row.index = i
    local function startDrag()
      if not row.movable then return end
      row.dragged = true -- this press is a drag, not a click (OnMouseUp)
      dragging = row
      row.text:SetAlpha(0.4)
      f:SetScript("OnUpdate", trackDrag)
    end
    row:EnableMouse(true)
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", startDrag)
    row:SetScript("OnDragStop", endDrag)

    -- The handle on the left: a three-line grip you drag the stop by.
    row.handle = CreateFrame("Button", nil, row)
    row.handle:SetSize(HANDLE_WIDTH, ROW_HEIGHT - 4)
    row.handle:SetPoint("LEFT", 0, 0)
    row.handle.lines = {}
    for k = 1, 3 do
      local line = row.handle:CreateTexture(nil, "ARTWORK")
      line:SetSize(10, 2)
      line:SetPoint("CENTER", 0, (2 - k) * 4)
      line:SetColorTexture(GRIP_COLOR[1], GRIP_COLOR[2], GRIP_COLOR[3], GRIP_COLOR[4])
      row.handle.lines[k] = line
    end
    -- On the finished-stops line instead: open or fold them.
    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetSize(14, 14)
    row.toggle:SetPoint("LEFT", 1, 0)
    row.toggle:SetScript("OnClick", function() Overview.ToggleFinished() end)
    row.toggle:Hide()
    -- A click on the finished-stops line opens or folds them; on a stop, it
    -- shows in the walkthrough (Overview.Select). Not at the end of a drag.
    row:SetScript("OnMouseDown", function(self) self.dragged = nil end)
    row:SetScript("OnMouseUp", function(self, button)
      if self.dragged then self.dragged = nil return end
      if button and button ~= "LeftButton" then return end
      if self.header then
        Overview.ToggleFinished()
      elseif self.stop then
        Overview.Select(self.stop)
      end
    end)
    row.handle:RegisterForDrag("LeftButton")
    row.handle:SetScript("OnDragStart", startDrag)
    row.handle:SetScript("OnDragStop", endDrag)
    row.handle:SetScript("OnEnter", function(self)
      for _, line in ipairs(self.lines) do line:SetColorTexture(1, 0.82, 0, 1) end
      row.hover:Show()
      if SetCursor then SetCursor("UI_MOVE_CURSOR") end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText("Drag to reorder")
      GameTooltip:Show()
    end)
    row.handle:SetScript("OnLeave", function(self)
      for _, line in ipairs(self.lines) do
        line:SetColorTexture(GRIP_COLOR[1], GRIP_COLOR[2], GRIP_COLOR[3], GRIP_COLOR[4])
      end
      row.hover:Hide()
      if ResetCursor then ResetCursor() end
      GameTooltip:Hide()
    end)
    -- The stop you're on: a faint gold band, and a bar down its left edge.
    row.current = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    row.current:SetAllPoints()
    row.current:SetColorTexture(1, 0.82, 0, 0.08)
    row.current:Hide()
    row.currentBar = row:CreateTexture(nil, "ARTWORK")
    row.currentBar:SetPoint("TOPLEFT", -4, 0)
    row.currentBar:SetPoint("BOTTOMLEFT", -4, 0)
    row.currentBar:SetWidth(2)
    row.currentBar:SetColorTexture(1, 0.82, 0, 0.9)
    row.currentBar:Hide()
    -- The stop or step the walkthrough at the top shows: a faint blue band.
    row.selected = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(0.55, 0.75, 1, 0.12)
    row.selected:Hide()
    row.hover = row:CreateTexture(nil, "BACKGROUND")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1, 1, 1, 0.06)
    row.hover:Hide()
    row:SetScript("OnEnter", function(self)
      if self.movable then self.hover:Show() end
      Overview.ShowStopTooltip(self)
    end)
    row:SetScript("OnLeave", function(self)
      self.hover:Hide()
      if self.tooltip then
        self.tooltip = nil
        GameTooltip:Hide()
      end
    end)
    f.rows[i] = row
  end
  f.marker = f:CreateTexture(nil, "OVERLAY")
  f.marker:SetHeight(2)
  f.marker:SetColorTexture(1, 0.82, 0, 0.9)
  f.marker:Hide()

  -- What's around you to add, and a stop of your own: in the On the way
  -- pane (UI/Drawer.lua), a click away rather than listed here.
  f.onTheWay = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.onTheWay:SetSize(WAY_WIDTH, WAY_HEIGHT)
  f.onTheWay:SetText("On the way")
  -- Opens it, or brings it to the front when it's open already.
  f.onTheWay:SetScript("OnClick", function()
    local pane = ns.Drawer.IsShown() and ns.Drawer.Frame()
    if not pane then ns.Drawer.Toggle() elseif pane.Raise then pane:Raise() end
  end)
  f.onTheWay:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("On the way")
    GameTooltip:AddLine("What's around you that you could add, and a detour of your own: repair, vendor, mailbox, "
      .. "bank...", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  f.onTheWay:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Button(f.onTheWay)
  f.onTheWay:Hide()
  -- Journeys set aside: resume one (the journey on now is set aside in its place), or forget it.
  f.asideHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.asideHeader:SetJustifyH("LEFT")
  f.asideHeader:SetText("Set aside")
  ns.Skin.Text(f.asideHeader)
  f.aside = {}
  for i = 1, SET_ASIDE do
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(356, SUGGEST_HEIGHT)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", -112, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row.forget = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.forget:SetSize(50, 16)
    row.forget:SetPoint("RIGHT", 0, 0)
    row.forget:SetText("Forget")
    row.forget:SetScript("OnClick", function() ns.Nav.ForgetSetAside(i) end)
    row.resume = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.resume:SetSize(54, 16)
    row.resume:SetPoint("RIGHT", row.forget, "LEFT", -4, 0)
    row.resume:SetText("Resume")
    -- Setting the journey on now aside closes the overview for a moment (no
    -- journey); the one resumed from here comes back up in it.
    row.resume:SetScript("OnClick", function()
      if ns.Nav.ResumeSetAside(i) then Overview.Show() end
    end)
    ns.Skin.Button(row.forget)
    ns.Skin.Button(row.resume)
    ns.Skin.Text(row.text)
    row:Hide()
    f.aside[i] = row
  end
  -- The rest of the journey on a map, under a line that folds it.
  f.mapHeader = CreateFrame("Button", nil, f)
  f.mapHeader:SetSize(356, 16)
  f.mapHeader.toggle = f.mapHeader:CreateTexture(nil, "ARTWORK")
  f.mapHeader.toggle:SetSize(14, 14)
  f.mapHeader.toggle:SetPoint("LEFT", 0, 0)
  f.mapHeader.text = f.mapHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.mapHeader.text:SetPoint("LEFT", f.mapHeader.toggle, "RIGHT", 4, 0)
  f.mapHeader.text:SetText("Map")
  f.mapHeader:SetScript("OnClick", function() Overview.ToggleMap() end)
  f.mapHeader:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(Overview.MapShown() and "Hide the map" or "Show the map of the rest of the journey")
    GameTooltip:Show()
  end)
  f.mapHeader:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Text(f.mapHeader.text)
  f.mapHeader:Hide()
  f.map = ns.RouteMap.NewView(f, 356)
  f.map.canvas:Hide()

  f.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 12, 8)
  ns.Skin.Text(f.more)
  ns.Skin.Box(f)
  -- A controller's cursor moves through it on Forever, and scrolls the
  -- stops (the d-pad off the first or last shown, or the right stick).
  ns.Pad.Window(f, { closeButton = f.close })
  ns.Pad.List(f, {
    rows = function() return f.rows end,
    at = function() return scroll, Overview.maxScroll or 0 end,
    scroll = function(delta) Overview.Scroll(delta) end,
  })
  f:Hide()
  return f
end

-- A quest stop's tooltip: what the quest's chain leads to (Quests.ChainText).
-- Returns the text shown, or nil.
function Overview.StopTooltipText(stop)
  local questID = stop and stop.action and stop.action.questID
  return questID and ns.Quests.ChainText(questID) or nil
end

function Overview.ShowStopTooltip(row)
  local text = Overview.StopTooltipText(row.stop)
  if not (text and GameTooltip) then return end
  row.tooltip = true
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetText(row.stop.text or "", 1, 1, 1, 1, true)
  for line in text:gmatch("[^\n]+") do GameTooltip:AddLine(line, 0.5, 0.82, 0.68, true) end
  GameTooltip:Show()
end

-- The stop the current step leads to.
local function currentStop(a)
  for k = a.index, #a.route.steps do
    local stop = a.route.steps[k].stop
    if stop then return stop end
  end
  return nil
end

-- { {stop, state} } with state "done", "now" or "next". Stops you skipped
-- (or passed with the old next button) are left out.
function Overview.Rows()
  local a = ns.Nav.active
  if not (a and a.journey) then return {} end
  local now = currentStop(a)
  local rows = {}
  for _, stop in ipairs(ns.Journey.AllStops(a.journey)) do
    if not (stop.skipped or stop.passed) then
      -- A quest done together with the stop you're on is on now too.
      local state = stop.done and "done" or (stop == now or (now and stop.joined == now)) and "now"
        or stop.gather and "gather" or "next"
      rows[#rows + 1] = { stop = stop, state = state }
    end
  end
  -- Done stops first, in the order they happened to be listed; what you
  -- gather as you go right under the stop you're on.
  local order = { done = 1, now = 2, gather = 3, next = 4 }
  local keyed = {}
  for i, r in ipairs(rows) do keyed[i] = { r = r, i = i } end
  table.sort(keyed, function(x, y)
    if order[x.r.state] ~= order[y.r.state] then return order[x.r.state] < order[y.r.state] end
    return x.i < y.i
  end)
  for i, k in ipairs(keyed) do rows[i] = k.r end
  return rows
end

local LOOK = {
  done = { "|cff7fd1aedone|r  ", 0.6 },
  now = { "|cffffd200now|r  ", 1 },
  next = { "      ", 1 },
  gather = { "|cff80c0ffas you go|r  ", 0.9 },
}

local FINISHED = { done = true }

-- Where your Hearthstone takes you on the way to `stop`, when the plan
-- uses it there and you haven't yet (steps from `from` on), else nil: a line
-- off to your inn on the map then has its reason in the list.
function Overview.HearthBefore(steps, from, stop)
  local hearth
  for i, step in ipairs(steps or {}) do
    if step.mode == "hearth" and i >= (from or 1) then hearth = step.to and step.to.label end
    if step.stop then
      if step.stop == stop then return hearth end
      hearth = nil
    end
  end
  return nil
end

-- The number each stop still to go has on the maps, { [stop] = number },
-- and the stop at the end (the maps' destination badge): numbered as the
-- maps number the steps from the one you're on (RouteMap.StepNumbers), so a
-- lone stop has none, as there.
function Overview.StopNumbers()
  local a = ns.Nav.active
  local numbers, goal = {}, nil
  if not (a and a.route and a.route.steps) then return numbers end
  local steps = {}
  for k = a.index or 1, #a.route.steps do steps[#steps + 1] = a.route.steps[k] end
  for i, n in pairs(ns.RouteMap.StepNumbers(steps)) do
    if steps[i].stop then numbers[steps[i].stop] = n end
    if i == #steps then goal = steps[i].stop end
  end
  return numbers, goal
end

-- What the list shows, top to bottom: the finished stops' line (when there
-- are any), those stops unless folded, then the open ones. Their steps are
-- in the walkthrough at the top, not here.
--   { header = true, count, folded } or { row = Rows() entry, index }
function Overview.Lines()
  local rows = Overview.Rows()
  local finished = 0
  for _, r in ipairs(rows) do
    if FINISHED[r.state] then finished = finished + 1 end
  end
  local folded = unfolded == false
    or (unfolded == nil and (finished >= AUTO_FOLD or #rows + 1 > MAX_ROWS))
  local lines = {}
  if finished > 0 then lines[1] = { header = true, count = finished, folded = folded } end
  for i, r in ipairs(rows) do
    if not (folded and FINISHED[r.state]) then lines[#lines + 1] = { row = r, index = i } end
  end
  return lines, rows
end

-------------------------------------------------------------- walkthrough

-- Every step of the journey so far and still to go: the ones walked before
-- it was last planned again (Nav keeps them), then the plan's. Returns them
-- as a route ({ steps }) and the index of the step you're on.
function Overview.Trail()
  local a = ns.Nav.active
  if not (a and a.route and a.route.steps) then return { steps = {} }, 1 end
  local steps = {}
  for _, step in ipairs(a.walked or {}) do steps[#steps + 1] = step end
  local walked = #steps
  for _, step in ipairs(a.route.steps) do steps[#steps + 1] = step end
  return { steps = steps }, walked + (a.index or 1)
end

-- The steps of `steps` that lead to `stop`: first, last (indexes), or nil.
-- The last time it's reached, in case it was headed for before a re-plan.
local function legIn(steps, stop)
  for i = #steps, 1, -1 do
    if steps[i].stop == stop then
      local first = i
      while first > 1 and not steps[first - 1].stop do first = first - 1 end
      return first, i
    end
  end
  return nil
end

-- What a stop with no steps of its own says in their place.
local function noSteps(stop, state)
  if state == "done" then return "Done along the way." end
  if state == "gather" then return "Gathered as you go, wherever it turns up." end
  if stop.joined then
    return string.format("Done together with %s.", stop.joined.text or "the stop you're on")
  end
  return "No way there planned yet."
end

-- What the walkthrough goes through, in the list's order: each stop's
-- steps one by one (one entry for a stop with none). Each entry:
--   { stop, state (the stop's: done / now / gather / next), stopNumber,
--     stops, step?, stepIndex? (in Trail), first?, last? (its stop's steps),
--     stepNumber?, stepCount?, stepState? (done / now / next) }
-- Returns the entries, the entry of the step you're on, and the trail.
function Overview.Walk()
  local a = ns.Nav.active
  if not (a and a.journey) then return {}, nil end
  local trail, cur = Overview.Trail()
  local rows = Overview.Rows()
  local out, at = {}, nil
  for n, r in ipairs(rows) do
    local first, last = legIn(trail.steps, r.stop)
    if first then
      for k = first, last do
        out[#out + 1] = { stop = r.stop, state = r.state, stopNumber = n, stops = #rows,
          step = trail.steps[k], stepIndex = k, first = first, last = last,
          stepNumber = k - first + 1, stepCount = last - first + 1,
          stepState = k < cur and "done" or k == cur and "now" or "next" }
        if k == cur then at = #out end
      end
    else
      out[#out + 1] = { stop = r.stop, state = r.state, stopNumber = n, stops = #rows }
    end
  end
  if not at then
    for i, p in ipairs(out) do
      if p.state == "now" then at = i break end
    end
  end
  return out, at or (#out > 0 and 1 or nil), trail, cur
end

-- The entry the walkthrough shows: the one selected, else the step you're on.
local function focused(walk, at)
  if focus then
    for i, p in ipairs(walk) do
      if focus.step and p.step == focus.step then return i end
    end
    for i, p in ipairs(walk) do
      if p.stop == focus.stop then return i end
    end
    focus = nil -- gone from the journey
  end
  return at
end

-- Selects `stop` (its step `step`, else its first, or the one you're on if
-- it's the stop you're on) for the walkthrough. `quiet`: not drawn yet (a
-- refresh follows).
function Overview.Focus(stop, step, quiet)
  if not stop then return end
  local walk, at = Overview.Walk()
  local now = at and walk[at]
  if now and now.stop == stop and (step == nil or step == now.step) then
    focus = nil
  else
    focus = { stop = stop, step = step }
  end
  if not quiet then Overview.Refresh() end
end

-- A click on a stop in the list: shows it in the walkthrough. A click on
-- the one shown, when it isn't where you are, goes back to the step you're on.
function Overview.Select(stop)
  if not stop then return end
  local walk, at = Overview.Walk()
  local i = at and focused(walk, at)
  if i and i ~= at and walk[i].stop == stop then
    focus = nil
    Overview.Refresh()
  else
    Overview.Focus(stop)
  end
end

-- Back to the step you're on.
function Overview.FocusNow()
  focus = nil
  Overview.Refresh()
end

-- The walkthrough `by` steps on (1) or back (-1). False at either end.
function Overview.WalkBy(by)
  local walk, at = Overview.Walk()
  local i = at and focused(walk, at)
  local p = i and walk[i + by]
  if not p then return false end
  focus = (i + by ~= at) and { stop = p.stop, step = p.step } or nil
  Overview.Refresh()
  return true
end

-- Fills in the walkthrough for entry `i` of `walk`; returns its height
-- (with the gap under it), 0 when there's nothing to show.
function Overview.LayoutWalk(walk, i, at, trail)
  local w = frame.walk
  local p = i and walk[i]
  Overview.walk = p and { index = i, count = #walk, entry = p } or nil
  if not p then
    w:Hide()
    return 0
  end
  local a = ns.Nav.active
  local tag = p.state == "done" and ("  ·  |cff7fd1ae" .. CHECK .. " done|r")
    or p.state == "now" and "  ·  |cffffd200now|r" or p.state == "gather" and "  ·  |cff80c0ffas you go|r" or ""
  w.heading:SetText(string.format("Stop %d of %d%s", p.stopNumber, p.stops, tag))
  w.title:SetText(p.stop.text or (p.stop.node and p.stop.node.label) or "?")
  w.title:SetAlpha(p.state == "done" and 0.7 or 1)
  local zone = ns.Journey.StopZone(p.stop)
  local hearth = p.state ~= "done" and Overview.HearthBefore(a.route.steps, a.index, p.stop)
  if hearth then
    hearth = "hearth to " .. hearth .. " first"
    zone = zone and (zone .. "  ·  " .. hearth) or hearth
  end
  w.zone:SetText(zone or "")
  local state = p.step and p.stepState or (p.state == "done" and "done") or (p.state == "now" and "now") or nil
  local icon = p.step and ns.RouteMap.TravelIcon(p.step)
  w.icon:SetTexture(icon)
  w.icon:SetShown(icon ~= nil)
  w.step:ClearAllPoints()
  if icon then
    w.step:SetPoint("TOPLEFT", w.icon, "TOPRIGHT", 4, -1)
  else
    w.step:SetPoint("TOPLEFT", 6, -51)
  end
  w.step:SetPoint("RIGHT", -52, 0)
  if p.step then
    w.step:SetText(string.format("Step %d of %d  ·  %s  ·  %s", p.stepNumber, p.stepCount,
      ns.Router.Describe(trail, p.stepIndex, true), ns.FormatDuration(p.step.seconds)))
  else
    w.step:SetText(noSteps(p.stop, p.state))
  end
  w.step:SetAlpha(state == "done" and 0.6 or 1)
  w.state:SetText(state == "done" and ("|cff7fd1ae" .. CHECK .. " Done|r") or state == "now" and "|cffffd200Now|r" or "")
  local color = state == "done" and DONE_COLOR or state == "now" and NOW_COLOR
  w.bar:SetShown(color and true or false)
  if color then w.bar:SetColorTexture(color[1], color[2], color[3], 0.9) end
  w.prev:SetEnabled(i > 1)
  w.next:SetEnabled(i < #walk)
  w.now:SetShown(i ~= at)
  w:Show()
  return WALK_HEIGHT
end

-- What the map draws with the walkthrough on entry `p`: the steps and
-- DrawRoute's opts. On the step you're on: the rest of the journey from it
-- (`cur`, in Trail's `steps`), that step bold and opaque, the rest of its
-- stop's steps a little faded, the others more. With another stop or step
-- selected (`away`): only that, so the map zooms in on it; a stop selected
-- from the list shows all its steps, one walked to with < > just that step
-- (bold, its stop's other steps left out). A start badge where it begins
-- (not your arrow: you may be elsewhere), and its stop in the list's colour
-- and number (green, unnumbered, when done).
function Overview.MapFocus(p, steps, cur, away)
  local opts = {}
  if not (away and p) then
    local drawn = {}
    for k = cur, #steps do drawn[#drawn + 1] = steps[k] end
    if p and p.step and p.stepIndex >= cur then
      local f, first, last = p.stepIndex - cur + 1, p.first - cur + 1, p.last - cur + 1
      opts.focus = f
      opts.alpha = function(i)
        if i == f then return FOCUS_ALPHA.step end
        if i >= first and i <= last then return FOCUS_ALPHA.stop end
        return FOCUS_ALPHA.rest
      end
    end
    return drawn, opts
  end
  local numbers, goal = Overview.StopNumbers()
  local function kindOf(stop)
    if stop.done then return "done" end
    return stop == goal and "goal" or "stop"
  end
  local drawn = {}
  if not p.step then
    -- A stop with no steps of its own: just where it is.
    local node = p.stop.node
    if not node then return {}, opts end
    drawn[1] = { from = node, to = node, mode = "walk", seconds = 0, stop = p.stop }
    opts.you = false
  else
    local wholeStop = not (focus and focus.step)
    local from, to = p.stepIndex, p.stepIndex
    if wholeStop then from, to = p.first, p.last end
    for k = from, to do drawn[#drawn + 1] = steps[k] end
    opts.you = "start"
    if wholeStop and #drawn > 1 then
      local f = p.stepIndex - from + 1
      opts.focus = f
      opts.alpha = function(i) return i == f and FOCUS_ALPHA.step or FOCUS_ALPHA.stop end
    else
      opts.focus = 1
    end
  end
  local last = drawn[#drawn]
  if last.stop then
    opts.last = kindOf(last.stop)
    opts.numbers = { [#drawn] = not last.stop.done and numbers[last.stop] or nil }
  else
    opts.last = false -- a step part way to its stop: nothing to mark where it ends
    opts.numbers = {}
  end
  return drawn, opts
end

-- What the walkthrough shows (for tests): { index, count, entry, heading,
-- title, step, state, prev, next, now } or nil.
function Overview.Walkthrough()
  local w = frame and frame.walk
  if not (w and w:IsShown() and Overview.walk) then return nil end
  local out = {}
  for key, value in pairs(Overview.walk) do out[key] = value end
  out.heading, out.title, out.step, out.state = w.heading:GetText(), w.title:GetText(), w.step:GetText(),
    w.state:GetText()
  out.now = w.now:IsShown()
  out.prev, out.next = out.index > 1, out.index < out.count
  return out
end

-- The nearest stop above (`by` -1) or below (+1) row `at` that can be moved,
-- as its index in `rows`, or nil.
local function movableNeighbour(rows, at, by)
  local i = at + by
  while rows[i] do
    if rows[i].state == "now" or rows[i].state == "next" then return i end
    i = i + by
  end
  return nil
end

-- A stop's "..." menu: what you do to a stop now and then. Moving up or down
-- is a drag without the drag (the same rules: not before a stop it needs,
-- and the order is yours from then on). {} for a stop that's finished or gone.
function Overview.StopMenu(stop)
  local a = ns.Nav.active
  if not (a and a.journey and stop) then return {} end
  local rows = Overview.Rows()
  local at
  for i, r in ipairs(rows) do
    if r.stop == stop then at = i end
  end
  local r = at and rows[at]
  if not r or FINISHED[r.state] then return {} end
  local root = a.journey.root or a.journey.def
  local items = {}
  if r.state == "now" or r.state == "next" then
    -- No pins on an order you made yourself: all of it keeps its place.
    if not root.manual then
      if ns.Journey.IsPinned(stop) then
        items[#items + 1] = { text = "Unpin stop", onClick = function() ns.Nav.TogglePin(stop) end,
          tip = "Re-plans can move it again." }
      else
        items[#items + 1] = { text = "Pin stop", onClick = function() ns.Nav.TogglePin(stop) end,
          tip = "It keeps its place when the journey re-plans; the stops around it can still change." }
      end
    end
    -- The stop you're heading for: later, as the directions box's >> does.
    if stop == ns.Nav.HeadingFor() and ns.Nav.MoveOnKind() == "later" then
      items[#items + 1] = { text = "Do this stop later", onClick = function() ns.Nav.MoveOn() end,
        tip = "The journey does the next stop first and fits this one in after." }
    end
    local up, down = movableNeighbour(rows, at, -1), movableNeighbour(rows, at, 1)
    local yours = "Like dragging it: the order is yours from then on, and re-plans keep it."
    if up then
      items[#items + 1] = { text = "Move up", onClick = function() Overview.Move(at, up) end, tip = yours }
    end
    if down then
      items[#items + 1] = { text = "Move down", onClick = function() Overview.Move(at, down) end, tip = yours }
    end
  end
  items[#items + 1] = { text = "Remove stop", onClick = function() ns.Nav.Drop(stop) end,
    tip = "Takes it off the journey, with any stops that need it." }
  return items
end

function Overview.ToggleFinished()
  local lines = Overview.Lines()
  unfolded = not (lines[1] and lines[1].header and not lines[1].folded)
  Overview.Refresh()
end

-- The set-aside journeys' rows from `y` down, under their header when
-- `header`; returns the y under them.
function Overview.LayoutSetAside(y, header)
  local aside = ns.Nav.SetAsideList and ns.Nav.SetAsideList() or {}
  frame.asideHeader:ClearAllPoints()
  frame.asideHeader:SetPoint("TOPLEFT", 12, y)
  frame.asideHeader:SetShown(header and #aside > 0)
  if header and #aside > 0 then y = y - 16 end
  for i, row in ipairs(frame.aside) do
    local entry = aside[i]
    if entry then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 12, y)
      row.text:SetText(string.format("%s%s  |cff9d9d9d%d stop%s left, %s|r",
        entry.icon and ("|T" .. entry.icon .. ":12:12|t ") or "", entry.title or "?", entry.stops or 0,
        entry.stops == 1 and "" or "s", ns.Nav.SetAsideAge(entry)))
      row:Show()
      y = y - SUGGEST_HEIGHT
    else
      row:Hide()
    end
  end
  return y
end

-- With no journey on: just the journeys set aside, each with Resume and
-- Forget. False (nothing drawn) when there are none.
function Overview.RefreshSetAside()
  local aside = ns.Nav.SetAsideList and ns.Nav.SetAsideList() or {}
  if #aside == 0 then return false end
  frame.title:SetText("Journeys set aside")
  frame.info:SetText("Resume one from where you are, or forget it.")
  frame.setAside:Hide()
  frame.walk:Hide()
  for _, row in ipairs(frame.rows) do row:Hide() end
  frame.onTheWay:Hide()
  frame.map.canvas:Hide()
  frame.mapHeader:Hide()
  frame.marker:Hide()
  frame.more:SetText("")
  local y = Overview.LayoutSetAside(TOP, false)
  frame.height = -y + 14
  frame:SetHeight(frame.height)
  return true
end

function Overview.Refresh()
  if not (frame and frame:IsShown()) then return end
  local a = ns.Nav.active
  if not (a and a.journey) then
    -- No journey on: the ones set aside by themselves (the home screen's
    -- button), or nothing to show. Plain directions have no overview.
    -- Only when asked for (`listing`): a journey that ends closes the window.
    if a or not frame.listing or not Overview.RefreshSetAside() then frame:Hide() end
    return
  end
  frame.listing = nil
  frame.setAside:Show()
  local lines, rows = Overview.Lines()
  local numbers, goal = Overview.StopNumbers()
  local root = a.journey.root or a.journey.def
  local done = 0
  for _, r in ipairs(rows) do
    if r.state == "done" then done = done + 1 end
  end
  frame.title:SetText(a.title)
  frame.info:SetText(string.format("%d of %d stops done  ·  %s to go%s", done, #rows,
    ns.FormatDuration(ns.Nav.TimeLeft(ns.Geo.PlayerNode())),
    root.manual and "  ·  your order" or "  ·  drag stops to reorder"))
  -- The walkthrough at the top, the list under it.
  local walk, at, trail, cur = Overview.Walk()
  local walkIndex = at and focused(walk, at)
  local shownEntry = walkIndex and walk[walkIndex]
  local top = TOP - Overview.LayoutWalk(walk, walkIndex, at, trail)
  -- Rows one under the other, as many as fit. Scrolled: from line
  -- scroll + 1. A list that needs scrolling keeps the full height, and
  -- stops once its last line shows.
  local room, used, shown = MAX_ROWS * ROW_HEIGHT, 0, 0
  local maxScroll = math.max(0, #lines - MAX_ROWS)
  scroll = math.max(0, math.min(scroll, maxScroll))
  Overview.maxScroll = maxScroll
  for i, row in ipairs(frame.rows) do
    local line = lines[scroll + i]
    local height = line and ROW_HEIGHT or 0
    if line and used + height > room then line = nil end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 12, top - used)
    row:SetHeight(math.max(height, 1))
    if line then
      used = used + height
      shown = shown + 1
    end
    local r = line and line.row
    row.stop, row.rowIndex, row.header = r and r.stop, line and line.index, line and line.header
    row.canPin = nil
    local lit = r ~= nil and r.state == "now"
    row.current:SetShown(lit)
    row.currentBar:SetShown(lit)
    -- The stop the walkthrough shows.
    row.selected:SetShown(shownEntry ~= nil and r ~= nil and r.stop == shownEntry.stop)
    -- Stop rows leave room for the number; the other lines don't need it.
    row.text:ClearAllPoints()
    row.text:SetPoint("TOPLEFT", HANDLE_WIDTH + 4 + (r and NUMBER_WIDTH + 2 or 0), -2)
    row.text:SetPoint("RIGHT", -44, 0)
    local number = r and not FINISHED[r.state] and numbers[r.stop]
    row.number:SetText(number and string.format("|c%s%d|r", NUMBER_COLOR[r.stop == goal and "goal" or "stop"], number)
      or "")
    if line and line.header then
      row.text:SetText(string.format("|cff9d9d9d%s finished|r  %s", line.count == 1 and "1 stop" or (line.count .. " stops"),
        line.folded and "(click to show)" or "(click to hide)"))
      row.zone:SetText("")
      row.text:SetAlpha(1)
      row.movable = false
      row.more:Hide()
      row.pin:Hide()
      row.handle:Hide()
      local texture = line.folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up"
      row.toggle:SetNormalTexture(texture)
      row.toggle:Show()
      row:Show()
    elseif r then
      local look = LOOK[r.state]
      row.text:SetText(look[1] .. (r.stop.text or (r.stop.node and r.stop.node.label) or "?"))
      local zone = ns.Journey.StopZone(r.stop)
      local hearth = not FINISHED[r.state] and Overview.HearthBefore(a.route.steps, a.index, r.stop)
      if hearth then
        hearth = "hearth to " .. hearth .. " first"
        zone = zone and (zone .. "  ·  " .. hearth) or hearth
      end
      row.zone:SetText(zone and ("      " .. zone) or "")
      row.text:SetAlpha(look[2])
      row.movable = r.state == "now" or r.state == "next"
      row.more:SetShown(r.state == "now" or r.state == "next" or r.state == "gather")
      -- No pins on an order you dragged yourself: all of it keeps its place.
      -- The lock shows on a pinned stop only; pinning is in the menu.
      row.canPin = row.movable and not root.manual
      row.pin:SetShown(row.canPin and ns.Journey.IsPinned(r.stop))
      row.handle:SetShown(row.movable)
      row.toggle:Hide()
      row:Show()
    else
      row:Hide()
    end
  end
  local below = #lines - scroll - shown
  frame.more:SetText((scroll > 0 or below > 0) and string.format("%s%s  ·  scroll for more",
    scroll > 0 and (scroll .. " above") or "", below > 0 and ((scroll > 0 and ", " or "") .. below .. " below") or "") or "")
  Overview.scrolled, Overview.shownLines = scroll, shown

  -- Under the stops: the On the way button, the journeys set aside, then
  -- the map. A scrolling list keeps its full height.
  local y = top - (maxScroll > 0 and room or used) - 10
  frame.onTheWay:ClearAllPoints()
  frame.onTheWay:SetPoint("TOPLEFT", 12, y)
  frame.onTheWay:Show()
  y = y - WAY_HEIGHT - 6
  y = Overview.LayoutSetAside(y, true)
  local mapHeight
  frame.mapHeader:ClearAllPoints()
  frame.mapHeader:SetPoint("TOPLEFT", 12, y - 4)
  frame.mapHeader.toggle:SetTexture(Overview.MapShown() and "Interface\\Buttons\\UI-MinusButton-Up"
    or "Interface\\Buttons\\UI-PlusButton-Up")
  frame.mapHeader:Show()
  y = y - 4 - 16
  if ns.RouteMap and Overview.MapShown() then
    -- The rest of the journey with the step you're on bold, or just what's
    -- selected, zoomed in (Overview.MapFocus).
    local drawn, opts = Overview.MapFocus(shownEntry, trail.steps, cur, walkIndex ~= at)
    local ok, h = pcall(ns.RouteMap.Draw, frame.map, { route = { steps = drawn } }, opts)
    mapHeight = ok and h or nil
  end
  frame.map.canvas:SetShown(mapHeight ~= nil)
  if mapHeight then
    frame.map.canvas:ClearAllPoints()
    frame.map.canvas:SetPoint("TOPLEFT", 12, y - 6)
    y = y - 6 - mapHeight
  end
  frame.height = -y + 26
  frame:SetHeight(frame.height)
end

-- The set-aside rows' text, top to bottom (for tests).
function Overview.SetAsideRows()
  local out = {}
  for _, row in ipairs(frame and frame.aside or {}) do
    if row:IsShown() then out[#out + 1] = row.text:GetText() end
  end
  return out
end

-- How many rows can be pinned (their menu offers it), and how many show the
-- lock of a pinned stop (for tests).
function Overview.PinCount()
  local can, pinned = 0, 0
  for _, row in ipairs(frame and frame.rows or {}) do
    if row:IsShown() and row.canPin then
      can = can + 1
      if row.pin:IsShown() then pinned = pinned + 1 end
    end
  end
  return can, pinned
end

-- The shown row for `stop` (for tests).
function Overview.RowFor(stop)
  for _, row in ipairs(frame and frame.rows or {}) do
    if row:IsShown() and row.stop == stop then return row end
  end
  return nil
end

-- The stop rows' map numbers, top to bottom, "" where a row has none (for tests).
function Overview.RowNumbers()
  local out = {}
  for _, row in ipairs(frame and frame.rows or {}) do
    if row:IsShown() and row.stop then
      out[#out + 1] = (row.number:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    end
  end
  return out
end

-- How many rows show a drag handle (for tests).
function Overview.HandleCount()
  local n = 0
  for _, row in ipairs(frame and frame.rows or {}) do
    if row:IsShown() and row.handle:IsShown() then n = n + 1 end
  end
  return n
end

-- Moves the stop on row `from` to where row `to` is (what a drag does).
function Overview.Move(from, to)
  local rows = Overview.Rows()
  local a, b = rows[from], rows[to]
  if not (a and b) then return false end
  return ns.Nav.MoveStop(a.stop, b.stop)
end

-- Whether the map under the stops shows (per character; shown unless you
-- folded it), and folding or showing it.
function Overview.MapShown()
  return not (ns.charDB and ns.charDB.overviewMapFolded)
end

function Overview.ToggleMap()
  if ns.charDB then ns.charDB.overviewMapFolded = Overview.MapShown() or nil end
  Overview.Refresh()
end

-- Whether the map is drawn now, and whether row `stop` is lit as the one
-- you're on (for tests).
function Overview.MapDrawn() return frame ~= nil and frame.map.canvas:IsShown() end
function Overview.IsLit(stop)
  local row = Overview.RowFor(stop)
  return row ~= nil and row.current:IsShown()
end

-- The window's height (for tests).
function Overview.Height() return frame and frame.height end

-- Scrolls the list (positive goes up, towards the first line).
function Overview.Scroll(delta)
  scroll = math.max(0, scroll - delta)
  Overview.Refresh()
end

function Overview.Show()
  frame = frame or create()
  focus = nil -- the walkthrough opens on the step you're on
  -- Opened with no journey on: the journeys set aside.
  frame.listing = not (ns.Nav.active and ns.Nav.active.journey) or nil
  frame:Show()
  Overview.Refresh()
end

function Overview.Toggle()
  if frame and frame:IsShown() then frame:Hide() else Overview.Show() end
end

function Overview.IsShown()
  return frame ~= nil and frame:IsShown()
end

-- The window, made (hidden) if there isn't one yet: edit modes move it anyway.
function Overview.EnsureFrame()
  frame = frame or create()
  return frame
end

ns.Movers.Add({ key = "Journey", label = "Journey", posKey = "overviewPos", home = HOME,
  frame = Overview.EnsureFrame })

-- A new journey folds by the rule again. It opens the overview only when the
-- options say so (off by default: View Journey on the directions box opens it any time).
ns.Listen("JOURNEY_STARTED", function()
  unfolded = nil
  scroll = 0
  focus = nil
  if ns.db.settings.overviewOnStart == true then
    Overview.Show()
  elseif frame and frame:IsShown() then
    Overview.Refresh()
  end
end)
-- Stops added to the journey: shown if it's open, without opening it (the
-- directions box's View Journey pulses instead).
ns.Listen("JOURNEY_EXTENDED", Overview.Refresh)
ns.Listen("NAV_CHANGED", Overview.Refresh)
ns.Listen("JOURNEYS_CHANGED", Overview.Refresh)
