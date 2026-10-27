local _, ns = ...

-- A button that targets the NPC the current step is for (/target <name>, the
-- game's own command, run when you click it or press its key binding:
-- Key Bindings > AddOns > Wayward). It's a secure button, so it stands on
-- its own beside the directions box rather than inside it (a box with a
-- secure button in it couldn't be moved or hidden in combat), and it changes
-- only out of combat; a change in combat waits for it to end.

local TargetButton = {}
ns.TargetButton = TargetButton

BINDING_HEADER_WAYWARD = "Wayward"
_G["BINDING_NAME_CLICK WaywardTargetButton:LeftButton"] = "Target the NPC for this step"

local ICON = "Interface\\Icons\\Ability_Hunter_SniperShot"
local button, pending, macro

local function create()
  local b = CreateFrame("Button", "WaywardTargetButton", UIParent, "SecureActionButtonTemplate")
  b:SetSize(26, 26)
  -- The directions box's layer, not above it: a window over the box (the
  -- Wayward panel) covers the button too, instead of it floating on top.
  b:SetFrameStrata("MEDIUM")
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type", "macro")
  b:SetNormalTexture(ICON)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  border:SetSize(26 * 64 / 36, 26 * 64 / 36)
  border:SetPoint("CENTER")
  b:SetScript("OnEnter", function(self)
    local name = ns.Nav.TargetNPC()
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Target " .. (name or "the NPC for this step"))
    local key = GetBindingKey and GetBindingKey("CLICK WaywardTargetButton:LeftButton")
    GameTooltip:AddLine(key and ("Key: " .. key) or "Set a key: Key Bindings > AddOns > Wayward", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:Hide()
  return b
end

-- Shows the button by the directions box with the current step's NPC, or hides it.
function TargetButton.Sync()
  if InCombatLockdown and InCombatLockdown() then
    pending = true
    return
  end
  pending = false
  button = button or create()
  local name = ns.Nav.active and ns.Nav.TargetNPC()
  local hud = ns.HUD.Frame and ns.HUD.Frame()
  local right, top = hud and hud:IsShown() and hud:GetRight(), hud and hud:GetTop()
  if name and right and top then
    macro = "/target " .. name
    button:SetAttribute("macrotext", macro)
    button:ClearAllPoints()
    -- Placed by position, not anchored to the box, so the box stays free to move.
    button:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right + 4, top - 4)
    if hud.GetFrameStrata and button.SetFrameStrata then
      button:SetFrameStrata(hud:GetFrameStrata() or "MEDIUM")
      button:SetFrameLevel((hud:GetFrameLevel() or 0) + 5)
    end
    button:Show()
  else
    macro = nil
    button:Hide()
  end
end

-- The button itself (for tests).
function TargetButton.Frame() return button end

-- What a click runs right now (for tests), or nil when the button is hidden.
function TargetButton.Macro()
  return macro
end

ns.Listen("NAV_CHANGED", function() ns.After(0, TargetButton.Sync) end)
ns.Listen("HUD_MOVED", TargetButton.Sync)
ns.On("PLAYER_REGEN_ENABLED", function() if pending then TargetButton.Sync() end end)
