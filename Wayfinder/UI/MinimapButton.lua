local _, ns = ...

-- A minimap button that opens Wayfinder. Uses LibDBIcon when another addon
-- has loaded it (so button managers and UI suites can handle it), else a
-- standard round button you can drag around the minimap. Also an entry in the
-- addon compartment (## AddonCompartmentFunc in the TOC).

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local ICON = "Interface\\Icons\\INV_Misc_Map_01"
local DEFAULT_ANGLE = 225
local atan2 = math.atan2 or math.atan

local button, usingLibIcon

local function onClick(mouseButton)
  if mouseButton == "RightButton" and ns.Nav.active and ns.Nav.active.journey then
    ns.JourneyOverview.Toggle()
  else
    ns.Panel.Toggle()
  end
end

local function tooltip(tt)
  tt:AddLine("Wayfinder")
  tt:AddLine("Left-click: open the panel", 1, 1, 1)
  if ns.Nav.active and ns.Nav.active.journey then tt:AddLine("Right-click: journey overview", 1, 1, 1) end
  if not usingLibIcon then tt:AddLine("Drag to move", 0.6, 0.6, 0.6) end
end

---------------------------------------------------------------- own button

local function place()
  local angle = math.rad(ns.db.settings.minimapAngle or DEFAULT_ANGLE)
  local radius = (Minimap:GetWidth() or 140) / 2 + 5
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function createButton()
  local b = CreateFrame("Button", "WayfinderMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = b:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")
  local background = b:CreateTexture(nil, "BACKGROUND")
  background:SetSize(20, 20)
  background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  background:SetPoint("TOPLEFT", 7, -5)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture(ICON)
  icon:SetPoint("TOPLEFT", 7, -6)

  b:SetScript("OnClick", function(_, mouseButton) onClick(mouseButton) end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    tooltip(GameTooltip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      ns.db.settings.minimapAngle = math.deg(atan2(cy / scale - my, cx / scale - mx))
      place()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  return b
end

---------------------------------------------------------------- setup

local function libIcon()
  if type(LibStub) ~= "table" then return nil end
  local ldb = LibStub("LibDataBroker-1.1", true)
  local icon = LibStub("LibDBIcon-1.0", true)
  return ldb, icon
end

function MinimapButton.Setup()
  ns.db.settings.minimapIcon = ns.db.settings.minimapIcon or {}
  local ldb, icon = libIcon()
  if ldb and icon then
    local ok = pcall(function()
      local launcher = ldb:NewDataObject("Wayfinder", {
        type = "launcher", icon = ICON, label = "Wayfinder",
        OnClick = function(_, mouseButton) onClick(mouseButton) end,
        OnTooltipShow = tooltip,
      })
      icon:Register("Wayfinder", launcher, ns.db.settings.minimapIcon)
    end)
    usingLibIcon = ok
  end
  if not usingLibIcon and Minimap then
    button = createButton()
    place()
  end
  MinimapButton.Refresh()
end

function MinimapButton.Refresh()
  local hidden = ns.db.settings.minimapIcon and ns.db.settings.minimapIcon.hide
  if usingLibIcon then
    local _, icon = libIcon()
    if hidden then icon:Hide("Wayfinder") else icon:Show("Wayfinder") end
  elseif button then
    button:SetShown(not hidden)
  end
end

function MinimapButton.IsShown()
  if usingLibIcon then return not ns.db.settings.minimapIcon.hide end
  return button ~= nil and button:IsShown()
end

ns.On("PLAYER_LOGIN", MinimapButton.Setup)

ns.RegisterCommand("minimap", "/wf minimap - show or hide the minimap button", function()
  local settings = ns.db.settings.minimapIcon
  settings.hide = not settings.hide
  MinimapButton.Refresh()
  ns.print("minimap button " .. (settings.hide and "hidden" or "shown"))
end)

-- Addon compartment (the addons menu by the minimap).
function Wayfinder_OnAddonCompartmentClick(_, mouseButton)
  onClick(mouseButton)
end

function Wayfinder_OnAddonCompartmentEnter(_, menuButton)
  GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
  tooltip(GameTooltip)
  GameTooltip:Show()
end

function Wayfinder_OnAddonCompartmentLeave()
  GameTooltip:Hide()
end
