local _, ns = ...

-- "Good to know", the bottom region of the main window: up to four rows
-- from ForYou.Observations(), most urgent first. Each is one line across the
-- pane: an icon, the fact with its numbers in gold, and at most one light
-- action at the right: Add detour (the observation's stop joins the journey;
-- Start journey when none is on), Show ... (a list page), Go (plain
-- directions) or Resume. A line as wide as the pane holds the whole
-- sentence, where a tile a quarter as wide cut it short. Hover a row for the
-- full text and any detail. With nothing to say, the region says so in one line.

local Obs = {}
ns.Observations = Obs

local MAX = 4
local ROW_H = 22
local ICON = 16
local PAD = 6
local ACTION_W = 110       -- room for the longest action ("Start journey", "Show trainer")
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
-- none is on), a list page, or plain directions.
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

local function tooltip(row)
  row.hover:Show()
  local o = row.observation
  if not o then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:SetText(Obs.Highlight(o.text, o.highlights), 1, 1, 1, 1, true)
  if o.detail then GameTooltip:AddLine(o.detail, 0.8, 0.8, 0.8, true) end
  if o.action then GameTooltip:AddLine(o.action.label or LABELS[o.action.kind] or "", 0.5, 0.8, 0.7) end
  GameTooltip:Show()
end

local function makeRow(parent, width, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(width, ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  -- A faint band on every other row, so four lines read as a list.
  if i % 2 == 1 then
    local band = row:CreateTexture(nil, "BACKGROUND")
    band:SetAllPoints()
    band:SetColorTexture(1, 1, 1, 0.04)
  end
  row.hover = row:CreateTexture(nil, "BORDER")
  row.hover:SetAllPoints()
  row.hover:SetColorTexture(1, 1, 1, 0.06)
  row.hover:Hide()
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ICON, ICON)
  row.icon:SetPoint("LEFT", PAD, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  -- A light action, not a button frame: a row is a fact first, and its
  -- action weighs less than a suggestion's Start journey.
  row.button = ns.Skin.LinkButton(row, ACTION_W, "", function() Obs.Run(row.observation) end)
  row.button:SetPoint("RIGHT", -PAD + 2, 0)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.text:SetPoint("RIGHT", row.button, "LEFT", -8, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  ns.Skin.Text(row.text)
  row:EnableMouse(true)
  row:SetScript("OnEnter", tooltip)
  row:SetScript("OnLeave", function(self)
    self.hover:Hide()
    GameTooltip:Hide()
  end)
  return row
end

function Obs.Create(parent, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(width, ROW_H)
  f.width = width
  f.tiles = {} -- the rows; the name is from when they were tiles
  for i = 1, MAX do f.tiles[i] = makeRow(f, width, i) end
  f.none = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.none:SetPoint("LEFT", PAD, 0)
  f.none:SetWidth(width - 2 * PAD)
  f.none:SetJustifyH("LEFT")
  f.none:SetText(NONE_TEXT)
  ns.Skin.Text(f.none)
  frame = f
  return f
end

local function fill(row, o)
  row.observation = o
  if not o then
    row:Hide()
    return
  end
  row:Show()
  row.icon:SetTexture(o.icon or DEFAULT_ICON)
  row.text:SetText(Obs.Highlight(o.text, o.highlights))
  local action = o.action
  row.button:SetShown(action ~= nil)
  if action then
    -- A detour's label follows the journey, which may have started or ended
    -- since the observation was made.
    row.button:SetText(action.kind == "detour" and ns.Search.DetourLabel() or action.label or LABELS[action.kind] or "Go")
  end
end

-- Brings the rows up to date; returns the region's height: a line a row,
-- one line when there's nothing to say.
function Obs.Update()
  if not frame then return 0 end
  local list = Obs.List()
  for i, row in ipairs(frame.tiles) do
    local ok, err = pcall(fill, row, list[i])
    if not ok then
      row:Hide()
      geterrorhandler()(err)
    end
  end
  frame.none:SetShown(#list == 0)
  frame.count = math.min(#list, MAX)
  frame:SetHeight(Obs.Height())
  return Obs.Height()
end

function Obs.Height()
  return math.max(1, frame and frame.count or 0) * ROW_H
end

-- The rows as drawn, { text, label } each (for tests).
function Obs.Tiles()
  local out = {}
  if not frame then return out end
  for _, row in ipairs(frame.tiles) do
    if row.observation then
      out[#out + 1] = { text = row.text:GetText(), label = row.button:IsShown() and row.button:GetText() or nil }
    end
  end
  return out
end

-- Clicks the action of row `index` (for tests).
function Obs.Act(index)
  local row = frame and frame.tiles[index]
  return row ~= nil and Obs.Run(row.observation) or false
end

function Obs.Frame() return frame end
