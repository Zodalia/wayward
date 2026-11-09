local _, ns = ...

-- "Where to quest", a region of the main window: the zones with quests for
-- you (ForYou.Zones()), the one you're in first, then by how well they fit
-- your level, then nearest. A glance gives the zone, its levels, how many
-- quests and how far; hover a zone for its hubs, where its chains lead and
-- the route there; click it for the journey to its first hub (the usual
-- question while a journey is on: add as a detour, switch, or cancel).
-- With no zones to show the region isn't there at all.

local Band = {}
ns.ZoneBand = Band

local MAX = 4
local GAP = 8
local CHIP_H = 42
local PAD = 8
local HERE = "You're here"
local UNSEEN = "New to you"
local STATE_COLOR = { 0.5, 0.82, 0.68 }
local FACT_COLOR = { 0.72, 0.72, 0.72 }

local frame

-- The zones, in order: what ForYou has, else none.
function Band.List()
  local fn = ns.ForYou and ns.ForYou.Zones
  if type(fn) ~= "function" then return {} end
  local ok, list = pcall(fn)
  if not ok or type(list) ~= "table" then return {} end
  return list
end

-- "You're here", "New to you", or nothing to say.
function Band.StateFor(z)
  return z.here and HERE or z.unseen and UNSEEN or nil
end

-- "Levels 10-15  ·  6 quests  ·  4 min": the levels, what you can take now
-- ("left" where you are), and the way to the first hub.
function Band.FactsFor(z)
  local parts = {}
  if z.lowest and z.highest then
    parts[#parts + 1] = z.lowest == z.highest and ("Level " .. z.lowest) or string.format("Levels %d-%d", z.lowest, z.highest)
  end
  if z.now then
    parts[#parts + 1] = string.format("%d quest%s%s", z.now, z.now == 1 and "" or "s", z.here and " left" or "")
  end
  if z.seconds then parts[#parts + 1] = ns.FormatDuration(z.seconds) end
  return table.concat(parts, "  ·  ")
end

-- Starts the zone's journey (or asks, while one is on).
function Band.Run(z)
  if not (z and z.row) then return false end
  ns.Panel.Activate(z.row)
  return true
end

local function tooltip(chip)
  local z = chip.zone
  if not (z and z.row) then return end
  ns.Panel.ShowTooltip(chip, z.row)
end

local function makeChip(parent, width)
  local chip = CreateFrame("Button", nil, parent)
  chip:SetSize(width, CHIP_H)
  ns.JourneyBox.Backdrop(chip)
  chip.name = chip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  chip.name:SetPoint("TOPLEFT", PAD, -6)
  chip.name:SetJustifyH("LEFT")
  chip.name:SetWordWrap(false)
  chip.state = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  chip.state:SetPoint("TOPRIGHT", -PAD, -8)
  chip.state:SetJustifyH("RIGHT")
  chip.state:SetTextColor(STATE_COLOR[1], STATE_COLOR[2], STATE_COLOR[3])
  chip.name:SetPoint("RIGHT", chip.state, "LEFT", -6, 0)
  chip.facts = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  chip.facts:SetPoint("BOTTOMLEFT", PAD, 7)
  chip.facts:SetPoint("RIGHT", -PAD, 0)
  chip.facts:SetJustifyH("LEFT")
  chip.facts:SetWordWrap(false)
  chip.facts:SetTextColor(FACT_COLOR[1], FACT_COLOR[2], FACT_COLOR[3])
  for _, fs in ipairs({ chip.name, chip.state, chip.facts }) do ns.Skin.Text(fs) end
  chip:SetScript("OnClick", function(self) Band.Run(self.zone) end)
  chip:SetScript("OnEnter", tooltip)
  chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return chip
end

function Band.Create(parent, width)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(width, CHIP_H)
  f.width = width
  local chipWidth = math.floor((width - (MAX - 1) * GAP) / MAX)
  f.chips = {}
  for i = 1, MAX do
    local chip = makeChip(f, chipWidth)
    chip:SetPoint("TOPLEFT", (i - 1) * (chipWidth + GAP), 0)
    f.chips[i] = chip
  end
  frame = f
  return f
end

local function fill(chip, z)
  chip.zone = z
  if not z then
    chip:Hide()
    return
  end
  chip:Show()
  chip.name:SetText(z.zone or "?")
  chip.state:SetText(Band.StateFor(z) or "")
  chip.facts:SetText(Band.FactsFor(z))
end

-- Brings the zones up to date; returns the region's height (0: no zones,
-- and the region is hidden).
function Band.Update()
  if not frame then return 0 end
  local list = Band.List()
  for i, chip in ipairs(frame.chips) do
    local ok, err = pcall(fill, chip, list[i])
    if not ok then
      chip:Hide()
      geterrorhandler()(err)
    end
  end
  frame.count = math.min(#list, MAX)
  frame:SetShown(frame.count > 0)
  return frame.count > 0 and CHIP_H or 0
end

function Band.Height() return frame and (frame.count or 0) > 0 and CHIP_H or 0 end

-- Whether the zones are on show (then the cards leave them to the band).
function Band.Shown() return frame ~= nil and (frame.count or 0) > 0 end

-- The zones as drawn, { name, state, facts } each (for tests).
function Band.Chips()
  local out = {}
  if not frame then return out end
  for _, chip in ipairs(frame.chips) do
    if chip.zone then
      out[#out + 1] = { name = chip.name:GetText(), state = chip.state:GetText(), facts = chip.facts:GetText() }
    end
  end
  return out
end

-- Clicks zone `index` (for tests).
function Band.Act(index)
  local chip = frame and frame.chips[index]
  return chip ~= nil and Band.Run(chip.zone) or false
end

function Band.Frame() return frame end
