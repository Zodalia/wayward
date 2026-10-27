local ADDON, ns = ...

ns.VERSION = "0.4.0"
ns.data = {}

function ns.print(msg)
  print("|cff7fd1aeWayward:|r " .. tostring(msg))
end

---------------------------------------------------------------- events

local frame = CreateFrame("Frame")
local handlers = {}

-- Several modules can listen to the same game event. An event this client
-- doesn't have (renamed or removed between versions) is skipped: registering
-- it would be an error, and one error stops the rest of a file loading.
function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then
      ns.unknownEvents = ns.unknownEvents or {}
      table.insert(ns.unknownEvents, event)
    end
  end
  table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end)

-- Internal messages between modules (e.g. "DATA_CHANGED" -> panel refresh).
local listeners = {}

function ns.Listen(message, fn)
  listeners[message] = listeners[message] or {}
  table.insert(listeners[message], fn)
end

function ns.Fire(message, ...)
  for _, fn in ipairs(listeners[message] or {}) do
    local ok, err = ns.Protect(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end

---------------------------------------------------------------- background jobs

-- Work over all the quest or item data, and For you's first build after a
-- login, take longer than Classic Era lets one script run (the game stops it,
-- "script ran too long", and a window being drawn is left blank). So they run
-- as background jobs, a slice per frame: ns.Warm(fn, done) queues fn and runs
-- its first slice at once; inside it, ns.WarmStep() hands the rest of the
-- frame back once the slice is used; done(ok, ...) gets what fn returned.
-- Code run directly, not by ns.Warm, never stops at a WarmStep.
-- Lua 5.1 can't pause inside a pcall: in code a job runs, a Lua function is
-- guarded with ns.Protect instead (data sources' own functions never pause,
-- so Sources.lua keeps pcall).
local WARM_SLICE_MS = 8
local warmQueue, warmCo, warmFrame, sliceStart = {}, nil, nil, 0
local warmThreads = setmetatable({}, { __mode = "k" }) -- a job's coroutine and ns.Protect's inside it
local unpack = unpack or table.unpack

local function clock() return debugprofilestop and debugprofilestop() or 0 end
local function pack(...) return { n = select("#", ...), ... } end

local function inJob()
  local co = coroutine.running()
  return co ~= nil and warmThreads[co] == true
end

function ns.WarmStep()
  if inJob() and clock() - sliceStart > WARM_SLICE_MS then coroutine.yield() end
end

-- pcall that a job can pause inside: there, fn runs in a coroutine of its
-- own (which catches errors as pcall does) and passes its pauses on.
function ns.Protect(fn, ...)
  if not inJob() then return pcall(fn, ...) end
  local inner = coroutine.create(fn)
  warmThreads[inner] = true
  local results = pack(coroutine.resume(inner, ...))
  while results[1] and coroutine.status(inner) ~= "dead" do
    coroutine.yield()
    results = pack(coroutine.resume(inner))
  end
  return unpack(results, 1, results.n)
end

-- The frame that runs the slices (for tests).
function ns.WarmFrame() return warmFrame end

-- True while a job is queued or running.
function ns.Warming()
  return warmCo ~= nil or #warmQueue > 0
end

local current -- the queue entry running: { fn, done }

local function warmTick()
  if not warmCo then
    current = table.remove(warmQueue, 1)
    if not current then
      warmFrame:SetScript("OnUpdate", nil)
      return
    end
    warmCo = coroutine.create(current[1])
    warmThreads[warmCo] = true
  end
  sliceStart = clock()
  local results = pack(coroutine.resume(warmCo))
  if results[1] and coroutine.status(warmCo) ~= "dead" then return end
  warmCo = nil
  if not results[1] then geterrorhandler()(results[2]) end
  if #warmQueue == 0 then warmFrame:SetScript("OnUpdate", nil) end
  local done = current[2]
  current = nil
  if done then
    local ok, err = pcall(done, unpack(results, 1, results.n))
    if not ok then geterrorhandler()(err) end
  end
end

function ns.Warm(fn, done)
  warmQueue[#warmQueue + 1] = { fn, done }
  warmFrame = warmFrame or CreateFrame("Frame")
  warmFrame:SetScript("OnUpdate", warmTick)
  -- The first slice now, unless a job is under way (or this is inside one).
  if not warmCo then warmTick() end
end

-- C_Timer.After, with the callback's error reported instead of lost (a
-- timer callback isn't inside any pcall'd handler).
function ns.After(delay, fn)
  C_Timer.After(delay, function()
    local ok, err = pcall(fn)
    if not ok then geterrorhandler()(err) end
  end)
end

---------------------------------------------------------------- game

-- One addon for two clients (one TOC, both Interface numbers):
--   "forever"  WoW Forever (Mainline 12.x API, its own new quests and zones,
--              some maps moved since vanilla);
--   "era"      Classic Era 1.15, whose realms also run Season of Discovery
--              and Hardcore (ns.Season).
-- Anything that isn't the Classic Era client counts as Forever.
function ns.Game()
  local era = WOW_PROJECT_CLASSIC ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
  return era and "era" or "forever"
end

function ns.IsForever()
  return ns.Game() == "forever"
end

-- Classic Era realm seasons (C_Seasons; Enum.SeasonID: 1 Mastery, 2 Discovery,
-- 3 Hardcore, 11 Fresh, 12 Fresh Hardcore): "sod", "hardcore" or nil. Looked
-- up on each call: the realm's season isn't known before you're in the world.
local SEASONS = { [2] = "sod", [3] = "hardcore", [12] = "hardcore" }

function ns.Season()
  local id = C_Seasons and C_Seasons.GetActiveSeason and C_Seasons.GetActiveSeason()
  if C_GameRules and C_GameRules.IsHardcoreActive and C_GameRules.IsHardcoreActive() then return "hardcore" end
  return id and SEASONS[id] or nil
end

function ns.IsHardcore()
  return ns.Season() == "hardcore"
end

-- "WoW Forever", "Classic Era", "Season of Discovery" or "Hardcore".
function ns.GameName()
  if ns.IsForever() then return "WoW Forever" end
  local season = ns.Season()
  return season == "sod" and "Season of Discovery" or season == "hardcore" and "Hardcore" or "Classic Era"
end

-- A quest this many levels above you is too hard: red (5) in the game's
-- colours, and orange too (3) on Hardcore, where a death ends the character.
function ns.TooHardLevels()
  return ns.IsHardcore() and 3 or 5
end

---------------------------------------------------------------- quest log

-- The quest log the way Forever's client asks for it (C_QuestLog), with
-- Classic Era's older functions underneath where the client has only those.
-- Looked up on each call (tests swap them in late).
local QuestLog = {}
ns.QuestLog = QuestLog

-- QUEST_ACCEPTED's quest ID: Classic Era sends (questLogIndex, questID),
-- Forever only (questID).
function QuestLog.AcceptedID(first, second)
  return second or first
end

function QuestLog.NumEntries()
  local fn = C_QuestLog and C_QuestLog.GetNumQuestLogEntries or GetNumQuestLogEntries
  return fn and fn() or 0
end

-- { questID, title, level, isHeader, isHidden } (as C_QuestLog.GetInfo), or nil.
function QuestLog.Info(index)
  if C_QuestLog and C_QuestLog.GetInfo then return C_QuestLog.GetInfo(index) end
  if not GetQuestLogTitle then return nil end
  -- title, level, questTag, isHeader, isCollapsed, isComplete, frequency,
  -- questID, ... (16th) isHidden
  local title, level, _, isHeader, _, _, _, questID, _, _, _, _, _, _, _, isHidden = GetQuestLogTitle(index)
  if not title then return nil end
  return { title = title, level = level, isHeader = isHeader and true or false, isHidden = isHidden and true or false,
    questID = not isHeader and questID ~= 0 and questID or nil }
end

-- The log's quests in order: for index, info in QuestLog.Entries() do ...
function QuestLog.Entries()
  local i, n = 0, QuestLog.NumEntries()
  return function()
    while i < n do
      i = i + 1
      local info = QuestLog.Info(i)
      if info then return i, info end
    end
  end
end

-- Objectives done (ready to hand in).
function QuestLog.IsComplete(questID)
  if C_QuestLog and C_QuestLog.IsComplete then return C_QuestLog.IsComplete(questID) and true or false end
  if IsQuestComplete then return IsQuestComplete(questID) and true or false end
  return false
end

-- The quest's index in your log, or nil when it isn't there.
function QuestLog.LogIndex(questID)
  local fn = C_QuestLog and C_QuestLog.GetLogIndexForQuestID or GetQuestLogIndexByID
  local index = fn and fn(questID)
  return index and index > 0 and index or nil
end

function QuestLog.Title(questID)
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then return C_QuestLog.GetTitleForQuestID(questID) end
  if C_QuestLog and C_QuestLog.GetQuestInfo then return C_QuestLog.GetQuestInfo(questID) end
  return nil
end

-- { questID, ... } of every quest this character handed in.
function QuestLog.CompletedIDs()
  if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then return C_QuestLog.GetAllCompletedQuestIDs() or {} end
  local out = {}
  for id, done in pairs(GetQuestsCompleted and GetQuestsCompleted() or {}) do
    if done then out[#out + 1] = id end
  end
  return out
end

---------------------------------------------------------------- client

-- Client functions that moved between API versions, looked up on each call
-- (tests swap them in late).
function ns.ItemCount(itemID)
  local fn = C_Item and C_Item.GetItemCount or GetItemCount
  return fn and fn(itemID) or 0
end

-- true / false, or nil when this client can't say.
function ns.KnowsSpell(spellID)
  if C_SpellBook and C_SpellBook.IsSpellKnown then return C_SpellBook.IsSpellKnown(spellID) and true or false end
  if IsPlayerSpell then return IsPlayerSpell(spellID) and true or false end
  if IsSpellKnown then return IsSpellKnown(spellID) and true or false end
  return nil
end

---------------------------------------------------------------- flights

-- On a flight path the zones you pass over aren't places you're in: what a
-- new zone sets off (suggestions planned again, "new journey" toasts) waits
-- for the landing. Checked every few seconds rather than trusting an event
-- to say you landed.
local LANDING_POLL = 2
local afterLanding, polling = {}, false

function ns.OnTaxi()
  return UnitOnTaxi ~= nil and UnitOnTaxi("player") and true or false
end

local function poll()
  if ns.OnTaxi() then return C_Timer.After(LANDING_POLL, poll) end
  polling = false
  local fns = afterLanding
  afterLanding = {}
  for _, fn in ipairs(fns) do
    local ok, err = pcall(fn)
    if not ok then geterrorhandler()(err) end
  end
end

-- Runs `fn` now, or once you land (once, however often it was asked for).
function ns.AfterFlight(fn)
  if not ns.OnTaxi() then return fn() end
  for _, queued in ipairs(afterLanding) do
    if queued == fn then return end
  end
  afterLanding[#afterLanding + 1] = fn
  if not polling then
    polling = true
    C_Timer.After(LANDING_POLL, poll)
  end
end

---------------------------------------------------------------- panel pages

-- Pages register themselves from their own files; UI/Panel.lua (loaded last)
-- turns them into tabs. See the page contract at the top of UI/Panel.lua.
ns.pages = {}

function ns.RegisterPage(page)
  table.insert(ns.pages, page)
end

-- /ww subcommands added by modules from their own files:
--   ns.RegisterCommand("item", "/ww item <link> - where an item comes from", function(rest) ... end)
-- `rest` keeps its original case, so links survive.
ns.commands = {}

-- Changes a setting and tells the windows (SETTINGS_CHANGED(key)).
function ns.SetSetting(key, value)
  ns.db.settings[key] = value
  ns.Fire("SETTINGS_CHANGED", key)
end

function ns.RegisterCommand(name, help, run)
  ns.commands[name] = { help = help, run = run }
end

---------------------------------------------------------------- saved data

local DEFAULTS = {
  npcs = {},         -- [npcID] = harvested NPC (see Harvest.lua)
  transports = {},   -- recorded with /ww dock (see Docks.lua)
  dungeonEntrances = {}, -- [name key] = entrances you walked through (see Dungeons.lua)
  mailboxes = {},    -- { {mapID, x, y}, ... }: mailboxes you opened (see Errands.lua)
  -- showArrow: the compass in the directions box; tomtom: nil until you've
  -- been asked (see UI/Options.lua), then true / false.
  settings = { showArrow = true },
}

local CHAR_DEFAULTS = {
  knownTaxi = {},    -- [taxi nodeID] = true
  classSpells = nil, -- last class trainer reading (see Harvest.lua)
  skippedSpells = nil, -- [spell (rank)] = true: left at the trainer (see Trainers.lua)
}

local function applyDefaults(target, defaults)
  for k, v in pairs(defaults) do
    if target[k] == nil then
      target[k] = type(v) == "table" and CopyTable(v) or v
    elseif type(v) == "table" and type(target[k]) == "table" then
      applyDefaults(target[k], v)
    end
  end
end

-- The addon was called Wayfinder before it was published, and its saved
-- variables with it.
-- The first load under the new name copies them over (once: only while the
-- Wayward ones are still empty) and leaves the old ones alone, so going back
-- to an older version loses nothing.
local function migrateSaved()
  if WayfinderDB and next(WayfinderDB) and not (WaywardDB and next(WaywardDB)) then
    WaywardDB = CopyTable(WayfinderDB)
  end
  if WayfinderCharDB and next(WayfinderCharDB) and not (WaywardCharDB and next(WaywardCharDB)) then
    WaywardCharDB = CopyTable(WayfinderCharDB)
  end
end

ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  migrateSaved()
  WaywardDB = WaywardDB or {}
  WaywardCharDB = WaywardCharDB or {}
  applyDefaults(WaywardDB, DEFAULTS)
  applyDefaults(WaywardCharDB, CHAR_DEFAULTS)
  ns.db, ns.charDB = WaywardDB, WaywardCharDB
  ns.Fire("DB_READY")
end)

---------------------------------------------------------------- formatting

function ns.FormatMoney(copper)
  copper = copper or 0
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return string.format("%dg %ds", g, s) end
  if s > 0 then return string.format("%ds %dc", s, c) end
  return c .. "c"
end

function ns.FormatDuration(seconds)
  if not seconds or seconds == math.huge then return "?" end
  if seconds < 60 then return "<1 min" end
  local minutes = math.floor(seconds / 60 + 0.5)
  if minutes < 60 then return "~" .. minutes .. " min" end
  return string.format("~%d h %d min", math.floor(minutes / 60), minutes % 60)
end

-- The game's quest difficulty colour for a level ({r, g, b}), or nil.
function ns.DifficultyColor(level)
  if type(level) ~= "number" or level <= 0 or not GetQuestDifficultyColor then return nil end
  local c = GetQuestDifficultyColor(level)
  return c and { r = c.r, g = c.g, b = c.b } or nil
end

function ns.EnumName(enum, value)
  for k, v in pairs(enum or {}) do
    if v == value then return k end
  end
  return nil
end

function ns.MapName(mapID)
  local info = mapID and C_Map.GetMapInfo(mapID)
  return info and info.name or "?"
end

function ns.SavePosition(frame, key)
  local point, _, relativePoint, x, y = frame:GetPoint()
  ns.db.settings[key] = { point, relativePoint, x, y }
end

-- `home`: { point, relativePoint, x, y } to use when nothing is saved.
function ns.RestorePosition(frame, key, home)
  local p = ns.db.settings[key] or home
  if p then
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  end
end

---------------------------------------------------------------- slash

local HELP = {
  "/ww - open or close the Wayward panel",
  "/ww help - this list",
  "/ww stop - stop the current directions",
  "/ww compass - the compass in the directions box on or off (text directions stay)",
  "/ww tomtom - TomTom's arrow on or off for Wayward's directions (when TomTom is installed)",
  "/ww where - print your map ID and coordinates (to report data fixes)",
  "/ww dock [boat|zeppelin|portal] - record a transport: once where you board, once where you get off",
  "/ww dock list - copy recorded transports",
  "/ww debug - version, data sources and scan times (/ww debug cards: the For you cards; /ww debug quest <id|name>: a quest's chain data and why it's notable)",
}

SLASH_WAYWARD1 = "/wayward"
SLASH_WAYWARD2 = "/ww"
SLASH_WAYWARD3 = "/wf" -- the old name's command; undocumented, kept so muscle memory still works
SlashCmdList.WAYWARD = function(msg)
  local cmd, rest = (msg or ""):lower():match("^(%S*)%s*(.-)$")
  local registered = ns.commands[cmd]
  if registered then
    registered.run((msg or ""):match("^%S*%s*(.-)$"))
  elseif cmd == "" then
    ns.Panel.Toggle()
  elseif cmd == "stop" then
    ns.Nav.Stop()
  elseif cmd == "tomtom" then
    ns.SetSetting("tomtom", ns.db.settings.tomtom ~= true)
    ns.print("TomTom arrow " .. (ns.db.settings.tomtom and "on (when TomTom is installed)" or "off"))
  elseif cmd == "arrow" or cmd == "compass" then
    ns.SetSetting("showArrow", not ns.db.settings.showArrow)
    ns.print("compass " .. (ns.db.settings.showArrow and "on" or "off"))
  elseif cmd == "where" then
    local mapID = C_Map.GetBestMapForUnit("player")
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then
      local x, y = pos:GetXY()
      ns.print(string.format("mapID=%d (%s) x=%.4f y=%.4f", mapID, ns.MapName(mapID), x, y))
    else
      ns.print("no map position here")
    end
  elseif cmd == "dock" then
    ns.Docks.Command(rest)
  elseif cmd == "debug" then
    ns.print("version " .. ns.VERSION .. " (" .. ns.GameName() .. ")")
    if rest == "cards" then
      for _, line in ipairs(ns.Cards.Diagnose()) do ns.print(line) end
      -- For you's cards carry a relevance; then its roles, parts and observations too.
      local shown = ns.Cards.Visible and ns.Cards.Visible() or {}
      if shown[1] and shown[1].relevance and ns.ForYou.Diagnose then
        for _, line in ipairs(ns.ForYou.Diagnose()) do ns.print(line) end
      end
      return
    end
    local questQuery = rest:match("^quest%s+(.+)$")
    if questQuery then
      local kind, id = ns.Search.Parse(questQuery)
      if kind and kind ~= "quest" then id = nil end
      local matches = id and { { id = id } } or ns.Quests.FindQuests(questQuery)
      if #matches == 0 then ns.print("no quest called " .. questQuery) end
      for i = 1, math.min(#matches, 3) do
        for _, line in ipairs(ns.Quests.Describe(matches[i].id)) do ns.print(line) end
        for _, line in ipairs(ns.Quests.DescribeNotable(matches[i].id)) do ns.print(line) end
        for _, line in ipairs(ns.Quests.DescribeChain(matches[i].id)) do ns.print(line) end
      end
      return
    end
    ns.print("data sources: " .. (ns.Data.Status() or "none (install " .. ns.Data.ADDON .. " for quests, items and more NPCs)"))
    local function count(t)
      local n = 0
      for _ in pairs(t) do n = n + 1 end
      return n
    end
    ns.print(string.format("learned NPCs: %d, known flight paths: %d", count(ns.db.npcs), count(ns.charDB.knownTaxi)))
    for name, ms in pairs(ns.debugTimings or {}) do
      ns.print(string.format("%s scan: %.0f ms", name, ms))
    end
    if ns.ForYou and ns.ForYou.lastParts then ns.print("forYou parts (ms): " .. ns.ForYou.lastParts) end
    if ns.QuestTimes then ns.print(ns.QuestTimes.Describe(ns.ForYou and ns.ForYou.SECONDS_PER_QUEST)) end
    if ns.unknownEvents then ns.print("events this client doesn't have: " .. table.concat(ns.unknownEvents, ", ")) end
  else
    if cmd ~= "help" then ns.print("no command called " .. cmd) end
    for _, line in ipairs(HELP) do ns.print(line) end
    local names = {}
    for name in pairs(ns.commands) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do ns.print(ns.commands[name].help) end
  end
end
