local _, ns = ...

-- On the way: the drawer on the directions box (its On the way action), for what
-- you could add near the journey you're on (Wayside.lua). What the journey
-- already gathers as you go has a section of its own above the box (HUD.lua).
--
--   On the way            what you could add: each with the time it adds,
--                         a + to add it and an x to wave it off for good
--   the icons on top      add a stop of your own: repair, vendor, mailbox,
--                         bank... Pick one and the list is its places, least
--                         out of the way first (Errands.lua); pick it again
--                         to go back.
--
-- It hangs under the directions box, or over it (and over Gathering as you
-- go) near the bottom of the screen, and stays open until you close it (per
-- character). Closed, that action carries a count of the offers and nothing
-- else calls for attention.
-- (It took over from the detour picker and the shopping list; ns.ErrandPicker
-- is this.)

local Drawer = {}
ns.Drawer = Drawer
ns.ErrandPicker = Drawer

local WIDTH = 330
local PADDING = 10
local CHIP = 28
local CHIP_GAP = 4
local ROWS = 8         -- lines at most: a heading, the offers, "+N more"; a kind's places
local ROW_HEIGHT = 20
local GAP = 4          -- between the directions box and the drawer
local ROOM_BELOW = 220 -- pixels under the directions box it needs, else it opens above
local TITLE = "On the way"
local OFFERS = "You could add"
local NOTHING = "Nothing on the way right now. The icons above add a stop of your own: a repair, a vendor, a mailbox..."
local GREY = "|cff9d9d9d"

local frame
local selected -- the kind of stop listed, nil for what's on the way
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

local function chip(parent, i)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(CHIP, CHIP)
  b:SetPoint("TOPLEFT", PADDING + (i - 1) * (CHIP + CHIP_GAP), -PADDING)
  b.back = b:CreateTexture(nil, "BACKGROUND")
  b.back:SetAllPoints()
  b.back:SetColorTexture(1, 1, 1, 0.08)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 3, -3)
  b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
  -- The chosen kind: a gold frame.
  b.ring = b:CreateTexture(nil, "OVERLAY")
  b.ring:SetTexture("Interface\\Buttons\\CheckButtonHilight")
  b.ring:SetBlendMode("ADD")
  b.ring:SetAllPoints()
  b.ring:Hide()
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnClick", function(self)
    if not self.kind then return end
    -- The chosen one again: back to what's on the way.
    Drawer.Select(self.kind.key ~= selected and self.kind.key or nil)
  end)
  b:SetScript("OnEnter", function(self)
    if self.kind then tooltip(self, self.kind.label, self.kind.key == selected and "Back to what's on the way" or "Add one as a stop") end
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function row(parent, i)
  local r = CreateFrame("Frame", nil, parent)
  r:SetSize(WIDTH - 2 * PADDING, ROW_HEIGHT)
  r.dismiss = CreateFrame("Button", nil, r, "UIPanelCloseButton")
  r.dismiss:SetSize(18, 18)
  r.dismiss:SetPoint("RIGHT", 2, 0)
  r.dismiss:SetScript("OnClick", function() Drawer.DismissLine(i) end)
  r.dismiss:SetScript("OnEnter", function(self) tooltip(self, "Not this one", "It won't be offered again on this journey.") end)
  r.dismiss:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r.add = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.add:SetSize(46, 16)
  r.add:SetPoint("RIGHT", r.dismiss, "LEFT", -2, 0)
  r.add:SetText("Add")
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
  ns.Skin.CloseButton(r.dismiss)
  ns.Skin.Text(r.text)
  ns.Skin.Text(r.time)
  r:Hide()
  return r
end

local function create()
  local f = ns.Skin.CreateBox("WaywardErrandPicker")
  f:SetWidth(WIDTH)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetBackdropColor(0, 0, 0, 0.9)
  -- A dark fill of its own under the rows: a UI skin may make the backdrop
  -- see-through, and chat behind the list made it hard to read.
  f.shade = f:CreateTexture(nil, "BACKGROUND", nil, 7)
  f.shade:SetPoint("TOPLEFT", 3, -3)
  f.shade:SetPoint("BOTTOMRIGHT", -3, 3)
  f.shade:SetColorTexture(0, 0, 0, 0.85)

  f.chips = {}
  for i = 1, #ns.Errands.KINDS do f.chips[i] = chip(f, i) end

  f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.heading:SetPoint("TOPLEFT", PADDING, -(PADDING + CHIP + 8))
  f.heading:SetPoint("RIGHT", -PADDING, 0)
  f.heading:SetJustifyH("LEFT")

  f.rows = {}
  for i = 1, ROWS do
    f.rows[i] = row(f, i)
    f.rows[i]:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -4 - (i - 1) * ROW_HEIGHT)
    -- As wide as the box, which takes the directions box's width (narrower
    -- with the compass off): a fixed width put the Add buttons past its edge.
    f.rows[i]:SetPoint("RIGHT", f, "RIGHT", -PADDING, 0)
  end

  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.empty:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -6)
  f.empty:SetPoint("RIGHT", -PADDING, 0)
  f.empty:SetJustifyH("LEFT")
  f.empty:SetWordWrap(true)
  for _, fs in ipairs({ f.heading, f.empty }) do ns.Skin.Text(fs) end
  ns.Skin.Box(f)
  f:Hide()
  return f
end

-- Under the directions box, or over it (and over the section above it)
-- when there's no room below.
local function place()
  local hud = ns.HUD.Frame()
  frame:ClearAllPoints()
  if not hud then
    frame:SetPoint("CENTER")
    return
  end
  frame:SetWidth(hud:GetWidth() or WIDTH)
  local bottom = hud:GetBottom()
  if bottom and bottom < ROOM_BELOW then
    frame:SetPoint("BOTTOMLEFT", ns.HUD.Top() or hud, "TOPLEFT", 0, GAP)
  else
    frame:SetPoint("TOPLEFT", hud, "BOTTOMLEFT", 0, -GAP)
  end
end

function Drawer.Kind() return selected and ns.Errands.Kind(selected) or nil end

-- What you could add on the way, as lines: a heading, then the offers.
local function waysideLines()
  local w = ns.Wayside.Get(true)
  local out = {}
  if #w.offers > 0 then
    out[#out + 1] = { header = true, text = OFFERS }
    for _, r in ipairs(w.offers) do
      out[#out + 1] = { text = r.text, right = r.right, tip = r.tip, row = r, offer = true,
        add = function() return ns.Wayside.Add(r) end, dismiss = function() return ns.Wayside.Dismiss(r) end }
    end
    if w.more > 0 then out[#out + 1] = { header = true, text = string.format("%s+%d more once these are dealt with|r", GREY, w.more) } end
  end
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
      right = p.inTrip and (GREY .. "in your journey|r") or ("+" .. ns.FormatDuration(p.extra)),
      tip = { p.npc or kind.label, p.place or "", string.format("A detour of %s on your journey.", ns.FormatDuration(p.extra)) },
      place = p, disabled = p.inTrip and true or false,
      add = function() return ns.Errands.Add(kind.key, p) end,
    }
  end
  return out, empty
end

function Drawer.Refresh()
  if not (frame and frame:IsShown()) then return end
  -- Placed again: the section above the box comes and goes.
  place()
  local kinds = ns.Errands.Kinds()
  for i, b in ipairs(frame.chips) do
    local kind = kinds[i]
    b.kind = kind
    if kind then
      b.icon:SetTexture(kind.icon)
      b.ring:SetShown(kind.key == selected)
      b:Show()
    else
      b:Hide()
    end
  end
  local kind = Drawer.Kind()
  local empty
  if kind then
    frame.heading:SetText(string.format("%s  %sleast out of the way first|r", kind.label, GREY))
    lines, empty = errandLines(kind)
  else
    frame.heading:SetText(TITLE)
    local ok, list, none = pcall(waysideLines)
    if not ok then
      geterrorhandler()(list)
      list, none = {}, "Couldn't list what's on the way here."
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
      r.dismiss:SetShown(line.dismiss ~= nil)
      -- The time sits left of whichever buttons the line has.
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
  frame:SetHeight(PADDING + CHIP + 8 + (frame.heading:GetStringHeight() or 14) + body + PADDING)
end

-- Lists a kind of stop to add (repair, mailbox...), or with nil what's on the way.
function Drawer.Select(key)
  if key ~= nil and not ns.Errands.Kind(key) then return end
  selected = key
  Drawer.Refresh()
end

-- Whether you left it open (per character): it comes back with the next journey.
function Drawer.Open()
  return ns.charDB ~= nil and ns.charDB.drawerOpen == true
end

local function show()
  if not ns.Nav.active then return end
  frame = frame or create()
  place()
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
    -- Each time you open it: what's on the way, or what you plainly need
    -- now (worn gear, full bags).
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
    show()
  end
end

-- Adds what's on line `i` to the journey. A stop of your own: back to
-- what's on the way.
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

-- The kind shown and the rows' text (for tests): { text, time, add, dismiss,
-- kind (a Wayside row's) }, headings left out; Drawer.Headings() has those.
function Drawer.Selected() return selected end
function Drawer.Rows()
  local out = {}
  if not Drawer.IsShown() then return out end
  for _, i in ipairs(plain()) do
    local r, line = frame.rows[i], lines[i]
    out[#out + 1] = { text = r.text:GetText(), time = r.time:GetText(), add = line.add ~= nil and not line.disabled,
      dismiss = line.dismiss ~= nil, kind = line.row and line.row.kind }
  end
  return out
end
function Drawer.Headings()
  local out = {}
  if not Drawer.IsShown() then return out end
  out[1] = frame.heading:GetText()
  for _, line in ipairs(lines) do
    if line.header then out[#out + 1] = line.text end
  end
  return out
end
function Drawer.EmptyText() return frame and frame.empty:IsShown() and frame.empty:GetText() or nil end
function Drawer.Frame() return frame end

ns.Listen("NAV_CHANGED", function()
  if not ns.Nav.active then Drawer.Hide(true) end
end)

ns.Listen("HUD_MOVED", function()
  if Drawer.IsShown() then place() end
end)

for _, message in ipairs({ "WAYSIDE_CHANGED", "JOURNEY_EXTENDED" }) do
  ns.Listen(message, function() Drawer.Refresh() end)
end
