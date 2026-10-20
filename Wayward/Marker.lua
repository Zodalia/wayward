local _, ns = ...

-- Showing you the NPC the current step is for (Nav.TargetNPC: the flight
-- master, the quest giver, the trainer), within what addons may do: raid
-- markers are protected, so instead
--   * a star over their nameplate (friendly NPC nameplates have to be on: the
--     options can turn the game's setting on), and
--   * a line in their tooltip when you mouse over them;
-- both only near where the step goes, so a namesake elsewhere isn't picked.
-- The directions box's target button (UI/HUD.lua) targets them for you.
-- /ww marker or the options turn the star and the tooltip line off.

local Marker = {}
ns.Marker = Marker

local NEAR = 100 -- yards from the step's place
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"

local function secret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

local function enabled()
  return ns.db and ns.db.settings.markNPCs ~= false
end

-- True when `unit` is who the current step is for.
function Marker.IsTarget(unit)
  if not (UnitExists and UnitExists(unit)) or (UnitIsPlayer and UnitIsPlayer(unit)) then return false end
  local name, node = ns.Nav.TargetNPC()
  if not (name and node) then return false end
  local unitName = UnitName(unit)
  if secret(unitName) or unitName ~= name then return false end
  local here = ns.Geo.PlayerNode()
  return here ~= nil and ns.Geo.Distance(here, node) <= NEAR
end

---------------------------------------------------------------- nameplates

local stars = {} -- [nameplate frame] = texture

local function plateFor(unit)
  local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
  if not plate or (plate.IsForbidden and plate:IsForbidden()) then return nil end
  return plate
end

-- Puts the star over `unit`'s nameplate when it's who the step is for (and
-- takes it off when not). Returns true when the star shows.
function Marker.Try(unit)
  local plate = plateFor(unit)
  if not plate then return false end
  local show = enabled() and Marker.IsTarget(unit)
  local star = stars[plate]
  if show and not star then
    star = plate:CreateTexture(nil, "OVERLAY")
    star:SetTexture(STAR)
    star:SetSize(22, 22)
    star:SetPoint("BOTTOM", plate, "TOP", 0, 2)
    stars[plate] = star
  end
  if star then star:SetShown(show) end
  return show
end

local function scan()
  for plate, star in pairs(stars) do star:Hide() end
  if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
    if plate.namePlateUnitToken then Marker.Try(plate.namePlateUnitToken) end
  end
end

ns.On("NAME_PLATE_UNIT_ADDED", function(unit) Marker.Try(unit) end)
ns.On("NAME_PLATE_UNIT_REMOVED", function(unit)
  local plate = plateFor(unit)
  if plate and stars[plate] then stars[plate]:Hide() end
end)
ns.Listen("NAV_CHANGED", scan)
ns.Listen("SETTINGS_CHANGED", function(key) if key == "markNPCs" then scan() end end)

-- The game's own setting: friendly NPCs' nameplates. Off by default.
function Marker.FriendlyNameplates()
  return GetCVarBool and GetCVarBool("nameplateShowFriendlyNPCs") or false
end

function Marker.SetFriendlyNameplates(on)
  if InCombatLockdown and InCombatLockdown() then
    ns.print("can't change nameplates in combat; try again after.")
    return
  end
  if SetCVar then SetCVar("nameplateShowFriendlyNPCs", on and "1" or "0") end
end

---------------------------------------------------------------- tooltips

-- The line added to their tooltip, or nil.
function Marker.TooltipLine(unit)
  if not (enabled() and Marker.IsTarget(unit)) then return nil end
  local step = ns.Nav.CurrentStep()
  local what = step and ns.Router.Describe(ns.Nav.active.route, ns.Nav.active.index) or "this step"
  return "Wayward: " .. what
end

local function onUnitTooltip(tooltip)
  if tooltip ~= GameTooltip then return end
  local ok, line = pcall(function()
    local _, unit = tooltip:GetUnit()
    return unit and Marker.TooltipLine(unit)
  end)
  if ok and line then pcall(tooltip.AddLine, tooltip, line, 0.5, 0.82, 0.68) end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, onUnitTooltip)
elseif GameTooltip and GameTooltip.HookScript then
  pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", onUnitTooltip)
end

ns.RegisterCommand("marker", "/ww marker - the star over the NPC you're heading for, and their tooltip line, on or off", function()
  ns.SetSetting("markNPCs", not enabled())
  ns.print("NPC star and tooltip line " .. (enabled() and "on" or "off")
    .. (enabled() and not Marker.FriendlyNameplates() and " (the star needs friendly NPC nameplates: see /ww options)" or ""))
end)
