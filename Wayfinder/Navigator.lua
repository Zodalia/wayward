local _, ns = ...

-- Follows a planned route or journey: places the built-in map waypoint on the
-- current step's destination and moves on when you get there (or further
-- along). Journey stops with a quest action wait until the quest is accepted
-- or handed in (see Journey.lua).

local Nav = {}
ns.Nav = Nav

-- Yards from a step's destination that count as "reached".
local RADIUS = { walk = 20, fly = 120, transport = 150 }
local GOAL_RADIUS = 10

local function setWaypoint(node)
  local mapID, x, y = ns.Geo.ZonePoint(node)
  if not (mapID and x and y) then return end
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
    ns.charDB.nav = { title = a.title, journey = ns.Journey.Save(a.journey) }
  else
    local g = a.goal
    ns.charDB.nav = { title = a.title, goal = { mapID = g.mapID, x = g.x, y = g.y, label = g.label } }
  end
end

local function showStep()
  local step = Nav.CurrentStep()
  if step then setWaypoint(step.to) end
  save()
  ns.Fire("NAV_CHANGED")
end

local function flightTip()
  if next(ns.charDB.knownTaxi) == nil then
    ns.print("tip: talk to a flight master once and Wayfinder will route you via your flight paths.")
  end
end

function Nav.Start(title, goal, route)
  Nav.active = { title = title, goal = goal, route = route, index = 1 }
  ns.print("directions to " .. title .. ": " .. ns.FormatDuration(route.seconds))
  flightTip()
  showStep()
end

-- `journey` from ns.Journey.Plan. `quiet` skips the chat line and overview
-- (used when resuming after a login).
function Nav.StartJourney(journey, quiet)
  local last = journey.stops[#journey.stops]
  Nav.active = { title = journey.title, goal = last.node, journey = journey, index = 1,
    route = { steps = journey.steps, seconds = journey.seconds } }
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
end

function Nav.Stop()
  if Nav.ownsWaypoint then
    C_Map.ClearUserWaypoint()
    Nav.ownsWaypoint = false
  end
  Nav.active = nil
  save()
  ns.Fire("NAV_CHANGED")
end

local function arrive()
  ns.print("you have arrived: " .. Nav.active.title)
  Nav.Stop()
end

-- "Skip" also counts the current stop as done, so the journey moves on.
function Nav.Next()
  local a = Nav.active
  if not a then return end
  local stop = a.route.steps[a.index].stop
  if stop then stop.done = true end
  if a.index >= #a.route.steps then return arrive() end
  a.index = a.index + 1
  showStep()
end

function Nav.Prev()
  local a = Nav.active
  if a and a.index > 1 then
    a.index = a.index - 1
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
  a.route, a.index = route, 1
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

-- A journey stop's quest was accepted / handed in. At the current stop the
-- journey moves on; done ahead of time, the rest is re-planned without it.
local function questAction(kind, questID)
  local a = Nav.active
  if not (a and a.journey) then return end
  for i, step in ipairs(a.route.steps) do
    local stop = ns.Journey.PendingAction(step)
    if stop and stop.action.kind == kind and stop.action.questID == questID and i >= a.index then
      stop.done = true
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
      return
    end
  end
end

ns.On("QUEST_ACCEPTED", function(questID) questAction("pickup", questID) end)
ns.On("QUEST_TURNED_IN", function(questID) questAction("turnin", questID) end)

-- Objectives have no event of their own: check the journey's quests when the log changes.
ns.On("QUEST_LOG_UPDATE", function()
  local a = Nav.active
  if not (a and a.journey and C_QuestLog.IsComplete) then return end
  for _, step in ipairs(a.route.steps) do
    local stop = ns.Journey.PendingAction(step)
    if stop and stop.action.kind == "complete" and C_QuestLog.IsComplete(stop.action.questID) then
      questAction("complete", stop.action.questID)
      return
    end
  end
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

-- Picks up a saved trip after logging in, re-planned from where you are.
function Nav.Resume()
  local saved = ns.charDB.nav
  local here = ns.Geo.PlayerNode()
  if not (saved and here) or Nav.active then return end
  if saved.journey then
    local journey = ns.Journey.Resume(ns.Journey.Load(saved.journey), here)
    if journey then
      ns.print("resuming journey: " .. journey.title .. " (/wf stop to end it)")
      return Nav.StartJourney(journey, true)
    end
  elseif saved.goal then
    local goal = ns.Geo.Node(saved.goal.mapID, saved.goal.x, saved.goal.y, saved.goal.label)
    local route = goal and ns.Router.Plan(here, goal, ns.Network.Build())
    if route then
      Nav.active = { title = saved.title, goal = goal, route = route, index = 1 }
      ns.print("resuming directions to " .. saved.title .. " (/wf stop to end them)")
      return showStep()
    end
  end
  ns.charDB.nav = nil
end

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
  if isLogin or isReload then C_Timer.After(1, Nav.Resume) end
end)

-- True while standing at a journey stop that waits for a quest action.
function Nav.Waiting()
  return Nav.active ~= nil and Nav.active.waiting == true
end

-- Called by the HUD several times a second. Returns your node and the step.
function Nav.Tick()
  local a = Nav.active
  if not a then return nil end
  local here = ns.Geo.PlayerNode()
  if not here then return nil, Nav.CurrentStep() end
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
    if ns.Geo.Distance(here, step.to) <= radius then
      if ns.Journey.PendingAction(step) then
        a.waiting = true
        if a.index ~= k then
          a.index = k
          showStep()
        end
      elseif k == #steps then
        if step.stop then step.stop.done = true end
        arrive()
        return here, nil
      else
        if step.stop then step.stop.done = true end
        a.index = k + 1
        showStep()
      end
      break
    end
  end
  return here, steps[a.index]
end
