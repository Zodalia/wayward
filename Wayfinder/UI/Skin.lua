local _, ns = ...

-- How Wayfinder's windows look. They are built from Blizzard's own templates
-- (the old backdrops are the fallback), which many UI suites restyle anyway.
-- When EllesmereUI or ElvUI is loaded, the UI files also hand their frames to
-- that suite's public skinning API, so they match the rest of the player's UI.
-- /wf skin turns that part off.
--
-- EllesmereUI: EllesmereUI.RegisterSkin(name, fn) calls fn(S) once, after login,
-- while the player has third-party skins on (SKINNING_API.md in its repo).
-- S.Shell, S.Panel, S.Button, ... paint a frame in the player's theme (window
-- colour and transparency, border, accent) and follow later changes by
-- themselves. S.Font sets the player's UI font; we re-apply it on show.
-- ElvUI: the handlers of its Skins module and SetTemplate("Transparent").
--
-- UI files call these on their frames as they create them:
--   Skin.Window(f), Skin.Box(f), Skin.Inset(f.Inset), Skin.Button(b),
--   Skin.CloseButton(b), Skin.EditBox(e), Skin.Tab(t), Skin.ScrollBar(s),
--   Skin.Text(fontString),
--   Skin.SetTabSelected(tab, selected) when the selected tab changes.
-- Call Window and Box after SetScript("OnShow"), which would drop our hook.

local Skin = {}
ns.Skin = Skin

local DIALOG_BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 8, right = 8, top = 8, bottom = 8 },
}

local TOOLTIP_BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

---------------------------------------------------------------- templates

-- A frame from a Blizzard template, or from `fallback` when this client doesn't
-- know the template, CreateFrame fails, or a child we use (`needs`) is missing.
-- Returns the frame and whether the template was used.
function Skin.Create(frameType, name, parent, template, fallback, needs)
  local known = true
  if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
    local ok, info = pcall(C_XMLUtil.GetTemplateInfo, template)
    known = ok and info ~= nil
  end
  if known then
    local ok, f = pcall(CreateFrame, frameType, name, parent, template)
    if ok and f then
      local complete = true
      for _, key in ipairs(needs or {}) do
        if type(f[key]) ~= "table" then complete = false end
      end
      if complete then return f, true end
      f:Hide()
    end
  end
  return CreateFrame(frameType, name, parent, fallback), false
end

-- A standard window: ButtonFrameTemplate without its portrait (title bar, close
-- button, inset), else the old dialog box. Sets f.close, and f.titleText when
-- the template has a title.
function Skin.CreateWindow(name)
  local f, templated = Skin.Create("Frame", name, UIParent, "ButtonFrameTemplate", "BackdropTemplate",
    { "CloseButton", "TitleContainer", "Inset" })
  if templated then
    if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f) end
    f.close = f.CloseButton
    local title = f.TitleContainer.TitleText
    f.titleText = type(title) == "table" and title or nil
  else
    f:SetBackdrop(DIALOG_BACKDROP)
    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -6, -6)
  end
  return f, templated
end

-- A small floating box with the tooltip look, else the old tooltip backdrop.
-- Both take SetBackdropColor.
function Skin.CreateBox(name)
  local f, templated = Skin.Create("Frame", name, UIParent, "TooltipBackdropTemplate", "BackdropTemplate",
    { "NineSlice" })
  if not templated then f:SetBackdrop(TOOLTIP_BACKDROP) end
  return f, templated
end

-- SearchBoxTemplate (magnifier, clear button), else InputBoxTemplate. Either
-- way box.hint is the grey hint shown while the box is empty.
function Skin.CreateSearchBox(parent)
  local box, templated = Skin.Create("EditBox", nil, parent, "SearchBoxTemplate", "InputBoxTemplate",
    { "Instructions" })
  if templated then
    box.hint = box.Instructions
  else
    box.hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    box.hint:SetPoint("LEFT", 2, 0)
  end
  return box, templated
end

-- A tab along the top of a window, else a plain button.
function Skin.CreateTab(parent)
  return Skin.Create("Button", nil, parent, "PanelTopTabButtonTemplate", "UIPanelButtonTemplate",
    { "Text", "Left", "Right" })
end

---------------------------------------------------------------- suites

local suite          -- { name, look = { [kind] = fn(object) }, select = fn(tab, selected) }
local pending = {}   -- { {kind, object} } not painted yet (no suite yet, or skin off)
local texts = {}     -- FontStrings, re-fonted on show
local painted = setmetatable({}, { __mode = "k" })
local registered = false

local function enabled()
  return not (ns.db and ns.db.settings.skin == false)
end

-- A broken skin must never break the window, so errors only end up here.
local function apply(kind, object)
  local fn = suite.look[kind]
  if not fn then return end
  local ok, err = pcall(fn, object)
  if ok then painted[object] = true else Skin.lastError = err end
end

local function flush()
  if not (suite and enabled()) then return end
  local queue = pending
  pending = {}
  for _, entry in ipairs(queue) do apply(entry[1], entry[2]) end
end

local function add(kind, object)
  if type(object) ~= "table" then return end
  if kind == "text" then texts[#texts + 1] = object end
  pending[#pending + 1] = { kind, object }
  flush()
end

-- Re-reads what the suite doesn't keep up to date itself (the font).
function Skin.Refresh()
  if not (suite and enabled()) then return end
  for _, fs in ipairs(texts) do
    if painted[fs] then apply("text", fs) end
  end
end

local function hookShow(f)
  if type(f) == "table" and f.HookScript then f:HookScript("OnShow", Skin.Refresh) end
end

function Skin.Window(f) add("window", f); hookShow(f) end
function Skin.Box(f) add("box", f); hookShow(f) end
function Skin.Inset(f) add("inset", f) end
function Skin.Button(b) add("button", b) end
function Skin.CloseButton(b) add("close", b) end
function Skin.EditBox(e) add("editbox", e) end
function Skin.Tab(t) add("tab", t) end
function Skin.ScrollBar(s) add("scrollbar", s) end
function Skin.Text(fs) add("text", fs) end

function Skin.SetTabSelected(tab, selected)
  if suite and suite.select and painted[tab] and enabled() then pcall(suite.select, tab, selected) end
end

-- "EllesmereUI", "ElvUI", or nil when windows use the templates alone.
function Skin.Status()
  return suite and suite.name or nil
end

local function ellesmere(S)
  return {
    name = "EllesmereUI",
    look = {
      window = function(f) S.Shell(f) end,
      box = function(f) S.Panel(f) end,
      inset = function(f) S.Inset(f) end,
      button = function(b) S.Button(b) end,
      close = function(b) S.CloseButton(b) end,
      editbox = function(e) S.EditBox(e) end,
      tab = function(t) S.Tab(t) end,
      scrollbar = function(s) S.ScrollBar(s) end,
      text = function(fs) S.Font(fs) end,
    },
    -- apiVersion 2+; older versions follow PanelTemplates_SetTab only.
    select = S.SetTabSelection and function(tab, selected) S.SetTabSelection(tab, selected) end,
  }
end

local function elvui()
  local E = type(ElvUI) == "table" and ElvUI[1]
  local S = E and E.GetModule and E:GetModule("Skins", true)
  if not S then return nil end
  local function flat(f)
    if type(f.NineSlice) == "table" then f.NineSlice:SetAlpha(0) end
    f:SetTemplate("Transparent")
  end
  return {
    name = "ElvUI",
    look = {
      window = function(f)
        if type(f.NineSlice) == "table" and S.HandlePortraitFrame then S:HandlePortraitFrame(f) else flat(f) end
      end,
      box = flat,
      inset = function(f) f:StripTextures() end,
      button = function(b) S:HandleButton(b) end,
      close = function(b) S:HandleCloseButton(b) end,
      editbox = function(e) S:HandleEditBox(e) end,
      tab = function(t) S:HandleTab(t) end,
      scrollbar = function(s) S:HandleScrollBar(s) end,
      text = function(fs)
        local _, size, flags = fs:GetFont()
        fs:SetFont(E.media.normFont, size or 12, flags)
      end,
    },
  }
end

-- After login, so the suites have set themselves up. EllesmereUI calls back
-- right away when its skins are on, and never when they are off.
local function detect()
  if suite or registered then return end
  if type(EllesmereUI) == "table" and type(EllesmereUI.RegisterSkin) == "function" then
    registered = true
    EllesmereUI.RegisterSkin("Wayfinder", function(S)
      suite = ellesmere(S)
      if S.OnLooksChanged then S.OnLooksChanged(Skin.Refresh) end
      flush()
    end)
    return
  end
  suite = elvui()
  flush()
end

ns.On("PLAYER_LOGIN", function() C_Timer.After(0, detect) end)

ns.RegisterCommand("skin", "/wf skin - match your UI suite's look (EllesmereUI, ElvUI) on or off", function()
  ns.db.settings.skin = not enabled()
  if enabled() then
    flush()
    ns.print("skin on" .. (suite and " (" .. suite.name .. ")"
      or " (no EllesmereUI or ElvUI skin active, so Blizzard's look)"))
  else
    ns.print("skin off" .. (next(painted) and "; /reload to remove it from windows already open" or ""))
  end
end)
