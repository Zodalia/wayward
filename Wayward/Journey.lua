local _, ns = ...

-- Journeys: adventures with several stops, e.g. "pick up three quests, then
-- go to the Deadmines". Stops are visited in the quickest order found
-- (nearest next stop, then pairwise swaps) that respects each stop's `after`
-- list.
--
-- A journey definition:
--   {
--     title = "Deadmines run",
--     kind = "quest" | "zone" | "dungeon" | "hand-in" | "finish" | "profession" | "custom" ...,
--     icon = "Interface\\Icons\\...",   -- both optional, shown by the home screen and the fanfare
--     stops = { stop, ... },   -- visited in any order allowed by `after`
--     finish = stop,           -- older definitions: a stop that comes after the others
--                              -- ("Enter X" becomes an `enter` stop, see Journey.Plan)
--   }
-- A stop:
--   {
--     node = route node (ns.Geo.Node),
--     text = "Pick up Red Silk Bandanas from Scout Riell",  -- shown on arrival
--     action = { kind = "pickup" | "complete" | "turnin", questID = 123 },  -- optional; also
--       { kind = "item", itemID, questID } (collect an item a quest needs) and
--       { kind = "manual", questID } (a step of a quest you confirm with next) and
--       { kind = "talk", npc } (done when you talk to them: a trainer, a vendor) and
--       { kind = "train", profession, cap, npc } (done when that profession's skill
--       cap is over `cap`: you bought the next rank) and
--       { kind = "explore", mapID } (done once you're in that zone, or a subzone of it) and
--       { kind = "enter", dungeon = "The Deadmines" } (done when you load into it) and
--       { kind = "learn", spells = { spellID or name, ... }, npc } (class training: done at the
--       trainer once one of those, or any new spell, is learned; Navigator.lua)
--     after = { stop, ... },   -- optional: stops that must come first
--     later = { stop, ... },   -- set by Journey.Postpone: stops you chose to do first
--     resolve = { kind = "objectives", questID = 123 },  -- optional: node found at planning time
--       (objectives in several areas: the area that fits the trip, see Journey.PickArea)
--     worked = { [area index] = time },  -- set on the way: objective areas you've cleared
--   }
-- A stop with an action waits there until the quest is accepted, its
-- objectives are complete, or it is handed in; one without an action is done
-- on arrival. Journey.QuestStops builds the stops for a whole quest.

local Journey = {}
ns.Journey = Journey

local MAX_SWAP_PASSES = 6

---------------------------------------------------------------- quest stops

-- Quest state comes from the same place as the rest of Wayward (completed
-- quest list and quest log), refreshed per call.
local done, logged = {}, {}

local function refresh()
  done, logged = ns.Quests.PlayerQuestState()
end

local function inLog(questID)
  return logged[questID] == true
end

local function completed(questID)
  return done[questID] == true
end

local function objectivesDone(questID)
  return inLog(questID) and ns.QuestLog.IsComplete(questID) or false
end

local function hasItem(itemID)
  return ns.ItemCount(itemID) > 0
end

-- Marks quest stops done when the quest has already moved past them (e.g.
-- while you were offline, a party member shared it, or you skipped the stop
-- and did it anyway). Returns how many changed.
function Journey.SyncQuestState(def)
  refresh()
  local changed = 0
  local function sync(stop)
    local action = stop and stop.action
    if not (action and action.questID) or (stop.done and not stop.passed) then return end
    local id = action.questID
    local now
    if action.kind == "pickup" then
      now = inLog(id) or completed(id)
    elseif action.kind == "complete" or action.kind == "manual" then
      now = completed(id) or objectivesDone(id)
    elseif action.kind == "item" then
      now = completed(id) or objectivesDone(id) or hasItem(action.itemID)
    elseif action.kind == "turnin" then
      now = completed(id)
    end
    if now then
      stop.done, stop.passed = true, nil
      changed = changed + 1
    end
  end
  for _, stop in ipairs(def.stops or {}) do sync(stop) end
  sync(def.finish)
  return changed
end

-- The stops for doing a whole quest from where it stands now: pick it up,
-- do the objectives, hand it in. Returns { stops } (empty if done).
function Journey.QuestStops(questID, here)
  local q = ns.Quests.Quest(questID)
  local name = q and q.name or ("quest " .. questID)
  refresh()
  if completed(questID) then return {} end
  local stops = {}
  local previous

  if not inLog(questID) then
    local giver, node = ns.Quests.QuestGiver(questID, here)
    if not node then return {} end
    previous = { node = node, text = string.format("Pick up %s from %s", name, giver or "the quest giver"),
      giver = giver, action = { kind = "pickup", questID = questID } }
    stops[#stops + 1] = previous
  end

  if not objectivesDone(questID) then
    -- What the quest needs first: items to collect (any order), then its
    -- extra steps in order (e.g. fill a bowl, place it at a bonfire).
    local gate = previous and { previous } or nil
    local items = {}
    for _, p in ipairs(ns.Quests.QuestPrep(questID, here)) do
      local stop
      if p.kind == "item" then
        stop = { node = p.node, text = string.format("%s for %s", p.text, name), after = previous and { previous } or nil,
          action = { kind = "item", itemID = p.itemID, questID = questID } }
        items[#items + 1] = stop
      else
        if #items > 0 then gate, items = items, {} end
        stop = { node = p.node, text = p.text, after = gate, action = { kind = "manual", questID = questID } }
        gate = { stop }
      end
      stops[#stops + 1] = stop
    end
    if #items > 0 then gate = items end
    local node = ns.Quests.ObjectiveNode(questID, here)
    if node then
      previous = { node = node, text = "Do " .. name, after = gate,
        action = { kind = "complete", questID = questID }, resolve = { kind = "objectives", questID = questID } }
      stops[#stops + 1] = previous
    end
  end

  local finisher, node = ns.Quests.QuestFinisher(questID, here)
  if node then
    stops[#stops + 1] = { node = node, npc = finisher, text = string.format("Hand in %s to %s", name, finisher or "the quest giver"),
      after = previous and { previous } or nil, action = { kind = "turnin", questID = questID } }
  end
  return stops
end

---------------------------------------------------------------- objective areas

-- A quest's objectives can be in several areas (Quests.ObjectiveAreas: one
-- camp, then the next one up the coast). A stop remembers the areas you've
-- cleared: after WORK_SECONDS in one, leaving it counts it as cleared for
-- CLEARED_FOR (about a respawn), and the way goes elsewhere meanwhile. Seeing
-- the camp empty (Camps.lua) counts it as cleared sooner.
local WORK_SECONDS, CLEARED_FOR = 30, 300

-- The areas that still have something you need (a finished objective's
-- spawns don't count; the quest log says which are finished):
-- { {index, nodes}, ... }.
function Journey.OpenAreas(questID)
  local areas = ns.Quests.ObjectiveAreas(questID)
  if #areas == 0 then return {} end
  local groups = ns.Quests.ObjectiveGroups(questID)
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID) or {}
  local finished = {}
  for g, group in ipairs(groups) do
    for _, o in ipairs(objectives) do
      if o.finished and group.name and type(o.text) == "string" and o.text:find(group.name, 1, true) then
        finished[g] = true
      end
    end
  end
  local out = {}
  for index, area in ipairs(areas) do
    local nodes = {}
    for _, m in ipairs(area) do
      if not finished[m.group] then nodes[#nodes + 1] = m.node end
    end
    if #nodes > 0 then out[#out + 1] = { index = index, nodes = nodes } end
  end
  return out
end

local function clearedAt(stop, index, now)
  local at = stop.worked and stop.worked[index]
  return at and now - at < CLEARED_FOR and at or nil
end

-- Whether you've cleared one of a stop's areas lately.
function Journey.Cleared(stop, index)
  return clearedAt(stop, index, time()) ~= nil
end

-- Seconds until a stop's objectives can be done again: when every area of
-- them still open is one you've cleared lately (a quest with one camp, say),
-- until the first respawns. 0 otherwise, and while you're in one.
function Journey.RespawnIn(stop)
  local action = stop and stop.action
  if not (action and action.kind == "complete" and action.questID and stop.worked) or stop.inArea then return 0 end
  local now, soonest = time(), nil
  for _, area in ipairs(Journey.OpenAreas(action.questID)) do
    local at = clearedAt(stop, area.index, now)
    if not at then return 0 end
    local left = at + CLEARED_FOR - now
    if not soonest or left < soonest then soonest = left end
  end
  return soonest or 0
end

-- How many of a stop's areas you've cleared lately.
function Journey.ClearedAreas(stop)
  local now, count = time(), 0
  for index in pairs(stop and stop.worked or {}) do
    if clearedAt(stop, index, now) then count = count + 1 end
  end
  return count
end

-- Tracks which of a stop's areas you're in (`index`, nil when in none); each
-- time in one is a visit (stop.visit, watched by Camps). Returns true when
-- that just counted the one you left as cleared: after WORK_SECONDS there, or
-- sooner when it looked cleared (Camps.LooksCleared).
function Journey.EnterArea(stop, index)
  if stop.areaAt == index then return false end
  local now, cleared, visit = time(), false, stop.visit
  if stop.areaAt and visit and (now - visit.since >= WORK_SECONDS or visit.looksCleared) then
    stop.worked = stop.worked or {}
    stop.worked[stop.areaAt] = now
    cleared = true
  end
  stop.areaAt, stop.visit = index, index and { since = now } or nil
  return cleared
end

-- Ends a visit without counting the area as cleared (you died there).
function Journey.ForgetVisit(stop)
  stop.areaAt, stop.visit, stop.inArea = nil, nil, nil
end

-- You say the area you're in is cleared (the directions box's move on). It
-- isn't the area you're in again until you've walked out of it (stop.leaving,
-- Nav). Returns false when you're in none of the stop's areas.
function Journey.ClearArea(stop)
  if not (stop and stop.areaAt) then return false end
  stop.worked = stop.worked or {}
  stop.worked[stop.areaAt] = time()
  stop.leaving = stop.areaAt
  Journey.ForgetVisit(stop)
  return true
end

-- Where to do a stop's objectives from `from` when they're in more than one
-- area: the one you're in; else one you haven't cleared lately, the least out
-- of the way on to `toward` (the stop after it); else the one cleared longest
-- ago (it respawns first). Returns the node to head for (the area's open
-- spawn nearest `from`) and the area's index, or nil with fewer than two areas.
function Journey.PickArea(stop, from, toward)
  local action = stop and stop.action
  if not (action and action.questID and from) then return nil end
  local areas = Journey.OpenAreas(action.questID)
  if #areas < 2 then return nil end
  local now = time()
  local best, bestIndex, bestRank, bestValue
  for _, area in ipairs(areas) do
    local node, distance = ns.Data.Nearest(area.nodes, from)
    local cleared = clearedAt(stop, area.index, now)
    local rank, value
    if stop.inArea and stop.areaAt == area.index then
      rank, value = 0, 0
    elseif cleared then
      rank, value = 2, cleared
    else
      rank, value = 1, distance + (toward and ns.Geo.Distance(node, toward) or 0)
    end
    if not bestRank or rank < bestRank or (rank == bestRank and value < bestValue) then
      best, bestIndex, bestRank, bestValue = node, area.index, rank, value
    end
  end
  return best, bestIndex
end

-- Refreshes nodes found at planning time (the objectives marker appears once
-- the quest is in your log; objectives in several areas pick one).
local function resolve(stop, here)
  local r = stop.resolve
  if r and r.kind == "objectives" then
    local node = Journey.PickArea(stop, here) or ns.Quests.ObjectiveNode(r.questID, here)
    if node then stop.node = node end
  end
end

---------------------------------------------------------------- ordering

-- The stops a stop comes after: the ones it needs (`after`) and the ones you
-- chose to do first (`later`, Journey.Postpone).
local function prerequisites(stop)
  if not stop.later then return stop.after or {} end
  local out = {}
  for _, s in ipairs(stop.after or {}) do out[#out + 1] = s end
  for _, s in ipairs(stop.later) do out[#out + 1] = s end
  return out
end

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
  -- Seconds until a stop can be done (its camps respawning): getting there
  -- sooner means waiting, so other stops fit in first.
  local readyIn = {}
  for i, stop in ipairs(stops) do readyIn[i + 1] = Journey.RespawnIn(stop) end
  local function arrive(t, from, i)
    return math.max(t + cost(from, i), readyIn[i])
  end

  -- A stop is ready once every stop it comes after (in this plan) is placed.
  local function ready(i, placed)
    for _, before in ipairs(prerequisites(stops[i - 1])) do
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

  -- Nearest next stop that is ready (soonest done, waits included).
  local order, used, current, clock = {}, {}, 1, 0
  for _ = 1, #stops do
    local best, bestAt
    for i = 2, #points do
      if not used[i] and ready(i, used) and (not bestAt or arrive(clock, current, i) < bestAt) then
        best, bestAt = i, arrive(clock, current, i)
      end
    end
    if not best then
      -- `after` loop: take the rest as given.
      for i = 2, #points do if not used[i] then best = i break end end
    end
    used[best] = true
    order[#order + 1] = best
    clock = arrive(clock, current, best)
    current = best
  end

  -- Reverse segments while that shortens the trip (2-opt), keeping `after`.
  local function total(o)
    local t, prev = 0, 1
    for _, i in ipairs(o) do t, prev = arrive(t, prev, i), i end
    return t
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
    for _, before in ipairs(prerequisites(stop)) do
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

---------------------------------------------------------------- hearthstone

-- Your Hearthstone (Hearth.lua) can stand in for a leg: hearth, then travel
-- on from the inn. It has an hour's cooldown, so a journey uses it once, on
-- the leg where it saves the most, any cooldown left by then counted as a
-- wait. That leg's route becomes the hearth and the rest. Returns
--   { stop, label, saves }                    used before `stop`, or
--   { stop, label, saves, readyIn, cooldown = true }  it would save `saves`
--     if it were ready, but it's `readyIn` seconds away, or
--   nil (no Hearthstone, or it doesn't help).
-- Stop order is found without it.
local HEARTH_MIN_SAVING = 60

local function viaHearth(net, node, goal)
  -- Kept on the network (rebuilt when what it's made of changes), per inn and goal.
  local cache = net.fromHearth
  if not cache or cache.key ~= node.wx .. ":" .. node.wy then
    cache = { key = node.wx .. ":" .. node.wy, routes = setmetatable({}, { __mode = "k" }) }
    net.fromHearth = cache
  end
  if cache.routes[goal] == nil then cache.routes[goal] = ns.Router.Plan(node, goal, net) or false end
  return cache.routes[goal] or nil
end

local function hearthLeg(legs, net)
  local hearth = ns.Hearth and ns.Hearth.Get()
  if not hearth then return nil end
  local cast = ns.Hearth.CAST
  local best, blocked
  for _, leg in ipairs(legs) do
    if leg.route.seconds >= cast + HEARTH_MIN_SAVING then
      local via = viaHearth(net, hearth.node, leg.stop.node)
      local saves = via and leg.route.seconds - (cast + via.seconds) or 0
      local wait = math.max(0, hearth.readyIn - leg.at)
      if saves - wait >= HEARTH_MIN_SAVING then
        if not best or saves - wait > best.saves then best = { leg = leg, via = via, saves = saves - wait, wait = wait } end
      elseif saves >= HEARTH_MIN_SAVING and (not blocked or saves > blocked.saves) then
        blocked = { stop = leg.stop, label = hearth.node.label, saves = saves, readyIn = wait, cooldown = true }
      end
    end
  end
  if not best then return blocked end
  local leg = best.leg
  local steps = { { mode = "hearth", from = leg.from, to = hearth.node, seconds = cast + best.wait } }
  -- Copies: the cached route is shared, and the plan marks its last step.
  for _, step in ipairs(best.via.steps) do
    local copy = {}
    for k, v in pairs(step) do copy[k] = v end
    steps[#steps + 1] = copy
  end
  if #best.via.steps == 0 then
    -- The inn is the stop: a step to carry its action.
    steps[#steps + 1] = { mode = "walk", from = hearth.node, to = leg.stop.node, seconds = 0 }
  end
  leg.route = { steps = steps, seconds = cast + best.wait + best.via.seconds }
  return { stop = leg.stop, label = hearth.node.label, saves = best.saves }
end

---------------------------------------------------------------- stop kinds

-- Stop kinds that wait for something at the stop (besides a quest's own).
local WAITS = { talk = true, train = true, explore = true, enter = true, learn = true }

-- Every stop kind a journey can hold, for code that builds stops (Trainers
-- falls back to a talk stop where `learn` is missing).
Journey.STOP_KINDS = { pickup = true, complete = true, turnin = true, item = true, manual = true,
  talk = true, train = true, explore = true, enter = true, learn = true }

-- What a stop says when its definition gives no text.
function Journey.DefaultText(stop)
  local action, label = stop.action, stop.node and stop.node.label
  local kind = action and action.kind
  if kind == "explore" then
    return "Explore " .. (action.mapID and ns.MapName(action.mapID) or label or "the zone")
  elseif kind == "enter" then
    return "Enter " .. (action.dungeon or label or "the dungeon")
  elseif kind == "learn" then
    return "Train your new spells" .. (action.npc and (" at " .. action.npc) or "")
  elseif kind == "talk" then
    return "Talk to " .. (action.npc or "them")
  end
  return label and ("Go to " .. label) or nil
end

-- The dungeon an older `finish` stop leads into ("Enter The Deadmines"), or nil.
local function dungeonOf(stop)
  local name = stop.text and stop.text:match("^Enter (.+)$")
  if not name and stop.node and stop.node.label and stop.node.label:find(" entrance$") then
    name = stop.node.label:gsub(" entrance$", "")
  end
  return name
end

-- An older definition's `finish` becomes an ordinary stop that comes after the
-- stops defined with it; a dungeon entrance gets the `enter` kind, so it is
-- done when you load into the dungeon, not on reaching its door.
local function adoptFinish(def)
  local finish = def.finish
  if not finish then return end
  def.finish = nil
  def.stops = def.stops or {}
  for _, stop in ipairs(def.stops) do
    if stop == finish then return end
  end
  if not finish.action then
    local dungeon = dungeonOf(finish)
    if dungeon then finish.action = { kind = "enter", dungeon = dungeon } end
  end
  local after, seen = {}, {}
  for _, s in ipairs(finish.after or {}) do
    after[#after + 1], seen[s] = s, true
  end
  for _, s in ipairs(def.stops) do
    if not seen[s] then after[#after + 1] = s end
  end
  finish.after = #after > 0 and after or nil
  def.stops[#def.stops + 1] = finish
end

---------------------------------------------------------------- planning

-- Plans a journey from `start`. Returns
--   { title, kind, icon, def, root, stops = ordered stops, skipped = unreachable stops,
--     steps = route steps (the last step of each leg carries .stop), seconds }
-- where seconds counts travel and any waits for a cleared camp to respawn.
-- or nil when no stop is reachable. `root` is the original definition, kept
-- across re-plans so the overview can show stops already done; the journey's
-- kind and icon live on it too.
function Journey.Plan(start, def, net)
  net = net or ns.Network.Build()
  adoptFinish(def)
  local root = def.root or def
  if root ~= def then adoptFinish(root) end
  def.kind, def.icon = def.kind or root.kind, def.icon or root.icon
  root.kind, root.icon = root.kind or def.kind, root.icon or def.icon
  for _, stop in ipairs(def.stops or {}) do
    stop.text = stop.text or Journey.DefaultText(stop)
    resolve(stop, start)
  end
  local ordered = root.manual and manualOrder(start, def.stops or {}, net) or orderStops(start, def.stops or {}, net)
  -- `first`: the stop you're doing now (another quest's objectives, on the
  -- way), when nothing it needs is still open.
  for i, stop in ipairs(ordered) do
    if stop == def.first and i > 1 then
      local candidate = { stop }
      for _, s in ipairs(ordered) do
        if s ~= stop then candidate[#candidate + 1] = s end
      end
      local inPlan = {}
      for _, s in ipairs(ordered) do inPlan[s] = true end
      if validOrder(candidate, inPlan) then ordered = candidate end
      break
    end
  end
  if root.manual then
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
  end

  -- Objectives in several areas: the one least out of the way between the
  -- stops either side of it.
  local previous = start
  for i, stop in ipairs(ordered) do
    if stop.resolve and stop.resolve.kind == "objectives" then
      local node = Journey.PickArea(stop, previous, ordered[i + 1] and ordered[i + 1].node)
      if node then stop.node = node end
    end
    previous = stop.node or previous
  end

  local journey = { title = def.title, kind = def.kind, icon = def.icon, def = def, root = root, stops = {},
    skipped = {}, steps = {}, seconds = 0 }
  local legs, from, clock = {}, start, 0
  for _, stop in ipairs(ordered) do
    local route = stop.node and ns.Router.Plan(from, stop.node, net)
    if route then
      legs[#legs + 1] = { from = from, stop = stop, route = route, at = clock }
      clock = math.max(clock + route.seconds, Journey.RespawnIn(stop))
      from = stop.node
    else
      journey.skipped[#journey.skipped + 1] = stop
    end
  end
  journey.hearth = hearthLeg(legs, net)

  for _, leg in ipairs(legs) do
    local stop, route = leg.stop, leg.route
    local steps = route.steps
    if #steps == 0 then
      -- Already standing at the stop: keep a step so its action still shows.
      steps = { { mode = "walk", from = leg.from, to = stop.node, seconds = 0 } }
    end
    for i, step in ipairs(steps) do
      if i == #steps then step.stop = stop end
      journey.steps[#journey.steps + 1] = step
    end
    -- Getting to a camp before it respawns means waiting there.
    journey.seconds = math.max(journey.seconds + route.seconds, Journey.RespawnIn(stop))
    journey.stops[#journey.stops + 1] = stop
  end
  if #journey.stops == 0 then return nil end
  return journey
end

local function open(stop)
  return stop and not stop.done and not stop.skipped
end

-- The same journey from here, without the stops already done or dropped. The
-- original plan (root) is the source, so stops added since are included.
-- `first`: a stop to put first when it can be (the one you're doing now).
function Journey.Replan(journey, start, net, first)
  local root = journey.root or journey.def
  local remaining = {}
  for _, stop in ipairs(root.stops or {}) do
    if open(stop) then remaining[#remaining + 1] = stop end
  end
  return Journey.Plan(start, { title = root.title, kind = root.kind, icon = root.icon, stops = remaining, root = root,
    first = first }, net)
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
  local order, from, to = {}, nil, nil
  for _, s in ipairs(journey.stops) do
    if open(s) then
      order[#order + 1] = s
      if s == stop then from = #order end
      if s == target then to = #order end
    end
  end
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

-- Puts an open stop after the next one in the current plan that doesn't need
-- it (the directions box's move on: do that one first). In a journey you
-- ordered yourself it moves there (Journey.Move); otherwise it becomes a rule
-- for the plans after (stop.later), so the rest is still ordered for you.
-- Returns the stop it now comes after, or nil when there's none. Re-plan
-- afterwards.
function Journey.Postpone(journey, stop)
  local root = journey.root or journey.def
  if not open(stop) then return nil end
  -- Your newest choice wins: stops you put after this one before needn't wait for it now.
  local waived = {}
  for _, s in ipairs(root.stops or {}) do
    for i = #(s.later or {}), 1, -1 do
      if s.later[i] == stop then
        waived[#waived + 1] = s
        table.remove(s.later, i)
      end
    end
    if s.later and #s.later == 0 then s.later = nil end
  end
  local target = Journey.PostponeAfter(journey, stop)
  if not target then
    for _, s in ipairs(waived) do
      s.later = s.later or {}
      table.insert(s.later, stop)
    end
  end
  return target
end

function Journey.PostponeAfter(journey, stop)
  local root = journey.root or journey.def
  local needs, seen = { [stop] = true }, false
  for _, s in ipairs(journey.stops) do
    if s == stop then
      seen = true
    elseif seen and open(s) then
      local dependent = false
      for _, before in ipairs(prerequisites(s)) do
        if needs[before] then dependent = true end
      end
      if dependent then
        needs[s] = true
      else
        if root.manual then
          if not Journey.Move(journey, stop, s) then return nil end
        else
          stop.later = stop.later or {}
          table.insert(stop.later, s)
        end
        return s
      end
    end
  end
  return nil
end

-- A journey's open stops as plain stops to add elsewhere (a dungeon entrance
-- keeps its `after`, so it still comes after the stops planned with it).
function Journey.OpenStops(journey)
  local root = journey.root or journey.def or journey
  local out = {}
  for _, stop in ipairs(root.stops or {}) do
    if open(stop) then out[#out + 1] = stop end
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
  return out
end

-- Stop that a step arrives at, if it still waits for something there (a
-- quest action, someone to talk to, a zone or dungeon to enter, spells to learn).
function Journey.PendingAction(step)
  local stop = step and step.stop
  local action = stop and stop.action
  return action and (action.questID or WAITS[action.kind]) and not stop.done and not stop.skipped and stop or nil
end

function Journey.StopsDone(journey)
  local done = 0
  for _, stop in ipairs(journey.stops) do
    if stop.done and not stop.passed then done = done + 1 end
  end
  return done
end

-- Stops done and stops in all, over the whole journey (the current plan and
-- the stops done before it was planned again), skipped ones left out: the
-- one count the directions box, the overview and the home screen share.
function Journey.Progress(journey)
  local done, total = 0, 0
  for _, stop in ipairs(Journey.AllStops(journey)) do
    if not (stop.skipped or stop.passed) then
      total = total + 1
      if stop.done then done = done + 1 end
    end
  end
  return done, total
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
  return node and { mapID = node.mapID, x = node.x, y = node.y, label = node.label, object = node.object, npc = node.npc }
end

local function loadNode(saved)
  local node = saved and ns.Geo.Node(saved.mapID, saved.x, saved.y, saved.label)
  if node then node.object, node.npc = saved.object, saved.npc end
  return node
end

-- A plain-table copy of a journey's original definition for SavedVariables.
function Journey.Save(journey)
  local root = journey.root or journey.def
  local index = {}
  for i, stop in ipairs(root.stops or {}) do index[stop] = i end
  local function save(stop)
    local after, later = {}, {}
    for _, before in ipairs(stop.after or {}) do after[#after + 1] = index[before] end
    for _, before in ipairs(stop.later or {}) do later[#later + 1] = index[before] end
    return { node = saveNode(stop.node), text = stop.text, giver = stop.giver, npc = stop.npc, action = stop.action, resolve = stop.resolve,
      done = stop.done, passed = stop.passed, skipped = stop.skipped, worked = stop.worked, after = #after > 0 and after or nil,
      later = #later > 0 and later or nil }
  end
  local saved = { title = root.title, kind = root.kind, icon = root.icon, manual = root.manual, stops = {} }
  for i, stop in ipairs(root.stops or {}) do saved.stops[i] = save(stop) end
  return saved
end

-- The definition back from Journey.Save; plan it with Journey.Plan. A save
-- from before dungeon entrances were stops (`finish`) still loads.
-- Names that say nothing about the journey (older saves used them for any
-- journey that had gained stops).
local GENERIC_TITLES = { ["Your journey"] = true, ["Your trip"] = true }
function Journey.IsGenericTitle(title)
  return title == nil or title == "" or GENERIC_TITLES[title] == true
end

-- A name from what a journey holds: its quests ("The Perfect Stout", "The
-- Perfect Stout and 2 more quests"), else its first open stop ("Repair at
-- Thrawn Boltar"). For journeys you put together yourself, out of detours.
function Journey.NameFor(def)
  local names, seen, firstText = {}, {}, nil
  for _, stop in ipairs(def and def.stops or {}) do
    if not (stop.done or stop.skipped) then
      local id = stop.action and stop.action.questID
      if id then
        if not seen[id] then
          seen[id] = true
          local q = ns.Quests and ns.Quests.Quest and ns.Quests.Quest(id)
          local name = q and q.name or (ns.QuestLog and ns.QuestLog.Title and ns.QuestLog.Title(id))
          if name then names[#names + 1] = name end
        end
      elseif not firstText then
        firstText = stop.text or (stop.node and stop.node.label)
      end
    end
  end
  if #names == 1 then return names[1] end
  if #names > 1 then
    return string.format("%s and %d more quest%s", names[1], #names - 1, #names == 2 and "" or "s")
  end
  return firstText or "Your journey"
end

function Journey.Load(saved)
  local def = { title = saved.title, kind = saved.kind, icon = saved.icon, manual = saved.manual, stops = {} }
  local function load(s)
    return { node = loadNode(s.node), text = s.text, giver = s.giver, npc = s.npc, action = s.action, resolve = s.resolve, done = s.done,
      passed = s.passed, skipped = s.skipped, worked = s.worked }
  end
  for i, s in ipairs(saved.stops or {}) do def.stops[i] = load(s) end
  for i, s in ipairs(saved.stops or {}) do
    for _, key in ipairs({ "after", "later" }) do
      if s[key] then
        def.stops[i][key] = {}
        for _, j in ipairs(s[key]) do table.insert(def.stops[i][key], def.stops[j]) end
      end
    end
  end
  if saved.finish then
    def.finish = load(saved.finish)
    adoptFinish(def)
  end
  if Journey.IsGenericTitle(def.title) then def.title = Journey.NameFor(def) end
  return def
end

-- The open part of a loaded definition, planned from here.
function Journey.Resume(def, start, net)
  Journey.SyncQuestState(def)
  local remaining = {}
  for _, stop in ipairs(def.stops) do
    if open(stop) and stop.node then remaining[#remaining + 1] = stop end
  end
  if #remaining == 0 then return nil end
  return Journey.Plan(start, { title = def.title, kind = def.kind, icon = def.icon, stops = remaining, root = def }, net)
end

-- Whether a loaded definition still has a stop to do (placed on the map or not).
function Journey.HasOpenStops(def)
  for _, stop in ipairs(def.stops or {}) do
    if open(stop) then return true end
  end
  return false
end
