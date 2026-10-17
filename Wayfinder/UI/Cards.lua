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
local TITLE_COLOR = { 0, 0, 0 }
local TEXT_COLOR = { 0.2824, 0.0157, 0.0157 }
local PARCHMENT = { 0.86, 0.78, 0.6, 0.97 }
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Map_01"

local function hasAtlas(name)
  return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- Text with a standard font (the template always exists), switched to the
-- Adventure Guide's own font when the client has it. Forever lacks some of
-- them, and text without a font errors when set.
local function text(parent, template, preferred)
  local fs = parent:CreateFontString(nil, "ARTWORK", template)
  local object = preferred and _G[preferred]
  if object then pcall(fs.SetFontObject, fs, object) end
  return fs
end

local function color(fs, c)
  fs:SetTextColor(c[1], c[2], c[3])
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

-- The round icon with its ring.
local function icon(card, size, ringSize)
  card.icon = card:CreateTexture(nil, "ARTWORK")
  card.icon:SetSize(size, size)
  if card.icon.SetMask then pcall(card.icon.SetMask, card.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
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

  card.title = text(card, "GameFontNormalHuge", "DestinyFontHuge")
  card.title:SetPoint("TOP", card.icon, "BOTTOM", 0, -18)
  card.title:SetWidth(264)
  card.title:SetJustifyH("CENTER")
  color(card.title, TITLE_COLOR)

  card.text = text(card, "GameFontHighlight", "GameTooltipHeader")
  card.text:SetPoint("TOP", card.title, "BOTTOM", 0, -8)
  card.text:SetWidth(264)
  card.text:SetJustifyH("CENTER")
  color(card.text, TEXT_COLOR)

  card.detail = text(card, "GameFontHighlightSmall", "SystemFont_Med1")
  card.detail:SetPoint("TOP", card.text, "BOTTOM", 0, -10)
  card.detail:SetWidth(264)
  card.detail:SetJustifyH("CENTER")
  color(card.detail, TEXT_COLOR)

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

  card.position = text(card, "GameFontHighlightSmall", "SystemFont_Med1")
  card.position:SetPoint("BOTTOM", 0, 18)
  color(card.position, TEXT_COLOR)
  hover(card)
  return card
end

local function smallCard(parent)
  local card = CreateFrame("Frame", nil, parent)
  card:SetSize(SMALL_W, SMALL_H)
  background(card, "adventureguide-pane-small")
  icon(card, 64, 94)
  card.icon:SetPoint("TOPLEFT", -10, -2)

  card.title = text(card, "GameFontNormalLarge", "QuestFont_Huge")
  card.title:SetPoint("TOPLEFT", 70, -14)
  card.title:SetWidth(260)
  card.title:SetJustifyH("LEFT")
  card.title:SetWordWrap(false)
  color(card.title, TITLE_COLOR)

  card.text = text(card, "GameFontHighlightSmall", "SystemFont_Med1")
  card.text:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -4)
  card.text:SetWidth(240)
  card.text:SetJustifyH("LEFT")
  card.text:SetWordWrap(true)
  if card.text.SetMaxLines then card.text:SetMaxLines(4) end
  color(card.text, TEXT_COLOR)

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
  card.icon:SetTexture(r.icon or DEFAULT_ICON)
  if r.iconCoords then card.icon:SetTexCoord((unpack or table.unpack)(r.iconCoords)) else card.icon:SetTexCoord(0, 1, 0, 1) end
  card.title:SetText(r.title)
  card.text:SetText(plain(r.subtitle))
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
