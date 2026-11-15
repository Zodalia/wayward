local _, ns = ...

-- Fanfare. Two frames near the top of the screen:
--   * when a journey is done: what it came to, as the 2 to 4 stats that
--     stand out most (levels, quests handed in, gold, XP, ... ; time and
--     distance fill in when there's little else), under its title and icon;
--     the same, headed "Journey ended", when you end one that came to
--     something before its end;
--   * when For you has a new major suggestion (a questing zone, a dungeon,
--     a profession's next rank): "New journey available", which
--     you click to start it (or add it as a detour, or switch to it: the
--     usual question); a few seconds after a journey is done, the same toast
--     says "Up next" with For you's top card.
-- Both fade after a while (not while the mouse is over them), with the
-- notes' draining time bar behind them, and both have the notes' x
-- (Snackbar.CloseButton). A click on the banner closes it too; the toast has
-- a labelled button ("Start journey"), and a click on the rest of it does
-- the same, as a card's does. /ww toasts or the options turn the
-- new-journey toasts off. Their sounds: Sounds.lua (/ww sounds).

local Fanfare = {}
ns.Fanfare = Fanfare

local TRIP_SECONDS, TOAST_SECONDS, FADE = 12, 8, 1
local GOLD = { 1, 0.82, 0 }
local TRIP_HOME = { "TOP", "TOP", 0, -150 }
local TOAST_HOME = { "TOP", "TOP", 0, -96 }

local PAD = 10 -- the notes' padding (Snackbar.PAD; that file loads after this one)

-- Fades `f` after `seconds` on screen, unless the mouse is over it (which
-- holds its time bar too).
local function fadeAfter(f, seconds)
  f.left, f.total = seconds, seconds
  f:SetAlpha(1)
  if f.bar then ns.Snackbar.DrawTimeBar(f.bar, f, 1) end
  f:SetScript("OnUpdate", function(self, dt)
    if self.IsMouseOver and self:IsMouseOver() then
      self.left = math.max(self.left, FADE)
      self:SetAlpha(1)
      if self.bar then ns.Snackbar.DrawTimeBar(self.bar, self, self.left / self.total) end
      return
    end
    self.left = self.left - dt
    if self.bar then ns.Snackbar.DrawTimeBar(self.bar, self, self.left / self.total) end
    if self.left <= 0 then
      self:SetScript("OnUpdate", nil)
      self:Hide()
      if self.onDone then self.onDone() end
    elseif self.left < FADE then
      self:SetAlpha(self.left / FADE)
    end
  end)
end

local function stat(parent)
  local l = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  local v = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  v:SetPoint("TOP", l, "BOTTOM", 0, -3)
  return { label = l, value = v }
end

---------------------------------------------------------------- journey done

local trip
local TRIP_WIDTH, MAX_STATS, MIN_STATS = 380, 4, 2

local function number(n)
  local s = tostring(math.floor((n or 0) + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (s:gsub("^,", ""))
end

local function xpRef()
  local max = UnitXPMax and UnitXPMax("player")
  return max and max > 0 and max / 10 or 1000
end

-- The stats a journey can show, most important first: { key, label, priority,
-- ref, format }. `ref` is a good amount (a number, or a function for one that
-- depends on your level): a stat scores its priority at `ref`, more for more
-- (up to twice at four times `ref`), less for less. Time and distance are
-- always there, but score low: they show only when there's little else.
local STATS = {
  { "levels", "Levels", 100, 1, function(n) return "+" .. n end },
  { "quests", "Quests done", 70, 3, tostring },
  { "ranks", "Ranks trained", 65, 1, tostring },
  { "flights", "Flight paths", 55, 1, tostring },
  { "money", "Money", 50, 10000, function(n) return ns.FormatMoney(n) end },
  { "picked", "Quests taken", 45, 3, tostring },
  { "stops", "Stops done", 42, 3, tostring }, -- only for a journey ended early
  { "xp", "XP earned", 40, xpRef, number },
  { "distance", "Distance", 12, 500, function(n) return number(n) .. " yd" end },
  { "seconds", "Time", 10, 300, function(n) return ns.FormatDuration(n) end },
}

-- The stats worth showing for a journey, best first: { key, label, text, score },
-- 2 to 4 of them (fewer only when the journey has less: an instant arrival).
function Fanfare.Highlights(stats)
  local out = {}
  for order, s in ipairs(STATS) do
    local amount = tonumber(stats[s[1]]) or 0
    if amount >= 1 then
      local ref = type(s[4]) == "function" and s[4]() or s[4]
      local score = s[3] * math.sqrt(math.min(amount / ref, 4))
      out[#out + 1] = { key = s[1], label = s[2], text = s[5](amount), score = score, order = order }
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.order < b.order
  end)
  -- Time and distance only to make up the minimum.
  local picked, fillers = {}, {}
  for _, h in ipairs(out) do
    if h.key == "seconds" or h.key == "distance" then fillers[#fillers + 1] = h else picked[#picked + 1] = h end
  end
  for _, h in ipairs(fillers) do
    if #picked < MIN_STATS then picked[#picked + 1] = h end
  end
  while #picked > MAX_STATS do table.remove(picked) end
  return picked
end

local function createTrip()
  local f = ns.Skin.CreateBox("WaywardTripFanfare")
  f:SetSize(TRIP_WIDTH, 112)
  ns.RestorePosition(f, "tripPos", TRIP_HOME)
  f:SetFrameStrata("HIGH")
  f:SetBackdropColor(0, 0, 0, 0.85)
  f:EnableMouse(true)
  f.bar = ns.Snackbar.TimeBar(f)
  f.close = ns.Snackbar.CloseButton(f, function() f:Hide() end, "Close")
  f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.heading:SetPoint("TOP", 0, -PAD - 2)
  f.heading:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.title:SetPoint("TOP", f.heading, "BOTTOM", 0, -4)
  f.title:SetWidth(350)
  f.title:SetWordWrap(false)
  f.stats = {}
  for i = 1, MAX_STATS do f.stats[i] = stat(f) end
  f:SetScript("OnMouseUp", function(self) self:Hide() end)
  ns.Skin.Box(f)
  f:Hide()
  return f
end

-- `sound`: a sound kit instead of the chosen one (for /ww sounds test).
local function showTrip(stats, sound)
  trip = trip or createTrip()
  trip.heading:SetText(stats.ended and "Journey ended" or "Journey complete!")
  -- The journey's icon (its kind) before its title.
  trip.title:SetText((stats.icon and ("|T" .. stats.icon .. ":16:16|t ") or "") .. (stats.title or ""))
  local shown = Fanfare.Highlights(stats)
  for i, slot in ipairs(trip.stats) do
    local h = shown[i]
    if h then
      -- Evenly spread across the banner, however many there are.
      slot.label:ClearAllPoints()
      slot.label:SetPoint("TOP", trip, "TOPLEFT", TRIP_WIDTH * (i - 0.5) / #shown, -64)
      slot.label:SetText(string.upper(h.label))
      slot.value:SetText(h.text)
      slot.label:Show()
      slot.value:Show()
    else
      slot.label:Hide()
      slot.value:Hide()
    end
  end
  Fanfare.lastShown = shown
  trip:Show()
  fadeAfter(trip, TRIP_SECONDS)
  ns.Sounds.Play("complete", sound)
end

-- The banner frame, or nil before the first (for tests).
function Fanfare.TripFrame() return trip end

-- stats: { title, kind, icon, xp, seconds, distance (yards), quests (handed
-- in), picked, levels, money (copper), flights, ranks }; a journey ended
-- before its end also has `ended` and `stops` (the stops done).
function Fanfare.TripDone(stats)
  showTrip(stats)
  Fanfare.lastTrip = stats
end

---------------------------------------------------------------- new journeys

local toast
local queue = {}

-- The toast frame, or nil before the first (for tests).
function Fanfare.ToastFrame() return toast end

local TOAST_ICON, TOAST_BUTTON_HEIGHT = 40, 20

-- Runs the toast's suggestion (start it, or the usual question on a
-- journey) and moves on to the next toast.
local function takeToast(f)
  local r = f.result
  f:Hide()
  if r and not r.preview then ns.Panel.Activate(r) end
  if f.onDone then f.onDone() end
end

local function createToast()
  local f = ns.Skin.CreateBox("WaywardJourneyToast")
  f:SetSize(320, 64 + TOAST_BUTTON_HEIGHT + 6)
  ns.RestorePosition(f, "toastPos", TOAST_HOME)
  f:SetFrameStrata("HIGH")
  f:SetBackdropColor(0, 0, 0, 0.85)
  f:EnableMouse(true)
  f.bar = ns.Snackbar.TimeBar(f)
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(TOAST_ICON, TOAST_ICON)
  f.icon:SetPoint("TOPLEFT", PAD, -PAD)
  if f.icon.SetMask then pcall(f.icon.SetMask, f.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  f.sheetIcon = f:CreateTexture(nil, "ARTWORK")
  f.sheetIcon:SetSize(TOAST_ICON, TOAST_ICON)
  f.sheetIcon:SetPoint("TOPLEFT", PAD, -PAD)
  f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.heading:SetPoint("TOPLEFT", PAD + TOAST_ICON + PAD, -PAD)
  f.heading:SetText("New journey available")
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.title:SetPoint("TOPLEFT", f.heading, "BOTTOMLEFT", 0, -3)
  f.title:SetPoint("RIGHT", -28, 0)
  f.title:SetJustifyH("LEFT")
  f.title:SetWordWrap(false)
  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
  f.sub:SetPoint("RIGHT", -28, 0)
  f.sub:SetJustifyH("LEFT")
  f.sub:SetWordWrap(false)
  f.close = ns.Snackbar.CloseButton(f, function() f:Hide(); if f.onDone then f.onDone() end end, "Not now")
  -- The labelled action, bottom right as on a note: start it (or, with a
  -- journey on, the usual question: add it as a detour or switch to it).
  f.go = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.go:SetSize(104, TOAST_BUTTON_HEIGHT)
  f.go:SetPoint("BOTTOMRIGHT", -PAD, PAD - 2)
  f.go:SetScript("OnClick", function() takeToast(f) end)
  ns.Skin.Button(f.go)
  -- A click on the rest of it does the same, as a suggestion card's does.
  f:SetScript("OnMouseUp", function(self) takeToast(self) end)
  f:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(self.result and self.result.title or "")
    GameTooltip:AddLine(self.result and self.result.preview and "A sound test: clicking it starts nothing"
      or ns.Nav.active and "Click to add it to your journey as a detour, or switch to it" or "Click to start it",
      0.5, 0.8, 0.7)
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.Skin.CloseButton(f.close)
  ns.Skin.Box(f)
  f:Hide()
  return f
end

local function plain(text)
  return ((text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function showNext()
  local item = table.remove(queue, 1)
  if not item then return end
  local r = item.result
  toast = toast or createToast()
  toast.result = r
  toast.heading:SetText(item.heading or "New journey available")
  toast.title:SetText(plain(r.title))
  toast.sub:SetText(plain(r.category and (r.category .. "  ·  " .. (r.place or r.subtitle or "")) or r.subtitle))
  if r.iconCoords then
    toast.sheetIcon:SetTexture(r.icon)
    toast.sheetIcon:SetTexCoord((unpack or table.unpack)(r.iconCoords))
    toast.sheetIcon:Show()
    toast.icon:Hide()
  else
    toast.icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_Map_01")
    toast.icon:Show()
    toast.sheetIcon:Hide()
  end
  toast.go:SetText("Start journey")
  toast.go:SetEnabled(not r.preview)
  toast.onDone = showNext
  toast:Show()
  fadeAfter(toast, TOAST_SECONDS)
  ns.Sounds.Play("toast", r.previewSound)
end

-- Shows "New journey available" for `r` (queued behind one on screen).
-- On a journey it doesn't pop up over what you're doing: it's a row on the
-- directions box's drawer instead (Wayside.Offer), to add or wave off.
function Fanfare.NewJourney(r)
  if ns.db.settings.toasts == false then return end
  Fanfare.lastNew = r
  if ns.Wayside and ns.Wayside.Offer(r) then
    Fanfare.lastOffered = r
    return
  end
  queue[#queue + 1] = { result = r }
  if not (toast and toast:IsShown()) then showNext() end
end

-- Shows "Up next" for `r` (For you's top card after a journey), ahead of any
-- "New journey available" still waiting. Never over the "Journey complete!"
-- banner: it waits until the banner is gone, and a moment more.
local UP_NEXT_GAP = 1

function Fanfare.UpNext(r)
  if ns.db.settings.suggestNext == false then return end
  if trip and trip:IsShown() then
    Fanfare.waitingUpNext = r
    return ns.After(UP_NEXT_GAP, function()
      -- Not if you've set off on something else meanwhile.
      if Fanfare.waitingUpNext == r and not ns.Nav.active then Fanfare.UpNext(r) end
    end)
  end
  Fanfare.waitingUpNext = nil
  table.insert(queue, 1, { result = r, heading = "Up next" })
  Fanfare.lastUpNext = r
  if not (toast and toast:IsShown()) then showNext() end
end

-- /ww sounds test: the banner or the toast ("trip" or "toast") with sample
-- text, playing `sound` (a sound kit) or the chosen one. The sample toast is
-- shown straight away (one on screen comes back after it) and starts nothing.
function Fanfare.Preview(kind, sound)
  if kind == "trip" then
    return showTrip({ title = "Sample journey", xp = 1250, seconds = 754, distance = 2310, quests = 3, picked = 2,
      money = 41250 }, sound)
  end
  local r = { preview = true, previewSound = sound, title = "Sample journey", category = "Questing zone",
    place = "Westfall", icon = "Interface\\Icons\\INV_Misc_Map_01" }
  if toast and toast:IsShown() and toast.result and not toast.result.preview then
    table.insert(queue, 1, { result = toast.result, heading = toast.heading:GetText() })
  end
  table.insert(queue, 1, { result = r })
  showNext()
end

-- Edit modes move the banner and the toast while they're hidden.
ns.Movers.Add({ key = "TripDone", label = "Journey complete", posKey = "tripPos", home = TRIP_HOME,
  frame = function() trip = trip or createTrip(); return trip end })
ns.Movers.Add({ key = "NewJourney", label = "New journey toast", posKey = "toastPos", home = TOAST_HOME,
  frame = function() toast = toast or createToast(); return toast end,
  hidden = function() return ns.db.settings.toasts == false end })

ns.RegisterCommand("toasts", "/ww toasts - the 'new journey available' toasts on or off", function()
  ns.SetSetting("toasts", ns.db.settings.toasts == false)
  ns.print("new journey toasts " .. (ns.db.settings.toasts == false and "off" or "on"))
end)
