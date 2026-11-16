local _, ns = ...

-- On the way: a pane of its own, opened from the directions box's On the way
-- action and the journey overview's, for what you could add around where you
-- are now (Wayside.lua). What the journey already gathers as you go has a
-- section of its own above the directions box (HUD.lua).
--
-- Along the top, a tab for each list:
--   Nearby                what's around you to add: quests to pick up or
--                         hand in, quests in your log with objectives around
--                         you, vendors you need, a new suggestion. Each with
--                         the time to get there from you, "+ Add" to add it,
--                         and a "..." whose "Not on this journey" waves it
--                         off for the rest of the journey.
--   repair, vendor,       a stop of your own: that kind's places, nearest to
--   mailbox, bank...      you first (Errands.lua).
-- Times are from where you stand, not along the journey: adding one, the
-- journey fits it in where it goes best.
--
-- It's a window of its own (move it by dragging, or in Edit Mode), and stays
-- open until you close it (per character): it comes back with the next
-- journey. Closed, the directions box's On the way carries a count of what's
-- nearby and nothing else calls for attention.
-- (It took over from the detour picker and the shopping list; ns.ErrandPicker
-- is this.)

local Drawer = {}
ns.Drawer = Drawer
ns.ErrandPicker = Drawer

local WIDTH = 330
local PADDING = 10
local TITLE_HEIGHT = 16
local CHIP = 28
local CHIP_GAP = 4
local ROWS = 8         -- lines at most: the offers and "+N more"; a kind's places
local ROW_HEIGHT = 20
local HOME = { "TOPRIGHT", "TOP", -175, -140 } -- left of the directions box
local TITLE = "On the way"
local NEARBY = "Nearby"
local NEARBY_ICON = "Interface\\Icons\\INV_Misc_Spyglass_02"
local NEARBY_TIP = "Quests, hand-ins and things you need around you"
local NOTHING = "Nothing to add around you right now. The tabs above list a stop of your own: a repair, a vendor, "
  .. "a mailbox..."
local GREY = "|cff9d9d9d"
local ADD = "+ Add"
local WAVE_OFF = "Not on this journey"
local WAVE_OFF_TIP = "It won't be offered again on this journey."

local frame
local selected -- the kind of stop listed, nil for Nearby
local lines = {}

local function tooltip(owner, title, ...)
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  GameTooltip:SetText(title)
  for i = 1, select("#", ...) do
    local line = select(i, ...)
    if line then GameTooltip:AddLine(line, 0.6, 0.6, 0.6, true) end
  end
  GameTooltip:Show()
end

-- A tab: Nearby first (no kind), then a kind of stop each.
local function chip(parent, i)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(CHIP, CHIP)
  b:SetPoint("TOPLEFT", PADDING + (i - 1) * (CHIP + CHIP_GAP), -(PADDING + TITLE_HEIGHT + 6))
  b.back = b:CreateTexture(nil, "BACKGROUND")
  b.back:SetAllPoints()
  b.back:SetColorTexture(1, 1, 1, 0.08)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 3, -3)
  b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
  -- The tab shown: a gold frame.
  b.ring = b:CreateTexture(nil, "OVERLAY")
  b.ring:SetTexture("Interface\\Buttons\\CheckButtonHilight")
  b.ring:SetBlendMode("ADD")
  b.ring:SetAllPoints()
  b.ring:Hide()
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnClick", function(self)
    if self.nearby then Drawer.Select(nil) elseif self.kind then Drawer.Select(self.kind.key) end
  end)
  b:SetScript("OnEnter", function(self)
    if self.nearby then
      tooltip(self, NEARBY, NEARBY_TIP)
    elseif self.kind then
      tooltip(self, self.kind.label, "Add one as a stop: nearest to you first")
    end
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function row(parent, i)
  local r = CreateFrame("Frame", nil, parent)
  r:SetSize(WIDTH - 2 * PADDING, ROW_HEIGHT)
  -- Waving an offer off is the lesser action, so it sits in the row's "..."
  -- (the same menu as everywhere else) rather than beside Add.
  r.more = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.more:SetSize(24, 16)
  r.more:SetPoint("RIGHT", 0, 0)
  r.more:SetText("...")
  r.more:SetScript("OnClick", function(self) ns.Menu.Show(self, Drawer.LineMenu(i)) end)
  r.more:SetScript("OnEnter", function(self) tooltip(self, "More", WAVE_OFF) end)
  r.more:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r.add = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.add:SetSize(50, 16)
  r.add:SetText(ADD)
  r.add:SetScript("OnClick", function() Drawer.AddLine(i) end)
  r.time = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.time:SetJustifyH("RIGHT")
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.text:SetPoint("LEFT", 2, 0)
  r.text:SetJustifyH("LEFT")
  r.text:SetWordWrap(false)
  r:EnableMouse(true)
  r:SetScript("OnEnter", function(self)
    local tip = self.line and self.line.tip
    if tip then tooltip(self, (unpack or table.unpack)(tip)) end
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Button(r.add)
  ns.Skin.Button(r.more)
  ns.Skin.Text(r.text)
  ns.Skin.Text(r.time)
  r:Hide()
  return r
end

local byItself = false -- opening again because you left it open, not asked

local function create()
  local f = ns.Skin.CreateBox("WaywardErrandPicker")
  f:SetWidth(WIDTH)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "wayPos")
  end)
  f:SetBackdropColor(0, 0, 0, 0.9)
  ns.RestorePosition(f, "wayPos", HOME)
  -- A dark fill of its own under the rows: a UI skin may make the backdrop
  -- see-through, and chat behind the list made it hard to read.
  f.shade = f:CreateTexture(nil, "BACKGROUND", nil, 7)
  f.shade:SetPoint("TOPLEFT", 3, -3)
  f.shade:SetPoint("BOTTOMRIGHT", -3, 3)
  f.shade:SetColorTexture(0, 0, 0, 0.85)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", PADDING, -PADDING)
  f.title:SetPoint("RIGHT", -30, 0)
  f.title:SetHeight(TITLE_HEIGHT)
  f.title:SetJustifyH("LEFT")
  f.title:SetText(TITLE)
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetPoint("TOPRIGHT", -2, -2)
  f.close:SetScript("OnClick", function() Drawer.Hide() end)
  ns.Skin.CloseButton(f.close)

  f.chips = {}
  for i = 1, #ns.Errands.KINDS + 1 do f.chips[i] = chip(f, i) end
  f.chips[1].nearby = true
  f.chips[1].icon:SetTexture(NEARBY_ICON)
  f.chips[1].icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.heading:SetPoint("TOPLEFT", PADDING, -(PADDING + TITLE_HEIGHT + 6 + CHIP + 8))
  f.heading:SetPoint("RIGHT", -PADDING, 0)
  f.heading:SetJustifyH("LEFT")

  f.rows = {}
  for i = 1, ROWS do
    f.rows[i] = row(f, i)
    f.rows[i]:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -4 - (i - 1) * ROW_HEIGHT)
    f.rows[i]:SetPoint("RIGHT", f, "RIGHT", -PADDING, 0)
  end

  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.empty:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -6)
  f.empty:SetPoint("RIGHT", -PADDING, 0)
  f.empty:SetJustifyH("LEFT")
  f.empty:SetWordWrap(true)
  for _, fs in ipairs({ f.title, f.heading, f.empty }) do ns.Skin.Text(fs) end
  ns.Skin.Box(f)
  -- A controller's cursor moves through it on Forever; B closes it as its
  -- close button does (so it stays closed for the next journey). Back by
  -- itself with a journey, it doesn't take the cursor from what you're doing.
  ns.Pad.Window(f, { close = function() Drawer.Hide() end, quiet = function() return byItself end })
  f:Hide()
  return f
end

function Drawer.Kind() return selected and ns.Errands.Kind(selected) or nil end

-- What's around you to add, as lines: the offers, then how many more.
local function nearbyLines()
  local w = ns.Wayside.Get(true)
  local out = {}
  for _, r in ipairs(w.offers) do
    out[#out + 1] = { text = r.text, right = r.right, tip = r.tip, row = r, offer = true,
      add = function() return ns.Wayside.Add(r) end, dismiss = function() return ns.Wayside.Dismiss(r) end }
  end
  if w.more > 0 then out[#out + 1] = { header = true, text = string.format("%s+%d more once these are dealt with|r", GREY, w.more) } end
  return out, #out == 0 and NOTHING or nil
end

-- A kind's places, as lines.
local function errandLines(kind)
  local ok, list, empty = pcall(ns.Errands.Get, kind.key)
  if not ok then
    geterrorhandler()(list)
    list, empty = {}, "Couldn't list these here."
  end
  local out = {}
  for _, p in ipairs(list) do
    out[#out + 1] = {
      text = string.format("%s  %s%s|r", p.npc or kind.label, GREY, p.place or ""),
      right = p.inTrip and (GREY .. "in your journey|r") or ns.FormatDuration(p.extra),
      tip = { p.npc or kind.label, p.place or "", string.format("%s from where you are.", ns.FormatDuration(p.extra)) },
      place = p, disabled = p.inTrip and true or false,
      add = function() return ns.Errands.Add(kind.key, p) end,
    }
  end
  return out, empty
end

function Drawer.Refresh()
  if not (frame and frame:IsShown()) then return end
  local kinds = ns.Errands.Kinds()
  for i, b in ipairs(frame.chips) do
    if b.nearby then
      b.ring:SetShown(selected == nil)
      b:Show()
    else
      local kind = kinds[i - 1]
      b.kind = kind
      if kind then
        b.icon:SetTexture(kind.icon)
        b.ring:SetShown(kind.key == selected)
        b:Show()
      else
        b:Hide()
      end
    end
  end
  local kind = Drawer.Kind()
  local empty
  if kind then
    frame.heading:SetText(string.format("%s  %snearest first|r", kind.label, GREY))
    lines, empty = errandLines(kind)
  else
    frame.heading:SetText(string.format("%s  %saround you|r", NEARBY, GREY))
    local ok, list, none = pcall(nearbyLines)
    if not ok then
      geterrorhandler()(list)
      list, none = {}, "Couldn't list what's around you here."
    end
    lines, empty = list, none
  end
  while #lines > ROWS do table.remove(lines) end
  for i, r in ipairs(frame.rows) do
    local line = lines[i]
    r.line = line
    if line then
      r.text:SetText(line.header and ("|cffffd200" .. line.text .. "|r") or line.text)
      r.time:SetText(line.right or "")
      r.add:SetShown(line.add ~= nil)
      r.add:SetEnabled(not line.disabled)
      r.more:SetShown(line.dismiss ~= nil)
      -- Add at the right edge, or left of the "..."; the time left of
      -- whichever buttons the line has.
      r.add:ClearAllPoints()
      if line.dismiss then
        r.add:SetPoint("RIGHT", r.more, "LEFT", -4, 0)
      else
        r.add:SetPoint("RIGHT", 0, 0)
      end
      r.time:ClearAllPoints()
      r.text:ClearAllPoints()
      r.text:SetPoint("LEFT", 2, 0)
      if line.add then
        r.time:SetPoint("RIGHT", r.add, "LEFT", -6, 0)
      else
        r.time:SetPoint("RIGHT", 0, 0)
      end
      r.text:SetPoint("RIGHT", r.time, "LEFT", -6, 0)
      r:Show()
    else
      r:Hide()
    end
  end
  frame.empty:SetText(empty or "")
  frame.empty:SetShown(#lines == 0)
  local body = #lines > 0 and (4 + #lines * ROW_HEIGHT) or (6 + (frame.empty:GetStringHeight() or 24))
  frame:SetHeight(PADDING + TITLE_HEIGHT + 6 + CHIP + 8 + (frame.heading:GetStringHeight() or 14) + body + PADDING)
end

-- Shows a kind of stop to add (repair, mailbox...), or with nil Nearby.
function Drawer.Select(key)
  if key ~= nil and not ns.Errands.Kind(key) then return end
  selected = key
  Drawer.Refresh()
end

-- Whether you left it open (per character): it comes back with the next journey.
function Drawer.Open()
  return ns.charDB ~= nil and ns.charDB.drawerOpen == true
end

-- The window, made (hidden) if there isn't one yet: edit modes move it anyway.
function Drawer.EnsureFrame()
  frame = frame or create()
  return frame
end

local function show()
  if not ns.Nav.active then return end
  Drawer.EnsureFrame()
  frame:Show()
  Drawer.Refresh()
end

function Drawer.Show()
  if not ns.Nav.active then return end
  if ns.charDB then ns.charDB.drawerOpen = true end
  show()
  ns.Fire("WAYSIDE_CHANGED")
end

-- Closes it; `keep`: only for now (the journey ended), not as your choice.
function Drawer.Hide(keep)
  if not keep and ns.charDB then ns.charDB.drawerOpen = nil end
  if frame then frame:Hide() end
  if not keep then ns.Fire("WAYSIDE_CHANGED") end
end

function Drawer.Toggle()
  if Drawer.IsShown() then
    Drawer.Hide()
  else
    -- Each time you open it: Nearby, or what you plainly need now (worn
    -- gear, full bags).
    selected = ns.Errands.UrgentKind()
    Drawer.Show()
  end
end

function Drawer.IsShown() return frame ~= nil and frame:IsShown() end

-- Called by the directions box as it updates: open again when you left it
-- open, and kept up to date while it shows.
function Drawer.Sync()
  if not ns.Nav.active then return end
  if Drawer.IsShown() then
    Drawer.Refresh()
  elseif Drawer.Open() then
    selected = nil
    byItself = true
    show()
    byItself = false
  end
end

-- Adds what's on line `i` to the journey. A stop of your own: back to Nearby.
function Drawer.AddLine(i)
  local line = lines[i]
  if not (line and line.add) or line.disabled then return false end
  local added = line.add()
  if added and selected then selected = nil end
  Drawer.Refresh()
  return added and true or false
end

function Drawer.DismissLine(i)
  local line = lines[i]
  if not (line and line.dismiss) then return false end
  local gone = line.dismiss()
  Drawer.Refresh()
  return gone and true or false
end

-- The "..." menu of line `i`: waving the offer off. {} for a line without one.
function Drawer.LineMenu(i)
  local line = lines[i]
  if not (line and line.dismiss) then return {} end
  return { { text = WAVE_OFF, tip = WAVE_OFF_TIP, onClick = function() Drawer.DismissLine(i) end } }
end

-- Line numbers of the rows that aren't headings (for tests and AddRow).
local function plain()
  local out = {}
  for i, line in ipairs(lines) do
    if not line.header then out[#out + 1] = i end
  end
  return out
end

-- Adds the `i`th row (headings not counted).
function Drawer.AddRow(i)
  local at = plain()[i]
  return at ~= nil and Drawer.AddLine(at) or false
end

function Drawer.DismissRow(i)
  local at = plain()[i]
  return at ~= nil and Drawer.DismissLine(at) or false
end

-- The `i`th row's "..." menu (headings not counted).
function Drawer.RowMenu(i)
  local at = plain()[i]
  return at ~= nil and Drawer.LineMenu(at) or {}
end

-- The kind shown and the rows' text (for tests): { text, time, add, dismiss
-- (it has a "..." to wave it off), addLabel, kind (a Wayside row's) }, headings left out; Drawer.Headings() has those.
function Drawer.Selected() return selected end
function Drawer.Rows()
  local out = {}
  if not Drawer.IsShown() then return out end
  for _, i in ipairs(plain()) do
    local r, line = frame.rows[i], lines[i]
    out[#out + 1] = { text = r.text:GetText(), time = r.time:GetText(), add = line.add ~= nil and not line.disabled,
      dismiss = line.dismiss ~= nil, addLabel = r.add:GetText(), kind = line.row and line.row.kind }
  end
  return out
end
-- The window's title, the tab's heading, then any heading lines in the list (for tests).
function Drawer.Headings()
  local out = {}
  if not Drawer.IsShown() then return out end
  out[1] = frame.title:GetText()
  out[2] = frame.heading:GetText()
  for _, line in ipairs(lines) do
    if line.header then out[#out + 1] = line.text end
  end
  return out
end
-- The tabs as shown, left to right (for tests): { label, selected }.
function Drawer.Tabs()
  local out = {}
  if not frame then return out end
  for _, b in ipairs(frame.chips) do
    if b:IsShown() then
      out[#out + 1] = { label = b.nearby and NEARBY or (b.kind and b.kind.label), selected = b.ring:IsShown() }
    end
  end
  return out
end
function Drawer.EmptyText() return frame and frame.empty:IsShown() and frame.empty:GetText() or nil end
function Drawer.Frame() return frame end

ns.Movers.Add({ key = "OnTheWay", label = "On the way", posKey = "wayPos", home = HOME,
  frame = Drawer.EnsureFrame })

ns.Listen("NAV_CHANGED", function()
  if not ns.Nav.active then Drawer.Hide(true) end
end)

for _, message in ipairs({ "WAYSIDE_CHANGED", "JOURNEY_EXTENDED" }) do
  ns.Listen(message, function() Drawer.Refresh() end)
end
