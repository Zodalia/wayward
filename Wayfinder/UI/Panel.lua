local _, ns = ...

-- The main window: pick a category, see ranked options for your character,
-- click one to get directions. Only "Class trainer" works in this MVP.

local Panel = {}
ns.Panel = Panel

local CATEGORIES = {
  { label = "Class trainer", provider = ns.Trainers },
  { label = "Quest hubs" },
  { label = "Dungeons" },
  { label = "Vendors" },
}
local MAX_ROWS = 7
local ROW_HEIGHT = 42

local frame

local function showRouteTooltip(row)
  local r = row.result
  if not (r and r.route) then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetText(r.title)
  for i = 1, #r.route.steps do
    GameTooltip:AddLine(i .. ". " .. ns.Router.Describe(r.route, i), 1, 1, 1, true)
  end
  GameTooltip:AddLine("Click for directions", 0.5, 0.8, 0.7)
  GameTooltip:Show()
end

local function createRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(352, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", parent.summary, "BOTTOMLEFT", 0, -10 - (index - 1) * ROW_HEIGHT)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

  row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.title:SetPoint("TOPLEFT", 6, -5)
  row.title:SetPoint("RIGHT", -6, 0)
  row.title:SetJustifyH("LEFT")

  row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)
  row.sub:SetPoint("RIGHT", -6, 0)
  row.sub:SetJustifyH("LEFT")

  row:SetScript("OnEnter", showRouteTooltip)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self)
    local r = self.result
    if r and r.route then
      ns.Nav.Start(r.title, r.goal, r.route)
      frame:Hide()
    end
  end)
  return row
end

local function create()
  local f = CreateFrame("Frame", "WayfinderPanel", UIParent, "BackdropTemplate")
  f:SetSize(384, 470)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "panelPos")
  end)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  })
  ns.RestorePosition(f, "panelPos")
  tinsert(UISpecialFrames, "WayfinderPanel")

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 18, -16)
  title:SetText("Wayfinder")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  search:SetSize(338, 22)
  search:SetPoint("TOPLEFT", 24, -42)
  search:SetAutoFocus(false)
  search:Disable()
  local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  hint:SetPoint("LEFT", 2, 0)
  hint:SetText("Search (coming soon)")

  local previous
  for i, cat in ipairs(CATEGORIES) do
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(84, 22)
    b:SetText(cat.label)
    if previous then b:SetPoint("LEFT", previous, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 18, -72) end
    if cat.provider then
      b:SetScript("OnClick", function() Panel.Select(i) end)
    else
      b:Disable()
    end
    previous = b
  end

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.summary:SetPoint("TOPLEFT", 18, -104)
  f.summary:SetWidth(348)
  f.summary:SetJustifyH("LEFT")
  f.summary:SetWordWrap(true)

  f.rows = {}
  for i = 1, MAX_ROWS do f.rows[i] = createRow(f, i) end

  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.empty:SetPoint("TOPLEFT", f.summary, "BOTTOMLEFT", 0, -16)
  f.empty:SetWidth(348)
  f.empty:SetJustifyH("LEFT")
  f.empty:SetWordWrap(true)

  f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.footer:SetPoint("BOTTOMLEFT", 18, 16)
  f.footer:SetWidth(348)
  f.footer:SetJustifyH("LEFT")
  f.footer:SetWordWrap(true)

  f:SetScript("OnShow", function() Panel.Refresh() end)
  return f
end

local selected = 1

function Panel.Select(index)
  selected = index
  Panel.Refresh()
end

function Panel.Refresh()
  if not (frame and frame:IsShown()) then return end
  local provider = CATEGORIES[selected].provider
  frame.summary:SetText(provider.SummaryText())

  local results, err, net = provider.Results()
  for i, row in ipairs(frame.rows) do
    local r = results[i]
    row.result = r
    if r then
      row.title:SetText(r.title)
      if r.route then
        row.sub:SetText(string.format("%s  ·  %s  ·  %s", r.zone, ns.FormatDuration(r.route.seconds),
          ns.Router.Summary(r.route)))
      else
        row.sub:SetText(r.zone .. "  ·  no route found from here")
      end
      row:Show()
    else
      row:Hide()
    end
  end

  if err then
    frame.empty:SetText(err)
  elseif #results == 0 then
    local className = UnitClass("player")
    frame.empty:SetText(string.format("No %s trainers known yet. Talk to one once and Wayfinder "
      .. "remembers where they are. City guards can point you to one.", className:lower()))
  else
    frame.empty:SetText("")
  end

  local flights = net and net.knownFlights or 0
  if flights == 0 then
    frame.footer:SetText("|cffffd200No flight paths known yet, so routes are on foot. Talk to any "
      .. "flight master once and routes will use your flight paths.|r")
  else
    frame.footer:SetText(string.format("%d known flight path%s on routes. Open any flight map to update. "
      .. "Boat and zeppelin docks are approximate.", flights, flights == 1 and "" or "s"))
  end
end

function Panel.Toggle()
  frame = frame or create()
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

ns.Listen("DATA_CHANGED", function() Panel.Refresh() end)
ns.On("ZONE_CHANGED_NEW_AREA", function() Panel.Refresh() end)
