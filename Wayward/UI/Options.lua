local _, ns = ...

-- Wayward's options, in the game's Settings (Options > AddOns > Wayward),
-- the quick menu on the minimap button (right-click; also the addon
-- compartment), and the one question asked when TomTom is installed: whether
-- to use its arrow. The compass and TomTom's arrow are separate: either,
-- both, or neither (text directions only). Slash commands change the same
-- settings.

local Options = {}
ns.Options = Options

local category

local function minimapShown()
  return not (ns.db.settings.minimapIcon and ns.db.settings.minimapIcon.hide)
end

local function setMinimapShown(v)
  ns.db.settings.minimapIcon = ns.db.settings.minimapIcon or {}
  ns.db.settings.minimapIcon.hide = not v
  if ns.MinimapButton then ns.MinimapButton.Refresh() end
end

-- { key, name, tooltip, get, set, quick }: `quick` puts it on the minimap menu too.
local CHOICES = {
  { "WAYWARD_COMPASS", "Compass in the directions box",
    "An arrow in the directions box points the way while you walk. Off: the box is narrower and shows text only.",
    function() return ns.db.settings.showArrow ~= false end,
    function(v) ns.SetSetting("showArrow", v) end, true },
  { "WAYWARD_TOMTOM", "TomTom's arrow",
    "Show Wayward's directions with TomTom's arrow and map pins (needs TomTom). Works with or without the compass.",
    function() return ns.db.settings.tomtom == true end,
    function(v) ns.SetSetting("tomtom", v) end },
  { "WAYWARD_MARKER", "Star over the NPC you're heading for",
    "A star over the nameplate of the flight master, quest giver, trainer or vendor the current step is for, and a line in their tooltip. The star needs friendly NPC nameplates (below).",
    function() return ns.db.settings.markNPCs ~= false end,
    function(v) ns.SetSetting("markNPCs", v) end },
  { "WAYWARD_FRIENDLY_PLATES", "Friendly NPC nameplates",
    "The game's own setting: nameplates over friendly NPCs. Needed for the star; off by default in the game.",
    function() return ns.Marker.FriendlyNameplates() end,
    function(v) ns.Marker.SetFriendlyNameplates(v) end },
  { "WAYWARD_ASK_PICKUP", "Ask when you pick up a quest",
    "When you pick up a quest that isn't in your trip: add it to the trip (with the time it adds), start a new trip for it, or not now.",
    function() return ns.db.settings.askOnPickup ~= false end,
    function(v) ns.SetSetting("askOnPickup", v) end, true },
  { "WAYWARD_OVERVIEW", "Open the journey overview when a trip starts",
    "The list of every stop opens by itself when a trip starts. Off: open it from the directions box's book button, or the minimap menu on a trip.",
    function() return ns.db.settings.overviewOnStart ~= false end,
    function(v) ns.SetSetting("overviewOnStart", v) end },
  { "WAYWARD_TOASTS", "New journey toasts",
    "A short message when For you has something new for you: a questing zone, a dungeon, spells to train, a profession's next rank. Click it to start the journey.",
    function() return ns.db.settings.toasts ~= false end,
    function(v) ns.SetSetting("toasts", v) end, true },
  { "WAYWARD_MINIMAP", "Minimap button",
    "The Wayward button on the minimap. Right-click it for this menu; /ww minimap brings it back.",
    minimapShown, setMinimapShown, true },
}

-- The choices (for the menu and tests): { name, tooltip, get, set, quick }.
function Options.Choices()
  local out = {}
  for _, c in ipairs(CHOICES) do
    out[#out + 1] = { name = c[2], tooltip = c[3], get = c[4], set = c[5], quick = c[6] == true }
  end
  return out
end

---------------------------------------------------------------- positions

-- Every pane back where it starts (the panes keep their own home; the panel
-- and the copy box are centred).
function Options.ResetPositions()
  local settings = ns.db.settings
  settings.panelPos = nil
  for _, pane in ipairs(ns.Movers and ns.Movers.Panes() or {}) do
    settings[pane.posKey] = nil
    local f = pane.frame and pane.frame()
    if f then ns.RestorePosition(f, pane.posKey, pane.home) end
  end
  if ns.Panel and ns.Panel.ResetPosition then ns.Panel.ResetPosition() end
  ns.print("windows and boxes put back where they started")
end

---------------------------------------------------------------- settings panel

local function addButton(c, label, buttonText, onClick, tooltip)
  if not (CreateSettingsButtonInitializer and SettingsPanel and SettingsPanel.GetLayout) then return end
  local layout = SettingsPanel:GetLayout(c)
  if not (layout and layout.AddInitializer) then return end
  layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true))
end

local function register()
  if category or not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting
    and Settings.CreateCheckbox and Settings.RegisterAddOnCategory) then return end
  local ok = pcall(function()
    local c = Settings.RegisterVerticalLayoutCategory("Wayward")
    for _, choice in ipairs(CHOICES) do
      local setting = Settings.RegisterProxySetting(c, choice[1], Settings.VarType.Boolean, choice[2],
        choice[4](), choice[4], choice[5])
      Settings.CreateCheckbox(c, setting, choice[3])
    end
    -- Buttons are extras: a client without their API still gets the checkboxes.
    pcall(addButton, c, "Windows and boxes", "Reset positions", Options.ResetPositions,
      "Put the Wayward window, the directions box, the journey overview and the banners back where they started.")
    pcall(addButton, c, "Welcome", "Show again",
      function() if ns.Welcome then ns.Welcome.Show() end end,
      "The short introduction shown on the first login: what Wayward does and how it learns.")
    pcall(addButton, c, "Slash commands", "List in chat", function() SlashCmdList.WAYWARD("help") end,
      "Every /ww command, printed to the chat window.")
    Settings.RegisterAddOnCategory(c)
    category = c
  end)
  if not ok then category = nil end
end

function Options.Open()
  if category and Settings.OpenToCategory then
    Settings.OpenToCategory(category:GetID())
  else
    ns.print("options: /ww compass, /ww tomtom, /ww toasts, /ww marker and /ww minimap turn those on or off.")
  end
end

---------------------------------------------------------------- quick menu

-- The menu's entries, in order, for whichever menu API this client has (and
-- for tests): { text, run } for a button, { text, get, set } for a checkbox,
-- { title = text } for a heading, {} for a divider.
function Options.MenuEntries()
  local entries = { { title = "Wayward" } }
  local panelOpen = ns.Panel and ns.Panel.IsShown()
  entries[#entries + 1] = { text = panelOpen and "Close Wayward" or "Open Wayward", run = function() ns.Panel.Toggle() end }
  if ns.Nav and ns.Nav.active then
    if ns.Nav.active.journey then
      entries[#entries + 1] = { text = "Journey overview", run = function() ns.JourneyOverview.Toggle() end }
    end
    entries[#entries + 1] = { text = "Stop directions", run = function() ns.Nav.Stop() end }
  end
  entries[#entries + 1] = {}
  for _, c in ipairs(CHOICES) do
    if c[6] then entries[#entries + 1] = { text = c[2], get = c[4], set = c[5] } end
  end
  if ns.Nav and ns.Nav.TomTomInstalled() then
    entries[#entries + 1] = { text = "TomTom's arrow", get = CHOICES[2][4], set = CHOICES[2][5] }
  end
  entries[#entries + 1] = {}
  entries[#entries + 1] = { text = "Options...", run = Options.Open }
  entries[#entries + 1] = { text = "Welcome and help", run = function() if ns.Welcome then ns.Welcome.Show() end end }
  return entries
end

-- Opens the quick menu at `owner` (the minimap button, the addon compartment
-- entry). Modern clients: MenuUtil. Without it, the options panel instead.
function Options.ShowMenu(owner)
  if not (MenuUtil and MenuUtil.CreateContextMenu and owner) then return Options.Open() end
  local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
    for _, e in ipairs(Options.MenuEntries()) do
      if e.title then
        root:CreateTitle(e.title)
      elseif e.get then
        root:CreateCheckbox(e.text, function() return e.get() and true or false end, function() e.set(not e.get()) end)
      elseif e.text then
        root:CreateButton(e.text, e.run)
      else
        root:CreateDivider()
      end
    end
  end)
  if not ok then Options.Open() end
end

---------------------------------------------------------------- TomTom

-- The question, once: TomTom is installed and you haven't chosen yet.
function Options.AskTomTom()
  if ns.db.settings.tomtom ~= nil or not ns.Nav.TomTomInstalled() then return false end
  if not (StaticPopupDialogs and StaticPopup_Show) then return false end
  StaticPopupDialogs.WAYWARD_TOMTOM = StaticPopupDialogs.WAYWARD_TOMTOM or {
    text = "Wayward: TomTom is installed.\n\nShow Wayward's directions with TomTom's arrow too? "
      .. "You can change this, and turn Wayward's own compass off, in the options (/ww options).",
    button1 = "Use TomTom", button2 = "No thanks",
    OnAccept = function() ns.SetSetting("tomtom", true) end,
    OnCancel = function(_, _, reason) if reason == "clicked" then ns.SetSetting("tomtom", false) end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopup_Show("WAYWARD_TOMTOM")
  return true
end

-- After login, when every addon (TomTom too) has loaded. The welcome window
-- comes first on a first login; the TomTom question waits for it.
ns.On("PLAYER_LOGIN", function()
  register()
  C_Timer.After(2, function()
    if ns.Welcome and ns.Welcome.IsShown() then return end
    Options.AskTomTom()
  end)
end)

ns.RegisterCommand("options", "/ww options - open Wayward's options", Options.Open)
ns.RegisterCommand("reset", "/ww reset - put every window and box back where it started", Options.ResetPositions)
