local _, ns = ...

-- Wayfinder's options, in the game's Settings (Options > AddOns > Wayfinder),
-- and the one question asked when TomTom is installed: whether to use its
-- arrow. The compass and TomTom's arrow are separate: either, both, or
-- neither (text directions only). Slash commands change the same settings.

local Options = {}
ns.Options = Options

local category

local function minimapShown()
  return not (ns.db.settings.minimapIcon and ns.db.settings.minimapIcon.hide)
end

-- { key, name, tooltip, get, set }
local CHOICES = {
  { "WAYFINDER_COMPASS", "Compass in the directions box",
    "An arrow in the directions box points the way while you walk. Off: the box is narrower and shows text only.",
    function() return ns.db.settings.showArrow ~= false end,
    function(v) ns.SetSetting("showArrow", v) end },
  { "WAYFINDER_TOMTOM", "TomTom's arrow",
    "Show Wayfinder's directions with TomTom's arrow and map pins (needs TomTom). Works with or without the compass.",
    function() return ns.db.settings.tomtom == true end,
    function(v) ns.SetSetting("tomtom", v) end },
  { "WAYFINDER_MINIMAP", "Minimap button",
    "The Wayfinder button on the minimap.",
    minimapShown,
    function(v)
      ns.db.settings.minimapIcon = ns.db.settings.minimapIcon or {}
      ns.db.settings.minimapIcon.hide = not v
      if ns.MinimapButton then ns.MinimapButton.Refresh() end
    end },
}

local function register()
  if category or not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting
    and Settings.CreateCheckbox and Settings.RegisterAddOnCategory) then return end
  local ok = pcall(function()
    local c = Settings.RegisterVerticalLayoutCategory("Wayfinder")
    for _, choice in ipairs(CHOICES) do
      local setting = Settings.RegisterProxySetting(c, choice[1], Settings.VarType.Boolean, choice[2],
        choice[4](), choice[4], choice[5])
      Settings.CreateCheckbox(c, setting, choice[3])
    end
    Settings.RegisterAddOnCategory(c)
    category = c
  end)
  if not ok then category = nil end
end

function Options.Open()
  if category and Settings.OpenToCategory then
    Settings.OpenToCategory(category:GetID())
  else
    ns.print("options: /wf compass, /wf tomtom and /wf minimap turn those on or off.")
  end
end

-- The question, once: TomTom is installed and you haven't chosen yet.
function Options.AskTomTom()
  if ns.db.settings.tomtom ~= nil or not ns.Nav.TomTomInstalled() then return false end
  if not (StaticPopupDialogs and StaticPopup_Show) then return false end
  StaticPopupDialogs.WAYFINDER_TOMTOM = StaticPopupDialogs.WAYFINDER_TOMTOM or {
    text = "Wayfinder: TomTom is installed.\n\nShow Wayfinder's directions with TomTom's arrow too? "
      .. "You can change this, and turn Wayfinder's own compass off, in the options (/wf options).",
    button1 = "Use TomTom", button2 = "No thanks",
    OnAccept = function() ns.SetSetting("tomtom", true) end,
    OnCancel = function(_, _, reason) if reason == "clicked" then ns.SetSetting("tomtom", false) end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopup_Show("WAYFINDER_TOMTOM")
  return true
end

-- After login, when every addon (TomTom too) has loaded.
ns.On("PLAYER_LOGIN", function()
  register()
  C_Timer.After(2, Options.AskTomTom)
end)

ns.RegisterCommand("options", "/wf options - open Wayfinder's options", Options.Open)
