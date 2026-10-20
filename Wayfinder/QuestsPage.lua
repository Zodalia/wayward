local _, ns = ...

-- "Quests" page: search quests by name and see whether you can take them.
-- Clicking a quest goes to its quest giver, to where you hand it in, or to the
-- start of its chain. Dungeon quests can be picked up in one trip that ends at
-- the entrance (also offered on the Dungeons page). With an empty search it
-- lists your quest log; "Add" puts a quest (log or search) into the current trip.
-- Searching and directions need quest data (Sources.lua); the log list does not.

-- The Quests side page's "Journal" category (UI/Panel.lua); it searches itself.
local QuestsPage = { id = "journal", label = "Journal", searchable = true,
  placeholder = "Quest name (or shift-click a quest link)" }
ns.QuestsPage = QuestsPage

local MAX_RESULTS = 20
local MIN_LENGTH = 2
local MAX_DUNGEON_ROWS = 2

local GREEN, YELLOW, GREY, RED = "|cff7fd1ae", "|cffffd200", "|cff9d9d9d", "|cffff7f3f"
local NOTABLE, NOTABLE_COLOR = "|cffc58cff", { r = 0.77, g = 0.55, b = 1 }

-- Label, colour and sort rank per status (Quests.lua, Quests.QuestStatus).
local STATUS = {
  available = { "Available", GREEN, 1 },
  inLog = { "In your log", YELLOW, 2 },
  needsEarlier = { "Needs earlier quests", RED, 3 },
  tooLow = { "Too low", RED, 4 },
  unavailable = { "Not available", RED, 5 },
  done = { "Done", GREY, 6 },
  notForYou = { "Not for you", GREY, 7 },
  unknown = { "Not in the quest data", GREY, 8 },
}

local summary

local function unavailableText()
  return "No quest data. Install a Wayfinder data addon to search quests."
end

local function label(status, extra)
  local s = STATUS[status]
  return s[2] .. s[1] .. "|r" .. (extra and ("  ·  " .. extra) or "")
end

-- A notable quest's tag for its row ("  ·  Class quest"), and its reasons as
-- tooltip lines (Notable.lua).
local function notable(questID, details)
  if not ns.Quests.NotableTag then return "" end
  local tag, reasons = ns.Quests.NotableTag(questID)
  for _, r in ipairs(reasons) do details[#details + 1] = { text = r.text, color = NOTABLE_COLOR } end
  return tag and ("  ·  " .. NOTABLE .. tag .. "|r") or ""
end

local function questTitle(q)
  return string.format("[%d] %s", ns.Quests.QuestLevel(q.id) or 0, q.name or ("Quest " .. q.id))
end

---------------------------------------------------------------- dungeon runs

-- A trip that picks up `quests` ({id, name}, ...) from their givers, then goes
-- to the dungeon entrance. Returns a planned journey, or nil when no giver can
-- be reached.
function QuestsPage.DungeonJourney(dungeonName, entrance, quests, start, net)
  local stops = {}
  for _, quest in ipairs(quests) do
    local giver, node = ns.Quests.QuestGiver(quest.id, start)
    if node then
      stops[#stops + 1] = { node = node, text = string.format("Pick up %s from %s", quest.name or "?", giver or "?"),
        giver = giver, action = { kind = "pickup", questID = quest.id } }
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
  for _, group in pairs(ns.Quests.QuestsForAreas(entry.areaIDs)) do
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
    local area = ns.Quests.QuestArea(m.q)
    if area then
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
          and QuestsPage.DungeonJourney(entry.name, ns.Data.Nearest(entry.entrances, start), quests, start, net)
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

---------------------------------------------------------------- the current trip

-- "Add" puts a quest (what's left of it: pick up, objectives, hand in) into the
-- trip you're on, re-ordered from where you are; with no trip on it starts
-- one. "In trip" takes it out again.
local function tripAction(questID, name)
  if ns.Nav.TripHasQuest(questID) then
    return { label = "In trip", run = function() ns.Nav.RemoveQuest(questID) end }
  end
  return { label = "Add", run = function()
    local here = ns.Geo.PlayerNode()
    local stops = here and ns.Journey.QuestStops(questID, here) or {}
    if #stops == 0 then
      ns.print("no known places for " .. (name or "that quest") .. ".")
      return
    end
    ns.Nav.AddToTrip(stops, name or ("quest " .. questID))
  end }
end

---------------------------------------------------------------- quest rows

-- Where clicking a quest goes: a one-stop journey that waits for the pickup or
-- turn-in there. Returns the stop, or nil and why there is none.
local function questStop(m, start)
  local q, status = m.q, m.status
  if status == "available" then
    local giver, node = ns.Quests.QuestGiver(q.id, start)
    if node then
      return { node = node, text = string.format("Pick up %s from %s", q.name, giver or "?"), giver = giver,
        action = { kind = "pickup", questID = q.id } }
    end
    local starters = q.startedBy or {}
    return nil, starters[3] and #starters[3] > 0 and "starts from an item" or "no known quest giver"
  elseif status == "inLog" then
    local finisher, node = ns.Quests.QuestFinisher(q.id, start)
    if node then
      return { node = node, npc = finisher, text = string.format("Hand in %s to %s", q.name, finisher or "?"),
        action = { kind = "turnin", questID = q.id } }
    end
    return nil, "no known place to hand it in"
  elseif status == "needsEarlier" and m.stepID then
    local step = ns.Quests.Quest(m.stepID)
    local stepName = step and step.name or ("quest " .. m.stepID)
    if m.stepState == "available" then
      local giver, node = ns.Quests.QuestGiver(m.stepID, start)
      if node then
        return { node = node, text = string.format("Start the chain: pick up %s from %s", stepName, giver or "?"),
          giver = giver, action = { kind = "pickup", questID = m.stepID } }
      end
    else
      local finisher, node = ns.Quests.QuestFinisher(m.stepID, start)
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
    local step = ns.Quests.Quest(m.stepID)
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
  -- Track the whole quest (pick up, do it, hand it in); for a chain, its first step.
  local target = m.status == "needsEarlier" and m.stepID or q.id
  local stops = stop and ns.Journey.QuestStops(target, start) or {}
  if #stops == 0 and stop then
    stops = { stop }
  elseif target ~= q.id and stops[1] then
    stops[1].text = "Start the chain: " .. stops[1].text:gsub("^%u", string.lower)
  end
  local journey = #stops > 0 and ns.Journey.Plan(start, { title = q.name, stops = stops }, net) or nil
  local sub = rowStatus(m) .. notable(q.id, details)
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
  local actions = (m.status == "available" or m.status == "inLog") and { tripAction(q.id, q.name) } or nil
  return { id = "quest" .. q.id, title = questTitle(q), titleColor = ns.DifficultyColor(ns.Quests.QuestLevel(q.id)),
    subtitle = sub, journey = journey, details = details, actions = actions }
end

---------------------------------------------------------------- quest log

-- Progress on a logged quest: "Ready to hand in", the first objective not
-- done yet ("3/8 Murloc Forager slain"), or nil.
local function progress(questID, complete)
  if complete then return GREEN .. "Ready to hand in|r" end
  for _, o in ipairs(C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID) or {}) do
    if not o.finished and o.text and o.text ~= "" then return o.text end
  end
  return nil
end

-- The quests in your log, in log order:
--   { id, title, level, zone (the log header above it), complete, progress }
function QuestsPage.LogQuests()
  local out, zone = {}, nil
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and info.isHeader then
      zone = info.title
    elseif info and info.questID and not info.isHidden then
      local id = info.questID
      local q = ns.Quests.Quest(id)
      local complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) or false
      out[#out + 1] = { id = id, title = info.title or (q and q.name) or ("Quest " .. id),
        level = (info.level or 0) > 0 and info.level or ns.Quests.QuestLevel(id) or 0,
        zone = zone, complete = complete, progress = progress(id, complete) }
    end
  end
  return out
end

-- One trip for several quests: each quest's own stops keep their order (their
-- `after` links) while the planner interleaves quests by travel time.
-- Returns the journey (or nil) and the IDs with no known places.
function QuestsPage.TripFor(questIDs, title, start, net)
  local stops, missing = {}, {}
  for _, id in ipairs(questIDs) do
    local questStops = ns.Journey.QuestStops(id, start)
    if #questStops == 0 then missing[#missing + 1] = id end
    for _, stop in ipairs(questStops) do stops[#stops + 1] = stop end
  end
  if #stops == 0 then return nil, missing end
  return ns.Journey.Plan(start, { title = title, stops = stops }, net), missing
end

local function questName(id)
  local q = ns.Quests.Quest(id)
  return q and q.name or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)) or ("Quest " .. id)
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

-- "Plan a trip for N quests" and "Hand in N completed quests" rows.
local function tripRow(title, ids, start, net, tripTitle)
  local journey, missing = QuestsPage.TripFor(ids, tripTitle, start, net)
  local unplaced = {}
  for _, id in ipairs(missing) do unplaced[id] = true end
  local details = {}
  for _, id in ipairs(ids) do
    details[#details + 1] = unplaced[id]
      and { text = questName(id) .. " (no known places)", color = { r = 1, g = 0.5, b = 0.25 } }
      or { text = questName(id) }
  end
  local sub
  if journey then
    sub = string.format("%sOne trip|r  ·  %s  ·  %s", GREEN, ns.FormatDuration(journey.seconds),
      plural(#journey.stops, "stop"))
    if #missing > 0 then sub = sub .. string.format("  ·  %s%d without known places|r", RED, #missing) end
  else
    sub = RED .. "No known places for " .. (#ids == 1 and "this quest" or "these quests") .. "|r"
  end
  return { title = title, subtitle = sub, journey = journey, details = details }
end

-- A quest from your log: progress, and a trip for what is left of it (no
-- pickup: it is already in your log).
local function logRow(entry, start, net)
  local parts = {}
  if entry.zone then parts[#parts + 1] = entry.zone end
  parts[#parts + 1] = entry.progress or (YELLOW .. "In progress|r")
  local journey
  if not ns.Quests.Available() then
    parts[#parts + 1] = GREY .. "directions need quest data|r"
  elseif start then
    local stops = ns.Journey.QuestStops(entry.id, start)
    journey = #stops > 0 and ns.Journey.Plan(start, { title = entry.title, stops = stops }, net) or nil
    if journey then
      parts[#parts + 1] = ns.FormatDuration(journey.seconds)
      if stops[#stops].action.kind ~= "turnin" then parts[#parts + 1] = "hand-in place unknown" end
    else
      parts[#parts + 1] = #stops > 0 and "no route found from here" or "no known places for it"
    end
  end
  local details = {}
  for _, o in ipairs(C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(entry.id) or {}) do
    if o.text and o.text ~= "" then
      details[#details + 1] = { text = o.text, color = o.finished and { r = 0.6, g = 0.6, b = 0.6 } or nil }
    end
  end
  local tag = ns.Quests.Available() and notable(entry.id, details) or ""
  return { id = "log" .. entry.id, title = string.format("[%d] %s", entry.level, entry.title),
    titleColor = ns.DifficultyColor(entry.level),
    subtitle = table.concat(parts, "  ·  ") .. tag, journey = journey, details = details,
    actions = ns.Quests.Available() and { tripAction(entry.id, entry.title) } or nil }
end

-- Empty search: trip rows for picked and completed quests, then the log.
local function logResults()
  local log = QuestsPage.LogQuests()
  local available = ns.Quests.Available()
  local start = ns.Geo.PlayerNode()
  local net = available and start and ns.Network.Build() or nil
  local results = {}
  if available and start then
    local complete = {}
    for _, entry in ipairs(log) do
      if entry.complete then complete[#complete + 1] = entry.id end
    end
    if #complete > 0 then
      local row = tripRow("Hand in " .. plural(#complete, "completed quest"), complete, start, net, "Hand in quests")
      row.id = "handin"
      if row.journey and ns.Nav.active then
        local journey = row.journey
        row.actions = { { label = "Add", run = function()
          ns.Nav.AddToTrip(ns.Journey.OpenStops(journey), "the hand-ins")
        end } }
      end
      results[#results + 1] = row
    end
  end
  for _, entry in ipairs(log) do results[#results + 1] = logRow(entry, start, net) end

  if #log == 0 then
    summary = nil
  elseif not available then
    summary = string.format("Your quest log: %s. No quest data. Install a Wayfinder data addon for directions and to search quests.",
      plural(#log, "quest"))
  else
    summary = string.format("Your quest log: %s. Click one for a trip, or Add it to the trip you're on. "
      .. "Type to search all quests.", plural(#log, "quest"))
  end
  return results, nil, net
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
  local available = ns.Quests.Available()
  if parse(query) == "" then
    return summary or (available and "Find a quest: whether you can take it, and where to go." or unavailableText())
  end
  if not available then return unavailableText() end
  return summary or ""
end

function QuestsPage.EmptyText(query)
  local text = parse(query)
  if text == "" then
    return "Your quest log is empty." .. (ns.Quests.Available() and " Type a quest name to search." or "")
  end
  if #text < MIN_LENGTH then return "Type a quest name (at least " .. MIN_LENGTH .. " letters)." end
  return string.format("No quest called \"%s\" in the quest data.", text)
end

function QuestsPage.Results(query)
  summary = nil
  local text, linkedID, linkedName = parse(query)
  if text == "" then return logResults() end
  if not ns.Quests.Available() then return {}, unavailableText() end
  if not linkedID and #text < MIN_LENGTH then return {} end
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local done, inLog = ns.Quests.PlayerQuestState()

  local found
  if linkedID then
    local q = ns.Quests.Quest(linkedID)
    if not q then
      summary = "That quest isn't in the quest data."
      return { { title = linkedName or ("Quest " .. linkedID), subtitle = label("unknown") } }, nil, net
    end
    found = { q }
  else
    found = ns.Quests.FindQuests(text)
  end

  local needle, matches = text:lower(), {}
  for _, q in ipairs(found) do
    local status, reason, stepID, stepState = ns.Quests.QuestStatus(q.id, done, inLog)
    local name = (q.name or ""):lower()
    matches[#matches + 1] = { q = q, status = status, reason = reason, stepID = stepID, stepState = stepState,
      exact = name == needle, prefix = name:sub(1, #needle) == needle, level = ns.Quests.QuestLevel(q.id) or 0 }
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


ns.RegisterCommand("quest", "/wf quest <name> - find a quest: can you take it, and where to go", function(rest)
  ns.Panel.Search("quests", rest)
end)
