local _, ns = ...

-- A small window with selected text, because chat lines can't be copied.

local frame

local function create()
  local f = CreateFrame("Frame", "WayfinderCopyBox", UIParent, "BackdropTemplate")
  f:SetSize(520, 260)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  })
  tinsert(UISpecialFrames, "WayfinderCopyBox")

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", 0, -16)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -40)
  scroll:SetPoint("BOTTOMRIGHT", -38, 18)

  f.edit = CreateFrame("EditBox", nil, scroll)
  f.edit:SetMultiLine(true)
  f.edit:SetAutoFocus(false)
  f.edit:SetFontObject(ChatFontNormal)
  f.edit:SetWidth(450)
  f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
  scroll:SetScrollChild(f.edit)
  return f
end

function ns.ShowCopyBox(title, text)
  frame = frame or create()
  frame.title:SetText(title .. "  -  Ctrl+A, Ctrl+C to copy")
  frame.edit:SetText(text)
  frame:Show()
  frame.edit:SetFocus()
  frame.edit:HighlightText()
end
