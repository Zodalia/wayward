local _, ns = ...

-- Your Wayward profile: the things that make its suggestions and routes as
-- good as they get (a flight map opened here, your class trainer, your
-- Hearthstone, the quest data), as a percentage with the next step, in the
-- main window under the cards (Panel.lua). Hover it for the whole list.
-- At 100% it shows a tick for the rest of that session and is gone from the
-- next one on (ns.charDB.profileComplete); /ww profile still lists it.

local Profile = {}
ns.Profile = Profile

local BAR_WIDTH = 120
local GREEN = { 0.25, 0.85, 0.3 }
local TICK = "Interface\\RaidFrame\\ReadyCheck-Ready"

local function currentContinent()
  local here = ns.Geo.PlayerNode()
  return here and ns.Geo.Continents()[here.instance]
end

-- The steps, in the order they're worth doing: { key, label, how, done() }.
local STEPS = {
  { "flights", "Flight paths",
    function()
      local continent = currentContinent()
      return continent and string.format("Open any flight master's map in %s, so routes can fly.", ns.MapName(continent))
        or "Open any flight master's map, so routes can fly."
    end,
    function()
      if next(ns.charDB.knownTaxi or {}) == nil then return false end
      local continent = currentContinent()
      return not continent or ns.Harvest.FlightsKnownOn(continent)
    end },
  { "trainer", "Class trainer",
    function() return "Talk to your class trainer once, so Wayward knows the spells you can learn." end,
    function() return ns.charDB.classSpells ~= nil end },
  { "hearth", "Hearthstone",
    function() return "Set your Hearthstone at an inn (or use it once), so trips can use it." end,
    function() return ns.Hearth.Node() ~= nil end },
  { "quests", "Quest data",
    function() return "Install " .. ns.Data.ADDON .. " for quests, items and every trainer." end,
    function() return ns.Data.Has("Quest") and true or false end },
}

-- { percent, done, total, steps = { {key, label, how, done}, ... }, next (first step not done) }
function Profile.State()
  local state = { steps = {}, done = 0, total = #STEPS }
  for _, s in ipairs(STEPS) do
    local ok, done = pcall(s[4])
    local step = { key = s[1], label = s[2], how = s[3](), done = ok and done or false }
    state.steps[#state.steps + 1] = step
    if step.done then
      state.done = state.done + 1
    elseif not state.next then
      state.next = step
    end
  end
  state.percent = math.floor(state.done / state.total * 100 + 0.5)
  return state
end

-- This session (a login or /reload): the strip stays, with its tick, for the
-- rest of the session it reached 100% in, and is gone from the next.
Profile.session = tostring(time and time() or 0) .. "-" .. tostring(math.random(1e6))

function Profile.Visible()
  if not ns.charDB then return false end
  local complete = ns.charDB.profileComplete
  return not complete or complete == Profile.session
end

---------------------------------------------------------------- the strip

local strip

local function tooltip(owner)
  local state = Profile.State()
  GameTooltip:SetOwner(owner, "ANCHOR_TOP")
  GameTooltip:SetText(string.format("Your Wayward profile: %d%%", state.percent))
  GameTooltip:AddLine("The more Wayward knows, the better its suggestions and routes.", 0.8, 0.8, 0.8, true)
  for _, step in ipairs(state.steps) do
    if step.done then
      GameTooltip:AddLine("|T" .. TICK .. ":0|t " .. step.label, GREEN[1], GREEN[2], GREEN[3])
    else
      GameTooltip:AddLine("- " .. step.label .. ": " .. step.how, 1, 0.82, 0, true)
    end
  end
  GameTooltip:Show()
end

local function hoverable(f)
  f:EnableMouse(true)
  f:SetScript("OnEnter", tooltip)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Under the large card (`anchor`), either side of the cards' page arrows,
-- which stay clickable between them.
function Profile.CreateStrip(parent, anchor, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(width, 20)
  f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)

  f.left = CreateFrame("Frame", nil, f)
  f.left:SetPoint("TOPLEFT")
  f.left:SetSize(BAR_WIDTH + 130, 20)
  hoverable(f.left)
  f.label = f.left:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("LEFT", 0, 0)
  f.label:SetText("PROFILE")
  f.bar = CreateFrame("StatusBar", nil, f.left)
  f.bar:SetSize(BAR_WIDTH, 10)
  f.bar:SetPoint("LEFT", f.label, "RIGHT", 8, 0)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetStatusBarColor(GREEN[1], GREEN[2], GREEN[3])
  f.bar:SetMinMaxValues(0, 100)
  f.bar.bg = f.bar:CreateTexture(nil, "BACKGROUND")
  f.bar.bg:SetAllPoints()
  f.bar.bg:SetColorTexture(0, 0, 0, 0.5)
  f.percent = f.left:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.percent:SetPoint("LEFT", f.bar, "RIGHT", 6, 0)
  f.tick = f.left:CreateTexture(nil, "OVERLAY")
  f.tick:SetSize(16, 16)
  f.tick:SetTexture(TICK)
  f.tick:SetPoint("LEFT", f.percent, "RIGHT", 4, 0)

  f.right = CreateFrame("Frame", nil, f)
  f.right:SetPoint("TOPRIGHT")
  f.right:SetSize(280, 20)
  hoverable(f.right)
  f.nextText = f.right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.nextText:SetPoint("RIGHT", 0, 0)
  f.nextText:SetWidth(280)
  f.nextText:SetJustifyH("RIGHT")
  f.nextText:SetWordWrap(false)
  ns.Skin.Text(f.label)
  ns.Skin.Text(f.percent)
  ns.Skin.Text(f.nextText)
  strip = f
  return f
end

-- Brings the strip up to date (the panel calls it on each refresh).
function Profile.Update()
  if not strip then return end
  local state = Profile.State()
  if state.percent >= 100 and ns.charDB and not ns.charDB.profileComplete then
    ns.charDB.profileComplete = Profile.session
  end
  if not Profile.Visible() then
    strip:Hide()
    return
  end
  strip.bar:SetValue(state.percent)
  strip.percent:SetText(state.percent .. "%")
  strip.tick:SetShown(state.percent >= 100)
  if state.next then
    strip.nextText:SetText("Next: " .. state.next.label)
  else
    strip.nextText:SetText("Profile complete!")
  end
  strip:Show()
end

function Profile.Strip() return strip end

ns.RegisterCommand("profile", "/ww profile - what Wayward knows about you so far, and what's left", function()
  local state = Profile.State()
  ns.print(string.format("profile: %d%%", state.percent))
  for _, step in ipairs(state.steps) do
    ns.print((step.done and "  done: " or "  to do: ") .. step.label .. (step.done and "" or (" - " .. step.how)))
  end
end)
