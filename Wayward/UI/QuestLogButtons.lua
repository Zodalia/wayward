local _, ns = ...

-- Buttons by the game's quest log for the quest selected in it: start a
-- journey for it, or, with a journey on, add it to that journey or start a
-- new one for it (the one on now is set aside, to resume later). A quest
-- already in the journey can't be added again. Clients without the old quest
-- log (QuestLogFrame) get no buttons.

local QuestLogButtons = {}
ns.QuestLogButtons = QuestLogButtons

local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
-- The size of the log's own buttons; BELOW clears its frame's bottom edge.
local WIDTH, HEIGHT, GAP, BELOW = 112, 21, 4, -10
local holder, add, new

-- The quest selected in the log, and its name; nil when none (or a header).
function QuestLogButtons.Selected()
  local index = GetQuestLogSelection and GetQuestLogSelection()
  local info = index and index > 0 and ns.QuestLog.Info(index)
  if not (info and info.questID) then return nil end
  return info.questID, info.title
end

local function questName(questID, title)
  local q = ns.Quests.Quest(questID)
  return title or (q and q.name) or ns.QuestLog.Title(questID) or ("quest " .. questID)
end

-- The journey for a quest from where you are: its stops (do it, hand it in),
-- or nil and why not.
function QuestLogButtons.Plan(questID, title)
  local here = ns.Geo.PlayerNode()
  if not here then return nil, "can't tell where you are right now." end
  local stops = ns.Journey.QuestStops(questID, here)
  local name = questName(questID, title)
  if #stops == 0 then return nil, "no directions for " .. name .. ": its places aren't known." end
  local journey = ns.Journey.Plan(here, { title = name, kind = "quest", icon = QUEST_ICON, stops = stops })
  if not journey then return nil, "no route for " .. name .. " from here." end
  return journey, nil, stops, name
end

-- What the buttons offer for a quest: "start" (no journey on), "both" (add
-- or new), or "new" (it's in the journey already).
function QuestLogButtons.Mode(questID)
  if not ns.Nav.active then return "start" end
  if ns.Nav.TripHasQuest(questID) then return "new" end
  return "both"
end

function QuestLogButtons.AddToJourney(questID, title)
  local _, why, stops, name = QuestLogButtons.Plan(questID, title)
  if not stops then return ns.print(why) end
  return ns.Nav.AddToTrip(stops, name)
end

-- A new journey never loses the one on now: it's set aside.
function QuestLogButtons.NewJourney(questID, title)
  local journey, why = QuestLogButtons.Plan(questID, title)
  if not journey then return ns.print(why) end
  if ns.Nav.active then ns.Nav.SetAside() end
  ns.Nav.StartJourney(journey)
  return true
end

local function button(label, onClick, tooltip)
  local b = CreateFrame("Button", nil, holder, "UIPanelButtonTemplate")
  b:SetSize(WIDTH, HEIGHT)
  b:SetText(label)
  ns.Skin.Button(b)
  b:SetScript("OnClick", function()
    local id, title = QuestLogButtons.Selected()
    if id then onClick(id, title) end
    QuestLogButtons.Sync()
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(tooltip(self))
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function create()
  holder = CreateFrame("Frame", "WaywardQuestLogButtons", QuestLogFrame)
  holder:SetSize(WIDTH * 2 + GAP, HEIGHT)
  add = button("Add to journey", QuestLogButtons.AddToJourney, function()
    return "Add this quest to your journey: " .. (ns.Nav.active and ns.Nav.active.title or "")
  end)
  add:SetPoint("TOPLEFT")
  new = button("New journey", QuestLogButtons.NewJourney, function(self)
    if self.mode == "start" then return "Start a journey for this quest" end
    return "Start a journey for this quest. The one on now is set aside, to resume later."
  end)
  holder:Hide()
end

-- A row of its own just under the log's buttons (Abandon, Share, Exit),
-- lined up with Abandon; where there's no Abandon button, by the log's right
-- edge instead.
local function place()
  holder:ClearAllPoints()
  local abandon = QuestLogFrameAbandonButton
  if abandon then
    holder:SetPoint("TOPLEFT", abandon, "BOTTOMLEFT", 0, BELOW)
  else
    holder:SetPoint("TOPLEFT", QuestLogFrame, "TOPRIGHT", -28, -80)
  end
end

function QuestLogButtons.Sync()
  if not QuestLogFrame then return end
  if not holder then create() end
  local id = QuestLogFrame:IsShown() and QuestLogButtons.Selected()
  if not id then return holder:Hide() end
  local mode = QuestLogButtons.Mode(id)
  new.mode = mode
  new:SetText(mode == "start" and "Start journey" or "New journey")
  new:ClearAllPoints()
  if mode == "start" then
    add:Hide()
    new:SetPoint("TOPLEFT")
  else
    add:Show()
    add:SetText(mode == "new" and "In your journey" or "Add to journey")
    add:SetEnabled(mode == "both")
    new:SetPoint("LEFT", add, "RIGHT", GAP, 0)
  end
  place()
  holder:Show()
end

ns.On("PLAYER_LOGIN", function()
  if not QuestLogFrame then return end
  if type(QuestLog_Update) == "function" then hooksecurefunc("QuestLog_Update", QuestLogButtons.Sync) end
  QuestLogFrame:HookScript("OnShow", QuestLogButtons.Sync)
  QuestLogFrame:HookScript("OnHide", QuestLogButtons.Sync)
end)
ns.Listen("NAV_CHANGED", QuestLogButtons.Sync)
ns.Listen("JOURNEY_EXTENDED", QuestLogButtons.Sync)
