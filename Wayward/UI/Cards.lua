local _, ns = ...

-- "Something to do next": suggestion cards, three equal ones per page, arrows
-- under them to page through the rest (so no suggestion shows twice); hover a
-- card for every detail, its stops and the route map. Each card: the round
-- icon, its role tag (QUESTING / EXPLORE / ALTERNATIVE), the title, one or
-- two lines of why, a row of up to three facts, and Start journey (or
-- Directions when the row has only a route).
-- The card art is the Adventure Guide pane where the client has that atlas
-- (Forever does); otherwise plain parchment.
--
-- A page opts in with `layout = "cards"` (and `width`); results are the usual
-- panel results (see the page contract in Panel.lua), plus optional `icon`
-- (file) / `iconCoords`, `kind`, `role`, `why`, `stats`, `category` and
-- `badge` ("~12 min", top right; red when `over`).

local Cards = {}
ns.Cards = Cards

local PER_PAGE = 3
local GAP = 10
local CARD_H = 180
local NAV_HEIGHT = 28      -- the arrows under the cards
local ICON = 48
local PAD = 12
-- Ink on parchment, darkest for titles.
local TITLE_COLOR = { 0.20, 0.10, 0.02 }
local TEXT_COLOR = { 0.22, 0.14, 0.06 }
local DETAIL_COLOR = { 0.28, 0.19, 0.09 }
local TAG_COLOR = { 0.45, 0.06, 0.02 } -- the role tag, a deep red
local PARCHMENT = { 0.86, 0.78, 0.6, 0.97 }
local RULE = { 0.35, 0.22, 0.08, 0.35 }
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Map_01"

-- The tag for a role, or for "continue" when the kind isn't a quest thing,
-- the kind itself; with no role, today's category.
local QUEST_KINDS = { quest = true, hub = true, handin = true, finish = true, zone = true, notable = true }
local ROLE_TAGS = { explore = "EXPLORE", alternative = "ALTERNATIVE" }

-- Small icons for the facts row, by what the fact is about.
local FACT_ICONS = {
  { "level", "Interface\\Icons\\Achievement_Level_10" },
  { "travel", "Interface\\Icons\\INV_Misc_PocketWatch_01" },
  { "journey", "Interface\\Icons\\INV_Misc_PocketWatch_01" },
  { "time", "Interface\\Icons\\INV_Misc_PocketWatch_01" },
  { "where", "Interface\\Icons\\INV_Misc_Spyglass_03" },
  { "nearby", "Interface\\Icons\\INV_Misc_Spyglass_03" },
  { "distance", "Interface\\Icons\\INV_Misc_Spyglass_03" },
  { "quest", "Interface\\Icons\\INV_Scroll_03" },
  { "ready", "Interface\\Icons\\INV_Letter_15" },
  { "log", "Interface\\Icons\\INV_Scroll_03" },
  { "xp", "Interface\\Icons\\INV_Misc_Book_11" },
  { "hub", "Interface\\Icons\\INV_Misc_Note_01" },
}
local DEFAULT_FACT_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local NEARBY_SECONDS = 120

local function hasAtlas(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- Friz Quadrata in ink colours, no shadow or outline (with them, everything on
-- parchment looks bold). The template is the fallback if the file can't be
-- set. (The Adventure Guide's own fonts are missing or broken in Forever.)
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
local function background(card)
  local bg = card:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  if hasAtlas("adventureguide-pane-small") then
    bg:SetAtlas("adventureguide-pane-small")
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

local function button(card, width, height)
  local b = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
  b:SetSize(width, height)
  b:SetScript("OnClick", function() if card.result then ns.Panel.Activate(card.result) end end)
  return b
end

-- Small button for a result's own action ("Flight only").
local function extra(card)
  local b = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
  b:SetSize(80, 20)
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

local function hover(card)
  card:EnableMouse(true)
  card:SetScript("OnEnter", function(self) if self.result then ns.Panel.ShowTooltip(self, self.result) end end)
  card:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Shift-click adds to the journey, like the panel's rows.
  card:SetScript("OnMouseUp", function(self)
    if self.result and IsShiftKeyDown and IsShiftKeyDown() then ns.Panel.Activate(self.result) end
  end)
end

-- A row of up to three facts, an icon and a value each ("~4 min away"),
-- across `width`.
local MAX_FACTS = 3

local function factRow(card, width)
  local row = CreateFrame("Frame", nil, card)
  row:SetSize(width, 16)
  row.width = width
  row.facts = {}
  for i = 1, MAX_FACTS do
    local fact = { }
    fact.icon = row:CreateTexture(nil, "ARTWORK")
    fact.icon:SetSize(14, 14)
    fact.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    fact.value = text(row, "GameFontNormalSmall", 11, TITLE_COLOR)
    fact.value:SetJustifyH("LEFT")
    fact.value:SetWordWrap(false)
    row.facts[i] = fact
  end
  return row
end

local function factIcon(label)
  local key = (label or ""):lower()
  for _, pair in ipairs(FACT_ICONS) do
    if key:find(pair[1], 1, true) then return pair[2] end
  end
  return DEFAULT_FACT_ICON
end

local function fillFacts(row, stats)
  local count = math.min(#stats, MAX_FACTS)
  local width = row.width / math.max(count, 1)
  for i, fact in ipairs(row.facts) do
    local stat = stats[i]
    local shown = stat ~= nil and i <= count
    fact.icon:SetShown(shown)
    fact.value:SetShown(shown)
    if shown then
      fact.icon:ClearAllPoints()
      fact.icon:SetPoint("LEFT", row, "LEFT", (i - 1) * width, 0)
      fact.icon:SetTexture(factIcon(stat[1]))
      fact.value:ClearAllPoints()
      fact.value:SetPoint("LEFT", fact.icon, "RIGHT", 4, 0)
      fact.value:SetWidth(width - 20)
      fact.value:SetText(stat[2])
      fact.label = stat[1]
    end
  end
end

-- A card, top to bottom: the icon with the tag and title beside it; the why;
-- a rule; the facts; the button. Fixed gaps, so every card lines up the same.
local function makeCard(parent, width)
  local card = CreateFrame("Frame", nil, parent)
  card:SetSize(width, CARD_H)
  background(card)
  icon(card, ICON, ICON + 22)
  card.icon:SetPoint("TOPLEFT", PAD + 2, -PAD - 2)
  local left = PAD + ICON + 14
  local textWidth = width - left - PAD

  card.badge = text(card, "GameFontNormal", 12, TITLE_COLOR)
  card.badge:SetPoint("TOPRIGHT", -PAD - 2, -PAD)
  card.badge:SetJustifyH("RIGHT")

  card.tag = text(card, "GameFontHighlightSmall", 10, TAG_COLOR)
  card.tag:SetPoint("TOPLEFT", left, -PAD - 2)
  card.tag:SetWidth(textWidth)
  card.tag:SetJustifyH("LEFT")
  card.tag:SetWordWrap(false)

  card.title = text(card, "GameFontNormalLarge", 14, TITLE_COLOR)
  card.title:SetPoint("TOPLEFT", card.tag, "BOTTOMLEFT", 0, -3)
  card.title:SetWidth(textWidth)
  card.title:SetJustifyH("LEFT")
  card.title:SetSpacing(1)
  if card.title.SetMaxLines then card.title:SetMaxLines(2) end

  -- The why, under the icon too: the card's full width.
  card.detail = text(card, "GameFontHighlightSmall", 11, TEXT_COLOR)
  card.detail:SetPoint("TOPLEFT", PAD, -PAD - ICON - 16)
  card.detail:SetWidth(width - 2 * PAD)
  card.detail:SetJustifyH("LEFT")
  card.detail:SetSpacing(2)
  if card.detail.SetMaxLines then card.detail:SetMaxLines(3) end

  card.rule = card:CreateTexture(nil, "ARTWORK")
  card.rule:SetColorTexture(RULE[1], RULE[2], RULE[3], RULE[4])
  card.rule:SetSize(width - 2 * PAD, 1)
  card.rule:SetPoint("BOTTOMLEFT", PAD, 54)

  card.stats = factRow(card, width - 2 * PAD)
  card.stats:SetPoint("TOPLEFT", card.rule, "BOTTOMLEFT", 0, -6)

  card.button = button(card, 120, 22)
  card.button:SetPoint("BOTTOM", 0, 10)
  card.extra = extra(card)
  card.extra:SetPoint("LEFT", card.button, "RIGHT", 6, 0)
  hover(card)
  return card
end

---------------------------------------------------------------- view

local view
local results, offset = {}, 0

local function pageButton(parent, direction, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(28, 28)
  local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. direction .. "Page-"
  b:SetNormalTexture(base .. "Up")
  b:SetPushedTexture(base .. "Down")
  b:SetDisabledTexture(base .. "Disabled")
  b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  b:SetScript("OnClick", onClick)
  return b
end

-- The cards across `width`, three per page, the arrows under them.
function Cards.Create(parent, width)
  width = width or 694
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(width, CARD_H + NAV_HEIGHT)
  holder.width = width
  local cardWidth = math.floor((width - (PER_PAGE - 1) * GAP) / PER_PAGE)
  holder.cards = {}
  for i = 1, PER_PAGE do
    local card = makeCard(holder, cardWidth)
    card:SetPoint("TOPLEFT", (i - 1) * (cardWidth + GAP), 0)
    holder.cards[i] = card
  end
  -- Under the cards, at the right: back, "Page 2 of 3", forward.
  holder.position = text(holder, "GameFontHighlightSmall", 11, { 0.85, 0.8, 0.7 })
  holder.position:SetPoint("TOPRIGHT", holder.cards[PER_PAGE], "BOTTOMRIGHT", -40, -8)
  holder.position:SetJustifyH("RIGHT")
  holder.prev = pageButton(holder, "Prev", function() Cards.Step(1) end)
  holder.prev:SetPoint("RIGHT", holder.position, "LEFT", -6, 0)
  holder.next = pageButton(holder, "Next", function() Cards.Step(-1) end)
  holder.next:SetPoint("LEFT", holder.position, "RIGHT", 6, 0)

  holder.empty = holder:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  holder.empty:SetPoint("TOPLEFT", 0, -8)
  holder.empty:SetWidth(width)
  holder.empty:SetJustifyH("LEFT")
  view = holder
  return holder
end

-- The holder's height (the cards and the arrows), for laying out the window.
function Cards.Height() return CARD_H + NAV_HEIGHT end

local function plain(text)
  return ((text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The role tag drawn on a card.
function Cards.TagFor(r)
  if r.role == "continue" then
    if QUEST_KINDS[r.kind] then return "QUESTING" end
    return string.upper(r.category or r.kind or "CONTINUE")
  end
  if ROLE_TAGS[r.role] then return ROLE_TAGS[r.role] end
  if r.category then return string.upper(r.category) end
  return r.role == nil and "ALTERNATIVE" or string.upper(r.role)
end

-- The why line: the row's own, else its first detail (the ranking, today).
function Cards.WhyFor(r)
  if r.why and r.why ~= "" then return plain(r.why) end
  local first = r.details and r.details[1]
  return first and plain(first.text) or ""
end

-- Up to three facts for the row: its stats, else what the row itself tells
-- (level from the title, travel time from the route, "Nearby" when close).
function Cards.FactsFor(r)
  if r.stats and #r.stats > 0 then return r.stats end
  local facts = {}
  local level = (r.title or ""):match("level (%d+)$")
  if level then facts[#facts + 1] = { "Level", level } end
  local seconds = (r.journey and r.journey.seconds) or (r.route and r.route.seconds)
  if seconds then
    if seconds < NEARBY_SECONDS then
      facts[#facts + 1] = { "Nearby", "Nearby" }
    else
      facts[#facts + 1] = { "Travel", ns.FormatDuration(seconds) .. " away" }
    end
  end
  return facts
end

-- The button's label: a journey, or plain directions.
function Cards.ButtonFor(r)
  return r.journey and "Start journey" or "Directions"
end

local function fill(card, r)
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
  -- "Run The Stockade  ·  level 23": the level is one of the facts.
  local title = (r.title or ""):match("^(.-)%s+·%s+level %d+$")
  card.title:SetText(title or r.title)
  card.tag:SetText(Cards.TagFor(r))
  card.badge:SetText(r.badge or "")
  card.badge:SetShown(r.badge ~= nil)
  local ink = r.over and TAG_COLOR or TITLE_COLOR
  card.badge:SetTextColor(ink[1], ink[2], ink[3])
  card.detail:SetText(Cards.WhyFor(r))
  local facts = Cards.FactsFor(r)
  fillFacts(card.stats, facts)
  card.stats:SetShown(#facts > 0)
  card.rule:SetShown(#facts > 0)
  card.button:SetText(Cards.ButtonFor(r))
  card.button:SetEnabled(r.journey ~= nil or r.route ~= nil)
  local action = r.actions and r.actions[1]
  card.extra:SetShown(action ~= nil)
  if action then card.extra:SetText(action.label) end
  -- Side by side when there are two buttons.
  card.button:ClearAllPoints()
  card.button:SetPoint("BOTTOM", action and -43 or 0, 10)
end

local reported

local function safeFill(card, r)
  local ok, err = pcall(fill, card, r)
  if not ok and not reported then
    reported = true
    -- In chat too: Lua errors are often switched off.
    ns.print("couldn't draw a suggestion card: " .. tostring(err))
    geterrorhandler()(err)
  end
end

local function paint()
  if not view then return end
  local pages = math.max(1, math.ceil(#results / PER_PAGE))
  local maxOffset = (pages - 1) * PER_PAGE
  if offset > maxOffset then offset = maxOffset end
  for i, card in ipairs(view.cards) do safeFill(card, results[offset + i]) end
  local several = pages > 1
  view.prev:SetShown(several)
  view.next:SetShown(several)
  view.prev:SetEnabled(offset > 0)
  view.next:SetEnabled(offset < maxOffset)
  view.position:SetText(several and string.format("Page %d of %d", offset / PER_PAGE + 1, pages) or "")
  view.empty:SetShown(#results == 0)
end

---------------------------------------------------------------- showing

-- Shows results; `reset` starts again at the first one.
function Cards.Show(list, emptyText, reset)
  results = list or {}
  if reset then offset = 0 end
  if view then
    view:Show()
    view.empty:SetText(emptyText or "")
  end
  paint()
end

function Cards.Hide()
  if view then view:Hide() end
end

-- Pages through the suggestions: positive goes back towards the first.
function Cards.Step(delta)
  offset = math.max(0, offset - delta * PER_PAGE)
  paint()
end

local function card(index)
  return view and view.cards[index]
end

-- The results on the cards, left to right (for tests).
function Cards.Visible()
  local out = {}
  if not view then return out end
  for _, c in ipairs(view.cards) do
    if c.result then out[#out + 1] = c.result end
  end
  return out
end

-- The why line drawn on a card (1 = leftmost), for tests.
function Cards.Detail(index)
  local c = card(index)
  return c and c.detail:GetText()
end
Cards.Why = Cards.Detail

-- A card's tag as drawn (1 = leftmost), for tests.
function Cards.Tag(index)
  local c = card(index)
  return c and c.tag:GetText()
end

-- A card's time as drawn (1 = leftmost), or nil when it has none, for tests.
function Cards.Badge(index)
  local c = card(index)
  return c and c.badge:IsShown() and c.badge:GetText() or nil
end

-- A card's facts as drawn, "LABEL=value" (1 = leftmost), for tests.
function Cards.Stats(index)
  local c = card(index)
  local out = {}
  if not (c and c.stats:IsShown()) then return out end
  for _, fact in ipairs(c.stats.facts) do
    if fact.value:IsShown() then out[#out + 1] = string.upper(fact.label or "") .. "=" .. fact.value:GetText() end
  end
  return out
end

-- The titles and button labels drawn on the cards (for tests).
function Cards.Drawn()
  local out = {}
  if not view then return out end
  for _, c in ipairs(view.cards) do
    if c.result then
      out[#out + 1] = (c.title:GetText() or "") .. "|" .. (c.button:GetText() or "")
    end
  end
  return out
end

-- What each card holds and how its text is set up, for /ww debug cards.
function Cards.Diagnose()
  if not view then return { "cards not created yet: open /ww first" } end
  local lines = {}
  for i, c in ipairs(view.cards) do
    local fontFile, size = c.title:GetFont()
    local r, g, b, a = c.title:GetTextColor()
    lines[#lines + 1] = string.format("card %d: shown=%s visible=%s result=%s title=%q font=%s size=%s colour=%.2f,%.2f,%.2f,%.2f width=%s",
      i, tostring((c:IsShown())), tostring((c:IsVisible())), tostring(c.result ~= nil),
      tostring((c.title:GetText())), tostring(fontFile), tostring(size), r or -1, g or -1, b or -1, a or -1,
      tostring((c.title:GetStringWidth())))
  end
  return lines
end
