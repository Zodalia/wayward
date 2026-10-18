local _, ns = ...

-- Suggestions along your trip (shown in the trip overview): quests you can
-- pick up, quests in your log ready to hand in, and vendors you need, that
-- are near the way and add little to it: SLACK seconds of travel or less
-- (the same as follow-up quests). Each comes with the stops to add.

local OnTheWay = {}
ns.OnTheWay = OnTheWay

local SLACK = 180       -- seconds of travel a suggestion may add
local NEAR = 600        -- yards from the route (straight line) to be worth planning
local CANDIDATES = 8    -- nearest candidates that get a full route
local MAX = 4           -- suggestions shown
local KEEP = 20         -- seconds a set of suggestions is reused

local cache

-- The trip's points: where you are, then its open stops in order (or the
-- destination), and every place its route passes (for "near the way").
local function routePoints(a, here)
  local stops, near = { here }, { here }
  if a.journey then
    for _, stop in ipairs(a.journey.stops) do
      if not stop.done and not stop.skipped and stop.node then stops[#stops + 1] = stop.node end
    end
  elseif a.goal then
    stops[#stops + 1] = a.goal
  end
  for k = a.index, #a.route.steps do near[#near + 1] = a.route.steps[k].to end
  for _, n in ipairs(stops) do near[#near + 1] = n end
  return stops, near
end

local function inTrip(a)
  local ids = {}
  local root = a.journey and (a.journey.root or a.journey.def)
  for _, stop in ipairs(root and root.stops or {}) do
    if stop.action and stop.action.questID then ids[stop.action.questID] = true end
  end
  return ids
end

-- What could be added: { {kind, label, node, stops}, ... }.
local function candidates(a, here)
  local out, have = {}, inTrip(a)
  local done, logged = ns.Questie.PlayerQuestState()
  -- Quest givers with quests for you.
  for _, hub in ipairs(ns.Questie.QuestHubs(here, 12)) do
    for _, g in ipairs(hub.givers) do
      local stops, names = {}, {}
      for _, q in ipairs(g.quests) do
        if not have[q.id] and not logged[q.id] then
          names[#names + 1] = q.name or ("quest " .. q.id)
          stops[#stops + 1] = { node = g.node, giver = g.name, action = { kind = "pickup", questID = q.id },
            text = string.format("Pick up %s from %s", q.name or ("quest " .. q.id), g.name or "the quest giver") }
        end
      end
      if #stops > 0 then
        out[#out + 1] = { kind = "pickup", node = g.node, stops = stops,
          label = #stops == 1 and string.format("Pick up %s (%s)", names[1], g.name or "?")
            or string.format("Pick up %d quests from %s", #stops, g.name or "?") }
      end
    end
  end
  -- Quests in your log ready to hand in.
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.IsComplete then
    for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
      local info = C_QuestLog.GetInfo(i)
      local id = info and not info.isHeader and info.questID
      if id and not have[id] and C_QuestLog.IsComplete(id) then
        local finisher, node = ns.Questie.QuestFinisher(id, here)
        local q = ns.Questie.Quest(id)
        local name = q and q.name or info.title or ("quest " .. id)
        if node then
          out[#out + 1] = { kind = "handin", node = node, label = string.format("Hand in %s (%s)", name, finisher or "?"),
            stops = { { node = node, npc = finisher, action = { kind = "turnin", questID = id },
              text = string.format("Hand in %s to %s", name, finisher or "the quest giver") } } }
        end
      end
    end
  end
  -- Vendors you need.
  for _, need in ipairs(ns.ForYou.ShoppingNeeds()) do
    local node = need.goal
    if node then
      local npc = node.npc or node.label
      out[#out + 1] = { kind = "vendor", node = node, label = need.title,
        stops = { { node = node, npc = npc, text = need.title, action = npc and { kind = "talk", npc = npc } or nil } } }
    end
  end
  return out
end

-- Seconds of travel `node` adds to the trip at its best place among `stops`.
local function added(node, stops, net)
  local plans = {}
  local function cost(from, to)
    local key = tostring(from) .. ">" .. tostring(to)
    if plans[key] == nil then
      local r = ns.Router.Plan(from, to, net)
      plans[key] = r and r.seconds or math.huge
    end
    return plans[key]
  end
  local best = cost(stops[#stops], node) -- at the end
  for i = 1, #stops - 1 do
    local extra = cost(stops[i], node) + cost(node, stops[i + 1]) - cost(stops[i], stops[i + 1])
    if extra < best then best = extra end
  end
  return math.max(0, best)
end

-- The suggestions for the trip on now, best first: { {kind, label, stops, extra} }.
function OnTheWay.Get()
  local a = ns.Nav.active
  local here = ns.Geo.PlayerNode()
  if not (a and here) then return {} end
  local now = GetTime and GetTime()
  local key = tostring(a) .. ":" .. a.index .. ":" .. #(a.journey and a.journey.stops or {})
  if cache and cache.key == key and now and now - cache.at < KEEP then return cache.list end

  local stops, near = routePoints(a, here)
  local list = {}
  local ok, all = pcall(candidates, a, here)
  if ok then
    -- The nearest to the way get a full plan.
    for _, c in ipairs(all) do
      local d = math.huge
      for _, p in ipairs(near) do d = math.min(d, ns.Geo.Distance(p, c.node)) end
      c.distance = d
    end
    table.sort(all, function(x, y) return x.distance < y.distance end)
    local net = ns.Network.Build()
    for i = 1, math.min(#all, CANDIDATES) do
      local c = all[i]
      if c.distance <= NEAR then
        c.extra = added(c.node, stops, net)
        if c.extra <= SLACK then list[#list + 1] = c end
      end
    end
    table.sort(list, function(x, y) return x.extra < y.extra end)
    while #list > MAX do table.remove(list) end
  end
  cache = { key = key, at = now or 0, list = list }
  return list
end

-- Adds a suggestion to the trip.
function OnTheWay.Add(s)
  cache = nil
  return ns.Nav.AddToTrip(s.stops, s.label)
end

ns.Listen("JOURNEY_STARTED", function() cache = nil end)
