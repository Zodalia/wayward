local _, ns = ...

-- Wayward's options, in the game's Settings (Options > AddOns > Wayward;
-- right-clicking the minimap button opens them), and the one question asked
-- when TomTom is installed: whether to use its arrow (yes turns the compass
-- off). The compass and TomTom's arrow are separate: either, both, or neither
-- (text directions only). Slash commands change the same settings.

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

-- The options, in sections: { title, { key, name, tooltip, get, set }, ... }.
local SECTIONS = {
  { "Navigation aid",
    { "WAYWARD_COMPASS", "Compass in the directions box",
      "An arrow in the directions box points the way while you walk. Off: the box is narrower and shows text only.",
      function() return ns.db.settings.showArrow ~= false end,
      function(v) ns.SetSetting("showArrow", v) end },
    { "WAYWARD_TOMTOM", "TomTom's arrow",
      "Show Wayward's directions with TomTom's arrow and map pins (needs TomTom). Works with or without the compass.",
      function() return ns.db.settings.tomtom == true end,
      function(v) ns.SetSetting("tomtom", v) end },
    { "WAYWARD_DETAIL", "Every step in the directions box",
      "On: the box shows each step to the next stop (walk, fly, take the boat) and a step count. "
        .. "Off: it shows only the stop you're heading for and the compass; hover the box for the step. "
        .. "Per character; /ww detail steps|stops changes it too.",
      function() return ns.Nav.Detail() ~= "stops" end,
      function(v) ns.Nav.SetDetail(v and "steps" or "stops") end },
  },
  { "NPCs",
    { "WAYWARD_MARKER", "Star over the NPC you're heading for",
      "A star over the nameplate of the flight master, quest giver, trainer or vendor the current step is for, and a line in their tooltip. The star needs friendly NPC nameplates (below).",
      function() return ns.db.settings.markNPCs ~= false end,
      function(v) ns.SetSetting("markNPCs", v) end },
    { "WAYWARD_FRIENDLY_PLATES", "Friendly NPC nameplates",
      "The game's own setting: nameplates over friendly NPCs. Needed for the star; off by default in the game.",
      function() return ns.Marker.FriendlyNameplates() end,
      function(v) ns.Marker.SetFriendlyNameplates(v) end },
  },
  { "Journeys and quests",
    { "WAYWARD_ASK_PICKUP", "Ask when you pick up a quest",
      "When you pick up a quest that isn't in your journey: add it to the journey (with the time it adds), start a new journey for it (the one on now is set aside), or not now.",
      function() return ns.db.settings.askOnPickup ~= false end,
      function(v) ns.SetSetting("askOnPickup", v) end },
    { "WAYWARD_OVERVIEW", "Open the journey overview when a journey starts",
      "The list of every stop opens by itself when a journey starts. Off: open it from the directions box's book button (View details), or shift-right-click the minimap button on a journey.",
      function() return ns.db.settings.overviewOnStart ~= false end,
      function(v) ns.SetSetting("overviewOnStart", v) end },
    { "WAYWARD_TOASTS", "New journey toasts",
      "A short message when For you has something new for you: a questing zone, a dungeon, spells to train, a profession's next rank. Click it to start the journey.",
      function() return ns.db.settings.toasts ~= false end,
      function(v) ns.SetSetting("toasts", v) end },
    { "WAYWARD_UP_NEXT", "Suggest a journey after one is done",
      "A few seconds after a journey ends, For you's top suggestion as an \"Up next\" toast. Click it to start the journey.",
      function() return ns.db.settings.suggestNext ~= false end,
      function(v) ns.SetSetting("suggestNext", v) end },
  },
  { "Minimap",
    { "WAYWARD_MINIMAP", "Minimap button",
      "The Wayward button on the minimap. Right-click it for these options; /ww minimap brings it back.",
      minimapShown, setMinimapShown },
  },
}

-- The choices (for tests): { section, name, tooltip, get, set }.
function Options.Choices()
  local out = {}
  for _, section in ipairs(SECTIONS) do
    for i = 2, #section do
      local c = section[i]
      out[#out + 1] = { section = section[1], name = c[2], tooltip = c[3], get = c[4], set = c[5] }
    end
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

local function addInitializer(c, initializer)
  if not (SettingsPanel and SettingsPanel.GetLayout) then return end
  local layout = SettingsPanel:GetLayout(c)
  if layout and layout.AddInitializer then layout:AddInitializer(initializer) end
end

local function addHeader(c, title)
  if CreateSettingsListSectionHeaderInitializer then
    addInitializer(c, CreateSettingsListSectionHeaderInitializer(title))
  end
end

local function addButton(c, label, buttonText, onClick, tooltip)
  if CreateSettingsButtonInitializer then
    addInitializer(c, CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true))
  end
end

local function register()
  if category or not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting
    and Settings.CreateCheckbox and Settings.RegisterAddOnCategory) then return end
  local ok = pcall(function()
    local c = Settings.RegisterVerticalLayoutCategory("Wayward")
    for _, section in ipairs(SECTIONS) do
      -- Headers and buttons are extras: a client without their API still gets the checkboxes.
      pcall(addHeader, c, section[1])
      for i = 2, #section do
        local choice = section[i]
        local setting = Settings.RegisterProxySetting(c, choice[1], Settings.VarType.Boolean, choice[2],
          choice[4](), choice[4], choice[5])
        Settings.CreateCheckbox(c, setting, choice[3])
      end
    end
    pcall(addHeader, c, "Windows and help")
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
    ns.print("options: /ww compass, /ww tomtom, /ww toasts, /ww marker and /ww minimap turn those on or off; "
      .. "/ww detail steps|stops sets what the directions box shows.")
  end
end

---------------------------------------------------------------- TomTom

-- The question, once: TomTom is installed and you haven't chosen yet. Using
-- TomTom turns Wayward's compass off (one arrow is enough).
function Options.AskTomTom()
  if ns.db.settings.tomtom ~= nil or not ns.Nav.TomTomInstalled() then return false end
  if not (StaticPopupDialogs and StaticPopup_Show) then return false end
  StaticPopupDialogs.WAYWARD_TOMTOM = StaticPopupDialogs.WAYWARD_TOMTOM or {
    text = "Wayward: TomTom is installed.\n\nShow Wayward's directions with TomTom's arrow instead of "
      .. "Wayward's compass? You can change this, or use both, in the options (/ww options).",
    button1 = "Use TomTom", button2 = "No thanks",
    OnAccept = function()
      ns.SetSetting("tomtom", true)
      ns.SetSetting("showArrow", false)
    end,
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
  ns.After(2, function()
    if ns.Welcome and ns.Welcome.IsShown() then return end
    Options.AskTomTom()
  end)
end)

ns.RegisterCommand("options", "/ww options - open Wayward's options", Options.Open)
ns.RegisterCommand("reset", "/ww reset - put every window and box back where it started", Options.ResetPositions)
