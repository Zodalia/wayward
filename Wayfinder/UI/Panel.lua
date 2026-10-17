local _, ns = ...

-- The main window: pick a category, see ranked options for your character,
-- click one to get directions.

local Panel = {}
ns.Panel = Panel

local CATEGORIES = {
  { label = "Class trainer", provider = ns.Trainers },
  { label = "Quest hubs", provider = ns.QuestHubs },
  { label = "Dungeons" },
  { label = "Vendors" },
}
local MAX_ROWS = 7
local ROW_HEIGHT = 42
local MAX_DETAIL_LINES = 12

local frame

local function showRouteTooltip(row)
  local r = row.result
  if not (r and r.route) then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetText(r.title)
  for i, line in ipairs(r.details or {}) do
    if i > MAX_DETAIL_LINES then
      GameTooltip:AddLine(string.format("... and %d more", #r.details - MAX_DETAIL_LINES), 0.6, 0.6, 0.6)
      break
    end
    local c = line.color or { r = 1, g = 1, b = 1 }
    GameTooltip:AddLine(line.text, c.r, c.g, c.b)
  end
  if r.details then GameTooltip:AddLine(" ") end
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
  f.categoryButtons = {}
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
    f.categoryButtons[i] = b
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
  -- New frames start shown; hide so the first Toggle opens rather than closes.
  f:Hide()
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
  for i, b in ipairs(frame.categoryButtons) do
    if i == selected then b:LockHighlight() else b:UnlockHighlight() end
  end

  local results, err, net = provider.Results()
  frame.summary:SetText(provider.SummaryText())
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
    frame.empty:SetText(provider.EmptyText())
  else
    frame.empty:SetText("")
  end

  local source = ns.Questie.StatusText()
  source = source and ("Data: " .. source .. " + places you visited. ")
    or "Data: places you visited (install QuestieDB for more). "
  local flights = net and net.knownFlights or 0
  if flights == 0 then
    frame.footer:SetText(source .. "|cffffd200No flight paths known yet, so routes are on foot. Talk to "
      .. "any flight master once and routes will use your flight paths.|r")
  else
    frame.footer:SetText(source .. string.format("%d known flight path%s. Boat and zeppelin docks are "
      .. "approximate.", flights, flights == 1 and "" or "s"))
  end
end

function Panel.IsShown()
  return frame ~= nil and frame:IsShown()
end

function Panel.Toggle()
  frame = frame or create()
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

ns.Listen("DATA_CHANGED", function() Panel.Refresh() end)
ns.On("ZONE_CHANGED_NEW_AREA", function() Panel.Refresh() end)
