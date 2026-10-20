local _, ns = ...

-- A small window with selected text, because chat lines can't be copied.

local frame

local function create()
  local f, templated = ns.Skin.CreateWindow("WaywardCopyBox")
  f:SetSize(520, 260)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "WaywardCopyBox")

  f.title = f.titleText
  if not f.title then
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", 0, -16)
  end
  ns.Skin.Text(f.title)
  ns.Skin.CloseButton(f.close)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -40)
  scroll:SetPoint("BOTTOMRIGHT", -38, 18)
  if templated then
    f.Inset:ClearAllPoints()
    f.Inset:SetPoint("TOPLEFT", 4, -32)
    f.Inset:SetPoint("BOTTOMRIGHT", -6, 4)
    ns.Skin.Inset(f.Inset)
  end
  ns.Skin.ScrollBar(scroll.ScrollBar)

  f.edit = CreateFrame("EditBox", nil, scroll)
  f.edit:SetMultiLine(true)
  f.edit:SetAutoFocus(false)
  f.edit:SetFontObject(ChatFontNormal)
  f.edit:SetWidth(450)
  f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
  scroll:SetScrollChild(f.edit)
  ns.Skin.Window(f)
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
