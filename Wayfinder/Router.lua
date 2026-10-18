local _, ns = ...

-- Plans the fastest trip from A to B over a travel network (see Network.lua):
-- walking anywhere on the same continent, flying between known flight paths,
-- and boats/zeppelins/tram/portals. Pure logic over route nodes, no game API.

local Router = {}
ns.Router = Router

Router.RUN_SPEED = 7       -- yards per second on foot
Router.WALK_FACTOR = 1.3   -- real paths vs a straight line
Router.FLY_SPEED = 25      -- effective yards per second along a flight path
Router.FLY_OVERHEAD = 20   -- seconds: talk to the flight master, take off, land

local function walkCost(a, b)
  local d = ns.Geo.Distance(a, b)
  if d == math.huge then return nil end
  return d * Router.WALK_FACTOR / Router.RUN_SPEED
end

local function flyCost(a, b)
  local d = ns.Geo.Distance(a, b)
  if d == math.huge then return nil end
  return Router.FLY_OVERHEAD + d / Router.FLY_SPEED
end

-- Seconds left on a step from where you are now. Walking is re-measured; a
-- flight is re-measured once airborne; boats and the like keep their estimate.
function Router.SecondsLeft(step, here, onTaxi)
  if step.mode == "walk" then
    return walkCost(here, step.to) or step.seconds
  end
  if step.mode == "fly" and onTaxi then
    local d = ns.Geo.Distance(here, step.to)
    if d < math.huge then return d / Router.FLY_SPEED end
  end
  return step.seconds
end

-- The network's own nodes (flight paths you know, transport ends) and the
-- quickest trips between them, worked out once per network and kept on it:
-- direct edges (walk, fly, transport) up front, then Dijkstra from a node the
-- first time a route starts there. A route is then: walk to a network node,
-- the best trip through the network, walk to the goal (or just walk).
local function prepare(net)
  if net.paths then return net.paths end
  local nodes, links = {}, {}
  for _, n in ipairs(net.flights) do nodes[#nodes + 1] = n end
  for _, t in ipairs(net.transports) do
    nodes[#nodes + 1] = t.a
    local ia = #nodes
    nodes[#nodes + 1] = t.b
    local ib = #nodes
    links[ia] = links[ia] or {}
    links[ib] = links[ib] or {}
    table.insert(links[ia], { to = ib, transport = t })
    table.insert(links[ib], { to = ia, transport = t })
  end
  local count = #nodes
  -- Best direct edge between two network nodes: walking, or flying between flight paths.
  local edge = {}
  for i = 1, count do
    local row, a = {}, nodes[i]
    for j = 1, count do
      if i ~= j then
        local cost, mode = walkCost(a, nodes[j]), "walk"
        if a.isFlight and nodes[j].isFlight then
          local fly = flyCost(a, nodes[j])
          if fly and (not cost or fly < cost) then cost, mode = fly, "fly" end
        end
        if cost then row[j] = { cost = cost, mode = mode } end
      end
    end
    edge[i] = row
  end

  local rows = {}
  local function from(s)
    if rows[s] then return rows[s] end
    local dist, prev, done = {}, {}, {}
    for i = 1, count do dist[i] = math.huge end
    dist[s] = 0
    for _ = 1, count do
      local current, best = nil, math.huge
      for i = 1, count do
        if not done[i] and dist[i] < best then current, best = i, dist[i] end
      end
      if not current then break end
      done[current] = true
      for j, e in pairs(edge[current]) do
        if not done[j] and best + e.cost < dist[j] then
          dist[j] = best + e.cost
          prev[j] = { from = current, mode = e.mode, seconds = e.cost }
        end
      end
      for _, link in ipairs(links[current] or {}) do
        local j, t = link.to, link.transport
        if not done[j] and best + t.time < dist[j] then
          dist[j] = best + t.time
          prev[j] = { from = current, mode = "transport", kind = t.kind, seconds = t.time }
        end
      end
    end
    rows[s] = { dist = dist, prev = prev }
    return rows[s]
  end

  net.paths = { nodes = nodes, from = from }
  return net.paths
end

-- Returns { steps = { {mode, from, to, seconds, kind} ... }, seconds } or nil.
function Router.Plan(start, goal, net)
  local paths = prepare(net)
  local nodes = paths.nodes
  local best = walkCost(start, goal) or math.huge
  local bestEntry, bestExit

  local exits = {}
  for j, node in ipairs(nodes) do
    if node.instance == goal.instance then exits[#exits + 1] = { j, walkCost(node, goal) } end
  end
  if #exits > 0 then
    for i, node in ipairs(nodes) do
      local toEntry = node.instance == start.instance and walkCost(start, node)
      if toEntry and toEntry < best then
        local dist = paths.from(i).dist
        for _, exit in ipairs(exits) do
          local total = toEntry + dist[exit[1]] + exit[2]
          if total < best then best, bestEntry, bestExit = total, i, exit[1] end
        end
      end
    end
  end
  if best == math.huge then return nil end
  if not bestEntry then
    return { steps = { { mode = "walk", from = start, to = goal, seconds = best } }, seconds = best }
  end

  local steps = { { mode = "walk", from = start, to = nodes[bestEntry], seconds = walkCost(start, nodes[bestEntry]) } }
  local middle, prev, j = {}, paths.from(bestEntry).prev, bestExit
  while prev[j] do
    local p = prev[j]
    table.insert(middle, 1, { mode = p.mode, kind = p.kind, from = nodes[p.from], to = nodes[j], seconds = p.seconds })
    j = p.from
  end
  for _, step in ipairs(middle) do steps[#steps + 1] = step end
  steps[#steps + 1] = { mode = "walk", from = nodes[bestExit], to = goal, seconds = walkCost(nodes[bestExit], goal) }
  -- Walking in place (already at the flight master or the dock) isn't a step.
  local out = {}
  for _, step in ipairs(steps) do
    if not (step.mode == "walk" and (step.seconds or 0) <= 0) then out[#out + 1] = step end
  end
  return { steps = out, seconds = best }
end

-- Walking into another zone becomes its own step ("Walk to Elwynn Forest"),
-- found by sampling the straight line. Used for the route you follow and for
-- previews, not while comparing routes (that would be wasted work).
local ZONE_SAMPLE_YARDS = 40
local MAX_ZONE_SAMPLES = 60
local MIN_LEG_YARDS = 30

local function zoneSteps(step)
  local a, b = step.from, step.to
  local distance = ns.Geo.Distance(a, b)
  if distance == math.huge or distance < 2 * MIN_LEG_YARDS then return { step } end
  local samples = math.min(MAX_ZONE_SAMPLES, math.ceil(distance / ZONE_SAMPLE_YARDS))
  local current = ns.Geo.ZoneAt(a.instance, a.wx, a.wy) or a.mapID
  local finalZone = ns.Geo.ZoneAt(b.instance, b.wx, b.wy)
  local out, from, done = {}, a, 0
  for i = 1, samples - 1 do
    local t = i / samples
    local wx, wy = a.wx + (b.wx - a.wx) * t, a.wy + (b.wy - a.wy) * t
    local zone = ns.Geo.ZoneAt(a.instance, wx, wy)
    if zone and zone ~= current then
      current = zone
      -- Skip a zone entry right before the destination; it adds nothing.
      if zone ~= finalZone or (1 - t) * distance > MIN_LEG_YARDS then
        local mapID, x, y = ns.Geo.ZonePoint({ instance = a.instance, wx = wx, wy = wy })
        local node = { label = ns.MapName(zone), mapID = mapID, x = x, y = y, instance = a.instance, wx = wx, wy = wy }
        out[#out + 1] = { mode = "walk", from = from, to = node, zoneEntry = zone, seconds = step.seconds * (t - done) }
        from, done = node, t
      end
    end
  end
  if #out == 0 then return { step } end
  local last = {}
  for k, v in pairs(step) do last[k] = v end
  last.from, last.seconds = from, step.seconds * (1 - done)
  out[#out + 1] = last
  return out
end

-- The same route with zone-entry steps added to its walks.
function Router.WithZoneSteps(route)
  if not route or route.zoned then return route end
  local steps = {}
  for _, step in ipairs(route.steps) do
    if step.mode == "walk" then
      for _, s in ipairs(zoneSteps(step)) do steps[#steps + 1] = s end
    else
      steps[#steps + 1] = step
    end
  end
  return { steps = steps, seconds = route.seconds, zoned = true }
end

local TRANSPORT_VERB = {
  boat = "Take the boat to %s", zeppelin = "Take the zeppelin to %s",
  tram = "Ride the Deeprun Tram to %s", portal = "Take the portal to %s",
}

-- Player-facing text for a step; walking is described by where it leads.
function Router.Describe(route, index)
  local step, nextStep = route.steps[index], route.steps[index + 1]
  -- A journey stop says what to do there ("Pick up ... from ...").
  if step.stop and step.stop.text then return step.stop.text end
  if step.mode == "fly" then return "Fly to " .. step.to.label end
  if step.mode == "transport" then
    return string.format(TRANSPORT_VERB[step.kind] or "Travel to %s", step.to.label)
  end
  if nextStep and nextStep.mode == "fly" then
    return "Go to the flight master at " .. step.to.label
  end
  if nextStep and nextStep.mode == "transport" then
    return string.format("Go to %s (%s to %s)", step.to.label, nextStep.kind, nextStep.to.label)
  end
  return "Walk to " .. step.to.label
end

-- One-line summary for a result row, e.g. "fly Lakeshire -> Stormwind".
function Router.Summary(route)
  local parts = {}
  for _, step in ipairs(route.steps) do
    if step.mode == "fly" then
      parts[#parts + 1] = "fly to " .. (step.to.label:match("^([^,]+)") or step.to.label)
    elseif step.mode == "transport" then
      parts[#parts + 1] = step.kind .. " to " .. step.to.label
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "on foot"
end
