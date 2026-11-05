local _, ns = ...

-- Directions box shown while navigating: current step, distance, and our own
-- compass (an arrow in a circle; /ww compass or the options turn it off, and
-- the box gets narrower), and a + button to add a detour (repair, mail, ...).
-- Blizzard's on-screen navigation is off by default in Forever
-- (showInGameNavigation = 0), so we don't rely on it.
-- Prototype: a bag button for the shopping list (quests gathered as you go)
-- with the count of what's left; open, the list pops up above the box.
-- Detail on demand (Nav.Detail): "steps" shows each step to the next stop
-- with a count; "stops" shows only the stop you're heading for and the
-- compass, and the step when you hover the box.

local HUD = {}
ns.HUD = HUD

local frame
local unpack = unpack or table.unpack
local UPDATE_INTERVAL = 0.1
local WIDTH = 330
local MIN_HEIGHT = 84
local PADDING = 10
local CIRCLE = 42
local TEXT_LEFT = PADDING + CIRCLE + 10
local ADD_SIZE = 20
local INFO_RIGHT = -(PADDING + ADD_SIZE + 2) -- the last line stops short of the + button
local HOME = { "TOP", "TOP", 0, -140 }
local FLASH_PERIOD = 0.8 -- seconds per pulse of the book button when the journey gains stops
local FLASH_PULSES = 3
local MAX_OBJECTIVES = 4 -- lines of objectives under the step; past that, "+N more"
-- PROTOTYPE: the shopping list (quests gathered as you go, Journey.ShoppingList).
local SHOP_ICON = "Interface\\Icons\\INV_Misc_Bag_07"
local SHOP_ROWS = 4        -- things listed, around you first, then nearest; the rest is one "+N more"
local SHOP_EVERY = 1       -- seconds between looks at what's around you
local SHOP_GAP = 3         -- the list sits this far above the box
local SHOP_PAD = 5         -- inside its background
local SHOP_FADE = 0.35     -- its background's alpha
local SHOP_LINE = 14       -- a line's height when the client can't say

-- What's at a stop, shown in the circle when there's no arrow to show.
local STOP_ICONS = {
  pickup = "Interface\\GossipFrame\\AvailableQuestIcon",
  turnin = "Interface\\GossipFrame\\ActiveQuestIcon",
  complete = "Interface\\Icons\\INV_Sword_04",
  item = "Interface\\Icons\\INV_Misc_Bag_10",
  manual = "Interface\\Icons\\INV_Misc_Note_01",
  talk = "Interface\\GossipFrame\\GossipGossipIcon",
  train = "Interface\\GossipFrame\\TrainerGossipIcon",
  learn = "Interface\\GossipFrame\\TrainerGossipIcon",
  explore = "Interface\\Icons\\INV_Misc_Map_01",
  enter = "Interface\\Icons\\INV_Misc_Key_03",
}
-- Travel icons are the route map's (RouteMap.TravelIcon); walking is this.
local WALK_ICON = "Interface\\Icons\\Ability_Rogue_Sprint"
local DISTANCE_ICON = "|TInterface\\Icons\\Ability_Tracking:13:13:0:0:64:64:5:59:5:59|t"
local TIME_ICON = "|TInterface\\Icons\\INV_Misc_PocketWatch_01:13:13:0:0:64:64:5:59:5:59|t"

-- A button's tooltip; `b.tip` can change later (the x says what it ends).
local function tooltip(b, text)
  b.tip = text
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self.tip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Blizzard's square button with an arrow (`arrow`: LEFT, RIGHT, ...) or an
-- icon file on it; a text button when this client lacks the template.
local function squareButton(parent, arrow, iconFile, fallback, onClick, tip)
  local b, templated = ns.Skin.Create("Button", nil, parent, "UIPanelSquareButton", "UIPanelButtonTemplate", { "icon" })
  b:SetSize(22, 22)
  if templated then
    if arrow and SquareButton_SetIcon then
      SquareButton_SetIcon(b, arrow)
    else
      b.icon:SetTexture(iconFile)
      b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      b.icon:SetSize(14, 14)
    end
  else
    b:SetText(fallback)
    ns.Skin.Button(b)
  end
  b:SetScript("OnClick", onClick)
  tooltip(b, tip)
  return b
end

-- Two of the square button's arrows side by side: fast forward. Our own
-- textures, so the template's press nudge (which re-anchors its icon) can't
-- pull them together; they're nudged the same way here.
local function fastForward(b)
  local icon = b.icon
  if not (icon and icon.GetTexCoord and icon:GetTexture()) then return end
  local coords = { icon:GetTexCoord() }
  local arrows = {}
  for i, dx in ipairs({ -3, 3 }) do
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetTexture(icon:GetTexture())
    t:SetTexCoord(unpack(coords))
    t:SetSize(icon:GetSize())
    t:SetPoint("CENTER", dx, 0)
    arrows[i] = { t, dx }
  end
  icon:SetAlpha(0)
  local function nudge(by)
    for _, a in ipairs(arrows) do
      a[1]:ClearAllPoints()
      a[1]:SetPoint("CENTER", a[2] + by, -by)
    end
  end
  b:HookScript("OnMouseDown", function(self) if self:IsEnabled() then nudge(-1) end end)
  b:HookScript("OnMouseUp", function() nudge(0) end)
  b.fastForward = arrows
end

local function create()
  local f = ns.Skin.CreateBox("WaywardHUD")
  f:SetSize(WIDTH, MIN_HEIGHT)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "hudPos")
    ns.Fire("HUD_MOVED")
  end)
  f:SetBackdropColor(0, 0, 0, 0.8)
  ns.RestorePosition(f, "hudPos", HOME)

  -- The arrow (or the stop's icon) in a dark circle, on its own frame: skins
  -- fade every texture of the box itself.
  local holder = CreateFrame("Frame", nil, f)
  f.holder = holder
  holder:SetSize(CIRCLE, CIRCLE)
  holder:SetPoint("TOPLEFT", PADDING, -PADDING)
  local circle = holder:CreateTexture(nil, "BACKGROUND")
  circle:SetAllPoints()
  circle:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
  circle:SetVertexColor(0, 0, 0, 0.55)
  f.arrow = holder:CreateTexture(nil, "ARTWORK")
  f.arrow:SetSize(CIRCLE - 4, CIRCLE - 4)
  f.arrow:SetPoint("CENTER")
  f.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
  f.icon = holder:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(CIRCLE - 8, CIRCLE - 8)
  f.icon:SetPoint("CENTER")
  if f.icon.SetMask then pcall(f.icon.SetMask, f.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  f.icon:Hide()

  -- Buttons top right: skip and move on (journeys), all stops, stop. No
  -- recalculate: the journey re-plans itself as you go (Navigator, liveCheck).
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetSize(24, 24)
  f.close:SetPoint("TOPRIGHT", -3, -3)
  f.close:SetScript("OnClick", function() ns.Nav.End() end)
  tooltip(f.close, "Stop directions")
  ns.Skin.CloseButton(f.close)
  f.list = squareButton(f, nil, "Interface\\Icons\\INV_Misc_Book_08", "=", function() ns.JourneyOverview.Toggle() end,
    "View details")
  f.list:SetPoint("RIGHT", f.close, "LEFT", -2, 0)
  -- A glow over the book button, pulsed when the journey gains stops (HUD.FlashJourney).
  f.listGlow = f.list:CreateTexture(nil, "OVERLAY")
  f.listGlow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  f.listGlow:SetBlendMode("ADD")
  f.listGlow:SetPoint("TOPLEFT", -2, 2)
  f.listGlow:SetPoint("BOTTOMRIGHT", 2, -2)
  f.listGlow:SetAlpha(0)
  f.moveOn = squareButton(f, "RIGHT", nil, ">>", function() ns.Nav.MoveOn() end, "Do this stop later")
  fastForward(f.moveOn)
  f.moveOn:SetPoint("RIGHT", f.list, "LEFT", -2, 0)
  f.skip = squareButton(f, nil, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "x", function() ns.Nav.Skip() end,
    "Skip this stop")
  f.skip:SetPoint("RIGHT", f.moveOn, "LEFT", -2, 0)
  -- PROTOTYPE: the shopping list's toggle, shown while the journey gathers
  -- something as you go. Hidden list: the button says how many things are
  -- still wanted. Open: the list pops up above the box (HUD.ToggleShop).
  f.shopToggle = squareButton(f, nil, SHOP_ICON, "$", function() HUD.ToggleShop() end, "Shopping list")
  f.shopToggle:SetPoint("RIGHT", f.skip, "LEFT", -2, 0)
  f.shopToggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(HUD.ShopOpen() and "Hide the shopping list" or "Show the shopping list")
    local n = frame and frame.shopCount or 0
    GameTooltip:AddLine(string.format("%d thing%s to gather as you go on this journey", n, n == 1 and "" or "s"),
      0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  f.shopToggle.count = f.shopToggle:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  f.shopToggle.count:SetPoint("BOTTOMRIGHT", 3, -3)
  f.shopToggle:Hide()
  -- The list itself: just the lines on a faint background, its bottom on the
  -- box's top edge (so it grows upward). Not part of the box: the box keeps
  -- its size. Hover it for where the rest are.
  f.shopList = CreateFrame("Frame", nil, f)
  f.shopList:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, SHOP_GAP)
  f.shopList:SetSize(WIDTH, 1)
  local shopBg = f.shopList:CreateTexture(nil, "BACKGROUND")
  shopBg:SetAllPoints()
  shopBg:SetColorTexture(0, 0, 0, SHOP_FADE)
  f.shopList.text = f.shopList:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.shopList.text:SetPoint("BOTTOMLEFT", SHOP_PAD, SHOP_PAD)
  f.shopList.text:SetJustifyH("LEFT")
  f.shopList.text:SetWordWrap(false)
  f.shopList.text:SetSpacing(2)
  f.shopList:EnableMouse(true)
  f.shopList:SetScript("OnEnter", function(self) HUD.ShowShopTooltip(self) end)
  f.shopList:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.shopList:Hide()
  -- Bottom right, beside the last line: add a detour (repair, mailbox, ...; UI/ErrandPicker.lua).
  f.add = squareButton(f, nil, "Interface\\Icons\\Spell_ChargePositive", "+", function() ns.ErrandPicker.Toggle() end,
    "Add a detour: repair, vendor, mailbox, bank...")
  f.add:SetSize(ADD_SIZE, ADD_SIZE)
  f.add:SetPoint("BOTTOMRIGHT", -6, 6)

  -- With the detail on "stops", the step is in a tooltip over the box.
  f:SetScript("OnEnter", function(self)
    local lines = HUD.StepTooltip()
    if not lines then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(lines[1])
    for i = 2, #lines do GameTooltip:AddLine(lines[i], 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", TEXT_LEFT, -PADDING - 2)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)

  -- Stops done, as a thin bar under the title (journeys only).
  f.progress = CreateFrame("StatusBar", nil, f)
  f.progress:SetHeight(4)
  f.progress:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -5)
  f.progress:SetPoint("RIGHT", -PADDING, 0)
  f.progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.progress:SetStatusBarColor(1, 0.82, 0)
  f.progress:SetMinMaxValues(0, 1)
  local track = f.progress:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(1, 1, 1, 0.12)

  f.step = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.step:SetPoint("RIGHT", -PADDING, 0)
  f.step:SetJustifyH("LEFT")
  f.step:SetWordWrap(true)

  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.sub:SetPoint("TOPLEFT", f.step, "BOTTOMLEFT", 0, -3)
  f.sub:SetPoint("RIGHT", -PADDING, 0)
  f.sub:SetJustifyH("LEFT")

  -- What a quest still needs, one objective a line, while you're doing it.
  f.objectives = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.objectives:SetPoint("RIGHT", -PADDING, 0)
  f.objectives:SetJustifyH("LEFT")
  f.objectives:SetSpacing(2)

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.info:SetPoint("TOPLEFT", f.sub, "BOTTOMLEFT", 0, -5)
  f.info:SetPoint("RIGHT", INFO_RIGHT, 0)
  f.info:SetJustifyH("LEFT")
  for _, fs in ipairs({ f.title, f.step, f.sub, f.objectives, f.info, f.shopList.text }) do ns.Skin.Text(fs) end

  local elapsed = 0
  f:SetScript("OnUpdate", function(_, dt)
    if f.flashLeft then
      f.flashLeft = f.flashLeft - dt
      if f.flashLeft > 0 then
        f.listGlow:SetAlpha(math.abs(math.sin(f.flashLeft / FLASH_PERIOD * math.pi)))
      else
        f.flashLeft = nil
        f.listGlow:SetAlpha(0)
      end
    end
    elapsed = elapsed + dt
    if elapsed >= UPDATE_INTERVAL then
      elapsed = 0
      local ok, err = pcall(HUD.Update)
      if not ok then
        -- Reported once, and the journey stops rather than failing ten times a second.
        pcall(ns.Nav.Stop)
        f:Hide()
        geterrorhandler()(err)
      end
    end
  end)
  ns.Skin.Box(f)
  return f
end

-- With the compass off there's no circle: the text starts at the edge and the
-- box is that much narrower.
local function applyCompass()
  local on = ns.db.settings.showArrow ~= false
  if frame.compass == on then return end
  frame.compass = on
  frame.holder:SetShown(on)
  frame.width = on and WIDTH or WIDTH - (TEXT_LEFT - PADDING)
  frame:SetWidth(frame.width)
  frame.title:ClearAllPoints()
  frame.title:SetPoint("TOPLEFT", on and TEXT_LEFT or PADDING, -PADDING - 2)
end

local function facing()
  local value = GetPlayerFacing and GetPlayerFacing()
  if value == nil or (type(issecretvalue) == "function" and issecretvalue(value)) then return nil end
  return value
end

-- The unfinished objectives of a quest in your log, e.g. { "4/8 Wolf Meat", "0/1 Wolf Pelt" }.
function HUD.Objectives(questID)
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  local out = {}
  for _, o in ipairs(objectives or {}) do
    if not o.finished and o.text then out[#out + 1] = o.text end
  end
  return out
end

-- The first unfinished objective of a quest in your log, e.g. "4/8 Wolf Meat".
function HUD.ObjectiveText(questID)
  return HUD.Objectives(questID)[1]
end

-- The objectives as the box's lines: as many as fit, then how many more.
local function objectiveLines(list)
  if #list <= MAX_OBJECTIVES then return table.concat(list, "\n") end
  local shown = {}
  for i = 1, MAX_OBJECTIVES - 1 do shown[i] = list[i] end
  shown[#shown + 1] = string.format("|cff9d9d9d+%d more|r", #list - #shown)
  return table.concat(shown, "\n")
end

-- Where the current step is among the steps to the next stop (a journey) or
-- to the destination: position and count.
local function legPosition(a)
  local steps = a.route.steps
  if not a.journey then return a.index, #steps end
  local first, last = 1, #steps
  for k = a.index - 1, 1, -1 do
    if steps[k].stop then first = k + 1 break end
  end
  for k = a.index, #steps do
    if steps[k].stop then last = k break end
  end
  return a.index - first + 1, last - first + 1
end

-- Lays the text out under the title, or under the progress bar on a journey.
local function place(trip)
  frame.progress:SetShown(trip)
  frame.step:ClearAllPoints()
  frame.step:SetPoint("TOPLEFT", trip and frame.progress or frame.title, "BOTTOMLEFT", 0, trip and -7 or -5)
  frame.step:SetPoint("RIGHT", -PADDING, 0)
  -- The title stops short of the buttons.
  local leftmost = trip and (frame.shopToggle:IsShown() and frame.shopToggle or frame.skip) or frame.close
  frame.title:SetPoint("RIGHT", leftmost, "LEFT", -6, 0)
end

---------------------------------------------------------------- shopping list (prototype)

local GREY = "|cff9d9d9d"

local function countText(e)
  return (e.have and e.need) and string.format("%d/%d", e.have, e.need) or nil
end

local function placeOf(node)
  if not (node and ns.Places) then return nil end
  local ok, place = pcall(ns.Places.NameFor, node)
  return ok and place or nil
end

-- "Goretusk  0/3 · Redridge Stew" around you; farther off, dimmer, and where
-- the nearest is when that has a name ("· near Lakeshire").
local function shopText(e)
  local count = countText(e)
  local where = ""
  if not e.near then
    local place = placeOf(e.node)
    where = place and ("  ·  near " .. place) or ""
  end
  return string.format("%s%s|r  %s%s%s%s|r", e.near and "|cffffffff" or "|cffb0b0b0", e.name, GREY,
    count and (count .. "  ·  ") or "", e.quest, where)
end

-- Whether the list is open (per character; hidden until you open it).
function HUD.ShopOpen()
  return ns.charDB ~= nil and ns.charDB.shopOpen == true
end

-- The list as lines, top to bottom: { text, entry } for up to SHOP_ROWS
-- things (around you first, then nearest: Journey.ShoppingList's order),
-- then { text, entries } for the rest. Empty when the journey gathers
-- nothing as you go.
function HUD.ShopLines(list)
  if not list then
    local a = ns.Nav.active
    list = a and a.journey and ns.Journey.ShoppingList(a.journey, ns.Geo.PlayerNode()) or {}
  end
  local lines, rest = {}, {}
  for _, e in ipairs(list) do
    if #lines < SHOP_ROWS then
      lines[#lines + 1] = { text = shopText(e), entry = e }
    else
      rest[#rest + 1] = e
    end
  end
  if #rest > 0 then
    lines[#lines + 1] = { text = string.format("%s+%d more|r", GREY, #rest), entries = rest }
  end
  return lines
end

-- Looks again at what's around you (every SHOP_EVERY seconds, or now when
-- `force`): the toggle shows while there's anything on the list, with the
-- count while it's hidden; the list sizes to its text, upward from the box.
local function refreshShop(a, force)
  local now = GetTime and GetTime()
  if not force and now and frame.shopAt and now - frame.shopAt < SHOP_EVERY then return end
  frame.shopAt = now
  local list = a and a.journey and ns.Journey.ShoppingList(a.journey, ns.Geo.PlayerNode()) or {}
  local open = #list > 0 and HUD.ShopOpen()
  frame.shopCount = #list
  frame.shopToggle:SetShown(#list > 0)
  frame.shopToggle.count:SetText((#list > 0 and not open) and tostring(#list) or "")
  if open and frame.shopToggle.LockHighlight then
    frame.shopToggle:LockHighlight()
  elseif frame.shopToggle.UnlockHighlight then
    frame.shopToggle:UnlockHighlight()
  end
  local lines = HUD.ShopLines(list)
  frame.shopLines = lines
  local texts = {}
  for i, line in ipairs(lines) do texts[i] = line.text end
  local text = frame.shopList.text
  text:SetWidth(0)
  text:SetText(table.concat(texts, "\n"))
  local maxWidth = (frame.width or WIDTH) - 2 * SHOP_PAD
  local width = text:GetStringWidth() or maxWidth
  if width > maxWidth then
    text:SetWidth(maxWidth)
    width = maxWidth
  end
  local height = text:GetStringHeight() or (#lines * SHOP_LINE)
  frame.shopHeight = open and (height + 2 * SHOP_PAD) or 0
  frame.shopList:SetSize(width + 2 * SHOP_PAD, math.max(frame.shopHeight, 1))
  frame.shopList:SetShown(open)
  -- Kept on screen with the box: its clamp counts the list.
  if frame.SetClampRectInsets then frame:SetClampRectInsets(0, 0, open and (frame.shopHeight + SHOP_GAP) or 0, 0) end
end

function HUD.ToggleShop()
  if not ns.charDB then return end
  ns.charDB.shopOpen = not HUD.ShopOpen() or nil
  if frame and ns.Nav.active then refreshShop(ns.Nav.active, true) end
end

-- The toggle and the list, for tests: { toggle, count, open, lines, height }.
function HUD.Shop()
  if not frame then return {} end
  local texts = {}
  for i, line in ipairs(frame.shopLines or {}) do texts[i] = line.text end
  return { toggle = frame.shopToggle:IsShown(), count = frame.shopToggle.count:GetText() or "",
    open = frame.shopList:IsShown(), lines = texts, height = frame.shopHeight or 0 }
end

-- Hovering the list: what's around you, and where the rest are.
function HUD.ShowShopTooltip(owner)
  local lines = frame and frame.shopLines or {}
  if #lines == 0 or not GameTooltip then return end
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  GameTooltip:SetText("Shopping list", 1, 1, 1)
  for _, line in ipairs(lines) do
    if line.entry then
      local e = line.entry
      local place = not e.near and placeOf(e.node)
      GameTooltip:AddLine(string.format("%s  %s%s|r", e.name, GREY, e.near and "around you" or place and ("near " .. place)
        or "farther off"), 0.9, 0.9, 0.9, true)
    elseif line.entries then
      for _, e in ipairs(line.entries) do
        local place = placeOf(e.node)
        GameTooltip:AddLine(string.format("%s%s  %s%s|r", e.name, countText(e) and (" " .. countText(e)) or "", GREY,
          place and ("near " .. place) or "elsewhere"), 0.8, 0.8, 0.8, true)
      end
    end
  end
  GameTooltip:AddLine("The journey takes you through these when they're on the way; it carries on whenever you do.",
    0.5, 0.82, 0.68, true)
  GameTooltip:Show()
end

-- The step and its count, for the tooltip when the box shows only the stop
-- (nil when it shows them itself).
function HUD.StepTooltip()
  if not (frame and frame.stepHidden) then return nil end
  return { frame.stepText, frame.subText ~= "" and frame.subText or nil }
end

function HUD.Update()
  if not frame then return end
  local here, step = ns.Nav.Tick()
  local a = ns.Nav.active
  if not (a and step) then
    frame:Hide()
    return
  end
  applyCompass()
  local trip = a.journey ~= nil
  frame.list:SetShown(trip)
  frame.moveOn:SetShown(trip)
  frame.skip:SetShown(trip)
  frame.close.tip = trip and "End journey" or "Stop directions"
  refreshShop(a)
  place(trip)

  -- One count each: stops done in the title, steps to the next stop (or to
  -- the destination) under the step, only when there's more than one.
  local progress = ns.Nav.Progress()
  if trip then
    frame.title:SetText(string.format("%s  |cff9d9d9d%d of %d done|r", progress.title or "", progress.done,
      progress.total))
    frame.progress:SetValue(progress.total > 0 and progress.done / progress.total or 0)
  else
    frame.title:SetText(a.title or "")
  end
  local position, count = legPosition(a)
  frame.stepText = ns.Router.Describe(a.route, a.index)
  frame.subText = count > 1 and string.format(trip and "Step %d of %d to get there" or "Step %d of %d", position, count)
    or ""
  -- Detail on demand: just the stop (and the compass), the step on hover.
  frame.stepHidden = ns.Nav.Detail() == "stops" and frame.stepText ~= progress.stopText
  local sub = frame.stepHidden and "" or frame.subText
  -- Gathering where you are (prototype): what for, and what's next once it's done.
  local gatherHere = ns.Nav.GatheringHere()
  if gatherHere then
    local q = ns.Quests.Quest(gatherHere.area.stop.action.questID)
    frame.stepText = "Gather here for " .. (q and q.name or "your quest")
    frame.stepHidden = false
    sub = "Then: " .. (gatherHere.stop.text or "the hand-in")
  end
  frame.step:SetText(frame.stepHidden and progress.stopText or frame.stepText)
  frame.sub:SetText(sub)

  -- A quest's objectives get their own lines between the step and the status.
  -- So does a hand-in still waiting on gathering: what it still needs.
  local gathering = ns.Journey.WaitsOnGathering(step.stop)
  local objectives = step.stop and step.stop.action and (step.stop.action.kind == "complete" or gathering)
    and HUD.Objectives(step.stop.action.questID) or {}
  local objective = objectives[1]
  local above = sub ~= "" and frame.sub or frame.step
  frame.objectives:SetText(objectiveLines(objectives))
  frame.objectives:SetShown(objective ~= nil)
  frame.objectives:ClearAllPoints()
  frame.objectives:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -5)
  frame.objectives:SetPoint("RIGHT", -PADDING, 0)
  frame.info:ClearAllPoints()
  frame.info:SetPoint("TOPLEFT", objective and frame.objectives or above, "BOTTOMLEFT", 0, -5)
  frame.info:SetPoint("RIGHT", INFO_RIGHT, 0)

  local distance = here and ns.Geo.Distance(here, step.to) or math.huge
  local remaining = TIME_ICON .. " " .. ns.FormatDuration(ns.Nav.RemainingSeconds(here))
  if gatherHere then
    -- Nothing waits for you here: walk on whenever you like.
    frame.info:SetText(string.format("|cff7fd1aeGathering here|r  ·  %s to go at your pace     %s",
      ns.FormatDuration(gatherHere.seconds), remaining))
  elseif objective and ns.Nav.InArea() then
    -- Among what you need: no arrow, just how it's going (and how long, at your pace here).
    if ns.Camps.LooksCleared(step.stop) then
      frame.info:SetText("|cffffd100Camp looks cleared|r     " .. remaining)
    else
      local left = ns.Camps.TimeLeft(step.stop)
      frame.info:SetText("|cff7fd1aeIn the area|r"
        .. (left and ("  ·  " .. ns.FormatDuration(left) .. " left here") or "") .. "     " .. remaining)
    end
  elseif objective and not gathering then
    -- On the way from a spot you've cleared to the next, or back to one respawning.
    local respawn = ns.Journey.RespawnIn(step.stop)
    local lead = respawn > 0 and ("|cff9d9d9dRespawns in " .. ns.FormatDuration(respawn) .. "|r     ")
      or ns.Journey.ClearedAreas(step.stop) > 0 and "|cff9d9d9dNext spot|r     " or ""
    frame.info:SetText(lead .. remaining)
  elseif ns.Nav.Interaction() == "fly" then
    frame.info:SetText(string.format("Pick %s on the flight map     %s", step.to.label or "your destination", remaining))
  elseif ns.Nav.Interaction() == "hearth" then
    frame.info:SetText(string.format("Use your Hearthstone     %s", remaining))
  elseif ns.Nav.Interaction() == "use" then
    frame.info:SetText(string.format("|cff7fd1aeYou're here:|r use %s     %s", (ns.Nav.TargetObject()), remaining))
  elseif ns.Nav.Interaction() == "enter" then
    frame.info:SetText("|cff7fd1aeYou're here:|r go in     " .. remaining)
  elseif ns.Nav.Interaction() == "talk" and not (step.stop and step.stop.action and step.stop.action.kind == "manual") then
    local name = ns.Nav.TargetNPC()
    local kind = step.stop and step.stop.action and step.stop.action.kind
    frame.info:SetText(string.format("|cff7fd1aeYou're here:|r talk to %s%s     %s", name or "them",
      kind == "train" and " and train it" or kind == "learn" and " and train your spells" or "", remaining))
  elseif ns.Nav.Waiting() then
    -- A quest step only you can tell is done; spells to train.
    local kind = step.stop and step.stop.action and step.stop.action.kind
    frame.info:SetText((kind == "manual" and "|cff7fd1aeYou're here:|r do it, then move on (>>)"
      or kind == "learn" and "|cff7fd1aeYou're here:|r train your spells" or "|cff7fd1aeYou're here|r")
      .. "     " .. remaining)
  elseif distance < math.huge and step.mode == "walk" then
    frame.info:SetText(string.format("%s %d yd     %s", DISTANCE_ICON, math.floor(distance), remaining))
  else
    frame.info:SetText(remaining)
  end

  -- Grow to fit the text (titles and steps can wrap).
  local function height(fs) return fs:GetStringHeight() or 12 end
  local subHeight = sub ~= "" and (3 + height(frame.sub)) or 0
  local objectivesHeight = objective and (5 + height(frame.objectives)) or 0
  frame:SetHeight(math.max(MIN_HEIGHT, PADDING * 2 + height(frame.title) + (trip and 16 or 5) + height(frame.step)
    + subHeight + objectivesHeight + 5 + height(frame.info)))

  local heading = facing()
  -- The compass points the way while you walk; otherwise its circle shows what's ahead.
  if step.mode == "walk" and distance < math.huge and heading and not ns.Nav.Waiting() and not ns.Nav.Flying()
      and not gatherHere then
    frame.arrow:SetRotation(ns.Geo.Bearing(here, step.to) - heading)
    frame.arrow:Show()
    frame.icon:Hide()
  else
    frame.arrow:Hide()
    local action = (step.stop or {}).action
    local kind = gatherHere and "complete" or action and action.kind
    frame.icon:SetTexture(kind and STOP_ICONS[kind] or ns.RouteMap.TravelIcon(step) or WALK_ICON)
    frame.icon:Show()
  end
end

-- Whether the compass arrow shows right now (for tests).
function HUD.ArrowShown() return frame ~= nil and frame.arrow:IsShown() end

-- The directions box (the target button sits beside it).
function HUD.Frame() return frame end

-- The box, made (hidden) if there isn't one yet: edit modes move it anyway.
function HUD.EnsureFrame()
  if not frame then
    frame = create()
    if not ns.Nav.active then frame:Hide() end
  end
  return frame
end

ns.Movers.Add({ key = "Directions", label = "Directions", posKey = "hudPos", home = HOME,
  frame = HUD.EnsureFrame, moved = function() ns.Fire("HUD_MOVED") end })

-- Whether the compass circle shows, and the box's width (for tests).
function HUD.CompassShown() return frame ~= nil and frame.holder:IsShown() end
function HUD.Width() return frame and frame.width end

-- The directions box's text: title, step, step count, status line, then the
-- objectives (shown between the step and the status; for tests).
function HUD.Lines()
  if not frame then return {} end
  return { frame.title:GetText(), frame.step:GetText(), frame.sub:GetText(), frame.info:GetText(),
    frame.objectives:IsShown() and frame.objectives:GetText() or "" }
end

-- Pulses the book button a few times: the journey has changed, its overview is a click away.
function HUD.FlashJourney()
  if frame then frame.flashLeft = FLASH_PERIOD * FLASH_PULSES end
end

-- Whether the book button is pulsing (for tests).
function HUD.Flashing() return frame ~= nil and frame.flashLeft ~= nil end

ns.Listen("SETTINGS_CHANGED", function(key)
  if (key == "showArrow" or key == "detail") and frame then HUD.Update() end
end)

-- The shopping list's counts: looked at again on the next update.
ns.On("QUEST_LOG_UPDATE", function() if frame then frame.shopAt = nil end end)

ns.Listen("JOURNEY_EXTENDED", function()
  if not ns.JourneyOverview.IsShown() then HUD.FlashJourney() end
end)

ns.Listen("NAV_CHANGED", function()
  if ns.Nav.active then
    frame = frame or create()
    frame:Show()
    HUD.Update()
  elseif frame then
    frame:Hide()
  end
end)
