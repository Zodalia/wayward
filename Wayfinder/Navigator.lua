local _, ns = ...

-- Follows a planned route or journey: places the built-in map waypoint on the
-- current step's destination and moves on when you get there (or further
-- along). Journey stops with a quest action wait until the quest is accepted
-- or handed in (see Journey.lua).

local Nav = {}
local unpack = unpack or table.unpack
ns.Nav = Nav

-- Yards from a step's destination that count as "reached".
local RADIUS = { walk = 20, fly = 120, transport = 150 }
local GOAL_RADIUS = 10

-- With TomTom installed and its arrow turned on (asked once, see
-- UI/Options.lua), its arrow and pins show the way, on top of the compass in
-- the directions box if that is on too. Modern TomTom: AddWaypoint(uiMapID, x, y, opts) and
-- RemoveWaypoint(uid); if that fails we fall back to our own arrow.
local tomtomFailed

-- Try TomTom again (e.g. after updating it); /wf tomtom calls this.
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
    { title = title, from = "Wayfinder", persistent = false, minimap = true, world = true, crazy = true })
  if ok and uid then
    Nav.tomtomWaypoint = uid
    return true
  end
  tomtomFailed = true
  ns.print("couldn't use TomTom's arrow; using Wayfinder's own.")
  return false
end

-- `title` says what to do there (the step text), for TomTom's arrow and pin.
local function setWaypoint(node, title)
  local mapID, x, y = ns.Geo.ZonePoint(node)
  if not (mapID and x and y) then return end
  if Nav.UsingTomTom() and setTomTom(mapID, x, y, title or node.label or "Wayfinder") then
    -- TomTom shows the way now: take down the map pin we put up before.
    if Nav.ownsWaypoint then
      C_Map.ClearUserWaypoint()
      Nav.ownsWaypoint = false
    end
    return
  end
  if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then return end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
  end
  Nav.ownsWaypoint = true
end

function Nav.CurrentStep()
  local a = Nav.active
  return a and a.route.steps[a.index]
end

-- The trip is saved per character so it survives logging out (see Resume).
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
    ns.print("tip: talk to a flight master once and Wayfinder will route you via your flight paths.")
  end
end

local newStats -- below

local function startRoute(title, goal, route)
  Nav.active = { title = title, goal = goal, route = ns.Router.WithZoneSteps(route), index = 1, stats = newStats() }
  ns.print("directions to " .. title .. ": " .. ns.FormatDuration(route.seconds))
  flightTip()
  showStep()
end

local offerFollowUps -- below: offers a trip's follow-up quests

-- What a trip has come to so far, for the fanfare at its end: XP earned,
-- yards travelled, quests handed in, and when it started.
local lastXP, lastXPMax

function newStats()
  lastXP, lastXPMax = UnitXP and UnitXP("player"), UnitXPMax and UnitXPMax("player")
  return { started = time(), xp = 0, distance = 0, quests = 0 }
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
  if not quiet then offerFollowUps(journey.stops) end
end

-- Starting something new while a trip is on asks: add it to the trip, or
-- replace the trip? (Replaces straight away where the game's dialogs aren't there.)
local function ask(label, add, replace)
  if not (StaticPopupDialogs and StaticPopup_Show) then return replace() end
  StaticPopupDialogs.WAYFINDER_TRIP = StaticPopupDialogs.WAYFINDER_TRIP or {
    text = "You're on a trip: %s.\n\nAdd \"%s\" to it, or replace the trip?",
    button1 = "Add to trip", button2 = "Cancel", button3 = "Replace",
    OnAccept = function(_, data) data.add() end,
    OnAlt = function(_, data) data.replace() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopup_Show("WAYFINDER_TRIP", Nav.active.title, label, { add = add, replace = replace })
end

-- A stop for a plain destination (a trainer, a vendor, a hub); someone to
-- talk to is done when you talk to them.
local function visitStop(title, goal)
  if goal.npc then
    return { node = goal, npc = goal.npc, text = "Talk to " .. goal.npc, action = { kind = "talk", npc = goal.npc } }
  end
  return { node = goal, text = "Go to " .. (goal.label or title) }
end

-- A panel result's stops for adding to a trip: a journey's open stops, or a
-- visit to a route's destination.
function Nav.StopsFor(result)
  if result.journey then return ns.Journey.OpenStops(result.journey) end
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
  if Nav.ownsWaypoint then
    C_Map.ClearUserWaypoint()
    Nav.ownsWaypoint = false
  end
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
    if action and (action.kind == "talk" or action.kind == "train") then return action.npc, stop.node end
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

-- What you do where you are now ("talk", "use", "fly", or nil), for the directions box.
function Nav.Interaction()
  local a = Nav.active
  if not a then return nil end
  if flightTalk(a.route.steps, a.index) then return a.waiting and "talk" or nil end
  local step = a.route.steps[a.index]
  if step and step.mode == "fly" and not onTaxi() then return "fly" end
  if a.waiting and Nav.TargetObject() then return "use" end
  if a.waiting and Nav.TargetNPC() then return "talk" end
  return nil
end

local function arrive()
  local a = Nav.active
  ns.print("you have arrived: " .. a.title)
  -- The end of a trip (or plain directions): its fanfare.
  if a.stats and ns.Fanfare then
    local stats = a.stats
    local ok, err = pcall(ns.Fanfare.TripDone, { title = a.title, xp = stats.xp, seconds = time() - stats.started,
      distance = stats.distance, quests = stats.quests })
    if not ok then ns.print("couldn't show the trip's fanfare: " .. tostring(err)) end
  end
  Nav.Stop()
end

-- "Skip" also counts the current stop as done, so the journey moves on.
-- Skipping a stop's step passes the stop (`passed`: left out of the plan, but
-- not counted as done); going back to it opens it again. A quest step you
-- confirm yourself ("Fill the bowl at the moonwell") is done instead.
function Nav.Next()
  local a = Nav.active
  if not a then return end
  local stop = a.route.steps[a.index].stop
  if stop and not stop.done then
    stop.done = true
    stop.passed = not (stop.action and stop.action.kind == "manual") or nil
  end
  if a.index >= #a.route.steps then return arrive() end
  a.index = a.index + 1
  showStep()
end

function Nav.Prev()
  local a = Nav.active
  if a and a.index > 1 then
    a.index = a.index - 1
    local stop = a.route.steps[a.index].stop
    if stop and stop.passed then stop.done, stop.passed = nil, nil end
    showStep()
  end
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

-- The current step is re-measured from `here`; later steps use the plan.
function Nav.RemainingSeconds(here)
  local a = Nav.active
  if not a then return nil end
  local total = 0
  for i = a.index, #a.route.steps do
    local step = a.route.steps[i]
    if i == a.index and here then
      total = total + ns.Router.SecondsLeft(step, here, onTaxi())
    else
      total = total + step.seconds
    end
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

-- Every other stop of the trip that the quest log, your bags or the completed
-- quests say is done now: skipped stops you did anyway, and steps of a quest
-- whose objectives are complete. The trip is re-planned if the stop you were
-- heading for is among them.
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

-- Picking up a quest that isn't in your trip yet: its stops (do it, hand it
-- in) planned, and a question: add them to the trip (and how much longer it
-- gets), start a new trip for them, or not now. Quests picked up one after
-- another are asked about together, once the trip has no more pickups to do
-- right where you are.
local PICKUP_WAIT = 1.5
local picked, waiting = {}, false

local function stillPicking()
  local step = Nav.CurrentStep()
  local stop = step and step.stop
  return stop ~= nil and stop.action ~= nil and stop.action.kind == "pickup" and not stop.done and Nav.Waiting()
end

-- The offer for the quests picked up: { label, stops, alone (seconds), extra
-- (seconds more on the current trip, or nil without one) }, or nil.
function Nav.PickupOffer(questIDs)
  local here = ns.Geo.PlayerNode()
  if not here then return nil end
  local stops, names = {}, {}
  for _, id in ipairs(questIDs) do
    if not Nav.TripHasQuest(id) then
      local qs = ns.Journey.QuestStops(id, here)
      if #qs > 0 then
        local q = ns.Questie.Quest(id)
        names[#names + 1] = q and q.name or ("quest " .. id)
        for _, st in ipairs(qs) do stops[#stops + 1] = st end
      end
    end
  end
  if #stops == 0 then return nil end
  local label = #names == 1 and names[1] or string.format("%d quests", #names)
  local alone = ns.Journey.Plan(here, { title = label, stops = stops })
  if not alone then return nil end
  local offer = { label = label, names = names, stops = stops, alone = alone.seconds, journey = alone }
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
      local finish = root.finish and not root.finish.done and not root.finish.skipped and root.finish or nil
      local with = base and ns.Journey.Plan(here, { stops = open, finish = finish })
      offer.extra = base and with and math.max(0, with.seconds - base.seconds) or nil
    else
      local with = ns.Journey.Plan(here, { stops = { { node = a.goal, text = a.title } , unpack(stops) } })
      local remaining = Nav.RemainingSeconds(here)
      offer.extra = with and remaining and math.max(0, with.seconds - remaining) or nil
    end
  end
  return offer
end

-- Shows a question; if the game can't, says so in chat rather than nothing.
local function askPlayer(which, text, data)
  local ok, err = pcall(StaticPopup_Show, which, text, nil, data)
  if not ok then ns.print("couldn't show a question (" .. tostring(err) .. "): " .. text:gsub("\n\n", " ")) end
end

local function askPickups()
  if stillPicking() then
    C_Timer.After(PICKUP_WAIT, askPickups)
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
  StaticPopupDialogs.WAYFINDER_PICKUP_ADD = StaticPopupDialogs.WAYFINDER_PICKUP_ADD or {
    text = "%s",
    button1 = "Add to trip", button2 = "Not now", button3 = "New trip",
    OnAccept = function(_, data) Nav.AddToTrip(data.stops, data.label) end,
    OnAlt = function(_, data) startJourney(data.journey) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopupDialogs.WAYFINDER_PICKUP_NEW = StaticPopupDialogs.WAYFINDER_PICKUP_NEW or {
    text = "%s",
    button1 = "Start trip", button2 = "Not now",
    OnAccept = function(_, data) startJourney(data.journey) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  if Nav.active and offer.extra then
    askPlayer("WAYFINDER_PICKUP_ADD", string.format(
      "You picked up %s.\n\nAdd it to your trip (about %s more), or start a new trip for it (%s)?",
      offer.label, ns.FormatDuration(offer.extra), ns.FormatDuration(offer.alone)), offer)
  else
    askPlayer("WAYFINDER_PICKUP_NEW", string.format("You picked up %s.\n\nStart a trip for it (%s)?",
      offer.label, ns.FormatDuration(offer.alone)), offer)
  end
end

ns.On("QUEST_ACCEPTED", function(questID)
  questAction("pickup", questID)
  syncStops()
  picked[#picked + 1] = questID
  if not waiting then
    waiting = true
    C_Timer.After(PICKUP_WAIT, askPickups)
  end
end)
ns.On("QUEST_TURNED_IN", function(questID)
  if Nav.active and Nav.active.stats then Nav.active.stats.quests = Nav.active.stats.quests + 1 end
  questAction("turnin", questID)
  syncStops()
end)

-- Talking to a quest giver: pickups on the trip that they don't offer you are
-- locked (the data missed an earlier quest). They're dropped, with what needs
-- them, and treated as locked everywhere until you hand something in.
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
    ns.Questie.MarkNotOffered(stop.action.questID)
    ns.print(string.format("%s isn't offered yet (it needs earlier quests): dropped from the trip.",
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
  if stop and stop.action and stop.action.kind == "talk" then
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

-- Buying a profession's next rank: the skill cap goes up.
local function trainedCheck()
  local mine = ns.Professions and ns.Professions.Mine()
  if not mine then return end
  finishStop(function(action)
    local have = action.kind == "train" and mine[action.profession]
    return have and have.cap > (action.cap or 0) or false
  end)
end

for _, event in ipairs({ "SKILL_LINES_CHANGED", "TRAINER_UPDATE", "CHAT_MSG_SKILL", "LEARNED_SPELL_IN_TAB" }) do
  ns.On(event, function() C_Timer.After(0.2, trainedCheck) end)
end

-- Collecting an item a quest needs.
ns.On("BAG_UPDATE_DELAYED", function()
  if not GetItemCount then return end
  finishStop(function(action) return action.kind == "item" and (GetItemCount(action.itemID) or 0) > 0 end)
  syncStops()
end)

-- Objectives have no event of their own: check the journey's quests when the log changes.
ns.On("QUEST_LOG_UPDATE", function()
  local a = Nav.active
  if not (a and a.journey and C_QuestLog.IsComplete) then return end
  for _, step in ipairs(a.route.steps) do
    local stop = ns.Journey.PendingAction(step)
    if stop and stop.action.kind == "complete" and C_QuestLog.IsComplete(stop.action.questID) then
      questAction("complete", stop.action.questID)
      break
    end
  end
  syncStops()
end)

-- Drops a stop (and the stops that need it, e.g. a quest's hand-in when you
-- drop its pickup) and re-plans the rest.
function Nav.Drop(stop)
  local a = Nav.active
  if not (a and a.journey and stop) then return end
  local dropped = { [stop] = true }
  stop.skipped = true
  local root = a.journey.root or a.journey.def
  local changed = true
  while changed do
    changed = false
    for _, other in ipairs(root.stops or {}) do
      for _, before in ipairs(other.after or {}) do
        if dropped[before] and not dropped[other] then
          dropped[other], other.skipped, changed = true, true, true
        end
      end
    end
  end
  local here = ns.Geo.PlayerNode()
  local journey = here and ns.Journey.Replan(a.journey, here)
  if not journey then
    ns.print("no stops left.")
    return Nav.Stop()
  end
  adopt(a, { steps = journey.steps, seconds = journey.seconds }, journey)
end

-- Moves a stop of the trip to where `target` is (the overview's drag and
-- drop) and re-plans; the trip keeps your order from then on.
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

-- Adds stops to the current trip and re-plans the order from where you are;
-- plain directions become a trip with their destination as a stop. With no
-- trip on, this starts one. Returns true when the trip changed.
local TRIP_TITLE = "Your trip"

function Nav.AddToTrip(stops, label)
  local here = ns.Geo.PlayerNode()
  if not here or #stops == 0 then return false end
  local a = Nav.active
  if not a then
    local journey = ns.Journey.Plan(here, { title = label, stops = stops })
    if not journey then
      ns.print("no route to " .. label .. " from here.")
      return false
    end
    startJourney(journey)
    return true
  end
  local journey = a.journey or { root = { title = a.title, stops = { visitStop(a.title, a.goal) } } }
  if ns.Journey.Extend(journey, stops) == 0 then
    ns.print(label .. " is already in your trip.")
    return false
  end
  local root = journey.root or journey.def
  root.title = TRIP_TITLE
  local planned = ns.Journey.Replan(journey, here)
  if not planned then
    ns.print("no route for the trip from here.")
    return false
  end
  a.title = planned.title
  adopt(a, { steps = planned.steps, seconds = planned.seconds }, planned)
  ns.print(string.format("added %s to your trip: %d stops, %s", label, #planned.stops,
    ns.FormatDuration(planned.seconds)))
  ns.Fire("JOURNEY_STARTED")
  offerFollowUps(stops)
  return true
end

-- Follow-up quests. When a trip gains a quest's hand-in, the quests that
-- follow it (Questie.FollowUps) are offered when adding them costs little
-- travel (FOLLOW_UP_SLACK more seconds): you pick them up where you hand the
-- first in, often from the same NPC.
local FOLLOW_UP_SLACK = 180

function Nav.FollowUpOffer(stops)
  local a = Nav.active
  local here = ns.Geo.PlayerNode()
  if not (a and a.journey and here) then return nil end
  local root = a.journey.root or a.journey.def
  local inTrip = {}
  for _, stop in ipairs(root.stops or {}) do
    if stop.action and stop.action.questID then inTrip[stop.action.questID] = true end
  end
  local base = ns.Journey.Replan(a.journey, here)
  if not base then return nil end
  local offer = { quests = {}, stops = {}, extra = 0 }
  for _, stop in ipairs(stops) do
    local action = stop.action
    if action and action.kind == "turnin" and not stop.done then
      for _, q in ipairs(ns.Questie.FollowUps(action.questID)) do
        if not inTrip[q.id] then
          inTrip[q.id] = true
          local qs = ns.Journey.QuestStops(q.id, here)
          if #qs > 0 and qs[1].action and qs[1].action.kind == "pickup" then
            qs[1].after = { stop }
            -- The trip with it, against the trip without: the travel it adds.
            local open = {}
            for _, s in ipairs(root.stops) do
              if not s.done and not s.skipped then open[#open + 1] = s end
            end
            for _, s in ipairs(offer.stops) do open[#open + 1] = s end
            for _, s in ipairs(qs) do open[#open + 1] = s end
            local finish = root.finish and not root.finish.done and not root.finish.skipped and root.finish or nil
            local with = ns.Journey.Plan(here, { stops = open, finish = finish })
            local extra = with and with.seconds - base.seconds - offer.extra
            if extra and extra <= FOLLOW_UP_SLACK then
              offer.extra = offer.extra + math.max(0, extra)
              offer.quests[#offer.quests + 1] = { quest = q, after = action.questID }
              for _, s in ipairs(qs) do offer.stops[#offer.stops + 1] = s end
            end
          end
        end
      end
    end
  end
  if #offer.quests == 0 then return nil end
  return offer
end

function offerFollowUps(stops)
  local offer = Nav.FollowUpOffer(stops)
  if not offer then return end
  local names, firsts = {}, {}
  for _, f in ipairs(offer.quests) do
    names[#names + 1] = f.quest.name or ("quest " .. f.quest.id)
    local q = ns.Questie.Quest(f.after)
    firsts[#firsts + 1] = q and q.name or ("quest " .. f.after)
  end
  local label = table.concat(names, ", ")
  Nav.pendingFollowUps = offer
  if not (StaticPopupDialogs and StaticPopup_Show) then return end
  StaticPopupDialogs.WAYFINDER_FOLLOWUP = StaticPopupDialogs.WAYFINDER_FOLLOWUP or {
    text = "%s",
    button1 = "Add", button2 = "No thanks",
    OnAccept = function(_, data) Nav.AddToTrip(data.stops, data.label) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  askPlayer("WAYFINDER_FOLLOWUP", string.format("%s continues with %s, about %s more on the way.\n\nAdd it to your trip too?",
    table.concat(firsts, ", "), label, ns.FormatDuration(offer.extra)), { stops = offer.stops, label = label })
end

-- True when the current trip still has an open stop for this quest.
function Nav.TripHasQuest(questID)
  local a = Nav.active
  local root = a and a.journey and (a.journey.root or a.journey.def)
  for _, stop in ipairs(root and root.stops or {}) do
    if stop.action and stop.action.questID == questID and not stop.done and not stop.skipped then return true end
  end
  return false
end

-- Takes a quest's open stops out of the trip.
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

-- Picks up a saved trip after logging in, re-planned from where you are.
function Nav.Resume()
  local saved = ns.charDB.nav
  local here = ns.Geo.PlayerNode()
  if not (saved and here) or Nav.active then return end
  if saved.journey then
    local journey = ns.Journey.Resume(ns.Journey.Load(saved.journey), here)
    if journey then
      ns.print("resuming journey: " .. journey.title .. " (/wf stop to end it)")
      Nav.StartJourney(journey, true)
      if Nav.active and saved.stats then Nav.active.stats = saved.stats end
      return
    end
  elseif saved.goal then
    local goal = ns.Geo.Node(saved.goal.mapID, saved.goal.x, saved.goal.y, saved.goal.label)
    local route = goal and ns.Router.Plan(here, goal, ns.Network.Build())
    if route then
      if goal then goal.npc = saved.goal.npc end
      Nav.active = { title = saved.title, goal = goal, route = ns.Router.WithZoneSteps(route), index = 1,
        stats = saved.stats or newStats() }
      ns.print("resuming directions to " .. saved.title .. " (/wf stop to end them)")
      return showStep()
    end
  end
  ns.charDB.nav = nil
end

-- XP earned on a trip, across level-ups.
ns.On("PLAYER_XP_UPDATE", function()
  local xp, max = UnitXP("player"), UnitXPMax("player")
  local a = Nav.active
  if a and a.stats and lastXP then
    local gained = xp >= lastXP and xp - lastXP or (lastXPMax or lastXP) - lastXP + xp
    a.stats.xp = a.stats.xp + gained
  end
  lastXP, lastXPMax = xp, max
end)

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if isLogin or isReload then C_Timer.After(1, Nav.Resume) end
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
  C_Timer.After(1, function()
    if Nav.active then Nav.Tick() end
  end)
end)

-- Called by the HUD several times a second. Returns your node and the step.
-- Objective areas. A quest's objectives are places, not a point: every spawn
-- of what you still need (QuestieDB, Questie.ObjectiveGroups; a finished
-- objective's go when the quest log says so). Within AREA_RADIUS of any of
-- them you're in the area: the stop counts as reached, and the compass and
-- waypoints step aside. Past AREA_LEAVE you've left it, and the way points at
-- the nearest of them from where you are.
local AREA_RADIUS, AREA_LEAVE = 80, 120

local function openSpots(questID)
  local groups = ns.Questie.ObjectiveGroups(questID)
  if #groups == 0 then return nil end
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID) or {}
  local spots = {}
  for _, g in ipairs(groups) do
    local finished = false
    for _, o in ipairs(objectives) do
      if o.finished and g.name and type(o.text) == "string" and o.text:find(g.name, 1, true) then finished = true end
    end
    if not finished then
      for _, node in ipairs(g.nodes) do spots[#spots + 1] = node end
    end
  end
  return spots
end

-- inside (true / false, or nil when the stop has no area) and the nearest spot.
local function areaOf(stop, here)
  local action = stop and stop.action
  if not (action and action.kind == "complete") then return nil end
  local spots = openSpots(action.questID)
  if not (spots and #spots > 0) then return nil end
  local best, bestDistance
  for _, node in ipairs(spots) do
    local d = ns.Geo.Distance(here, node)
    if d < (bestDistance or math.huge) then best, bestDistance = node, d end
  end
  if not best then return false end
  return bestDistance <= (stop.inArea and AREA_LEAVE or AREA_RADIUS), best
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

function Nav.Tick()
  local a = Nav.active
  if not a then return nil end
  local here = ns.Geo.PlayerNode()
  if not here then return nil, Nav.CurrentStep() end
  -- Yards travelled on a trip (not jumps: a hearthstone, a loading screen).
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
    local inside, spot = areaOf(pending, here)
    if inside ~= nil then
      if inside and not pending.inArea then
        pending.inArea = true
      elseif not inside and pending.inArea then
        -- Left the area: the nearest spot from here, for the way back.
        pending.inArea = nil
        if k == a.index and spot then
          step.to = ns.Geo.Node(spot.mapID, spot.x, spot.y, pending.node.label) or spot
          pending.node = step.to
          showStep()
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
