local _, ns = ...

-- A movable window with a read-only, select-all text box so the report can be
-- copied out of the game (Ctrl+A, Ctrl+C) without relying on SavedVariables.

local SECTIONS = { "headline", "meta", "context", "probes", "events" }

local frame

local function create()
  local f = CreateFrame("Frame", "WFProbeExportFrame", UIParent, "BackdropTemplate")
  f:SetSize(760, 520)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  })

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", 0, -16)
  title:SetText("WFProbe report  -  Ctrl+A then Ctrl+C to copy")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -40)
  scroll:SetPoint("BOTTOMRIGHT", -38, 18)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(690)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  -- Read-only: any typing restores the report text.
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput and f.text then self:SetText(f.text) self:HighlightText() end
  end)
  scroll:SetScrollChild(edit)

  f.edit = edit
  tinsert(UISpecialFrames, "WFProbeExportFrame")
  return f
end

local function buildText()
  local data, key = ns.charData()
  local parts = { "-- WFProbe " .. ns.VERSION .. " report for " .. key }
  for _, section in ipairs(SECTIONS) do
    parts[#parts + 1] = section .. " = " .. ns.serialize(data[section])
  end
  return table.concat(parts, "\n\n")
end

function ns.ShowExport()
  frame = frame or create()
  frame.text = buildText()
  frame.edit:SetText(frame.text)
  frame:Show()
  frame.edit:SetFocus()
  frame.edit:HighlightText()
end

function ns.RefreshExportIfShown()
  if frame and frame:IsShown() then ns.ShowExport() end
end
