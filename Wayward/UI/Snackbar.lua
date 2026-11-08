local _, ns = ...

-- Snackbars: a short note laid over the directions box (UI/HUD.lua) for a
-- moment, with one or two icon buttons, that fades on its own. A bar behind
-- the words drains as its time runs out. They carry what used to be a dialog
-- in the middle of the screen: "You picked up X. Add it to your journey?"
-- (add, new journey) and "Added X to your journey." (undo). Doing nothing is
-- always an answer: it fades (not while the mouse is over it, which also
-- holds the bar) or the x closes it at once, and nothing changes. The icons
-- say what they do on hover; the box shows `detail` on hover, when it has
-- some. One at a time; the next waits for the one on screen to go. With no
-- directions on, it sits where the directions box would be.
--
-- Snackbar.Show{ text, note?, title? and detail? (the hover), actions = { {
--   label (the icon's tooltip), icon ("add" | "undo" | "journey"), run,
--   tooltip? } }, seconds?, sound?, quests? ({ [questID] = true }: which
--   quests it's about, for Snackbar.Drop) } queues one.

local Snackbar = {}
ns.Snackbar = Snackbar

local PAD, ICON, CLOSE = 10, 22, 20
local MIN_HEIGHT = 48
local NOTICE_SECONDS, QUESTION_SECONDS, FADE = 8, 15, 0.4
local BOX_STRATA, CONTENT_STRATA = "HIGH", "DIALOG"
local BAR_COLOR = { 1, 0.82, 0, 0.18 }
local GREY = { 0.6, 0.6, 0.6 }

-- Each action's picture; its words are the button's tooltip.
local ICONS = {
  add = { "Interface\\Icons\\Spell_ChargePositive", 0.08, 0.92, 0.08, 0.92 },
  journey = { "Interface\\Icons\\INV_Misc_Map_01", 0.08, 0.92, 0.08, 0.92 },
  -- The model viewer's turn-left arrow: the curved arrow of "undo".
  undo = { "Interface\\Buttons\\UI-RotationLeft-Button-Up", 0.2, 0.8, 0.2, 0.8 },
}
Snackbar.ICONS = ICONS

local frame
local queue = {}
local showNext

local function finish()
  if frame then
    frame:SetScript("OnUpdate", nil)
    frame:Hide()
    frame.item = nil
  end
  if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
  showNext()
end

local function showTooltip(owner, title, lines)
  if not GameTooltip then return end
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  GameTooltip:SetText(title or "")
  for _, line in ipairs(lines or {}) do GameTooltip:AddLine(line, GREY[1], GREY[2], GREY[3], true) end
  GameTooltip:Show()
end

local function iconButton(parent, i)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(ICON, ICON)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints()
  local glow = b:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  glow:SetBlendMode("ADD")
  b:SetScript("OnClick", function() Snackbar.Click(i) end)
  b:SetScript("OnEnter", function(self)
    local a = frame and frame.item and frame.item.actions[i]
    if a then showTooltip(self, a.label, a.tooltip and { a.tooltip }) end
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function create()
  local f = ns.Skin.CreateBox("WaywardSnackbar")
  f:SetFrameStrata(BOX_STRATA)
  f:SetBackdropColor(0, 0, 0, 0.95)
  f:EnableMouse(true)

  -- Everything on the box sits on a layer of its own, a strata above it: a UI
  -- suite's skin (EllesmereUI's panel, ElvUI's template) paints the box with
  -- frames of its own whose level we don't control, and at the box's level
  -- they can cover what's drawn there. A higher strata always draws above.
  -- The layer takes no mouse: hovering and clicks on the box still reach it.
  f.content = CreateFrame("Frame", nil, f)
  f.content:SetAllPoints()
  f.content:SetFrameStrata(CONTENT_STRATA)

  -- The time left, behind the words: drains from the right.
  f.bar = f.content:CreateTexture(nil, "BACKGROUND")
  f.bar:SetPoint("TOPLEFT", 2, -2)
  f.bar:SetPoint("BOTTOMLEFT", 2, 2)
  f.bar:SetColorTexture(BAR_COLOR[1], BAR_COLOR[2], BAR_COLOR[3], BAR_COLOR[4])

  f.close = CreateFrame("Button", nil, f.content, "UIPanelCloseButton")
  f.close:SetSize(CLOSE, CLOSE)
  f.close:SetPoint("TOPRIGHT", -3, -3)
  f.close:SetScript("OnClick", function() Snackbar.Dismiss() end)
  f.close:SetScript("OnEnter", function(self) showTooltip(self, "Not now") end)
  f.close:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.CloseButton(f.close)

  f.buttons = {}
  for i = 1, 2 do f.buttons[i] = iconButton(f.content, i) end
  f.buttons[1]:SetPoint("RIGHT", -(CLOSE + 8), 0)
  f.buttons[2]:SetPoint("RIGHT", f.buttons[1], "LEFT", -6, 0)

  f.text = f.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.text:SetJustifyH("LEFT")
  f.text:SetWordWrap(true)
  f.note = f.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.note:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -4)
  f.note:SetPoint("RIGHT", f.text, "RIGHT")
  f.note:SetJustifyH("LEFT")
  f.note:SetWordWrap(true)

  f:SetScript("OnEnter", function(self)
    local item = self.item
    if item and item.detail and #item.detail > 0 then showTooltip(self, item.title or "Wayward", item.detail) end
  end)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.Box(f)
  f:Hide()
  return f
end

-- Over the directions box, as wide as it is; with no directions on, where it
-- would be.
local function place()
  local hud = ns.HUD and ns.HUD.EnsureFrame and ns.HUD.EnsureFrame()
  frame:ClearAllPoints()
  if hud then
    frame:SetPoint("TOPLEFT", hud, "TOPLEFT")
    frame:SetPoint("TOPRIGHT", hud, "TOPRIGHT")
  else
    frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
    frame:SetWidth(330)
  end
end

-- Covers the directions box while it's up (they change size as you go), or
-- fits the words when they need more room; the words sit in the middle.
local function fit()
  local item = frame.item
  if not item then return end
  local words = (frame.text:GetStringHeight() or 14)
    + (item.note and ((frame.note:GetStringHeight() or 12) + 4) or 0)
  local height = math.max(MIN_HEIGHT, words + 2 * PAD)
  local hud = ns.HUD and ns.HUD.Frame and ns.HUD.Frame()
  if hud and hud:IsShown() then height = math.max(height, hud:GetHeight() or 0) end
  local top = math.max(PAD, math.floor((height - words) / 2))
  if height ~= frame.height or top ~= frame.top then
    frame.height, frame.top = height, top
    frame:SetHeight(height)
    frame.text:ClearAllPoints()
    frame.text:SetPoint("TOPLEFT", PAD, -top)
    frame.text:SetPoint("RIGHT", frame.leftmost, "LEFT", -8, 0)
  end
end

local function layout(item)
  local leftmost = frame.close
  for i, b in ipairs(frame.buttons) do
    local a = item.actions[i]
    if a then
      local art = ICONS[a.icon] or ICONS.add
      b.icon:SetTexture(art[1])
      b.icon:SetTexCoord(art[2], art[3], art[4], art[5])
      b.kind = a.icon
      b:Show()
      leftmost = b
    else
      b:Hide()
    end
  end
  frame.leftmost = leftmost
  frame.text:SetText(item.text)
  frame.note:SetText(item.note or "")
  frame.note:SetShown(item.note ~= nil)
  frame.height, frame.top = nil, nil
  fit()
end

-- How much of its time the one on screen has left (0..1; held while hovered).
local function drawBar()
  local width = (frame:GetWidth() or 0) - 4
  local share = frame.total > 0 and math.max(0, frame.left / frame.total) or 0
  frame.bar:SetWidth(math.max(0.1, width * share))
  frame.bar:SetShown(share > 0)
end

-- Fades after the item's time on screen, unless the mouse is over it.
local function countDown(seconds)
  frame.total, frame.left = seconds, seconds
  frame:SetAlpha(1)
  drawBar()
  frame:SetScript("OnUpdate", function(self, dt)
    fit()
    if self.IsMouseOver and self:IsMouseOver() then
      self.left = math.max(self.left, FADE)
      self:SetAlpha(1)
    else
      self.left = self.left - dt
      if self.left <= 0 then return finish() end
      if self.left < FADE then self:SetAlpha(self.left / FADE) end
    end
    drawBar()
  end)
end

function showNext()
  local item = table.remove(queue, 1)
  if not item then return end
  if not CreateFrame then return showNext() end
  frame = frame or create()
  frame.item = item
  place()
  frame:Show()
  -- In case something moved the box to another strata since.
  if frame.content:GetFrameStrata() ~= CONTENT_STRATA then frame.content:SetFrameStrata(CONTENT_STRATA) end
  layout(item)
  countDown(item.seconds or (item.question and QUESTION_SECONDS or NOTICE_SECONDS))
  if item.sound then ns.Sounds.Play(item.sound) end
end

-- Queues `item` (see the top of the file). Returns it.
function Snackbar.Show(item)
  item.actions = item.actions or {}
  queue[#queue + 1] = item
  if not Snackbar.Current() then showNext() end
  return item
end

-- The one on screen, or nil.
function Snackbar.Current()
  return frame and frame:IsShown() and frame.item or nil
end

-- Waiting behind the one on screen.
function Snackbar.Queued() return queue end

-- The snackbar's frame, once there's been one (for tests).
function Snackbar.Frame() return frame end

-- The share of its time the one on screen has left, 0..1 (for tests).
function Snackbar.TimeLeft()
  if not Snackbar.Current() then return 0 end
  return frame.total > 0 and math.max(0, frame.left / frame.total) or 0
end

-- Runs the on-screen one's action `i` and closes it.
function Snackbar.Click(i)
  local item = Snackbar.Current()
  local a = item and item.actions[i]
  if not a then return end
  finish()
  a.run()
end

-- Closes the one on screen without doing anything.
function Snackbar.Dismiss()
  if Snackbar.Current() then finish() end
end

-- Takes every snackbar away, on screen and waiting.
function Snackbar.Clear()
  for i = #queue, 1, -1 do queue[i] = nil end
  Snackbar.Dismiss()
end

-- Takes away every snackbar, on screen or waiting, about `questID` (one
-- abandoned: its question or its undo has nothing left to act on).
function Snackbar.Drop(questID)
  for i = #queue, 1, -1 do
    if queue[i].quests and queue[i].quests[questID] then table.remove(queue, i) end
  end
  local item = Snackbar.Current()
  if item and item.quests and item.quests[questID] then finish() end
end
