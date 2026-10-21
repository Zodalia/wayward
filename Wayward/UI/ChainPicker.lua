local _, ns = ...

-- The follow-up question (Nav.FollowUpOffer): the quests a chain continues
-- with, a tick box and a time each (travel it adds and doing it), and the
-- total of the ticked ones at the bottom. Confirm adds them to the trip;
-- Cancel, Escape or the x adds nothing.

local ChainPicker = {}
ns.ChainPicker = ChainPicker

local WIDTH, ROW_HEIGHT, INDENT = 380, 24, 16
local TOP, BOTTOM = 56, 74
local GREY = { 0.6, 0.6, 0.6 }

local frame

local function row(parent, i)
  local r = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  r:SetSize(24, 24)
  r.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  r.label:SetPoint("LEFT", r, "RIGHT", 2, 0)
  r.label:SetJustifyH("LEFT")
  r.label:SetWordWrap(false)
  r.time = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.time:SetPoint("RIGHT", parent, "TOPRIGHT", -20, -(TOP + (i - 0.5) * ROW_HEIGHT))
  r.time:SetJustifyH("RIGHT")
  r.label:SetPoint("RIGHT", r.time, "LEFT", -8, 0)
  r:SetScript("OnClick", function() ChainPicker.Toggle(i) end)
  r:SetScript("OnEnter", function(self)
    local e = frame.offer and frame.offer.quests[i]
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(e.quest.name or ("Quest " .. e.quest.id))
    GameTooltip:AddLine(ChainPicker.TimeDetail(frame.offer, e), GREY[1], GREY[2], GREY[3], true)
    if e.parent then
      local before = frame.offer.quests[e.parent].quest
      GameTooltip:AddLine("Needs " .. (before.name or ("quest " .. before.id)) .. " first.", GREY[1], GREY[2], GREY[3], true)
    end
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return r
end

local function create()
  local f, templated = ns.Skin.CreateWindow("WaywardChainPicker")
  f:SetWidth(WIDTH)
  f:SetPoint("CENTER", 0, 120)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  tinsert(UISpecialFrames, "WaywardChainPicker")

  f.title = f.titleText
  if not f.title then
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -16)
  end
  f.title:SetText("Follow-up quests")
  ns.Skin.Text(f.title)
  ns.Skin.CloseButton(f.close)
  if templated then
    f.Inset:ClearAllPoints()
    f.Inset:SetPoint("TOPLEFT", 4, -26)
    f.Inset:SetPoint("BOTTOMRIGHT", -6, 4)
    ns.Skin.Inset(f.Inset)
  end

  f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.heading:SetPoint("TOPLEFT", 18, -34)
  f.heading:SetPoint("RIGHT", -18, 0)
  f.heading:SetJustifyH("LEFT")
  f.heading:SetWordWrap(false)

  f.rows = {}

  f.total = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.total:SetPoint("BOTTOMLEFT", 18, 44)
  f.total:SetPoint("RIGHT", -18, 0)
  f.total:SetJustifyH("LEFT")

  f.confirm = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.confirm:SetSize(110, 22)
  f.confirm:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 14)
  f.confirm:SetText("Confirm")
  f.confirm:SetScript("OnClick", function() ChainPicker.Confirm() end)
  ns.Skin.Button(f.confirm)

  f.cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.cancel:SetSize(110, 22)
  f.cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 14)
  f.cancel:SetText("Cancel")
  f.cancel:SetScript("OnClick", function() ChainPicker.Cancel() end)
  ns.Skin.Button(f.cancel)

  f:SetScript("OnHide", function(self)
    self.offer = nil
    ChainPicker.current = nil
  end)
  ns.Skin.Window(f)
  f:Hide()
  return f
end

-- "~1 min more travel + ~5 min to do it (your average)"
function ChainPicker.TimeDetail(offer, e)
  local doing = ns.FormatDuration(e.seconds - e.travel) .. " to do it"
  if ns.QuestTimes.Seconds() then doing = doing .. " (your average)" end
  if e.travel < 1 then return "On the way; " .. doing end
  return string.format("%s more travel + %s", ns.FormatDuration(e.travel), doing)
end

-- "Total: ~12 min for 2 quests", or "Nothing ticked".
function ChainPicker.TotalText(offer)
  local choice = ns.Nav.FollowUpChoice(offer)
  if choice.count == 0 then return "Nothing ticked" end
  return string.format("Total: %s for %d quest%s", ns.FormatDuration(choice.seconds), choice.count,
    choice.count == 1 and "" or "s")
end

local function refresh()
  local offer = frame.offer
  for i, r in ipairs(frame.rows) do
    local e = offer.quests[i]
    if e then
      r:SetChecked(e.checked)
      r:Show()
      r.label:Show()
      r.time:Show()
    else
      r:Hide()
      r.label:Hide()
      r.time:Hide()
    end
  end
  frame.total:SetText(ChainPicker.TotalText(offer))
  if frame.confirm.SetEnabled then frame.confirm:SetEnabled(ns.Nav.FollowUpChoice(offer).count > 0) end
end

-- Shows the offer; true when it was shown.
function ChainPicker.Show(offer)
  if not CreateFrame then return false end
  frame = frame or create()
  frame.offer = offer
  frame.heading:SetText(offer.heading or "The chain continues with:")
  for i, e in ipairs(offer.quests) do
    local r = frame.rows[i] or row(frame, i)
    frame.rows[i] = r
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", frame, "TOPLEFT", 14 + (e.depth - 1) * INDENT, -(TOP + (i - 1) * ROW_HEIGHT))
    local q = e.quest
    local level = (q.questLevel or 0) ~= 0 and q.questLevel or q.requiredLevel or 0
    r.label:SetText(string.format("[%d] %s", level, q.name or ("Quest " .. q.id)))
    local color = ns.DifficultyColor(level)
    if color then r.label:SetTextColor(color.r, color.g, color.b) end
    r.time:SetText(ns.FormatDuration(e.seconds))
  end
  frame:SetHeight(TOP + #offer.quests * ROW_HEIGHT + BOTTOM)
  refresh()
  frame:Show()
  ChainPicker.current = offer
  return true
end

function ChainPicker.Toggle(index)
  if not (frame and frame.offer) then return end
  ns.Nav.ToggleFollowUp(frame.offer, index)
  refresh()
end

function ChainPicker.Confirm()
  local offer = frame and frame.offer
  if frame then frame:Hide() end
  ChainPicker.current = nil
  if offer then ns.Nav.AcceptFollowUps(offer) end
end

function ChainPicker.Cancel()
  if frame then frame:Hide() end
  ChainPicker.current = nil
end

function ChainPicker.IsShown()
  return frame ~= nil and frame:IsShown() and frame.offer ~= nil
end
