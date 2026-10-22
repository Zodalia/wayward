local _, ns = ...

-- Suggestions along your trip (shown in the trip overview): quests you can
-- pick up, quests in your log ready to hand in, and vendors you need, that
-- are near the way and add little to it: SLACK seconds of travel or less
-- (the same as follow-up quests). Each comes with the stops to add; a
-- pickup brings its quest's objectives and hand-in along when they add under
-- AUTO_ADD seconds more.

local OnTheWay = {}
ns.OnTheWay = OnTheWay

local unpack = unpack or table.unpack

local SLACK = 180       -- seconds of travel a suggestion may add
local NEAR = 600        -- yards from the route (straight line) to be worth planning
local CANDIDATES = 8    -- nearest candidates that get a full route
local MAX = 4           -- suggestions shown
local KEEP = 20         -- seconds a set of suggestions is reused
local AUTO_ADD = 60     -- seconds: a pickup whose objectives and hand-in add less brings them along

local cache

-- The trip's points: where you are, then its open stops in order (or the
-- destination), and every place its route passes (for "near the way").
-- Errands.lua ranks its places by these too.
function OnTheWay.RoutePoints(a, here)
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
  local done, logged = ns.Quests.PlayerQuestState()
  -- Quest givers with quests for you.
  for _, hub in ipairs(ns.Quests.QuestHubs(here, 12)) do
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
  for _, info in ns.QuestLog.Entries() do
    local id = not info.isHeader and info.questID
    if id and not have[id] and ns.QuestLog.IsComplete(id) then
      local finisher, node = ns.Quests.QuestFinisher(id, here)
      local q = ns.Quests.Quest(id)
      local name = q and q.name or info.title or ("quest " .. id)
      if node then
        out[#out + 1] = { kind = "handin", node = node, label = string.format("Hand in %s (%s)", name, finisher or "?"),
          stops = { { node = node, npc = finisher, action = { kind = "turnin", questID = id },
            text = string.format("Hand in %s to %s", name, finisher or "the quest giver") } } }
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
function OnTheWay.Added(node, stops, net)
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

  local stops, near = OnTheWay.RoutePoints(a, here)
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
        c.extra = OnTheWay.Added(c.node, stops, net)
        if c.extra <= SLACK then list[#list + 1] = c end
      end
    end
    table.sort(list, function(x, y) return x.extra < y.extra end)
    while #list > MAX do table.remove(list) end
  end
  cache = { key = key, at = now or 0, list = list }
  return list
end

-- A pickup's quest done and handed in, when that adds under AUTO_ADD seconds
-- of travel to the trip with the pickup: added with it rather than asked
-- about once you pick it up. `stops` are the suggestion's pickups; returns
-- the stops to add, and the names of the quests that came whole.
local function withHandIns(stops)
  local a, here = ns.Nav.active, ns.Geo.PlayerNode()
  if not (a and here) then return stops, {} end
  local root = a.journey and (a.journey.root or a.journey.def)
  local open, finish = {}, nil
  if root then
    for _, st in ipairs(root.stops or {}) do
      if not st.done and not st.skipped then open[#open + 1] = st end
    end
    finish = root.finish and not root.finish.done and not root.finish.skipped and root.finish or nil
  else
    open[1] = { node = a.goal, text = a.title }
  end
  local function plan(list)
    local all = { unpack(open) }
    for _, st in ipairs(list) do all[#all + 1] = st end
    return ns.Journey.Plan(here, { stops = all, finish = finish })
  end
  local out, whole = { unpack(stops) }, {}
  local base = plan(out)
  if not base then return stops, whole end
  for i, pickup in ipairs(stops) do
    local id = pickup.action and pickup.action.questID
    local qs = id and ns.Journey.QuestStops(id, here) or {}
    if #qs > 1 and qs[1].action.kind == "pickup" then
      -- The suggestion's giver: the rest of the quest comes after that pickup.
      qs[1].node, qs[1].giver, qs[1].text = pickup.node, pickup.giver, pickup.text
      local candidate = { unpack(out) }
      candidate[i] = qs[1]
      for k = 2, #qs do candidate[#candidate + 1] = qs[k] end
      local with = plan(candidate)
      if with and #with.skipped <= #base.skipped and with.seconds - base.seconds < AUTO_ADD then
        out, base = candidate, with
        local q = ns.Quests.Quest(id)
        whole[#whole + 1] = q and q.name or ("quest " .. id)
      end
    end
  end
  return out, whole
end

-- Adds a suggestion to the trip.
function OnTheWay.Add(s)
  cache = nil
  local stops, whole = s.stops, {}
  if s.kind == "pickup" then
    -- An error still adds the pickups (and is reported).
    local ok, a, b = pcall(withHandIns, s.stops)
    if ok then stops, whole = a, b else geterrorhandler()(a) end
  end
  local added = ns.Nav.AddToTrip(stops, s.label)
  if added and #whole > 0 then
    ns.print(string.format("handing in %s adds under a minute: added too.", table.concat(whole, ", ")))
  end
  return added
end

ns.Listen("JOURNEY_STARTED", function() cache = nil end)
ns.Listen("JOURNEY_EXTENDED", function() cache = nil end)
