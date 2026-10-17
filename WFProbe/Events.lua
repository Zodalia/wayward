local _, ns = ...

-- Contextual probes: some data only exists while a window is open (vendor,
-- trainer, flight master, bank). These also test "harvesting": recording an
-- NPC's ID and position when you talk to it, to build our own world database.

local try, sample, get = ns.try, ns.sample, ns.get

local function playerPos()
  local mapID = C_Map.GetBestMapForUnit("player")
  local p = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not p then return { mapID = mapID } end
  local x, y = p:GetXY()
  return { mapID = mapID, x = x, y = y }
end

local function npcSnapshot()
  local guid = UnitGUID("npc")
  local out = { name = UnitName("npc"), guid = guid, at = playerPos() }
  if guid and not ns.isSecret(guid) then
    local unitType, _, _, _, _, npcID = strsplit("-", guid)
    out.unitType, out.npcID = unitType, tonumber(npcID)
  end
  out.guidIsSecret = ns.isSecret(guid)
  return out
end

local printed = {}

local function store(key, build, ...)
  local ok, payload = pcall(build, ...)
  if not ok then payload = { status = "error", err = tostring(payload) } end
  local data = ns.charData()
  local prev = data.events[key]
  data.events[key] = { at = date("%Y-%m-%d %H:%M:%S"), seen = (prev and prev.seen or 0) + 1, data = payload }
  if not printed[key] then
    printed[key] = true
    ns.print("captured " .. key .. (ok and "" or " (with errors)"))
  end
  ns.RefreshExportIfShown()
end

-- Keeps the last few entries of a rolling list (quest accepts / turn-ins).
local function append(key, entry)
  local data = ns.charData()
  local list = data.events[key] or {}
  table.insert(list, 1, entry)
  while #list > 5 do table.remove(list) end
  data.events[key] = list
end

local function merchant()
  local n = GetMerchantNumItems()
  local items = {}
  for i = 1, math.min(n, 6) do
    local item
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
      item = C_MerchantFrame.GetItemInfo(i)
    else
      local name, _, price, stack, available, usable = GetMerchantItemInfo(i)
      item = { name = name, price = price, stackCount = stack, numAvailable = available, isUsable = usable }
    end
    if type(item) == "table" then
      item.link = get("GetMerchantItemLink", i)
      item.itemID = get("GetMerchantItemID", i)
    end
    items[#items + 1] = item
  end
  return {
    npc = npcSnapshot(),
    numItems = n,
    api = (C_MerchantFrame and C_MerchantFrame.GetItemInfo) and "C_MerchantFrame.GetItemInfo" or "GetMerchantItemInfo",
    items = items,
    canRepair = get("CanMerchantRepair"),
  }
end

local function trainer()
  local out = {
    npc = npcSnapshot(),
    isTradeskillTrainer = try("IsTradeskillTrainer"),
    greeting = get("GetTrainerGreetingText"),
  }
  local n = get("GetNumTrainerServices")
  out.numServices = n or "<GetNumTrainerServices missing>"
  if n then
    local services = {}
    for i = 1, math.min(n, 12) do
      local name, rank, category = GetTrainerServiceInfo(i)
      services[#services + 1] = {
        name = name, rank = rank, category = category,
        levelReq = get("GetTrainerServiceLevelReq", i),
        cost = get("GetTrainerServiceCost", i),
      }
    end
    out.services = services
  end
  return out
end

local function taxi()
  local out = { npc = npcSnapshot(), taxiMapID = get("GetTaxiMapID") }
  local n = get("NumTaxiNodes") or 0
  out.numNodes, out.nodes = n, {}
  for i = 1, math.min(n, 8) do
    local x, y = TaxiNodePosition(i)
    out.nodes[i] = { name = TaxiNodeName(i), type = TaxiNodeGetType(i), cost = get("TaxiNodeCost", i), x = x, y = y }
  end
  if out.taxiMapID then
    local rec = try("C_TaxiMap.GetAllTaxiNodes", out.taxiMapID)
    if rec.status == "ok" then rec.value = sample(rec.value, 5) end
    out.allTaxiNodes = rec
  end
  return out
end

local function gossip()
  local function quests(rec)
    if rec.status == "ok" then
      rec.value = sample(rec.value, 5, function(q)
        return { questID = q.questID, title = q.title, level = q.questLevel, trivial = q.isTrivial }
      end)
    end
    return rec
  end
  local options = try("C_GossipInfo.GetOptions")
  if options.status == "ok" then
    options.value = sample(options.value, 8, function(o)
      return { name = o.name, id = o.gossipOptionID, icon = o.icon, flags = o.flags, status = o.status }
    end)
  end
  return {
    npc = npcSnapshot(),
    options = options,
    availableQuests = quests(try("C_GossipInfo.GetAvailableQuests")),
    activeQuests = quests(try("C_GossipInfo.GetActiveQuests")),
  }
end

-- Quest detail / reward screens: reward choices feed "is this an upgrade?".
local function questFrame()
  local out = {
    npc = npcSnapshot(),
    questID = get("GetQuestID"),
    title = get("GetTitleText"),
    rewardXP = get("GetRewardXP"),
    rewardMoney = get("GetRewardMoney"),
    numChoices = get("GetNumQuestChoices"),
    numRewards = get("GetNumQuestRewards"),
  }
  local choices = {}
  for i = 1, math.min(out.numChoices or 0, 6) do
    choices[#choices + 1] = get("GetQuestItemLink", "choice", i)
  end
  out.choiceLinks = choices
  return out
end

local function bank()
  local out, seen = { containers = {} }, {}
  local function scan(label, bag)
    if type(bag) ~= "number" or seen[bag] then return end
    seen[bag] = true
    local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
    if ok and type(slots) == "number" and slots > 0 then
      local used = 0
      for s = 1, slots do
        if C_Container.GetContainerItemInfo(bag, s) then used = used + 1 end
      end
      out.containers[label .. " (" .. bag .. ")"] = slots .. " slots, " .. used .. " used"
    end
  end
  if Enum.BagIndex then
    for name, bag in pairs(Enum.BagIndex) do scan(name, bag) end
  end
  scan("legacyBank", -1)
  for bag = 5, 12 do scan("bag", bag) end
  out.cBank = ns.listFunctions("C_Bank")
  return out
end

local handlers = {
  MERCHANT_SHOW = function() store("merchant", merchant) end,
  TRAINER_SHOW = function() store("trainer", trainer) end,
  TAXIMAP_OPENED = function() store("taxi", taxi) end,
  GOSSIP_SHOW = function() store("gossip", gossip) end,
  QUEST_DETAIL = function() store("questDetail", questFrame) end,
  QUEST_COMPLETE = function() store("questReward", questFrame) end,
  QUEST_GREETING = function() store("questGreeting", npcSnapshot) end,
  -- Bank contents can arrive a moment after the window opens.
  BANKFRAME_OPENED = function() C_Timer.After(0.5, function() store("bank", bank) end) end,
  PLAYER_INTERACTION_MANAGER_FRAME_SHOW = function(interactionType)
    local typeName = ns.enumName(Enum.PlayerInteractionType, interactionType)
    store("interaction:" .. typeName, npcSnapshot)
  end,
  QUEST_ACCEPTED = function(questID)
    local ok, npc = pcall(npcSnapshot)
    append("questAccepted", { questID = questID, npc = ok and npc or tostring(npc), at = date("%H:%M:%S") })
  end,
  QUEST_TURNED_IN = function(questID, xp, money)
    local ok, npc = pcall(npcSnapshot)
    append("questTurnedIn", { questID = questID, xp = xp, money = money, npc = ok and npc or tostring(npc) })
  end,
  QUESTLINE_UPDATE = function()
    if ns.RefreshQuestLines then ns.RefreshQuestLines(true) end
  end,
}

local frame = CreateFrame("Frame")
local registered, unknown = {}, {}
for event in pairs(handlers) do
  if pcall(frame.RegisterEvent, frame, event) then
    registered[#registered + 1] = event
  else
    unknown[#unknown + 1] = event
  end
end
table.sort(registered)
table.sort(unknown)
ns.eventSupport = { registered = table.concat(registered, ", "), unknown = table.concat(unknown, ", ") }

frame:SetScript("OnEvent", function(_, event, ...)
  local ok, err = pcall(handlers[event], ...)
  if not ok then ns.print(event .. " handler error: " .. tostring(err)) end
end)
