local _, ns = ...

-- "For you" page, the panel's first tab: a handful of things to do next for
-- this character, right now. Needs come first when they are due (spells you
-- can train and afford, repairs, ammo, food, a flight path close by);
-- everything else is ranked by estimated XP per minute: quest hubs, and
-- dungeons with their quests. Where a need is on the way to the best option,
-- both become one journey ("Train in Stormwind, then pick up 3 quests in ...").
--
-- XP comes from QuestieDB's quest XP table (Support.Get("QuestXP").db). Without
-- it, options are ranked by quests per hour weighted by level fit, and the
-- summary line says so. Without QuestieDB there are no hubs or dungeon quests,
-- so dungeons are ranked by level fit and travel time, as on the Find page.
--
-- Quests already in your log count too, at their full XP; only the time left
-- for them is counted. Ones ready to hand in are trips of their own ("Hand in
-- 3 quests in Lakeshire") or ride along with the quest hub where you hand them
-- in; unfinished ones close together are one whole-quest trip ("Finish 2
-- quests near Lakeshire"); a dungeon's quests in your log count toward it.

-- Shown as Adventure Guide style cards (UI/Cards.lua) on a wider panel.
local ForYou = { id = "foryou", label = "For you", order = 10, searchable = false, layout = "cards", width = 730 }
ns.ForYou = ForYou

local SECONDS_PER_QUEST = 300   -- time to do one quest, on top of the trip
local MAX_RESULTS = 7           -- rows the panel shows
local MIN_XP_ROWS = 3           -- XP options listed however many needs are due
local CACHE_SECONDS = 5         -- a refresh is reused this long (cleared early on data or zone changes)
local MAX_LEVEL = 60            -- Forever's level cap: quests give no XP there
local LOW_AMMO = 200            -- arrows or bullets left
local LOW_FOOD = 5              -- food and drink items left in your bags
local FOOD_FROM_LEVEL = 6       -- below this, eating and drinking between fights rarely matters
local FLIGHT_NEAR_SECONDS = 180 -- an undiscovered flight path this close (by route) is worth the detour
local COMBINE_SLACK = 30        -- seconds a combined journey may add over the two trips apart
local MAX_PICKUPS = 4           -- dungeon quest givers visited on the way to the entrance
local HANDIN_SECONDS = 30       -- handing in one quest, on top of the trip
local MIN_SHARE_LEFT = 0.25     -- an unfinished quest takes at least this share of SECONDS_PER_QUEST
local FINISH_RADIUS = 600       -- yards between objective areas done in one "Finish" trip
local MAX_FINISH = 3            -- log quests per "Finish" trip (up to two stops each)
local FINISH_TRIPS = 3          -- nearest groups of unfinished log quests offered
local HANDIN_AT_HUB = 350       -- yards: hand-ins this close to a hub's quest giver join the hub

local GOLD = { r = 1, g = 0.82, b = 0 }
local GREY = { r = 0.6, g = 0.6, b = 0.6 }

-- Lower comes first among needs.
local PRIORITY = { repair = 1, train = 2, ammo = 3, food = 4, flight = 5 }

local cache, summary
ForYou.runs = 0 -- refreshes computed, not served from the cache

---------------------------------------------------------------- helpers

local function plural(n, word)
  return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local function formatNumber(n)
  local s = tostring(math.floor(n + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (s:gsub("^,", ""))
end

local function seconds(route)
  return route and route.seconds or math.huge
end

local function capitalize(text)
  return text:sub(1, 1):upper() .. text:sub(2)
end

-- A provider error leaves its part out of the page instead of blanking it.
local function try(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if ok then return a, b end
  geterrorhandler()(a)
  return nil
end

-- Runs a provider, reporting an error instead of breaking the page.
local function run(provider)
  local ok, results, _, net = pcall(provider)
  if not ok then
    geterrorhandler()(results)
    return {}
  end
  return results or {}, net
end
-- "Redridge Mountains" from "Redridge Mountains  ·  2 quests for you".
local function firstPart(text)
  local i = text:find("  ·  ", 1, true)
  return i and text:sub(1, i - 1) or text
end

local function placeName(node, fallback)
  return ns.Places.NameFor(node) or fallback or ns.MapName(node.mapID)
end

-- Journeys mark their stops done, so each journey gets its own copies.
local function copyStop(stop)
  local c = {}
  for k, v in pairs(stop) do c[k] = v end
  return c
end

-- Copies of a list of stops, with `after` pointing at the copies.
local function copyStops(stops, into)
  into = into or {}
  local copies = {}
  for _, s in ipairs(stops) do
    copies[s] = copyStop(s)
    into[#into + 1] = copies[s]
  end
  for _, s in ipairs(stops) do
    if s.after then
      local after = {}
      for _, before in ipairs(s.after) do after[#after + 1] = copies[before] or before end
      copies[s].after = after
    end
  end
  return into
end

local function zoneName(node)
  return ns.MapName((ns.Geo.ZonePoint(node)))
end

---------------------------------------------------------------- quest XP

-- QuestieDB's quest XP: [questID] = { questLevel, xp }, the full reward before
-- the level penalty. It is Era data (the Forever file matches Era's), so
-- Forever-only quests are missing; those get the average XP for their level.
local function xpTable()
  local lib = _G.LibQuestieDB
  if not (ns.Questie.Available() and type(lib) == "table" and type(lib.Support) == "table"
    and type(lib.Support.Get) == "function") then return nil end
  local ok, module = pcall(lib.Support.Get, "QuestXP")
  local db = ok and type(module) == "table" and module.db
  if type(db) ~= "table" or next(db) == nil then return nil end
  return db
end

local function xpEntry(db, questID)
  local e = db[questID]
  if type(e) == "table" then return tonumber(e[1]), tonumber(e[2]) end
  if type(e) == "number" then return nil, e end
  return nil, nil
end

local averages = setmetatable({}, { __mode = "k" }) -- [db] = { [questLevel] = average xp }

local function averageXP(db, level)
  local avg = averages[db]
  if not avg then
    local sum, count = {}, {}
    for id in pairs(db) do
      local l, xp = xpEntry(db, id)
      if l and xp and l > 0 and xp > 0 then
        sum[l], count[l] = (sum[l] or 0) + xp, (count[l] or 0) + 1
      end
    end
    avg = {}
    for l, s in pairs(sum) do avg[l] = s / count[l] end
    averages[db] = avg
  end
  for d = 0, MAX_LEVEL do
    local v = avg[level - d] or avg[level + d]
    if v then return v end
  end
  return 0
end

-- Share of a quest's XP you still get: all of it up to 5 levels under you,
-- then 20% less per level, never under 10% (the vanilla rule).
local function levelFactor(questLevel, level)
  return math.max(1, math.min(10, 2 * (questLevel - level) + 20)) / 10
end

-- XP for one quest (with data), else its level fit as a share of one quest.
local function questValue(q, ctx)
  local questLevel, xp
  if ctx.db then questLevel, xp = xpEntry(ctx.db, q.id) end
  if not questLevel or questLevel <= 0 then questLevel = q.level or ctx.level end
  local factor = levelFactor(questLevel, ctx.level)
  if not ctx.xpMode then return factor, false end
  local estimated = xp == nil
  if estimated then xp = averageXP(ctx.db, questLevel) end
  return xp * factor, estimated
end

-- value: XP (or quests) for the option; rate: per minute, trip included. A
-- quest takes SECONDS_PER_QUEST unless it says otherwise (log quests: q.seconds).
local function score(option, ctx)
  option.value, option.estimated = 0, 0
  option.seconds = option.trip
  for _, q in ipairs(option.quests) do
    local v, estimated = questValue(q, ctx)
    q.value = v
    option.value = option.value + v
    option.seconds = option.seconds + (q.seconds or SECONDS_PER_QUEST)
    if estimated then option.estimated = option.estimated + 1 end
  end
  option.rate = option.value / math.max(option.seconds / 60, 1)
end

local function rateText(option, ctx)
  if ctx.xpMode then return string.format("~%s XP/min", formatNumber(option.rate)) end
  return string.format("~%.1f quests/h", option.rate * 60)
end

---------------------------------------------------------------- needs

local function trainingNeed(ctx)
  local s = ns.Trainers.SpellSummary()
  if not (s and s.trainable > 0) then return nil end
  local spells = plural(s.trainable, "new spell")
  if GetMoney() < s.cost then
    ctx.notes[#ctx.notes + 1] = string.format("%s to train once you have %s.", capitalize(spells),
      ns.FormatMoney(s.cost))
    return nil
  end
  local best = (try(ns.Trainers.Results) or {})[1]
  if not (best and best.route) then return nil end
  local place = placeName(best.goal, best.zone)
  return {
    kind = "train", only = "Train only",
    title = string.format("Train %s in %s", spells, place),
    zone = best.zone, goal = best.goal, route = best.route,
    why = string.format("%s for %s", spells, ns.FormatMoney(s.cost)),
    rank = string.format("Needs come first: you can train and afford %s (%s).", spells, ns.FormatMoney(s.cost)),
    details = { { text = "Trainer: " .. best.title } },
    stop = { node = best.goal, text = "Train your new spells at " .. best.title, phrase = "train in " .. place },
  }
end

-- Food and drink in your bags (any item the Vendors page calls food), or nil
-- when the bag API is missing.
local function bagFoodCount()
  local container = C_Container
  local numSlots = container and container.GetContainerNumSlots or GetContainerNumSlots
  if type(numSlots) ~= "function" then return nil end
  local count = 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, numSlots(bag) or 0 do
      local itemID, stack
      if container and container.GetContainerItemInfo then
        local info = container.GetContainerItemInfo(bag, slot)
        if type(info) == "table" then itemID, stack = info.itemID, info.stackCount end
      elseif GetContainerItemInfo then
        local _, n, _, _, _, _, _, _, _, id = GetContainerItemInfo(bag, slot)
        itemID, stack = id, n
      end
      if itemID and ns.Vendors.GoodsKind(itemID) == "food" then count = count + (stack or 1) end
    end
  end
  return count
end

-- Arrows or bullets left; 0 with nothing in the ammo slot.
local function ammoLeft()
  local ok, slot = pcall(GetInventorySlotInfo or error, "AmmoSlot")
  if not (ok and slot) then return nil end
  if not (GetInventoryItemID and GetInventoryItemID("player", slot)) then return 0 end
  local n = GetInventoryItemCount and GetInventoryItemCount("player", slot)
  return type(n) == "number" and n or nil
end

local VENDOR_VERB = { repair = "repair", ammo = "buy ammo", food = "buy food & drink" }

local function vendorWhy(need, p, left)
  if need == "repair" then
    if (p.durability or 1) <= 0 then return "some gear is broken" end
    return string.format("gear at %d%%", math.floor(p.durability * 100 + 0.5))
  end
  if left == 0 then return need == "ammo" and "no ammo left" or "no food left" end
  return string.format("%d %s left", left, need == "ammo" and "ammo" or "food & drink")
end

-- Repairs (gear at 50% or lower), ammo and food when running low: the fastest
-- vendor for each; a vendor that covers several gets one row.
local function vendorNeeds(ctx)
  local p = ns.Vendors.Needs()
  local due = {}
  if p.urgent then due.repair = true end
  if p.ammo then
    local left = ammoLeft()
    if left and left < LOW_AMMO then due.ammo = left end
  end
  local _, class = UnitClass("player")
  if class ~= "MAGE" and ctx.level >= FOOD_FROM_LEVEL then
    local food = bagFoodCount()
    if food and food < LOW_FOOD then due.food = food end
  end
  if next(due) == nil then return {} end

  local results = try(ns.Vendors.Results) or {}
  local rows, byVendor = {}, {}
  for _, need in ipairs({ "repair", "ammo", "food" }) do
    if due[need] ~= nil then
      local best
      for _, r in ipairs(results) do
        if r.covers and r.covers[need] and r.route and seconds(r.route) < seconds(best and best.route) then best = r end
      end
      if best then
        local row = byVendor[best]
        if not row then
          row = { vendor = best, needs = {} }
          byVendor[best] = row
          rows[#rows + 1] = row
        end
        row.needs[#row.needs + 1] = need
      end
    end
  end

  local out = {}
  for _, row in ipairs(rows) do
    local r, verbs, whys = row.vendor, {}, {}
    local name = r.goal.label or r.title
    for _, need in ipairs(row.needs) do
      verbs[#verbs + 1] = VENDOR_VERB[need]
      whys[#whys + 1] = vendorWhy(need, p, due[need])
    end
    local what = table.concat(verbs, " and ")
    local first = row.needs[1]
    out[#out + 1] = {
      kind = first, only = (#row.needs == 1 and first == "repair") and "Repair only" or "Shop only",
      title = string.format("%s at %s", capitalize(what), name),
      zone = ns.MapName(r.goal.mapID), goal = r.goal, route = r.route,
      why = table.concat(whys, ", "),
      rank = "Needs come first: " .. table.concat(whys, ", ") .. ".",
      details = r.details,
      stop = { node = r.goal, text = string.format("%s at %s", capitalize(what), name),
        phrase = string.format("%s at %s", what, name) },
    }
  end
  return out
end

-- C_TaxiMap node.faction: 1 = Horde, 2 = Alliance, anything else is neutral.
local OTHER_FACTION = { Alliance = 1, Horde = 2 }

-- The nearest flight path you haven't discovered, if it is a short trip.
local FLIGHT_MASTER_RADIUS = 120 -- yards from a flight path's map position

local function flightNeed(ctx, start, net)
  local continent = ns.Geo.Continents()[start.instance]
  -- Only where we know your flight paths; otherwise every one looks new.
  if not (continent and ns.Harvest.FlightsKnownOn(continent)) then return nil end
  local other = OTHER_FACTION[UnitFactionGroup("player")]
  local reach = FLIGHT_NEAR_SECONDS * ns.Router.RUN_SPEED / ns.Router.WALK_FACTOR
  local best, bestDistance
  for _, t in ipairs(C_TaxiMap.GetTaxiNodesForMap(continent) or {}) do
    if t.position and t.name and not ns.charDB.knownTaxi[t.nodeID] and t.faction ~= other then
      local node = ns.Geo.Node(continent, t.position.x, t.position.y, t.name)
      local d = node and ns.Geo.Distance(start, node)
      if d and d <= reach and d < (bestDistance or math.huge) then best, bestDistance = node, d end
    end
  end
  local route = best and ns.Router.Plan(start, best, net)
  if not route or route.seconds > FLIGHT_NEAR_SECONDS then return nil end
  local town = best.label:match("^([^,]+)") or best.label
  -- Head for the flight master's own spot when Wayfinder has recorded them.
  local master, talkTo
  for _, npc in pairs(ns.Harvest.AllNPCs()) do
    if npc.kinds.flightMaster then
      local node = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.name)
      if node and ns.Geo.Distance(node, best) <= FLIGHT_MASTER_RADIUS
        and (not master or ns.Geo.Distance(node, best) < ns.Geo.Distance(master, best)) then
        master, talkTo = node, npc.name
      end
    end
  end
  local stopNode = master or best
  if master then route = ns.Router.Plan(start, master, net) or route end
  return {
    kind = "flight", only = "Flight only",
    title = string.format("Learn the %s flight path", town),
    zone = ns.MapName(best.mapID), goal = stopNode, route = route,
    why = "not discovered yet",
    rank = "Needs come first: a flight path you haven't discovered is close by, and later trips get faster.",
    details = {},
    stop = { node = stopNode, text = string.format("Talk to %s to learn %s",
        talkTo and (talkTo .. ", the flight master,") or "the flight master", town),
      phrase = string.format("learn the %s flight path", town) },
  }
end

---------------------------------------------------------------- quest log

-- Share of a quest still to do, from its objectives ("3/8 Murloc Forager
-- slain"): 1 without objective data, never under MIN_SHARE_LEFT (finding the
-- last mobs, walking back out).
local function shareLeft(questID)
  local objectives = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(questID)
  if type(objectives) ~= "table" or #objectives == 0 then return 1 end
  local done = 0
  for _, o in ipairs(objectives) do
    local have, need = tonumber(o.numFulfilled), tonumber(o.numRequired)
    if not (need and need > 0) and type(o.text) == "string" then
      local a, b = o.text:match("(%d+)%s*/%s*(%d+)")
      have, need = tonumber(a), tonumber(b)
    end
    if o.finished then
      done = done + 1
    elseif need and need > 0 then
      done = done + math.min(have or 0, need) / need
    end
  end
  return math.max(MIN_SHARE_LEFT, 1 - done / #objectives)
end

-- Quests in your log: { id, row (QuestieDB), name, level, complete, left }.
local function readLog()
  local out = {}
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return out end
  for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
    local info = C_QuestLog.GetInfo(i)
    local id = info and not info.isHeader and not info.isHidden and info.questID
    if id then
      local row = ns.Questie.Quest(id)
      local complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) and true or false
      out[#out + 1] = { id = id, row = row, name = row and row.name or info.title,
        level = ns.Questie.QuestLevel(id) or info.level, complete = complete,
        left = complete and 0 or shareLeft(id) }
    end
  end
  return out
end

-- A log quest as an option's quest: full XP, only the time left counted.
local function logQuest(e)
  return { id = e.id, name = e.name, level = e.level, inLog = true, handin = e.complete, left = e.left,
    seconds = e.complete and HANDIN_SECONDS or SECONDS_PER_QUEST * e.left }
end

-- Quests done inside a dungeon count toward its option instead. Dungeons.lua
-- caches the dungeon finder list on first use, so not before the API exists.
local function dungeonQuest(row)
  if not row or type(GetLFGDungeonInfo) ~= "function" then return false end
  local area = tonumber(row.zoneOrSort)
  return area ~= nil and area > 0 and ns.Dungeons.ForArea(area) ~= nil
end

-- Quests ready to hand in, grouped by where you hand them in: their
-- finishers clustered like quest hubs, then merged by place.
local function handinOptions(ctx, start, net)
  local givers, order = {}, {}
  for _, e in ipairs(ctx.log) do
    if e.complete then
      local name, node, distance = ns.Questie.QuestFinisher(e.id, start)
      if node then
        local key = string.format("%s@%d:%.4f:%.4f", name or "?", node.mapID, node.x, node.y)
        local g = givers[key]
        if not g then
          g = { name = name, node = node, distance = distance, quests = {} }
          givers[key] = g
          order[#order + 1] = g
        end
        g.quests[#g.quests + 1] = e
      else
        ctx.unplaced = ctx.unplaced + 1
      end
    end
  end
  if #order == 0 then return {} end
  table.sort(order, function(a, b) return a.distance < b.distance end)

  local named, byPlace = {}, {}
  for _, hub in ipairs(ns.Questie.Cluster(order, math.huge)) do
    local place = ns.Places.NameFor(hub.anchor.node)
    local key = place and (place .. "@" .. hub.anchor.node.mapID)
    if key and byPlace[key] then
      for _, g in ipairs(hub.givers) do table.insert(byPlace[key].givers, g) end
    else
      hub.place = place
      named[#named + 1] = hub
      if key then byPlace[key] = hub end
    end
  end

  local out = {}
  for _, hub in ipairs(named) do
    local quests, stops = {}, {}
    for _, g in ipairs(hub.givers) do
      for _, e in ipairs(g.quests) do
        local q = logQuest(e)
        q.giver = g.name
        quests[#quests + 1] = q
        stops[#stops + 1] = { node = g.node, group = "turnin", action = { kind = "turnin", questID = e.id },
          text = string.format("Hand in %s to %s", e.name or ("quest " .. e.id), g.name or "the quest giver") }
      end
    end
    local goal = hub.anchor.node
    local route = ns.Router.Plan(start, goal, net)
    if route then
      local where = hub.place and ("in " .. hub.place) or ("to " .. (hub.anchor.name or "the quest giver"))
      out[#out + 1] = {
        kind = "handin", place = hub.place,
        title = capitalize(string.format("hand in %s %s", plural(#quests, "quest"), where)),
        zone = zoneName(goal), goal = goal, route = route, trip = route.seconds,
        quests = quests, stops = stops, handinStops = stops,
      }
    end
  end
  return out
end

-- Unfinished log quests close together as one whole-quest trip ("Finish 2
-- quests near Lakeshire"), nearest first. Dungeon quests count toward their
-- dungeon; quests without a known objective area are left out.
local function finishOptions(ctx, start, net)
  local open = {}
  for _, e in ipairs(ctx.log) do
    if not e.complete and not dungeonQuest(e.row) then
      local node = ns.Questie.ObjectiveNode(e.id, start)
      if node then
        open[#open + 1] = { entry = e, node = node, distance = ns.Geo.Distance(start, node) }
      else
        ctx.unplaced = ctx.unplaced + 1
      end
    end
  end
  table.sort(open, function(a, b) return a.distance < b.distance end)

  local groups = {}
  for _, o in ipairs(open) do
    local joined
    for _, g in ipairs(groups) do
      if #g < MAX_FINISH and ns.Geo.Distance(g[1].node, o.node) <= FINISH_RADIUS then
        g[#g + 1] = o
        joined = true
        break
      end
    end
    if not joined and #groups < FINISH_TRIPS then groups[#groups + 1] = { o } end
  end

  local out = {}
  for _, g in ipairs(groups) do
    local anchor = g[1].node
    local route = ns.Router.Plan(start, anchor, net)
    if route then
      local quests, stops = {}, {}
      for _, o in ipairs(g) do
        quests[#quests + 1] = logQuest(o.entry)
        for _, s in ipairs(ns.Journey.QuestStops(o.entry.id, start)) do stops[#stops + 1] = s end
      end
      local place = ns.Places.NameFor(anchor)
      local where = place and ("near " .. place) or ("in " .. zoneName(anchor))
      out[#out + 1] = {
        kind = "finish", title = capitalize(string.format("finish %s %s", plural(#quests, "quest"), where)),
        zone = zoneName(anchor), goal = anchor, route = route, trip = route.seconds,
        quests = quests, stops = stops,
      }
    end
  end
  return out
end

---------------------------------------------------------------- XP options

local function hubOptions()
  local out = {}
  for _, r in ipairs(run(ns.QuestHubs.Results)) do
    if r.goal and r.route and r.quests then
      local quests = r.quests
      local where = r.place and ("in " .. r.place) or ("near " .. (r.anchorName or "?"))
      local doing = string.format("pick up %s %s", plural(#quests, "quest"), where)
      local names = {}
      for _, q in ipairs(quests) do names[#names + 1] = q.name or ("quest " .. q.id) end
      out[#out + 1] = {
        kind = "hub", title = capitalize(doing), zone = ns.MapName(r.goal.mapID), place = r.place, where = where,
        goal = r.goal, route = r.route, trip = r.route.seconds, quests = quests,
        stops = {},
        finish = { node = r.goal, phrase = doing, text = "Pick up quests here: " .. table.concat(names, ", ") },
      }
    end
  end
  return out
end

-- A hub where you also hand quests in takes them along ("Pick up 3 quests and
-- hand in 2 in Lakeshire"), handing in first. Returns the hand-ins left alone.
local function mergeHandins(hubs, handins)
  local alone = {}
  for _, h in ipairs(handins) do
    local target
    for _, hub in ipairs(hubs) do
      local d = ns.Geo.Distance(h.goal, hub.goal)
      if not hub.handins and ((h.place and h.place == hub.place and d < math.huge) or d <= HANDIN_AT_HUB) then
        target = hub
        break
      end
    end
    if target then
      target.title = capitalize(string.format("pick up %s and hand in %d %s", plural(#target.quests, "quest"),
        #h.quests, target.where))
      target.handins = #h.quests
      for _, q in ipairs(h.quests) do target.quests[#target.quests + 1] = q end
      target.stops, target.handinStops = h.stops, h.stops
    else
      alone[#alone + 1] = h
    end
  end
  return alone
end

-- Dungeons with their quests (available and in your log) as XP options, and
-- the rest in Dungeons' own order (level fit and travel time). Log quests
-- count at full XP with the time left for them; ones ready to hand in are
-- hand-in options instead.
local function dungeonOptions(ctx)
  -- Dungeons.lua caches the dungeon finder list on first use; don't trigger
  -- that before the API exists.
  if type(GetLFGDungeonInfo) ~= "function" then return {}, {} end
  local logged = {}
  for _, e in ipairs(ctx.log) do logged[e.id] = e end
  local withQuests, plain = {}, {}
  for _, r in ipairs(run(ns.Dungeons.Results)) do
    local entry = r.dungeon
    local available, inLog, seen = {}, {}, {}
    local function add(list, q)
      if not seen[q.id] then
        seen[q.id] = true
        list[#list + 1] = q
      end
    end
    for _, q in ipairs(r.quests and r.quests.available or {}) do add(available, q) end
    for _, q in ipairs(r.quests and r.quests.inLog or {}) do
      if not (logged[q.id] and logged[q.id].complete) then add(inLog, q) end
    end
    local quests = {}
    for _, q in ipairs(available) do quests[#quests + 1] = q end
    for _, q in ipairs(inLog) do
      local e = logged[q.id]
      quests[#quests + 1] = { id = q.id, name = q.name, level = q.level, inLog = true, left = e and e.left,
        seconds = e and SECONDS_PER_QUEST * e.left }
    end
    local name = entry and entry.name or r.title
    local option = {
      kind = "dungeon", name = name, raid = entry and entry.raid, result = r,
      title = "Run " .. r.title, zone = r.zone, goal = r.goal, route = r.route, trip = seconds(r.route),
      quests = quests, available = available, inLog = inLog,
    }
    if r.route then
      if #quests > 0 then withQuests[#withQuests + 1] = option else plain[#plain + 1] = option end
    end
  end
  return withQuests, plain
end

-- Pick up the dungeon's quests on the way (nearest givers), finish at the entrance.
local function dungeonJourney(option, ctx, start, net)
  -- Givers are ranked by trip time, not straight distance, so one on another
  -- continent (e.g. Darnassus for Blackfathom Deeps) still counts.
  local pickups = {}
  for _, q in ipairs(option.available) do
    local giver, node = ns.Questie.QuestGiver(q.id, start)
    local route = node and ns.Router.Plan(start, node, net)
    if route then
      pickups[#pickups + 1] = { node = node, seconds = route.seconds, group = "pickup",
        text = string.format("Pick up %s from %s", q.name or ("quest " .. q.id), giver or "?"),
        action = { kind = "pickup", questID = q.id } }
    end
  end
  table.sort(pickups, function(a, b) return a.seconds < b.seconds end)
  while #pickups > MAX_PICKUPS do table.remove(pickups) end
  option.stops = pickups
  option.finish = { node = option.goal, text = "Enter " .. option.name, phrase = "run " .. option.name }
  if #pickups == 0 then return end

  local def = { stops = {}, finish = copyStop(option.finish) }
  for _, s in ipairs(pickups) do def.stops[#def.stops + 1] = copyStop(s) end
  local journey = ns.Journey.Plan(start, def, net)
  if not journey then return end
  option.journey = journey
  option.trip = journey.seconds
  score(option, ctx)
end

-- Hand-ins, unfinished log quests, and a hub with hand-ins: one journey over
-- their stops, ranked again with its real trip time.
local function questJourney(option, ctx, start, net)
  local def = { title = option.title, stops = copyStops(option.stops),
    finish = option.finish and copyStop(option.finish) }
  local journey = ns.Journey.Plan(start, def, net)
  if not journey then return end
  option.journey = journey
  option.trip = journey.seconds
  score(option, ctx)
end

-- "Pick up 2 quests, then run The Deadmines"; pickups in a row are counted.
local function journeyTitle(stops)
  local parts, pickups = {}, 0
  local function flush()
    if pickups > 0 then parts[#parts + 1] = "pick up " .. plural(pickups, "quest") end
    pickups = 0
  end
  for _, stop in ipairs(stops) do
    if stop.group == "pickup" then
      pickups = pickups + 1
    else
      flush()
      parts[#parts + 1] = stop.phrase or stop.text
    end
  end
  flush()
  return capitalize(table.concat(parts, ", then "))
end

-- A due need and the best option in one journey, when the need is on the way:
-- the journey takes no longer than the two trips apart. The option's quests or
-- entrance come last, so you train or shop first, then quest. Hand-ins and
-- unfinished log quests have no fixed end: the need goes wherever it is quickest.
local function combine(need, option, start, net)
  if not (need.stop and (option.finish or #option.stops > 0)) then return nil end
  local needStop = copyStop(need.stop)
  local def = { stops = copyStops(option.stops, { needStop }), finish = option.finish and copyStop(option.finish) }
  local journey = ns.Journey.Plan(start, def, net)
  if not journey or #journey.skipped > 0 then return nil end
  if journey.seconds > seconds(need.route) + option.trip + COMBINE_SLACK then return nil end
  if option.kind == "dungeon" then
    journey.title = journeyTitle(journey.stops)
  else
    local doing = option.title:sub(1, 1):lower() .. option.title:sub(2)
    if journey.stops[1] == needStop then
      journey.title = capitalize(needStop.phrase .. ", then " .. doing)
    elseif journey.stops[#journey.stops] == needStop then
      journey.title = string.format("%s, then %s", option.title, needStop.phrase)
    else
      journey.title = string.format("%s, %s on the way", option.title, needStop.phrase)
    end
  end
  def.title = journey.title
  return journey
end

---------------------------------------------------------------- rows

local function onlyAction(need)
  return { label = need.only, run = function()
    ns.Nav.Start(need.title, need.goal, need.route)
    if ns.Panel.IsShown() then ns.Panel.Toggle() end
  end }
end

local function needRow(need)
  local details = { { text = need.rank, color = GOLD } }
  for _, line in ipairs(need.details or {}) do details[#details + 1] = line end
  return {
    id = "need" .. need.kind, kind = need.kind, title = need.title,
    subtitle = string.format("%s  ·  %s  ·  %s", need.zone, ns.FormatDuration(need.route.seconds), need.why),
    goal = need.goal, route = need.route, details = details,
  }
end

local function logText(q)
  if q.handin then return "  (ready to hand in)" end
  local done = q.left and math.floor((1 - q.left) * 100 + 0.5) or 0
  if done > 0 then return string.format("  (in your log, ~%d%% done)", done) end
  return "  (in your log)"
end

-- New quests, log quests to finish (and their minutes left), and hand-ins.
local function questCounts(option)
  local fresh, logged, handins, left = 0, 0, 0, 0
  for _, q in ipairs(option.quests) do
    if q.handin then
      handins = handins + 1
    elseif q.inLog then
      logged, left = logged + 1, left + (q.seconds or SECONDS_PER_QUEST)
    else
      fresh = fresh + 1
    end
  end
  return fresh, logged, handins, left
end

-- "trip ~4 min + 3 x 5 min per quest + ~4 min left on 2 in your log + 2 x 30 s per hand-in"
local function timeText(option)
  local fresh, logged, handins, left = questCounts(option)
  local parts = { "trip " .. ns.FormatDuration(option.trip) }
  if fresh > 0 then parts[#parts + 1] = string.format("%d x %d min per quest", fresh, SECONDS_PER_QUEST / 60) end
  if logged > 0 then
    parts[#parts + 1] = string.format("%s left on %d in your log", ns.FormatDuration(left), logged)
  end
  if handins > 0 then parts[#parts + 1] = string.format("%d x %d s per hand-in", handins, HANDIN_SECONDS) end
  return table.concat(parts, " + ")
end

local function questLines(details, option, ctx)
  for _, q in ipairs(option.quests) do
    local value = ctx.xpMode and string.format("  -  %s XP", formatNumber(q.value)) or ""
    local who = q.inLog and logText(q) or (q.giver and ("  (" .. q.giver .. ")") or "")
    details[#details + 1] = {
      text = string.format("[%d] %s%s%s", q.level or 0, q.name or ("Quest " .. q.id), value, who),
      color = GetQuestDifficultyColor and q.level and GetQuestDifficultyColor(q.level),
    }
  end
end

-- Hand in only the quests that are ready, leaving the hub's new quests.
local function handinOnly(option)
  return { label = "Hand in only", run = function()
    local start = ns.Geo.PlayerNode()
    local title = string.format("Hand in %s", plural(#option.handinStops, "quest"))
    local journey = start and ns.Journey.Plan(start, { title = title, stops = copyStops(option.handinStops) })
    if not journey then return end
    ns.Nav.StartJourney(journey)
    if ns.Panel.IsShown() then ns.Panel.Toggle() end
  end }
end

local function optionRow(option, rank, total, ctx)
  local count = #option.quests
  local fresh, logged, handins = questCounts(option)
  local amount = ctx.xpMode and (formatNumber(option.value) .. " XP") or plural(count, "quest")
  local details = { {
    text = string.format("#%d of %d by %s: ~%s in %s (%s).", rank, total,
      ctx.xpMode and "XP per minute" or "quests per hour", amount, ns.FormatDuration(option.seconds),
      timeText(option)),
    color = GOLD,
  } }
  if logged + handins > 0 then
    local how = {}
    if handins > 0 then how[#how + 1] = string.format("handing one in takes ~%d s", HANDIN_SECONDS) end
    if logged > 0 then
      how[#how + 1] = string.format("unfinished ones take %d min times the share of objectives left",
        SECONDS_PER_QUEST / 60)
    end
    -- The same on most cards: in the breakdown and tooltip only.
    details[#details + 1] = { text = "Quests in your log count at full XP; " .. table.concat(how, ", ") .. ".",
      color = GREY, more = true }
  end
  if option.estimated > 0 then
    details[#details + 1] = { text = string.format("XP estimated for %s QuestieDB has no XP for.",
      plural(option.estimated, "quest")), color = GREY, more = true }
  end
  if not ctx.xpMode then
    details[#details + 1] = { text = "No quest XP data: quests count by level fit.", color = GREY }
  end
  if option.kind == "dungeon" then
    details[#details + 1] = { text = option.raid and "Raid: needs a raid group." or "Dungeon: bring a group.",
      color = GREY }
  end
  questLines(details, option, ctx)

  local why = { plural(count, "quest") }
  if option.kind == "dungeon" then
    if #option.inLog > 0 then why[1] = why[1] .. string.format(" (%d in your log)", #option.inLog) end
    why[#why + 1] = option.raid and "raid" or "group"
  elseif option.kind == "handin" then
    why[1] = plural(handins, "quest") .. " ready"
  elseif option.kind == "finish" then
    why[1] = plural(logged, "quest") .. " in your log"
  elseif handins > 0 then
    why[1] = string.format("%s + %d to hand in", plural(fresh, "quest"), handins)
  end
  why[#why + 1] = rateText(option, ctx)

  local row = {
    id = option.kind .. (option.name or option.title), kind = option.kind, raid = option.raid, title = option.title,
    subtitle = string.format("%s  ·  %s  ·  %s", firstPart(option.zone),
      ns.FormatDuration(option.trip), table.concat(why, ", ")),
    goal = option.goal, route = option.route, details = details, rate = option.rate,
  }
  if option.journey then
    row.journey = option.journey
    row.title = option.journey.title or journeyTitle(option.journey.stops)
    option.journey.title = row.title
    option.journey.def.title = row.title
  end
  if option.kind == "hub" and option.handinStops then row.actions = { handinOnly(option) } end
  return row
end

-- Dungeons without quests for you (or without QuestieDB): Dungeons' own ranking.
local function plainRow(option)
  local r = option.result
  local details = { { text = ns.Questie.Available() and "No quests for it: ranked by level fit and travel time."
    or "Ranked by level fit and travel time. Install QuestieDB for its quests and XP.", color = GOLD } }
  for _, line in ipairs(r.details or {}) do details[#details + 1] = line end
  return {
    id = "plain" .. (r.id or option.name), kind = "dungeon", raid = option.raid, title = option.title,
    subtitle = string.format("%s  ·  %s  ·  fits your level", firstPart(r.zone),
      ns.FormatDuration(option.trip)),
    goal = r.goal, route = r.route, details = details,
  }
end

local function comboRow(need, option, journey, ctx)
  local details = { { text = need.rank .. " On the way: the best option, " .. option.title .. ".",
    color = GOLD } }
  for _, line in ipairs(need.details or {}) do details[#details + 1] = line end
  questLines(details, option, ctx)
  return {
    id = "combo" .. need.kind, kind = need.kind, title = journey.title,
    subtitle = string.format("%s  ·  %s, then %s", ns.FormatDuration(journey.seconds), need.why,
      rateText(option, ctx)),
    journey = journey, details = details, actions = { onlyAction(need) },
  }
end

---------------------------------------------------------------- page

local function summaryFor(ctx, needs)
  local level = UnitLevel("player")
  local ranking = ctx.xpMode and "the most XP per minute" or "the most quests per hour"
  local parts = {}
  if needs > 0 then
    parts[1] = string.format("Level %d: |cff7fd1ae%s due|r first, then %s.", level, plural(needs, "thing"), ranking)
  else
    parts[1] = string.format("Level %d: %s from here.", level, ranking)
  end
  if not ctx.questie then
    parts[#parts + 1] = "Install QuestieDB for quest hubs and XP; dungeons are ranked by level fit and travel time."
  elseif level >= MAX_LEVEL then
    parts[#parts + 1] = "At the level cap quests give no XP, so options are ranked by quests per hour."
  elseif not ctx.db then
    parts[#parts + 1] = "No quest XP in your QuestieDB: ranked by quests per hour, weighted by level fit."
  end
  local ready, unfinished = 0, 0
  for _, e in ipairs(ctx.log) do
    if e.complete then ready = ready + 1 else unfinished = unfinished + 1 end
  end
  if ready + unfinished > 0 then
    local counted = {}
    if ready > 0 then counted[#counted + 1] = string.format("%d ready to hand in", ready) end
    if unfinished > 0 then counted[#counted + 1] = string.format("%d to finish (timed by objectives left)", unfinished) end
    parts[#parts + 1] = string.format("Quest log counted at full XP: %s.", table.concat(counted, ", "))
    if ctx.unplaced > 0 then
      parts[#parts + 1] = string.format("%s in your log can't be placed on the map%s.", plural(ctx.unplaced, "quest"),
        ctx.questie and "" or " without QuestieDB")
    end
  end
  for _, note in ipairs(ctx.notes) do parts[#parts + 1] = note end
  return table.concat(parts, " ")
end

local function build()
  local start = ns.Geo.PlayerNode()
  if not start then
    summary = nil
    return {}, "Can't read your position here."
  end
  local net = ns.Network.Build()
  local level = UnitLevel("player")
  local db = xpTable()
  local ctx = { level = level, db = db, xpMode = db ~= nil and level < MAX_LEVEL,
    questie = ns.Questie.Available() and true or false, notes = {}, unplaced = 0 }
  ctx.log = try(readLog) or {}

  local needs = {}
  local function addNeed(n) if n then needs[#needs + 1] = n end end
  addNeed(try(trainingNeed, ctx))
  for _, n in ipairs(try(vendorNeeds, ctx) or {}) do addNeed(n) end
  addNeed(try(flightNeed, ctx, start, net))
  table.sort(needs, function(a, b) return PRIORITY[a.kind] < PRIORITY[b.kind] end)
  while #needs > MAX_RESULTS - MIN_XP_ROWS do table.remove(needs) end

  -- Options by XP per minute; journeys (dungeon pickups, log quests) are
  -- planned only for the ones listed, then those are ranked again with the
  -- real trip time.
  local options = try(hubOptions) or {}
  local handins = try(handinOptions, ctx, start, net) or {}
  for _, option in ipairs(mergeHandins(options, handins)) do options[#options + 1] = option end
  for _, option in ipairs(try(finishOptions, ctx, start, net) or {}) do options[#options + 1] = option end
  local dungeons, plain = try(dungeonOptions, ctx)
  for _, option in ipairs(dungeons or {}) do options[#options + 1] = option end
  for _, option in ipairs(options) do score(option, ctx) end
  local function byRate(a, b)
    if a.rate ~= b.rate then return a.rate > b.rate end
    return a.seconds < b.seconds
  end
  table.sort(options, byRate)
  local total = #options
  local listed = {}
  for i = 1, math.min(#options, MAX_RESULTS - #needs) do listed[i] = options[i] end
  for _, option in ipairs(listed) do
    if option.kind == "dungeon" then
      try(dungeonJourney, option, ctx, start, net)
    elseif #option.stops > 0 then
      try(questJourney, option, ctx, start, net)
    end
  end
  table.sort(listed, byRate)

  local results = {}
  local combined = needs[1] and listed[1] and try(combine, needs[1], listed[1], start, net)
  for i, need in ipairs(needs) do
    results[#results + 1] = (i == 1 and combined) and comboRow(need, listed[1], combined, ctx) or needRow(need)
  end
  for i, option in ipairs(listed) do results[#results + 1] = optionRow(option, i, total, ctx) end
  for _, option in ipairs(plain or {}) do
    if #results >= MAX_RESULTS then break end
    results[#results + 1] = plainRow(option)
  end

  summary = summaryFor(ctx, #needs)
  return results, nil, net
end

function ForYou.SummaryText()
  return summary or "What to do next, for this character, from where you stand."
end

function ForYou.EmptyText()
  return "Nothing to suggest from here yet. Visit a trainer for your class, open a flight map, or install "
    .. "QuestieDB for quest hubs and XP estimates."
end

-- Computed once per refresh and reused for CACHE_SECONDS: the providers plan
-- many routes.
-- Card icons by kind: classic-era icons, and the class circle for trainers.
local ICONS = {
  hub = "Interface\\Icons\\INV_Misc_Note_01", handin = "Interface\\Icons\\INV_Letter_15",
  finish = "Interface\\Icons\\INV_Sword_04", dungeon = "Interface\\Icons\\INV_Misc_Key_14",
  raid = "Interface\\Icons\\INV_Misc_Head_Dragon_01", flight = "Interface\\Icons\\Ability_Hunter_EagleEye",
  repair = "Interface\\Icons\\Trade_BlackSmithing", food = "Interface\\Icons\\INV_Misc_Food_15",
  ammo = "Interface\\Icons\\INV_Ammo_Arrow_01", reagents = "Interface\\Icons\\INV_Misc_Dust_02",
}

local function iconFor(r)
  if r.kind == "train" then
    local _, class = UnitClass("player")
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then return "Interface\\TargetingFrame\\UI-Classes-Circles", coords end
    return "Interface\\Icons\\INV_Misc_Book_09"
  end
  if r.kind == "dungeon" and r.raid then return ICONS.raid end
  return ICONS[r.kind] or "Interface\\Icons\\INV_Misc_Map_01"
end

function ForYou.Results()
  local now = GetTime and GetTime()
  if cache and now and now - cache.at < CACHE_SECONDS then return cache.results, cache.err, cache.net end
  local started = debugprofilestop and debugprofilestop()
  local results, err, net = build()
  for _, r in ipairs(results or {}) do r.icon, r.iconCoords = iconFor(r) end
  ForYou.runs = ForYou.runs + 1
  if started then
    ns.debugTimings = ns.debugTimings or {}
    ns.debugTimings.forYou = debugprofilestop() - started
  end
  cache = now and { at = now, results = results, err = err, net = net } or nil
  return results, err, net
end

function ForYou.Invalidate()
  cache = nil
end

-- Registered before the panel's own listeners, so its refresh sees fresh data.
ns.Listen("DATA_CHANGED", ForYou.Invalidate)
ns.Listen("FLIGHTS_CHANGED", ForYou.Invalidate)
ns.On("ZONE_CHANGED_NEW_AREA", ForYou.Invalidate)

ns.RegisterPage(ForYou)

ns.RegisterCommand("next", "/wf next - what to do next (opens the For you page)", function()
  ForYou.Invalidate()
  ns.Panel.Search(ForYou.id)
end)
