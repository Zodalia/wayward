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
      local zone = ns.Journey.StopZone(stop)
      GameTooltip:AddLine(i .. ". " .. (stop.text or stop.node.label or "?")
        .. (zone and ("  |cff9d9d9d(" .. zone .. ")|r") or ""), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click to start this journey", 0.5, 0.8, 0.7)
  elseif r.route then
    local route = ns.Router.WithZoneSteps(r.route)
    for i = 1, #route.steps do
      GameTooltip:AddLine(i .. ". " .. ns.Router.Describe(route, i), 1, 1, 1, true)
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

  ns.Skin.Button(row.action)
  ns.Skin.Text(row.title)
  ns.Skin.Text(row.sub)

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
  -- ButtonFrameTemplate is Blizzard's standard window (title bar, close button,
  -- inset), so UI suites that restyle Blizzard windows know it too.
  local f, templated = ns.Skin.CreateWindow("WayfinderPanel")
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
  ns.RestorePosition(f, "panelPos")
  tinsert(UISpecialFrames, "WayfinderPanel")

  local title = f.titleText
  if not title then
    title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
  end
  title:SetText("Wayfinder")
  ns.Skin.Text(title)
  ns.Skin.CloseButton(f.close)
  if templated then
    -- The tabs stand on the inset; the footer stays inside it.
    f.Inset:ClearAllPoints()
    f.Inset:SetPoint("TOPLEFT", 4, -62)
    f.Inset:SetPoint("BOTTOMRIGHT", -6, 4)
    ns.Skin.Inset(f.Inset)
  end

  -- Page tabs, bottom edge 62 below the top. Template tabs size themselves on
  -- show between the window's min/maxTabWidth.
  local pages = sortedPages()
  local tabWidth = math.min(math.floor((348 - 4 * (#pages - 1)) / math.max(#pages, 1)), 110)
  f.minTabWidth, f.maxTabWidth = tabWidth, tabWidth
  f.tabs = {}
  f.templateTabs = true
  local previous
  for i, page in ipairs(pages) do
    local b, tab = ns.Skin.CreateTab(f)
    f.templateTabs = f.templateTabs and tab
    b:SetID(i)
    b:SetWidth(tabWidth)
    if not tab then b:SetHeight(22) end
    b:SetText(page.label)
    if previous then b:SetPoint("LEFT", previous, "RIGHT", 4, 0) else b:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 18, -62) end
    b:SetScript("OnClick", function() Panel.SelectPage(page.id) end)
    ns.Skin.Tab(b)
    f.tabs[i] = { button = b, page = page }
    previous = b
  end
  f.numTabs = #pages -- for PanelTemplates_SetTab

  local searchTemplate
  f.search, searchTemplate = ns.Skin.CreateSearchBox(f)
  f.search:SetSize(338, 22)
  f.search:SetPoint("TOPLEFT", 24, -68)
  f.search:SetAutoFocus(false)
  -- Hook rather than replace the template's handler (clear button, hint).
  local onText = searchTemplate and f.search.HookScript or f.search.SetScript
  onText(f.search, "OnTextChanged", function(self, userInput)
    query = self:GetText() or ""
    self.hint:SetShown(query == "")
    -- The clear button empties the box without user input.
    if userInput or (searchTemplate and query == "") then scheduleSearch() end
  end)
  ns.Skin.EditBox(f.search)
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
    ns.Skin.Button(b)
    f.categoryButtons[i] = b
    previous = b
  end

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.summary:SetWidth(348)
  f.summary:SetJustifyH("LEFT")
  f.summary:SetWordWrap(true)

  f.rows = {}
  for i = 1, MAX_ROWS do f.rows[i] = createRow(f, i) end

  -- Scrolling: the mouse wheel anywhere on the panel, or these buttons.
  f.down = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.down:SetSize(22, 18)
  f.down:SetPoint("TOPRIGHT", f.rows[MAX_ROWS], "BOTTOMRIGHT", -4, -2)
  f.down:SetText("v")
  f.down:SetScript("OnClick", function() Panel.Scroll(-MAX_ROWS + 1) end)
  f.up = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.up:SetSize(22, 18)
  f.up:SetPoint("RIGHT", f.down, "LEFT", -2, 0)
  f.up:SetText("^")
  f.up:SetScript("OnClick", function() Panel.Scroll(MAX_ROWS - 1) end)
  ns.Skin.Button(f.up)
  ns.Skin.Button(f.down)
  f.position = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.position:SetPoint("RIGHT", f.up, "LEFT", -6, 0)
  ns.Skin.Text(f.position)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta) Panel.Scroll(delta) end)

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
  ns.Skin.Text(f.summary)
  ns.Skin.Text(f.empty)
  ns.Skin.Text(f.footer)

  hookLinks()
  f:SetScript("OnShow", function() Panel.Refresh() end)
  ns.Skin.Window(f)
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
  for i, tab in ipairs(frame.tabs) do
    local selected = tab.page == page
    if frame.templateTabs then
      if selected and PanelTemplates_SetTab then PanelTemplates_SetTab(frame, i) end
    elseif selected then
      tab.button:LockHighlight()
    else
      tab.button:UnlockHighlight()
    end
    ns.Skin.SetTabSelected(tab.button, selected)
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
  local here = ns.Geo.PlayerNode()
  local continent = here and ns.Geo.Continents()[here.instance]
  if continent and not ns.Harvest.FlightsKnownOn(continent) then
    return source .. string.format("|cffffd200Open any flight map in %s once so Wayfinder knows your flight "
      .. "paths here.|r", ns.MapName(continent))
  end
  return source .. string.format("%d known flight path%s. Boat and zeppelin docks are approximate.", flights,
    flights == 1 and "" or "s")
end

local offset, listKey = 0, nil

-- Draws the visible slice of the last results; scrolling only repaints.
local function paint()
  local results = frame.results or {}
  local maxOffset = math.max(0, #results - MAX_ROWS)
  if offset > maxOffset then offset = maxOffset end
  for i, row in ipairs(frame.rows) do
    local r = results[offset + i]
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
  local scrolls = #results > MAX_ROWS
  frame.up:SetShown(scrolls)
  frame.down:SetShown(scrolls)
  if scrolls then
    frame.up:SetEnabled(offset > 0)
    frame.down:SetEnabled(offset < maxOffset)
    frame.position:SetText(string.format("%d-%d of %d", offset + 1, math.min(offset + MAX_ROWS, #results), #results))
  else
    frame.position:SetText("")
  end
end

function Panel.Refresh()
  if not (frame and frame:IsShown()) then return end
  local page = currentPage()
  layout(page)

  local q = page.searchable and query or ""
  local results, err, net = page.Results(q)
  results = results or {}
  -- A new page, category or search starts at the top; a data refresh keeps your place.
  local key = page.id .. "|" .. selectedCategory .. "|" .. q
  if key ~= listKey then offset, listKey = 0, key end
  frame.results = results
  frame.summary:SetText(page.SummaryText(q) or "")
  paint()

  if err then
    frame.empty:SetText(err)
  elseif #results == 0 then
    frame.empty:SetText(page.EmptyText(q) or "")
  else
    frame.empty:SetText("")
  end
  frame.footer:SetText(footerText(net or ns.Network.Build()))
end

-- Moves the result list: positive goes up (towards the first result).
function Panel.Scroll(delta)
  if not (frame and frame:IsShown() and frame.results) then return end
  offset = math.max(0, offset - delta)
  paint()
end

-- The results currently on screen (for tests and other modules).
function Panel.VisibleResults()
  local out = {}
  for _, row in ipairs(frame and frame.rows or {}) do
    if row.result then out[#out + 1] = row.result end
  end
  return out
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
