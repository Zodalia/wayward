local _, ns = ...

-- The Wayfinder window. The main window shows the card page (For you) and
-- never changes size; the other pages (Quests, Vendors, Trainers, Dungeons,
-- Items) open in a side panel docked to its right, from icon tabs inside its
-- right edge.
--
-- Page contract (register with ns.RegisterPage(page) from any file that loads
-- before this one):
--   page.id, page.label        -- side tab tooltip / side panel title
--   page.icon                  -- side tab icon (optional)
--   page.order                 -- tab order, lowest first
--   page.layout = "cards"      -- shown in the main window as cards (UI/Cards.lua), with
--   page.width                 --   this window width; other pages are lists in the side panel
--   page.searchable            -- show the search box (shift-clicked links go in it too)
--   page.placeholder           -- search box hint (or page.Placeholder())
--   page.SummaryText(query)    -- line under the search box
--   page.EmptyText(query)      -- shown when there are no results
--   page.Results(query)        -- returns results, err, net
--   page.categories            -- optional { {label, provider}, ... } shown as buttons,
--   page.selected              --   and the selected one (see categoryPage below)
-- A result:
--   title, and either subtitle or zone (zone gets "· time · summary" appended),
--   goal + route (from ns.Router.Plan) or journey (from ns.Journey.Plan),
--   details = { {text, color, more}, ... } for the tooltip (cards leave out the
--     first, the ranking, and those with `more`),
--   place and stats = { {label, value}, ... } (up to 3) for cards: a "where" line
--     and labelled numbers in place of the subtitle,
--   actions = { {label, run = function(result) end} } (the first is shown as a button).

local Panel = {}
ns.Panel = Panel

local MAX_ROWS = 7
local MAIN_WIDTH = 730 -- when no card page says otherwise
local SIDE_WIDTH = 384
local HEIGHT = 530
local ROW_HEIGHT = 42
local MAX_DETAIL_LINES = 12
local SEARCH_DELAY = 0.3
local SIDE_TAB_SIZE = 32
-- The tab column inside the main window's right edge.
local TAB_COLUMN = SIDE_TAB_SIZE + 16
local TAB_ICONS = {
  quests = "Interface\\Icons\\INV_Misc_QuestionMark",
  vendors = "Interface\\Icons\\INV_Misc_Coin_02",
  trainers = "Interface\\Icons\\INV_Misc_Book_11",
  dungeons = "Interface\\Icons\\INV_Misc_Key_14",
  items = "Interface\\Icons\\INV_Misc_Bag_08",
}
local MAX_CATEGORIES = 4

local frame, side
local mainPage, sidePage = nil, nil
local query = ""

---------------------------------------------------------------- side pages

local function matches(r, q)
  if q == "" then return true end
  local text = ((r.title or "") .. " " .. (r.zone or "") .. " " .. (r.subtitle or "")):lower()
  return text:find(q:lower(), 1, true) ~= nil
end

-- A side page made of providers (same SummaryText/EmptyText/Results shape),
-- one per category button. A searchable provider gets the search text; for
-- the others the box filters their results.
local function categoryPage(page)
  page.searchable = true
  page.selected = 1
  local function current() return page.categories[page.selected].provider end
  function page.Placeholder() return current().placeholder or "Filter these results" end
  function page.SummaryText(q) return current().SummaryText(q) end
  function page.EmptyText(q) return current().EmptyText(q) end
  function page.Results(q)
    local provider = current()
    if provider.searchable then return provider.Results(q) end
    local results, err, net = provider.Results()
    if q == "" then return results, err, net end
    local filtered = {}
    for _, r in ipairs(results or {}) do
      if matches(r, q) then filtered[#filtered + 1] = r end
    end
    return filtered, err, net
  end
  ns.RegisterPage(page)
end

categoryPage({ id = "quests", label = "Quests", order = 20, categories = {
  { label = "Journal", provider = ns.QuestsPage },
  { label = "Hubs", provider = ns.QuestHubs },
} })
categoryPage({ id = "vendors", label = "Vendors", order = 30, categories = {
  { label = "Vendors", provider = ns.Vendors },
} })
categoryPage({ id = "trainers", label = "Trainers", order = 40, categories = {
  { label = "Class", provider = ns.Trainers },
  { label = "Weapons", provider = ns.WeaponMasters },
} })
categoryPage({ id = "dungeons", label = "Dungeons", order = 50, categories = {
  { label = "Dungeons", provider = ns.Dungeons },
} })

---------------------------------------------------------------- pages

local function sortedPages()
  table.sort(ns.pages, function(a, b)
    if (a.order or 100) ~= (b.order or 100) then return (a.order or 100) < (b.order or 100) end
    return a.label < b.label
  end)
  return ns.pages
end

local function isCards(page)
  return page.layout == "cards"
end

-- The card page the main window opens on: the first one by order.
local function defaultMain()
  for _, page in ipairs(sortedPages()) do
    if isCards(page) then return page end
  end
  return nil
end

local function listPages()
  local out = {}
  for _, page in ipairs(sortedPages()) do
    if not isCards(page) then out[#out + 1] = page end
  end
  return out
end

---------------------------------------------------------------- results

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

-- The tooltip for a result (rows and cards share it).
function Panel.ShowTooltip(owner, r)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(r.title)
  addDetails(r)
  if r.journey then
    for i, stop in ipairs(r.journey.stops) do
      local zone = ns.Journey.StopZone(stop)
      GameTooltip:AddLine(i .. ". " .. (stop.text or stop.node.label or "?")
        .. (zone and ("  |cff9d9d9d(" .. zone .. ")|r") or ""), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click to start this journey", 0.5, 0.8, 0.7)
    if ns.Nav.active then GameTooltip:AddLine("Shift-click to add it to your trip", 0.5, 0.8, 0.7) end
  elseif r.route then
    local route = ns.Router.WithZoneSteps(r.route)
    for i = 1, #route.steps do
      GameTooltip:AddLine(i .. ". " .. ns.Router.Describe(route, i), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click for directions", 0.5, 0.8, 0.7)
    if ns.Nav.active then GameTooltip:AddLine("Shift-click to add it to your trip", 0.5, 0.8, 0.7) end
  end
  GameTooltip:Show()
end

-- What clicking a result does (rows and cards): start its directions or
-- journey; with shift held during a trip, add it to the trip instead.
function Panel.Activate(r)
  if ns.Nav.active and IsShiftKeyDown and IsShiftKeyDown() then
    local stops = ns.Nav.StopsFor(r)
    if #stops > 0 then ns.Nav.AddToTrip(stops, r.title) end
    Panel.Refresh()
    return
  end
  if r.journey then
    ns.Nav.StartJourney(r.journey)
    frame:Hide()
  elseif r.route then
    ns.Nav.Start(r.title, r.goal, r.route)
    frame:Hide()
  end
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

  row:SetScript("OnEnter", function(self) if self.result then Panel.ShowTooltip(self, self.result) end end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self) if self.result then Panel.Activate(self.result) end end)
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
  if not (side and side:IsVisible() and side.search:HasFocus() and type(text) == "string") then return end
  local now = GetTime and GetTime() or 0
  if text == lastLink and lastLinkTime == now then return end
  lastLink, lastLinkTime = text, now
  side.search:Insert(text)
end

local function hookLinks()
  if type(ChatEdit_InsertLink) == "function" then hooksecurefunc("ChatEdit_InsertLink", insertLink) end
  if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
    hooksecurefunc(ChatFrameUtil, "InsertLink", insertLink)
  end
end

---------------------------------------------------------------- footer

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

---------------------------------------------------------------- side panel

local function createSide(parent)
  local s, templated = ns.Skin.CreateWindow("WayfinderSidePanel")
  s:SetParent(parent)
  s:SetSize(SIDE_WIDTH, HEIGHT)
  -- Flush against the main window; the side tabs sit inside it.
  s:SetPoint("TOPLEFT", parent, "TOPRIGHT", 0, 0)
  s:EnableMouse(true)

  s.title = s.titleText
  if not s.title then
    s.title = s:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    s.title:SetPoint("TOPLEFT", 18, -16)
  end
  ns.Skin.Text(s.title)
  ns.Skin.CloseButton(s.close)
  s.close:SetScript("OnClick", function() Panel.CloseSide() end)
  if templated then
    s.Inset:ClearAllPoints()
    s.Inset:SetPoint("TOPLEFT", 4, -26)
    s.Inset:SetPoint("BOTTOMRIGHT", -6, 4)
    ns.Skin.Inset(s.Inset)
  end

  local searchTemplate
  s.search, searchTemplate = ns.Skin.CreateSearchBox(s)
  s.search:SetSize(338, 22)
  s.search:SetPoint("TOPLEFT", 24, -34)
  s.search:SetAutoFocus(false)
  -- Hook rather than replace the template's handler (clear button, hint).
  local onText = searchTemplate and s.search.HookScript or s.search.SetScript
  onText(s.search, "OnTextChanged", function(self, userInput)
    query = self:GetText() or ""
    self.hint:SetShown(query == "")
    -- The clear button empties the box without user input.
    if userInput or (searchTemplate and query == "") then scheduleSearch() end
  end)
  ns.Skin.EditBox(s.search)
  s.search:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    Panel.Refresh()
  end)
  s.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  -- Category buttons, labelled for the page shown (see refreshSide).
  s.categoryButtons = {}
  for i = 1, MAX_CATEGORIES do
    local b = CreateFrame("Button", nil, s, "UIPanelButtonTemplate")
    b:SetSize(84, 22)
    b:SetScript("OnClick", function() Panel.Select(i) end)
    ns.Skin.Button(b)
    b:Hide()
    s.categoryButtons[i] = b
  end

  s.summary = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  s.summary:SetWidth(SIDE_WIDTH - 36)
  s.summary:SetJustifyH("LEFT")
  s.summary:SetWordWrap(true)

  s.rows = {}
  for i = 1, MAX_ROWS do s.rows[i] = createRow(s, i) end

  -- Scrolling: the mouse wheel anywhere on the side panel, or these buttons.
  s.down = CreateFrame("Button", nil, s, "UIPanelButtonTemplate")
  s.down:SetSize(22, 18)
  s.down:SetPoint("TOPRIGHT", s.rows[MAX_ROWS], "BOTTOMRIGHT", -4, -2)
  s.down:SetText("v")
  s.down:SetScript("OnClick", function() Panel.Scroll(-MAX_ROWS + 1) end)
  s.up = CreateFrame("Button", nil, s, "UIPanelButtonTemplate")
  s.up:SetSize(22, 18)
  s.up:SetPoint("RIGHT", s.down, "LEFT", -2, 0)
  s.up:SetText("^")
  s.up:SetScript("OnClick", function() Panel.Scroll(MAX_ROWS - 1) end)
  ns.Skin.Button(s.up)
  ns.Skin.Button(s.down)
  s.position = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  s.position:SetPoint("RIGHT", s.up, "LEFT", -6, 0)
  ns.Skin.Text(s.position)
  s:EnableMouseWheel(true)
  s:SetScript("OnMouseWheel", function(_, delta) Panel.Scroll(delta) end)

  s.empty = s:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  s.empty:SetPoint("TOPLEFT", s.summary, "BOTTOMLEFT", 0, -16)
  s.empty:SetWidth(SIDE_WIDTH - 36)
  s.empty:SetJustifyH("LEFT")
  s.empty:SetWordWrap(true)
  ns.Skin.Text(s.summary)
  ns.Skin.Text(s.empty)

  ns.Skin.Window(s)
  s:Hide()
  return s
end

---------------------------------------------------------------- main window

local function create()
  -- ButtonFrameTemplate is Blizzard's standard window (title bar, close button,
  -- inset), so UI suites that restyle Blizzard windows know it too.
  local f, templated = ns.Skin.CreateWindow("WayfinderPanel")
  mainPage = mainPage or defaultMain()
  local width = mainPage and mainPage.width or MAIN_WIDTH
  f:SetSize(width + TAB_COLUMN, HEIGHT)
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
    -- The footer stays inside the inset.
    f.Inset:ClearAllPoints()
    f.Inset:SetPoint("TOPLEFT", 4, -26)
    f.Inset:SetPoint("BOTTOMRIGHT", -6, 4)
    ns.Skin.Inset(f.Inset)
  end

  -- Side tabs in a column inside the right edge for the list pages (square
  -- icons in an action-button border); each opens or closes the side panel.
  f.tabs = {}
  for i, page in ipairs(listPages()) do
    local b = CreateFrame("CheckButton", nil, f)
    b:SetSize(SIDE_TAB_SIZE, SIDE_TAB_SIZE)
    b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -40 - (i - 1) * (SIDE_TAB_SIZE + 12))
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetSize(SIDE_TAB_SIZE * 64 / 36, SIDE_TAB_SIZE * 64 / 36)
    border:SetPoint("CENTER")
    b:SetNormalTexture(page.icon or TAB_ICONS[page.id] or "Interface\\Icons\\INV_Misc_Map_01")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    -- SetCheckedTexture takes no blend mode; without ADD it covers the icon.
    b:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
    local checked = b:GetCheckedTexture()
    if checked then checked:SetBlendMode("ADD") end
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(page.label)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function()
      if sidePage == page and side:IsShown() then Panel.CloseSide() else Panel.SelectPage(page.id) end
    end)
    f.tabs[i] = { button = b, page = page }
  end

  f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.summary:SetPoint("TOPLEFT", 18, -34)
  f.summary:SetWidth(width - 36)
  f.summary:SetJustifyH("LEFT")
  f.summary:SetWordWrap(true)

  f.cards = ns.Cards.Create(f)
  f.cards:SetPoint("TOPLEFT", f.summary, "BOTTOMLEFT", 0, -12)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta) ns.Cards.Step(delta) end)

  f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.footer:SetPoint("BOTTOMLEFT", 18, 16)
  f.footer:SetWidth(width - 36)
  f.footer:SetJustifyH("LEFT")
  f.footer:SetWordWrap(true)
  ns.Skin.Text(f.summary)
  ns.Skin.Text(f.footer)

  side = createSide(f)
  hookLinks()
  f:SetScript("OnShow", function() Panel.Refresh() end)
  ns.Skin.Window(f)
  -- New frames start shown; hide so the first Toggle opens rather than closes.
  f:Hide()
  return f
end

---------------------------------------------------------------- refresh

local checkedPage

local function markTabs()
  checkedPage = side:IsShown() and sidePage and sidePage.id or nil
  for _, tab in ipairs(frame.tabs) do
    tab.button:SetChecked(checkedPage == tab.page.id)
  end
end

-- The list page whose side tab is selected, or nil (for tests).
function Panel.SelectedTab()
  return checkedPage
end

local offset, listKey = 0, nil

-- Draws the visible slice of the last results; scrolling only repaints.
local function paint()
  local results = side.results or {}
  local maxOffset = math.max(0, #results - MAX_ROWS)
  if offset > maxOffset then offset = maxOffset end
  for i, row in ipairs(side.rows) do
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
  side.up:SetShown(scrolls)
  side.down:SetShown(scrolls)
  if scrolls then
    side.up:SetEnabled(offset > 0)
    side.down:SetEnabled(offset < maxOffset)
    side.position:SetText(string.format("%d-%d of %d", offset + 1, math.min(offset + MAX_ROWS, #results), #results))
  else
    side.position:SetText("")
  end
end

local cardKey

local function refreshMain()
  if not mainPage then return nil end
  local results, err, net = mainPage.Results("")
  results = results or {}
  local fresh = mainPage.id ~= cardKey
  cardKey = mainPage.id
  frame.summary:SetText(mainPage.SummaryText("") or "")
  ns.Cards.Show(results, err or (#results == 0 and mainPage.EmptyText("")) or "", fresh)
  return net
end

local function refreshSide()
  local page = sidePage
  side.title:SetText(page.label)
  if page.searchable then side.search:Show() else side.search:Hide() end
  side.search.hint:SetText(page.Placeholder and page.Placeholder() or page.placeholder or "Search")
  -- One category is just the page: no buttons.
  local categories = page.categories and #page.categories > 1 and page.categories or {}
  local showCategories = #categories > 0
  local width = showCategories and math.floor((SIDE_WIDTH - 36 - 4 * (#categories - 1)) / #categories) or 0
  for i, b in ipairs(side.categoryButtons) do
    local cat = categories[i]
    b:SetShown(cat ~= nil)
    if cat then
      b:SetText(cat.label)
      b:SetWidth(width)
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", 18 + (i - 1) * (width + 4), -62)
      if i == page.selected then b:LockHighlight() else b:UnlockHighlight() end
    end
  end
  local top = page.searchable and -62 or -34
  if showCategories then top = top - 28 end
  side.summary:ClearAllPoints()
  side.summary:SetPoint("TOPLEFT", 18, top)

  local q = page.searchable and query or ""
  local results, err, net = page.Results(q)
  results = results or {}
  -- A new page, category or search starts at the top; a data refresh keeps your place.
  local key = page.id .. "|" .. (page.selected or 1) .. "|" .. q
  if key ~= listKey then offset, listKey = 0, key end
  side.results = results
  side.summary:SetText(page.SummaryText(q) or "")
  paint()
  if err then
    side.empty:SetText(err)
  elseif #results == 0 then
    side.empty:SetText(page.EmptyText(q) or "")
  else
    side.empty:SetText("")
  end
  return net
end

function Panel.Refresh()
  if not (frame and frame:IsShown()) then return end
  local net = refreshMain()
  if side:IsShown() and sidePage then net = refreshSide() or net end
  markTabs()
  frame.footer:SetText(footerText(net or ns.Network.Build()))
end

-- Moves the side panel's list (positive goes up, towards the first result),
-- or steps through the cards when the side panel is closed.
function Panel.Scroll(delta)
  if not (frame and frame:IsShown()) then return end
  if not side:IsShown() then return ns.Cards.Step(delta) end
  offset = math.max(0, offset - delta)
  paint()
end

-- The side panel's results currently on screen (for tests and other modules).
function Panel.VisibleResults()
  local out = {}
  if not (side and side:IsShown()) then return out end
  for _, row in ipairs(side.rows) do
    if row.result then out[#out + 1] = row.result end
  end
  return out
end

function Panel.CloseSide()
  if side then side:Hide() end
  Panel.Refresh()
end

-- Selects a page by id: a card page shows in the main window (and closes the
-- side panel), any other page opens in the side panel, on `category` (index)
-- when given.
function Panel.SelectPage(id, category)
  frame = frame or create()
  for _, page in ipairs(sortedPages()) do
    if page.id == id then
      if category and page.categories and page.categories[category] then page.selected = category end
      if isCards(page) then
        mainPage = page
        side:Hide()
      else
        if page ~= sidePage then
          sidePage = page
          query = ""
          side.search:SetText("")
        end
        side:Show()
      end
    end
  end
  Panel.Refresh()
end

-- Selects a category on the side panel's page.
function Panel.Select(index)
  if sidePage then Panel.SelectPage(sidePage.id, index) end
end

-- Opens the window on a page with a search, e.g. from /wf item <link>; on a
-- page with categories, the first one (Quests: your journal, which searches).
function Panel.Search(id, text)
  frame = frame or create()
  if not frame:IsShown() then frame:Show() end
  Panel.SelectPage(id, 1)
  if side:IsShown() then
    query = text or ""
    side.search:SetText(query)
  end
  Panel.Refresh()
end

function Panel.IsShown()
  return frame ~= nil and frame:IsShown()
end

function Panel.SideShown()
  return side ~= nil and side:IsShown()
end

function Panel.Toggle()
  frame = frame or create()
  if frame:IsShown() then frame:Hide() else frame:Show() end
end

ns.Listen("DATA_CHANGED", function() Panel.Refresh() end)
ns.On("ZONE_CHANGED_NEW_AREA", function() Panel.Refresh() end)
