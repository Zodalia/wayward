local _, ns = ...

-- Journeys: trips with several stops, e.g. "pick up three quests, then go to
-- the Deadmines". Stops are visited in the quickest order found (nearest
-- next stop, then pairwise swaps), with an optional fixed final stop.
--
-- A journey definition:
--   {
--     title = "Deadmines run",
--     stops = { stop, ... },   -- visited in any order
--     finish = stop,           -- optional, always last (e.g. a dungeon entrance)
--   }
-- A stop:
--   {
--     node = route node (ns.Geo.Node),
--     text = "Pick up Red Silk Bandanas from Scout Riell",  -- shown on arrival
--     action = { kind = "pickup" | "turnin", questID = 123 },  -- optional
--   }
-- A stop with an action waits there until the quest is accepted / handed in;
-- one without an action is done on arrival.

local Journey = {}
ns.Journey = Journey

local MAX_SWAP_PASSES = 6

-- Travel seconds between points, planned once per pair.
local function costTable(points, net)
  local cache = {}
  return function(i, j)
    local key = i .. ":" .. j
    if cache[key] == nil then
      local route = ns.Router.Plan(points[i], points[j], net)
      cache[key] = route and route.seconds or math.huge
    end
    return cache[key]
  end
end

local function orderStops(start, stops, net)
  local points = { start }
  for _, stop in ipairs(stops) do points[#points + 1] = stop.node end
  local cost = costTable(points, net)

  -- Nearest next stop.
  local order, used, current = {}, {}, 1
  for _ = 1, #stops do
    local best, bestCost
    for i = 2, #points do
      if not used[i] and (not bestCost or cost(current, i) < bestCost) then best, bestCost = i, cost(current, i) end
    end
    used[best] = true
    order[#order + 1] = best
    current = best
  end

  -- Reverse segments while that shortens the trip (2-opt).
  local function total(o)
    local sum, prev = 0, 1
    for _, i in ipairs(o) do sum, prev = sum + cost(prev, i), i end
    return sum
  end
  local best = total(order)
  for _ = 1, MAX_SWAP_PASSES do
    local improved = false
    for a = 1, #order - 1 do
      for b = a + 1, #order do
        local candidate = {}
        for k = 1, a - 1 do candidate[k] = order[k] end
        for k = a, b do candidate[k] = order[b - (k - a)] end
        for k = b + 1, #order do candidate[k] = order[k] end
        local t = total(candidate)
        if t < best then order, best, improved = candidate, t, true end
      end
    end
    if not improved then break end
  end

  local ordered = {}
  for _, i in ipairs(order) do ordered[#ordered + 1] = stops[i - 1] end
  return ordered
end

-- Plans a journey from `start`. Returns
--   { title, def, stops = ordered stops, skipped = unreachable stops,
--     steps = route steps (the last step of each leg carries .stop), seconds }
-- or nil when no stop is reachable.
function Journey.Plan(start, def, net)
  net = net or ns.Network.Build()
  local ordered = orderStops(start, def.stops or {}, net)
  if def.finish then ordered[#ordered + 1] = def.finish end

  local journey = { title = def.title, def = def, stops = {}, skipped = {}, steps = {}, seconds = 0 }
  local from = start
  for _, stop in ipairs(ordered) do
    local route = ns.Router.Plan(from, stop.node, net)
    if route then
      local steps = route.steps
      if #steps == 0 then
        -- Already standing at the stop: keep a step so its action still shows.
        steps = { { mode = "walk", from = from, to = stop.node, seconds = 0 } }
      end
      for i, step in ipairs(steps) do
        if i == #steps then step.stop = stop end
        journey.steps[#journey.steps + 1] = step
      end
      journey.seconds = journey.seconds + route.seconds
      journey.stops[#journey.stops + 1] = stop
      from = stop.node
    else
      journey.skipped[#journey.skipped + 1] = stop
    end
  end
  if #journey.stops == 0 then return nil end
  return journey
end

-- The same journey from here, without the stops already done.
function Journey.Replan(journey, start, net)
  local def = journey.def
  local remaining = {}
  for _, stop in ipairs(def.stops or {}) do
    if not stop.done then remaining[#remaining + 1] = stop end
  end
  local finish = def.finish and not def.finish.done and def.finish or nil
  return Journey.Plan(start, { title = def.title, stops = remaining, finish = finish }, net)
end

-- Stop that a step arrives at, if it still waits for a quest action.
function Journey.PendingAction(step)
  local stop = step and step.stop
  return stop and stop.action and stop.action.questID and not stop.done and stop or nil
end

function Journey.StopsDone(journey)
  local done = 0
  for _, stop in ipairs(journey.stops) do
    if stop.done then done = done + 1 end
  end
  return done
end
