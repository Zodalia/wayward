local _, ns = ...

-- Moving the boxes in the game's Edit Mode and in EllesmereUI's unlock mode.
-- The directions, the journey overview, the "Journey complete!" banner and the
-- "New journey available" toast each get a box to drag there, shown or not.
-- The new spot is saved where the box's own drag saves it (settings.hudPos,
-- ...), keeping the box's own anchor point, so the directions still grow
-- downwards.
--
-- Edit Mode: Forever has Blizzard's (EditModeManagerFrame). While it's open we
-- put a box of our own over each pane; drag it to move the pane, right-click
-- it to put the pane back where it starts.
-- EllesmereUI: EllesmereUI:RegisterUnlockElements (EUI_UnlockMode.lua in its
-- repo), from PLAYER_LOGIN. Its mover hands over the spot as CENTER/CENTER
-- offsets from UIParent's centre; we place the pane by its own point.
--
-- Panes add themselves from their files: Movers.Add{ key, label, posKey,
-- home = { point, relativePoint, x, y }, frame = fn (makes it if needed),
-- moved = fn?, hidden = fn? }.

local Movers = {}
ns.Movers = Movers

local panes = {}
local overlays = {}
local editing = false

function Movers.Add(pane)
  panes[#panes + 1] = pane
end

function Movers.Panes() return panes end

-- Where `point` of a w x h box sits from its centre.
local OFFSETS = {
  TOPLEFT = { -1, 1 }, TOP = { 0, 1 }, TOPRIGHT = { 1, 1 },
  LEFT = { -1, 0 }, CENTER = { 0, 0 }, RIGHT = { 1, 0 },
  BOTTOMLEFT = { -1, -1 }, BOTTOM = { 0, -1 }, BOTTOMRIGHT = { 1, -1 },
}
local function fromCentre(point, w, h)
  local o = OFFSETS[point] or OFFSETS.CENTER
  return o[1] * (w or 0) / 2, o[2] * (h or 0) / 2
end

-- UIParent units to the frame's own (its SetPoint offsets).
local function ratio(f)
  local s = f:GetEffectiveScale()
  return (s and s > 0) and UIParent:GetEffectiveScale() / s or 1
end

local function saved(pane, f)
  ns.SavePosition(f, pane.posKey)
  if pane.moved then pane.moved() end
end

-- Moves the pane by dx, dy (UIParent units), keeping its anchor point.
function Movers.Shift(pane, dx, dy)
  local f = pane.frame()
  local point, _, relativePoint, x, y = f:GetPoint()
  local k = ratio(f)
  f:ClearAllPoints()
  f:SetPoint(point or pane.home[1], UIParent, relativePoint or pane.home[2], (x or 0) + dx * k, (y or 0) + dy * k)
  saved(pane, f)
end

-- Puts the pane's centre at x, y from UIParent's centre (UIParent units),
-- anchored by its home point.
function Movers.PlaceCentre(pane, x, y)
  local f = pane.frame()
  local k = ratio(f)
  local ox, oy = fromCentre(pane.home[1], f:GetSize())
  f:ClearAllPoints()
  f:SetPoint(pane.home[1], UIParent, "CENTER", x * k + ox, y * k + oy)
  saved(pane, f)
end

-- The pane's centre from UIParent's centre (UIParent units).
function Movers.Centre(pane)
  local f = pane.frame()
  local point, _, relativePoint, x, y = f:GetPoint()
  local k = ratio(f)
  local ox, oy = fromCentre(point, f:GetSize())
  local rx, ry = fromCentre(relativePoint, UIParent:GetSize())
  return rx + ((x or 0) - ox) / k, ry + ((y or 0) - oy) / k
end

-- Back where it starts.
function Movers.Reset(pane)
  local f = pane.frame()
  ns.db.settings[pane.posKey] = nil
  ns.RestorePosition(f, pane.posKey, pane.home)
  if pane.moved then pane.moved() end
end

---------------------------------------------------------------- Edit Mode

local function fit(o)
  local f = o.pane.frame()
  local k = ratio(f)
  local w, h = f:GetSize()
  o:SetSize(math.max(40, (w or 0) / k), math.max(24, (h or 0) / k))
  o:ClearAllPoints()
  o:SetPoint("CENTER", f, "CENTER")
end

local function createOverlay(pane)
  local o = CreateFrame("Button", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  o.pane = pane
  o:SetFrameStrata("DIALOG")
  o:SetMovable(true)
  o:SetClampedToScreen(true)
  o:RegisterForDrag("LeftButton")
  o:RegisterForClicks("RightButtonUp")
  if o.SetBackdrop then
    o:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    o:SetBackdropColor(0.1, 0.45, 0.9, 0.35)
    o:SetBackdropBorderColor(0.3, 0.7, 1, 0.9)
  end
  o.label = o:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  o.label:SetPoint("CENTER")
  o.label:SetText("Wayward: " .. pane.label)
  o:SetScript("OnDragStart", function(self)
    self.fromX, self.fromY = self:GetCenter()
    self:StartMoving()
  end)
  o:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local x, y = self:GetCenter()
    if x and self.fromX then Movers.Shift(pane, x - self.fromX, y - self.fromY) end
    fit(self)
  end)
  o:SetScript("OnClick", function(self)
    Movers.Reset(pane)
    fit(self)
  end)
  o:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Wayward: " .. pane.label)
    GameTooltip:AddLine("Drag to move. Right-click: back where it starts.", 0.5, 0.8, 0.7)
    GameTooltip:Show()
  end)
  o:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- The directions grow and shrink with their text.
  pane.frame():HookScript("OnSizeChanged", function() if o:IsShown() then fit(o) end end)
  return o
end

function Movers.EnterEditMode()
  editing = true
  for i, pane in ipairs(panes) do
    if pane.hidden and pane.hidden() then
      if overlays[i] then overlays[i]:Hide() end
    else
      overlays[i] = overlays[i] or createOverlay(pane)
      fit(overlays[i])
      overlays[i]:Show()
    end
  end
end

function Movers.ExitEditMode()
  editing = false
  for _, o in pairs(overlays) do o:Hide() end
end

function Movers.Editing() return editing end

-- The boxes shown now, by pane key (for tests).
function Movers.Overlays()
  local out = {}
  for i, o in pairs(overlays) do
    if o:IsShown() then out[panes[i].key] = o end
  end
  return out
end

local function hookEditMode()
  local m = EditModeManagerFrame
  if not (m and m.HookScript) then return end
  m:HookScript("OnShow", Movers.EnterEditMode)
  m:HookScript("OnHide", Movers.ExitEditMode)
  if m:IsShown() then Movers.EnterEditMode() end
end

---------------------------------------------------------------- EllesmereUI

-- The element tables we hand EllesmereUI (for tests).
function Movers.UnlockElements()
  local out = {}
  for i, pane in ipairs(panes) do
    out[#out + 1] = {
      key = "Wayward_" .. pane.key,
      label = "Wayward: " .. pane.label,
      group = "Wayward",
      order = 900 + i,
      getFrame = pane.frame,
      getSize = function() return pane.frame():GetSize() end,
      savePos = function(_, point, relativePoint, x, y)
        if point == "CENTER" and (relativePoint or "CENTER") == "CENTER" then
          Movers.PlaceCentre(pane, x or 0, y or 0)
        else
          local f = pane.frame()
          f:ClearAllPoints()
          f:SetPoint(point, UIParent, relativePoint or point, x or 0, y or 0)
          saved(pane, f)
        end
      end,
      loadPos = function()
        local x, y = Movers.Centre(pane)
        return { point = "CENTER", relPoint = "CENTER", x = x, y = y }
      end,
      clearPos = function() Movers.Reset(pane) end,
      applyPos = function() ns.RestorePosition(pane.frame(), pane.posKey, pane.home) end,
      onLiveMove = pane.moved,
      isHidden = pane.hidden,
      -- We place our panes ourselves and they change size with their text:
      -- no resizing, no anchor links, no re-applying at login.
      noResize = true,
      noInitHook = true,
      ownsPosition = true,
      noAnchorTo = true,
      noAnchorTarget = true,
    }
  end
  return out
end

local function registerUnlock()
  local E = EllesmereUI
  if type(E) ~= "table" or type(E.RegisterUnlockElements) ~= "function" then return end
  local make = type(E.MakeUnlockElement) == "function" and E.MakeUnlockElement
  local elements = {}
  for _, spec in ipairs(Movers.UnlockElements()) do
    if make then
      elements[#elements + 1] = make(spec)
    else
      -- The long field names, as MakeUnlockElement would give them.
      spec.savePosition, spec.loadPosition = spec.savePos, spec.loadPos
      spec.clearPosition, spec.applyPosition = spec.clearPos, spec.applyPos
      elements[#elements + 1] = spec
    end
  end
  local ok, err = pcall(E.RegisterUnlockElements, E, elements, "Wayward")
  if not ok then ns.print("couldn't add the boxes to EllesmereUI's unlock mode: " .. tostring(err)) end
  Movers.unlockRegistered = ok
end

ns.On("PLAYER_LOGIN", function()
  hookEditMode()
  registerUnlock()
end)
