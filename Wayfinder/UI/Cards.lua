local _, ns = ...

-- Suggestion cards in the style of modern WoW's Adventure Guide ("Suggested
-- Content"): one large featured card on the left, two smaller ones stacked on
-- the right, arrows to step through the rest. Sizes, fonts and colours follow
-- Blizzard's own frame (Blizzard_EncounterJournal, AdventureJournal templates).
-- The Adventure Guide isn't in Forever, so its art is used only when the
-- client has those atlases; otherwise a plain parchment look.
--
-- A page opts in with `layout = "cards"` (and `width`); results are the usual
-- panel results, plus optional `icon` (file) / `iconCoords` and `kind`.

local Cards = {}
ns.Cards = Cards

local LARGE_W, LARGE_H = 335, 337
local SMALL_W, SMALL_H = 344, 161
local GAP = 11
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
  card.title:SetPoint("TOP", card.icon, "BOTTOM", 0, -16)
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
  if card.detail.SetMaxLines then card.detail:SetMaxLines(5) end

  card.button = button(card, 116, 32, true)
  card.button:SetPoint("BOTTOM", 0, 31)
  card.extra = extra(card)
  card.extra:SetPoint("BOTTOM", card.button, "TOP", 0, 6)

  card.prev = CreateFrame("Button", nil, card)
  card.prev:SetSize(32, 32)
  card.prev:SetPoint("BOTTOMLEFT", 16, 12)
  card.prev:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
  card.prev:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
  card.prev:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Disabled")
  card.prev:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  card.prev:SetScript("OnClick", function() Cards.Step(1) end)
  card.next = CreateFrame("Button", nil, card)
  card.next:SetSize(32, 32)
  card.next:SetPoint("BOTTOMRIGHT", -16, 12)
  card.next:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
  card.next:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
  card.next:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Disabled")
  card.next:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  card.next:SetScript("OnClick", function() Cards.Step(-1) end)

  card.position = text(card, "GameFontHighlightSmall", 10, DETAIL_COLOR)
  card.position:SetPoint("BOTTOM", 0, 18)
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
  card.title:SetWidth(256)
  card.title:SetJustifyH("LEFT")
  card.title:SetWordWrap(false)

  card.text = text(card, "GameFontHighlightSmall", 11, TEXT_COLOR)
  card.text:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -6)
  card.text:SetWidth(256)
  card.text:SetJustifyH("LEFT")
  card.text:SetWordWrap(true)
  card.text:SetSpacing(2)
  if card.text.SetMaxLines then card.text:SetMaxLines(3) end

  card.button = button(card, 116, 24)
  card.button:SetPoint("BOTTOMLEFT", 70, 14)
  card.extra = extra(card)
  card.extra:SetPoint("LEFT", card.button, "RIGHT", 6, 0)
  hover(card)
  return card
end

---------------------------------------------------------------- view

local view
local results, offset = {}, 0

function Cards.Create(parent)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(LARGE_W + 12 + SMALL_W, LARGE_H)
  holder.large = largeCard(holder)
  holder.large:SetPoint("TOPLEFT", 0, 0)
  holder.small = { smallCard(holder), smallCard(holder) }
  holder.small[1]:SetPoint("TOPLEFT", holder.large, "TOPRIGHT", 12, -4)
  holder.small[2]:SetPoint("TOPLEFT", holder.small[1], "BOTTOMLEFT", 0, -GAP)
  holder.empty = holder:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  holder.empty:SetPoint("TOPLEFT", 0, -8)
  holder.empty:SetWidth(LARGE_W + 12 + SMALL_W)
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
  -- "Run The Stockade  ·  level 23": the level reads better in the subtitle.
  local title, level = (r.title or ""):match("^(.-)%s+·%s+(level %d+)$")
  card.title:SetText(title or r.title)
  local subtitle = plain(r.subtitle)
  if level then subtitle = level:gsub("^l", "L") .. "  ·  " .. subtitle end
  card.text:SetText(subtitle)
  if large then
    local lines = {}
    for i = 2, math.min(#(r.details or {}), 5) do lines[#lines + 1] = plain(r.details[i].text) end
    card.detail:SetText(table.concat(lines, "\n"))
  end
  card.button:SetText(r.journey and "Start trip" or "Go")
  card.button:SetEnabled(r.journey ~= nil or r.route ~= nil)
  local action = r.actions and r.actions[1]
  card.extra:SetShown(action ~= nil)
  if action then card.extra:SetText(action.label) end
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
  view.large.prev:SetEnabled(offset > 0)
  view.large.next:SetEnabled(offset < maxOffset)
  view.large.position:SetText(#results > 1 and string.format("%d of %d", offset + 1, #results) or "")
  view.empty:SetShown(#results == 0)
end

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
