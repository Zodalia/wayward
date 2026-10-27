local _, ns = ...

-- The whole journey at a glance (View details): every stop with done / now /
-- next, opened from the directions box (=) and when a journey with several
-- stops starts. An open stop can be dropped (x); stops that need it are
-- dropped with it. Stops you've skipped or dropped aren't listed.
-- Drag an open stop up or down by its handle (or the row) to reorder the
-- journey. Under an open stop, the steps that get you there (walk, fly,
-- boat...), with the one you're on marked: open under the current stop, and
-- any stop's +/- opens or folds them, so you can see where it's taking you
-- (and hearth instead).
-- Finished stops fold into one line you can open;
-- they fold by themselves once there are AUTO_FOLD of them, or when showing
-- them would push open stops off the list.
-- Under the stops: detours on the way (OnTheWay.lua), the journeys you set
-- aside (Nav.SetAside) with Resume and Forget, and a map of the rest.

local Overview = {}
ns.JourneyOverview = Overview

local MAX_ROWS = 10        -- the list is this many stop rows tall
local ROW_HEIGHT = 30
local STEP_HEIGHT = 15     -- a step line under a stop
local POOL = 24            -- rows drawn at most (stops and steps)
local SUGGESTIONS = 4      -- "Detours on the way" rows
local SUGGEST_HEIGHT = 18
local SET_ASIDE = 5        -- set-aside journey rows (Nav keeps that many)
local HANDLE_WIDTH = 16
local GRIP_COLOR = { 0.6, 0.6, 0.6, 0.8 }
local AUTO_FOLD = 3

local frame
local HOME = { "TOPLEFT", "TOP", 170, -140 }
local unfolded -- nil: fold by the rule above; true / false: the player's choice for this journey
local opened = setmetatable({}, { __mode = "k" }) -- [stop] = true / false: its steps shown (nil: the current stop's)
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
  f.title:SetPoint("RIGHT", -30, 0)
  f.title:SetJustifyH("LEFT")

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.info:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  ns.Skin.CloseButton(close)
  ns.Skin.Text(f.title)
  ns.Skin.Text(f.info)

  f.rows = {}
  for i = 1, POOL do
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(356, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 12, -44 - (i - 1) * ROW_HEIGHT)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("TOPLEFT", HANDLE_WIDTH + 4, -2)
    row.text:SetPoint("RIGHT", -24, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    -- Where the stop is, so a journey across several zones reads at a glance.
    row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.zone:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -2)
    row.zone:SetPoint("RIGHT", -24, 0)
    row.zone:SetJustifyH("LEFT")
    ns.Skin.Text(row.zone)
    row.drop = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.drop:SetSize(20, 16)
    row.drop:SetPoint("RIGHT", 0, 0)
    row.drop:SetText("x")
    row.drop:SetScript("OnClick", function() ns.Nav.Drop(row.stop) end)
    ns.Skin.Button(row.drop)
    -- Show or fold the steps to this stop.
    row.expand = CreateFrame("Button", nil, row)
    row.expand:SetSize(14, 14)
    row.expand:SetPoint("RIGHT", row.drop, "LEFT", -6, 0)
    row.expand:SetScript("OnClick", function() Overview.ToggleSteps(row.stop) end)
    row.expand:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Show or hide the steps to this stop")
      GameTooltip:Show()
    end)
    row.expand:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.expand:Hide()
    ns.Skin.Text(row.text)
    row.index = i
    local function startDrag()
      if not row.movable then return end
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
    row:SetScript("OnMouseUp", function(self) if self.header then Overview.ToggleFinished() end end)
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

  -- Detours on the way: things to add that cost little (OnTheWay.lua).
  f.suggestHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.suggestHeader:SetJustifyH("LEFT")
  f.suggest = {}
  for i = 1, SUGGESTIONS do
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(356, SUGGEST_HEIGHT)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetPoint("RIGHT", -52, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row.add = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.add:SetSize(46, 16)
    row.add:SetPoint("RIGHT", 0, 0)
    row.add:SetText("Add")
    row.add:SetScript("OnClick", function() if row.suggestion then ns.OnTheWay.Add(row.suggestion) end end)
    ns.Skin.Button(row.add)
    ns.Skin.Text(row.text)
    row:Hide()
    f.suggest[i] = row
  end
  ns.Skin.Text(f.suggestHeader)
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
    row.resume:SetScript("OnClick", function() ns.Nav.ResumeSetAside(i) end)
    ns.Skin.Button(row.forget)
    ns.Skin.Button(row.resume)
    ns.Skin.Text(row.text)
    row:Hide()
    f.aside[i] = row
  end
  -- The rest of the journey on a map.
  f.map = ns.RouteMap.NewView(f, 356)
  f.map.canvas:Hide()

  f.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 12, 8)
  ns.Skin.Text(f.more)
  ns.Skin.Box(f)
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
      local state = stop.done and "done" or stop == now and "now" or "next"
      rows[#rows + 1] = { stop = stop, state = state }
    end
  end
  -- Done stops first, in the order they happened to be listed.
  local order = { done = 1, now = 2, next = 3 }
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
}

local FINISHED = { done = true }

-- The current route's steps that lead to `stop`: first, last (indexes), or nil.
local function legOf(a, stop)
  local first = 1
  for i, step in ipairs(a.route.steps) do
    if step.stop == stop then return first, i end
    if step.stop then first = i + 1 end
  end
  return nil
end

local function stepsOpen(stop, state)
  if opened[stop] ~= nil then return opened[stop] end
  return state == "now"
end

function Overview.ToggleSteps(stop)
  if not stop then return end
  local state
  for _, r in ipairs(Overview.Rows()) do
    if r.stop == stop then state = r.state end
  end
  opened[stop] = not stepsOpen(stop, state)
  Overview.Refresh()
end

-- What the list shows, top to bottom: the finished stops' line (when there
-- are any), those stops unless folded, then the open ones.
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
  local a = ns.Nav.active
  for i, r in ipairs(rows) do
    if not (folded and FINISHED[r.state]) then
      lines[#lines + 1] = { row = r, index = i }
      -- The steps that get you there, under an open stop.
      local first, last = nil, nil
      if a and not FINISHED[r.state] then first, last = legOf(a, r.stop) end
      if first and stepsOpen(r.stop, r.state) then
        for k = first, last do
          lines[#lines + 1] = { step = a.route.steps[k], stepIndex = k,
            state = k < a.index and "done" or k == a.index and "now" or "next" }
        end
      end
      if first then lines[#lines].hasSteps = true end
      if first then
        for j = #lines, 1, -1 do
          if lines[j].row then lines[j].stepsOpen, lines[j].canOpen = stepsOpen(r.stop, r.state), true break end
        end
      end
    end
  end
  return lines, rows
end

function Overview.ToggleFinished()
  local lines = Overview.Lines()
  unfolded = not (lines[1] and lines[1].header and not lines[1].folded)
  Overview.Refresh()
end

function Overview.Refresh()
  if not (frame and frame:IsShown()) then return end
  local a = ns.Nav.active
  if not (a and a.journey) then
    frame:Hide()
    return
  end
  local lines, rows = Overview.Lines()
  local root = a.journey.root or a.journey.def
  local done = 0
  for _, r in ipairs(rows) do
    if r.state == "done" then done = done + 1 end
  end
  frame.title:SetText(a.title)
  frame.info:SetText(string.format("%d of %d stops done  ·  %s to go%s", done, #rows,
    ns.FormatDuration(ns.Nav.RemainingSeconds(ns.Geo.PlayerNode())),
    root.manual and "  ·  your order" or "  ·  drag stops to reorder"))
  -- Rows one under the other (step lines are shorter), as many as fit.
  -- Scrolled: from line scroll + 1, as many as fit. A list that needs
  -- scrolling keeps the full height, and stops once its last line shows.
  local room, used, shown = MAX_ROWS * ROW_HEIGHT, 0, 0
  local function heightOf(line) return line.step and STEP_HEIGHT or ROW_HEIGHT end
  local maxScroll, fromEnd = 0, 0
  for i = #lines, 1, -1 do
    fromEnd = fromEnd + heightOf(lines[i])
    if fromEnd > room then
      maxScroll = i
      break
    end
  end
  scroll = math.max(0, math.min(scroll, maxScroll))
  Overview.maxScroll = maxScroll
  for i, row in ipairs(frame.rows) do
    local line = lines[scroll + i]
    local height = line and (line.step and STEP_HEIGHT or ROW_HEIGHT) or 0
    if line and used + height > room then line = nil end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 12, -44 - used)
    row:SetHeight(math.max(height, 1))
    if line then
      used = used + height
      shown = shown + 1
    end
    local r = line and line.row
    row.stop, row.rowIndex, row.header = r and r.stop, line and line.index, line and line.header
    row.expand:Hide()
    if line and line.step then
      local route = a.route
      local text = ns.Router.Describe(route, line.stepIndex, true) .. "  ·  " .. ns.FormatDuration(line.step.seconds)
      local look = line.state == "now" and "|cffffd200>|r " or "   "
      row.text:SetText("      " .. look .. text)
      row.text:SetAlpha(line.state == "done" and 0.45 or 0.9)
      row.zone:SetText("")
      row.movable = false
      row.drop:Hide()
      row.handle:Hide()
      row.toggle:Hide()
      row:Show()
    elseif line and line.header then
      row.text:SetText(string.format("|cff9d9d9d%s finished|r  %s", line.count == 1 and "1 stop" or (line.count .. " stops"),
        line.folded and "(click to show)" or "(click to hide)"))
      row.zone:SetText("")
      row.text:SetAlpha(1)
      row.movable = false
      row.drop:Hide()
      row.handle:Hide()
      local texture = line.folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up"
      row.toggle:SetNormalTexture(texture)
      row.toggle:Show()
      row:Show()
    elseif r then
      local look = LOOK[r.state]
      row.text:SetText(look[1] .. (r.stop.text or (r.stop.node and r.stop.node.label) or "?"))
      local zone = ns.Journey.StopZone(r.stop)
      row.zone:SetText(zone and ("      " .. zone) or "")
      row.text:SetAlpha(look[2])
      row.movable = r.state == "now" or r.state == "next"
      row.drop:SetShown(r.state == "now" or r.state == "next")
      row.handle:SetShown(row.movable)
      row.toggle:Hide()
      if line.canOpen then
        row.expand:SetNormalTexture(line.stepsOpen and "Interface\\Buttons\\UI-MinusButton-Up"
          or "Interface\\Buttons\\UI-PlusButton-Up")
        row.expand:Show()
      end
      row:Show()
    else
      row:Hide()
    end
  end
  local below = #lines - scroll - shown
  frame.more:SetText((scroll > 0 or below > 0) and string.format("%s%s  ·  scroll for more",
    scroll > 0 and (scroll .. " above") or "", below > 0 and ((scroll > 0 and ", " or "") .. below .. " below") or "") or "")
  Overview.scrolled, Overview.shownLines = scroll, shown

  -- Under the stops: detours on the way, the journeys set aside, then the
  -- map. A scrolling list keeps its full height.
  local y = -44 - (maxScroll > 0 and room or used) - 10
  local list = ns.OnTheWay and ns.OnTheWay.Get() or {}
  frame.suggestHeader:ClearAllPoints()
  frame.suggestHeader:SetPoint("TOPLEFT", 12, y)
  frame.suggestHeader:SetShown(#list > 0)
  if #list > 0 then
    frame.suggestHeader:SetText("Detours on the way (3 min or less)")
    y = y - 16
  end
  for i, row in ipairs(frame.suggest) do
    local s = list[i]
    row.suggestion = s
    if s then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 12, y)
      row.text:SetText(string.format("%s  |cff9d9d9d+%s|r", s.label, ns.FormatDuration(s.extra)))
      row:Show()
      y = y - SUGGEST_HEIGHT
    else
      row:Hide()
    end
  end
  local aside = ns.Nav.SetAsideList and ns.Nav.SetAsideList() or {}
  frame.asideHeader:ClearAllPoints()
  frame.asideHeader:SetPoint("TOPLEFT", 12, y)
  frame.asideHeader:SetShown(#aside > 0)
  if #aside > 0 then y = y - 16 end
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
  local mapHeight
  if ns.RouteMap then
    local remaining = {}
    for k = a.index, #a.route.steps do remaining[#remaining + 1] = a.route.steps[k] end
    local ok, h = pcall(ns.RouteMap.Draw, frame.map, { route = { steps = remaining } })
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

-- The window's height (for tests).
function Overview.Height() return frame and frame.height end

-- Scrolls the list (positive goes up, towards the first line).
function Overview.Scroll(delta)
  scroll = math.max(0, scroll - delta)
  Overview.Refresh()
end

function Overview.Show()
  frame = frame or create()
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

-- A new journey folds by the rule again, and opens the overview unless the
-- options say not to (the directions box's book button opens it any time).
ns.Listen("JOURNEY_STARTED", function()
  unfolded = nil
  opened = setmetatable({}, { __mode = "k" })
  scroll = 0
  if ns.db.settings.overviewOnStart ~= false then
    Overview.Show()
  elseif frame and frame:IsShown() then
    Overview.Refresh()
  end
end)
-- Stops added to the journey: shown if it's open, without opening it (the
-- directions box's book button flashes instead).
ns.Listen("JOURNEY_EXTENDED", Overview.Refresh)
ns.Listen("NAV_CHANGED", Overview.Refresh)
ns.Listen("JOURNEYS_CHANGED", Overview.Refresh)
