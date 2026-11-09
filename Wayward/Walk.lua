local _, ns = ...

-- Walking, zone by zone. A walk inside one zone is a straight line (the
-- router pads it for real paths). A walk between zones goes through the
-- links between them: gates, passes, bridges, tunnels (Data/ZoneLinks.lua,
-- and the crossings you've walked yourself, recorded here). So a walk never
-- goes over a mountain range or across the sea because the far side happens
-- to be close on the map.
--
--   Walk.Path(a, b, wantVias) -> yards, vias     nil when you can't walk it
--   Walk.Distance(a, b)       -> yards or nil
--
-- `vias`: the links on the way, in order: { { node, zone (the one you walk
-- into), label }, ... }; nil for a straight line.
--
-- A zone with no link at all is uncharted: walks into and out of it are a
-- straight line, as before. Two charted zones with no chain of links
-- between them can't be walked between (the router looks for a boat or a
-- flight instead).

local Walk = {}
ns.Walk = Walk

local CLOSE_YARDS = 100    -- this near, a walk is straight whatever the zones say (the zone lines are rough)
local REPLACE_YARDS = 600  -- a crossing you walked replaces the bundled point for those zones this near it
local SAME_YARDS = 150     -- a crossing this near one already recorded for those zones is the same one
local BORDER_YARDS = { 40, 80, 120 } -- how far round you the zone you left has to be for a crossing to count
local RETRY_SECONDS = 5    -- map data not ready (early in a login): the links are read again after this,
local RETRIES = 6          -- this many times (a map this client doesn't have never turns up)

local graph, graphKey, graphAt
local retries = 0
local version = 0

local function learned()
  return ns.db and ns.db.zoneLinks or {}
end

local function key()
  local bundled = ns.data.zoneLinks or {}
  return table.concat({ tostring(bundled), #bundled, tostring(learned()), #learned() }, "|")
end

-- Changes whenever the links do: the network's worked-out paths are kept by it.
local current

function Walk.Version()
  current()
  return version
end

function Walk.Reset()
  graph, graphKey = nil, nil
  version = version + 1
end

local function build()
  local links, missed = {}, false
  for _, l in ipairs(ns.data.zoneLinks or {}) do
    if not l.forever or ns.IsForever() then
      local x, y = ns.Data.EraToForever(l.mapID, l.x, l.y)
      local node = ns.Geo.Node(l.mapID, x, y, l.label)
      if node then
        links[#links + 1] = { zones = { l.a, l.b }, node = node, label = l.label }
      else
        missed = true
      end
    end
  end
  -- What you walked beats the bundled guess for the same two zones.
  for _, l in ipairs(learned()) do
    local node = ns.Geo.Node(l.mapID, l.x, l.y, l.label)
    if node then
      local nearest, nearestAt
      for i, other in ipairs(links) do
        local same = not other.learned and ((other.zones[1] == l.a and other.zones[2] == l.b)
          or (other.zones[1] == l.b and other.zones[2] == l.a))
        local d = same and ns.Geo.Distance(node, other.node)
        if d and d <= REPLACE_YARDS and (not nearestAt or d < nearestAt) then nearest, nearestAt = i, d end
      end
      local link = { zones = { l.a, l.b }, node = node, label = l.label, learned = true }
      if nearest then links[nearest] = link else links[#links + 1] = link end
    end
  end

  local byZone = {}
  for i, link in ipairs(links) do
    for _, zone in ipairs(link.zones) do
      byZone[zone] = byZone[zone] or {}
      table.insert(byZone[zone], i)
    end
  end
  -- Links that share a zone are a straight walk apart.
  local edges = {}
  for i, link in ipairs(links) do
    local row = {}
    for _, zone in ipairs(link.zones) do
      for _, j in ipairs(byZone[zone]) do
        if j ~= i and not row[j] then
          local d = ns.Geo.Distance(link.node, links[j].node)
          if d < math.huge then row[j] = d end
        end
      end
    end
    edges[i] = row
  end
  local rows = {}
  local function from(s)
    if rows[s] then return rows[s] end
    local dist, prev, done = {}, {}, {}
    for i = 1, #links do dist[i] = math.huge end
    dist[s] = 0
    for _ = 1, #links do
      local current, best = nil, math.huge
      for i = 1, #links do
        if not done[i] and dist[i] < best then current, best = i, dist[i] end
      end
      if not current then break end
      done[current] = true
      for j, d in pairs(edges[current]) do
        if not done[j] and best + d < dist[j] then dist[j], prev[j] = best + d, current end
      end
    end
    rows[s] = { dist = dist, prev = prev }
    return rows[s]
  end
  return { links = links, byZone = byZone, from = from, missed = missed }
end

function current()
  local k = key()
  local now = GetTime and GetTime() or 0
  local retry = graph and graph.missed and retries < RETRIES and now - graphAt >= RETRY_SECONDS
  if graph and graphKey == k and not retry then return graph end
  retries = retry and retries + 1 or retries
  graph, graphKey, graphAt = build(), k, now
  version = version + 1
  return graph
end

-- The zone a node is in, as far as walking goes: its own map when that's a
-- zone with links, else the zone the continent map has there.
local function zoneOf(node, g)
  if node.mapID and g.byZone[node.mapID] then return node.mapID end
  if not (node.instance and node.wx) then return nil end
  return ns.Geo.ZoneAt(node.instance, node.wx, node.wy)
end

function Walk.ZoneOf(node)
  return node and zoneOf(node, current()) or nil
end

-- Whether a zone has links (see the top of the file).
function Walk.Charted(mapID)
  return current().byZone[mapID] ~= nil
end

function Walk.Path(a, b, wantVias)
  local straight = ns.Geo.Distance(a, b)
  if straight == math.huge then return nil end
  if straight <= CLOSE_YARDS then return straight end
  local g = current()
  local za, zb = zoneOf(a, g), zoneOf(b, g)
  if not za or not zb or za == zb then return straight end
  local la, lb = g.byZone[za], g.byZone[zb]
  if not la or not lb then return straight end
  local best, first, last = math.huge, nil, nil
  for _, i in ipairs(la) do
    local out = ns.Geo.Distance(a, g.links[i].node)
    if out < best then
      local dist = g.from(i).dist
      for _, j in ipairs(lb) do
        local total = out + dist[j] + ns.Geo.Distance(g.links[j].node, b)
        if total < best then best, first, last = total, i, j end
      end
    end
  end
  if not first then return nil end
  if not wantVias then return best end
  local order, prev, j = {}, g.from(first).prev, last
  while j do
    table.insert(order, 1, g.links[j])
    j = prev[j]
  end
  local vias, zone = {}, za
  for i, link in ipairs(order) do
    local other = link.zones[1] == zone and link.zones[2] or link.zones[1]
    local nextLink = order[i + 1]
    -- A link only touched, not gone through (the next one leaves the same zone).
    local touched = nextLink and (nextLink.zones[1] == zone or nextLink.zones[2] == zone)
      and nextLink.zones[1] ~= other and nextLink.zones[2] ~= other
    if not touched then
      vias[#vias + 1] = { node = link.node, zone = other, label = link.label }
      zone = other
    end
  end
  return best, vias
end

function Walk.Distance(a, b)
  return (Walk.Path(a, b))
end

---------------------------------------------------------------- crossings you walk

local function round(v)
  return math.floor(v * 1000 + 0.5) / 1000
end

-- Records where you walked from `from` into `to` (map IDs), at `node`.
-- Returns the record, or nil when one is already known there.
function Walk.Learn(from, to, node, label)
  if not (ns.db and from and to and from ~= to and node) then return nil end
  ns.db.zoneLinks = ns.db.zoneLinks or {}
  for _, l in ipairs(ns.db.zoneLinks) do
    if (l.a == from and l.b == to) or (l.a == to and l.b == from) then
      local known = ns.Geo.Node(l.mapID, l.x, l.y)
      if known and ns.Geo.Distance(known, node) <= SAME_YARDS then return nil end
    end
  end
  local record = { a = from, b = to, mapID = node.mapID, x = round(node.x), y = round(node.y), label = label }
  table.insert(ns.db.zoneLinks, record)
  Walk.Reset()
  return record
end

-- The zone you just left, when it lies within a few steps of where you are.
local function zoneBehind(here, now, was)
  for _, yards in ipairs(BORDER_YARDS) do
    for k = 0, 7 do
      local angle = k * math.pi / 4
      local zone = ns.Geo.ZoneAt(here.instance, here.wx + yards * math.cos(angle), here.wy + yards * math.sin(angle))
      if zone == was and zone ~= now then return true end
    end
  end
  return false
end

local lastZone

local function placed()
  local here = ns.Geo.PlayerNodeExact()
  if not here then return nil end
  return here, ns.Geo.ZoneAt(here.instance, here.wx, here.wy)
end

-- A new zone on foot, with the one you were in right behind you: that's a
-- crossing. Not from the air, not as a ghost, and not after a loading
-- screen, a hearthstone or a spirit healer (none of those leave the old
-- zone a few steps away, and a loading screen forgets it).
local function zoneChanged()
  local here, zone = placed()
  local was = lastZone
  lastZone = zone or lastZone
  if not (here and zone and was and zone ~= was) then return end
  if ns.OnTaxi() or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then return end
  if not zoneBehind(here, zone, was) then return end
  local subZone = GetSubZoneText and GetSubZoneText() or ""
  Walk.Learn(was, zone, here, subZone ~= "" and subZone or nil)
end

ns.On("ZONE_CHANGED_NEW_AREA", zoneChanged)
ns.On("ZONE_CHANGED", function()
  if lastZone == nil then
    local _, zone = placed()
    lastZone = zone
  end
end)
ns.On("PLAYER_ENTERING_WORLD", function()
  local _, zone = placed()
  lastZone = zone
end)

---------------------------------------------------------------- /ww crossings

function Walk.LuaLine(l)
  return string.format('{ a = %d, b = %d, mapID = %d, x = %.3f, y = %.3f, label = "%s" },', l.a, l.b, l.mapID, l.x, l.y,
    ((l.label or (ns.MapName(l.a) .. " - " .. ns.MapName(l.b))):gsub('"', '\\"')))
end

function Walk.Command(arg)
  local word = (arg or ""):match("^(%S*)")
  if word == "clear" then
    ns.db.zoneLinks = {}
    Walk.Reset()
    ns.print("recorded crossings cleared.")
    return
  end
  local recorded = learned()
  if #recorded == 0 then
    ns.print("no crossings recorded yet. Walk from one zone into the next and Wayward remembers where.")
    return
  end
  local lines = { "-- Crossings you walked. Paste into Wayward/Data/ZoneLinks.lua." }
  for _, l in ipairs(recorded) do
    lines[#lines + 1] = string.format("-- %s - %s", ns.MapName(l.a), ns.MapName(l.b))
    lines[#lines + 1] = Walk.LuaLine(l)
  end
  ns.ShowCopyBox("Recorded crossings", table.concat(lines, "\n"))
end

ns.RegisterCommand("crossings", "/ww crossings - copy the zone crossings you've walked (clear: forget them)", Walk.Command)
