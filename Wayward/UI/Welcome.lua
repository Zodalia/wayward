local _, ns = ...

-- A short introduction, shown once on the first login with Wayward (and from
-- /ww welcome, the options or the minimap menu after that): what it does,
-- how to open it, how it learns, and where its data comes from.

local Welcome = {}
ns.Welcome = Welcome

local WIDTH, HEIGHT = 460, 330
local SHOW_DELAY = 3 -- seconds after login: after the loading screen, before the TomTom question

local frame

-- The paragraphs, top to bottom (for tests too).
function Welcome.Lines()
  local status = ns.Data and ns.Data.Has("Quest") and ns.Data.Status()
  return {
    "Wayward suggests what to do next for this character and gives step-by-step directions: "
      .. "on foot, by flight path, boat, zeppelin and tram.",
    "Open it with /ww or the minimap button. Right-click the button for the options "
      .. "(also in Options > AddOns > Wayward).",
    "It learns as you play: open a flight map once on each continent, visit your class trainer, "
      .. "and talk to vendors and flight masters as you meet them.",
    status and ("Data: " .. status .. ", plus the places you visit.")
      or ("Wayward ships no quest database. For quests, items and every trainer, install "
        .. ns.Data.ADDON .. " (the Questie team's free database); Wayward reads it by itself. "
        .. "Until then it knows the places you've been."),
    "Directions open in a box you can drag; its compass points the way. /ww help lists every command.",
  }
end

local function create()
  local f, templated = ns.Skin.CreateWindow("WaywardWelcome")
  f:SetSize(WIDTH, HEIGHT)
  f:SetPoint("CENTER", 0, 60)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  tinsert(UISpecialFrames, "WaywardWelcome")

  local title = f.titleText
  if not title then
    title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
  end
  title:SetText("Welcome to Wayward")
  ns.Skin.Text(title)
  ns.Skin.CloseButton(f.close)
  if templated then
    f.Inset:ClearAllPoints()
    f.Inset:SetPoint("TOPLEFT", 4, -26)
    f.Inset:SetPoint("BOTTOMRIGHT", -6, 4)
    ns.Skin.Inset(f.Inset)
  end

  f.paragraphs = {}
  local previous
  for i = 1, 5 do
    local fs = f:CreateFontString(nil, "OVERLAY", i == 1 and "GameFontNormal" or "GameFontHighlight")
    fs:SetWidth(WIDTH - 40)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    if previous then
      fs:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -10)
    else
      fs:SetPoint("TOPLEFT", 20, -40)
    end
    ns.Skin.Text(fs)
    f.paragraphs[i] = fs
    previous = fs
  end

  local function button(text, x, onClick)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(120, 22)
    b:SetPoint("BOTTOMLEFT", x, 14)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    ns.Skin.Button(b)
    return b
  end
  f.open = button("Open Wayward", 20, function()
    f:Hide()
    if not ns.Panel.IsShown() then ns.Panel.Toggle() end
  end)
  f.options = button("Options", 148, function()
    f:Hide()
    ns.Options.Open()
  end)
  f.done = button("Close", WIDTH - 140, function() f:Hide() end)
  f:SetScript("OnHide", function()
    -- The TomTom question waited for this window.
    if ns.Options and ns.Options.AskTomTom then ns.Options.AskTomTom() end
  end)
  ns.Skin.Window(f)
  f:Hide()
  return f
end

function Welcome.Show()
  frame = frame or create()
  for i, text in ipairs(Welcome.Lines()) do frame.paragraphs[i]:SetText(text) end
  ns.db.settings.welcomed = ns.VERSION
  frame:Show()
end

function Welcome.Hide()
  if frame then frame:Hide() end
end

function Welcome.IsShown()
  return frame ~= nil and frame:IsShown()
end

-- Whether the first-login welcome is still due (for tests).
function Welcome.Due()
  return ns.db.settings.welcomed == nil
end

ns.On("PLAYER_LOGIN", function()
  if not Welcome.Due() then return end
  ns.After(SHOW_DELAY, function()
    if Welcome.Due() and not (InCombatLockdown and InCombatLockdown()) then Welcome.Show() end
  end)
end)

ns.RegisterCommand("welcome", "/ww welcome - the short introduction again", Welcome.Show)
