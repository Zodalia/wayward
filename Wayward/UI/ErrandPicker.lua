local _, ns = ...

-- Add a detour (the directions box's + button): the kinds of detour along
-- the top (repair, vendor, mailbox, bank, ...), and under them the places of
-- the chosen kind that add least to the journey, each with the time it adds
-- and Add (Errands.lua). It hangs under the directions box, or over it near
-- the bottom of the screen; adding a place closes it.

local Picker = {}
ns.ErrandPicker = Picker

local WIDTH = 330
local PADDING = 10
local CHIP = 28
local CHIP_GAP = 4
local ROWS = 5
local ROW_HEIGHT = 20
local GAP = 4          -- between the directions box and the list
local ROOM_BELOW = 220 -- pixels under the directions box it needs, else it opens above

local frame
local selected -- the kind shown

local function tooltip(owner, title, line)
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  GameTooltip:SetText(title)
  if line then GameTooltip:AddLine(line, 0.6, 0.6, 0.6, true) end
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
  b:SetScript("OnClick", function(self) if self.kind then Picker.Select(self.kind.key) end end)
  b:SetScript("OnEnter", function(self) if self.kind then tooltip(self, self.kind.label) end end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function row(parent, i)
  local r = CreateFrame("Frame", nil, parent)
  r:SetSize(WIDTH - 2 * PADDING, ROW_HEIGHT)
  r.add = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
  r.add:SetSize(46, 16)
  r.add:SetPoint("RIGHT", 0, 0)
  r.add:SetText("Add")
  r.add:SetScript("OnClick", function() Picker.AddRow(i) end)
  r.time = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.time:SetPoint("RIGHT", r.add, "LEFT", -6, 0)
  r.time:SetJustifyH("RIGHT")
  r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.text:SetPoint("LEFT", 2, 0)
  r.text:SetPoint("RIGHT", r.time, "LEFT", -6, 0)
  r.text:SetJustifyH("LEFT")
  r.text:SetWordWrap(false)
  r:EnableMouse(true)
  r:SetScript("OnEnter", function(self)
    local p = self.place
    if not p then return end
    tooltip(self, p.npc or Picker.Kind().label, string.format("%s\nA detour of %s on your journey.", p.place or "",
      ns.FormatDuration(p.extra)))
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Button(r.add)
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
  tinsert(UISpecialFrames, "WaywardErrandPicker")

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

-- Under the directions box, or over it when there's no room below.
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
    frame:SetPoint("BOTTOMLEFT", hud, "TOPLEFT", 0, GAP)
  else
    frame:SetPoint("TOPLEFT", hud, "BOTTOMLEFT", 0, -GAP)
  end
end

function Picker.Kind() return ns.Errands.Kind(selected) end

function Picker.Refresh()
  if not (frame and frame:IsShown()) then return end
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
  local kind = Picker.Kind()
  frame.heading:SetText(string.format("%s  |cff9d9d9dleast out of the way first|r", kind.label))

  local ok, list, empty = pcall(ns.Errands.Get, selected)
  if not ok then
    geterrorhandler()(list)
    list, empty = {}, "Couldn't list these here."
  end
  frame.list = list
  for i, r in ipairs(frame.rows) do
    local p = list[i]
    r.place = p
    if p then
      r.text:SetText(string.format("%s  |cff9d9d9d%s|r", p.npc or kind.label, p.place or ""))
      r.time:SetText(p.inTrip and "|cff9d9d9din your journey|r" or ("+" .. ns.FormatDuration(p.extra)))
      r.add:SetEnabled(not p.inTrip)
      r:Show()
    else
      r:Hide()
    end
  end
  frame.empty:SetText(empty or "")
  frame.empty:SetShown(#list == 0)
  local body = #list > 0 and (4 + #list * ROW_HEIGHT) or (6 + (frame.empty:GetStringHeight() or 24))
  frame:SetHeight(PADDING + CHIP + 8 + (frame.heading:GetStringHeight() or 14) + body + PADDING)
end

function Picker.Select(key)
  if not ns.Errands.Kind(key) then return end
  selected = key
  Picker.Refresh()
end

function Picker.Show()
  if not ns.Nav.active then return end
  frame = frame or create()
  place()
  frame:Show()
  Picker.Select(selected and ns.Errands.Kind(selected) and selected or ns.Errands.DefaultKind())
end

function Picker.Hide()
  if frame then frame:Hide() end
end

function Picker.Toggle()
  if Picker.IsShown() then
    Picker.Hide()
  else
    -- Each time it opens: on what you most likely need now.
    selected = nil
    Picker.Show()
  end
end

function Picker.IsShown() return frame ~= nil and frame:IsShown() end

-- Adds the place on row `i` to the journey and closes the list.
function Picker.AddRow(i)
  local p = frame and frame.list and frame.list[i]
  if not p then return false end
  local added = ns.Errands.Add(selected, p)
  if added then Picker.Hide() else Picker.Refresh() end
  return added
end

-- The kind shown and its rows' text (for tests).
function Picker.Selected() return selected end
function Picker.Rows()
  local out = {}
  for _, r in ipairs(frame and frame.rows or {}) do
    if r:IsShown() then out[#out + 1] = { text = r.text:GetText(), time = r.time:GetText() } end
  end
  return out
end
function Picker.EmptyText() return frame and frame.empty:IsShown() and frame.empty:GetText() or nil end

ns.Listen("NAV_CHANGED", function()
  if not ns.Nav.active then Picker.Hide() end
end)

ns.Listen("HUD_MOVED", function()
  if Picker.IsShown() then place() end
end)
