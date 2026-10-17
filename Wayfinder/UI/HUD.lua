local _, ns = ...

-- Directions box shown while navigating: current step, distance, and our own
-- arrow. Blizzard's on-screen navigation is off by default in Forever
-- (showInGameNavigation = 0), so we don't rely on it.

local HUD = {}
ns.HUD = HUD

local frame
local UPDATE_INTERVAL = 0.1

local function button(parent, text, onClick, tooltip)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(24, 20)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(tooltip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Button(b)
  return b
end

local function create()
  local f = ns.Skin.CreateBox("WayfinderHUD")
  f:SetSize(320, 78)
  f:SetPoint("TOP", 0, -140)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "hudPos")
  end)
  f:SetBackdropColor(0, 0, 0, 0.8)
  ns.RestorePosition(f, "hudPos")

  -- On its own frame: skins fade every texture of the box itself.
  local arrowHolder = CreateFrame("Frame", nil, f)
  arrowHolder:SetAllPoints()
  f.arrow = arrowHolder:CreateTexture(nil, "ARTWORK")
  f.arrow:SetSize(40, 40)
  f.arrow:SetPoint("LEFT", 10, 0)
  f.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 58, -9)
  f.title:SetPoint("RIGHT", -86, 0)
  f.title:SetJustifyH("LEFT")

  f.step = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.step:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
  f.step:SetPoint("RIGHT", -10, 0)
  f.step:SetJustifyH("LEFT")
  f.step:SetWordWrap(true)

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.info:SetPoint("BOTTOMLEFT", 58, 9)
  f.info:SetJustifyH("LEFT")
  ns.Skin.Text(f.title)
  ns.Skin.Text(f.step)
  ns.Skin.Text(f.info)

  local stop = button(f, "x", function() ns.Nav.Stop() end, "Stop directions")
  stop:SetPoint("TOPRIGHT", -6, -6)
  local nextB = button(f, ">", function() ns.Nav.Next() end, "Skip to next step")
  nextB:SetPoint("RIGHT", stop, "LEFT", -2, 0)
  local prev = button(f, "<", function() ns.Nav.Prev() end, "Previous step")
  prev:SetPoint("RIGHT", nextB, "LEFT", -2, 0)
  local recalc = button(f, "R", function() ns.Nav.Recalculate() end, "Recalculate from here")
  recalc:SetPoint("TOP", stop, "BOTTOM", 0, -26)
  f.list = button(f, "=", function() ns.JourneyOverview.Toggle() end, "All stops of this journey")
  f.list:SetPoint("RIGHT", recalc, "LEFT", -2, 0)

  local elapsed = 0
  f:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= UPDATE_INTERVAL then
      elapsed = 0
      HUD.Update()
    end
  end)
  ns.Skin.Box(f)
  return f
end

local function facing()
  local value = GetPlayerFacing and GetPlayerFacing()
  if value == nil or (type(issecretvalue) == "function" and issecretvalue(value)) then return nil end
  return value
end

-- The first unfinished objective of a quest in your log, e.g. "4/8 Wolf Meat".
function HUD.ObjectiveText(questID)
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  for _, o in ipairs(objectives or {}) do
    if not o.finished and o.text then return o.text end
  end
  return nil
end

function HUD.Update()
  if not frame then return end
  local here, step = ns.Nav.Tick()
  local a = ns.Nav.active
  if not (a and step) then
    frame:Hide()
    return
  end
  if a.journey then
    frame.title:SetText(string.format("%s  (%d/%d stops)", a.title, ns.Journey.StopsDone(a.journey),
      #a.journey.stops))
  else
    frame.title:SetText(a.title)
  end
  frame.step:SetText(string.format("%d/%d  %s", a.index, #a.route.steps, ns.Router.Describe(a.route, a.index)))

  local distance = here and ns.Geo.Distance(here, step.to) or math.huge
  local remaining = ns.FormatDuration(ns.Nav.RemainingSeconds(here))
  frame.list:SetShown(a.journey ~= nil)
  local objective = step.stop and step.stop.action and step.stop.action.kind == "complete"
    and HUD.ObjectiveText(step.stop.action.questID)
  if objective then
    frame.info:SetText(objective .. "  ·  " .. remaining .. " to go")
  elseif ns.Nav.Waiting() then
    frame.info:SetText("|cff7fd1aeYou're here|r  ·  " .. remaining .. " to go")
  elseif distance < math.huge and step.mode == "walk" then
    frame.info:SetText(string.format("%d yd  ·  %s to go", math.floor(distance), remaining))
  else
    frame.info:SetText(remaining .. " to go")
  end

  local heading = facing()
  if ns.db.settings.showArrow and step.mode == "walk" and distance < math.huge and heading then
    frame.arrow:SetRotation(ns.Geo.Bearing(here, step.to) - heading)
    frame.arrow:Show()
  else
    frame.arrow:Hide()
  end
end

ns.Listen("NAV_CHANGED", function()
  if ns.Nav.active then
    frame = frame or create()
    frame:Show()
    HUD.Update()
  elseif frame then
    frame:Hide()
  end
end)
