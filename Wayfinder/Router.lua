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

-- Returns { steps = { {mode, from, to, seconds, kind} ... }, seconds } or nil.
function Router.Plan(start, goal, net)
  local nodes = { start, goal }
  for _, n in ipairs(net.flights) do nodes[#nodes + 1] = n end

  local links = {} -- [node index] = { {to = index, transport = t} }
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
  local dist, prev, done = {}, {}, {}
  for i = 1, count do dist[i] = math.huge end
  dist[1] = 0

  local function relax(from, to, cost, step)
    if cost and dist[from] + cost < dist[to] then
      dist[to] = dist[from] + cost
      prev[to] = { from = from, mode = step.mode, kind = step.kind, seconds = cost }
    end
  end

  -- Dijkstra over a small dense graph (tens of nodes), so O(n^2) is fine.
  for _ = 1, count do
    local current, best = nil, math.huge
    for i = 1, count do
      if not done[i] and dist[i] < best then current, best = i, dist[i] end
    end
    if not current or current == 2 then break end
    done[current] = true
    local node = nodes[current]
    for j = 1, count do
      if j ~= current and not done[j] then
        relax(current, j, walkCost(node, nodes[j]), { mode = "walk" })
        if node.isFlight and nodes[j].isFlight then
          relax(current, j, flyCost(node, nodes[j]), { mode = "fly" })
        end
      end
    end
    for _, link in ipairs(links[current] or {}) do
      relax(current, link.to, link.transport.time, { mode = "transport", kind = link.transport.kind })
    end
  end

  if dist[2] == math.huge then return nil end

  local steps, i = {}, 2
  while prev[i] do
    local p = prev[i]
    table.insert(steps, 1, { mode = p.mode, kind = p.kind, from = nodes[p.from], to = nodes[i], seconds = p.seconds })
    i = p.from
  end
  return { steps = steps, seconds = dist[2] }
end

local TRANSPORT_VERB = {
  boat = "Take the boat to %s", zeppelin = "Take the zeppelin to %s",
  tram = "Ride the Deeprun Tram to %s", portal = "Take the portal to %s",
}

-- Player-facing text for a step; walking is described by where it leads.
function Router.Describe(route, index)
  local step, nextStep = route.steps[index], route.steps[index + 1]
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
