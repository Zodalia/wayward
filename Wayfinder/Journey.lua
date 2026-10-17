local _, ns = ...

-- Journeys: trips with several stops, e.g. "pick up three quests, then go to
-- the Deadmines". Stops are visited in the quickest order found (nearest
-- next stop, then pairwise swaps) that respects each stop's `after` list,
-- with an optional fixed final stop.
--
-- A journey definition:
--   {
--     title = "Deadmines run",
--     stops = { stop, ... },   -- visited in any order allowed by `after`
--     finish = stop,           -- optional, always last (e.g. a dungeon entrance)
--   }
-- A stop:
--   {
--     node = route node (ns.Geo.Node),
--     text = "Pick up Red Silk Bandanas from Scout Riell",  -- shown on arrival
--     action = { kind = "pickup" | "complete" | "turnin", questID = 123 },  -- optional
--     after = { stop, ... },   -- optional: stops that must come first
--     resolve = { kind = "objectives", questID = 123 },  -- optional: node found at planning time
--   }
-- A stop with an action waits there until the quest is accepted, its
-- objectives are complete, or it is handed in; one without an action is done
-- on arrival. Journey.QuestStops builds the stops for a whole quest.

local Journey = {}
ns.Journey = Journey

local MAX_SWAP_PASSES = 6

---------------------------------------------------------------- quest stops

-- Quest state comes from the same place as the rest of Wayfinder (completed
-- quest list and quest log), refreshed per call.
local done, logged = {}, {}

local function refresh()
  done, logged = ns.Questie.PlayerQuestState()
end

local function inLog(questID)
  return logged[questID] == true
end

local function completed(questID)
  return done[questID] == true
end

local function objectivesDone(questID)
  return inLog(questID) and C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID) or false
end

-- Marks quest stops done when the quest has already moved past them (e.g.
-- while you were offline, or a party member shared it).
function Journey.SyncQuestState(def)
  refresh()
  local function sync(stop)
    local action = stop and stop.action
    if not (action and action.questID) or stop.done then return end
    local id = action.questID
    if action.kind == "pickup" then
      stop.done = inLog(id) or completed(id)
    elseif action.kind == "complete" then
      stop.done = completed(id) or objectivesDone(id)
    elseif action.kind == "turnin" then
      stop.done = completed(id)
    end
  end
  for _, stop in ipairs(def.stops or {}) do sync(stop) end
  sync(def.finish)
end

-- The stops for doing a whole quest from where it stands now: pick it up,
-- do the objectives, hand it in. Returns { stops } (empty if done).
function Journey.QuestStops(questID, here)
  local q = ns.Questie.Quest(questID)
  local name = q and q.name or ("quest " .. questID)
  refresh()
  if completed(questID) then return {} end
  local stops = {}
  local previous

  if not inLog(questID) then
    local giver, node = ns.Questie.QuestGiver(questID, here)
    if not node then return {} end
    previous = { node = node, text = string.format("Pick up %s from %s", name, giver or "the quest giver"),
      action = { kind = "pickup", questID = questID } }
    stops[#stops + 1] = previous
  end

  if not objectivesDone(questID) then
    local node = ns.Questie.ObjectiveNode(questID, here)
    if node then
      previous = { node = node, text = "Do " .. name, after = previous and { previous } or nil,
        action = { kind = "complete", questID = questID }, resolve = { kind = "objectives", questID = questID } }
      stops[#stops + 1] = previous
    end
  end

  local finisher, node = ns.Questie.QuestFinisher(questID, here)
  if node then
    stops[#stops + 1] = { node = node, text = string.format("Hand in %s to %s", name, finisher or "the quest giver"),
      after = previous and { previous } or nil, action = { kind = "turnin", questID = questID } }
  end
  return stops
end

-- Refreshes nodes found at planning time (the objectives marker appears once
-- the quest is in your log).
local function resolve(stop, here)
  local r = stop.resolve
  if r and r.kind == "objectives" then
    local node = ns.Questie.ObjectiveNode(r.questID, here)
    if node then stop.node = node end
  end
end

---------------------------------------------------------------- ordering

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
  local points, indexOf = { start }, {}
  for i, stop in ipairs(stops) do
    points[#points + 1] = stop.node
    indexOf[stop] = i + 1
  end
  local cost = costTable(points, net)

  -- A stop is ready once every stop it comes after (in this plan) is placed.
  local function ready(i, placed)
    for _, before in ipairs(stops[i - 1].after or {}) do
      local j = indexOf[before]
      if j and not placed[j] then return false end
    end
    return true
  end

  local function valid(o)
    local placed = {}
    for _, i in ipairs(o) do
      if not ready(i, placed) then return false end
      placed[i] = true
    end
    return true
  end

  -- Nearest next stop that is ready.
  local order, used, current = {}, {}, 1
  for _ = 1, #stops do
    local best, bestCost
    for i = 2, #points do
      if not used[i] and ready(i, used) and (not bestCost or cost(current, i) < bestCost) then
        best, bestCost = i, cost(current, i)
      end
    end
    if not best then
      -- `after` loop: take the rest as given.
      for i = 2, #points do if not used[i] then best = i break end end
    end
    used[best] = true
    order[#order + 1] = best
    current = best
  end

  -- Reverse segments while that shortens the trip (2-opt), keeping `after`.
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
        if t < best and valid(candidate) then order, best, improved = candidate, t, true end
      end
    end
    if not improved then break end
  end

  local ordered = {}
  for _, i in ipairs(order) do ordered[#ordered + 1] = stops[i - 1] end
  return ordered
end

-- Stops in the player's own order (Journey.Move); stops added since (marked
-- `unplaced`) go where they add the least travel time.
local function validOrder(order, inPlan)
  local placed = {}
  for _, stop in ipairs(order) do
    for _, before in ipairs(stop.after or {}) do
      if inPlan[before] and not placed[before] then return false end
    end
    placed[stop] = true
  end
  return true
end

local function manualOrder(start, stops, net)
  local order, extra, points, indexOf, inPlan = {}, {}, { start }, {}, {}
  for i, stop in ipairs(stops) do
    points[#points + 1] = stop.node
    indexOf[stop] = i + 1
    inPlan[stop] = true
    if stop.unplaced then extra[#extra + 1] = stop else order[#order + 1] = stop end
  end
  if #extra == 0 then return order end
  local cost = costTable(points, net)
  local function total(o)
    local sum, prev = 0, 1
    for _, stop in ipairs(o) do sum, prev = sum + cost(prev, indexOf[stop]), indexOf[stop] end
    return sum
  end
  for _, stop in ipairs(extra) do
    local best, bestTotal
    for pos = 1, #order + 1 do
      local candidate = {}
      for k = 1, pos - 1 do candidate[k] = order[k] end
      candidate[pos] = stop
      for k = pos, #order do candidate[k + 1] = order[k] end
      local t = total(candidate)
      if (not bestTotal or t < bestTotal) and validOrder(candidate, inPlan) then best, bestTotal = candidate, t end
    end
    if not best then
      best = order
      best[#best + 1] = stop
    end
    order = best
    stop.unplaced = nil
  end
  return order
end

---------------------------------------------------------------- planning

-- Plans a journey from `start`. Returns
--   { title, def, root, stops = ordered stops, skipped = unreachable stops,
--     steps = route steps (the last step of each leg carries .stop), seconds }
-- or nil when no stop is reachable. `root` is the original definition, kept
-- across re-plans so the overview can show stops already done.
function Journey.Plan(start, def, net)
  net = net or ns.Network.Build()
  for _, stop in ipairs(def.stops or {}) do resolve(stop, start) end
  if def.finish then resolve(def.finish, start) end
  local root = def.root or def
  local ordered
  if root.manual then
    ordered = manualOrder(start, def.stops or {}, net)
    -- Keep the root in this order, so later re-plans start from it.
    if root.stops and root.stops ~= def.stops then
      local planned, stops = {}, {}
      for _, stop in ipairs(ordered) do planned[stop] = true end
      for _, stop in ipairs(root.stops) do
        if not planned[stop] then stops[#stops + 1] = stop end
      end
      for _, stop in ipairs(ordered) do stops[#stops + 1] = stop end
      root.stops = stops
    end
  else
    ordered = orderStops(start, def.stops or {}, net)
  end
  if def.finish then ordered[#ordered + 1] = def.finish end

  local journey = { title = def.title, def = def, root = root, stops = {}, skipped = {}, steps = {},
    seconds = 0 }
  local from = start
  for _, stop in ipairs(ordered) do
    local route = stop.node and ns.Router.Plan(from, stop.node, net)
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

local function open(stop)
  return stop and not stop.done and not stop.skipped
end

-- The same journey from here, without the stops already done or dropped. The
-- original plan (root) is the source, so stops added since are included.
function Journey.Replan(journey, start, net)
  local root = journey.root or journey.def
  local remaining = {}
  for _, stop in ipairs(root.stops or {}) do
    if open(stop) then remaining[#remaining + 1] = stop end
  end
  local finish = open(root.finish) and root.finish or nil
  return Journey.Plan(start, { title = root.title, stops = remaining, finish = finish, root = root }, net)
end

local function questKey(stop)
  local a = stop.action
  return a and a.questID and (a.kind .. ":" .. a.questID) or nil
end

-- Adds stops to a journey's plan, skipping quest stops it already has open.
-- Returns how many were added; re-plan afterwards (Journey.Replan).
function Journey.Extend(journey, stops)
  local root = journey.root or journey.def
  root.stops = root.stops or {}
  local have = {}
  for _, stop in ipairs(root.stops) do
    local key = questKey(stop)
    if key and open(stop) then have[key] = true end
  end
  local added = 0
  for _, stop in ipairs(stops) do
    local key = questKey(stop)
    if not (key and have[key]) then
      -- In a trip you ordered yourself, the next plan finds it a place.
      if root.manual then stop.unplaced = true end
      table.insert(root.stops, stop)
      added = added + 1
      if key then have[key] = true end
    end
  end
  return added
end

-- Moves an open stop to where `target` is in the current plan (after it when
-- moving down, before it when moving up); from then on the journey keeps your
-- order. Returns false, and changes nothing, when that would put a stop before
-- one it needs (a hand-in before its pickup). Re-plan afterwards.
function Journey.Move(journey, stop, target)
  if not (stop and target) or stop == target then return false end
  local root = journey.root or journey.def
  if stop == root.finish then return false end
  local order, from, to = {}, nil, nil
  for _, s in ipairs(journey.stops) do
    if open(s) and s ~= root.finish then
      order[#order + 1] = s
      if s == stop then from = #order end
      if s == target then to = #order end
    end
  end
  if target == root.finish then to = #order end
  if not (from and to) then return false end
  table.remove(order, from)
  table.insert(order, to, stop)
  local inPlan = {}
  for _, s in ipairs(order) do inPlan[s] = true end
  if not validOrder(order, inPlan) then return false end
  local stops, moved = {}, {}
  for _, s in ipairs(order) do moved[s] = true end
  for _, s in ipairs(root.stops or {}) do
    if not moved[s] then stops[#stops + 1] = s end
  end
  for _, s in ipairs(order) do stops[#stops + 1] = s end
  root.stops = stops
  root.manual = true
  return true
end

-- A journey's open stops as plain stops to add elsewhere; its fixed final stop
-- (e.g. a dungeon entrance) comes after the rest.
function Journey.OpenStops(journey)
  local root = journey.root or journey.def
  local out = {}
  for _, stop in ipairs(root.stops or {}) do
    if open(stop) then out[#out + 1] = stop end
  end
  if open(root.finish) then
    local finish = root.finish
    local after = {}
    for _, stop in ipairs(out) do after[#after + 1] = stop end
    finish.after = #after > 0 and after or finish.after
    out[#out + 1] = finish
  end
  return out
end

-- Every stop of the original plan, in a stable order: the open ones as the
-- current plan visits them, then the rest. For the overview window.
function Journey.AllStops(journey)
  local out, seen = {}, {}
  for _, stop in ipairs(journey.stops) do
    out[#out + 1] = stop
    seen[stop] = true
  end
  local root = journey.root or journey.def
  for _, stop in ipairs(root.stops or {}) do
    if not seen[stop] then out[#out + 1] = stop end
  end
  if root.finish and not seen[root.finish] then out[#out + 1] = root.finish end
  return out
end

-- Stop that a step arrives at, if it still waits for a quest action.
function Journey.PendingAction(step)
  local stop = step and step.stop
  return stop and stop.action and stop.action.questID and not stop.done and not stop.skipped and stop or nil
end

function Journey.StopsDone(journey)
  local done = 0
  for _, stop in ipairs(journey.stops) do
    if stop.done and not stop.passed then done = done + 1 end
  end
  return done
end

-- The zone a stop is in ("Stormwind City"), for lists of stops.
function Journey.StopZone(stop)
  local node = stop and stop.node
  if not node then return nil end
  local mapID = ns.Geo.ZoneAt(node.instance, node.wx, node.wy) or node.mapID
  return mapID and ns.MapName(mapID) or nil
end

---------------------------------------------------------------- saving

local function saveNode(node)
  return node and { mapID = node.mapID, x = node.x, y = node.y, label = node.label }
end

local function loadNode(saved)
  return saved and ns.Geo.Node(saved.mapID, saved.x, saved.y, saved.label)
end

-- A plain-table copy of a journey's original definition for SavedVariables.
function Journey.Save(journey)
  local root = journey.root or journey.def
  local index = {}
  for i, stop in ipairs(root.stops or {}) do index[stop] = i end
  local function save(stop)
    local after = {}
    for _, before in ipairs(stop.after or {}) do after[#after + 1] = index[before] end
    return { node = saveNode(stop.node), text = stop.text, action = stop.action, resolve = stop.resolve,
      done = stop.done, passed = stop.passed, skipped = stop.skipped, after = #after > 0 and after or nil }
  end
  local saved = { title = root.title, manual = root.manual, stops = {} }
  for i, stop in ipairs(root.stops or {}) do saved.stops[i] = save(stop) end
  if root.finish then saved.finish = save(root.finish) end
  return saved
end

-- The definition back from Journey.Save; plan it with Journey.Plan.
function Journey.Load(saved)
  local def = { title = saved.title, manual = saved.manual, stops = {} }
  local function load(s)
    return { node = loadNode(s.node), text = s.text, action = s.action, resolve = s.resolve, done = s.done,
      passed = s.passed, skipped = s.skipped }
  end
  for i, s in ipairs(saved.stops or {}) do def.stops[i] = load(s) end
  for i, s in ipairs(saved.stops or {}) do
    if s.after then
      def.stops[i].after = {}
      for _, j in ipairs(s.after) do table.insert(def.stops[i].after, def.stops[j]) end
    end
  end
  if saved.finish then def.finish = load(saved.finish) end
  return def
end

-- The open part of a loaded definition, planned from here.
function Journey.Resume(def, start, net)
  Journey.SyncQuestState(def)
  local remaining = {}
  for _, stop in ipairs(def.stops) do
    if open(stop) and stop.node then remaining[#remaining + 1] = stop end
  end
  local finish = open(def.finish) and def.finish or nil
  if #remaining == 0 and not finish then return nil end
  return Journey.Plan(start, { title = def.title, stops = remaining, finish = finish, root = def }, net)
end
