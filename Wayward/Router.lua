local _, ns = ...

-- Plans the fastest trip from A to B over a travel network (see Network.lua):
-- walking (zone to zone through the links between them, see Walk.lua), flying
-- between known flight paths (or from one you walk up to and learn), and
-- boats/zeppelins/tram/portals. Pure logic
-- over route nodes, no game API.

local Router = {}
ns.Router = Router

Router.RUN_SPEED = 7       -- yards per second on foot
Router.WALK_FACTOR = 1.3   -- real paths vs a straight line (inside a zone, and between its links)
Router.FLY_SPEED = 25      -- effective yards per second along a flight path
Router.FLY_OVERHEAD = 20   -- seconds: talk to the flight master, take off, land

-- Nil when you can't walk from a to b: another continent, or zones with no
-- way between them on foot (Walk.lua).
local function walkCost(a, b)
  local d = ns.Walk.Distance(a, b)
  if not d then return nil end
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
-- A network that's another one with flight paths learned on the way
-- (Router.Learned) shares its nodes, in the same order, and its walks.
local function prepare(net)
  if net.paths then return net.paths end
  local base = net.base or net
  local nodes, links = {}, {}
  for _, n in ipairs(net.flights) do nodes[#nodes + 1] = n end
  for _, n in ipairs(net.learnable or {}) do
    -- Learned earlier on the journey: a flight path like the ones you know.
    if net.learned and net.learned[n.nodeID] then
      base.copies = base.copies or {}
      local copy = base.copies[n]
      if not copy then
        copy = {}
        for k, v in pairs(n) do copy[k] = v end
        copy.learn = nil
        base.copies[n] = copy
      end
      n = copy
    end
    nodes[#nodes + 1] = n
  end
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
  -- Best direct edge between two network nodes: walking, or flying between
  -- flight paths (from one you'd learn on the way, never to one).
  local edge = {}
  local walks = base.walks or {}
  base.walks = walks
  for i = 1, count do
    local row, a = {}, nodes[i]
    local walked = walks[i] or {}
    walks[i] = walked
    for j = 1, count do
      if i ~= j then
        if walked[j] == nil then walked[j] = walkCost(a, nodes[j]) or false end
        local cost, mode = walked[j] or nil, "walk"
        if a.isFlight and nodes[j].isFlight and not nodes[j].learn then
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

-- The flight paths `route` learns on the way (flies on from one you don't
-- have yet): their taxi nodeIDs.
function Router.LearnedOn(route)
  local out = {}
  for _, step in ipairs(route and route.steps or {}) do
    if step.mode == "fly" and step.from.learn and step.from.nodeID then out[#out + 1] = step.from.nodeID end
  end
  return out
end

-- `net` with flight path `nodeID` learned too, for the rest of a journey
-- after the leg that learns it: you can fly there as well as from there.
-- Kept on the network it's made from (so re-plans don't work its paths out
-- again), and gone with it when that's rebuilt.
function Router.Learned(net, nodeID)
  if not nodeID or (net.learned and net.learned[nodeID]) then return net end
  local base = net.base or net
  local learned, ids = { [nodeID] = true }, { nodeID }
  for id in pairs(net.learned or {}) do
    learned[id] = true
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local key = table.concat(ids, ",")
  base.variants = base.variants or {}
  local v = base.variants[key]
  if not v then
    v = { flights = base.flights, learnable = base.learnable, transports = base.transports,
      knownFlights = base.knownFlights, base = base, learned = learned }
    base.variants[key] = v
  end
  return v
end

-- Returns { steps = { {mode, from, to, seconds, kind} ... }, seconds } or nil.
function Router.Plan(start, goal, net)
  ns.WarmStep()
  local paths = prepare(net)
  local nodes = paths.nodes
  local best = walkCost(start, goal) or math.huge
  local bestEntry, bestExit

  local exits = {}
  for j, node in ipairs(nodes) do
    local toGoal = node.instance == goal.instance and walkCost(node, goal)
    if toGoal then exits[#exits + 1] = { j, toGoal } end
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

-- Walking into another zone becomes its own step: to the link you go
-- through ("Walk to Loch Modan through South Gate Pass", Walk.lua), or,
-- where the zones have no links, found by sampling the straight line ("Walk
-- to Elwynn Forest"). Used for the route you follow and for previews, not
-- while comparing routes (that would be wasted work).
local ZONE_SAMPLE_YARDS = 40
local MAX_ZONE_SAMPLES = 60
local MIN_LEG_YARDS = 30

-- A walk through links, as one step per link and the rest of the way. Nil
-- for a straight walk.
local function linkSteps(step)
  local yards, vias = ns.Walk.Path(step.from, step.to, true)
  if not (yards and vias and #vias > 0) then return nil end
  local out, from = {}, step.from
  local function share(a, b)
    return yards > 0 and step.seconds * ns.Geo.Distance(a, b) / yards or 0
  end
  for _, via in ipairs(vias) do
    local n = via.node
    local node = { label = ns.MapName(via.zone), pass = via.label, mapID = n.mapID, x = n.x, y = n.y,
      instance = n.instance, wx = n.wx, wy = n.wy }
    out[#out + 1] = { mode = "walk", from = from, to = node, zoneEntry = via.zone, link = true, seconds = share(from, node) }
    from = node
  end
  local last = {}
  for k, v in pairs(step) do last[k] = v end
  last.from, last.seconds = from, share(from, step.to)
  out[#out + 1] = last
  return out
end

local function zoneSteps(step)
  local linked = linkSteps(step)
  if linked then return linked end
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

-- Where the arrow points for a step: its own end, except a walk through an
-- area to gather in on the way (Journey: gathering as you go) that the next
-- stop doesn't need: that's passed through, not headed for, so the arrow
-- points on to the next stop (or the flight master or boat on the way
-- there), past any zone borders found by sampling, but never past a link
-- (a pass or a gate is the way: the arrow points at it, not through the
-- mountain). A needed area (step.via.needed) is the
-- point of the walk: heading for a hand-in that can't be done yet would
-- only send you back out. Returns the node and its step's index.
function Router.Aim(route, index)
  local step = route.steps[index]
  if not (step and step.via and not step.via.needed) then return step and step.to, index end
  local k = index
  while route.steps[k + 1] and route.steps[k + 1].mode == "walk" do
    k = k + 1
    local nextStep = route.steps[k + 1]
    if route.steps[k].link or route.steps[k].stop or not nextStep or nextStep.mode ~= "walk" then break end
  end
  return route.steps[k].to, k
end

-- Player-facing text for a step; walking is described by where it leads.
-- `travelOnly` describes the travel even when the step ends at a journey stop.
function Router.Describe(route, index, travelOnly)
  local step, nextStep = route.steps[index], route.steps[index + 1]
  -- Passing through an area on the way: said with where the arrow points
  -- ("Hand in Rare Books to Brother Paxton, through Goldshire (An Enticing Offer)").
  if step.via and not step.via.needed then
    local _, aim = Router.Aim(route, index)
    if aim ~= index then
      local place = ns.Places and ns.Places.NameFor(step.to)
      local through = place and place ~= step.to.label and string.format("through %s (%s)", place, step.to.label)
        or "through the area for " .. step.to.label
      return Router.Describe(route, aim, travelOnly) .. ", " .. through
    end
  end
  -- A journey stop says what to do there ("Pick up ... from ...").
  if step.stop and step.stop.text and not travelOnly then
    return ns.Journey and ns.Journey.StopText(step.stop) or step.stop.text
  end
  if step.mode == "fly" then return "Fly to " .. step.to.label end
  if step.mode == "hearth" then return "Hearth to " .. step.to.label end
  if step.mode == "transport" then
    return string.format(TRANSPORT_VERB[step.kind] or "Travel to %s", step.to.label)
  end
  if nextStep and nextStep.mode == "fly" then
    if step.to.learn then
      return string.format("Learn the flight path at %s%s", step.to.label,
        step.to.npc and (" from " .. step.to.npc) or "")
    end
    if step.to.npc then return string.format("Talk to %s, the flight master at %s", step.to.npc, step.to.label) end
    return "Talk to the flight master at " .. step.to.label
  end
  if nextStep and nextStep.mode == "transport" then
    return string.format("Go to %s (%s to %s)", step.to.label, nextStep.kind, nextStep.to.label)
  end
  -- The destination is someone to talk to (a trainer, a vendor).
  if not nextStep and step.to.npc then return "Talk to " .. step.to.npc end
  -- Through an area to gather in on the way (Journey: gathering as you go).
  if step.via then
    local place = ns.Places and ns.Places.NameFor(step.to)
    if place and place ~= step.to.label then return string.format("Through %s (%s)", place, step.to.label) end
    return "Through the area for " .. step.to.label
  end
  -- An objective area is labelled with its quest: walk to the place there
  -- ("Walk to Shimmer Ridge"), else to "the area for The Perfect Stout".
  local stop = step.stop
  if stop and stop.action and stop.action.kind == "complete" and stop.node == step.to then
    local place = ns.Places and ns.Places.NameFor(step.to)
    if place and place ~= step.to.label then return "Walk to " .. place end
    return "Walk to the area for " .. step.to.label
  end
  if step.zoneEntry and step.to.pass then return string.format("Walk to %s through %s", step.to.label, step.to.pass) end
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
    elseif step.mode == "hearth" then
      parts[#parts + 1] = "hearth to " .. step.to.label
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "on foot"
end
