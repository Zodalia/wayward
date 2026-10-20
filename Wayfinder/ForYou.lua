local _, ns = ...

-- "For you" page, the panel's first tab: a handful of things to do next for
-- this character, right now, one card per kind of thing (its `category`):
--   Due now     spells you can train and afford, repairs, ammo, food, a flight
--               path close by (at most MAX_NEEDS), always first;
--   Don't miss  the quest that stands out most (Notable.lua: a class quest, a
--               reward for your class, a Forever-only quest...) that you can
--               take or have in your log within NOTABLE_SECONDS of travel,
--               whatever its XP; right after what's due;
--   Hand in     the best group of quests ready to hand in;
--   Finish      the best group of unfinished quests in your log;
--   Best quest  the single quest worth the most XP that you can pick up nearby,
--               as a whole-quest trip;
--   Questing zone  where to quest at your level, anywhere in the world (up to
--               MAX_ZONES): the quests you can take there now and the ones their
--               chains unlock, and the hub to start at;
--   Dungeon     the best dungeon, with its quests picked up on the way, and the
--               others for your level;
-- in that order after the due ones; then hand-ins, finishing and the best
-- quest by estimated XP per minute.
--
-- XP comes from the data's quest XP table (ns.Data.QuestXP). Without it,
-- options are ranked by quests per hour weighted by level fit, and the
-- summary line says so. Without quest data there are no hubs or dungeon quests,
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

local SECONDS_PER_QUEST = 300   -- time to do one quest, on top of the trip (until QuestTimes has
                                -- learned how long yours take: perQuest)
local MAX_RESULTS = 9           -- cards the page shows (three pages)
local MAX_NEEDS = 2             -- "Due now" and "Worth a visit" cards
local REPAIR_SOON = 0.75        -- gear at or under this: repair if a vendor is close
local REPAIR_NEAR_SECONDS = 120 -- "close" for that
local TRAIN_LEVELS_STALE = 2    -- levels since your last trainer visit before new spells are likely
local ZONE_MIN_QUESTS = 4       -- quests you can take now for a zone to get a card
local DUNGEON_QUEST_SHARE = 0.6 -- of a dungeon's quests, the share you need to be able to take now
                                -- (mobs in Forever's dungeons give little XP: the quests make the run)
local MAX_ZONES = 3             -- "Questing zone" cards
local ZONE_HUBS = 3             -- hubs named on a zone card after the first
local ZONE_QUEST_LINES = 5      -- quests listed on a zone card
local CACHE_SECONDS = 5         -- a refresh is reused this long (cleared early on data or zone changes)
local MAX_LEVEL = 60            -- Forever's level cap: quests give no XP there
local LOW_AMMO = 200            -- arrows or bullets left
local LOW_FOOD = 5              -- food and drink items left in your bags
local FOOD_FROM_LEVEL = 6       -- below this, eating and drinking between fights rarely matters
local FLIGHT_NEAR_SECONDS = 180 -- an undiscovered flight path this close (by route) is worth the detour
local MAX_PICKUPS = 4           -- dungeon quest givers visited on the way to the entrance
local HANDIN_SECONDS = 30       -- handing in one quest, on top of the trip
local MIN_SHARE_LEFT = 0.25     -- an unfinished quest takes at least this share of SECONDS_PER_QUEST
local FINISH_RADIUS = 600       -- yards between objective areas done in one "Finish" trip
local MAX_FINISH = 3            -- log quests per "Finish" trip (up to two stops each)
local FINISH_TRIPS = 3          -- nearest groups of unfinished log quests offered
local NOTABLE_SECONDS = 600     -- "Don't miss": travel to the quest's first stop, at most
local NOTABLE_TRIES = 4         -- notable quests planned before giving up on the card
local BUDGET_DUNGEON = 60       -- minutes: with less time than this, no dungeon
local BUDGET_TRIES = 3          -- hand-in or finish trips planned to find one that fits

local GOLD = { r = 1, g = 0.82, b = 0 }
local GREY = { r = 0.6, g = 0.6, b = 0.6 }
local NOTABLE = { r = 0.77, g = 0.55, b = 1 }

-- Lower comes first among needs; soft ones ("Worth a visit") after all of these.
local PRIORITY = { repair = 1, train = 2, ammo = 3, food = 4, flight = 5, profession = 6 }
local SOFT_PRIORITY = 10

ForYou.SECONDS_PER_QUEST = SECONDS_PER_QUEST
local cache, summary
local perQuest = SECONDS_PER_QUEST -- this refresh's time per quest: your average once known
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
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
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

-- A notable quest's tag ("Class quest") and its reasons (Notable.lua), or nil.
local function notableTag(questID)
  if not ns.Quests.NotableTag then return nil end
  local tag, reasons = try(ns.Quests.NotableTag, questID)
  return tag, reasons
end

-- A quest line on a card: its tag on the line, its strongest reason in the
-- tooltip only.
local function addQuestLine(details, line, questID)
  local tag, reasons = notableTag(questID)
  if tag then line.text = line.text .. "  ·  " .. tag end
  details[#details + 1] = line
  if tag then details[#details + 1] = { text = "    " .. reasons[1].text, color = NOTABLE, more = true } end
end

---------------------------------------------------------------- quest XP

-- The data's quest XP: [questID] = { questLevel, xp }, the full reward before
-- the level penalty. It is Era data (the Forever file matches Era's), so
-- Forever-only quests are missing; those get the average XP for their level.
local function xpTable()
  local db = ns.Data.QuestXP()
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
-- quest takes perQuest unless it says otherwise (log quests: q.seconds).
local function score(option, ctx)
  option.value, option.estimated = 0, 0
  option.seconds = option.trip
  for _, q in ipairs(option.quests) do
    local v, estimated = questValue(q, ctx)
    q.value = v
    option.value = option.value + v
    option.seconds = option.seconds + (q.seconds or perQuest)
    if estimated then option.estimated = option.estimated + 1 end
  end
  option.rate = option.value / math.max(option.seconds / 60, 1)
end

local function rateText(option, ctx)
  if ctx.xpMode then return string.format("~%s XP/min", formatNumber(option.rate)) end
  return string.format("~%.1f quests/h", option.rate * 60)
end

-- The rate as a card stat: { label, value }.
local function rateStat(option, ctx)
  if ctx.xpMode then return { "XP/min", "~" .. formatNumber(option.rate) } end
  return { "Quests/h", string.format("~%.1f", option.rate * 60) }
end

---------------------------------------------------------------- needs

-- Without a fresh spell list: at an even level (when classes get new ranks),
-- before your first trainer visit or a couple of levels after the last one.
local function likelyTraining(ctx, s)
  if ctx.level < 2 or ctx.level % 2 ~= 0 then return nil end
  if s and ctx.level < (s.level or 0) + TRAIN_LEVELS_STALE then return nil end
  local best = (try(ns.Trainers.Results) or {})[1]
  if not (best and best.route) then return nil end
  local place = placeName(best.goal, best.zone)
  local since = s and string.format("you're level %d, %d levels since your last visit", ctx.level, ctx.level - s.level)
    or string.format("you're level %d and haven't visited a trainer yet", ctx.level)
  return {
    kind = "train", soft = true, title = string.format("Visit your trainer in %s", place),
    zone = best.zone, goal = best.goal, route = best.route,
    why = string.format("new spells likely at level %d", ctx.level),
    rank = string.format("Worth a visit: %s; classes get new spells at even levels.", since),
    details = { { text = "Trainer: " .. best.title } },
  }
end

local function trainingNeed(ctx)
  local s = ns.Trainers.SpellSummary()
  -- Spell data (no trainer visit yet) that has nothing for you: no card.
  if s and s.fromData and s.trainable == 0 then return nil end
  if not (s and s.trainable > 0) then return likelyTraining(ctx, s) end
  local spells = plural(s.trainable, "new spell")
  local cost = s.costUnknown and "?" or ns.FormatMoney(s.cost)
  if not s.costUnknown and GetMoney() < s.cost then
    ctx.notes[#ctx.notes + 1] = string.format("%s to train once you have %s.", capitalize(spells),
      ns.FormatMoney(s.cost))
    return nil
  end
  local best = (try(ns.Trainers.Results) or {})[1]
  if not (best and best.route) then return nil end
  local place = placeName(best.goal, best.zone)
  -- The spells themselves, first thing on the card.
  local details, level = {}, UnitLevel("player")
  for _, sp in ipairs(ns.Trainers.Services() or {}) do
    if sp.type ~= "used" and sp.levelReq and sp.levelReq <= level then
      details[#details + 1] = { text = string.format("%s%s%s", sp.name, sp.rank and (" (" .. sp.rank .. ")") or "",
        sp.cost and ("  -  " .. ns.FormatMoney(sp.cost)) or "") }
    end
  end
  details[#details + 1] = { text = "Trainer: " .. best.title, more = #details > 0 }
  return {
    kind = "train", only = "Train only",
    stats = { { "Spells", tostring(s.trainable) }, { "Cost", cost },
      { "Travel", ns.FormatDuration(best.route.seconds) } },
    title = string.format("Train %s in %s", spells, place),
    zone = best.zone, goal = best.goal, route = best.route,
    why = s.costUnknown and spells or string.format("%s for %s", spells, cost),
    rank = s.costUnknown and string.format("Needs come first: you can train %s.", spells)
      or string.format("Needs come first: you can train and afford %s (%s).", spells, cost),
    details = details,
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

-- A profession's next rank you can train now: due when you're at your cap
-- (you can't skill up any more), worth a visit before that.
local function professionNeeds(start, net)
  local mine = ns.Professions.Mine()
  if not mine then return {} end
  local out = {}
  for _, p in ipairs(ns.Professions.LIST) do
    local have = mine[p.name]
    local rank, state = nil, nil
    if have then rank, state = ns.Professions.NextRank(have) end
    if rank and state == "ready" then
      local trainer, route, sure = ns.Professions.NearestTrainer(p.name, rank.name, start, net)
      if trainer and route then
        local capped = have.rank >= have.cap
        local place = placeName(trainer.node, ns.MapName(trainer.node.mapID))
        trainer.node.npc = trainer.name
        local details = { { text = string.format("Trainer: %s, %s.", trainer.name, place) } }
        if not sure then
          details[#details + 1] = { text = "Not every trainer teaches " .. rank.name .. "; if this one doesn't, the Professions tab lists others.", more = true }
        end
        -- The trip: go there and buy the rank (done when your skill cap goes up).
        local title = string.format("Train %s %s in %s", rank.name, p.name, place)
        local stop = { node = trainer.node, npc = trainer.name,
          text = string.format("Train %s %s at %s", rank.name, p.name, trainer.name),
          action = { kind = "train", profession = p.name, cap = have.cap, npc = trainer.name } }
        local journey = ns.Journey.Plan(start, { title = title, stops = { stop } }, net)
        out[#out + 1] = {
          kind = "profession", soft = not capped, icon = p.icon, journey = journey,
          title = title,
          zone = ns.MapName(trainer.node.mapID), goal = trainer.node, route = route,
          why = string.format("%s %d/%d%s", p.name, have.rank, have.cap, capped and ", at your cap" or ""),
          stats = { { "Skill", string.format("%d/%d", have.rank, have.cap) }, { "Next", rank.name },
            { "Travel", ns.FormatDuration(route.seconds) } },
          rank = capped and string.format("Needs come first: %s is at its cap; %s lets it go up to %d.", p.name, rank.name, rank.cap)
            or string.format("Worth a visit: you can train %s %s (up to %d skill).", rank.name, p.name, rank.cap),
          details = details,
        }
      end
    end
  end
  return out
end

-- Gear wearing down (not yet at the 50% that makes repairs due): worth it
-- when a repair vendor is a short trip away.
local function repairSoonNeed()
  local p = ns.Vendors.Needs()
  if p.urgent or not (p.durability and p.durability <= REPAIR_SOON) then return nil end
  local best
  for _, r in ipairs(try(ns.Vendors.Results) or {}) do
    if r.covers and r.covers.repair and r.route and seconds(r.route) < seconds(best and best.route) then best = r end
  end
  if not (best and seconds(best.route) <= REPAIR_NEAR_SECONDS) then return nil end
  local name = best.goal.label or best.title
  local percent = math.floor(p.durability * 100 + 0.5)
  return {
    kind = "repair", soft = true, title = "Repair at " .. name,
    zone = ns.MapName(best.goal.mapID), goal = best.goal, route = best.route,
    why = string.format("gear at %d%%, a repairer close by", percent),
    rank = string.format("Worth a visit: your gear is at %d%% and a repairer is %s away.", percent,
      ns.FormatDuration(best.route.seconds)),
    details = best.details,
  }
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

-- Quests in your log: { id, row (quest data), name, level, complete, left }.
local function readLog()
  local out = {}
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return out end
  for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
    local info = C_QuestLog.GetInfo(i)
    local id = info and not info.isHeader and not info.isHidden and info.questID
    if id then
      local row = ns.Quests.Quest(id)
      local complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) and true or false
      out[#out + 1] = { id = id, row = row, name = row and row.name or info.title,
        level = ns.Quests.QuestLevel(id) or info.level, complete = complete,
        left = complete and 0 or shareLeft(id) }
    end
  end
  return out
end

-- A log quest as an option's quest: full XP, only the time left counted.
local function logQuest(e)
  return { id = e.id, name = e.name, level = e.level, inLog = true, handin = e.complete, left = e.left,
    seconds = e.complete and HANDIN_SECONDS or perQuest * e.left }
end

-- Quests done inside a dungeon count toward its option instead. Dungeons.lua
-- caches the dungeon finder list on first use, so not before the API exists.
local function dungeonQuest(row)
  if not row or type(GetLFGDungeonInfo) ~= "function" then return false end
  local area = ns.Quests.QuestArea(row)
  return area ~= nil and ns.Dungeons.ForArea(area) ~= nil
end

-- Quests ready to hand in, grouped by where you hand them in: their
-- finishers clustered like quest hubs, then merged by place.
local function handinOptions(ctx, start, net)
  local givers, order = {}, {}
  for _, e in ipairs(ctx.log) do
    if e.complete then
      local name, node, distance = ns.Quests.QuestFinisher(e.id, start)
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
  for _, hub in ipairs(ns.Quests.Cluster(order, math.huge)) do
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
          npc = g.name, text = string.format("Hand in %s to %s", e.name or ("quest " .. e.id), g.name or "the quest giver") }
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
        quests = quests, stops = stops,
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
      local node = ns.Quests.ObjectiveNode(e.id, start)
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

-- Dungeons with their quests (available and in your log) as XP options, and
-- the rest in Dungeons' own order (level fit and travel time). Log quests
-- count at full XP with the time left for them; ones ready to hand in are
-- hand-in options instead.
local function dungeonOptions(ctx)
  -- Dungeons.lua caches the dungeon finder list on first use; don't trigger
  -- that before the API exists.
  if type(GetLFGDungeonInfo) ~= "function" then return {}, {}, {} end
  local logged = {}
  for _, e in ipairs(ctx.log) do logged[e.id] = e end
  local withQuests, plain, held = {}, {}, {}
  local routed = {}
  for _, r in ipairs(run(ns.Dungeons.Results)) do
    if r.goal then routed[#routed + 1] = r end -- not those whose entrance isn't known
  end
  for _, r in ipairs(routed) do
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
        seconds = e and perQuest * e.left }
    end
    local name = entry and entry.name or r.title
    local later = r.quests and r.quests.later or {}
    local option = {
      kind = "dungeon", name = name, raid = entry and entry.raid, result = r,
      title = "Run " .. r.title, zone = r.zone, goal = r.goal, route = r.route, trip = seconds(r.route),
      quests = quests, available = available, inLog = inLog, later = later,
    }
    -- Not yet when most of its quests are still to come: when they open.
    local total = #quests + #later
    if total > 0 and #quests / total < DUNGEON_QUEST_SHARE then
      for _, q in ipairs(later) do
        local required = q.requiredLevel or 0
        if required > ctx.level and (not option.opensAt or required < option.opensAt) then option.opensAt = required end
      end
      option.held = true
    end
    if r.route then
      if option.held then
        held[#held + 1] = option
      elseif #quests > 0 then
        withQuests[#withQuests + 1] = option
      else
        plain[#plain + 1] = option
      end
    end
  end
  return withQuests, plain, held
end

-- Pick up the dungeon's quests on the way (nearest givers), finish at the entrance.
local function dungeonJourney(option, ctx, start, net)
  -- Givers are ranked by trip time, not straight distance, so one on another
  -- continent (e.g. Darnassus for Blackfathom Deeps) still counts.
  local pickups = {}
  for _, q in ipairs(option.available) do
    local giver, node = ns.Quests.QuestGiver(q.id, start)
    local route = node and ns.Router.Plan(start, node, net)
    if route then
      pickups[#pickups + 1] = { node = node, seconds = route.seconds, group = "pickup", giver = giver,
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

-- The quest worth the most XP among the hubs' quests (not dungeon ones), as a
-- whole-quest trip: pick it up, do it (and what it needs first), hand it in.
local function bestQuestOption(hubs, ctx, start, net)
  local best, bestValue, bestHub
  for _, hub in ipairs(hubs) do
    for _, q in ipairs(hub.quests) do
      if not q.inLog and not dungeonQuest(ns.Quests.Quest(q.id)) then
        local v = questValue(q, ctx)
        if not bestValue or v > bestValue or (v == bestValue and hub.trip < bestHub.trip) then
          best, bestValue, bestHub = q, v, hub
        end
      end
    end
  end
  if not best then return nil end
  local stops = ns.Journey.QuestStops(best.id, start)
  if #stops == 0 then return nil end
  local name = best.name or ("quest " .. best.id)
  local journey = ns.Journey.Plan(start, { title = "Do " .. name, stops = stops }, net)
  if not journey then return nil end
  local option = {
    kind = "quest", title = "Do " .. name, zone = bestHub.zone, place = bestHub.place,
    goal = journey.stops[#journey.stops].node, trip = journey.seconds, journey = journey, stops = stops,
    quests = { { id = best.id, name = best.name, level = best.level, giver = best.giver } },
  }
  score(option, ctx)
  return option
end

-- Seconds from the start of a journey to its first stop.
local function firstLeg(journey)
  local total = 0
  for _, step in ipairs(journey.steps) do
    total = total + (step.seconds or 0)
    if step.stop then break end
  end
  return total
end

-- "Don't miss": the quest that stands out most (Quests.NotableScore), among
-- those you can take at the hubs and those in your log (not dungeon ones, nor
-- `skip`), whose first stop is within NOTABLE_SECONDS. Not ranked by XP: a
-- class quest worth little XP still gets the card.
local function notableOption(hubs, ctx, start, net, skip)
  if not ns.Quests.NotableTag then return nil end
  local candidates, seen = {}, {}
  local function consider(id, name, level, inLog, near, complete)
    if seen[id] or skip[id] then return end
    seen[id] = true
    local row = ns.Quests.Quest(id)
    if not row or dungeonQuest(row) then return end
    local tag, reasons = notableTag(id)
    if not tag then return end
    candidates[#candidates + 1] = { id = id, name = name or row.name, level = level, inLog = inLog, tag = tag,
      reasons = reasons, score = ns.Quests.NotableScore(id), near = near or math.huge, complete = complete }
  end
  for _, hub in ipairs(hubs) do
    -- A hub farther than that can't have a quest whose giver is near enough.
    if hub.trip <= NOTABLE_SECONDS then
      for _, q in ipairs(hub.quests) do
        if not q.inLog then consider(q.id, q.name, q.level, false, hub.trip) end
      end
    end
  end
  for _, e in ipairs(ctx.log) do consider(e.id, e.name, e.level, true, nil, e.complete) end
  table.sort(candidates, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.near < b.near
  end)
  for i, c in ipairs(candidates) do
    if i > NOTABLE_TRIES then break end
    local stops = ns.Journey.QuestStops(c.id, start)
    local name = c.name or ("quest " .. c.id)
    local title = (c.complete and "Hand in " or c.inLog and "Finish " or "Do ") .. name
    local journey = #stops > 0 and ns.Journey.Plan(start, { title = title, stops = stops }, net) or nil
    local travel = journey and firstLeg(journey)
    if travel and travel <= NOTABLE_SECONDS then
      local first = journey.stops[1].node
      return {
        kind = "notable", title = title, zone = zoneName(first), goal = journey.stops[#journey.stops].node,
        trip = journey.seconds, travel = travel, journey = journey, stops = stops, tag = c.tag, reasons = c.reasons,
        quests = { { id = c.id, name = c.name, level = c.level, inLog = c.inLog } },
      }
    end
  end
  return nil
end

-- Where to quest at your level, anywhere: per zone (Quests.ZoneQuests), the
-- quests you can take now and those their chains unlock, worth their XP; the
-- hub to start at is the one with the most quests for you now, and the card's
-- trip picks up all of them there. Zones need
-- ZONE_MIN_QUESTS quests you can take now; the best MAX_ZONES by XP (quest
-- count without XP data) get a route to their first hub.
local function zoneOptions(ctx, start, net)
  local zones = {}
  for mapID, z in pairs(ns.Quests.ZoneQuests(start)) do
    local now, later, value, lowest, highest = {}, {}, 0, math.huge, 0
    for _, q in ipairs(z.quests) do
      if not dungeonQuest(ns.Quests.Quest(q.id)) then
        q.value = questValue(q, ctx)
        value = value + q.value
        lowest, highest = math.min(lowest, q.level or ctx.level), math.max(highest, q.level or ctx.level)
        if q.chain then later[#later + 1] = q else now[#now + 1] = q end
      end
    end
    if #now >= ZONE_MIN_QUESTS then
      zones[#zones + 1] = { mapID = mapID, now = now, later = later, value = value, lowest = lowest, highest = highest }
    end
  end
  table.sort(zones, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return #a.now > #b.now
  end)

  local out = {}
  for _, z in ipairs(zones) do
    if #out >= MAX_ZONES then break end
    -- Givers of the quests you can take now, clustered into hubs, named by place.
    local givers, byKey = {}, {}
    for _, q in ipairs(z.now) do
      local key = string.format("%s@%d:%.4f:%.4f", q.giver or "?", q.node.mapID, q.node.x, q.node.y)
      local g = byKey[key]
      if not g then
        g = { name = q.giver, node = q.node, distance = ns.Geo.Distance(start, q.node), quests = {} }
        byKey[key] = g
        givers[#givers + 1] = g
      end
      g.quests[#g.quests + 1] = q
    end
    table.sort(givers, function(a, b) return a.distance < b.distance end)
    -- A town's givers can fall into more than one cluster: one hub per place.
    local hubs, byPlace = {}, {}
    for _, hub in ipairs(ns.Quests.Cluster(givers, math.huge)) do
      local place = ns.Places.NameFor(hub.anchor.node)
      local same = place and byPlace[place]
      if same then
        for _, g in ipairs(hub.givers) do same.givers[#same.givers + 1] = g end
        same.count = same.count + hub.count
        if #hub.anchor.quests > #same.anchor.quests then same.anchor = hub.anchor end
      else
        hub.place = place or ("near " .. (hub.anchor.name or "?"))
        hubs[#hubs + 1] = hub
        if place then byPlace[place] = hub end
      end
    end
    table.sort(hubs, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return a.anchor.distance < b.anchor.distance
    end)
    local first = hubs[1]
    local anchor = first.anchor.node
    local goal = ns.Geo.Node(anchor.mapID, anchor.x, anchor.y, string.format("%s (%s)", first.place, first.anchor.name or "?"))
    local route = goal and ns.Router.Plan(start, goal, net)
    -- With a time budget: the trip to the first hub and one quest must fit.
    local over = route and ctx.budget and route.seconds + perQuest > ctx.budget
    if over and #ctx.overZones < MAX_ZONES then
      ctx.overZones[#ctx.overZones + 1] = { kind = "zone", zone = ns.MapName(z.mapID), mapID = z.mapID, title = "Quest in " .. ns.MapName(z.mapID),
        goal = goal, route = route, trip = route.seconds, seconds = route.seconds + perQuest,
        now = z.now, later = z.later, value = z.value, lowest = z.lowest, highest = z.highest, hubs = hubs, first = first, leads = {} }
    end
    if route and not over then
      -- Where the chains lead: the places their next quests start, other than the first hub.
      local leads, seen = {}, { [first.place] = true }
      for _, q in ipairs(z.later) do
        local place = ns.Places.NameFor(q.node)
        if place and not seen[place] then
          seen[place] = true
          leads[#leads + 1] = place
        end
      end
      -- The trip: pick up every quest you can take at the first hub.
      local title = "Quest in " .. ns.MapName(z.mapID)
      local stops = {}
      for _, g in ipairs(first.givers) do
        for _, q in ipairs(g.quests) do
          stops[#stops + 1] = { node = g.node, group = "pickup", giver = g.name, action = { kind = "pickup", questID = q.id },
            text = string.format("Pick up %s from %s", q.name or ("quest " .. q.id), g.name or "the quest giver") }
        end
      end
      local journey = #stops > 0 and ns.Journey.Plan(start, { title = title, stops = stops }, net) or nil
      out[#out + 1] = {
        kind = "zone", zone = ns.MapName(z.mapID), mapID = z.mapID, title = title,
        goal = goal, route = route, journey = journey, trip = journey and journey.seconds or route.seconds,
        seconds = route.seconds + perQuest, now = z.now, later = z.later, value = z.value,
        lowest = z.lowest, highest = z.highest, hubs = hubs, first = first, leads = leads,
      }
    end
  end
  return out
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
    id = "need" .. need.kind .. (need.icon or ""), kind = need.kind, professionIcon = need.icon,
    category = need.soft and "Worth a visit" or "Due now", title = need.title,
    subtitle = string.format("%s  ·  %s  ·  %s", need.zone, ns.FormatDuration(need.route.seconds), need.why),
    place = capitalize(need.why),
    stats = need.stats or { { "Where", need.zone }, { "Travel", ns.FormatDuration(need.route.seconds) } },
    goal = need.goal, route = need.route, journey = need.journey, details = details,
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
      logged, left = logged + 1, left + (q.seconds or perQuest)
    else
      fresh = fresh + 1
    end
  end
  return fresh, logged, handins, left
end

-- "5 min", or "7 min (your average)" once QuestTimes knows.
local function perQuestText()
  local text = string.format("%d min", math.floor(perQuest / 60 + 0.5))
  if perQuest ~= SECONDS_PER_QUEST then text = text .. " (your average)" end
  return text
end

-- "trip ~4 min + 3 x 5 min per quest + ~4 min left on 2 in your log + 2 x 30 s per hand-in"
local function timeText(option)
  local fresh, logged, handins, left = questCounts(option)
  local parts = { "trip " .. ns.FormatDuration(option.trip) }
  if fresh > 0 then parts[#parts + 1] = string.format("%d x %s per quest", fresh, perQuestText()) end
  if logged > 0 then
    parts[#parts + 1] = string.format("%s left on %d in your log", ns.FormatDuration(left), logged)
  end
  if handins > 0 then parts[#parts + 1] = string.format("%d x %d s per hand-in", handins, HANDIN_SECONDS) end
  return table.concat(parts, " + ")
end

-- Under a quest line, in the tooltip only: what its chain leads to.
local CHAIN = { r = 0.5, g = 0.82, b = 0.68 }

local function chainLine(details, questID)
  local text = ns.Quests.ChainText(questID)
  if text then details[#details + 1] = { text = "    " .. text:gsub("\n", "\n    "), color = CHAIN, more = true } end
end

local function questLines(details, option, ctx)
  for _, q in ipairs(option.quests) do
    local value = ctx.xpMode and string.format("  -  %s XP", formatNumber(q.value)) or ""
    local who = q.inLog and logText(q) or (q.giver and ("  (" .. q.giver .. ")") or "")
    addQuestLine(details, {
      text = string.format("[%d] %s%s%s", q.level or 0, q.name or ("Quest " .. q.id), value, who),
      color = GetQuestDifficultyColor and q.level and GetQuestDifficultyColor(q.level), quest = true,
    }, q.id)
    chainLine(details, q.id)
  end
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
  if option.fitting then
    details[1].text = string.format("Least travel of %d that fit in %d min: ~%s in %s (%s).", option.fitting,
      ctx.budget / 60, amount, ns.FormatDuration(option.seconds), timeText(option))
  end
  if logged + handins > 0 then
    local how = {}
    if handins > 0 then how[#how + 1] = string.format("handing one in takes ~%d s", HANDIN_SECONDS) end
    if logged > 0 then
      how[#how + 1] = string.format("unfinished ones take %s times the share of objectives left",
        perQuestText())
    end
    -- The same on most cards: in the breakdown and tooltip only.
    details[#details + 1] = { text = "Quests in your log count at full XP; " .. table.concat(how, ", ") .. ".",
      color = GREY, more = true }
  end
  if option.estimated > 0 then
    details[#details + 1] = { text = string.format("XP estimated for %s the data has no XP for.",
      plural(option.estimated, "quest")), color = GREY, more = true }
  end
  if not ctx.xpMode then
    details[#details + 1] = { text = "No quest XP data: quests count by level fit.", color = GREY }
  end
  if option.kind == "dungeon" then
    -- Cards say "Group" / "Raid" by the place instead.
    details[#details + 1] = { text = option.raid and "Raid: needs a raid group." or "Dungeon: bring a group.",
      color = GREY, more = true }
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

  -- For the cards: where, then up to three numbers.
  local place = firstPart(option.zone)
  local stats = {}
  local level = option.title and option.title:match("level (%d+)$")
  if level then stats[#stats + 1] = { "Level", level } end
  stats[#stats + 1] = { "Travel", ns.FormatDuration(option.trip) }
  if option.kind == "dungeon" then
    place = string.format("%s  ·  %s  ·  %s", place, option.raid and "Raid" or "Group", why[1])
  elseif option.kind == "handin" then
    stats[#stats + 1] = { "Ready", tostring(handins) }
  elseif option.kind == "finish" then
    stats[#stats + 1] = { "In your log", tostring(logged) }
  elseif option.kind == "quest" then
    local q = option.quests[1]
    stats[#stats + 1] = ctx.xpMode and { "XP", "~" .. formatNumber(option.value) } or { "Level", tostring(q.level or "?") }
  else
    stats[#stats + 1] = { "Quests", handins > 0 and string.format("%d + %d ready", fresh, handins) or tostring(fresh) }
  end
  stats[#stats + 1] = rateStat(option, ctx)

  local CATEGORY = { hub = "Quest hub", handin = "Hand in", finish = "Finish", quest = "Best quest",
    dungeon = option.raid and "Raid" or "Dungeon" }
  local row = {
    id = option.kind .. (option.name or option.title), kind = option.kind, raid = option.raid, title = option.title,
    category = CATEGORY[option.kind],
    subtitle = string.format("%s  ·  %s  ·  %s", firstPart(option.zone),
      ns.FormatDuration(option.trip), table.concat(why, ", ")),
    place = place, stats = stats,
    goal = option.goal, route = option.route, details = details, rate = option.rate,
  }
  if option.journey then
    row.journey = option.journey
    -- A dungeon card keeps its name; the pickups on the way are in the place line.
    if option.kind == "dungeon" then
      local pickups = #option.journey.stops - 1
      if pickups > 0 then row.place = row.place .. string.format("  ·  %s on the way", plural(pickups, "pickup")) end
    else
      row.title = option.journey.title or journeyTitle(option.journey.stops)
    end
    option.journey.title = row.title
    option.journey.def.title = row.title
  end
  return row
end

-- Dungeons without quests for you (or without quest data): Dungeons' own ranking.
local function plainRow(option)
  local r = option.result
  local details = { { text = ns.Quests.Available() and "No quests for it: ranked by level fit and travel time."
    or "Ranked by level fit and travel time. Install a Wayfinder data addon for its quests and XP.", color = GOLD } }
  for _, line in ipairs(r.details or {}) do details[#details + 1] = line end
  local stats = {}
  local level = option.title and option.title:match("level (%d+)$")
  if level then stats[1] = { "Level", level } end
  stats[#stats + 1] = { "Travel", ns.FormatDuration(option.trip) }
  return {
    id = "plain" .. (r.id or option.name), kind = "dungeon", raid = option.raid, title = option.title,
    category = option.raid and "Raid" or "Dungeon",
    subtitle = string.format("%s  ·  %s  ·  fits your level", firstPart(r.zone),
      ns.FormatDuration(option.trip)),
    place = string.format("%s  ·  %s  ·  fits your level", firstPart(r.zone), option.raid and "Raid" or "Group"),
    stats = stats,
    goal = r.goal, route = r.route, details = details,
  }
end

-- "Don't miss": what makes the quest stand out, in plain words; its XP doesn't rank it.
local function notableRow(option, ctx)
  local q = option.quests[1]
  local details = { { text = string.format("Don't miss: %s Shown whatever its XP: it's %s away.",
    option.reasons[1].text, ns.FormatDuration(option.travel)), color = GOLD } }
  for i = 2, #option.reasons do details[#details + 1] = { text = option.reasons[i].text, color = NOTABLE } end
  local line = string.format("[%d] %s%s", q.level or 0, q.name or ("Quest " .. q.id), q.inLog and "  (in your log)" or "")
  if ctx.xpMode then line = line .. string.format("  -  %s XP", formatNumber((questValue(q, ctx)))) end
  details[#details + 1] = { text = line, quest = true,
    color = GetQuestDifficultyColor and q.level and GetQuestDifficultyColor(q.level) }
  local stats = { { "Level", tostring(q.level or "?") }, { "Travel", ns.FormatDuration(option.travel) } }
  if option.trip > option.travel then stats[#stats + 1] = { "Trip", ns.FormatDuration(option.trip) } end
  return {
    id = "notable" .. q.id, kind = "notable", category = "Don't miss", title = option.title,
    subtitle = string.format("%s  ·  %s  ·  %s", option.zone, ns.FormatDuration(option.travel), option.tag),
    place = string.format("%s  ·  %s", option.tag, option.zone), stats = stats,
    goal = option.goal, journey = option.journey, details = details,
  }
end

local function zoneRow(z, ctx)
  local levels = z.lowest == z.highest and ("Level " .. z.lowest) or string.format("Levels %d-%d", z.lowest, z.highest)
  local details = { {
    text = string.format("Questing zone: %s you can take now%s%s.", plural(#z.now, "quest"),
      #z.later > 0 and string.format(", %d more as their chains unlock", #z.later) or "",
      ctx.xpMode and string.format(", ~%s XP in all", formatNumber(z.value)) or ""),
    color = GOLD,
  } }
  details[#details + 1] = { text = string.format("Start at %s: the trip picks up its %s.", z.first.place,
    plural(z.first.count, "quest")) }
  local next = {}
  for i = 2, math.min(#z.hubs, ZONE_HUBS + 1) do
    next[#next + 1] = string.format("%s (%d)", z.hubs[i].place, z.hubs[i].count)
  end
  if #next > 0 then details[#details + 1] = { text = "Then: " .. table.concat(next, ", ") .. "." } end
  if #z.leads > 0 then
    details[#details + 1] = { text = "Chains lead on to " .. table.concat(z.leads, ", ", 1, math.min(#z.leads, 3)) .. "." }
  end
  -- The quests worth the most, the ones you can take now first.
  local listed = {}
  for _, q in ipairs(z.now) do listed[#listed + 1] = q end
  table.sort(listed, function(a, b) return (a.value or 0) > (b.value or 0) end)
  for i = 1, math.min(#listed, ZONE_QUEST_LINES) do
    local q = listed[i]
    local value = ctx.xpMode and string.format("  -  %s XP", formatNumber(q.value)) or ""
    addQuestLine(details, {
      text = string.format("[%d] %s%s  (%s)", q.level or 0, q.name or ("Quest " .. q.id), value, q.giver or "?"),
      color = GetQuestDifficultyColor and q.level and GetQuestDifficultyColor(q.level), quest = true, more = i > 2,
    }, q.id)
    chainLine(details, q.id)
  end
  local quests = tostring(#z.now)
  if #z.later > 0 then quests = string.format("%d + %d", #z.now, #z.later) end
  return {
    id = "zone" .. z.mapID, kind = "zone", category = "Questing zone", title = z.title,
    subtitle = string.format("%s  ·  %s  ·  %s  ·  start at %s", z.zone, levels, ns.FormatDuration(z.trip), z.first.place),
    place = string.format("%s  ·  start at %s", levels, z.first.place),
    stats = { { "Quests", quests }, ctx.xpMode and { "XP", "~" .. formatNumber(z.value) } or { "Hubs", tostring(#z.hubs) },
      { z.journey and "Trip" or "Travel", ns.FormatDuration(z.trip) } },
    goal = z.goal, route = z.route, journey = z.journey, details = details,
  }
end

---------------------------------------------------------------- page

local function summaryFor(ctx, needs)
  local level = UnitLevel("player")
  local ranking = ctx.xpMode and "the best of each kind, by XP per minute" or "the best of each kind, by quests per hour"
  local parts = {}
  if needs > 0 then
    parts[1] = string.format("Level %d: |cff7fd1ae%s due|r first, then %s.", level, plural(needs, "thing"), ranking)
  else
    parts[1] = string.format("Level %d: %s from here.", level, ranking)
  end
  if ctx.budget then
    local minutes = ctx.budget / 60
    if ctx.nothingFits then
      parts[1] = string.format("Nothing to quest fits in %d min: the quickest option, a bit over%s.", minutes,
        needs > 0 and string.format(", after |cff7fd1ae%s due|r", plural(needs, "thing")) or "")
    elseif needs > 0 then
      parts[1] = string.format("Fits in %d min: |cff7fd1ae%s due|r first, then %s; hand-ins and finishes by least travel.",
        minutes, plural(needs, "thing"), ranking)
    else
      parts[1] = string.format("Fits in %d min: %s; hand-ins and finishes by least travel.", minutes, ranking)
    end
  end
  if not ctx.quests then
    parts[#parts + 1] = "Install a Wayfinder data addon for quest hubs and XP; dungeons are ranked by level fit and travel time."
  elseif level >= MAX_LEVEL then
    parts[#parts + 1] = "At the level cap quests give no XP, so options are ranked by quests per hour."
  elseif not ctx.db then
    parts[#parts + 1] = "No quest XP in the data: ranked by quests per hour, weighted by level fit."
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
        ctx.quests and "" or " without quest data")
    end
  end
  for _, note in ipairs(ctx.notes) do parts[#parts + 1] = note end
  return table.concat(parts, " ")
end

-- How long each part of the last refresh took, for /wf debug.
local parts
local function timed(name, fn, ...)
  local started = debugprofilestop and debugprofilestop()
  local a, b, c = try(fn, ...)
  if started then parts[#parts + 1] = string.format("%s %.0f", name, debugprofilestop() - started) end
  return a, b, c
end

local function build()
  parts = {}
  local start = ns.Geo.PlayerNode()
  if not start then
    summary = nil
    return {}, "Can't read your position here."
  end
  local net = ns.Network.Build()
  local level = UnitLevel("player")
  local db = xpTable()
  perQuest = ns.QuestTimes.Seconds() or SECONDS_PER_QUEST
  local ctx = { level = level, db = db, xpMode = db ~= nil and level < MAX_LEVEL,
    quests = ns.Quests.Available() and true or false, notes = {}, unplaced = 0, overZones = {} }
  ctx.log = try(readLog) or {}
  -- A time budget (see "time budget" below): what doesn't fit is left out.
  local budget = ForYou.Budget()
  ctx.budget = budget and budget * 60
  local function fits(seconds) return not ctx.budget or seconds <= ctx.budget end
  local function keep(list, test)
    local out = {}
    for _, item in ipairs(list) do if test(item) then out[#out + 1] = item end end
    return out
  end
  local function needSeconds(n) return n.journey and n.journey.seconds or seconds(n.route) end

  local needs = {}
  local function addNeed(n) if n then needs[#needs + 1] = n end end
  addNeed(timed("training", trainingNeed, ctx))
  for _, n in ipairs(timed("vendors", vendorNeeds, ctx) or {}) do addNeed(n) end
  addNeed(timed("flight", flightNeed, ctx, start, net))
  addNeed(timed("repair", repairSoonNeed))
  for _, n in ipairs(timed("professions", professionNeeds, start, net) or {}) do addNeed(n) end
  local function priority(n) return (n.soft and SOFT_PRIORITY or 0) + PRIORITY[n.kind] end
  table.sort(needs, function(a, b) return priority(a) < priority(b) end)
  if ctx.budget then needs = keep(needs, function(n) return fits(needSeconds(n)) end) end
  while #needs > MAX_NEEDS do table.remove(needs) end

  -- Every option, ranked by XP per minute (the rank shown on each card); then
  -- the best of each kind. Journeys are planned only for those, and ranked
  -- again with their real trip time.
  local hubs = timed("hubs", hubOptions) or {}
  local handins = timed("handins", handinOptions, ctx, start, net) or {}
  local finishes = timed("finish", finishOptions, ctx, start, net) or {}
  local dungeons, plain, held = timed("dungeons", dungeonOptions, ctx)
  dungeons, plain, held = dungeons or {}, plain or {}, held or {}
  -- With quest data, a dungeon without quests for you isn't worth the run in
  -- Forever (its mobs give little XP); without it there's nothing better to go on.
  if ctx.quests then plain = {} end
  for _, list in ipairs({ hubs, handins, finishes, dungeons }) do
    for _, option in ipairs(list) do score(option, ctx) end
  end
  local function byRate(a, b)
    if a.rate ~= b.rate then return a.rate > b.rate end
    return a.seconds < b.seconds
  end
  -- With a budget, what doesn't fit is kept aside: the quickest of it is
  -- offered when nothing fits. Dungeons need BUDGET_DUNGEON minutes.
  local over = {}
  local questHubs = hubs -- the best quest can come from a hub too big for the budget
  if ctx.budget then
    local dungeonTime = budget >= BUDGET_DUNGEON
    for _, list in ipairs({ handins, finishes, dungeonTime and dungeons or {} }) do
      for _, option in ipairs(list) do over[#over + 1] = option end
    end
    local function optionFits(o) return fits(o.seconds) end
    hubs, handins, finishes = keep(hubs, optionFits), keep(handins, optionFits), keep(finishes, optionFits)
    dungeons = dungeonTime and keep(dungeons, optionFits) or {}
    plain = dungeonTime and keep(plain, function(o) return fits(o.trip) end) or {}
    if not dungeonTime then held = {} end
    table.sort(over, byRate)
    for i, option in ipairs(over) do option.overRank = i end
  end
  local all = {}
  for _, list in ipairs({ hubs, handins, finishes, dungeons }) do
    for _, option in ipairs(list) do all[#all + 1] = option end
  end
  table.sort(all, byRate)
  for i, option in ipairs(all) do option.rank = i end
  local function best(list)
    table.sort(list, byRate)
    return list[1]
  end

  local picks = {}
  local function pick(option) if option then picks[#picks + 1] = option end end
  local function journeyFor(option)
    if #option.stops > 0 then timed("trips", questJourney, option, ctx, start, net) end
  end
  -- With a budget: the least travel first, the first whose planned trip still fits.
  local function quickest(list)
    table.sort(list, function(a, b)
      if a.trip ~= b.trip then return a.trip < b.trip end
      return a.seconds < b.seconds
    end)
    for i = 1, math.min(#list, BUDGET_TRIES) do
      local option = list[i]
      journeyFor(option)
      if fits(option.seconds) then
        option.fitting = #list
        return option
      end
    end
  end
  local handin, finish
  if ctx.budget then
    handin, finish = quickest(handins), quickest(finishes)
  else
    handin, finish = best(handins), best(finishes)
    if handin then journeyFor(handin) end
    if finish then journeyFor(finish) end
  end
  pick(handin)
  pick(finish)
  local dungeon = best(dungeons)
  local quest = timed("best quest", bestQuestOption, questHubs, ctx, start, net)
  if quest then
    quest.rank = 1
    for _, option in ipairs(all) do
      if option.rate > quest.rate then quest.rank = quest.rank + 1 end
    end
    if not fits(quest.seconds) then
      over[#over + 1] = quest
      quest.overRank = quest.rank
      quest = nil
    end
  end
  pick(quest)
  table.sort(picks, ctx.budget and function(a, b) return a.seconds < b.seconds end or byRate)
  local notable = timed("don't miss", notableOption, hubs, ctx, start, net,
    quest and { [quest.quests[1].id] = true } or {})

  -- The other dungeons for your level, named on the dungeon card; and the
  -- ones held back until more of their quests open.
  local others = {}
  for _, list in ipairs({ dungeons, plain }) do
    for _, option in ipairs(list) do
      if option ~= dungeon and option ~= (not dungeon and plain[1] or nil) then
        local name, level = (option.title or ""):match("^Run (.-)%s+·%s+level (%d+)$")
        others[#others + 1] = name and string.format("%s (%s)", name, level) or option.name
      end
    end
  end
  table.sort(held, function(a, b) return (a.opensAt or math.huge) < (b.opensAt or math.huge) end)
  local soon = {}
  for i = 1, math.min(#held, 3) do
    local h = held[i]
    soon[#soon + 1] = string.format("%s %s (%d more quest%s)", h.name,
      h.opensAt and ("at level " .. h.opensAt) or "after earlier quests", #h.later, #h.later == 1 and "" or "s")
  end

  local results = {}
  -- With a budget each card shows its time (`badge`, UI/Cards.lua).
  local function add(row, seconds)
    if not row or #results >= MAX_RESULTS then return end
    if ctx.budget and seconds then row.badge = ns.FormatDuration(seconds) end
    results[#results + 1] = row
  end
  -- What's due, then the quest not to miss, then the rest of the needs.
  for _, need in ipairs(needs) do
    if not need.soft then add(needRow(need), needSeconds(need)) end
  end
  if notable and (not ctx.budget or fits(notable.seconds or notable.trip)) then
    add(notableRow(notable, ctx), notable.seconds or notable.trip)
  end
  for _, need in ipairs(needs) do
    if need.soft then add(needRow(need), needSeconds(need)) end
  end
  local zones = timed("zones", zoneOptions, ctx, start, net) or {}
  for _, zone in ipairs(zones) do add(zoneRow(zone, ctx), zone.seconds) end
  local dungeonRow, dungeonSeconds
  if dungeon then
    timed("dungeon trip", dungeonJourney, dungeon, ctx, start, net)
    if fits(dungeon.seconds) then
      dungeonRow, dungeonSeconds = optionRow(dungeon, dungeon.rank, #all, ctx), dungeon.seconds
    else
      over[#over + 1] = dungeon
      dungeon.overRank = dungeon.rank
    end
  elseif plain[1] then
    -- Without quest data: the best one by level fit and travel time.
    dungeonRow, dungeonSeconds = plainRow(plain[1]), plain[1].trip
  end
  if dungeonRow and #others > 0 then
    table.insert(dungeonRow.details, 2, { text = "Also for your level: " .. table.concat(others, ", ", 1, math.min(#others, 4)) .. "." })
  end
  if #soon > 0 then
    local line = "Dungeons later, once you can take most of their quests: " .. table.concat(soon, ", ") .. "."
    if dungeonRow then
      -- In the dungeon card's tooltip, not on the card.
      table.insert(dungeonRow.details, 2, { text = line, more = true })
    else
      ctx.notes[#ctx.notes + 1] = line
    end
  end
  add(dungeonRow, dungeonSeconds)
  for _, option in ipairs(picks) do add(optionRow(option, option.rank, #all, ctx), option.seconds) end

  -- Nothing to quest fits the budget: the quickest option anyway, "a bit over".
  if ctx.budget and #zones == 0 and not dungeonRow and #picks == 0 then
    for _, z in ipairs(ctx.overZones) do over[#over + 1] = z end
    local nearest
    for _, option in ipairs(over) do
      if not nearest or option.seconds < nearest.seconds then nearest = option end
    end
    if nearest then
      local row
      if nearest.kind == "zone" then
        row = zoneRow(nearest, ctx)
      else
        if nearest.kind == "handin" or nearest.kind == "finish" then journeyFor(nearest) end
        row = optionRow(nearest, nearest.overRank or 1, #over, ctx)
      end
      row.category = (row.category or "") .. "  ·  a bit over"
      row.details[1].text = string.format("Nothing fits in %d min; this is the quickest. ", budget) .. row.details[1].text
      row.over = true
      ctx.nothingFits = true
      add(row, nearest.seconds)
    end
  end

  local due = 0
  for _, need in ipairs(needs) do if not need.soft then due = due + 1 end end
  summary = summaryFor(ctx, due)
  return results, nil, net
end

function ForYou.SummaryText()
  return summary or "What to do next, for this character, from where you stand."
end

function ForYou.EmptyText()
  return "Nothing to suggest from here yet. Visit a trainer for your class, open a flight map, or install "
    .. "a Wayfinder data addon for quest hubs and XP estimates."
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
  quest = "Interface\\Icons\\INV_Scroll_03", zone = "Interface\\Icons\\INV_Misc_Spyglass_03",
  notable = "Interface\\Icons\\INV_Misc_Gem_Variety_02",
}

local function iconFor(r)
  if r.kind == "profession" and r.professionIcon then return r.professionIcon end
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
    ForYou.lastParts = parts and table.concat(parts, ", ") or nil
  end
  cache = now and { at = now, results = results, err = err, net = net } or nil
  pcall(ForYou.CheckNew, results)
  return results, err, net
end

function ForYou.Invalidate()
  cache = nil
end

-- Vendors you need to visit now (repairs, ammo, food, a repairer close by):
-- { {title, goal, why}, ... }, for suggestions along a trip (OnTheWay.lua).
function ForYou.ShoppingNeeds()
  local ctx = { level = UnitLevel("player"), notes = {} }
  local out = {}
  for _, n in ipairs(try(vendorNeeds, ctx) or {}) do out[#out + 1] = n end
  local soon = try(repairSoonNeed)
  if soon then out[#out + 1] = soon end
  return out
end

---------------------------------------------------------------- time budget

-- "I have 20 minutes": ns.charDB.budgetMinutes (nil: no limit). With one,
-- build() leaves out what its estimate says won't fit (trip plus quest time,
-- as score() counts it), picks hand-ins and finishes by least travel, shows
-- a zone only when the trip to its first hub and one quest fit, and no
-- dungeon under BUDGET_DUNGEON minutes. Each card shows its time.
function ForYou.Budget()
  local minutes = ns.charDB and tonumber(ns.charDB.budgetMinutes)
  return minutes and minutes > 0 and minutes or nil
end

function ForYou.SetBudget(minutes)
  ns.charDB.budgetMinutes = minutes
  ForYou.Invalidate()
  if ns.Panel and ns.Panel.IsShown() then ns.Panel.Refresh() end
end

-- The buttons beside the summary line (UI/Panel.lua, page.controls).
ForYou.controls = {
  label = "Time:",
  tooltip = "How long you have: For you only suggests what fits.",
  choices = { { text = "15", value = 15 }, { text = "30", value = 30 }, { text = "60", value = 60 },
    { text = "Any", value = false } },
  get = function() return ForYou.Budget() or false end,
  set = function(value) ForYou.SetBudget(value or nil) end,
}

ns.RegisterCommand("time", "/wf time <minutes> | off - For you suggests only what fits in that time", function(rest)
  local arg = (rest or ""):lower()
  local minutes = tonumber(arg:match("^(%d+)"))
  if arg == "off" or arg == "none" or arg == "any" then
    ForYou.SetBudget(nil)
    ns.print("time budget off: For you suggests anything")
  elseif minutes and minutes > 0 then
    ForYou.SetBudget(minutes)
    ns.print(string.format("For you suggests what fits in %d min (/wf time off to stop)", minutes))
  elseif arg == "" then
    local current = ForYou.Budget()
    ns.print(current and string.format("time budget: %d min (/wf time off to stop)", current)
      or "no time budget (/wf time 20: only what fits in 20 minutes)")
  else
    ns.print("/wf time <minutes> | off")
  end
end)

---------------------------------------------------------------- new journeys

-- Major suggestions: somewhere to quest, a dungeon, spells to train, a
-- profession's next rank. One the character hasn't been shown before pops up
-- as "New journey available" (UI/Fanfare.lua). The first look only learns
-- what's there, so an update doesn't bring a flood.
local function major(r)
  return r.category == "Questing zone" or r.category == "Dungeon" or r.category == "Raid"
    or r.kind == "train" or r.kind == "profession"
end

function ForYou.CheckNew(results)
  local first = ns.charDB.seenCards == nil
  ns.charDB.seenCards = ns.charDB.seenCards or {}
  local seen = ns.charDB.seenCards
  for _, r in ipairs(results or {}) do
    if major(r) then
      local key = (r.id or "?") .. "|" .. (r.title or "")
      if not seen[key] then
        seen[key] = true
        if not first and ns.Fanfare then ns.Fanfare.NewJourney(r) end
      end
    end
  end
end

-- Looked at in the background when things change: a level, a quest handed
-- in, a new zone (not in combat: it plans many routes).
local CHECK_DELAY = 4
local checking = false

local function check()
  checking = false
  if InCombatLockdown and InCombatLockdown() then
    checking = true
    return
  end
  ForYou.Invalidate()
  local results = ForYou.Results()
  ForYou.CheckNew(results)
end

local function soon()
  if checking then return end
  checking = true
  C_Timer.After(CHECK_DELAY, check)
end

ns.On("PLAYER_LEVEL_UP", soon)
ns.On("QUEST_TURNED_IN", soon)
ns.On("ZONE_CHANGED_NEW_AREA", soon)
ns.On("PLAYER_REGEN_ENABLED", function() if checking then soon() end end)

-- Registered before the panel's own listeners, so its refresh sees fresh data.
ns.Listen("DATA_CHANGED", ForYou.Invalidate)
ns.Listen("FLIGHTS_CHANGED", ForYou.Invalidate)
ns.On("ZONE_CHANGED_NEW_AREA", ForYou.Invalidate)

ns.RegisterPage(ForYou)

ns.RegisterCommand("next", "/wf next - what to do next (opens the For you page)", function()
  ForYou.Invalidate()
  ns.Panel.Search(ForYou.id)
end)
