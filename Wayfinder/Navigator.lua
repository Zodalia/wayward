local _, ns = ...

-- Follows a planned route: places the built-in map waypoint on the current
-- step's destination and moves on when you get there (or further along).

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

local function showStep()
  local step = Nav.CurrentStep()
  if step then setWaypoint(step.to) end
  ns.Fire("NAV_CHANGED")
end

function Nav.Start(title, goal, route)
  Nav.active = { title = title, goal = goal, route = route, index = 1 }
  ns.print("directions to " .. title .. ": " .. ns.FormatDuration(route.seconds))
  if next(ns.charDB.knownTaxi) == nil then
    ns.print("tip: talk to a flight master once and Wayfinder will route you via your flight paths.")
  end
  showStep()
end

function Nav.Stop()
  if Nav.ownsWaypoint then
    C_Map.ClearUserWaypoint()
    Nav.ownsWaypoint = false
  end
  Nav.active = nil
  ns.Fire("NAV_CHANGED")
end

function Nav.Next()
  local a = Nav.active
  if not a then return end
  if a.index >= #a.route.steps then
    ns.print("you have arrived: " .. a.title)
    Nav.Stop()
    return
  end
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

-- Re-plan from where you are now (after a hearthstone, a detour, ...).
function Nav.Recalculate()
  local a = Nav.active
  local start = ns.Geo.PlayerNode()
  if not (a and start) then return end
  local route = ns.Router.Plan(start, a.goal, ns.Network.Build())
  if not route then
    ns.print("no route from here.")
    return
  end
  a.route, a.index = route, 1
  showStep()
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
  local route = here and ns.Router.Plan(here, a.goal, ns.Network.Build())
  local current = Nav.RemainingSeconds(here)
  if route and current and route.seconds < current - 15 then
    a.route, a.index = route, 1
    ns.print("faster route with your flight paths: " .. ns.FormatDuration(route.seconds))
    showStep()
  end
end)

-- Called by the HUD several times a second. Returns your node and the step.
function Nav.Tick()
  local a = Nav.active
  if not a then return nil end
  local here = ns.Geo.PlayerNode()
  if not here then return nil, Nav.CurrentStep() end
  local steps = a.route.steps
  -- Jump to the step after the furthest destination you have already reached.
  for k = #steps, a.index, -1 do
    local radius = k == #steps and GOAL_RADIUS or RADIUS[steps[k].mode]
    if ns.Geo.Distance(here, steps[k].to) <= radius then
      if k == #steps then
        ns.print("you have arrived: " .. a.title)
        Nav.Stop()
        return here, nil
      end
      a.index = k + 1
      showStep()
      break
    end
  end
  return here, steps[a.index]
end
