local _, ns = ...

-- Static probes: run on /wfprobe. Each answers "does this API exist in Forever,
-- and does it return data the levelling helper could use?"

local try, sample, get = ns.try, ns.sample, ns.get

local probes = {}
local function probe(category, name, fn)
  probes[#probes + 1] = { category = category, name = name, fn = fn }
end

-- Where the player is, shared by the map-based probes.
local ctx = {}

local function buildContext()
  wipe(ctx)
  ctx.mapID = C_Map.GetBestMapForUnit("player")
  ctx.chain = {}
  local id, guard = ctx.mapID, 0
  while id and id > 0 and guard < 10 do
    local info = C_Map.GetMapInfo(id)
    if not info then break end
    ctx.chain[#ctx.chain + 1] = string.format("%d %s (%s)", info.mapID, info.name or "?",
      ns.enumName(Enum.UIMapType, info.mapType))
    if Enum.UIMapType and info.mapType == Enum.UIMapType.Continent then
      ctx.continentID = info.mapID
    end
    id, guard = info.parentMapID, guard + 1
  end
end

-- Runs fn for the player's zone and its continent (if different).
local function forMaps(fn)
  local out = {}
  if ctx.mapID then out["zone" .. ctx.mapID] = fn(ctx.mapID) end
  if ctx.continentID and ctx.continentID ~= ctx.mapID then
    out["continent" .. ctx.continentID] = fn(ctx.continentID)
  end
  return out
end

local function count(rec)
  return rec.status == "ok" and type(rec.value) == "table" and #rec.value or 0
end

local function pos(p)
  if type(p) ~= "table" then return nil end
  return string.format("%.3f,%.3f", p.x or -1, p.y or -1)
end

---------------------------------------------------------------- meta

probe("meta", "build", function()
  local version, build, buildDate, interface = GetBuildInfo()
  local projects = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and k:find("^WOW_PROJECT_") then projects[k] = v end
  end
  ns.headline("interface", interface)
  ns.headline("build", tostring(version) .. " (" .. tostring(build) .. ")")
  return { version = version, build = build, date = buildDate, interface = interface, projects = projects }
end)

probe("meta", "foreverGlobals", function()
  local hits = {}
  for k, v in pairs(_G) do
    if type(k) == "string" then
      local lk = k:lower()
      if lk:find("forever") or lk:find("camelot") then hits[#hits + 1] = k .. ":" .. type(v) end
    end
  end
  table.sort(hits)
  return { count = #hits, names = table.concat(hits, ", ") }
end)

probe("meta", "namespaces", function()
  local names = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and k:find("^C_") and type(v) == "table" then names[#names + 1] = k end
  end
  table.sort(names)
  return { count = #names, names = table.concat(names, " ") }
end)

probe("meta", "gameRules", function()
  return {
    functions = ns.listFunctions("C_GameRules"),
    activeGameMode = try("C_GameRules.GetActiveGameMode"),
    gameModeEnum = Enum.GameMode,
  }
end)

probe("meta", "secretValues", function()
  local found = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and k:lower():find("secret") and type(v) == "function" then
      found[#found + 1] = k
    end
  end
  table.sort(found)
  return {
    functions = table.concat(found, ", "),
    playerHealthIsSecret = ns.isSecret(UnitHealth("player")),
    playerMapIDIsSecret = ns.isSecret(ctx.mapID),
  }
end)

probe("meta", "savedVariables", function()
  ns.headline("savedVariables", ns.svCheck and ns.svCheck.verdict)
  return ns.svCheck
end)

probe("meta", "events", function()
  return ns.eventSupport
end)

---------------------------------------------------------------- player

probe("player", "unit", function()
  local _, classFile, classID = UnitClass("player")
  local _, raceFile, raceID = UnitRace("player")
  return {
    level = UnitLevel("player"),
    maxLevel = get("GetMaxPlayerLevel"),
    class = classFile, classID = classID,
    race = raceFile, raceID = raceID,
    faction = UnitFactionGroup("player"),
    xp = get("UnitXP", "player"), xpMax = get("UnitXPMax", "player"),
    restedXP = get("GetXPExhaustion"),
    money = get("GetMoney"),
    bindLocation = get("GetBindLocation"),
    zone = get("GetRealZoneText"), subZone = get("GetSubZoneText"),
  }
end)

probe("player", "position", function()
  local out = { mapID = ctx.mapID, continentID = ctx.continentID, chain = ctx.chain }
  if ctx.mapID then
    local p = C_Map.GetPlayerMapPosition(ctx.mapID, "player")
    if p then
      out.x, out.y = p:GetXY()
      local continent, world = C_Map.GetWorldPosFromMapPos(ctx.mapID, p)
      out.worldContinentID = continent
      if world then out.worldX, out.worldY = world:GetXY() end
    end
  end
  out.unitPosition = try("UnitPosition", "player")
  ns.headline("playerMapPosition", out.x ~= nil)
  ns.headline("worldPosition", out.worldX ~= nil)
  return out
end)

---------------------------------------------------------------- map

probe("map", "zonesOnContinent", function()
  if not ctx.continentID then return { status = "empty", note = "player is not on a continent map" } end
  local rec = try("C_Map.GetMapChildrenInfo", ctx.continentID, Enum.UIMapType.Zone, true)
  ns.headline("zonesOnContinent", count(rec))
  if rec.status == "ok" then
    rec.value = sample(rec.value, 50, function(m) return m.mapID .. " " .. m.name end)
  end
  return rec
end)

probe("map", "mapLinks", function()
  return forMaps(function(id)
    local rec = try("C_Map.GetMapLinksForMap", id)
    if rec.status == "ok" then
      rec.value = sample(rec.value, 8, function(l)
        return { name = l.name, linkedMap = l.linkedUiMapID, atlas = l.atlasName, pos = pos(l.position) }
      end)
    end
    return rec
  end)
end)

probe("map", "areaPOIs", function()
  return forMaps(function(id)
    local rec = try("C_AreaPoiInfo.GetAreaPOIForMap", id)
    ns.headlineMax("areaPOIs", count(rec))
    if rec.status == "ok" then
      rec.value = sample(rec.value, 10, function(poiID)
        local info = C_AreaPoiInfo.GetAreaPOIInfo(id, poiID)
        if not info then return poiID end
        return { id = poiID, name = info.name, atlas = info.atlasName, pos = pos(info.position) }
      end)
    end
    return rec
  end)
end)

probe("map", "vignettes", function()
  local rec = try("C_VignetteInfo.GetVignettes")
  if rec.status == "ok" then
    rec.value = sample(rec.value, 8, function(guid)
      local info = C_VignetteInfo.GetVignetteInfo(guid)
      local p = ctx.mapID and C_VignetteInfo.GetVignettePosition(guid, ctx.mapID)
      return info and { name = info.name, atlas = info.atlasName, type = info.type, pos = pos(p) } or guid
    end)
  end
  return rec
end)

probe("map", "minimapTracking", function()
  local n = get("C_Minimap.GetNumTrackingTypes")
  if not n then return { status = "missing", legacy = type(GetNumTrackingTypes) == "function" } end
  local names = {}
  for i = 1, n do
    local info = C_Minimap.GetTrackingInfo(i)
    if type(info) == "table" then
      names[#names + 1] = tostring(info.name)
    elseif info ~= nil then
      names[#names + 1] = tostring(info)
    end
  end
  return { count = n, names = table.concat(names, ", ") }
end)

---------------------------------------------------------------- navigation

probe("navigation", "waypointAPIs", function()
  local canSet = try("C_Map.CanSetUserWaypointOnMap", ctx.mapID)
  ns.headline("userWaypointsAllowedHere", canSet.value == true)
  return {
    canSetOnZone = canSet,
    hasUserWaypoint = try("C_Map.HasUserWaypoint"),
    uiMapPoint = type(UiMapPoint) == "table" and type(UiMapPoint.CreateFromCoordinates) == "function",
    superTrack = ns.listFunctions("C_SuperTrack"),
    navigation = ns.listFunctions("C_Navigation"),
  }
end)

---------------------------------------------------------------- travel

probe("travel", "taxiNodesForMap", function()
  return forMaps(function(id)
    local rec = try("C_TaxiMap.GetTaxiNodesForMap", id)
    ns.headlineMax("taxiNodesOnMap", count(rec))
    if rec.status == "ok" then
      rec.value = sample(rec.value, 8, function(t)
        return { id = t.nodeID, name = t.name, state = ns.enumName(Enum.FlightPathState, t.state),
          faction = t.faction, pos = pos(t.position) }
      end)
    end
    return rec
  end)
end)

probe("travel", "allTaxiNodesOutsideTaxiWindow", function()
  local rec = try("C_TaxiMap.GetAllTaxiNodes", ctx.continentID or ctx.mapID)
  if rec.status == "ok" then rec.value = sample(rec.value, 3) end
  return rec
end)

---------------------------------------------------------------- quests

probe("quests", "questLog", function()
  local n = C_QuestLog.GetNumQuestLogEntries()
  local quests, withWaypoint = {}, 0
  for i = 1, n do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader then
      local wp = try("C_QuestLog.GetNextWaypoint", info.questID)
      if wp.values then withWaypoint = withWaypoint + 1 end
      if #quests < 8 then
        quests[#quests + 1] = {
          id = info.questID, title = info.title, level = info.level,
          difficulty = info.difficultyLevel, suggestedGroup = info.suggestedGroup,
          complete = info.isComplete, onMap = info.isOnMap, hasLocalPOI = info.hasLocalPOI,
          objectives = try("C_QuestLog.GetQuestObjectives", info.questID),
          nextWaypoint = wp,
        }
      end
    end
  end
  ns.headline("questLogEntries", n)
  ns.headline("questsWithNextWaypoint", withWaypoint)
  return { entries = n, sampled = quests }
end)

probe("quests", "questsOnMap", function()
  return forMaps(function(id)
    local rec = try("C_QuestLog.GetQuestsOnMap", id)
    ns.headlineMax("questPOIsOnMap", count(rec))
    if rec.status == "ok" then
      rec.value = sample(rec.value, 8, function(q)
        return string.format("%d @ %.3f,%.3f", q.questID, q.x or -1, q.y or -1)
      end)
    end
    return rec
  end)
end)

probe("quests", "completedQuests", function()
  local all = try("C_QuestLog.GetAllCompletedQuestIDs")
  local out = { getAllCompletedQuestIDs = all.status, legacyGetQuestsCompleted = try("GetQuestsCompleted").status }
  if all.status == "ok" then
    out.count = #all.value
    out.firstIDs = table.concat(all.value, ", ", 1, math.min(#all.value, 10))
  end
  out.isQuestFlaggedCompleted = type(C_QuestLog.IsQuestFlaggedCompleted) == "function"
  ns.headline("completedQuestsKnown", out.count or all.status)
  return out
end)

-- C_QuestLine is what retail's world map uses for "!" quest-start pins. If it
-- works in Forever we get quest givers with coordinates without shipping data.
local function questLineSnapshot()
  return forMaps(function(id)
    local rec = try("C_QuestLine.GetAvailableQuestLines", id)
    ns.headlineMax("questLinesAvailable", count(rec))
    if rec.status == "ok" then
      rec.value = sample(rec.value, 8, function(q)
        return { line = q.questLineName, quest = q.questName, questID = q.questID,
          x = q.x, y = q.y, hidden = q.isHidden, campaign = q.isCampaign }
      end)
    end
    return rec
  end)
end

probe("quests", "questLines", function()
  forMaps(function(id) return try("C_QuestLine.RequestQuestLinesForMap", id) end)
  return questLineSnapshot()
end)

probe("quests", "taskQuests", function()
  return forMaps(function(id)
    local rec = try("C_TaskQuest.GetQuestsOnMap", id)
    if rec.status == "missing" then rec = try("C_TaskQuest.GetQuestsForPlayerByMapID", id) end
    if rec.status == "ok" then rec.value = sample(rec.value, 5) end
    return rec
  end)
end)

---------------------------------------------------------------- dungeons

probe("dungeons", "entrancesOnMap", function()
  return forMaps(function(id)
    local rec = try("C_EncounterJournal.GetDungeonEntrancesForMap", id)
    ns.headlineMax("dungeonEntrances", count(rec))
    if rec.status == "ok" then
      rec.value = sample(rec.value, 10, function(d)
        return { name = d.name, journalInstanceID = d.journalInstanceID, atlas = d.atlasName, pos = pos(d.position) }
      end)
    end
    return rec
  end)
end)

probe("dungeons", "encounterJournal", function()
  local numTiers = get("EJ_GetNumTiers")
  if not numTiers then return { status = "missing" } end
  local previous = get("EJ_GetCurrentTier")
  local tiers = {}
  for t = 1, numTiers do
    EJ_SelectTier(t)
    local entry = { name = EJ_GetTierInfo(t) }
    for _, isRaid in ipairs({ false, true }) do
      local names = {}
      for i = 1, 100 do
        local instanceID, name = EJ_GetInstanceByIndex(i, isRaid)
        if not instanceID then break end
        names[#names + 1] = instanceID .. " " .. tostring(name)
      end
      entry[isRaid and "raids" or "dungeons"] = table.concat(names, ", ")
    end
    tiers[t] = entry
  end
  if previous then EJ_SelectTier(previous) end
  return { numTiers = numTiers, tiers = tiers }
end)

-- LFG dungeon records carry min/max/recommended levels, which is exactly what
-- "Dungeons for my level" needs.
probe("dungeons", "lfgDungeonInfo", function()
  if type(GetLFGDungeonInfo) ~= "function" then return { status = "missing" } end
  local total, listed = 0, {}
  for id = 1, 3000 do
    local ok, name, typeID, _, minLevel, maxLevel, recLevel, _, _, expansion, _, _, _, maxPlayers =
      pcall(GetLFGDungeonInfo, id)
    if ok and name then
      total = total + 1
      if #listed < 60 and type(minLevel) == "number" and minLevel <= 60 then
        listed[#listed + 1] = string.format("%d %s [%s-%s rec %s] type=%s exp=%s players=%s",
          id, name, tostring(minLevel), tostring(maxLevel), tostring(recLevel),
          tostring(typeID), tostring(expansion), tostring(maxPlayers))
      end
    end
  end
  ns.headline("lfgDungeonsUpTo60", #listed)
  return { total = total, upTo60 = listed, numRandomDungeons = try("GetNumRandomDungeons") }
end)

---------------------------------------------------------------- character

local SLOTS = {
  "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot",
  "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
  "Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot", "AmmoSlot",
}

probe("character", "equipment", function()
  local slots, statsSample = {}, nil
  for _, slotName in ipairs(SLOTS) do
    local ok, slotID = pcall(GetInventorySlotInfo, slotName)
    if not ok or not slotID then
      slots[slotName] = "<no such slot>"
    else
      local link = GetInventoryItemLink("player", slotID)
      if not link then
        slots[slotName] = "empty"
      else
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local name, _, quality, _, reqLevel, _, subType, _, equipLoc = getInfo(link)
        local ilvl = get("C_Item.GetDetailedItemLevelInfo", link)
        slots[slotName] = string.format("%s ilvl=%s q=%s req=%s %s/%s", tostring(name), tostring(ilvl),
          tostring(quality), tostring(reqLevel), tostring(equipLoc), tostring(subType))
        if not statsSample then statsSample = { item = name, stats = try("C_Item.GetItemStats", link) } end
      end
    end
  end
  ns.headline("equippedSlotsReadable", slots.ChestSlot ~= nil)
  return { slots = slots, averageItemLevel = try("GetAverageItemLevel"), statsSample = statsSample }
end)

probe("character", "bags", function()
  local bags = {}
  for bag = 0, 5 do
    local slots = C_Container.GetContainerNumSlots(bag)
    local used, items = 0, {}
    for slot = 1, slots do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info then
        used = used + 1
        if #items < 3 then
          items[#items + 1] = string.format("%s x%s q=%s", tostring(info.itemID), tostring(info.stackCount),
            tostring(info.quality))
        end
      end
    end
    bags["bag" .. bag] = { slots = slots, used = used, items = items }
  end
  return { bags = bags, bagIndexEnum = Enum.BagIndex }
end)

probe("character", "professions", function()
  local out = { getProfessions = try("GetProfessions") }
  local list = {}
  if out.getProfessions.status == "ok" then
    -- Returns (prof1, prof2, archaeology, fishing, cooking) with nil gaps.
    local indices = { GetProfessions() }
    for i = 1, 5 do
      if indices[i] then
        local name, _, rank, maxRank = GetProfessionInfo(indices[i])
        list[#list + 1] = string.format("%s %s/%s", tostring(name), tostring(rank), tostring(maxRank))
      end
    end
  end
  out.list = list
  out.legacyGetNumSkillLines = try("GetNumSkillLines")
  return out
end)

-- Retail's spellbook lists not-yet-learned spells with the level they unlock.
-- If Forever keeps that, "new spells at your trainer" needs no shipped data.
probe("character", "spellbook", function()
  if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then
    return { status = "missing", legacyGetNumSpellTabs = type(GetNumSpellTabs) == "function" }
  end
  local bank = Enum.SpellBookSpellBank.Player
  local counts, future = {}, {}
  for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
    local li = C_SpellBook.GetSpellBookSkillLineInfo(line)
    if li then
      for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
        local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
        if item then
          local typeName = ns.enumName(Enum.SpellBookItemType, item.itemType)
          counts[typeName] = (counts[typeName] or 0) + 1
          if item.itemType == Enum.SpellBookItemType.FutureSpell and #future < 10 then
            future[#future + 1] = string.format("%s (level %s)", tostring(item.name),
              tostring(get("C_SpellBook.GetSpellBookItemLevelLearned", i, bank)))
          end
        end
      end
    end
  end
  ns.headline("futureSpellsListed", counts.FutureSpell or 0)
  return { itemTypeCounts = counts, futureSpells = future }
end)

---------------------------------------------------------------- runner

function ns.RunAll()
  local data = ns.charData()
  ns.currentHeadline = {}
  data.headline = ns.currentHeadline
  data.probes = {}
  data.meta = { addonVersion = ns.VERSION, runAt = date("%Y-%m-%d %H:%M:%S") }

  local ok, err = pcall(buildContext)
  data.context = ok and { mapID = ctx.mapID, continentID = ctx.continentID, chain = ctx.chain }
    or { status = "error", err = tostring(err) }

  local tally = { ok = 0, empty = 0, missing = 0, error = 0 }
  for _, p in ipairs(probes) do
    local success, res = pcall(p.fn)
    local rec
    if not success then
      rec = { status = "error", err = tostring(res) }
    elseif type(res) == "table" and res.status then
      rec = res
    else
      rec = { status = res == nil and "empty" or "ok", value = res }
    end
    data.probes[p.category] = data.probes[p.category] or {}
    data.probes[p.category][p.name] = rec
    tally[rec.status] = (tally[rec.status] or 0) + 1
  end

  ns.print(string.format("%d probes: %d ok, %d empty, %d missing, %d errors. Re-checking quest lines in 3s...",
    #probes, tally.ok, tally.empty, tally.missing, tally.error))
  C_Timer.After(3, ns.RefreshQuestLines)
end

-- Quest lines load asynchronously after RequestQuestLinesForMap, so look again.
-- `silent` is used for QUESTLINE_UPDATE, which can fire often.
function ns.RefreshQuestLines(silent)
  local data = ns.charData()
  if not (ctx.mapID and data.probes and data.probes.quests) then return end
  local ok, res = pcall(questLineSnapshot)
  data.probes.quests.questLinesAfterDelay = ok and { status = "ok", value = res }
    or { status = "error", err = tostring(res) }
  if silent then return end
  ns.print("quest lines re-checked: " .. tostring(ns.currentHeadline.questLinesAvailable or 0) .. " available.")
  ns.RefreshExportIfShown()
end

function ns.TestWaypoint(clear)
  if clear then
    ns.print("clear waypoint: " .. try("C_Map.ClearUserWaypoint").status)
    return
  end
  local mapID = C_Map.GetBestMapForUnit("player")
  local p = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not p then
    ns.print("no map position here (instance or restricted area?).")
    return
  end
  local x, y = p:GetXY()
  local tx = x < 0.5 and x + 0.03 or x - 0.03
  local out = { target = { mapID = mapID, x = tx, y = y } }
  out.canSet = try("C_Map.CanSetUserWaypointOnMap", mapID)
  local point = UiMapPoint and UiMapPoint.CreateFromCoordinates(mapID, tx, y)
  out.set = try("C_Map.SetUserWaypoint", point)
  out.superTrack = try("C_SuperTrack.SetSuperTrackedUserWaypoint", true)
  C_Timer.After(1, function()
    out.isSuperTracking = try("C_SuperTrack.IsSuperTrackingUserWaypoint")
    out.distance = try("C_Navigation.GetDistance")
    local data = ns.charData()
    data.probes.navigation = data.probes.navigation or {}
    data.probes.navigation.waypointTest = { status = "ok", value = out }
    data.headline = data.headline or {}
    data.headline.waypointTestDistance = out.distance.value
    ns.print(string.format("waypoint placed ~3%% of the map %s of you (distance %s). "
      .. "Note whether you see the pin and the on-screen arrow.",
      x < 0.5 and "east" or "west", tostring(out.distance.value)))
    ns.RefreshExportIfShown()
  end)
end
