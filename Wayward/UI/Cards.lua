local _, ns = ...

-- Suggestion cards in the style of modern WoW's Adventure Guide ("Suggested
-- Content"): one large featured card on the left, two smaller ones stacked on
-- the right, arrows under them to page through the rest, three at a time (so
-- no suggestion shows twice); hover a card for
-- every detail and step. Sizes, fonts and colours follow
-- Blizzard's own frame (Blizzard_EncounterJournal, AdventureJournal templates).
-- The Adventure Guide isn't in Forever, so its art is used only when the
-- client has those atlases; otherwise a plain parchment look.
--
-- A page opts in with `layout = "cards"` (and `width`); results are the usual
-- panel results, plus optional `icon` (file) / `iconCoords`, `kind`, and
-- `place` / `stats` / `category` (see the page contract in Panel.lua), and
-- `badge` ("~12 min", top right; red when `over`).

local Cards = {}
ns.Cards = Cards

local LARGE_W, LARGE_H = 335, 365
local SMALL_W, SMALL_H = 344, 175
local GAP = 11
local WIDTH = LARGE_W + 12 + SMALL_W
local NAV_HEIGHT = 34      -- the arrows under the cards
-- Ink on parchment, darkest for titles.
local TITLE_COLOR = { 0.20, 0.10, 0.02 }
local TEXT_COLOR = { 0.22, 0.14, 0.06 }
local DETAIL_COLOR = { 0.28, 0.19, 0.09 }
local TAG_COLOR = { 0.45, 0.06, 0.02 } -- the card's kind ("BEST QUEST"), a deep red
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

-- The large pane's art has a reward ribbon in its top-left corner (retail
-- shows a reward there; we have none), so the large card is built from the
-- small pane's art in three slices instead: its top and bottom as drawn
-- (torn edges and corners), the band between them stretched to fit.
local SLICE = 0.4 -- share of the small pane's height kept as drawn, top and bottom

local function sliced(card, atlas)
  local info = C_Texture.GetAtlasInfo(atlas)
  if not (info and info.file and info.leftTexCoord and info.rightTexCoord and info.topTexCoord
    and info.bottomTexCoord and info.height and info.height > 0) then return false end
  local l, r, t, b = info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord
  local w, h = card:GetWidth() or LARGE_W, card:GetHeight() or LARGE_H
  local edge = math.floor(info.height * SLICE + 0.5)
  local function piece(v0, v1, height, point, y)
    local tex = card:CreateTexture(nil, "BACKGROUND")
    tex:SetTexture(info.file)
    tex:SetTexCoord(l, r, t + (b - t) * v0, t + (b - t) * v1)
    tex:SetSize(w, height)
    tex:SetPoint(point, 0, y)
  end
  piece(0, SLICE, edge, "TOP", 0)
  piece(SLICE, 1 - SLICE, h - 2 * edge, "TOP", -edge)
  piece(1 - SLICE, 1, edge, "BOTTOM", 0)
  return true
end

-- Card background: the Adventure Guide pane, or parchment.
local function background(card, atlas)
  if atlas == "adventureguide-pane-large" and hasAtlas("adventureguide-pane-small") then
    local ok, done = pcall(sliced, card, "adventureguide-pane-small")
    if ok and done then return end
  end
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

local function hover(card)
  card:EnableMouse(true)
  card:SetScript("OnEnter", function(self) if self.result then ns.Panel.ShowTooltip(self, self.result) end end)
  card:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Shift-click adds to the trip, like the panel's rows.
  card:SetScript("OnMouseUp", function(self)
    if self.result and IsShiftKeyDown and IsShiftKeyDown() then ns.Panel.Activate(self.result) end
  end)
end

-- A row of up to three numbers, label over value ("TRAVEL / ~5 min"), split
-- evenly across `width` with thin rules between them.
local MAX_STATS = 3
local RULE = { 0.35, 0.22, 0.08, 0.35 }

local function statStrip(card, width, labelSize, valueSize, justify)
  local strip = CreateFrame("Frame", nil, card)
  strip:SetSize(width, labelSize + valueSize + 8)
  strip.width, strip.justify = width, justify
  strip.columns, strip.rules = {}, {}
  for i = 1, MAX_STATS do
    local label = text(strip, "GameFontHighlightSmall", labelSize, DETAIL_COLOR)
    label:SetJustifyH(justify)
    label:SetWordWrap(false)
    local value = text(strip, "GameFontNormal", valueSize, TITLE_COLOR)
    value:SetJustifyH(justify)
    value:SetWordWrap(false)
    strip.columns[i] = { label = label, value = value }
    if i > 1 then
      local rule = strip:CreateTexture(nil, "ARTWORK")
      rule:SetColorTexture(RULE[1], RULE[2], RULE[3], RULE[4])
      rule:SetSize(1, labelSize + valueSize + 4)
      strip.rules[i] = rule
    end
  end
  return strip
end

local function fillStats(strip, stats)
  local count = math.min(#stats, MAX_STATS)
  local width = strip.width / math.max(count, 1)
  for i, col in ipairs(strip.columns) do
    local stat = stats[i]
    local shown = stat ~= nil and i <= count
    col.label:SetShown(shown)
    col.value:SetShown(shown)
    if shown then
      local inset = strip.justify == "LEFT" and (i > 1 and 8 or 0) or 4
      col.label:ClearAllPoints()
      col.label:SetPoint("TOPLEFT", (i - 1) * width + inset, 0)
      col.label:SetWidth(width - inset - 4)
      col.label:SetText(string.upper(stat[1]))
      col.value:ClearAllPoints()
      col.value:SetPoint("TOPLEFT", col.label, "BOTTOMLEFT", 0, -3)
      col.value:SetWidth(width - inset - 4)
      col.value:SetText(stat[2])
    end
    local rule = strip.rules[i]
    if rule then
      rule:SetShown(shown)
      rule:ClearAllPoints()
      rule:SetPoint("TOPLEFT", (i - 1) * width, 0)
    end
  end
end

-- A thin rule across a card, between its blocks.
local function divider(card, width)
  local line = card:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(RULE[1], RULE[2], RULE[3], RULE[4])
  line:SetSize(width, 1)
  return line
end

-- Large card, top to bottom: icon, its kind ("DUNGEON"), title, where; the
-- numbers; a rule; the quests and notes; the button. Fixed gaps, so every card lines up the same.
local LARGE_TEXT_W = 270

local function largeCard(parent)
  local card = CreateFrame("Frame", nil, parent)
  card:SetSize(LARGE_W, LARGE_H)
  background(card, "adventureguide-pane-large")
  icon(card, 64, 94)
  card.icon:SetPoint("TOPLEFT", (LARGE_W - 64) / 2, -16)

  card.badge = text(card, "GameFontNormalLarge", 16, TITLE_COLOR)
  card.badge:SetPoint("TOPRIGHT", -24, -24)
  card.badge:SetJustifyH("RIGHT")

  card.tag = text(card, "GameFontHighlightSmall", 10, TAG_COLOR)
  card.tag:SetPoint("TOP", card.icon, "BOTTOM", 0, -10)
  card.tag:SetWidth(LARGE_TEXT_W)
  card.tag:SetJustifyH("CENTER")

  card.title = text(card, "GameFontNormalHuge", 18, TITLE_COLOR)
  card.title:SetPoint("TOP", card.tag, "BOTTOM", 0, -4)
  card.title:SetWidth(LARGE_TEXT_W)
  card.title:SetJustifyH("CENTER")
  if card.title.SetMaxLines then card.title:SetMaxLines(2) end

  card.text = text(card, "GameFontHighlight", 12, TEXT_COLOR)
  card.text:SetPoint("TOP", card.title, "BOTTOM", 0, -4)
  card.text:SetWidth(LARGE_TEXT_W)
  card.text:SetJustifyH("CENTER")
  card.text:SetSpacing(2)
  if card.text.SetMaxLines then card.text:SetMaxLines(2) end

  card.stats = statStrip(card, LARGE_TEXT_W, 10, 15, "CENTER")
  card.rule = divider(card, LARGE_TEXT_W - 20)

  card.detail = text(card, "GameFontHighlightSmall", 11, TEXT_COLOR)
  card.detail:SetWidth(LARGE_TEXT_W - 12)
  card.detail:SetJustifyH("LEFT")
  card.detail:SetSpacing(3)
  if card.detail.SetMaxLines then card.detail:SetMaxLines(5) end

  card.button = button(card, 116, 32, true)
  card.button:SetPoint("BOTTOM", 0, 22)
  card.extra = extra(card)
  card.extra:SetPoint("LEFT", card.button, "RIGHT", 6, 0)
  hover(card)
  return card
end

-- Small card: the same blocks beside the icon, one line each.
local SMALL_LEFT, SMALL_TEXT_W = 74, 254

local function smallCard(parent)
  local card = CreateFrame("Frame", nil, parent)
  card:SetSize(SMALL_W, SMALL_H)
  background(card, "adventureguide-pane-small")
  icon(card, 64, 94)
  card.icon:SetPoint("TOPLEFT", -10, -2)

  -- Clear of the pane's worn top edge, and no smaller than the large card's.
  card.badge = text(card, "GameFontNormal", 13, TITLE_COLOR)
  card.badge:SetPoint("TOPRIGHT", -18, -13)
  card.badge:SetJustifyH("RIGHT")

  card.tag = text(card, "GameFontHighlightSmall", 10, TAG_COLOR)
  card.tag:SetPoint("TOPLEFT", SMALL_LEFT, -15)
  card.tag:SetWidth(SMALL_TEXT_W)
  card.tag:SetJustifyH("LEFT")

  card.title = text(card, "GameFontNormalLarge", 14, TITLE_COLOR)
  card.title:SetPoint("TOPLEFT", card.tag, "BOTTOMLEFT", 0, -3)
  card.title:SetWidth(SMALL_TEXT_W)
  card.title:SetJustifyH("LEFT")
  card.title:SetWordWrap(false)

  card.text = text(card, "GameFontHighlightSmall", 11, TEXT_COLOR)
  card.text:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -4)
  card.text:SetWidth(SMALL_TEXT_W)
  card.text:SetJustifyH("LEFT")
  card.text:SetWordWrap(false)

  card.stats = statStrip(card, SMALL_TEXT_W, 9, 12, "LEFT")

  card.detail = text(card, "GameFontHighlightSmall", 10, DETAIL_COLOR)
  card.detail:SetWidth(SMALL_TEXT_W)
  card.detail:SetJustifyH("LEFT")
  card.detail:SetSpacing(2)
  if card.detail.SetMaxLines then card.detail:SetMaxLines(2) end

  card.button = button(card, 116, 24)
  card.button:SetPoint("BOTTOMLEFT", SMALL_LEFT - 2, 14)
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
  b:SetSize(32, 32)
  local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. direction .. "Page-"
  b:SetNormalTexture(base .. "Up")
  b:SetPushedTexture(base .. "Down")
  b:SetDisabledTexture(base .. "Disabled")
  b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  b:SetScript("OnClick", onClick)
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
  -- "Run The Stockade  ·  level 23": the level is one of the numbers.
  local title, level = (r.title or ""):match("^(.-)%s+·%s+level (%d+)$")
  card.title:SetText(title or r.title)
  card.tag:SetText(r.category and string.upper(r.category) or "")
  card.badge:SetText(r.badge or "")
  card.badge:SetShown(r.badge ~= nil)
  local ink = r.over and TAG_COLOR or TITLE_COLOR
  card.badge:SetTextColor(ink[1], ink[2], ink[3])

  -- Where, then the numbers; rows without them show their subtitle instead.
  local stats = r.stats
  if not stats and level then stats = { { "Level", level } } end
  card.text:SetText(plain(r.place or r.subtitle))
  local below = card.text
  if stats and #stats > 0 then
    fillStats(card.stats, stats)
    card.stats:ClearAllPoints()
    card.stats:SetPoint("TOP", card.text, "BOTTOM", 0, large and -14 or -8)
    if not large then
      card.stats:ClearAllPoints()
      card.stats:SetPoint("TOPLEFT", card.text, "BOTTOMLEFT", 0, -8)
    end
    card.stats:Show()
    below = card.stats
  else
    card.stats:Hide()
  end

  -- The quests and notes (details after the ranking line, without those
  -- marked `more`); the tooltip has everything.
  local lines, room = {}, large and 5 or 2
  for i = 2, #(r.details or {}) do
    if #lines >= room then break end
    if not r.details[i].more then lines[#lines + 1] = plain(r.details[i].text) end
  end
  card.detail:SetText(table.concat(lines, "\n"))
  card.detail:ClearAllPoints()
  if large then
    card.rule:ClearAllPoints()
    card.rule:SetPoint("TOP", below, "BOTTOM", 0, -10)
    card.rule:SetShown(#lines > 0)
    card.detail:SetPoint("TOP", card.rule, "BOTTOM", 0, -10)
  else
    card.detail:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -8)
  end
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

local PER_PAGE = 3

local function paint()
  if not view then return end
  local pages = math.max(1, math.ceil(#results / PER_PAGE))
  local maxOffset = (pages - 1) * PER_PAGE
  if offset > maxOffset then offset = maxOffset end
  safeFill(view.large, results[offset + 1], true)
  safeFill(view.small[1], results[offset + 2])
  safeFill(view.small[2], results[offset + 3])
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

-- A card's kind as drawn (1 = large), for tests.
function Cards.Tag(index)
  local card = view and ({ view.large, view.small[1], view.small[2] })[index]
  return card and card.tag:GetText()
end

-- A card's time as drawn (1 = large), or nil when it has none, for tests.
function Cards.Badge(index)
  local card = view and ({ view.large, view.small[1], view.small[2] })[index]
  return card and card.badge:IsShown() and card.badge:GetText() or nil
end

-- A card's numbers as drawn, "LABEL=value" (1 = large), for tests.
function Cards.Stats(index)
  local card = view and ({ view.large, view.small[1], view.small[2] })[index]
  local out = {}
  if not (card and card.stats:IsShown()) then return out end
  for _, col in ipairs(card.stats.columns) do
    if col.label:IsShown() then out[#out + 1] = col.label:GetText() .. "=" .. col.value:GetText() end
  end
  return out
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

-- What each card holds and how its text is set up, for /ww debug cards.
function Cards.Diagnose()
  if not view then return { "cards not created yet: open /ww first" } end
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
