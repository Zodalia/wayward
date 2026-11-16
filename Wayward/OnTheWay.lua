local _, ns = ...

-- Nearby (the On the way pane's first tab, UI/Drawer.lua): quests you can
-- pick up, quests in your log ready to hand in, and vendors you need, around
-- where you are now: NEAR yards or less in a straight line and SLACK seconds
-- of travel or less from you. Worked out from where you stand, not along the
-- whole journey: what's near you, and how long it takes to get there. Each
-- comes with the stops to add (the journey places them where they fit); a
-- pickup brings its quest's objectives and hand-in along when they add under
-- AUTO_ADD seconds more.

local OnTheWay = {}
ns.OnTheWay = OnTheWay

local unpack = unpack or table.unpack

local SLACK = 180       -- seconds of travel from you, at most
local NEAR = 600        -- yards from you (straight line) to be worth planning
local CANDIDATES = 8    -- nearest candidates that get a full route
local MAX = 4           -- suggestions shown
local KEEP = 20         -- seconds a set of suggestions is reused
local MOVED = 40        -- yards you walk before they're worked out again
local AUTO_ADD = 60     -- seconds: a pickup whose objectives and hand-in add less brings them along

local cache

-- Seconds of travel from `here` to `node` (math.huge when there's no way).
-- Errands.lua times its places by this too.
function OnTheWay.Seconds(here, node, net)
  local r = ns.Router.Plan(here, node, net)
  return r and r.seconds or math.huge
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

-- What's nearby to add, nearest first: { {kind, label, stops, node, extra
-- (seconds from you)} }.
function OnTheWay.Get()
  local a = ns.Nav.active
  local here = ns.Geo.PlayerNode()
  if not (a and here) then return {} end
  local now = GetTime and GetTime()
  local key = tostring(a) .. ":" .. a.index .. ":" .. #(a.journey and a.journey.stops or {})
  if cache and cache.key == key and now and now - cache.at < KEEP and cache.here
    and ns.Geo.Distance(cache.here, here) <= MOVED then
    return cache.list
  end

  local list = {}
  local ok, all = pcall(candidates, a, here)
  if ok then
    -- The nearest to you get a full plan.
    for _, c in ipairs(all) do c.distance = ns.Geo.Distance(here, c.node) end
    table.sort(all, function(x, y) return x.distance < y.distance end)
    local net = ns.Network.Build()
    for i = 1, math.min(#all, CANDIDATES) do
      local c = all[i]
      if c.distance <= NEAR then
        c.extra = OnTheWay.Seconds(here, c.node, net)
        if c.extra <= SLACK then list[#list + 1] = c end
      end
    end
    table.sort(list, function(x, y) return x.extra < y.extra end)
    while #list > MAX do table.remove(list) end
  end
  cache = { key = key, at = now or 0, here = here, list = list }
  return list
end

-- A pickup's quest done and handed in, when that adds under AUTO_ADD seconds
-- of travel to the journey with the pickup: added with it rather than asked
-- about once you pick it up. Under AUTO_ADD only by spending your
-- Hearthstone (Journey.Plan's withoutHearth) doesn't count: those are left
-- to ask about. `stops` are the suggestion's pickups; returns the stops to
-- add, the names of the quests that came whole, and of those left out for
-- the Hearthstone.
local function withHandIns(stops)
  local a, here = ns.Nav.active, ns.Geo.PlayerNode()
  if not (a and here) then return stops, {}, {} end
  local root = a.journey and (a.journey.root or a.journey.def)
  local open = {}
  if root then
    for _, st in ipairs(root.stops or {}) do
      if not st.done and not st.skipped then open[#open + 1] = st end
    end
  else
    open[1] = { node = a.goal, text = a.title }
  end
  local function plan(list)
    local all = { unpack(open) }
    for _, st in ipairs(list) do all[#all + 1] = st end
    return ns.Journey.Plan(here, { stops = all })
  end
  local out, whole, hearthOnly = { unpack(stops) }, {}, {}
  local base = plan(out)
  if not base then return stops, whole, hearthOnly end
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
      local q = ns.Quests.Quest(id)
      local name = q and q.name or ("quest " .. id)
      -- Done inside a dungeon: a run of it, never "under a minute". Left to
      -- ask about once you pick it up.
      local besides = { unpack(open) }
      for _, st in ipairs(out) do besides[#besides + 1] = st end
      local run = ns.Journey.RunSeconds(qs, besides)
      if with and run == 0 and #with.skipped <= #base.skipped and with.seconds - base.seconds < AUTO_ADD then
        if with.withoutHearth - base.withoutHearth < AUTO_ADD then
          out, base = candidate, with
          whole[#whole + 1] = name
        else
          hearthOnly[#hearthOnly + 1] = name
        end
      end
    end
  end
  return out, whole, hearthOnly
end

-- Adds a detour to the journey.
function OnTheWay.Add(s)
  cache = nil
  local stops, whole, hearthOnly = s.stops, {}, {}
  if s.kind == "pickup" then
    -- An error still adds the pickups (and is reported).
    local ok, a, b, c = pcall(withHandIns, s.stops)
    if ok then stops, whole, hearthOnly = a, b, c else geterrorhandler()(a) end
  end
  local added = ns.Nav.AddToTrip(stops, s.label)
  if added and #whole > 0 then
    ns.print(string.format("handing in %s adds under a minute: added too.", table.concat(whole, ", ")))
  end
  if added and #hearthOnly > 0 then
    ns.print(string.format("handing in %s adds under a minute only by using your Hearthstone, so it isn't "
      .. "added unasked.", table.concat(hearthOnly, ", ")))
  end
  return added
end

ns.Listen("JOURNEY_STARTED", function() cache = nil end)
ns.Listen("JOURNEY_EXTENDED", function() cache = nil end)
