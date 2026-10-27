local _, ns = ...

-- Follows a planned route or journey: places the built-in map waypoint on the
-- current step's destination and moves on when you get there (or further
-- along). Journey stops with a quest action wait until the quest is accepted
-- or handed in (see Journey.lua).

local Nav = {}
local unpack = unpack or table.unpack
ns.Nav = Nav

-- Yards from a step's destination that count as "reached".
local RADIUS = { walk = 20, fly = 120, transport = 150, hearth = 150 }
local GOAL_RADIUS = 10

-- With TomTom installed and its arrow turned on (asked once, see
-- UI/Options.lua), its arrow and pins show the way, on top of the compass in
-- the directions box if that is on too. Modern TomTom: AddWaypoint(uiMapID, x, y, opts) and
-- RemoveWaypoint(uid); if that fails we fall back to our own arrow.
local tomtomFailed

-- Try TomTom again (e.g. after updating it); /ww tomtom calls this.
function Nav.ResetTomTom()
  tomtomFailed = nil
end

function Nav.TomTomInstalled()
  return type(TomTom) == "table" and type(TomTom.AddWaypoint) == "function"
end

function Nav.UsingTomTom()
  return ns.db.settings.tomtom == true and not tomtomFailed and Nav.TomTomInstalled()
end

local function clearTomTom()
  if Nav.tomtomWaypoint and type(TomTom) == "table" and TomTom.RemoveWaypoint then
    pcall(TomTom.RemoveWaypoint, TomTom, Nav.tomtomWaypoint)
  end
  Nav.tomtomWaypoint = nil
end

local function setTomTom(mapID, x, y, title)
  clearTomTom()
  local ok, uid = pcall(TomTom.AddWaypoint, TomTom, mapID, x, y,
    { title = title, from = "Wayward", persistent = false, minimap = true, world = true, crazy = true })
  if ok and uid then
    Nav.tomtomWaypoint = uid
    return true
  end
  tomtomFailed = true
  ns.print("couldn't use TomTom's arrow; using Wayward's own.")
  return false
end

-- The game's map pin (and its marker on screen) outlasts a logout or reload,
-- so where we put ours is saved: one still there next time is ours to take
-- down, not left pointing at an old step (TomTom showing the way instead,
-- or no journey to resume).
local function clearPin()
  if Nav.ownsWaypoint and C_Map.ClearUserWaypoint then
    C_Map.ClearUserWaypoint()
    Nav.ownsWaypoint = false
  end
  ns.charDB.pin = nil
end

local PIN_SAME = 1e-4

local function adoptPin()
  local pin = ns.charDB.pin
  local current = pin and C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
  local x, y
  if current and current.position then x, y = current.position:GetXY() end
  if x and current.uiMapID == pin.mapID and math.abs(x - pin.x) < PIN_SAME and math.abs(y - pin.y) < PIN_SAME then
    Nav.ownsWaypoint = true
  else
    -- Gone, or one you placed yourself since: not ours.
    ns.charDB.pin = nil
  end
end

-- `title` says what to do there (the step text), for TomTom's arrow and pin.
local function setWaypoint(node, title)
  local mapID, x, y = ns.Geo.ZonePoint(node)
  if not (mapID and x and y) then return end
  if Nav.UsingTomTom() and setTomTom(mapID, x, y, title or node.label or "Wayward") then
    -- TomTom shows the way now: take down the map pin we put up before.
    clearPin()
    return
  end
  -- Classic Era has no map pins: the directions box and its compass show the way.
  if not (C_Map.SetUserWaypoint and UiMapPoint) then return end
  if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then return end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
  end
  Nav.ownsWaypoint = true
  ns.charDB.pin = { mapID = mapID, x = x, y = y }
end

function Nav.CurrentStep()
  local a = Nav.active
  return a and a.route.steps[a.index]
end

-- The journey is saved per character so it survives logging out (see Resume).
local function save()
  local a = Nav.active
  if not a then
    ns.charDB.nav = nil
  elseif a.journey then
    ns.charDB.nav = { title = a.title, journey = ns.Journey.Save(a.journey), stats = a.stats }
  else
    local g = a.goal
    ns.charDB.nav = { title = a.title, goal = { mapID = g.mapID, x = g.x, y = g.y, label = g.label, npc = g.npc },
      stats = a.stats }
  end
end

local function showStep()
  local step = Nav.CurrentStep()
  if step then setWaypoint(step.to, ns.Router.Describe(Nav.active.route, Nav.active.index)) end
  if Nav.active then Nav.active.closest = nil end
  save()
  ns.Fire("NAV_CHANGED")
end

-- Turning TomTom's arrow on or off moves the current waypoint over.
ns.Listen("SETTINGS_CHANGED", function(key)
  if key ~= "tomtom" then return end
  tomtomFailed = nil
  clearTomTom()
  if Nav.active then showStep() end
end)

local function flightTip()
  if next(ns.charDB.knownTaxi) == nil then
    ns.print("tip: talk to a flight master once and Wayward will route you via your flight paths.")
  end
end

local newStats -- below

local function startRoute(title, goal, route)
  Nav.active = { title = title, goal = goal, route = ns.Router.WithZoneSteps(route), index = 1, stats = newStats() }
  ns.print("directions to " .. title .. ": " .. ns.FormatDuration(route.seconds))
  flightTip()
  showStep()
  -- Unless it ended at once (you were there): the fanfare has its own sound.
  if Nav.active then ns.Sounds.Play("start") end
end

local offerFollowUps -- below: offers a journey's follow-up quests (true when it asked)

-- What a journey has come to so far, for the fanfare at its end: XP earned,
-- yards travelled, quests handed in, and when it started.
local lastXP, lastXPMax, lastMoney

-- What a journey came to, for its fanfare: quests handed in (`quests`) and
-- picked up, levels, money looted or earned, flight paths learned,
-- profession ranks trained.
function newStats()
  lastXP, lastXPMax = UnitXP and UnitXP("player"), UnitXPMax and UnitXPMax("player")
  lastMoney = GetMoney and GetMoney()
  return { started = time(), xp = 0, distance = 0, quests = 0, picked = 0, levels = 0, money = 0, flights = 0,
    ranks = 0 }
end

-- Adds `n` (default 1) to the journey's `key` (journeys saved before a stat existed start it at 0).
local function count(key, n)
  local stats = Nav.active and Nav.active.stats
  if stats then stats[key] = (stats[key] or 0) + (n or 1) end
end

local function startJourney(journey, quiet)
  local last = journey.stops[#journey.stops]
  Nav.active = { title = journey.title, goal = last.node, journey = journey, index = 1,
    route = ns.Router.WithZoneSteps({ steps = journey.steps, seconds = journey.seconds }), stats = newStats() }
  if not quiet then
    ns.print(string.format("journey: %s, %d stop%s, %s", journey.title, #journey.stops,
      #journey.stops == 1 and "" or "s", ns.FormatDuration(journey.seconds)))
    for _, stop in ipairs(journey.skipped) do
      ns.print("no route to " .. (stop.node and stop.node.label or stop.text or "a stop") .. "; left out.")
    end
    flightTip()
  end
  showStep()
  if not quiet and #journey.stops > 1 then ns.Fire("JOURNEY_STARTED") end
  -- One sound: the follow-up question's when it asks one, none when the
  -- journey ended at once (the fanfare has its own).
  if not quiet and not offerFollowUps(journey.stops) and Nav.active then ns.Sounds.Play("start") end
end

-- Starting something new while a journey is on asks: add it as a detour, or
-- switch to it (the journey on now is set aside, to resume later; see
-- Nav.SetAside)? Switches straight away where the game's dialogs aren't there.
local function ask(label, detour, start)
  local function switch()
    if Nav.active then Nav.SetAside() end
    start()
  end
  if not (StaticPopupDialogs and StaticPopup_Show) then return switch() end
  StaticPopupDialogs.WAYWARD_TRIP = StaticPopupDialogs.WAYWARD_TRIP or {
    text = "You're on a journey: %s.\n\nAdd \"%s\" to it as a detour, or switch to it? "
      .. "Switching sets your journey aside, to resume later (View details in the directions box).",
    button1 = "Add as detour", button2 = "Cancel", button3 = "Switch journey",
    OnAccept = function(_, data) data.add() end,
    OnAlt = function(_, data) data.switch() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopup_Show("WAYWARD_TRIP", Nav.active.title, label, { add = detour, switch = switch })
end

-- A stop for a plain destination (a trainer, a vendor, a hub); someone to
-- talk to is done when you talk to them.
local function visitStop(title, goal)
  if goal.npc then
    return { node = goal, npc = goal.npc, text = "Talk to " .. goal.npc, action = { kind = "talk", npc = goal.npc } }
  end
  return { node = goal, text = "Go to " .. (goal.label or title) }
end

-- A panel result's stops for adding to a journey: a journey's open stops, a
-- class trainer with spells to learn (`spells`, the training card), or a
-- visit to a route's destination.
function Nav.StopsFor(result)
  if result.journey then return ns.Journey.OpenStops(result.journey) end
  if result.goal and result.spells then
    local npc = result.goal.npc
    return { { node = result.goal, npc = npc, text = "Train your new spells at " .. (npc or result.title),
      action = { kind = "learn", spells = result.spells, npc = npc } } }
  end
  if result.goal then return { visitStop(result.title, result.goal) } end
  return {}
end

function Nav.Start(title, goal, route)
  if Nav.active then
    return ask(title, function() Nav.AddToTrip({ visitStop(title, goal) }, title) end,
      function() startRoute(title, goal, route) end)
  end
  startRoute(title, goal, route)
end

-- `journey` from ns.Journey.Plan. `quiet` skips the chat line and overview
-- (used when resuming after a login) and never asks.
function Nav.StartJourney(journey, quiet)
  if Nav.active and not quiet then
    return ask(journey.title, function() Nav.AddToTrip(ns.Journey.OpenStops(journey), journey.title) end,
      function() startJourney(journey) end)
  end
  startJourney(journey, quiet)
end

local function clearWaypoints()
  clearTomTom()
  clearPin()
end

function Nav.Stop()
  clearWaypoints()
  Nav.active = nil
  save()
  ns.Fire("NAV_CHANGED")
end

-- Walking to a flight master: the step after is the flight.
local function flightTalk(steps, k)
  local step, nextStep = steps[k], steps[k + 1]
  return step ~= nil and step.mode == "walk" and nextStep ~= nil and nextStep.mode == "fly"
end

local function onTaxi()
  return UnitOnTaxi and UnitOnTaxi("player") and true or false
end

-- The NPC the current step leads to, and where: the flight master, the quest
-- giver or the one to hand in to, the trainer or vendor you're going to.
function Nav.TargetNPC()
  local a = Nav.active
  local step = a and a.route.steps[a.index]
  if not step then return nil end
  if flightTalk(a.route.steps, a.index) then return step.to.npc, step.to end
  local stop = step.stop
  if stop then
    local action = stop.action
    if stop.node and stop.node.object then return nil end -- an object, not someone
    if action and (action.kind == "talk" or action.kind == "train" or action.kind == "learn") then
      return action.npc, stop.node
    end
    if action and action.kind == "pickup" then return stop.giver, stop.node end
    if action and action.kind == "turnin" then return stop.npc, stop.node end
    return nil
  end
  if a.index == #a.route.steps then return step.to.npc, step.to end
  return nil
end

-- The object the current stop is at (Buzzbox 323) and its name, or nil.
function Nav.TargetObject()
  local a = Nav.active
  local step = a and a.route.steps[a.index]
  local stop = step and step.stop
  if not (stop and stop.node and stop.node.object) then return nil end
  return stop.giver or stop.npc or stop.node.label, stop.node
end

-- What you do where you are now ("talk", "use", "fly", "hearth", "enter",
-- or nil), for the directions box.
function Nav.Interaction()
  local a = Nav.active
  if not a then return nil end
  if flightTalk(a.route.steps, a.index) then return a.waiting and "talk" or nil end
  local step = a.route.steps[a.index]
  if step and step.mode == "fly" and not onTaxi() then return "fly" end
  if step and step.mode == "hearth" then return "hearth" end
  if a.waiting and Nav.TargetObject() then return "use" end
  if a.waiting and Nav.TargetNPC() then return "talk" end
  local action = a.waiting and step and step.stop and step.stop.action
  if action and action.kind == "enter" then return "enter" end
  return nil
end

local UP_NEXT_DELAY = 4 -- seconds after a journey's fanfare before "Up next"

local function arrive()
  local a = Nav.active
  ns.print("you have arrived: " .. a.title)
  -- The end of a journey (or plain directions): its fanfare.
  if a.stats and ns.Fanfare then
    local stats = a.stats
    local ok, err = pcall(ns.Fanfare.TripDone, { title = a.title, kind = a.journey and a.journey.kind,
      icon = a.journey and a.journey.icon, xp = stats.xp, seconds = time() - stats.started,
      distance = stats.distance, quests = stats.quests, picked = stats.picked, levels = stats.levels,
      money = stats.money, flights = stats.flights, ranks = stats.ranks })
    if not ok then ns.print("couldn't show the journey's fanfare: " .. tostring(err)) end
  end
  -- A journey done: what next, once the fanfare has had a moment.
  if a.journey and ns.ForYou then
    local title = a.title
    ns.After(UP_NEXT_DELAY, function() ns.ForYou.SuggestNext(title) end)
  end
  Nav.Stop()
end

-- A fresh plan from `here` to the same goal (or the journey's remaining stops).
local function planFrom(a, here)
  local net = ns.Network.Build()
  if a.journey then
    local journey = ns.Journey.Replan(a.journey, here, net)
    return journey and { steps = journey.steps, seconds = journey.seconds }, journey
  end
  return ns.Router.Plan(here, a.goal, net)
end

local function adopt(a, route, journey)
  a.route, a.index = ns.Router.WithZoneSteps(route), 1
  if journey then
    a.journey = journey
    a.goal = journey.stops[#journey.stops].node
  end
  showStep()
end

-- Re-plan from where you are now (after a hearthstone, a detour, ...).
function Nav.Recalculate()
  local a = Nav.active
  local here = ns.Geo.PlayerNode()
  if not (a and here) then return end
  local route, journey = planFrom(a, here)
  if not route then
    ns.print("no route from here.")
    return
  end
  adopt(a, route, journey)
end

local function onTaxi()
  return UnitOnTaxi and UnitOnTaxi("player") or false
end

-- The current step is re-measured from `here`; later steps use the plan. In
-- a camp, what its objectives still need at your pace there counts too, and
-- arriving at a cleared camp before it respawns means waiting there.
function Nav.RemainingSeconds(here)
  local a = Nav.active
  if not a then return nil end
  local total = 0
  for i = a.index, #a.route.steps do
    local step = a.route.steps[i]
    if i == a.index and here then
      total = total + ns.Router.SecondsLeft(step, here, onTaxi()) + (ns.Camps.TimeLeft(step.stop) or 0)
    else
      total = total + step.seconds
    end
    if step.stop then total = math.max(total, ns.Journey.RespawnIn(step.stop)) end
  end
  return total
end

-- Learning a flight path mid-trip (e.g. talking to a flight master you were
-- walking past) can make a much faster route; switch to it.
ns.Listen("FLIGHTS_CHANGED", function()
  local a = Nav.active
  if not a or onTaxi() then return end
  local here = ns.Geo.PlayerNode()
  if not here then return end
  local route, journey = planFrom(a, here)
  local current = Nav.RemainingSeconds(here)
  if route and current and route.seconds < current - 15 then
    ns.print("faster route with your flight paths: " .. ns.FormatDuration(route.seconds))
    adopt(a, route, journey)
  end
end)

-- A journey stop's quest was accepted / handed in (or its item collected:
-- `matches` picks the stop). At the current stop the journey moves on; done
-- ahead of time, the rest is re-planned without it. Returns true if a stop was.
local function finishStop(matches)
  local a = Nav.active
  if not (a and a.journey) then return false end
  for i, step in ipairs(a.route.steps) do
    local stop = ns.Journey.PendingAction(step)
    if stop and i >= a.index and matches(stop.action) then
      stop.done, stop.passed = true, nil
      if stop.action.kind == "train" then count("ranks") end
      if i == #a.route.steps then return arrive() end
      local relocate = false
      for k = i + 1, #a.route.steps do
        local later = a.route.steps[k].stop
        if later and later.resolve and not later.done then relocate = true end
      end
      if i == a.index and not relocate then
        a.index = i + 1
        showStep()
      else
        -- Done ahead of time, or a later stop's place is now known better.
        Nav.Recalculate()
      end
      return true
    end
  end
  return false
end

local function questAction(kind, questID)
  return finishStop(function(action) return action.kind == kind and action.questID == questID end)
end

-- Every other stop of the journey that the quest log, your bags or the
-- completed quests say is done now: skipped stops you did anyway, and steps
-- of a quest whose objectives are complete. The journey is re-planned if the
-- stop you were heading for is among them.
local function syncStops()
  local a = Nav.active
  if not (a and a.journey) then return end
  local current = Nav.CurrentStep()
  local pending = current and current.stop and not current.stop.done and current.stop
  if ns.Journey.SyncQuestState(a.journey.root or a.journey.def) == 0 then return end
  if pending and pending.done then
    Nav.Recalculate()
  else
    showStep()
  end
end

-- Picking up a quest that isn't in your journey yet: its stops (do it, hand
-- it in) planned, and a question: add them to the journey (and how much
-- longer it gets), start a new journey for them (the one on now is set
-- aside), or not now. Quests picked up one after another are asked about
-- together, once the journey has no more pickups to do right where you are.
local PICKUP_WAIT = 1.5
local picked, waiting = {}, false
local QUEST_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"

local function stillPicking()
  local step = Nav.CurrentStep()
  local stop = step and step.stop
  return stop ~= nil and stop.action ~= nil and stop.action.kind == "pickup" and not stop.done and Nav.Waiting()
end

-- The offer for the quests picked up: { label, stops, alone (seconds), extra
-- (seconds more on the current journey, or nil without one) }, or nil.
function Nav.PickupOffer(questIDs)
  local here = ns.Geo.PlayerNode()
  if not here then return nil end
  local stops, names, ids = {}, {}, {}
  for _, id in ipairs(questIDs) do
    if not Nav.TripHasQuest(id) then
      local qs = ns.Journey.QuestStops(id, here)
      if #qs > 0 then
        local q = ns.Quests.Quest(id)
        names[#names + 1] = q and q.name or ("quest " .. id)
        ids[#ids + 1] = id
        for _, st in ipairs(qs) do stops[#stops + 1] = st end
      end
    end
  end
  if #stops == 0 then return nil end
  local label = #names == 1 and names[1] or string.format("%d quests", #names)
  local alone = ns.Journey.Plan(here, { title = label, kind = "quest", icon = QUEST_ICON, stops = stops })
  if not alone then return nil end
  local offer = { label = label, names = names, ids = ids, stops = stops, alone = alone.seconds, journey = alone }
  local a = Nav.active
  if a then
    local base, open
    if a.journey then
      base = ns.Journey.Replan(a.journey, here)
      local root = a.journey.root or a.journey.def
      open = {}
      for _, s in ipairs(root.stops or {}) do
        if not s.done and not s.skipped then open[#open + 1] = s end
      end
      for _, s in ipairs(stops) do open[#open + 1] = s end
      local with = base and ns.Journey.Plan(here, { stops = open })
      offer.extra = base and with and math.max(0, with.seconds - base.seconds) or nil
    else
      local with = ns.Journey.Plan(here, { stops = { { node = a.goal, text = a.title } , unpack(stops) } })
      local remaining = Nav.RemainingSeconds(here)
      offer.extra = with and remaining and math.max(0, with.seconds - remaining) or nil
    end
  end
  return offer
end

-- What the quests picked up lead to, when it's worth knowing (a dungeon
-- quest or a long chain, Quests.ChainHighlight): "\n" and a line each, or "".
local function chainNote(offer)
  local lines = {}
  for i, id in ipairs(offer.ids or {}) do
    local text = ns.Quests.ChainHighlight(id)
    if text then
      text = text:gsub("\n", ". ")
      lines[#lines + 1] = #offer.ids > 1 and (offer.names[i] .. ": " .. text .. ".") or (text .. ".")
    end
  end
  return #lines > 0 and ("\n" .. table.concat(lines, "\n")) or ""
end

-- Shows a question, with its sound; if the game can't, says so in chat rather
-- than nothing. True when it was shown.
local function askPlayer(which, text, data)
  local ok, err = pcall(StaticPopup_Show, which, text, nil, data)
  if not ok then
    ns.print("couldn't show a question (" .. tostring(err) .. "): " .. text:gsub("\n\n", " "))
    return false
  end
  ns.Sounds.Play("popup")
  return true
end

local function askPickups()
  if stillPicking() then
    ns.After(PICKUP_WAIT, askPickups)
    return
  end
  waiting = false
  local ids = picked
  picked = {}
  if ns.db.settings.askOnPickup == false then return end
  local offer = Nav.PickupOffer(ids)
  if not offer then return end
  Nav.lastPickupOffer = offer
  if not (StaticPopupDialogs and StaticPopup_Show) then return end
  -- StaticPopup_Show takes two text arguments (then the data): the message is
  -- built here and passed as one.
  StaticPopupDialogs.WAYWARD_PICKUP_ADD = StaticPopupDialogs.WAYWARD_PICKUP_ADD or {
    text = "%s",
    button1 = "Add to journey", button2 = "Not now", button3 = "New journey",
    OnAccept = function(_, data) Nav.AddToTrip(data.stops, data.label) end,
    OnAlt = function(_, data)
      -- A new journey never loses the one on now: it's set aside.
      if Nav.active then Nav.SetAside() end
      startJourney(data.journey)
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopupDialogs.WAYWARD_PICKUP_NEW = StaticPopupDialogs.WAYWARD_PICKUP_NEW or {
    text = "%s",
    button1 = "Start journey", button2 = "Not now",
    OnAccept = function(_, data) startJourney(data.journey) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  local note = chainNote(offer)
  if Nav.active and offer.extra then
    askPlayer("WAYWARD_PICKUP_ADD", string.format(
      "You picked up %s.%s\n\nAdd it to your journey (about %s more), or start a new journey for it (%s)? "
      .. "A new journey sets the one on now aside, to resume later.",
      offer.label, note, ns.FormatDuration(offer.extra), ns.FormatDuration(offer.alone)), offer)
  else
    askPlayer("WAYWARD_PICKUP_NEW", string.format("You picked up %s.%s\n\nStart a journey for it (%s)?",
      offer.label, note, ns.FormatDuration(offer.alone)), offer)
  end
end

ns.On("QUEST_ACCEPTED", function(...)
  local questID = ns.QuestLog.AcceptedID(...)
  count("picked")
  questAction("pickup", questID)
  syncStops()
  picked[#picked + 1] = questID
  if not waiting then
    waiting = true
    ns.After(PICKUP_WAIT, askPickups)
  end
end)
ns.On("QUEST_TURNED_IN", function(questID)
  count("quests")
  questAction("turnin", questID)
  syncStops()
end)

-- Talking to a quest giver: pickups on the journey that they don't offer you
-- are locked (the data missed an earlier quest). They're dropped, with what
-- needs them, and treated as locked everywhere until you hand something in.
local OFFER_RADIUS = 25 -- yards from a pickup stop that count as "at its giver"

ns.Listen("QUESTS_OFFERED", function(npcName, ids)
  local a = Nav.active
  local here = ns.Geo.PlayerNode()
  if not (a and a.journey and here) then return end
  local missing = {}
  for k = a.index, #a.route.steps do
    local stop = ns.Journey.PendingAction(a.route.steps[k])
    local action = stop and stop.action
    if action and action.kind == "pickup" and not ids[action.questID]
      and ns.Geo.Distance(here, stop.node) <= OFFER_RADIUS and (not stop.giver or stop.giver == npcName) then
      missing[#missing + 1] = stop
    end
  end
  for _, stop in ipairs(missing) do
    ns.Quests.MarkNotOffered(stop.action.questID)
    ns.print(string.format("%s isn't offered yet (it needs earlier quests): dropped from the journey.",
      (stop.text or "that quest"):gsub("^Pick up ", ""):gsub(" from .*$", "")))
    if Nav.active then Nav.Drop(stop) end
  end
end)

-- Talking to someone. The flight map opening moves on to the flight; any
-- window of the NPC a stop or the destination is for (or of anyone where it
-- is, when names don't match, e.g. another language) finishes it.
local TALK_RADIUS = 15

ns.On("TAXIMAP_OPENED", function()
  local a = Nav.active
  if a and flightTalk(a.route.steps, a.index) then
    a.index = a.index + 1
    a.waiting = false
    showStep()
  end
end)

function Nav.Talked(npcName)
  local a = Nav.active
  local here = ns.Geo.PlayerNode()
  if not (a and here) then return end
  local name, node = Nav.TargetNPC()
  local close = node and ns.Geo.Distance(here, node) <= TALK_RADIUS
  if not ((name and npcName == name) or close) then return end
  local step = a.route.steps[a.index]
  local stop = step and step.stop
  local kind = stop and stop.action and stop.action.kind
  -- Class training is done once you've learned something (below); where the
  -- client can't show the trainer's list, talking to them has to do.
  if kind == "talk" or (kind == "learn" and not Nav.CanWatchTraining()) then
    finishStop(function(action) return action == stop.action end)
  elseif not stop and a.index == #a.route.steps and step.to.npc then
    a.talked = true
    arrive()
  end
end

for _, event in ipairs({ "GOSSIP_SHOW", "MERCHANT_SHOW", "TRAINER_SHOW", "QUEST_GREETING", "QUEST_DETAIL",
  "BANKFRAME_OPENED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" }) do
  ns.On(event, function() Nav.Talked(UnitName("npc")) end)
end

-- Class training (a `learn` stop): done at the trainer once one of the stop's
-- spells is known, or any spell on their list has just been bought. The list
-- is read from the trainer window (empty at TRAINER_SHOW, filled in by
-- TRAINER_UPDATE): what was "used" when it first filled in against what is
-- used now. Leaving without training keeps the stop; move on or skip it.
local learning -- { stop, used = { [service name] = true } or nil } while a trainer is open for a learn stop

function Nav.CanWatchTraining()
  return type(GetNumTrainerServices) == "function" and type(GetTrainerServiceInfo) == "function"
end

local function usedServices()
  local out, n = {}, GetNumTrainerServices()
  for i = 1, n or 0 do
    local name, kind = GetTrainerServiceInfo(i)
    if name and kind == "used" then out[name] = true end
  end
  return n and n > 0 and out or nil
end

-- The learn stop you're at (or heading for), or nil.
local function learnStop()
  local a = Nav.active
  if not (a and a.journey) then return nil end
  for k = a.index, #a.route.steps do
    local stop = ns.Journey.PendingAction(a.route.steps[k])
    if stop and stop.action.kind == "learn" then return stop end
  end
  return nil
end

-- A listed spell known (an ID this client can check, or a name the trainer
-- lists as used), or a service used since the list was read.
local function trained(stop, used)
  for _, spell in ipairs(stop.action.spells or {}) do
    if type(spell) == "number" and ns.KnowsSpell(spell) then return true end
    if type(spell) == "string" and used and used[spell] then return true end
  end
  if learning and learning.used and used then
    for name in pairs(used) do
      if not learning.used[name] then return true end
    end
  end
  return false
end

local function learnCheck()
  local stop = learning and learning.stop
  if not (stop and Nav.CanWatchTraining()) then return end
  local used = usedServices()
  if trained(stop, used) then
    learning = nil
    finishStop(function(action) return action == stop.action end)
  elseif used and not learning.used then
    learning.used = used
  end
end

ns.On("TRAINER_SHOW", function()
  local stop = learnStop()
  if not stop then return end
  learning = { stop = stop }
  learnCheck()
end)
ns.On("TRAINER_UPDATE", learnCheck)
ns.On("SPELLS_CHANGED", learnCheck)
ns.On("TRAINER_CLOSED", function()
  learnCheck()
  learning = nil
end)

-- Exploring (an `explore` stop): done once you're in that zone, or a zone
-- inside it (a city in its zone), from wherever you crossed; flying over it
-- doesn't count.
local function inZone(mapID, here)
  local id = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  for _ = 1, 10 do
    if not id then break end
    if id == mapID then return true end
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
    id = info and info.parentMapID
  end
  return here ~= nil and ns.Geo.ZoneAt(here.instance, here.wx, here.wy) == mapID
end

function Nav.InZone(mapID)
  return inZone(mapID, ns.Geo.PlayerNode())
end

-- True when an explore stop was just done.
local function exploreCheck(here)
  local a = Nav.active
  if not (a and a.journey) or onTaxi() then return false end
  return finishStop(function(action) return action.kind == "explore" and inZone(action.mapID, here) end)
end

ns.On("ZONE_CHANGED_NEW_AREA", function() exploreCheck(ns.Geo.PlayerNode()) end)

-- Entering a dungeon (an `enter` stop): done when the world you load into is
-- that instance, as Dungeons.lua learns entrances. A wing counts for its
-- dungeon ("Scarlet Monastery - Armory").
local function instanceKey(name)
  return ((name or ""):lower():gsub("^the ", ""):gsub("[^%w]", ""))
end

function Nav.EnteredInstance(name)
  local key = instanceKey(name)
  if key == "" then return false end
  return finishStop(function(action)
    if action.kind ~= "enter" then return false end
    local want = instanceKey(action.dungeon)
    return want ~= "" and (key == want or key:sub(1, #want) == want or want:sub(1, #key) == key)
  end)
end

ns.On("PLAYER_ENTERING_WORLD", function()
  if not (Nav.active and IsInInstance and GetInstanceInfo) then return end
  local inside, kind = IsInInstance()
  if not inside or (kind ~= "party" and kind ~= "raid") then return end
  Nav.EnteredInstance((GetInstanceInfo()))
end)

-- Buying a profession's next rank: the skill cap goes up.
local function trainedCheck()
  local mine = ns.Professions and ns.Professions.Mine()
  if not mine then return end
  finishStop(function(action)
    local have = action.kind == "train" and mine[action.profession]
    return have and have.cap > (action.cap or 0) or false
  end)
end

for _, event in ipairs({ "SKILL_LINES_CHANGED", "TRAINER_UPDATE", "CHAT_MSG_SKILL" }) do
  ns.On(event, function() ns.After(0.2, trainedCheck) end)
end

-- Collecting an item a quest needs.
ns.On("BAG_UPDATE_DELAYED", function()
  finishStop(function(action) return action.kind == "item" and ns.ItemCount(action.itemID) > 0 end)
  syncStops()
end)

-- Objectives have no event of their own: check the journey's quests when the log changes.
ns.On("QUEST_LOG_UPDATE", function()
  local a = Nav.active
  if not (a and a.journey) then return end
  for _, step in ipairs(a.route.steps) do
    local stop = ns.Journey.PendingAction(step)
    if stop and stop.action.kind == "complete" and ns.QuestLog.IsComplete(stop.action.questID) then
      questAction("complete", stop.action.questID)
      break
    end
  end
  syncStops()
end)

-- Drops a stop (and the stops that need it, e.g. a quest's hand-in when you
-- drop its pickup) and re-plans the rest.
-- The open stops that need `stop` (directly or through others), in plan order.
local function dependents(journey, stop)
  local root = journey.root or journey.def
  local dropped, out = { [stop] = true }, {}
  local changed = true
  while changed do
    changed = false
    for _, other in ipairs(root.stops or {}) do
      for _, before in ipairs(other.after or {}) do
        if dropped[before] and not dropped[other] then
          dropped[other], changed = true, true
          if not other.done and not other.skipped then out[#out + 1] = other end
        end
      end
    end
  end
  return out
end

function Nav.Drop(stop)
  local a = Nav.active
  if not (a and a.journey and stop) then return end
  stop.skipped = true
  for _, other in ipairs(dependents(a.journey, stop)) do other.skipped = true end
  local here = ns.Geo.PlayerNode()
  local journey = here and ns.Journey.Replan(a.journey, here)
  if not journey then
    ns.print("no stops left.")
    return Nav.Stop()
  end
  adopt(a, { steps = journey.steps, seconds = journey.seconds }, journey)
end

-- Moves a stop of the journey to where `target` is (the overview's drag and
-- drop) and re-plans; the journey keeps your order from then on.
function Nav.MoveStop(stop, target)
  local a = Nav.active
  if not (a and a.journey) then return false end
  if not ns.Journey.Move(a.journey, stop, target) then
    ns.print("can't move that stop there: it comes after another stop.")
    return false
  end
  local here = ns.Geo.PlayerNode()
  local journey = here and ns.Journey.Replan(a.journey, here)
  if not journey then return false end
  adopt(a, { steps = journey.steps, seconds = journey.seconds }, journey)
  return true
end

-- Adds stops to the current journey as detours and re-plans the order from
-- where you are; plain directions become a journey ("custom") with their
-- destination as a stop. With no journey on, this starts one. Returns true
-- when the journey changed.
local TRIP_TITLE = "Your journey"

function Nav.AddToTrip(stops, label)
  local here = ns.Geo.PlayerNode()
  if not here or #stops == 0 then return false end
  local a = Nav.active
  if not a then
    local journey = ns.Journey.Plan(here, { title = label, kind = "custom", stops = stops })
    if not journey then
      ns.print("no route to " .. label .. " from here.")
      return false
    end
    startJourney(journey)
    return true
  end
  local journey = a.journey or { root = { title = a.title, kind = "custom", stops = { visitStop(a.title, a.goal) } } }
  if ns.Journey.Extend(journey, stops) == 0 then
    ns.print(label .. " is already in your journey.")
    return false
  end
  local root = journey.root or journey.def
  root.title = TRIP_TITLE
  local planned = ns.Journey.Replan(journey, here)
  if not planned then
    ns.print("no route for the journey from here.")
    return false
  end
  a.title = planned.title
  adopt(a, { steps = planned.steps, seconds = planned.seconds }, planned)
  ns.print(string.format("added %s to your journey: %d stops, %s", label, #planned.stops,
    ns.FormatDuration(planned.seconds)))
  ns.Fire("JOURNEY_EXTENDED")
  -- One sound: the follow-up question's, when it asks one.
  if not offerFollowUps(stops) then ns.Sounds.Play("step") end
  return true
end

-- The same, by the name the design uses: a detour is a stop added to a journey.
Nav.AddDetour = Nav.AddToTrip

-- Follow-up quests. When a journey gains a quest's hand-in, the quests that
-- follow it (Quests.FollowUps) are offered when adding them costs little
-- travel (FOLLOW_UP_SLACK more seconds): you pick them up where you hand the
-- first in, often from the same NPC. The rest of the chain after them is
-- listed too (CHAIN_OFFER_DEPTH steps, CHAIN_OFFER_MAX quests), ticked when
-- it is on the way as well, for you to tick or untick (UI/ChainPicker.lua).
-- Adding one quest (from your log, a search, a pickup) lists its follow-ups
-- out of the way too, unticked: you chose that quest, so its chain is wanted;
-- a journey of several only asks about the ones on the way.
local FOLLOW_UP_SLACK = 180
local CHAIN_OFFER_DEPTH = 4
local CHAIN_OFFER_MAX = 8

-- Seconds to do one quest on top of the travel: your average once known.
local function questSeconds()
  return ns.QuestTimes.Seconds() or (ns.ForYou and ns.ForYou.SECONDS_PER_QUEST) or 300
end

-- The offer: { quests = { entry, ... }, stops, extra }, entries in chain order
-- (a quest right after the one it follows):
--   { quest (row), after (questID it follows), parent (entry index, nil for a
--     first follow-up), depth, travel (seconds it adds), seconds (travel and
--     doing it), stops, checked }
-- `stops` and `extra` are the ticked ones' stops and travel.
-- `anyDistance`: first follow-ups out of the way are listed too (unticked).
-- `skip`: quest IDs not to list (ones you were just asked about).
function Nav.FollowUpOffer(stops, anyDistance, skip)
  local a = Nav.active
  local here = ns.Geo.PlayerNode()
  if not (a and a.journey and here) then return nil end
  local root = a.journey.root or a.journey.def
  local inTrip = {}
  for id in pairs(skip or {}) do inTrip[id] = true end
  for _, stop in ipairs(root.stops or {}) do
    if stop.action and stop.action.questID then inTrip[stop.action.questID] = true end
  end
  local base = ns.Journey.Replan(a.journey, here)
  if not base then return nil end
  local open = {}
  for _, s in ipairs(root.stops) do
    if not s.done and not s.skipped then open[#open + 1] = s end
  end
  local perQuest = questSeconds()
  local offer = { quests = {}, stops = {}, extra = 0, perQuest = perQuest }
  local travel = 0 -- what every quest listed so far adds to the journey

  local function consider(turnin, afterID, parent, depth)
    for _, q in ipairs(ns.Quests.FollowUps(afterID)) do
      if #offer.quests >= CHAIN_OFFER_MAX then return end
      if not inTrip[q.id] then
        inTrip[q.id] = true
        local qs = ns.Journey.QuestStops(q.id, here)
        if #qs > 0 and qs[1].action and qs[1].action.kind == "pickup" then
          qs[1].after = { turnin }
          -- The journey with it (and the ones listed before), against the journey without.
          local with = { unpack(open) }
          for _, s in ipairs(qs) do with[#with + 1] = s end
          local planned = ns.Journey.Plan(here, { stops = with })
          local extra = planned and planned.seconds - base.seconds - travel
          -- A first follow-up only when it's on the way (or anyDistance); the chain after it is listed anyway.
          if extra and (parent or anyDistance or extra <= FOLLOW_UP_SLACK) then
            extra = math.max(0, extra)
            travel = travel + extra
            open = with
            local entry = { quest = q, after = afterID, parent = parent, depth = depth, travel = extra,
              seconds = extra + perQuest, stops = qs,
              checked = extra <= FOLLOW_UP_SLACK and (not parent or offer.quests[parent].checked) }
            offer.quests[#offer.quests + 1] = entry
            if entry.checked then
              offer.extra = offer.extra + extra
              for _, s in ipairs(qs) do offer.stops[#offer.stops + 1] = s end
            end
            local last = qs[#qs]
            if depth < CHAIN_OFFER_DEPTH and last.action and last.action.kind == "turnin" then
              consider(last, q.id, #offer.quests, depth + 1)
            end
          end
        end
      end
    end
  end

  for _, stop in ipairs(stops) do
    local action = stop.action
    if action and action.kind == "turnin" and not stop.done then consider(stop, action.questID, nil, 1) end
  end
  if #offer.quests == 0 then return nil end
  return offer
end

-- Ticks or unticks a quest of the offer: a quest needs the one before it in
-- the chain, so ticking one ticks those before it, and unticking one unticks
-- those after it.
function Nav.ToggleFollowUp(offer, index)
  local entry = offer.quests[index]
  if not entry then return end
  entry.checked = not entry.checked
  if entry.checked then
    local p = entry.parent
    while p do
      offer.quests[p].checked = true
      p = offer.quests[p].parent
    end
  else
    for i = index + 1, #offer.quests do
      local e = offer.quests[i]
      if e.parent and not offer.quests[e.parent].checked then e.checked = false end
    end
  end
end

-- The ticked quests: { stops, names, count, seconds (travel and doing them) }.
function Nav.FollowUpChoice(offer)
  local choice = { stops = {}, names = {}, count = 0, seconds = 0 }
  for _, e in ipairs(offer.quests) do
    if e.checked then
      choice.count = choice.count + 1
      choice.seconds = choice.seconds + e.seconds
      choice.names[#choice.names + 1] = e.quest.name or ("quest " .. e.quest.id)
      for _, s in ipairs(e.stops) do choice.stops[#choice.stops + 1] = s end
    end
  end
  return choice
end

-- Adds the ticked quests of the offer to the journey. The ones left unticked
-- aren't asked about again straight away; the chain past the offer can be.
local answered

function Nav.AcceptFollowUps(offer)
  local choice = Nav.FollowUpChoice(offer)
  if choice.count == 0 then return false end
  answered = {}
  for _, e in ipairs(offer.quests) do answered[e.quest.id] = true end
  local added = Nav.AddToTrip(choice.stops, table.concat(choice.names, ", "))
  answered = nil
  return added
end

function offerFollowUps(stops)
  local handIns = {}
  for _, stop in ipairs(stops) do
    local action = stop.action
    if action and action.kind == "turnin" and not stop.done then handIns[action.questID] = true end
  end
  local single = next(handIns) ~= nil and next(handIns, next(handIns)) == nil
  local offer = Nav.FollowUpOffer(stops, single and not answered, answered)
  if not offer then return end
  local firsts, seen = {}, {}
  for _, e in ipairs(offer.quests) do
    if not e.parent and not seen[e.after] then
      seen[e.after] = true
      local q = ns.Quests.Quest(e.after)
      firsts[#firsts + 1] = q and q.name or ("quest " .. e.after)
    end
  end
  offer.heading = table.concat(firsts, ", ") .. " continues with:"
  Nav.pendingFollowUps = offer
  if not (ns.ChainPicker and ns.ChainPicker.Show(offer)) then return end
  ns.Sounds.Play("popup")
  return true
end

-- True when the current journey still has an open stop for this quest.
function Nav.TripHasQuest(questID)
  local a = Nav.active
  local root = a and a.journey and (a.journey.root or a.journey.def)
  for _, stop in ipairs(root and root.stops or {}) do
    if stop.action and stop.action.questID == questID and not stop.done and not stop.skipped then return true end
  end
  return false
end

-- Takes a quest's open stops out of the journey.
function Nav.RemoveQuest(questID)
  local a = Nav.active
  if not (a and a.journey) then return end
  local root = a.journey.root or a.journey.def
  for _, stop in ipairs(root.stops or {}) do
    if stop.action and stop.action.questID == questID and not stop.done then stop.skipped = true end
  end
  local here = ns.Geo.PlayerNode()
  local planned = here and ns.Journey.Replan(a.journey, here)
  if not planned then return Nav.Stop() end
  adopt(a, { steps = planned.steps, seconds = planned.seconds }, planned)
end

-- A saved journey re-planned from where you are (the slow part, run as a
-- background job after a login): { journey } or { goal, route } to start,
-- "done" when nothing of it is left to do, or nil to try again in a moment:
-- just after a login or reload the game may not have your position, its maps
-- or your quest log ready, and a journey dropped then would be lost.
local function planResume(saved)
  local here = ns.Geo.PlayerNode()
  if not here then return nil end
  if saved.journey then
    local def = ns.Journey.Load(saved.journey)
    local journey = ns.Journey.Resume(def, here)
    if journey then return { journey = journey } end
    if ns.Journey.HasOpenStops(def) then return nil end
  elseif saved.goal then
    local goal = ns.Geo.Node(saved.goal.mapID, saved.goal.x, saved.goal.y, saved.goal.label)
    local route = goal and ns.Router.Plan(here, goal, ns.Network.Build())
    if not route then return nil end
    goal.npc = saved.goal.npc
    return { goal = goal, route = route }
  end
  return "done"
end

-- Starts what planResume found. True when that's settled: resumed, nothing
-- left, or something else started (or the save changed) meanwhile.
local function applyResume(saved, plan)
  if Nav.active or ns.charDB.nav ~= saved then return true end
  if plan == "done" then
    ns.charDB.nav = nil
    return true
  end
  if not plan then return false end
  if plan.journey then
    ns.print("resuming journey: " .. plan.journey.title .. " (/ww stop to end it)")
    Nav.StartJourney(plan.journey, true)
    if Nav.active and saved.stats then Nav.active.stats = saved.stats end
  else
    Nav.active = { title = saved.title, goal = plan.goal, route = ns.Router.WithZoneSteps(plan.route), index = 1,
      stats = saved.stats or newStats() }
    ns.print("resuming directions to " .. saved.title .. " (/ww stop to end them)")
    showStep()
  end
  return true
end

-- Picks up a saved journey, re-planned from where you are, all at once (see
-- planResume). True when that's settled; false to try again later.
function Nav.Resume()
  local saved = ns.charDB.nav
  if not saved or Nav.active then return true end
  return applyResume(saved, planResume(saved))
end

-- XP earned on a journey, across level-ups.
ns.On("PLAYER_XP_UPDATE", function()
  local xp, max = UnitXP("player"), UnitXPMax("player")
  local a = Nav.active
  if a and a.stats and lastXP then
    local gained = xp >= lastXP and xp - lastXP or (lastXPMax or lastXP) - lastXP + xp
    a.stats.xp = a.stats.xp + gained
  end
  lastXP, lastXPMax = xp, max
end)

ns.On("PLAYER_LEVEL_UP", function() count("levels") end)
ns.Listen("FLIGHTS_CHANGED", function(learned) count("flights", learned) end)

-- Money in on a journey (loot, quest rewards, selling); spending doesn't take it back.
ns.On("PLAYER_MONEY", function()
  local money = GetMoney()
  if lastMoney and money > lastMoney then count("money", money - lastMoney) end
  lastMoney = money
end)
ns.On("PLAYER_LOGIN", function() lastMoney = GetMoney() end)

-- After a login or reload: the saved journey back, re-planned as a background
-- job (ns.Warm) once the quest data is ready, tried every RESUME_EVERY seconds
-- RESUME_TRIES times while the game isn't ready for it. A journey that can't
-- be re-planned stays saved (/ww resume, or the next login); one that fails
-- with an error RESUME_FAILURES logins running (saved by an older version,
-- say) is dropped rather than fail every login. The game stopping a script
-- that ran too long says nothing about the journey, so that doesn't count.
local RESUME_EVERY, RESUME_TRIES, RESUME_FAILURES = 3, 10, 3

local function resumeFailed(err, reported)
  local saved = ns.charDB.nav
  local timeout = type(err) == "string" and err:find("script ran too long", 1, true)
  if saved and not timeout then
    saved.failed = (saved.failed or 0) + 1
    if saved.failed >= RESUME_FAILURES then ns.charDB.nav = nil end
  end
  Nav.active = nil
  clearPin()
  if not reported then geterrorhandler()(err) end
end

local function tryResume(triesLeft)
  local saved = ns.charDB.nav
  if not saved or Nav.active then
    if not Nav.active then clearPin() end
    return
  end
  -- Re-planning reads the quest data: after it's indexed (Quests.Warm).
  if ns.Quests.Warm() then
    ns.After(RESUME_EVERY, function() tryResume(triesLeft) end)
    return
  end
  ns.Warm(function() return planResume(saved) end, function(ok, plan)
    -- A job's error is reported already.
    if not ok then return resumeFailed(plan, true) end
    local fine, settled = pcall(applyResume, saved, plan)
    if not fine then return resumeFailed(settled) end
    if settled then
      if not Nav.active then clearPin() end
    elseif triesLeft > 1 then
      ns.After(RESUME_EVERY, function() tryResume(triesLeft - 1) end)
    else
      ns.print("couldn't re-plan your journey from here yet; it's kept: /ww resume tries again.")
    end
  end)
end

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if not (isLogin or isReload) then return end
  ns.After(1, function()
    adoptPin()
    tryResume(RESUME_TRIES)
  end)
end)

ns.RegisterCommand("resume", "/ww resume - pick up the saved journey again", function()
  if Nav.active then return ns.print("a journey is already on.") end
  if not ns.charDB.nav then return ns.print("no saved journey.") end
  tryResume(1)
end)

---------------------------------------------------------------- set aside

-- A journey you set aside (to start another, or for later) is saved with its
-- stops done so far, newest first, up to MAX_SET_ASIDE of them; the oldest
-- goes when there's more. Resuming one plans what's left of it from here.
-- The journey overview lists them under the journey on now; /ww journeys
-- lists them in chat.
local MAX_SET_ASIDE = 5

function Nav.SetAsideList()
  ns.charDB.journeys = ns.charDB.journeys or {}
  return ns.charDB.journeys
end

-- Saves the journey on now (plain directions as a one-stop journey) and ends
-- navigation, without the fanfare. Returns the list entry, or nil without one.
function Nav.SetAside()
  local a = Nav.active
  if not a then return nil end
  local journey = a.journey or { root = { title = a.title, kind = "custom", stops = { visitStop(a.title, a.goal) } } }
  local saved = ns.Journey.Save(journey)
  local left = 0
  for _, s in ipairs(saved.stops) do
    if not (s.done or s.skipped) then left = left + 1 end
  end
  local entry = { title = a.title, kind = saved.kind, icon = saved.icon, at = time(), stops = left, journey = saved,
    stats = a.stats }
  local list = Nav.SetAsideList()
  table.insert(list, 1, entry)
  while #list > MAX_SET_ASIDE do table.remove(list) end
  clearWaypoints()
  Nav.active = nil
  save()
  ns.print(string.format("set aside: %s (%d stop%s left). Resume it from the journey overview or /ww journeys.",
    a.title, left, left == 1 and "" or "s"))
  ns.Fire("NAV_CHANGED")
  ns.Fire("JOURNEYS_CHANGED")
  return entry
end

-- Starts set-aside journey `i` again, planned from here; a journey on now is
-- set aside in its place. True when it started.
function Nav.ResumeSetAside(i)
  local list = Nav.SetAsideList()
  local entry = list[i or 1]
  if not entry then
    ns.print("no journey set aside there.")
    return false
  end
  local here = ns.Geo.PlayerNode()
  if not here then
    ns.print("can't read your position here.")
    return false
  end
  local def = ns.Journey.Load(entry.journey)
  local journey = ns.Journey.Resume(def, here)
  if not journey then
    if ns.Journey.HasOpenStops(def) then
      ns.print("no route from here to what's left of " .. entry.title .. "; it's kept.")
      return false
    end
    table.remove(list, i or 1)
    ns.print("nothing left to do on " .. entry.title .. ".")
    ns.Fire("JOURNEYS_CHANGED")
    return false
  end
  table.remove(list, i or 1)
  if Nav.active then Nav.SetAside() end
  ns.print("resuming journey: " .. entry.title)
  startJourney(journey)
  if Nav.active and entry.stats then Nav.active.stats = entry.stats end
  ns.Fire("JOURNEYS_CHANGED")
  return true
end

function Nav.ForgetSetAside(i)
  local list = Nav.SetAsideList()
  local entry = table.remove(list, i or 1)
  if not entry then return false end
  ns.print("forgotten: " .. entry.title)
  ns.Fire("JOURNEYS_CHANGED")
  return true
end

-- "~5 min ago" for a set-aside entry.
function Nav.SetAsideAge(entry)
  local seconds = time() - (entry.at or time())
  return (seconds < 60 and "just now") or (ns.FormatDuration(seconds) .. " ago")
end

ns.RegisterCommand("journeys", "/ww journeys [resume|forget <n>] - the journey on now and the ones set aside", function(rest)
  local verb, n = (rest or ""):lower():match("^(%a*)%s*(%d*)")
  if verb == "resume" then return Nav.ResumeSetAside(tonumber(n) or 1) end
  if verb == "forget" then
    if not Nav.ForgetSetAside(tonumber(n) or 1) then ns.print("no journey set aside there.") end
    return
  end
  local p = Nav.Progress()
  if p then
    ns.print(string.format("on now: %s (%d of %d stops done, %s to go)", p.title, p.done, p.total,
      ns.FormatDuration(p.seconds)))
  else
    ns.print("no journey on now.")
  end
  local list = Nav.SetAsideList()
  if #list == 0 then return ns.print("none set aside.") end
  for i, entry in ipairs(list) do
    ns.print(string.format("set aside %d: %s (%d stop%s left, %s) - /ww journeys resume %d, /ww journeys forget %d",
      i, entry.title, entry.stops or 0, entry.stops == 1 and "" or "s", Nav.SetAsideAge(entry), i, i))
  end
end)

---------------------------------------------------------------- progress

-- How the journey on now stands, for the directions box and the home screen:
-- { title, kind, icon, done, total (stops), seconds (left), stopIndex,
--   stopText (the stop you're heading for), directions (true with plain
--   directions: one stop, the destination) }, or nil with nothing on.
function Nav.Progress()
  local a = Nav.active
  if not a then return nil end
  local here = ns.Geo.PlayerNode()
  local out = { title = a.title, seconds = Nav.RemainingSeconds(here), done = 0, total = 1, stopIndex = 1,
    stopText = a.title, directions = a.journey == nil }
  if a.journey then
    out.kind, out.icon = a.journey.kind, a.journey.icon
    out.done, out.total = ns.Journey.Progress(a.journey)
    local stop = Nav.HeadingFor()
    out.stopText = stop and (stop.text or (stop.node and stop.node.label)) or a.title
    local before = 0
    for _, s in ipairs(a.journey.stops) do
      if s == stop then break end
      if not (s.done or s.skipped or s.passed) then before = before + 1 end
    end
    out.stopIndex = math.min(out.done + before + 1, math.max(out.total, 1))
  end
  return out
end

---------------------------------------------------------------- detail

-- How much the directions box shows (per character): "steps" (each step to
-- the next stop, with a count) or "stops" (the stop you're heading for and
-- the compass; the step on hover).
function Nav.Detail()
  return ns.charDB.detail == "stops" and "stops" or "steps"
end

function Nav.SetDetail(mode)
  ns.charDB.detail = mode == "stops" and "stops" or nil
  ns.Fire("SETTINGS_CHANGED", "detail")
end

ns.RegisterCommand("detail", "/ww detail steps|stops - what the directions box shows: every step, or just the stop", function(rest)
  local mode = (rest or ""):lower():match("^(%a+)")
  if mode ~= "steps" and mode ~= "stops" then mode = Nav.Detail() == "steps" and "stops" or "steps" end
  Nav.SetDetail(mode)
  ns.print(mode == "stops" and "directions box: the stop you're heading for; hover it for the step."
    or "directions box: every step to the next stop.")
end)

-- True while standing at a journey stop that waits for a quest action.
function Nav.Waiting()
  return Nav.active ~= nil and Nav.active.waiting == true
end

-- Automatic re-routing: after a hearthstone or portal (a jump, or a loading
-- screen), on the wrong continent, or when you have walked well away from the
-- current target. Never on a flight path, and not more often than every 10 s.
local JUMP_YARDS = 300
local STRAY_YARDS = 250
local REPLAN_COOLDOWN = 10

local function autoReplan(a, here, reason)
  local now = GetTime and GetTime()
  if now and a.lastReplan and now - a.lastReplan < REPLAN_COOLDOWN then return false end
  a.lastReplan = now
  local route, journey = planFrom(a, here)
  if not route then return false end
  ns.print("re-routed from here (" .. reason .. ").")
  adopt(a, route, journey)
  return true
end

local function checkRoute(a, here, previous)
  local step = a.route.steps[a.index]
  if not step or onTaxi() then return false end
  local distance = ns.Geo.Distance(here, step.to)
  if previous and ns.Geo.Distance(previous, here) > JUMP_YARDS then
    return autoReplan(a, here, "you moved a long way")
  end
  if here.instance ~= step.to.instance and here.instance ~= step.from.instance then
    return autoReplan(a, here, "you're on another continent")
  end
  if step.mode == "walk" and distance < math.huge then
    a.closest = math.min(a.closest or distance, distance)
    if distance > a.closest + STRAY_YARDS then return autoReplan(a, here, "you went another way") end
  end
  return false
end

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if isLogin or isReload then return end
  -- Tick compares with where you were before the loading screen.
  ns.After(1, function()
    if Nav.active then Nav.Tick() end
  end)
end)

-- Called by the HUD several times a second. Returns your node and the step.
-- Objective areas. A quest's objectives are places, not a point: every spawn
-- of what you still need (quest data, Journey.OpenAreas; a finished
-- objective's go when the quest log says so). Within AREA_RADIUS of any of
-- them you're in the area: the stop counts as reached, and the compass and
-- waypoints step aside. Past AREA_LEAVE you've left it. Spawns close together
-- are one area (a camp); a stop remembers the areas you've cleared, so leaving
-- one you worked re-plans the trip on to another area (or the stops on the
-- way there), and a short step out points at the nearest area you haven't.
local AREA_RADIUS, AREA_LEAVE = 80, 120

-- inside (true / false, or nil when the stop has no area), the nearest spot
-- and the index of its area.
local function areaOf(stop, here)
  local action = stop and stop.action
  if not (action and action.kind == "complete") then return nil end
  local areas = ns.Journey.OpenAreas(action.questID)
  if #areas == 0 then return nil end
  local best, bestDistance, bestArea
  for _, area in ipairs(areas) do
    local node, d = ns.Data.Nearest(area.nodes, here)
    -- The camp you just moved on from isn't the area till you're out of it.
    if area.index == stop.leaving then
      if d > AREA_LEAVE then stop.leaving = nil else node = nil end
    end
    if node and d < (bestDistance or math.huge) then best, bestDistance, bestArea = node, d, area.index end
  end
  if not best then return false end
  return bestDistance <= (stop.inArea and AREA_LEAVE or AREA_RADIUS), best, bestArea
end

local function questName(questID)
  local q = ns.Quests.Quest(questID)
  return q and q.name or ("quest " .. questID)
end

-- Left the area of the stop you're on, its objectives not done. A cleared
-- area: the journey from here, on to another. A short step out: the way back
-- to the nearest area you haven't cleared.
-- A camp of the stop's is cleared: the journey from here, on to another camp
-- (or other stops while it respawns), saying which. False without a route.
local function onFromCamp(a, stop, here)
  local journey = a.journey and ns.Journey.Replan(a.journey, here)
  if not journey then return false end
  a.lastReplan = GetTime and GetTime()
  local areas, left = ns.Journey.OpenAreas(stop.action.questID), 0
  for _, area in ipairs(areas) do
    if not ns.Journey.Cleared(stop, area.index) then left = left + 1 end
  end
  if left > 0 then
    ns.print(string.format("that spot's cleared: on to another for %s.", questName(stop.action.questID)))
  elseif journey.stops[1] ~= stop then
    ns.print(string.format("that spot's cleared: other stops first while it respawns (%s).",
      ns.FormatDuration(ns.Journey.RespawnIn(stop))))
  else
    ns.print(string.format("that spot's cleared: back when it respawns (%s).", ns.FormatDuration(ns.Journey.RespawnIn(stop))))
  end
  adopt(a, { steps = journey.steps, seconds = journey.seconds }, journey)
  return true
end

local function leftArea(a, step, stop, here, spot, cleared)
  if cleared and onFromCamp(a, stop, here) then return end
  local node = ns.Journey.PickArea(stop, here) or spot
  if node then
    step.to = ns.Geo.Node(node.mapID, node.x, node.y, stop.node.label) or node
    stop.node = step.to
    showStep()
  end
end

-- Progress on a later stop's objectives while you're in their area (a camp on
-- the way to the next): you're doing that one now, so it comes first.
local function progressOf(questID)
  local parts = {}
  for _, o in ipairs(C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID) or {}) do
    parts[#parts + 1] = tostring(o.numFulfilled or o.text)
  end
  return table.concat(parts, "|")
end

local function doingLater()
  local a = Nav.active
  if not (a and a.journey) or onTaxi() or Nav.Dead() then return end
  local here = ns.Geo.PlayerNode()
  if not here then return end
  local current = a.route.steps[a.index]
  local busy = a.waiting or (current and current.stop and current.stop.inArea)
  for k = a.index, #a.route.steps do
    local stop = ns.Journey.PendingAction(a.route.steps[k])
    if stop and stop.action.kind == "complete" then
      local before, now = stop.progress, progressOf(stop.action.questID)
      stop.progress = now
      if before and before ~= now and not busy and stop ~= (current and current.stop) then
        local inside, _, area = areaOf(stop, here)
        if inside then
          stop.inArea = true
          ns.Journey.EnterArea(stop, area)
          local journey = ns.Journey.Replan(a.journey, here, nil, stop)
          if journey then
            a.lastReplan = GetTime and GetTime()
            ns.print(string.format("you're doing %s here: it's next on the journey now.", questName(stop.action.questID)))
            adopt(a, { steps = journey.steps, seconds = journey.seconds }, journey)
          end
          return
        end
      end
    end
  end
end

ns.On("QUEST_LOG_UPDATE", doingLater)

-- Abandoning a quest (Quests.lua): it isn't asked about if just picked up,
-- an open follow-up question about its chain closes, and its open stops
-- leave the journey with the stops that need them (a follow-up picked up
-- where you'd have handed it in). A journey with nothing left ends.
function Nav.QuestAbandoned(questID)
  for i = #picked, 1, -1 do
    if picked[i] == questID then table.remove(picked, i) end
  end
  local offer = ns.ChainPicker and ns.ChainPicker.current
  if offer then
    for _, e in ipairs(offer.quests) do
      if e.after == questID then
        ns.ChainPicker.Cancel()
        break
      end
    end
  end
  local a = Nav.active
  if not (a and a.journey) then return end
  local root = a.journey.root or a.journey.def
  local dropped = false
  for _, stop in ipairs(root.stops or {}) do
    if stop.action and stop.action.questID == questID and not stop.done and not stop.skipped then
      stop.skipped, dropped = true, true
      for _, other in ipairs(dependents(a.journey, stop)) do other.skipped = true end
    end
  end
  if not dropped then return end
  local here = ns.Geo.PlayerNode()
  local planned = here and ns.Journey.Replan(a.journey, here)
  if not planned then
    ns.print(string.format("you abandoned %s: nothing left on the journey, so it's cancelled.", questName(questID)))
    return Nav.Stop()
  end
  ns.print(string.format("you abandoned %s: dropped from your journey.", questName(questID)))
  a.title = planned.title or a.title
  adopt(a, { steps = planned.steps, seconds = planned.seconds }, planned)
end

ns.Listen("QUEST_ABANDONED", Nav.QuestAbandoned)

---------------------------------------------------------------- move on, skip

-- The stop the current leg of a journey leads to (the step may be a flight on the way).
function Nav.HeadingFor()
  local a = Nav.active
  if not (a and a.journey) then return nil end
  for k = a.index, #a.route.steps do
    local stop = a.route.steps[k].stop
    if stop then return stop end
  end
  return nil
end

-- What move on does now: "cleared" (you're in one of the stop's camps: it
-- counts as cleared), "done" (a quest step only you can tell is done, and
-- you're at it), "later" (the next stop first), or nil off a journey.
function Nav.MoveOnKind()
  local stop = Nav.HeadingFor()
  if not stop then return nil end
  if stop.inArea and stop.areaAt then return "cleared" end
  local current = Nav.CurrentStep()
  if stop.action and stop.action.kind == "manual" and Nav.Waiting() and current and current.stop == stop then
    return "done"
  end
  return "later"
end

function Nav.MoveOn()
  local a = Nav.active
  local stop = Nav.HeadingFor()
  local here = ns.Geo.PlayerNode()
  if not (stop and here) then return end
  local kind = Nav.MoveOnKind()
  if kind == "cleared" then
    ns.Journey.ClearArea(stop)
    onFromCamp(a, stop, here)
  elseif kind == "done" then
    finishStop(function(action) return action == stop.action end)
  else
    local first = ns.Journey.Postpone(a.journey, stop)
    if not first then
      ns.print("nothing else on the journey to do first; skip it to take it off.")
      return
    end
    local journey = ns.Journey.Replan(a.journey, here)
    if not journey then return end
    ns.print(string.format("later: %s, after %s.", stop.text or "that stop", first.text or "the next stop"))
    adopt(a, { steps = journey.steps, seconds = journey.seconds }, journey)
  end
end

-- Takes the stop you're heading for off the journey, with the stops that need
-- it (a hand-in when you skip the objectives), once you say yes.
function Nav.Skip()
  local a = Nav.active
  local stop = Nav.HeadingFor()
  if not stop then return end
  local also = dependents(a.journey, stop)
  if not (StaticPopupDialogs and StaticPopup_Show) then return Nav.Drop(stop) end
  StaticPopupDialogs.WAYWARD_SKIP = StaticPopupDialogs.WAYWARD_SKIP or {
    text = "%s",
    button1 = "Skip", button2 = "Cancel",
    OnAccept = function(_, data) if Nav.active then Nav.Drop(data.stop) end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  local text = string.format("Skip \"%s\"?\n\nIt's taken off the journey%s.", stop.text or "this stop",
    #also == 0 and "" or #also == 1 and string.format(", with \"%s\", which needs it", also[1].text or "a stop")
    or string.format(", with the %d stops that need it", #also))
  askPlayer("WAYWARD_SKIP", text, { stop = stop })
end

-- True while you're in the area of the stop you're working on.
function Nav.InArea()
  local step = Nav.CurrentStep()
  return step ~= nil and step.stop ~= nil and step.stop.inArea == true
end

-- True while you're on a flight path: no arrows, no re-planning, no steps
-- passed on the way; landing picks up from where you are.
function Nav.Flying()
  return Nav.active ~= nil and onTaxi()
end

-- Dying. From death until you're alive again (at your corpse or a spirit
-- healer) the journey holds still: releasing moves you to a graveyard, which
-- isn't leaving a camp (its visit just ends, not cleared) or a reason to
-- re-plan, and the way still points where it did.
local dead = false

local function secretValue(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

function Nav.Dead()
  if UnitIsDeadOrGhost then
    local v = UnitIsDeadOrGhost("player")
    if not secretValue(v) then return v and true or false end
  end
  return dead
end

-- Once per death: the camp you were in isn't left, its visit just ends.
local function died(a)
  if a.died then return end
  a.died, a.waiting = true, false
  for _, step in ipairs(a.route.steps) do
    if step.stop and (step.stop.visit or step.stop.inArea) then ns.Journey.ForgetVisit(step.stop) end
  end
end

ns.On("PLAYER_DEAD", function()
  dead = true
  if Nav.active then died(Nav.active) end
end)

local function alive()
  dead = false
  local a = Nav.active
  -- Where you died and where you are now aren't a journey's distance or a stray.
  if a then a.died, a.lastHere, a.closest = nil, nil, nil end
end
ns.On("PLAYER_UNGHOST", alive)
ns.On("PLAYER_ALIVE", function()
  -- Also fires on release, as a ghost.
  local ghost = UnitIsGhost and UnitIsGhost("player")
  if not secretValue(ghost) and ghost == false then alive() end
end)

function Nav.Tick()
  local a = Nav.active
  if not a then return nil end
  local here = ns.Geo.PlayerNode()
  if not here then return nil, Nav.CurrentStep() end
  if Nav.Dead() then
    died(a)
    a.lastHere, a.closest = nil, nil
    return here, a.route.steps[a.index]
  end
  a.died = nil
  -- Yards travelled on a journey (not jumps: a hearthstone, a loading screen).
  local last = a.lastHere
  if a.stats and last and last.instance == here.instance then
    local d = ns.Geo.Distance(last, here)
    if d < JUMP_YARDS then a.stats.distance = a.stats.distance + d end
  end
  if onTaxi() then
    -- Took off without us seeing the flight map: on to the flight.
    if flightTalk(a.route.steps, a.index) then
      a.index = a.index + 1
      showStep()
    end
    if not a.flying then
      a.flying = true
      -- TomTom's arrow has nothing to show in the air.
      clearTomTom()
      ns.Fire("NAV_CHANGED")
    end
    a.lastHere = here
    return here, a.route.steps[a.index]
  elseif a.flying then
    a.flying = nil
    a.lastHere = nil
    showStep()
  end
  local previous = a.lastHere
  a.lastHere = here
  -- In a zone you set out to explore: that stop is done, wherever you crossed in.
  if exploreCheck(here) then return here, Nav.CurrentStep() end
  local startIndex = a.index
  local steps = a.route.steps
  -- Never jump past a stop that still waits for a quest action.
  local limit = #steps
  for k = a.index, #steps do
    if ns.Journey.PendingAction(steps[k]) then
      limit = k
      break
    end
  end
  a.waiting = false
  -- Jump to the step after the furthest destination you have already reached.
  for k = limit, a.index, -1 do
    local step = steps[k]
    local radius = (k == #steps or step.stop) and GOAL_RADIUS or RADIUS[step.mode]
    -- A zone entry counts once you're in that zone, wherever you crossed.
    local reached = step.zoneEntry and (here.mapID == step.zoneEntry
      or ns.Geo.ZoneAt(here.instance, here.wx, here.wy) == step.zoneEntry)
    -- A quest's objectives: being anywhere in their area counts.
    local pending = ns.Journey.PendingAction(step)
    local inside, spot, area = areaOf(pending, here)
    if inside ~= nil then
      local cleared = ns.Journey.EnterArea(pending, inside and area or nil)
      if inside then
        pending.inArea = true
        ns.Camps.Watch(pending)
      elseif pending.inArea then
        pending.inArea = nil
        if k == a.index then
          leftArea(a, step, pending, here, spot, cleared)
          return here, a.route.steps[a.index]
        end
      end
    end
    if reached or inside or (inside == nil and ns.Geo.Distance(here, step.to) <= radius) then
      if ns.Journey.PendingAction(step) then
        a.waiting = true
        if a.index ~= k then
          a.index = k
          showStep()
        end
      elseif flightTalk(steps, k) and not onTaxi() then
        -- At the flight master: the flight starts when you open their map.
        a.waiting = true
        if a.index ~= k then
          a.index = k
          showStep()
        end
      elseif k == #steps and not step.stop and step.to.npc and not a.talked then
        -- At the trainer or vendor: done when you talk to them.
        a.waiting = true
        if a.index ~= k then
          a.index = k
          showStep()
        end
      elseif k == #steps then
        if step.stop then step.stop.done, step.stop.passed = true, nil end
        arrive()
        return here, nil
      else
        if step.stop then step.stop.done, step.stop.passed = true, nil end
        a.index = k + 1
        showStep()
      end
      break
    end
  end
  -- In an objective area there's nothing to point at.
  if Nav.InArea() and (Nav.ownsWaypoint or Nav.tomtomWaypoint) then clearWaypoints() end
  -- Only when nothing was reached: arriving by teleport still counts as arriving.
  if a.index == startIndex and not a.waiting then checkRoute(a, here, previous) end
  return here, a.route.steps[a.index]
end
