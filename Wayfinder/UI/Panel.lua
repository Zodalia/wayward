local _, ns = ...

-- The main window: tabs for pages (For you, Find, Quests, Items, ...), a search
-- box, and ranked results; click a result to get directions.
--
-- Page contract (register with ns.RegisterPage(page) from any file that loads
-- before this one):
--   page.id, page.label        -- tab
--   page.order                 -- tab position, lowest first; the first tab opens by default
--   page.searchable            -- show the search box (shift-clicked links go in it too)
--   page.placeholder           -- search box hint
--   page.SummaryText(query)    -- line under the search box
--   page.EmptyText(query)      -- shown when there are no results
--   page.Results(query)        -- returns results, err, net
--   page.categories            -- optional { {label, provider}, ... } shown as buttons
--                                 (providers use the same Summary/Empty/Results shape)
-- A result:
--   title, and either subtitle or zone (zone gets "· time · summary" appended),
--   goal + route (from ns.Router.Plan) or journey (from ns.Journey.Plan),
--   details = { {text, color}, ... } for the tooltip,
--   actions = { {label, run = function(result) end} } (the first is shown as a button).

local Panel = {}
ns.Panel = Panel

local MAX_ROWS = 7
local ROW_HEIGHT = 42
local MAX_DETAIL_LINES = 12
local SEARCH_DELAY = 0.3

local frame
local selectedPage, selectedCategory = nil, 1
local query = ""

---------------------------------------------------------------- Find page

local function matches(r, q)
  if q == "" then return true end
  local text = ((r.title or "") .. " " .. (r.zone or "") .. " " .. (r.subtitle or "")):lower()
  return text:find(q:lower(), 1, true) ~= nil
end

local findPage = {
  id = "find", label = "Find", order = 20, searchable = true, placeholder = "Filter these results",
  categories = {
    { label = "Class trainer", provider = ns.Trainers },
    { label = "Quest hubs", provider = ns.QuestHubs },
    { label = "Dungeons", provider = ns.Dungeons },
    { label = "Vendors", provider = ns.Vendors },
  },
}

local function category()
  return findPage.categories[selectedCategory].provider
end

function findPage.SummaryText() return category().SummaryText() end
function findPage.EmptyText() return category().EmptyText() end

function findPage.Results(q)
  local results, err, net = category().Results()
  if q == "" then return results, err, net end
  local filtered = {}
  for _, r in ipairs(results) do
    if matches(r, q) then filtered[#filtered + 1] = r end
  end
  return filtered, err, net
end

ns.RegisterPage(findPage)

---------------------------------------------------------------- rows

local function addDetails(r)
  for i, line in ipairs(r.details or {}) do
    if i > MAX_DETAIL_LINES then
      GameTooltip:AddLine(string.format("... and %d more", #r.details - MAX_DETAIL_LINES), 0.6, 0.6, 0.6)
      break
    end
    local c = line.color or { r = 1, g = 1, b = 1 }
    GameTooltip:AddLine(line.text, c.r, c.g, c.b)
  end
  if r.details then GameTooltip:AddLine(" ") end
end

local function showTooltip(row)
  local r = row.result
  if not r then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetText(r.title)
  addDetails(r)
  if r.journey then
    for i, stop in ipairs(r.journey.stops) do
      GameTooltip:AddLine(i .. ". " .. (stop.text or stop.node.label or "?"), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click to start this journey", 0.5, 0.8, 0.7)
  elseif r.route then
    for i = 1, #r.route.steps do
      GameTooltip:AddLine(i .. ". " .. ns.Router.Describe(r.route, i), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click for directions", 0.5, 0.8, 0.7)
  end
  GameTooltip:Show()
end

local function subtitle(r)
  if r.subtitle then return r.subtitle end
  if r.journey then
    local stops = #r.journey.stops
    return string.format("%s  ·  %s  ·  %d stop%s", r.zone or "", ns.FormatDuration(r.journey.seconds), stops,
      stops == 1 and "" or "s")
  end
  if r.route then
    return string.format("%s  ·  %s  ·  %s", r.zone or "", ns.FormatDuration(r.route.seconds),
      ns.Router.Summary(r.route))
  end
  return (r.zone or "") .. "  ·  no route found from here"
end

local function createRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(352, ROW_HEIGHT)
  row:SetPoint("TOPLEFT", parent.summary, "BOTTOMLEFT", 0, -10 - (index - 1) * ROW_HEIGHT)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

  row.action = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.action:SetSize(72, 20)
  row.action:SetPoint("TOPRIGHT", -4, -4)
  row.action:SetScript("OnClick", function()
    local r = row.result
    local action = r and r.actions and r.actions[1]
    if action then
      action.run(r)
      Panel.Refresh()
    end
  end)

  row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.title:SetPoint("TOPLEFT", 6, -5)
  row.title:SetPoint("RIGHT", row.action, "LEFT", -4, 0)
  row.title:SetJustifyH("LEFT")

  row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -3)
  row.sub:SetPoint("RIGHT", -6, 0)
  row.sub:SetJustifyH("LEFT")

  row:SetScript("OnEnter", showTooltip)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self)
    local r = self.result
    if r and r.journey then
      ns.Nav.StartJourney(r.journey)
      frame:Hide()
    elseif r and r.route then
      ns.Nav.Start(r.title, r.goal, r.route)
      frame:Hide()
    end
  end)
  return row
end

---------------------------------------------------------------- search

local pendingSearch = 0

local function scheduleSearch()
  pendingSearch = pendingSearch + 1
  local token = pendingSearch
  C_Timer.After(SEARCH_DELAY, function()
    if token == pendingSearch then Panel.Refresh() end
  end)
end

-- Shift-clicking an item, quest or spell while the search box has focus puts
-- its link there (both hook points exist on some clients, hence the guard).
local lastLink, lastLinkTime
local function insertLink(text)
  if not (frame and frame:IsShown() and frame.search:HasFocus() and type(text) == "string") then return end
  local now = GetTime and GetTime() or 0
  if text == lastLink and lastLinkTime == now then return end
  lastLink, lastLinkTime = text, now
  frame.search:Insert(text)
end

local function hookLinks()
  if type(ChatEdit_InsertLink) == "function" then hooksecurefunc("ChatEdit_InsertLink", insertLink) end
  if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
    hooksecurefunc(ChatFrameUtil, "InsertLink", insertLink)
  end
end

---------------------------------------------------------------- frame

local function sortedPages()
  table.sort(ns.pages, function(a, b)
    if (a.order or 100) ~= (b.order or 100) then return (a.order or 100) < (b.order or 100) end
    return a.label < b.label
  end)
  return ns.pages
end

local function create()
  local f = CreateFrame("Frame", "WayfinderPanel", UIParent, "BackdropTemplate")
  f:SetSize(384, 520)
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

  -- Page tabs.
  local pages = sortedPages()
  local tabWidth = math.floor((348 - 4 * (#pages - 1)) / math.max(#pages, 1))
  f.tabs = {}
  local previous
  for i, page in ipairs(pages) do
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(math.min(tabWidth, 110), 22)
    b:SetText(page.label)
    if previous then b:SetPoint("LEFT", previous, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 18, -40) end
    b:SetScript("OnClick", function() Panel.SelectPage(page.id) end)
    f.tabs[i] = { button = b, page = page }
    previous = b
  end

  f.search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  f.search:SetSize(338, 22)
  f.search:SetPoint("TOPLEFT", 24, -68)
  f.search:SetAutoFocus(false)
  f.search.hint = f.search:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.search.hint:SetPoint("LEFT", 2, 0)
  f.search:SetScript("OnTextChanged", function(self, userInput)
    query = self:GetText() or ""
    self.hint:SetShown(query == "")
    if userInput then scheduleSearch() end
  end)
  f.search:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    Panel.Refresh()
  end)
  f.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  -- Category buttons (Find page).
  f.categoryButtons = {}
  previous = nil
  for i, cat in ipairs(findPage.categories) do
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(84, 22)
    b:SetText(cat.label)
    if previous then b:SetPoint("LEFT", previous, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 18, -96) end
    b:SetScript("OnClick", function() Panel.Select(i) end)
    f.categoryButtons[i] = b
    previous = b
  end

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
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

  hookLinks()
  f:SetScript("OnShow", function() Panel.Refresh() end)
  -- New frames start shown; hide so the first Toggle opens rather than closes.
  f:Hide()
  return f
end

---------------------------------------------------------------- refresh

local function currentPage()
  if not selectedPage then selectedPage = sortedPages()[1] end
  return selectedPage
end

local function layout(page)
  for _, tab in ipairs(frame.tabs) do
    if tab.page == page then tab.button:LockHighlight() else tab.button:UnlockHighlight() end
  end
  if page.searchable then frame.search:Show() else frame.search:Hide() end
  frame.search.hint:SetText(page.placeholder or "Search")
  local showCategories = page.categories ~= nil
  for i, b in ipairs(frame.categoryButtons) do
    b:SetShown(showCategories)
    if i == selectedCategory then b:LockHighlight() else b:UnlockHighlight() end
  end
  local top = page.searchable and -96 or -68
  if showCategories then top = top - 28 end
  frame.summary:ClearAllPoints()
  frame.summary:SetPoint("TOPLEFT", 18, top)
end

local function footerText(net)
  local source = ns.Questie.StatusText()
  source = source and ("Data: " .. source .. " + places you visited. ")
    or "Data: places you visited (install QuestieDB for more). "
  local flights = net and net.knownFlights or 0
  if flights == 0 then
    return source .. "|cffffd200No flight paths known yet, so routes are on foot. Talk to any flight "
      .. "master once and routes will use your flight paths.|r"
  end
  return source .. string.format("%d known flight path%s. Boat and zeppelin docks are approximate.", flights,
    flights == 1 and "" or "s")
end

function Panel.Refresh()
  if not (frame and frame:IsShown()) then return end
  local page = currentPage()
  layout(page)

  local q = page.searchable and query or ""
  local results, err, net = page.Results(q)
  results = results or {}
  frame.summary:SetText(page.SummaryText(q) or "")
  for i, row in ipairs(frame.rows) do
    local r = results[i]
    row.result = r
    if r then
      row.title:SetText(r.title)
      row.sub:SetText(subtitle(r))
      local action = r.actions and r.actions[1]
      row.action:SetShown(action ~= nil)
      if action then row.action:SetText(action.label) end
      row:Show()
    else
      row:Hide()
    end
  end

  if err then
    frame.empty:SetText(err)
  elseif #results == 0 then
    frame.empty:SetText(page.EmptyText(q) or "")
  else
    frame.empty:SetText("")
  end
  frame.footer:SetText(footerText(net or ns.Network.Build()))
end

-- Selects a page by id (pages from ns.RegisterPage).
function Panel.SelectPage(id)
  for _, page in ipairs(sortedPages()) do
    if page.id == id and page ~= selectedPage then
      selectedPage = page
      query = ""
      if frame then frame.search:SetText("") end
    end
  end
  Panel.Refresh()
end

-- Selects a category on the Find page.
function Panel.Select(index)
  selectedCategory = index
  Panel.SelectPage("find")
end

-- Opens the panel on a page with a search, e.g. from /wf item <link>.
function Panel.Search(id, text)
  frame = frame or create()
  if not frame:IsShown() then frame:Show() end
  Panel.SelectPage(id)
  query = text or ""
  frame.search:SetText(query)
  Panel.Refresh()
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
