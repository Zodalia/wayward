local _, ns = ...

-- A raid target marker (a star) on the NPC the current step leads to (see
-- Nav.TargetNPC): the flight master, the quest giver, the trainer. Set when
-- you see them (their nameplate, your mouseover, your target), and only near
-- where the step goes, so a namesake elsewhere isn't marked. Off with the
-- option or /wf marker.

local Marker = {}
ns.Marker = Marker

local STAR = 1
local NEAR = 100 -- yards from the step's place

local function secret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

local function enabled()
  return ns.db and ns.db.settings.markNPCs ~= false
end

-- Marks `unit` when it's who the step is for. Returns true when it did.
function Marker.Try(unit)
  if not (enabled() and SetRaidTarget and UnitExists and UnitExists(unit)) then return false end
  if UnitIsPlayer and UnitIsPlayer(unit) then return false end
  local name, node = ns.Nav.TargetNPC()
  if not (name and node) then return false end
  local unitName = UnitName(unit)
  if secret(unitName) or unitName ~= name then return false end
  local here = ns.Geo.PlayerNode()
  if not (here and ns.Geo.Distance(here, node) <= NEAR) then return false end
  if GetRaidTargetIndex and GetRaidTargetIndex(unit) == STAR then return true end
  local ok = pcall(SetRaidTarget, unit, STAR)
  if ok then Marker.marked = name end
  return ok
end

local function scanNameplates()
  if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
    if plate.namePlateUnitToken then Marker.Try(plate.namePlateUnitToken) end
  end
end

ns.On("NAME_PLATE_UNIT_ADDED", function(unit) Marker.Try(unit) end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() Marker.Try("mouseover") end)
ns.On("PLAYER_TARGET_CHANGED", function() Marker.Try("target") end)
ns.Listen("NAV_CHANGED", scanNameplates)

ns.RegisterCommand("marker", "/wf marker - the star marker on the NPC you're heading for on or off", function()
  ns.SetSetting("markNPCs", not enabled())
  ns.print("NPC marker " .. (enabled() and "on" or "off"))
end)
