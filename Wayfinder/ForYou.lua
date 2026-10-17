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

local ForYou = { id = "foryou", label = "For you", order = 10, searchable = false }
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

-- Runs a provider while recording what ns.Questie[name] returns to it, so its
-- QuestieDB scan is reused rather than run twice. Quest hub and dungeon
-- results don't carry quest IDs yet, and XP needs them.
local function withCapture(name, provider)
  local bridge = ns.Questie
  local original, captured = bridge[name], {}
  if type(original) == "function" then
    bridge[name] = function(...)
      local value = original(...)
      captured[#captured + 1] = value
      return value
    end
  end
  local ok, results, _, net = pcall(provider)
  bridge[name] = original
  if not ok then
    geterrorhandler()(results)
    return {}, nil, captured
  end
  return results or {}, net, captured
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

-- value: XP (or quests) for the option; rate: per minute, trip included.
local function score(option, ctx)
  option.value, option.estimated = 0, 0
  for _, q in ipairs(option.quests) do
    local v, estimated = questValue(q, ctx)
    q.value = v
    option.value = option.value + v
    if estimated then option.estimated = option.estimated + 1 end
  end
  option.seconds = option.trip + #option.quests * SECONDS_PER_QUEST
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
local function flightNeed(ctx, start, net)
  local continent = ns.Geo.Continents()[start.instance]
  if not continent then return nil end
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
  return {
    kind = "flight", only = "Flight only",
    title = string.format("Learn the %s flight path", town),
    zone = ns.MapName(best.mapID), goal = best, route = route,
    why = "not discovered yet",
    rank = "Needs come first: a flight path you haven't discovered is close by, and later trips get faster.",
    details = {},
    stop = { node = best, text = "Talk to the flight master to learn " .. town,
      phrase = string.format("learn the %s flight path", town) },
  }
end

---------------------------------------------------------------- XP options

-- The raw hub (with quest IDs) behind a Quest hubs result: same anchor as the
-- result's goal. A hub merged into another shares its anchor but has fewer quests.
local function rawHub(r, captured)
  local best
  for _, hubs in ipairs(captured) do
    for _, hub in ipairs(type(hubs) == "table" and hubs or {}) do
      local a = hub.anchor and hub.anchor.node
      if a and a.mapID == r.goal.mapID and a.x == r.goal.x and a.y == r.goal.y
        and (not best or hub.count > best.count) then best = hub end
    end
  end
  return best
end

local function hubOptions()
  local results, _, captured = withCapture("QuestHubs", ns.QuestHubs.Results)
  local out = {}
  for _, r in ipairs(results) do
    local hub = r.goal and r.route and rawHub(r, captured)
    if hub then
      local quests = {}
      for _, giver in ipairs(hub.givers) do
        for _, q in ipairs(giver.quests) do
          quests[#quests + 1] = { id = q.id, name = q.name, level = q.level, giver = giver.name }
        end
      end
      local where = hub.place and ("in " .. hub.place) or ("near " .. (hub.anchor.name or "?"))
      local doing = string.format("pick up %s %s", plural(#quests, "quest"), where)
      local names = {}
      for _, q in ipairs(quests) do names[#names + 1] = q.name or ("quest " .. q.id) end
      out[#out + 1] = {
        kind = "hub", title = capitalize(doing), zone = ns.MapName(r.goal.mapID),
        goal = r.goal, route = r.route, trip = r.route.seconds, quests = quests,
        stops = {},
        finish = { node = r.goal, phrase = doing, text = "Pick up quests here: " .. table.concat(names, ", ") },
      }
    end
  end
  return out
end

-- Dungeons.lua's result ids are "dungeon" .. this.
local function normalize(name)
  return ((name or ""):lower():gsub("^the ", ""):gsub("[^%w]", ""))
end

-- Dungeons with their quests (available and in your log) as XP options, and
-- the rest in Dungeons' own order (level fit and travel time).
local function dungeonOptions()
  -- Dungeons.lua caches the dungeon finder list on first use; don't trigger
  -- that before the API exists.
  if type(GetLFGDungeonInfo) ~= "function" then return {}, {} end
  local results, _, captured = withCapture("QuestsForAreas", ns.Dungeons.Results)
  local byID = {}
  for _, entry in ipairs(try(ns.Dungeons.Catalogue) or {}) do byID["dungeon" .. normalize(entry.name)] = entry end
  local areaQuests = type(captured[1]) == "table" and captured[1] or {}

  local withQuests, plain = {}, {}
  for _, r in ipairs(results) do
    local entry = byID[r.id]
    local available, inLog, seen = {}, {}, {}
    local function add(list, q)
      if not seen[q.id] then
        seen[q.id] = true
        list[#list + 1] = q
      end
    end
    for areaID in pairs(entry and entry.areaIDs or {}) do
      local group = areaQuests[areaID]
      if group then
        for _, q in ipairs(group.available or {}) do add(available, q) end
        for _, q in ipairs(group.inLog or {}) do add(inLog, q) end
      end
    end
    local quests = {}
    for _, q in ipairs(available) do quests[#quests + 1] = q end
    for _, q in ipairs(inLog) do quests[#quests + 1] = { id = q.id, name = q.name, level = q.level, inLog = true } end
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
  local pickups = {}
  for _, q in ipairs(option.available) do
    local giver, node, distance = ns.Questie.QuestGiver(q.id, start)
    if node and distance and distance < math.huge then
      pickups[#pickups + 1] = { node = node, distance = distance, group = "pickup",
        text = string.format("Pick up %s from %s", q.name or ("quest " .. q.id), giver or "?"),
        action = { kind = "pickup", questID = q.id } }
    end
  end
  table.sort(pickups, function(a, b) return a.distance < b.distance end)
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
-- entrance come last, so you train or shop first, then quest.
local function combine(need, option, start, net)
  if not (need.stop and option.finish) then return nil end
  local def = { stops = { copyStop(need.stop) }, finish = copyStop(option.finish) }
  for _, s in ipairs(option.stops) do def.stops[#def.stops + 1] = copyStop(s) end
  local journey = ns.Journey.Plan(start, def, net)
  if not journey or #journey.skipped > 0 then return nil end
  if journey.seconds > seconds(need.route) + option.trip + COMBINE_SLACK then return nil end
  journey.title = journeyTitle(journey.stops)
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
    id = "need" .. need.kind, title = need.title,
    subtitle = string.format("%s  ·  %s  ·  %s", need.zone, ns.FormatDuration(need.route.seconds), need.why),
    goal = need.goal, route = need.route, details = details,
  }
end

local function questLines(details, option, ctx)
  for _, q in ipairs(option.quests) do
    local value = ctx.xpMode and string.format("  -  %s XP", formatNumber(q.value)) or ""
    local who = q.inLog and "  (in your log)" or (q.giver and ("  (" .. q.giver .. ")") or "")
    details[#details + 1] = {
      text = string.format("[%d] %s%s%s", q.level or 0, q.name or ("Quest " .. q.id), value, who),
      color = GetQuestDifficultyColor and q.level and GetQuestDifficultyColor(q.level),
    }
  end
end

local function optionRow(option, rank, total, ctx)
  local count = #option.quests
  local amount = ctx.xpMode and (formatNumber(option.value) .. " XP") or plural(count, "quest")
  local details = { {
    text = string.format("#%d of %d by %s: ~%s in %s (trip %s + %d x %d min per quest).", rank, total,
      ctx.xpMode and "XP per minute" or "quests per hour", amount, ns.FormatDuration(option.seconds),
      ns.FormatDuration(option.trip), count, SECONDS_PER_QUEST / 60),
    color = GOLD,
  } }
  if option.estimated > 0 then
    details[#details + 1] = { text = string.format("XP estimated for %s QuestieDB has no XP for.",
      plural(option.estimated, "quest")), color = GREY }
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
  end
  why[#why + 1] = rateText(option, ctx)

  local row = {
    id = option.kind .. (option.name or option.title), title = option.title,
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
  return row
end

-- Dungeons without quests for you (or without QuestieDB): Dungeons' own ranking.
local function plainRow(option)
  local r = option.result
  local details = { { text = ns.Questie.Available() and "No quests for it: ranked by level fit and travel time."
    or "Ranked by level fit and travel time. Install QuestieDB for its quests and XP.", color = GOLD } }
  for _, line in ipairs(r.details or {}) do details[#details + 1] = line end
  return {
    id = "plain" .. (r.id or option.name), title = option.title,
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
    id = "combo" .. need.kind, title = journey.title,
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
    questie = ns.Questie.Available() and true or false, notes = {} }

  local needs = {}
  local function addNeed(n) if n then needs[#needs + 1] = n end end
  addNeed(try(trainingNeed, ctx))
  for _, n in ipairs(try(vendorNeeds, ctx) or {}) do addNeed(n) end
  addNeed(try(flightNeed, ctx, start, net))
  table.sort(needs, function(a, b) return PRIORITY[a.kind] < PRIORITY[b.kind] end)
  while #needs > MAX_RESULTS - MIN_XP_ROWS do table.remove(needs) end

  -- Options by XP per minute; dungeon journeys (with pickups) are planned only
  -- for the ones listed, then those are ranked again with the real trip time.
  local options = try(hubOptions) or {}
  local dungeons, plain = try(dungeonOptions)
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
    if option.kind == "dungeon" then try(dungeonJourney, option, ctx, start, net) end
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
function ForYou.Results()
  local now = GetTime and GetTime()
  if cache and now and now - cache.at < CACHE_SECONDS then return cache.results, cache.err, cache.net end
  local started = debugprofilestop and debugprofilestop()
  local results, err, net = build()
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
