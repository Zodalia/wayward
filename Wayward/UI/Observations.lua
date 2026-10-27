local _, ns = ...

-- "Good to know", the bottom region of the main window: up to four tiles
-- from ForYou.Observations(), each an icon, a short text with its numbers in
-- gold, and at most one button: Add detour (the observation's stop joins the
-- journey, or starts one), Show ... (a side page) or Go (plain directions).
-- Hover a tile for the full text. Until ForYou has observations, the region
-- says so in one line.

local Obs = {}
ns.Observations = Obs

local MAX = 4
local GAP = 8
local TILE_H = 84
local ICON = 36
local PAD = 8
local GOLD = "|cffffd200"
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local LABELS = { detour = "Add detour", show = "Show", go = "Go", resume = "Resume" }
local NONE_TEXT = "Nothing to flag right now."

local frame

-- The observations, in order: what ForYou has, else none.
function Obs.List()
  local fn = ns.ForYou and ns.ForYou.Observations
  if type(fn) ~= "function" then return {} end
  local ok, list = pcall(fn)
  if not ok or type(list) ~= "table" then return {} end
  return list
end

-- The text with its highlights in gold.
function Obs.Highlight(text, highlights)
  text = text or ""
  for _, h in ipairs(highlights or {}) do
    if h ~= "" then
      -- Plain text on both sides ("81%" has a % in it).
      local pattern = h:gsub("%W", "%%%0")
      text = text:gsub(pattern, function(found) return GOLD .. found .. "|r" end, 1)
    end
  end
  return text
end

-- Runs an observation's action: a detour into the journey (a new one when
-- none is on), a side page, or plain directions.
function Obs.Run(o)
  local action = o and o.action
  if not action then return false end
  -- What the journey or the directions are called: the action's own title,
  -- else the observation's text.
  local name = action.title or o.text or action.label or "detour"
  if action.kind == "detour" and (action.stops or action.stop) then
    -- Every stop it brings (all the hand-ins of a group), not just the first.
    local stops = action.stops or (type(action.stop[1]) == "table" and action.stop or { action.stop })
    ns.Nav.AddToTrip(stops, name)
    ns.Panel.Refresh()
    return true
  elseif action.kind == "resume" then
    ns.Nav.ResumeSetAside(action.index or 1)
    ns.Panel.Refresh()
    return true
  elseif action.kind == "show" and action.page then
    ns.Panel.Search(action.page, action.query or "")
    return true
  elseif action.kind == "go" and action.goal and action.route then
    ns.Nav.Start(name, action.goal, action.route)
    if ns.Panel.Hide then ns.Panel.Hide() end
    return true
  end
  return false
end

local function tooltip(tile)
  local o = tile.observation
  if not o then return end
  GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
  GameTooltip:SetText(Obs.Highlight(o.text, o.highlights), 1, 1, 1, 1, true)
  if o.detail then GameTooltip:AddLine(o.detail, 0.8, 0.8, 0.8, true) end
  if o.action then GameTooltip:AddLine(o.action.label or LABELS[o.action.kind] or "", 0.5, 0.8, 0.7) end
  GameTooltip:Show()
end

local function makeTile(parent, width)
  local tile = CreateFrame("Frame", nil, parent)
  tile:SetSize(width, TILE_H)
  ns.JourneyBox.Backdrop(tile)
  tile.icon = tile:CreateTexture(nil, "ARTWORK")
  tile.icon:SetSize(ICON, ICON)
  tile.icon:SetPoint("TOPLEFT", PAD, -PAD)
  tile.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  tile.text = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  tile.text:SetPoint("TOPLEFT", tile.icon, "TOPRIGHT", 6, 0)
  tile.text:SetPoint("RIGHT", -PAD, 0)
  tile.text:SetJustifyH("LEFT")
  tile.text:SetJustifyV("TOP")
  tile.text:SetWordWrap(true)
  if tile.text.SetMaxLines then tile.text:SetMaxLines(3) end
  ns.Skin.Text(tile.text)
  tile.button = CreateFrame("Button", nil, tile, "UIPanelButtonTemplate")
  tile.button:SetSize(90, 18)
  tile.button:SetPoint("BOTTOMRIGHT", -PAD, PAD - 2)
  tile.button:SetScript("OnClick", function() Obs.Run(tile.observation) end)
  ns.Skin.Button(tile.button)
  tile:EnableMouse(true)
  tile:SetScript("OnEnter", tooltip)
  tile:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return tile
end

function Obs.Create(parent, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(width, TILE_H)
  f.width = width
  local tileWidth = math.floor((width - (MAX - 1) * GAP) / MAX)
  f.tiles = {}
  for i = 1, MAX do
    local tile = makeTile(f, tileWidth)
    tile:SetPoint("TOPLEFT", (i - 1) * (tileWidth + GAP), 0)
    f.tiles[i] = tile
  end
  f.none = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.none:SetPoint("TOPLEFT", 4, -4)
  f.none:SetWidth(width - 8)
  f.none:SetJustifyH("LEFT")
  f.none:SetText(NONE_TEXT)
  ns.Skin.Text(f.none)
  frame = f
  return f
end

local function fill(tile, o)
  tile.observation = o
  if not o then
    tile:Hide()
    return
  end
  tile:Show()
  tile.icon:SetTexture(o.icon or DEFAULT_ICON)
  tile.text:SetText(Obs.Highlight(o.text, o.highlights))
  local action = o.action
  tile.button:SetShown(action ~= nil)
  if action then tile.button:SetText(action.label or LABELS[action.kind] or "Go") end
end

-- Brings the tiles up to date; returns the region's height.
function Obs.Update()
  if not frame then return 0 end
  local list = Obs.List()
  for i, tile in ipairs(frame.tiles) do
    local ok, err = pcall(fill, tile, list[i])
    if not ok then
      tile:Hide()
      geterrorhandler()(err)
    end
  end
  frame.none:SetShown(#list == 0)
  frame.count = math.min(#list, MAX)
  return TILE_H
end

function Obs.Height() return TILE_H end

-- The tiles as drawn, { text, label } each (for tests).
function Obs.Tiles()
  local out = {}
  if not frame then return out end
  for _, tile in ipairs(frame.tiles) do
    if tile.observation then
      out[#out + 1] = { text = tile.text:GetText(), label = tile.button:IsShown() and tile.button:GetText() or nil }
    end
  end
  return out
end

-- Clicks the button of tile `index` (for tests).
function Obs.Act(index)
  local tile = frame and frame.tiles[index]
  return tile ~= nil and Obs.Run(tile.observation) or false
end

function Obs.Frame() return frame end
