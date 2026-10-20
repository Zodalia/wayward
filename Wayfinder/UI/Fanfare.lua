local _, ns = ...

-- Fanfare. Two frames near the top of the screen:
--   * when a trip is done: what it came to (XP earned, time taken, distance
--     travelled, quests handed in);
--   * when For you has a new major suggestion (a questing zone, a dungeon,
--     new spells, a profession's next rank): "New journey available", which
--     you click to start it (or add it to your trip: the usual question).
-- Both fade after a while (not while the mouse is over them); a click on the
-- first, or the toast's x, closes it. /wf toasts or the options turn the
-- new-journey toasts off. Their sounds: Sounds.lua (/wf sounds).

local Fanfare = {}
ns.Fanfare = Fanfare

local TRIP_SECONDS, TOAST_SECONDS, FADE = 12, 8, 1
local GOLD = { 1, 0.82, 0 }

-- Fades `f` after `seconds` on screen, unless the mouse is over it.
local function fadeAfter(f, seconds)
  f.left = seconds
  f:SetAlpha(1)
  f:SetScript("OnUpdate", function(self, dt)
    if self.IsMouseOver and self:IsMouseOver() then
      self.left = math.max(self.left, FADE)
      self:SetAlpha(1)
      return
    end
    self.left = self.left - dt
    if self.left <= 0 then
      self:SetScript("OnUpdate", nil)
      self:Hide()
      if self.onDone then self.onDone() end
    elseif self.left < FADE then
      self:SetAlpha(self.left / FADE)
    end
  end)
end

local function stat(parent, label, x)
  local l = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  l:SetPoint("TOP", parent, "TOPLEFT", x, -64)
  local v = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  v:SetPoint("TOP", l, "BOTTOM", 0, -3)
  l:SetText(string.upper(label))
  return v
end

---------------------------------------------------------------- trip done

local trip

local function createTrip()
  local f = ns.Skin.CreateBox("WayfinderTripFanfare")
  f:SetSize(380, 112)
  f:SetPoint("TOP", UIParent, "TOP", 0, -150)
  f:SetFrameStrata("HIGH")
  f:SetBackdropColor(0, 0, 0, 0.85)
  f:EnableMouse(true)
  f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.heading:SetPoint("TOP", 0, -12)
  f.heading:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.title:SetPoint("TOP", f.heading, "BOTTOM", 0, -4)
  f.title:SetWidth(350)
  f.title:SetWordWrap(false)
  f.xp = stat(f, "XP earned", 56)
  f.time = stat(f, "Time", 146)
  f.distance = stat(f, "Distance", 236)
  f.quests = stat(f, "Quests", 326)
  f:SetScript("OnMouseUp", function(self) self:Hide() end)
  ns.Skin.Box(f)
  f:Hide()
  return f
end

local function number(n)
  local s = tostring(math.floor((n or 0) + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (s:gsub("^,", ""))
end

-- `sound`: a sound kit instead of the chosen one (for /wf sounds test).
local function showTrip(stats, sound)
  trip = trip or createTrip()
  trip.heading:SetText("Journey complete!")
  trip.title:SetText(stats.title or "")
  trip.xp:SetText(number(stats.xp))
  trip.time:SetText(ns.FormatDuration(stats.seconds))
  trip.distance:SetText(number(stats.distance) .. " yd")
  trip.quests:SetText(tostring(stats.quests or 0))
  trip:Show()
  fadeAfter(trip, TRIP_SECONDS)
  ns.Sounds.Play("complete", sound)
end

-- stats: { title, xp, seconds, distance (yards), quests }
function Fanfare.TripDone(stats)
  showTrip(stats)
  Fanfare.lastTrip = stats
end

---------------------------------------------------------------- new journeys

local toast
local queue = {}

local function createToast()
  local f = ns.Skin.CreateBox("WayfinderJourneyToast")
  f:SetSize(320, 64)
  f:SetPoint("TOP", UIParent, "TOP", 0, -96)
  f:SetFrameStrata("HIGH")
  f:SetBackdropColor(0, 0, 0, 0.85)
  f:EnableMouse(true)
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(40, 40)
  f.icon:SetPoint("LEFT", 12, 0)
  if f.icon.SetMask then pcall(f.icon.SetMask, f.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
  f.sheetIcon = f:CreateTexture(nil, "ARTWORK")
  f.sheetIcon:SetSize(40, 40)
  f.sheetIcon:SetPoint("LEFT", 12, 0)
  f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.heading:SetPoint("TOPLEFT", 62, -10)
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
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetSize(22, 22)
  f.close:SetPoint("TOPRIGHT", -2, -2)
  f.close:SetScript("OnClick", function() f:Hide(); if f.onDone then f.onDone() end end)
  -- Click: start it, or add it to your trip (the usual question when one is on).
  f:SetScript("OnMouseUp", function(self)
    local r = self.result
    self:Hide()
    if r and not r.preview then ns.Panel.Activate(r) end
    if self.onDone then self.onDone() end
  end)
  f:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(self.result and self.result.title or "")
    GameTooltip:AddLine(self.result and self.result.preview and "A sound test: clicking it starts nothing"
      or ns.Nav.active and "Click to add it to your trip, or start it instead" or "Click to start it", 0.5, 0.8, 0.7)
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
  local r = table.remove(queue, 1)
  if not r then return end
  toast = toast or createToast()
  toast.result = r
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
  toast.onDone = showNext
  toast:Show()
  fadeAfter(toast, TOAST_SECONDS)
  ns.Sounds.Play("toast", r.previewSound)
end

-- Shows "New journey available" for `r` (queued behind one on screen).
function Fanfare.NewJourney(r)
  if ns.db.settings.toasts == false then return end
  queue[#queue + 1] = r
  Fanfare.lastNew = r
  if not (toast and toast:IsShown()) then showNext() end
end

-- /wf sounds test: the banner or the toast ("trip" or "toast") with sample
-- text, playing `sound` (a sound kit) or the chosen one. The sample toast is
-- shown straight away (one on screen comes back after it) and starts nothing.
function Fanfare.Preview(kind, sound)
  if kind == "trip" then
    return showTrip({ title = "Sample journey", xp = 1250, seconds = 754, distance = 2310, quests = 3 }, sound)
  end
  local r = { preview = true, previewSound = sound, title = "Sample journey", category = "Questing zone",
    place = "Westfall", icon = "Interface\\Icons\\INV_Misc_Map_01" }
  if toast and toast:IsShown() and toast.result and not toast.result.preview then
    table.insert(queue, 1, toast.result)
  end
  table.insert(queue, 1, r)
  showNext()
end

ns.RegisterCommand("toasts", "/wf toasts - the 'new journey available' toasts on or off", function()
  ns.SetSetting("toasts", ns.db.settings.toasts == false)
  ns.print("new journey toasts " .. (ns.db.settings.toasts == false and "off" or "on"))
end)
