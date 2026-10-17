local _, ns = ...

-- The whole journey at a glance: every stop with done / now / next, opened
-- from the directions box (=) and when a journey with several stops starts.
-- An open stop can be dropped (x); stops that need it are dropped with it.

local Overview = {}
ns.JourneyOverview = Overview

local MAX_ROWS = 10
local ROW_HEIGHT = 30

local frame

local function create()
  local f = ns.Skin.CreateBox("WayfinderJourneyOverview")
  f:SetSize(380, 64 + MAX_ROWS * ROW_HEIGHT)
  f:SetPoint("TOPLEFT", UIParent, "TOP", 170, -140)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    ns.SavePosition(self, "overviewPos")
  end)
  f:SetBackdropColor(0, 0, 0, 0.85)
  ns.RestorePosition(f, "overviewPos")

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 12, -10)
  f.title:SetPoint("RIGHT", -30, 0)
  f.title:SetJustifyH("LEFT")

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.info:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  ns.Skin.CloseButton(close)
  ns.Skin.Text(f.title)
  ns.Skin.Text(f.info)

  f.rows = {}
  for i = 1, MAX_ROWS do
    local row = CreateFrame("Frame", nil, f)
    row:SetSize(356, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 12, -44 - (i - 1) * ROW_HEIGHT)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("TOPLEFT", 0, -2)
    row.text:SetPoint("RIGHT", -24, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    -- Where the stop is, so a trip across several zones reads at a glance.
    row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.zone:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -2)
    row.zone:SetPoint("RIGHT", -24, 0)
    row.zone:SetJustifyH("LEFT")
    ns.Skin.Text(row.zone)
    row.drop = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.drop:SetSize(20, 16)
    row.drop:SetPoint("RIGHT", 0, 0)
    row.drop:SetText("x")
    row.drop:SetScript("OnClick", function() ns.Nav.Drop(row.stop) end)
    ns.Skin.Button(row.drop)
    ns.Skin.Text(row.text)
    f.rows[i] = row
  end

  f.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 12, 8)
  ns.Skin.Text(f.more)
  ns.Skin.Box(f)
  f:Hide()
  return f
end

-- The stop the current step leads to.
local function currentStop(a)
  for k = a.index, #a.route.steps do
    local stop = a.route.steps[k].stop
    if stop then return stop end
  end
  return nil
end

-- { {stop, state} } with state "done", "dropped", "now" or "next".
function Overview.Rows()
  local a = ns.Nav.active
  if not (a and a.journey) then return {} end
  local now = currentStop(a)
  local rows = {}
  for _, stop in ipairs(ns.Journey.AllStops(a.journey)) do
    local state = stop.skipped and "dropped" or stop.done and "done" or stop == now and "now" or "next"
    rows[#rows + 1] = { stop = stop, state = state }
  end
  -- Done and dropped stops first, in the order they happened to be listed.
  local order = { done = 1, dropped = 1, now = 2, next = 3 }
  local keyed = {}
  for i, r in ipairs(rows) do keyed[i] = { r = r, i = i } end
  table.sort(keyed, function(x, y)
    if order[x.r.state] ~= order[y.r.state] then return order[x.r.state] < order[y.r.state] end
    return x.i < y.i
  end)
  for i, k in ipairs(keyed) do rows[i] = k.r end
  return rows
end

local LOOK = {
  done = { "|cff7fd1aedone|r  ", 0.6 },
  dropped = { "|cff808080dropped|r  ", 0.5 },
  now = { "|cffffd200now|r  ", 1 },
  next = { "      ", 1 },
}

function Overview.Refresh()
  if not (frame and frame:IsShown()) then return end
  local a = ns.Nav.active
  if not (a and a.journey) then
    frame:Hide()
    return
  end
  local rows = Overview.Rows()
  local done = 0
  for _, r in ipairs(rows) do
    if r.state == "done" then done = done + 1 end
  end
  frame.title:SetText(a.title)
  frame.info:SetText(string.format("%d of %d stops done  ·  %s to go", done, #rows,
    ns.FormatDuration(ns.Nav.RemainingSeconds(ns.Geo.PlayerNode()))))
  for i, row in ipairs(frame.rows) do
    local r = rows[i]
    row.stop = r and r.stop
    if r then
      local look = LOOK[r.state]
      row.text:SetText(look[1] .. (r.stop.text or (r.stop.node and r.stop.node.label) or "?"))
      local zone = ns.Journey.StopZone(r.stop)
      row.zone:SetText(zone and ("      " .. zone) or "")
      row.text:SetAlpha(look[2])
      row.drop:SetShown(r.state == "now" or r.state == "next")
      row:Show()
    else
      row:Hide()
    end
  end
  frame.more:SetText(#rows > MAX_ROWS and string.format("... and %d more", #rows - MAX_ROWS) or "")
end

function Overview.Show()
  frame = frame or create()
  frame:Show()
  Overview.Refresh()
end

function Overview.Toggle()
  if frame and frame:IsShown() then frame:Hide() else Overview.Show() end
end

function Overview.IsShown()
  return frame ~= nil and frame:IsShown()
end

ns.Listen("JOURNEY_STARTED", Overview.Show)
ns.Listen("NAV_CHANGED", Overview.Refresh)
