local _, ns = ...

-- Suggestion cards in the style of modern WoW's Adventure Guide ("Suggested
-- Content"): one large featured card on the left, two smaller ones stacked on
-- the right, arrows under them to step through the rest. Each card's "?"
-- button opens its breakdown (why, then every stop and step) where the side
-- panel docks, so the cards stay in view. Sizes, fonts and colours follow
-- Blizzard's own frame (Blizzard_EncounterJournal, AdventureJournal templates).
-- The Adventure Guide isn't in Forever, so its art is used only when the
-- client has those atlases; otherwise a plain parchment look.
--
-- A page opts in with `layout = "cards"` (and `width`); results are the usual
-- panel results, plus optional `icon` (file) / `iconCoords` and `kind`.

local Cards = {}
ns.Cards = Cards

local LARGE_W, LARGE_H = 335, 365
local SMALL_W, SMALL_H = 344, 175
local GAP = 11
local WIDTH = LARGE_W + 12 + SMALL_W
local NAV_HEIGHT = 34      -- the arrows under the cards
local BREAKDOWN_WIDTH = 384 -- the side panel's
local BREAKDOWN_ROWS = 40   -- lines drawn at most; as many as fit show
-- Ink on parchment, darkest for titles.
local TITLE_COLOR = { 0.20, 0.10, 0.02 }
local TEXT_COLOR = { 0.22, 0.14, 0.06 }
local DETAIL_COLOR = { 0.28, 0.19, 0.09 }
local PARCHMENT = { 0.86, 0.78, 0.6, 0.97 }
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Map_01"

local function hasAtlas(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- Friz Quadrata in ink colours, no shadow or outline (with them, everything on
-- parchment looks bold). Morpheus was tried for titles: in Forever it's all
-- decorative small caps, hard to read. The template is the fallback if the
-- file can't be set. (The Adventure Guide's own fonts are missing or broken
-- in Forever: text with them showed nothing.)
local FONT = "Fonts\\FRIZQT__.TTF"

local function text(parent, template, size, c)
  local fs = parent:CreateFontString(nil, "OVERLAY", template)
  local ok, set = pcall(fs.SetFont, fs, FONT, size, "")
  if not ok or set == false then fs:SetFontObject(template) end
  fs:SetShadowOffset(0, 0)
  fs:SetTextColor(c[1], c[2], c[3])
  return fs
end

-- Card background: the Adventure Guide pane, or parchment.
local function background(card, atlas)
  local bg = card:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  if hasAtlas(atlas) then
    bg:SetAtlas(atlas)
  else
    bg:SetColorTexture(PARCHMENT[1], PARCHMENT[2], PARCHMENT[3], PARCHMENT[4])
    local edge = card:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0.35, 0.25, 0.12, 0.9)
  end
end

-- The round icon with its ring. Icons are masked round; a masked texture
-- can't take tex coords, so icons cut from a sheet (class circles, already
-- round) use a second, unmasked texture in the same place.
local function icon(card, size, ringSize)
  card.icon = card:CreateTexture(nil, "ARTWORK")
  card.icon:SetSize(size, size)
  if card.icon.SetMask then pcall(card.icon.SetMask, card.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  card.sheetIcon = card:CreateTexture(nil, "ARTWORK")
  card.sheetIcon:SetSize(size, size)
  card.sheetIcon:SetPoint("CENTER", card.icon)
  card.sheetIcon:Hide()
  card.ring = card:CreateTexture(nil, "OVERLAY")
  card.ring:SetSize(ringSize, ringSize)
  card.ring:SetPoint("CENTER", card.icon)
  if hasAtlas("adventureguide-ring") then
    card.ring:SetAtlas("adventureguide-ring")
  else
    card.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    card.ring:SetSize(ringSize * 0.75, ringSize * 0.75)
    card.ring:SetPoint("CENTER", card.icon, "CENTER", 10, -10)
  end
end

local function button(card, width, height, large)
  local b = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
  b:SetSize(width, height)
  if large and GameFontNormalLarge and b.SetNormalFontObject then
    b:SetNormalFontObject(GameFontNormalLarge)
    b:SetHighlightFontObject(GameFontNormalLarge)
  end
  b:SetScript("OnClick", function() if card.result then ns.Panel.Activate(card.result) end end)
  return b
end

-- Small text-style button for a result's own action ("Flight only").
local function extra(card)
  local b = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
  b:SetSize(96, 20)
  b:Hide()
  b:SetScript("OnClick", function()
    local r = card.result
    local action = r and r.actions and r.actions[1]
    if action then
      action.run(r)
      ns.Panel.Refresh()
    end
  end)
  return b
end

-- The "?" button in a card's top-right corner: its breakdown.
local function queryButton(card)
  local b = CreateFrame("Button", nil, card)
  b:SetSize(22, 22)
  b:SetPoint("TOPRIGHT", -14, -12)
  b:SetNormalTexture("Interface\\Icons\\INV_Misc_QuestionMark")
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  border:SetSize(22 * 64 / 36, 22 * 64 / 36)
  border:SetPoint("CENTER")
  b:SetScript("OnClick", function() if card.result then Cards.ShowBreakdown(card.result) end end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Show every step")
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  card.query = b
end

local function hover(card)
  card:EnableMouse(true)
  card:SetScript("OnEnter", function(self) if self.result then ns.Panel.ShowTooltip(self, self.result) end end)
  card:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Shift-click adds to the trip, like the panel's rows.
  card:SetScript("OnMouseUp", function(self)
    if self.result and IsShiftKeyDown and IsShiftKeyDown() then ns.Panel.Activate(self.result) end
  end)
end

local function largeCard(parent)
  local card = CreateFrame("Frame", nil, parent)
  card:SetSize(LARGE_W, LARGE_H)
  background(card, "adventureguide-pane-large")
  icon(card, 64, 94)
  card.icon:SetPoint("TOPLEFT", (LARGE_W - 64) / 2, -18)

  -- Title and subtitle centred under the icon; the details below read as a
  -- left-aligned paragraph.
  card.title = text(card, "GameFontNormalHuge", 18, TITLE_COLOR)
  card.title:SetPoint("TOP", card.icon, "BOTTOM", 0, -14)
  card.title:SetWidth(264)
  card.title:SetJustifyH("CENTER")
  if card.title.SetMaxLines then card.title:SetMaxLines(2) end

  card.text = text(card, "GameFontHighlight", 12, TEXT_COLOR)
  card.text:SetPoint("TOP", card.title, "BOTTOM", 0, -6)
  card.text:SetWidth(264)
  card.text:SetJustifyH("CENTER")
  card.text:SetSpacing(2)

  card.detail = text(card, "GameFontHighlightSmall", 11, DETAIL_COLOR)
  card.detail:SetPoint("TOP", card.text, "BOTTOM", 0, -12)
  card.detail:SetWidth(250)
  card.detail:SetJustifyH("LEFT")
  card.detail:SetSpacing(3)
  if card.detail.SetMaxLines then card.detail:SetMaxLines(9) end

  card.button = button(card, 116, 32, true)
  card.button:SetPoint("BOTTOM", 0, 22)
  card.extra = extra(card)
  card.extra:SetPoint("LEFT", card.button, "RIGHT", 6, 0)
  queryButton(card)
  hover(card)
  return card
end

local function smallCard(parent)
  local card = CreateFrame("Frame", nil, parent)
  card:SetSize(SMALL_W, SMALL_H)
  background(card, "adventureguide-pane-small")
  icon(card, 64, 94)
  card.icon:SetPoint("TOPLEFT", -10, -2)

  card.title = text(card, "GameFontNormalLarge", 14, TITLE_COLOR)
  card.title:SetPoint("TOPLEFT", 72, -16)
  card.title:SetWidth(222)
  card.title:SetJustifyH("LEFT")
  card.title:SetWordWrap(false)

  card.text = text(card, "GameFontHighlightSmall", 11, TEXT_COLOR)
  card.text:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -6)
  card.text:SetWidth(256)
  card.text:SetJustifyH("LEFT")
  card.text:SetWordWrap(true)
  card.text:SetSpacing(2)
  if card.text.SetMaxLines then card.text:SetMaxLines(2) end

  card.detail = text(card, "GameFontHighlightSmall", 10, DETAIL_COLOR)
  card.detail:SetPoint("TOPLEFT", card.text, "BOTTOMLEFT", 0, -6)
  card.detail:SetWidth(256)
  card.detail:SetJustifyH("LEFT")
  card.detail:SetSpacing(2)
  if card.detail.SetMaxLines then card.detail:SetMaxLines(4) end

  card.button = button(card, 116, 24)
  card.button:SetPoint("BOTTOMLEFT", 70, 14)
  card.extra = extra(card)
  card.extra:SetPoint("LEFT", card.button, "RIGHT", 6, 0)
  queryButton(card)
  hover(card)
  return card
end

---------------------------------------------------------------- view

local view
local results, offset = {}, 0

local function pageButton(parent, direction, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(32, 32)
  local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. direction .. "Page-"
  b:SetNormalTexture(base .. "Up")
  b:SetPushedTexture(base .. "Down")
  b:SetDisabledTexture(base .. "Disabled")
  b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  b:SetScript("OnClick", onClick)
  return b
end

-- The breakdown: a window docked to the right of the main window, where the
-- side panel goes (they replace each other), styled like it. A result's why
-- and every stop and step, with its button to go.
local function createBreakdown(main)
  local b, templated = ns.Skin.CreateWindow("WayfinderBreakdown")
  b:SetParent(main)
  b:SetWidth(BREAKDOWN_WIDTH)
  b:SetPoint("TOPLEFT", main, "TOPRIGHT", 0, 0)
  b:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 0, 0)
  b:EnableMouse(true)
  b.titleBar = b.titleText
  if not b.titleBar then
    b.titleBar = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.titleBar:SetPoint("TOPLEFT", 18, -16)
  end
  b.titleBar:SetText("Breakdown")
  ns.Skin.Text(b.titleBar)
  ns.Skin.CloseButton(b.close)
  b.close:SetScript("OnClick", function() Cards.HideBreakdown() end)
  if templated then
    b.Inset:ClearAllPoints()
    b.Inset:SetPoint("TOPLEFT", 4, -26)
    b.Inset:SetPoint("BOTTOMRIGHT", -6, 4)
    ns.Skin.Inset(b.Inset)
  end

  b.title = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  b.title:SetPoint("TOPLEFT", 18, -38)
  b.title:SetPoint("RIGHT", -18, 0)
  b.title:SetJustifyH("LEFT")
  b.title:SetWordWrap(true)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  b.text:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -4)
  b.text:SetPoint("RIGHT", -18, 0)
  b.text:SetJustifyH("LEFT")
  b.text:SetWordWrap(true)
  ns.Skin.Text(b.title)
  ns.Skin.Text(b.text)

  -- Lines wrap, so they're stacked as they are drawn (see paintBreakdown).
  b.rows = {}
  for i = 1, BREAKDOWN_ROWS do
    local row = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row:SetWidth(BREAKDOWN_WIDTH - 40)
    row:SetJustifyH("LEFT")
    row:SetWordWrap(true)
    ns.Skin.Text(row)
    b.rows[i] = row
  end

  b.button = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
  b.button:SetSize(116, 24)
  b.button:SetPoint("BOTTOMRIGHT", -18, 14)
  b.button:SetScript("OnClick", function()
    local r = b.result
    Cards.HideBreakdown()
    if r then ns.Panel.Activate(r) end
  end)
  ns.Skin.Button(b.button)
  b.position = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.position:SetPoint("BOTTOMLEFT", 18, 20)
  ns.Skin.Text(b.position)
  b:EnableMouseWheel(true)
  b:SetScript("OnMouseWheel", function(_, delta) Cards.ScrollBreakdown(delta) end)
  ns.Skin.Window(b)
  b:Hide()
  return b
end

function Cards.Create(parent)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(WIDTH, LARGE_H + NAV_HEIGHT)
  holder.large = largeCard(holder)
  holder.large:SetPoint("TOPLEFT", 0, 0)
  holder.small = { smallCard(holder), smallCard(holder) }
  holder.small[1]:SetPoint("TOPLEFT", holder.large, "TOPRIGHT", 12, -4)
  holder.small[2]:SetPoint("TOPLEFT", holder.small[1], "BOTTOMLEFT", 0, -GAP)

  -- Under the cards: back, "2 of 7", forward.
  holder.position = text(holder, "GameFontHighlightSmall", 11, { 0.85, 0.8, 0.7 })
  holder.position:SetPoint("TOP", holder.large, "BOTTOM", (WIDTH - LARGE_W) / 2, -11)
  holder.prev = pageButton(holder, "Prev", function() Cards.Step(1) end)
  holder.prev:SetPoint("RIGHT", holder.position, "LEFT", -10, 0)
  holder.next = pageButton(holder, "Next", function() Cards.Step(-1) end)
  holder.next:SetPoint("LEFT", holder.position, "RIGHT", 10, 0)

  holder.empty = holder:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  holder.empty:SetPoint("TOPLEFT", 0, -8)
  holder.empty:SetWidth(WIDTH)
  holder.empty:SetJustifyH("LEFT")
  holder.breakdown = createBreakdown(parent)
  view = holder
  return holder
end

local function plain(text)
  return ((text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function fill(card, r, large)
  card.result = r
  if not r then
    card:Hide()
    return
  end
  card:Show()
  if r.iconCoords then
    card.sheetIcon:SetTexture(r.icon)
    card.sheetIcon:SetTexCoord((unpack or table.unpack)(r.iconCoords))
    card.sheetIcon:Show()
    card.icon:Hide()
  else
    card.icon:SetTexture(r.icon or DEFAULT_ICON)
    card.icon:Show()
    card.sheetIcon:Hide()
  end
  -- "Run The Stockade  ·  level 23": the level reads better in the subtitle.
  local title, level = (r.title or ""):match("^(.-)%s+·%s+(level %d+)$")
  card.title:SetText(title or r.title)
  local subtitle = plain(r.subtitle)
  if level then subtitle = level:gsub("^l", "L") .. "  ·  " .. subtitle end
  card.text:SetText(subtitle)
  -- The why (details after the ranking line, without those marked `more`);
  -- the breakdown has the rest.
  local lines, room = {}, large and 9 or 4
  for i = 2, #(r.details or {}) do
    if #lines >= room then break end
    if not r.details[i].more then lines[#lines + 1] = plain(r.details[i].text) end
  end
  card.detail:SetText(table.concat(lines, "\n"))
  card.button:SetText(r.journey and "Start trip" or "Go")
  card.button:SetEnabled(r.journey ~= nil or r.route ~= nil)
  local action = r.actions and r.actions[1]
  card.extra:SetShown(action ~= nil)
  if action then card.extra:SetText(action.label) end
  if large then
    -- Side by side when there are two buttons.
    card.button:ClearAllPoints()
    card.button:SetPoint("BOTTOM", action and -51 or 0, 22)
  end
end

local reported

local function safeFill(card, r, large)
  local ok, err = pcall(fill, card, r, large)
  if not ok and not reported then
    reported = true
    -- In chat too: Lua errors are often switched off.
    ns.print("couldn't draw a suggestion card: " .. tostring(err))
    geterrorhandler()(err)
  end
end

local function paint()
  if not view then return end
  local maxOffset = math.max(0, #results - 1)
  if offset > maxOffset then offset = maxOffset end
  safeFill(view.large, results[offset + 1], true)
  safeFill(view.small[1], results[offset + 2])
  safeFill(view.small[2], results[offset + 3])
  local several = #results > 1
  view.prev:SetShown(several)
  view.next:SetShown(several)
  view.prev:SetEnabled(offset > 0)
  view.next:SetEnabled(offset < maxOffset)
  view.position:SetText(several and string.format("%d of %d", offset + 1, #results) or "")
  view.empty:SetShown(#results == 0)
end

---------------------------------------------------------------- breakdown

local function rowText(text, indent) return (indent and "      " or "") .. plain(text) end

-- A result's breakdown, top to bottom: { {text, kind} } with kind "why" (its
-- details), "stop" (a trip's stops, numbered), "step" (travel, with its
-- time) or "note".
function Cards.Breakdown(r)
  local out = {}
  for _, line in ipairs(r.details or {}) do out[#out + 1] = { rowText(line.text), "why" } end
  local function travel(route, i)
    local step = route.steps[i]
    return { rowText(ns.Router.Describe(route, i, true) .. "  ·  " .. ns.FormatDuration(step.seconds or 0), true), "step" }
  end
  if r.journey then
    local route = ns.Router.WithZoneSteps({ steps = r.journey.steps, seconds = r.journey.seconds })
    -- Each stop, then how you get there.
    local number, leg = 0, {}
    for i, step in ipairs(route.steps) do
      leg[#leg + 1] = travel(route, i)
      if step.stop then
        number = number + 1
        local zone = ns.Journey.StopZone(step.stop)
        out[#out + 1] = { string.format("%d. %s%s", number, plain(step.stop.text or step.stop.node.label or "?"),
          zone and ("  (" .. zone .. ")") or ""), "stop" }
        for _, line in ipairs(leg) do out[#out + 1] = line end
        leg = {}
      end
    end
    out[#out + 1] = { string.format("%d stops, %s in all", number, ns.FormatDuration(r.journey.seconds)), "note" }
  elseif r.route then
    local route = ns.Router.WithZoneSteps(r.route)
    for i = 1, #route.steps do out[#out + 1] = travel(route, i) end
    if #route.steps == 0 then out[#out + 1] = { "You're already there.", "note" } end
    out[#out + 1] = { ns.FormatDuration(r.route.seconds) .. " in all", "note" }
  else
    out[#out + 1] = { "No route found from here.", "note" }
  end
  return out
end

-- On the dark window: the why in grey, stops gold, steps white.
local KIND_COLOR = { why = { 0.75, 0.75, 0.75 }, stop = { 1, 0.82, 0 }, step = { 1, 1, 1 }, note = { 0.6, 0.6, 0.6 } }
local BREAKDOWN_TOP_GAP = 12
local BREAKDOWN_BOTTOM = 48 -- room for the button
local breakdownOffset = 0

-- Lines from the scroll offset, each under the last, while they fit.
local function paintBreakdown()
  local b = view.breakdown
  local lines = b.lines or {}
  if breakdownOffset > math.max(0, #lines - 1) then breakdownOffset = math.max(0, #lines - 1) end
  local top = b:GetTop() and b.text:GetBottom() and (b:GetTop() - b.text:GetBottom()) or 80
  local room = (b:GetHeight() or 530) - top - BREAKDOWN_TOP_GAP - BREAKDOWN_BOTTOM
  local used, last, shown = 0, nil, 0
  for i, row in ipairs(b.rows) do
    local line = lines[breakdownOffset + i]
    row:ClearAllPoints()
    if line and used < room then
      row:SetText(line[1])
      local c = KIND_COLOR[line[2]] or KIND_COLOR.step
      row:SetTextColor(c[1], c[2], c[3])
      if last then
        row:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, line[2] == "stop" and -6 or -2)
      else
        row:SetPoint("TOPLEFT", b.text, "BOTTOMLEFT", 2, -BREAKDOWN_TOP_GAP)
      end
      used = used + (row:GetStringHeight() or 12) + (line[2] == "stop" and 6 or 2)
      if used > room and last then
        row:SetText("")
        row:Hide()
      else
        row:Show()
        shown = shown + 1
        last = row
      end
    else
      row:SetText("")
      row:Hide()
    end
  end
  local more = breakdownOffset > 0 or breakdownOffset + shown < #lines
  b.position:SetText(more and string.format("lines %d-%d of %d  ·  scroll for more", breakdownOffset + 1,
    breakdownOffset + shown, #lines) or "")
end

function Cards.ShowBreakdown(r)
  if not view then return end
  GameTooltip:Hide()
  -- It docks where the side panel goes.
  if ns.Panel.SideShown() then ns.Panel.CloseSide() end
  local b = view.breakdown
  b.result = r
  b.lines = Cards.Breakdown(r)
  breakdownOffset = 0
  local title, level = (r.title or ""):match("^(.-)%s+·%s+(level %d+)$")
  b.title:SetText(title or r.title)
  local subtitle = plain(r.subtitle)
  if level then subtitle = level:gsub("^l", "L") .. "  ·  " .. subtitle end
  b.text:SetText(subtitle)
  b.button:SetText(r.journey and "Start trip" or "Go")
  b.button:SetEnabled(r.journey ~= nil or r.route ~= nil)
  b:Show()
  paintBreakdown()
end

function Cards.ScrollBreakdown(delta)
  if not (view and view.breakdown:IsShown()) then return end
  breakdownOffset = math.max(0, breakdownOffset - delta)
  paintBreakdown()
end

function Cards.HideBreakdown()
  if view then view.breakdown:Hide() end
end

-- The breakdown's lines on screen (for tests), or nil when it's closed.
function Cards.BreakdownShown()
  if not (view and view.breakdown:IsShown()) then return nil end
  local out = {}
  for _, row in ipairs(view.breakdown.rows) do
    local t = row:GetText()
    if t and t ~= "" then out[#out + 1] = t end
  end
  return out
end

function Cards.BreakdownOpen()
  return view ~= nil and view.breakdown:IsShown()
end

---------------------------------------------------------------- showing

-- Shows results; `reset` starts again at the first one (and closes a breakdown).
function Cards.Show(list, emptyText, reset)
  results = list or {}
  if reset then
    offset = 0
    Cards.HideBreakdown()
  end
  if view then
    view:Show()
    view.empty:SetText(emptyText or "")
  end
  paint()
end

function Cards.Hide()
  if view then view:Hide() end
end

-- Steps through the suggestions: positive goes back towards the first.
function Cards.Step(delta)
  offset = math.max(0, offset - delta)
  paint()
end

-- The results on the large and small cards, in that order (for tests).
function Cards.Visible()
  local out = {}
  if not view then return out end
  for _, card in ipairs({ view.large, view.small[1], view.small[2] }) do
    if card.result then out[#out + 1] = card.result end
  end
  return out
end

-- The details drawn on a card (1 = large), for tests.
function Cards.Detail(index)
  local card = view and ({ view.large, view.small[1], view.small[2] })[index]
  return card and card.detail:GetText()
end

-- The titles and button labels drawn on the cards (for tests).
function Cards.Drawn()
  local out = {}
  if not view then return out end
  for _, card in ipairs({ view.large, view.small[1], view.small[2] }) do
    if card.result then
      out[#out + 1] = (card.title:GetText() or "") .. "|" .. (card.button:GetText() or "")
    end
  end
  return out
end

-- What each card holds and how its text is set up, for /wf debug cards.
function Cards.Diagnose()
  if not view then return { "cards not created yet: open /wf first" } end
  local lines = {}
  local names = { "large", "small 1", "small 2" }
  for i, card in ipairs({ view.large, view.small[1], view.small[2] }) do
    local fontFile, size = card.title:GetFont()
    local r, g, b, a = card.title:GetTextColor()
    lines[#lines + 1] = string.format("%s: shown=%s visible=%s result=%s title=%q font=%s size=%s colour=%.2f,%.2f,%.2f,%.2f width=%s",
      names[i], tostring((card:IsShown())), tostring((card:IsVisible())), tostring(card.result ~= nil),
      tostring((card.title:GetText())), tostring(fontFile), tostring(size), r or -1, g or -1, b or -1, a or -1,
      tostring((card.title:GetStringWidth())))
  end
  return lines
end
