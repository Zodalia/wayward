local _, ns = ...

-- A "more actions" menu: the one place for what you reach for now and then,
-- or what can't be undone (skip, set aside, end), so those don't sit on a box
-- as a row of icons. Shared by every surface, so "..." means the same thing
-- everywhere.
--   ns.Menu.Show(owner, items)   items = { { text =, onClick =, tip = }, ... }
-- The game's own context menu where the client has one (MenuUtil); else a
-- small box of our own under `owner`, closed by picking, by clicking away or
-- by Escape. Showing it again from the same owner closes it.

local Menu = {}
ns.Menu = Menu

local WIDTH = 170
local ROW = 20
local PAD = 6

local frame, catcher
local current = {}   -- the items shown (or last handed to the game's menu)
local currentOwner

local function hide()
  if frame then frame:Hide() end
  if catcher then catcher:Hide() end
  currentOwner = nil
end

local function row(parent, i)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(ROW)
  b:SetPoint("TOPLEFT", PAD, -PAD - (i - 1) * ROW)
  b:SetPoint("RIGHT", -PAD, 0)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 0.82, 0, 0.18)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 4, 0)
  b.text:SetPoint("RIGHT", -4, 0)
  b.text:SetJustifyH("LEFT")
  b.text:SetWordWrap(false)
  ns.Skin.Text(b.text)
  b:SetScript("OnClick", function(self)
    local item = self.item
    hide()
    if item and item.onClick then item.onClick() end
  end)
  b:SetScript("OnEnter", function(self)
    local item = self.item
    if not (item and item.tip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(item.text)
    GameTooltip:AddLine(item.tip, 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function create()
  -- Under the menu, over everything else: a click anywhere else closes it.
  catcher = CreateFrame("Button", nil, UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("DIALOG")
  catcher:RegisterForClicks("AnyUp")
  catcher:SetScript("OnClick", hide)
  catcher:Hide()

  local f = ns.Skin.CreateBox("WaywardMenu")
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetBackdropColor(0, 0, 0, 0.92)
  f.rows = {}
  f:Hide()
  tinsert(UISpecialFrames, "WaywardMenu")
  f:SetScript("OnHide", function() if catcher then catcher:Hide() end end)
  ns.Skin.Box(f)
  return f
end

-- The game's context menu, when this client has it. False when it hasn't or
-- it failed (then our own box shows).
local function native(owner, items)
  if not (MenuUtil and MenuUtil.CreateContextMenu) then return false end
  local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
    for _, item in ipairs(items) do
      local element = root:CreateButton(item.text, function() if item.onClick then item.onClick() end end)
      if item.tip and element and element.SetTooltip then
        element:SetTooltip(function(tooltip)
          tooltip:SetText(item.text)
          tooltip:AddLine(item.tip, 0.6, 0.6, 0.6, true)
        end)
      end
    end
  end)
  return ok
end

function Menu.Show(owner, items)
  if frame and frame:IsShown() and currentOwner == owner then return hide() end
  current = items or {}
  if #current == 0 then return hide() end
  if native(owner, current) then return end
  frame = frame or create()
  for i, item in ipairs(current) do
    local b = frame.rows[i] or row(frame, i)
    frame.rows[i] = b
    b.item = item
    b.text:SetText(item.text)
    b:Show()
  end
  for i = #current + 1, #frame.rows do frame.rows[i]:Hide() end
  frame:SetSize(WIDTH, #current * ROW + 2 * PAD)
  frame:ClearAllPoints()
  frame:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -2)
  currentOwner = owner
  catcher:Show()
  frame:Show()
end

function Menu.Hide() hide() end

-- Whether our own box is showing (the game's menu looks after itself).
function Menu.IsShown() return frame ~= nil and frame:IsShown() end

-- The items last shown, as their labels; and picking one (for tests).
function Menu.Labels()
  local out = {}
  for i, item in ipairs(current) do out[i] = item.text end
  return out
end

function Menu.Pick(i)
  local item = current[i]
  hide()
  if item and item.onClick then item.onClick() end
end
