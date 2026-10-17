local _, ns = ...

-- "Quests" page: search quests by name and see whether you can take them.
-- Clicking a quest goes to its quest giver, to where you hand it in, or to the
-- start of its chain. Dungeon quests can be picked up in one trip that ends at
-- the entrance (also offered on the Dungeons page). Needs QuestieDB.

local QuestsPage = { id = "quests", label = "Quests", order = 30, searchable = true,
  placeholder = "Quest name (or shift-click a quest link)" }
ns.QuestsPage = QuestsPage

local MAX_RESULTS = 20
local MIN_LENGTH = 2
local MAX_DUNGEON_ROWS = 2

local GREEN, YELLOW, GREY, RED = "|cff7fd1ae", "|cffffd200", "|cff9d9d9d", "|cffff7f3f"

-- Label, colour and sort rank per status (QuestieBridge.lua, Bridge.QuestStatus).
local STATUS = {
  available = { "Available", GREEN, 1 },
  inLog = { "In your log", YELLOW, 2 },
  needsEarlier = { "Needs earlier quests", RED, 3 },
  tooLow = { "Too low", RED, 4 },
  unavailable = { "Not available", RED, 5 },
  done = { "Done", GREY, 6 },
  notForYou = { "Not for you", GREY, 7 },
  unknown = { "Unknown to QuestieDB", GREY, 8 },
}

local summary

local function unavailableText()
  local _, reason = ns.Questie.Available()
  return (reason or "QuestieDB is not available") .. ". Install QuestieDB to search quests."
end

local function label(status, extra)
  local s = STATUS[status]
  return s[2] .. s[1] .. "|r" .. (extra and ("  ·  " .. extra) or "")
end

local function questTitle(q)
  return string.format("[%d] %s", ns.Questie.QuestLevel(q.id) or 0, q.name or ("Quest " .. q.id))
end

---------------------------------------------------------------- dungeon runs

-- A trip that picks up `quests` ({id, name}, ...) from their givers, then goes
-- to the dungeon entrance. Returns a planned journey, or nil when no giver can
-- be reached.
function QuestsPage.DungeonJourney(dungeonName, entrance, quests, start, net)
  local stops = {}
  for _, quest in ipairs(quests) do
    local giver, node = ns.Questie.QuestGiver(quest.id, start)
    if node then
      stops[#stops + 1] = { node = node, text = string.format("Pick up %s from %s", quest.name or "?", giver or "?"),
        action = { kind = "pickup", questID = quest.id } }
    end
  end
  if #stops == 0 then return nil end
  return ns.Journey.Plan(start, { title = dungeonName .. " quests", stops = stops,
    finish = { node = entrance, text = "Enter " .. dungeonName } }, net)
end

-- Row action on the Dungeons page.
function QuestsPage.StartDungeonRun(dungeonName, entrance, quests)
  local start = ns.Geo.PlayerNode()
  local journey = start and QuestsPage.DungeonJourney(dungeonName, entrance, quests, start)
  if not journey then
    ns.print("no quest giver for " .. dungeonName .. " can be reached from here.")
    return
  end
  ns.Nav.StartJourney(journey)
  if ns.Panel.IsShown() then ns.Panel.Toggle() end
end

-- Quests you can take for a catalogue dungeon (ns.Dungeons.Catalogue()).
local function dungeonQuests(entry)
  local available = {}
  for _, group in pairs(ns.Questie.QuestsForAreas(entry.areaIDs)) do
    for _, quest in ipairs(group.available) do available[#available + 1] = quest end
  end
  table.sort(available, function(a, b) return a.id < b.id end)
  return available
end

-- "The Deadmines: pick up 2 quests" rows for dungeons the matches belong to.
local function dungeonRows(matches, start, net)
  local byArea
  local rows, seen = {}, {}
  for _, m in ipairs(matches) do
    local area = m.q.zoneOrSort
    if type(area) == "number" and area > 0 then
      if not byArea then
        byArea = {}
        for _, entry in ipairs(ns.Dungeons.Catalogue()) do
          for areaID in pairs(entry.areaIDs) do byArea[areaID] = entry end
        end
      end
      local entry = byArea[area]
      if entry and not seen[entry] and #entry.entrances > 0 then
        seen[entry] = true
        local quests = dungeonQuests(entry)
        local journey = #quests > 0
          and QuestsPage.DungeonJourney(entry.name, ns.Questie.Nearest(entry.entrances, start), quests, start, net)
        if journey then
          local details = {}
          for _, stop in ipairs(journey.stops) do details[#details + 1] = { text = stop.text } end
          rows[#rows + 1] = {
            title = string.format("%s: pick up %d quest%s", entry.name, #quests, #quests == 1 and "" or "s"),
            subtitle = string.format("%sDungeon quest run|r  ·  %s  ·  ends at the entrance", GREEN,
              ns.FormatDuration(journey.seconds)),
            journey = journey,
          }
          if #rows >= MAX_DUNGEON_ROWS then break end
        end
      end
    end
  end
  return rows
end

---------------------------------------------------------------- quest rows

-- Where clicking a quest goes: a one-stop journey that waits for the pickup or
-- turn-in there. Returns the stop, or nil and why there is none.
local function questStop(m, start)
  local q, status = m.q, m.status
  if status == "available" then
    local giver, node = ns.Questie.QuestGiver(q.id, start)
    if node then
      return { node = node, text = string.format("Pick up %s from %s", q.name, giver or "?"),
        action = { kind = "pickup", questID = q.id } }
    end
    local starters = q.startedBy or {}
    return nil, starters[3] and #starters[3] > 0 and "starts from an item" or "no known quest giver"
  elseif status == "inLog" then
    local finisher, node = ns.Questie.QuestFinisher(q.id, start)
    if node then
      return { node = node, text = string.format("Hand in %s to %s", q.name, finisher or "?"),
        action = { kind = "turnin", questID = q.id } }
    end
    return nil, "no known place to hand it in"
  elseif status == "needsEarlier" and m.stepID then
    local step = ns.Questie.Quest(m.stepID)
    local stepName = step and step.name or ("quest " .. m.stepID)
    if m.stepState == "available" then
      local giver, node = ns.Questie.QuestGiver(m.stepID, start)
      if node then
        return { node = node, text = string.format("Start the chain: pick up %s from %s", stepName, giver or "?"),
          action = { kind = "pickup", questID = m.stepID } }
      end
    else
      local finisher, node = ns.Questie.QuestFinisher(m.stepID, start)
      if node then
        return { node = node, text = string.format("Finish %s first: hand it in to %s", stepName, finisher or "?"),
          action = { kind = "turnin", questID = m.stepID } }
      end
    end
    return nil, "no known place for " .. stepName
  end
  return nil
end

-- Short status for the row; the full reason goes in the tooltip.
local function rowStatus(m)
  if m.status == "needsEarlier" and m.stepID then
    local step = ns.Questie.Quest(m.stepID)
    local name = step and step.name or ("quest " .. m.stepID)
    return label(m.status, (m.stepState == "available" and "start: " or "finish: ") .. name)
  elseif m.status == "tooLow" then
    return label(m.status, "level " .. (m.q.requiredLevel or "?"))
  elseif m.status == "notForYou" then
    return STATUS.notForYou[2] .. ((m.reason or "Not for you"):gsub("%.$", "")) .. "|r"
  elseif m.status == "available" and m.reason and not m.reason:find("^You can") then
    return label(m.status, (m.reason:gsub("%.$", "")))
  end
  return label(m.status)
end

local function questRow(m, start, net)
  local q = m.q
  local details = { { text = m.reason or "" } }
  local stop, why = questStop(m, start)
  local journey = stop and ns.Journey.Plan(start, { title = q.name, stops = { stop } }, net)
  local sub = rowStatus(m)
  if journey then
    sub = sub .. "  ·  " .. ns.FormatDuration(journey.seconds)
  elseif stop then
    sub = sub .. "  ·  no route found from here"
  elseif why then
    sub = sub .. "  ·  " .. why
  end
  if (q.requiredLevel or 0) > 0 then
    details[#details + 1] = { text = "Requires level " .. q.requiredLevel, color = { r = 0.7, g = 0.7, b = 0.7 } }
  end
  return { id = "quest" .. q.id, title = questTitle(q), subtitle = sub, journey = journey, details = details }
end

---------------------------------------------------------------- search

local function rank(a, b)
  if a.exact ~= b.exact then return a.exact end
  local ra, rb = STATUS[a.status][3], STATUS[b.status][3]
  if ra ~= rb then return ra < rb end
  if a.prefix ~= b.prefix then return a.prefix end
  if a.level ~= b.level then return a.level < b.level end
  return a.q.id < b.q.id
end

-- Text typed, or the quest of a shift-clicked link (|Hquest:id:...|h[Name]|h).
local function parse(text)
  text = (text or ""):match("^%s*(.-)%s*$")
  local linked = tonumber(text:match("|Hquest:(%d+)") or text:match("^#(%d+)$"))
  return text, linked, text:match("|h%[(.-)%]|h")
end

function QuestsPage.SummaryText(query)
  if not ns.Questie.Available() then return unavailableText() end
  if parse(query) == "" then return "Find a quest: whether you can take it, and where to go." end
  return summary or ""
end

function QuestsPage.EmptyText(query)
  local text = parse(query)
  if #text < MIN_LENGTH then return "Type a quest name (at least " .. MIN_LENGTH .. " letters)." end
  return string.format("No quest called \"%s\" in QuestieDB.", text)
end

function QuestsPage.Results(query)
  summary = nil
  if not ns.Questie.Available() then return {}, unavailableText() end
  local text, linkedID, linkedName = parse(query)
  if not linkedID and #text < MIN_LENGTH then return {} end
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local done, inLog = ns.Questie.PlayerQuestState()

  local found
  if linkedID then
    local q = ns.Questie.Quest(linkedID)
    if not q then
      summary = "That quest isn't in QuestieDB."
      return { { title = linkedName or ("Quest " .. linkedID), subtitle = label("unknown") } }, nil, net
    end
    found = { q }
  else
    found = ns.Questie.FindQuests(text)
  end

  local needle, matches = text:lower(), {}
  for _, q in ipairs(found) do
    local status, reason, stepID, stepState = ns.Questie.QuestStatus(q.id, done, inLog)
    local name = (q.name or ""):lower()
    matches[#matches + 1] = { q = q, status = status, reason = reason, stepID = stepID, stepState = stepState,
      exact = name == needle, prefix = name:sub(1, #needle) == needle, level = ns.Questie.QuestLevel(q.id) or 0 }
  end
  table.sort(matches, rank)

  local shown = {}
  for i = 1, math.min(#matches, MAX_RESULTS) do shown[i] = matches[i] end
  local results = dungeonRows(shown, start, net)
  for _, m in ipairs(shown) do results[#results + 1] = questRow(m, start, net) end

  if #matches > MAX_RESULTS then
    summary = string.format("First %d of %d quests matching \"%s\". Type more to narrow it down.", MAX_RESULTS,
      #matches, text)
  elseif #matches > 0 then
    summary = string.format("%d quest%s matching \"%s\". Click one to go there.", #matches,
      #matches == 1 and "" or "s", linkedName or text)
  end
  return results, nil, net
end

ns.RegisterPage(QuestsPage)

ns.RegisterCommand("quest", "/wf quest <name> - find a quest: can you take it, and where to go", function(rest)
  ns.Panel.Search("quests", rest)
end)
