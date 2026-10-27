local _, ns = ...

-- "For you" page, the panel's first tab: a handful of things to do next for
-- this character, right now, as suggestion cards (each a journey) and a row
-- of observations ("Good to know" tiles).
--
-- Suggestions come from the candidate providers:
--   Don't miss     the quest that stands out most (Notable.lua: a class quest, a
--                  reward for your class, a Forever-only quest...) that you can
--                  take or have in your log within NOTABLE_SECONDS of travel;
--   Hand in        the best group of quests ready to hand in;
--   Finish         the best group of unfinished quests in your log;
--   Best quest     the quest worth the most XP that you can pick up nearby, as a
--                  whole-quest journey;
--   Questing zone  where to quest at your level, anywhere (up to MAX_ZONES);
--   Dungeon        the best dungeon, with its quests picked up on the way;
--   Profession     a profession's next rank you can train now.
-- Each gets a relevance score (see "relevance" below): suitability,
-- proximity, progression, novelty and intent, 0..1 each, weighted; XP per
-- minute counts inside suitability only. The cards are then picked by role
-- for each page of three: a continuation (the most relevant whose strongest
-- part is progression), an exploration (strongest part novelty, somewhere or
-- something else) and an alternative (yet another kind). Every card says in
-- one sentence what its two strongest parts are (`why`).
--
-- Observations (ForYou.Observations) are the needs: repairs, ammo, food,
-- spells to train, an undiscovered flight path, gear wearing down, a
-- profession at its cap, quests ready to hand in, new spells at the next
-- level, full bags and a vendor nearby. Each has at most one action: a
-- detour (a stop to add to the journey), a side page to show, or directions.
--
-- XP comes from the data's quest XP table (ns.Data.QuestXP). Without it,
-- quests count by level fit, and the summary line says so. Without quest
-- data there are no hubs or dungeon quests, so dungeons are ranked by level
-- fit and travel time, as on the Find page.
--
-- Quests already in your log count too, at their full XP; only the time left
-- for them is counted. Ones ready to hand in are journeys of their own ("Hand
-- in 3 quests in Lakeshire"); unfinished ones close together are one
-- whole-quest journey ("Finish 2 quests near Lakeshire"); a dungeon's quests
-- in your log count toward it. A card whose journey has a quest your journey
-- already has, or a dungeon your journey goes to, isn't shown.

-- Shown as Adventure Guide style cards (UI/Cards.lua) on a wider panel.
local ForYou = { id = "foryou", label = "For you", order = 10, searchable = false, layout = "cards" }
ns.ForYou = ForYou

local SECONDS_PER_QUEST = 300   -- time to do one quest, on top of the trip (until QuestTimes has
                                -- learned how long yours take: perQuest)
local MAX_RESULTS = 9           -- cards the page shows (three pages)
local REPAIR_SOON = 0.75        -- gear at or under this: repair if a vendor is close
local REPAIR_NEAR_SECONDS = 120 -- "close" for that
local TRAIN_LEVELS_STALE = 2    -- levels since your last trainer visit before new spells are likely
local ZONE_MIN_QUESTS = 4       -- quests you can take now for a zone to get a card
local DUNGEON_QUEST_SHARE = 0.6 -- of a dungeon's quests, the share you need to be able to take now
                                -- (mobs in Forever's dungeons give little XP: the quests make the run)
local MAX_ZONES = 3             -- "Questing zone" cards
local HOME_LEVEL = 10           -- below this, your starting zone's card comes first and no other starting zone gets one
local ZONE_HUBS = 3             -- hubs named on a zone card after the first
local ZONE_QUEST_LINES = 5      -- quests listed on a zone card
local CACHE_SECONDS = 5         -- a refresh is reused this long (cleared early on data or zone changes)
local MAX_LEVEL = 60            -- the level cap (Forever and Classic Era): quests give no XP there
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
local BAGS_NEARLY_FULL = 2      -- free bag slots at or under this: worth knowing
local VENDOR_NEAR_SECONDS = 120 -- a vendor this close is worth a tile on its own
local HANDIN_OBSERVATIONS = 2   -- hand-in groups mentioned, nearest first
local ABILITY_LEVELS_AHEAD = 2  -- new spells at a level this close are worth knowing about

-- Relevance (docs/DESIGN.md "Relevance"): the five parts and their weights.
local WEIGHTS = { suitability = 0.30, proximity = 0.20, progression = 0.20, novelty = 0.15, intent = 0.15 }
local PART_NAMES = { "suitability", "proximity", "progression", "novelty", "intent" }
local NEAR_SECONDS = 120        -- proximity 1.0 up to this
local MID_SECONDS = 480         -- proximity 0.5 here
local FAR_SECONDS = 1500        -- proximity 0 from here
local SHOWN_DECAY = 0.04        -- novelty lost per refresh a card was shown on and never started
local SHOWN_FLOOR = 0.6         -- never below this share of its novelty
ForYou.WEIGHTS = WEIGHTS

-- The starting zones (uiMapIDs) and each race's own: Elwynn Forest, Durotar,
-- Dun Morogh, Teldrassil, Tirisfal Glades, Mulgore.
local RACE_HOME = { [1] = 1429, [2] = 1411, [3] = 1426, [4] = 1438, [5] = 1420, [6] = 1412, [7] = 1426, [8] = 1411 }
local STARTING_ZONES = {}
for _, mapID in pairs(RACE_HOME) do STARTING_ZONES[mapID] = true end

local WAITING = "Getting the quest data ready..."
local WORKING = "Working out what's next..."

local GOLD = { r = 1, g = 0.82, b = 0 }
local GREY = { r = 0.6, g = 0.6, b = 0.6 }
local NOTABLE = { r = 0.77, g = 0.55, b = 1 }

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

local function clamp(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

-- A provider error leaves its part out of the page instead of blanking it.
local function try(fn, ...)
  local ok, a, b, c = ns.Protect(fn, ...)
  if ok then return a, b, c end
  geterrorhandler()(a)
  return nil
end

-- Runs a provider, reporting an error instead of breaking the page.
local function run(provider)
  local ok, results, _, net = ns.Protect(provider)
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

-- The zone (uiMapID) a node is in, for "the same zone as" comparisons.
local function zoneOf(node)
  return node and (ns.Geo.ZonePoint(node)) or nil
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

-- A journey planned for a card carries the card's kind, so a start of it
-- (JOURNEY_STARTED) can be learned as intent (below).
local function plan(start, def, net, kind)
  local journey = ns.Journey.Plan(start, def, net)
  if journey and journey.def then journey.def.kind = journey.def.kind or kind end
  return journey
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
-- quest takes perQuest unless it says otherwise (log quests: q.seconds). The
-- rate only feeds suitability (XP for the time, against the best on offer).
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

---------------------------------------------------------------- needs

-- The needs feed the observations (ForYou.Observations): each is { kind,
-- text, highlights, urgency, goal, route, stop? (a detour), page? (a side
-- page to show) }. The old card fields (title, zone, why, details) are kept
-- for OnTheWay (ShoppingNeeds) and the tests.

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
    kind = "train", soft = true, urgency = 0.35, title = string.format("Visit your trainer in %s", place),
    zone = best.zone, goal = best.goal, route = best.route,
    why = string.format("new spells likely at level %d", ctx.level),
    text = string.format("New spells are likely at level %d (%s): your trainer is in %s, %s away.", ctx.level, since,
      place, ns.FormatDuration(best.route.seconds)),
    highlights = { string.format("level %d", ctx.level) },
    details = { { text = "Trainer: " .. best.title } },
  }
end

local function trainingNeed(ctx)
  local s = ns.Trainers.SpellSummary(true)
  -- Spell data (no trainer visit yet) that has nothing for you: nothing to say.
  if s and s.fromData and s.trainable == 0 then return nil end
  -- All you could learn you left at the trainer: nothing until there's more.
  if s and s.trainable == 0 and s.skipped > 0 then return nil end
  if not (s and s.trainable > 0) then return likelyTraining(ctx, s) end
  local spells = plural(s.trainable, "new spell")
  local cost = s.costUnknown and "?" or ns.FormatMoney(s.cost)
  if not s.costUnknown and GetMoney() < s.cost then
    return {
      kind = "train", soft = true, urgency = 0.3, title = capitalize(spells) .. " to train",
      text = string.format("%s to train once you have %s.", capitalize(spells), ns.FormatMoney(s.cost)),
      highlights = { spells, ns.FormatMoney(s.cost) }, page = "trainers", pageLabel = "Show spells",
      why = "not affordable yet", spells = s.names,
    }
  end
  local best = (try(ns.Trainers.Results) or {})[1]
  if not (best and best.route) then return nil end
  local place = placeName(best.goal, best.zone)
  -- The spells themselves, first thing in the details.
  local details, level = {}, UnitLevel("player")
  local services, _, cs = ns.Trainers.Services()
  for _, sp in ipairs(services or {}) do
    if ns.Trainers.CanTrain(sp, level, cs and cs.level) and not ns.Trainers.Skipped(sp) then
      details[#details + 1] = { text = string.format("%s%s%s", sp.name, sp.rank and (" (" .. sp.rank .. ")") or "",
        sp.cost and ("  -  " .. ns.FormatMoney(sp.cost)) or "") }
    end
  end
  details[#details + 1] = { text = "Trainer: " .. best.title, more = #details > 0 }
  if s.skipped > 0 then
    details[#details + 1] = { text = string.format("Not counted: %s you left at the trainer.",
      plural(s.skipped, "spell")) }
  end
  local highlights = { spells }
  if not s.costUnknown then highlights[#highlights + 1] = cost end
  return {
    kind = "train", urgency = 0.7,
    title = string.format("Train %s in %s", spells, place),
    zone = best.zone, goal = best.goal, route = best.route,
    why = s.costUnknown and spells or string.format("%s for %s", spells, cost),
    text = string.format("%s to train%s at %s in %s, %s away.", capitalize(spells),
      s.costUnknown and "" or (" for " .. cost), best.title, place, ns.FormatDuration(best.route.seconds)),
    highlights = highlights,
    details = details, spells = s.names,
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

-- Free and total bag slots, or nil when the bag API is missing.
local function bagSpace()
  local container = C_Container
  local numSlots = container and container.GetContainerNumSlots or GetContainerNumSlots
  local numFree = container and container.GetContainerNumFreeSlots or GetContainerNumFreeSlots
  if type(numSlots) ~= "function" or type(numFree) ~= "function" then return nil end
  local free, total = 0, 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    local n = numSlots(bag) or 0
    if n > 0 then
      total = total + n
      free = free + (tonumber((numFree(bag))) or 0)
    end
  end
  if total == 0 then return nil end
  return free, total
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
local VENDOR_URGENCY = { repair = 0.9, ammo = 0.7, food = 0.5 }

local function vendorWhy(need, p, left)
  if need == "repair" then
    if (p.durability or 1) <= 0 then return "some gear is broken" end
    return string.format("gear at %d%%", math.floor(p.durability * 100 + 0.5))
  end
  if left == 0 then return need == "ammo" and "no ammo left" or "no food left" end
  return string.format("%d %s left", left, need == "ammo" and "ammo" or "food & drink")
end

local function vendorUrgency(need, p, left)
  if need == "repair" then return (p.durability or 1) <= 0 and 1 or VENDOR_URGENCY.repair end
  if left == 0 then return VENDOR_URGENCY[need] + 0.25 end
  return VENDOR_URGENCY[need]
end

-- Repairs (gear at 50% or lower), ammo and food when running low: the fastest
-- vendor for each; a vendor that covers several gets one observation.
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
    local r, verbs, whys, highlights, urgency = row.vendor, {}, {}, {}, 0
    local name = r.goal.label or r.title
    for _, need in ipairs(row.needs) do
      verbs[#verbs + 1] = VENDOR_VERB[need]
      whys[#whys + 1] = vendorWhy(need, p, due[need])
      highlights[#highlights + 1] = whys[#whys]:match("%d+%%") or whys[#whys]:match("^%d+ %S+") or whys[#whys]
      urgency = math.max(urgency, vendorUrgency(need, p, due[need]))
    end
    local what = table.concat(verbs, " and ")
    local first = row.needs[1]
    out[#out + 1] = {
      kind = first, urgency = urgency,
      title = string.format("%s at %s", capitalize(what), name),
      zone = ns.MapName(r.goal.mapID), goal = r.goal, route = r.route,
      why = table.concat(whys, ", "),
      text = string.format("%s: %s at %s, %s away.", capitalize(table.concat(whys, ", ")), what, name,
        ns.FormatDuration(r.route.seconds)),
      highlights = highlights,
      details = r.details,
      stop = { node = r.goal, text = string.format("%s at %s", capitalize(what), name),
        phrase = string.format("%s at %s", what, name) },
    }
  end
  return out
end

-- A profession's next rank you can train now, as a journey (a suggestion
-- card); at your cap (you can't skill up any more) it is an observation too.
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
        -- The journey: go there and buy the rank (done when your skill cap goes up).
        local title = string.format("Train %s %s in %s", rank.name, p.name, place)
        local stop = { node = trainer.node, npc = trainer.name,
          text = string.format("Train %s %s at %s", rank.name, p.name, trainer.name),
          action = { kind = "train", profession = p.name, cap = have.cap, npc = trainer.name } }
        local journey = plan(start, { title = title, stops = { stop } }, net, "profession")
        out[#out + 1] = {
          kind = "profession", capped = capped, icon = p.icon, journey = journey, profession = p.name,
          title = title, urgency = 0.6,
          zone = ns.MapName(trainer.node.mapID), goal = trainer.node, route = route,
          trip = journey and journey.seconds or route.seconds,
          why = string.format("%s %d/%d%s", p.name, have.rank, have.cap, capped and ", at your cap" or ""),
          text = string.format("%s is at its cap (%d/%d): %s lets it go up to %d, at %s in %s, %s away.", p.name,
            have.rank, have.cap, rank.name, rank.cap, trainer.name, place, ns.FormatDuration(route.seconds)),
          highlights = { string.format("%d/%d", have.rank, have.cap), rank.name },
          stats = { { "Skill", string.format("%d/%d", have.rank, have.cap) }, { "Next", rank.name },
            { "Travel", ns.FormatDuration(route.seconds) } },
          details = details,
          stop = copyStop(stop),
          rankName = rank.name, rankCap = rank.cap, have = have,
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
    kind = "repair", soft = true, urgency = 0.4, title = "Repair at " .. name,
    zone = ns.MapName(best.goal.mapID), goal = best.goal, route = best.route,
    why = string.format("gear at %d%%, a repairer close by", percent),
    text = string.format("Gear at %d%%: %s repairs, %s away.", percent, name, ns.FormatDuration(best.route.seconds)),
    highlights = { string.format("%d%%", percent) },
    details = best.details,
    stop = { node = best.goal, text = "Repair at " .. name, phrase = "repair at " .. name },
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
  -- Head for the flight master's own spot when Wayward has recorded them.
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
    kind = "flight", urgency = 0.5,
    title = string.format("Learn the %s flight path", town),
    zone = ns.MapName(best.mapID), goal = stopNode, route = route,
    why = "not discovered yet",
    text = string.format("The %s flight path is %s away and you haven't learned it: later journeys get faster.", town,
      ns.FormatDuration(route.seconds)),
    highlights = { town },
    details = {},
    stop = { node = stopNode, text = string.format("Talk to %s to learn %s",
        talkTo and (talkTo .. ", the flight master,") or "the flight master", town),
      phrase = string.format("learn the %s flight path", town) },
  }
end

-- New spells at the next level or two (from the trainer's list or the class
-- spell data), and where your trainer is.
local function abilitiesNeed(ctx)
  local s = ns.Trainers.SpellSummary(true)
  if not (s and s.nextLevel and s.nextCount > 0 and s.nextLevel - ctx.level <= ABILITY_LEVELS_AHEAD) then return nil end
  local best = (try(ns.Trainers.Results) or {})[1]
  local where = ""
  if best and best.goal then
    where = string.format(": your trainer is %s in %s", best.title, placeName(best.goal, best.zone))
    if best.route then where = where .. ", " .. ns.FormatDuration(best.route.seconds) .. " away" end
  end
  local spells = plural(s.nextCount, "new spell")
  return {
    kind = "abilities", urgency = 0.2, title = string.format("%s at level %d", capitalize(spells), s.nextLevel),
    text = string.format("%s at level %d%s.", capitalize(spells), s.nextLevel, where),
    highlights = { spells, string.format("level %d", s.nextLevel) },
    -- Nothing to learn there yet: the trainer and the spells on the Trainers
    -- page, not directions to someone who can't teach you today.
    page = "trainers", pageLabel = "Show trainer",
  }
end

-- Full (or nearly full) bags, and the nearest vendor to sell at.
local function bagsNeed()
  local free, total = bagSpace()
  if not free or free > BAGS_NEARLY_FULL then return nil end
  local best
  for _, r in ipairs(try(ns.Vendors.Results) or {}) do
    if r.goal and r.route and seconds(r.route) < seconds(best and best.route) then best = r end
  end
  local name = best and (best.goal.label or best.title)
  local state = free == 0 and "Bags full" or string.format("Bags nearly full (%d of %d slots free)", free, total)
  local text = state .. (best and string.format(": the nearest vendor is %s, %s away.", name,
    ns.FormatDuration(best.route.seconds)) or ".")
  return {
    kind = "bags", urgency = free == 0 and 0.85 or 0.45, title = state, text = text,
    highlights = { free == 0 and "full" or string.format("%d of %d", free, total) },
    goal = best and best.goal, route = best and best.route, zone = best and ns.MapName(best.goal.mapID),
    stop = best and { node = best.goal, text = "Sell at " .. name, phrase = "sell at " .. name } or nil,
  }
end

-- A vendor a couple of minutes away, when no other tile sends you to one.
local function vendorNearbyNeed()
  local best
  for _, r in ipairs(try(ns.Vendors.Results) or {}) do
    if r.goal and r.route and seconds(r.route) < seconds(best and best.route) then best = r end
  end
  if not (best and seconds(best.route) <= VENDOR_NEAR_SECONDS) then return nil end
  local name = best.goal.label or best.title
  return {
    kind = "vendor", urgency = 0.15, title = "Vendor nearby: " .. name,
    text = string.format("A vendor nearby: %s, %s away.", name, ns.FormatDuration(best.route.seconds)),
    highlights = { name },
    goal = best.goal, route = best.route, zone = ns.MapName(best.goal.mapID),
    stop = { node = best.goal, text = "Visit " .. name, phrase = "visit " .. name },
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
  for _, info in ns.QuestLog.Entries() do
    local id = not info.isHeader and not info.isHidden and info.questID
    if id then
      local row = ns.Quests.Quest(id)
      local complete = ns.QuestLog.IsComplete(id)
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

-- A quest that carries a chain on: it has a prerequisite (which you did,
-- since you can take it).
local function continuesChain(questID)
  local q = ns.Quests.Quest(questID)
  if not q then return false end
  return (type(q.preQuestSingle) == "table" and #q.preQuestSingle > 0)
    or (type(q.preQuestGroup) == "table" and #q.preQuestGroup > 0) or false
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
    local quests, stops, ids = {}, {}, {}
    for _, g in ipairs(hub.givers) do
      for _, e in ipairs(g.quests) do
        local q = logQuest(e)
        q.giver = g.name
        quests[#quests + 1] = q
        ids[#ids + 1] = e.id
        stops[#stops + 1] = { node = g.node, group = "turnin", action = { kind = "turnin", questID = e.id },
          npc = g.name, text = string.format("Hand in %s to %s", e.name or ("quest " .. e.id), g.name or "the quest giver") }
      end
    end
    local goal = hub.anchor.node
    local route = ns.Router.Plan(start, goal, net)
    if route then
      local where = hub.place and ("in " .. hub.place) or ("to " .. (hub.anchor.name or "the quest giver"))
      out[#out + 1] = {
        kind = "handin", place = hub.place, where = where,
        title = capitalize(string.format("hand in %s %s", plural(#quests, "quest"), where)),
        zone = zoneName(goal), goal = goal, route = route, trip = route.seconds,
        quests = quests, stops = stops, questIDs = ids,
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
      dungeonLevel = tonumber((r.title or ""):match("level (%d+)$")) or (entry and entry.level),
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
  local journey = plan(start, def, net, "dungeon")
  if not journey then return end
  option.journey = journey
  option.trip = journey.seconds
  score(option, ctx)
end

-- Hand-ins, unfinished log quests, and a hub with hand-ins: one journey over
-- their stops, scored again with its real trip time.
local function questJourney(option, ctx, start, net)
  local def = { title = option.title, stops = copyStops(option.stops),
    finish = option.finish and copyStop(option.finish) }
  local journey = plan(start, def, net, option.kind)
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
-- whole-quest journey: pick it up, do it (and what it needs first), hand it in.
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
  local journey = plan(start, { title = "Do " .. name, stops = stops }, net, "quest")
  if not journey then return nil end
  local option = {
    kind = "quest", title = "Do " .. name, zone = bestHub.zone, place = bestHub.place,
    goal = journey.stops[#journey.stops].node, trip = journey.seconds, journey = journey, stops = stops,
    quests = { { id = best.id, name = best.name, level = best.level, giver = best.giver } },
    chained = continuesChain(best.id), tag = (notableTag(best.id)),
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
    local journey = #stops > 0 and plan(start, { title = title, stops = stops }, net, "notable") or nil
    local travel = journey and firstLeg(journey)
    if travel and travel <= NOTABLE_SECONDS then
      local first = journey.stops[1].node
      local option = {
        kind = "notable", title = title, zone = zoneName(first), goal = journey.stops[#journey.stops].node,
        trip = journey.seconds, travel = travel, journey = journey, stops = stops, tag = c.tag, reasons = c.reasons,
        notableScore = c.score, chained = continuesChain(c.id),
        quests = { { id = c.id, name = c.name, level = c.level, inLog = c.inLog, handin = c.complete,
          seconds = c.complete and HANDIN_SECONDS or nil } },
      }
      score(option, ctx)
      return option
    end
  end
  return nil
end

-- Below HOME_LEVEL, the starting zone to stay in: the one you're in, else
-- your race's (from a capital, say).
local function homeZone(ctx, start)
  if ctx.level >= HOME_LEVEL then return nil end
  local here = ns.Geo.ZoneAt(start.instance, start.wx, start.wy)
  if here and STARTING_ZONES[here] then return here end
  local _, _, raceID = UnitRace("player")
  return RACE_HOME[raceID]
end

-- Where to quest at your level, anywhere: per zone (Quests.ZoneQuests), the
-- quests you can take now and those their chains unlock, worth their XP; the
-- hub to start at is the one with the most quests for you now, and the card's
-- journey picks up all of them there. Zones need ZONE_MIN_QUESTS quests you
-- can take now; the best MAX_ZONES by XP (quest count without XP data) get a
-- route to their first hub. Below HOME_LEVEL your starting zone comes first.
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
  local home = homeZone(ctx, start)
  table.sort(zones, function(a, b)
    if (a.mapID == home) ~= (b.mapID == home) then return a.mapID == home end
    if a.value ~= b.value then return a.value > b.value end
    return #a.now > #b.now
  end)
  -- While your starting zone has quests for you, not the other starting zones.
  if home and zones[1] and zones[1].mapID == home then
    local kept = { zones[1] }
    for i = 2, #zones do
      if not STARTING_ZONES[zones[i].mapID] then kept[#kept + 1] = zones[i] end
    end
    zones = kept
  end
  -- Below HOME_LEVEL, never another race's starting zone across the sea: a
  -- neighbour by road or tram (Elwynn from Dun Morogh) is a fine change of
  -- scenery, a boat to Teldrassil isn't.
  if home then
    local kept = {}
    for _, z in ipairs(zones) do
      local node = z.now[1] and z.now[1].node
      local far = STARTING_ZONES[z.mapID] and z.mapID ~= home and node and node.instance ~= start.instance
      if not far then kept[#kept + 1] = z end
    end
    zones = kept
  end

  local out = {}
  for _, z in ipairs(zones) do
    ns.WarmStep()
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
      -- The journey: pick up every quest you can take at the first hub.
      local title = "Quest in " .. ns.MapName(z.mapID)
      local stops = {}
      for _, g in ipairs(first.givers) do
        for _, q in ipairs(g.quests) do
          stops[#stops + 1] = { node = g.node, group = "pickup", giver = g.name, action = { kind = "pickup", questID = q.id },
            text = string.format("Pick up %s from %s", q.name or ("quest " .. q.id), g.name or "the quest giver") }
        end
      end
      local journey = #stops > 0 and plan(start, { title = title, stops = stops }, net, "zone") or nil
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

---------------------------------------------------------------- relevance

-- Each candidate gets five parts, 0..1 (docs/DESIGN.md "Relevance"), and
-- relevance = their weighted sum. The parts live on the row as
-- `relevance_parts`, for /ww debug cards and the `why` sentence.

-- How many levels under you a quest turns grey (the vanilla rule, roughly).
local function greyDelta(level)
  if level <= 5 then return 5 end
  if level <= 39 then return 5 + math.floor(level / 10) end
  return level - math.floor(level * 0.75)
end

-- 1.0 from level-2 to level+2, falling to 0 at grey and at too hard (5
-- levels up; 3 on Hardcore, where orange is already a risk).
local function levelFit(questLevel, level)
  local d = questLevel - level
  if d >= -2 and d <= 2 then return 1 end
  if d < 0 then
    local grey = greyDelta(level)
    if -d >= grey then return 0 end
    return clamp(1 - (-d - 2) / (grey - 2))
  end
  local hard = ns.IsHardcore() and 3 or 5
  if d >= hard then return 0 end
  return clamp(1 - (d - 2) / (hard - 2))
end
ForYou.LevelFit = levelFit

-- Travel time to the first stop: 1.0 within 2 minutes, 0.5 at about 8, 0
-- past 25. Transports count as time, not distance (the router's seconds).
local function proximity(travel)
  if not travel or travel == math.huge then return 0 end
  if travel <= NEAR_SECONDS then return 1 end
  if travel <= MID_SECONDS then return 1 - 0.5 * (travel - NEAR_SECONDS) / (MID_SECONDS - NEAR_SECONDS) end
  if travel >= FAR_SECONDS then return 0 end
  return 0.5 * (FAR_SECONDS - travel) / (FAR_SECONDS - MID_SECONDS)
end
ForYou.Proximity = proximity

-- Seconds to an option's first stop: the journey's first leg, else its route.
local function travelTo(option)
  if option.travel then return option.travel end
  if option.journey then return firstLeg(option.journey) end
  return option.route and option.route.seconds or option.trip
end

-- Dungeons and raids count less when you're on your own.
local function groupFit(option)
  if option.kind ~= "dungeon" then return 1 end
  local members = type(GetNumGroupMembers) == "function" and tonumber((GetNumGroupMembers())) or 0
  if option.raid then return members > 5 and 1 or 0.3 end
  return members > 1 and 1 or 0.6
end

-- 1 when a quest's reward is something your class would use (Notable.lua's
-- armour and weapon reasoning), 0.5 when nothing is known either way.
local function rewardFit(option)
  if option.reward then return option.reward end
  if not ns.Quests.Notable then return 0.5 end
  for _, q in ipairs(option.quests or option.now or {}) do
    for _, r in ipairs(try(ns.Quests.Notable, q.id) or {}) do
      if r.kind == "reward" then return 1 end
    end
  end
  return 0.5
end

-- Does it fit this character now: level fit (half of it), XP for the time
-- against the best on offer (a fifth), a reward you'd use, and group content
-- when you're solo.
local function suitability(option, ctx)
  local quests = option.quests or option.now or {}
  local fit, n = 0, 0
  for _, q in ipairs(quests) do
    fit, n = fit + levelFit(q.level or ctx.level, ctx.level), n + 1
  end
  if n > 0 then
    fit = fit / n
  elseif option.dungeonLevel then
    fit = levelFit(option.dungeonLevel, ctx.level)
  else
    fit = 1
  end
  local xp = 0
  if option.rate and ctx.bestRate and ctx.bestRate > 0 then xp = clamp(option.rate / ctx.bestRate) end
  option.levelFit, option.xpShare = fit, xp
  return clamp(0.5 * fit + 0.2 * xp + 0.15 * rewardFit(option) + 0.15 * groupFit(option))
end

-- Does it continue something under way: quests in the log, a chain's next
-- step, the zone you're questing in, a dungeon whose quests you hold, a
-- profession at its cap.
local function progression(option, ctx)
  local k = option.kind
  if k == "handin" then return 1 end
  if k == "finish" then return 0.95 end
  if k == "dungeon" then
    if #(option.inLog or {}) > 0 then return 0.8 end
    if #(option.quests or {}) > 0 then return 0.4 end
    return 0.2
  end
  if k == "notable" then
    local q = option.quests[1]
    if q.handin then return 1 end
    if q.inLog then return 0.9 end
    return option.chained and 0.6 or 0.3
  end
  if k == "quest" then return option.chained and 0.7 or 0.3 end
  if k == "zone" then
    if ctx.journeyMap and option.mapID == ctx.journeyMap then return 1 end
    if option.mapID == ctx.hereMap then return 0.7 end
    return #(option.later or {}) > 0 and 0.35 or 0.2
  end
  if k == "profession" then return option.capped and 1 or 0.6 end
  return 0.3
end

-- Whether the map at a node is explored (the client's map exploration), or
-- nil when the client can't say.
local function exploredAt(node)
  local lookup = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition
  local mapID, x, y = ns.Geo.ZonePoint(node)
  if not (lookup and mapID and CreateVector2D) then return nil end
  local ok, areaIDs = pcall(lookup, mapID, CreateVector2D(x, y))
  if not ok or type(areaIDs) ~= "table" then return nil end
  return areaIDs[1] ~= nil
end

local function visitedZone(mapID)
  local visited = ns.charDB and ns.charDB.visitedZones
  return visited ~= nil and mapID ~= nil and visited[mapID] == true
end

-- A dungeon you walked into before (Dungeons.lua records the entrance).
local function walkedIn(option)
  local all = ns.db and ns.db.dungeonEntrances
  if not (all and option.name) then return false end
  local wanted = option.name:lower()
  for _, record in pairs(all) do
    if type(record.name) == "string" and record.name:lower() == wanted then return true end
  end
  return false
end

-- Hook: a transport on the way you haven't used yet (not tracked yet; 0).
function ForYou.TransportNovelty(option)
  return 0
end

-- Is it new or remarkable: a zone or dungeon you haven't explored, a notable
-- quest, a transport you haven't used.
local function novelty(option, ctx)
  local k, n = option.kind, 0.2
  if k == "zone" then
    if option.mapID == ctx.hereMap then
      n = 0.15
    elseif visitedZone(option.mapID) then
      n = 0.4
    elseif exploredAt(option.goal) then
      n = 0.7
    else
      n = 1
    end
  elseif k == "dungeon" then
    n = walkedIn(option) and 0.4 or 0.9
  elseif k == "notable" then
    n = 1 -- tagged by Notable.lua: remarkable by definition
  elseif k == "quest" then
    n = option.tag and 0.8 or 0.3
  elseif k == "profession" then
    n = 0.5
  elseif k == "handin" or k == "finish" then
    n = 0.1
  end
  return clamp(n + ForYou.TransportNovelty(option))
end

-- Hook: an explicit preference for a kind of journey (no setting yet).
function ForYou.Preference()
  return ns.charDB and ns.charDB.preferKind or nil
end

-- The kinds of journey this character starts, learned (ns.charDB.startedKinds).
local function learnedKind(kind)
  local kinds = ns.charDB and ns.charDB.startedKinds
  if not kinds then return 0.5, 0 end
  local most = 0
  for _, n in pairs(kinds) do most = math.max(most, n) end
  if most == 0 then return 0.5, 0 end
  return (kinds[kind] or 0) / most, most
end

-- What the player has told us: the time budget, the kind of journey they
-- start most, the zone of the active journey, an explicit preference.
local function intent(option, ctx)
  local learned = learnedKind(option.kind)
  local budget = 0.5
  if ctx.budget then budget = (option.seconds or option.trip or 0) <= ctx.budget and 1 or 0 end
  local zone = 0.5
  if ctx.journeyMap then zone = option.mapID == ctx.journeyMap and 1 or 0.3 end
  option.intentWhy = (learned >= budget and learned >= zone and learned > 0.5) and "kind"
    or (zone >= budget and zone > 0.5) and "zone" or (budget > 0.5) and "budget" or nil
  local i = 0.4 * learned + 0.3 * budget + 0.3 * zone
  local preference = ForYou.Preference()
  if preference then
    i = 0.5 * (preference == option.kind and 1 or 0) + 0.5 * i
    if preference == option.kind then option.intentWhy = "preference" end
  end
  return clamp(i)
end

local function relevanceOf(parts)
  local total = 0
  for _, name in ipairs(PART_NAMES) do total = total + WEIGHTS[name] * (parts[name] or 0) end
  return total
end

-- Ties between parts go to the one that says more: what it continues, then
-- what's new about it, then its fit, then intent, then plain distance.
local PART_ORDER = { progression = 1, novelty = 2, suitability = 3, intent = 4, proximity = 5 }
local LEAD_ORDER = { "progression", "novelty", "suitability", "intent", "proximity" }

-- The part with the biggest value (LEAD_ORDER on a tie). Proximity never
-- leads: anything within two minutes scores full marks for it, and being
-- close is a reason to go, not what a suggestion is about (it still counts in
-- the relevance and can still be named in the why).
local function lead(parts)
  local best, bestValue = nil, -1
  for _, name in ipairs(LEAD_ORDER) do
    if name ~= "proximity" and (parts[name] or 0) > bestValue then best, bestValue = name, parts[name] or 0 end
  end
  return best
end

-- The phrase for one part of an option, in plain words.
local function phraseFor(name, option, parts, ctx)
  local k = option.kind
  if name == "proximity" then
    local travel = travelTo(option)
    if travel and travel <= NEAR_SECONDS then return "right nearby" end
    return ns.FormatDuration(travel) .. " away"
  end
  if name == "progression" then
    if k == "handin" then return "quests in your log are ready to hand in" end
    if k == "finish" then return "picks up where your log left off" end
    if k == "dungeon" then
      if #(option.inLog or {}) > 0 then return "continues quests in your log" end
      return "its quests are waiting at their givers"
    end
    if k == "notable" or k == "quest" then
      local q = option.quests[1]
      if q.handin then return "ready to hand in from your log" end
      if q.inLog then return "already in your log" end
      if option.chained then return "continues a chain you started" end
      return "a quest line to start"
    end
    if k == "zone" then
      if ctx.journeyMap and option.mapID == ctx.journeyMap then return "where your journey already is" end
      if option.mapID == ctx.hereMap then return "the zone you're in, with quests left" end
      if #(option.later or {}) > 0 then return "its chains lead on" end
      return "somewhere new to quest"
    end
    if k == "profession" then
      return option.capped and (option.profession .. " is at its cap") or ("the next rank of " .. option.profession)
    end
    return "something to carry on with"
  end
  if name == "novelty" then
    if k == "zone" then
      if parts.novelty >= 0.9 then return "a zone you haven't seen" end
      if parts.novelty >= 0.6 then return "a zone you've barely explored" end
      return "a zone you know"
    end
    if k == "dungeon" then return parts.novelty >= 0.8 and "a dungeon you haven't run" or "a dungeon you know" end
    if k == "notable" then
      local reason = option.reasons and option.reasons[1] and option.reasons[1].text
      if reason then return (reason:gsub("%.$", "")) end
      return "a quest that stands out"
    end
    if k == "quest" then return option.tag and ("a quest that stands out: " .. option.tag) or "a quest you haven't done" end
    if k == "profession" then return "a new rank to learn" end
    return "something familiar"
  end
  if name == "suitability" then
    local n = #(option.quests or option.now or {})
    if k == "zone" then return plural(n, "quest") .. " at your level" end
    if k == "handin" then return "full XP for " .. plural(n, "quest") end
    if k == "finish" then return plural(n, "quest") .. " at your level, part done" end
    if k == "dungeon" then return n > 0 and (plural(n, "quest") .. " at your level") or "fits your level" end
    if k == "profession" then return "something you can train right now" end
    local reward = rewardFit(option) >= 1 and " with a reward for you" or ""
    return "a quest at your level" .. reward
  end
  if name == "intent" then
    local w = option.intentWhy
    if w == "preference" then return "the kind you asked for" end
    if w == "kind" then return "the kind of journey you start most" end
    if w == "zone" then return "in your journey's zone" end
    if w == "budget" then return string.format("fits your %d min", ctx.budget / 60) end
    return "a change of pace"
  end
  return nil
end

-- One plain sentence naming the two strongest parts: "Picks up where your
-- log left off, 4 min away".
local function whyFor(option, parts, ctx)
  local names = {}
  for _, name in ipairs(PART_NAMES) do names[#names + 1] = { name = name, value = parts[name] or 0 } end
  table.sort(names, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return PART_ORDER[a.name] < PART_ORDER[b.name]
  end)
  local top = { names[1], names[2] }
  table.sort(top, function(a, b) return PART_ORDER[a.name] < PART_ORDER[b.name] end)
  local first = phraseFor(top[1].name, option, parts, ctx) or ""
  local second = phraseFor(top[2].name, option, parts, ctx)
  return capitalize(first) .. (second and (", " .. second) or "")
end

-- How many refreshes a card has been shown on (CheckNew keeps the count).
local function shownCount(row)
  local seen = ns.charDB and ns.charDB.seenCards
  local n = seen and seen[(row.id or "?") .. "|" .. (row.title or "")]
  if type(n) == "number" then return n end
  return n and 1 or 0
end

-- Scores an option and writes relevance, its parts and `why` onto its row;
-- the `why` goes first in the details (the tooltip's gold line).
local function scoreRow(row, option, ctx)
  option.mapID = option.mapID or zoneOf(option.journey and option.journey.stops[1] and option.journey.stops[1].node
    or option.goal)
  local parts = {
    suitability = suitability(option, ctx),
    proximity = proximity(travelTo(option)),
    progression = progression(option, ctx),
    novelty = novelty(option, ctx),
    intent = intent(option, ctx),
  }
  -- Shown on refresh after refresh and never started: a little less new each time.
  local shown = shownCount(row)
  if shown > 0 then parts.novelty = parts.novelty * math.max(SHOWN_FLOOR, 1 - SHOWN_DECAY * shown) end
  for _, name in ipairs(PART_NAMES) do parts[name] = math.floor(clamp(parts[name]) * 100 + 0.5) / 100 end
  row.relevance_parts = parts
  row.relevance = math.floor(relevanceOf(parts) * 1000 + 0.5) / 1000
  row.lead = lead(parts)
  row.why = whyFor(option, parts, ctx)
  row.zoneKey = option.mapID or firstPart(option.zone or row.zone or "")
  row.travel = travelTo(option)
  table.insert(row.details, 1, { text = row.why .. ".", color = GOLD })
  return row
end

---------------------------------------------------------------- rows

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

local CATEGORY = { hub = "Quest hub", handin = "Hand in", finish = "Finish", quest = "Best quest" }

local function optionRow(option, ctx)
  local count = #option.quests
  local fresh, logged, handins = questCounts(option)
  local amount = ctx.xpMode and (formatNumber(option.value) .. " XP") or plural(count, "quest")
  local details = { {
    text = string.format("~%s in %s (%s).", amount, ns.FormatDuration(option.seconds), timeText(option)),
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
    if not ctx.xpMode then stats[#stats + 1] = { "Level", tostring(q.level or "?") } end
  else
    stats[#stats + 1] = { "Quests", handins > 0 and string.format("%d + %d ready", fresh, handins) or tostring(fresh) }
  end
  if ctx.xpMode then stats[#stats + 1] = { "XP", "~" .. formatNumber(option.value) } end

  local row = {
    id = option.kind .. (option.name or option.title), kind = option.kind, raid = option.raid, title = option.title,
    category = CATEGORY[option.kind] or (option.raid and "Raid" or "Dungeon"),
    subtitle = string.format("%s  ·  %s  ·  %s", firstPart(option.zone),
      ns.FormatDuration(option.trip), table.concat(why, ", ")),
    place = place, stats = stats, zone = option.zone,
    goal = option.goal, route = option.route, details = details,
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
  return scoreRow(row, option, ctx)
end

-- Dungeons without quests for you (or without quest data): Dungeons' own ranking.
local function plainRow(option, ctx)
  local r = option.result
  local details = { { text = ns.Quests.Available() and "No quests for it: ranked by level fit and travel time."
    or "Ranked by level fit and travel time. Install " .. ns.Data.ADDON .. " for its quests and XP.", color = GREY } }
  for _, line in ipairs(r.details or {}) do details[#details + 1] = line end
  local stats = {}
  local level = option.title and option.title:match("level (%d+)$")
  if level then stats[1] = { "Level", level } end
  stats[#stats + 1] = { "Travel", ns.FormatDuration(option.trip) }
  local row = {
    id = "plain" .. (r.id or option.name), kind = "dungeon", raid = option.raid, title = option.title,
    category = option.raid and "Raid" or "Dungeon",
    subtitle = string.format("%s  ·  %s  ·  fits your level", firstPart(r.zone),
      ns.FormatDuration(option.trip)),
    place = string.format("%s  ·  %s  ·  fits your level", firstPart(r.zone), option.raid and "Raid" or "Group"),
    stats = stats, zone = r.zone,
    goal = r.goal, route = r.route, details = details,
  }
  return scoreRow(row, option, ctx)
end

-- "Don't miss": what makes the quest stand out, in plain words; its XP doesn't rank it.
-- `travel` is the first leg only (to the quest giver, or on with one in your log).
local function notableRow(option, ctx)
  local q = option.quests[1]
  local where = q.inLog and string.format("It's in your log, %s away", ns.FormatDuration(option.travel))
    or string.format("Its quest giver is %s away", ns.FormatDuration(option.travel))
  if option.trip > option.travel then where = where .. string.format(", the whole journey %s", ns.FormatDuration(option.trip)) end
  local details = { { text = string.format("Don't miss: %s %s.", option.reasons[1].text, where), color = NOTABLE } }
  for i = 2, #option.reasons do details[#details + 1] = { text = option.reasons[i].text, color = NOTABLE } end
  local line = string.format("[%d] %s%s", q.level or 0, q.name or ("Quest " .. q.id), q.inLog and "  (in your log)" or "")
  if ctx.xpMode then line = line .. string.format("  -  %s XP", formatNumber((questValue(q, ctx)))) end
  details[#details + 1] = { text = line, quest = true,
    color = GetQuestDifficultyColor and q.level and GetQuestDifficultyColor(q.level) }
  -- The reward that makes it stand out, shown beside the tooltip.
  local rewardItem
  for _, reason in ipairs(option.reasons) do
    if reason.itemID then rewardItem = reason.itemID break end
  end
  local stats = { { "Level", tostring(q.level or "?") }, { "Travel", ns.FormatDuration(option.travel) } }
  if option.trip > option.travel then stats[#stats + 1] = { "Journey", ns.FormatDuration(option.trip) } end
  local row = {
    id = "notable" .. q.id, kind = "notable", category = "Don't miss", title = option.title, item = rewardItem,
    subtitle = string.format("%s  ·  %s  ·  %s", option.zone, ns.FormatDuration(option.travel), option.tag),
    place = string.format("%s  ·  %s", option.tag, option.zone), stats = stats, zone = option.zone,
    goal = option.goal, journey = option.journey, details = details,
  }
  return scoreRow(row, option, ctx)
end

local function zoneRow(z, ctx)
  local levels = z.lowest == z.highest and ("Level " .. z.lowest) or string.format("Levels %d-%d", z.lowest, z.highest)
  local details = { {
    text = string.format("Questing zone: %s you can take now%s%s.", plural(#z.now, "quest"),
      #z.later > 0 and string.format(", %d more as their chains unlock", #z.later) or "",
      ctx.xpMode and string.format(", ~%s XP in all", formatNumber(z.value)) or ""),
  } }
  details[#details + 1] = { text = string.format("Start at %s: the journey picks up its %s.", z.first.place,
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
  local row = {
    id = "zone" .. z.mapID, kind = "zone", category = "Questing zone", title = z.title, mapID = z.mapID,
    subtitle = string.format("%s  ·  %s  ·  %s  ·  start at %s", z.zone, levels, ns.FormatDuration(z.trip), z.first.place),
    place = string.format("%s  ·  start at %s", levels, z.first.place), zone = z.zone,
    stats = { { "Quests", quests }, ctx.xpMode and { "XP", "~" .. formatNumber(z.value) } or { "Hubs", tostring(#z.hubs) },
      { z.journey and "Journey" or "Travel", ns.FormatDuration(z.trip) } },
    goal = z.goal, route = z.route, journey = z.journey, details = details,
  }
  return scoreRow(row, z, ctx)
end

-- A profession's next rank, as a card (its journey ends with buying the rank).
local function professionRow(need, ctx)
  local details = {}
  for _, line in ipairs(need.details or {}) do details[#details + 1] = line end
  local row = {
    id = "profession" .. need.profession, kind = "profession", professionIcon = need.icon,
    category = "Profession", title = need.title,
    subtitle = string.format("%s  ·  %s  ·  %s", need.zone, ns.FormatDuration(need.route.seconds), need.why),
    place = capitalize(need.why), stats = need.stats, zone = need.zone,
    goal = need.goal, route = need.route, journey = need.journey, details = details,
  }
  need.reward = 1
  return scoreRow(row, need, ctx)
end

---------------------------------------------------------------- observations

local OBSERVATION_ICONS = {
  train = "Interface\\Icons\\INV_Misc_Book_09", repair = "Interface\\Icons\\Trade_BlackSmithing",
  food = "Interface\\Icons\\INV_Misc_Food_15", ammo = "Interface\\Icons\\INV_Ammo_Arrow_01",
  flight = "Interface\\Icons\\Ability_Hunter_EagleEye", profession = "Interface\\Icons\\INV_Misc_Note_01",
  handin = "Interface\\Icons\\INV_Letter_15", abilities = "Interface\\Icons\\INV_Misc_Book_09",
  bags = "Interface\\Icons\\INV_Misc_Bag_08", vendor = "Interface\\Icons\\INV_Misc_Coin_01",
}

-- A need as an observation: { id, kind, icon, text, highlights, urgency,
-- action = { label, kind = "detour" | "show" | "go", stop, page, goal, route } }.
local function observationFor(need)
  local o = {
    id = need.id or ("obs:" .. need.kind .. (need.profession or "")), kind = need.kind,
    icon = need.icon or OBSERVATION_ICONS[need.kind] or "Interface\\Icons\\INV_Misc_Map_01",
    text = need.text or need.title, highlights = need.highlights or {}, urgency = clamp(need.urgency or 0.5),
    details = need.details, spells = need.spells,
  }
  if need.kind == "train" and not need.icon then
    local _, class = UnitClass("player")
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then o.icon, o.iconCoords = "Interface\\TargetingFrame\\UI-Classes-Circles", coords end
  end
  if need.stop then
    o.action = { label = "Add detour", kind = "detour", stop = need.stop, stops = need.stops, goal = need.goal,
      route = need.route, title = need.title }
  elseif need.page then
    o.action = { label = need.pageLabel or "Show", kind = "show", page = need.page }
  elseif need.goal and need.route then
    o.action = { label = "Go", kind = "go", goal = need.goal, route = need.route, title = need.title }
  end
  return o
end

-- Completed quests ready to hand in: one observation per place, nearest
-- first, with the hand-in stops (Journey.QuestStops) as a detour.
local function handinObservations(handins, start)
  local sorted = {}
  for _, h in ipairs(handins) do sorted[#sorted + 1] = h end
  table.sort(sorted, function(a, b) return a.trip < b.trip end)
  local out = {}
  for i = 1, math.min(#sorted, HANDIN_OBSERVATIONS) do
    local h = sorted[i]
    local stops = {}
    for _, id in ipairs(h.questIDs or {}) do
      for _, s in ipairs(ns.Journey.QuestStops(id, start)) do stops[#stops + 1] = s end
    end
    if #stops > 0 then
      local n = #h.quests
      out[#out + 1] = observationFor({
        id = "obs:handin" .. i, kind = "handin", urgency = math.min(0.75, 0.5 + 0.05 * n),
        title = h.title,
        text = string.format("%s ready to hand in %s, %s away.", plural(n, "quest"), h.where, ns.FormatDuration(h.trip)),
        highlights = { plural(n, "quest"), ns.FormatDuration(h.trip) },
        goal = h.goal, route = h.route, stop = stops[1], stops = stops,
      })
    end
  end
  return out
end

---------------------------------------------------------------- page

local function summaryFor(ctx, observations)
  local level = UnitLevel("player")
  local parts = { string.format("Level %d: a few good options from where you are.", level) }
  if ctx.budget then
    local minutes = ctx.budget / 60
    if ctx.nothingFits then
      parts[1] = string.format("Nothing to quest fits in %d min: the quickest option, a bit over.", minutes)
    else
      parts[1] = string.format("Fits in %d min: a few good options from where you are.", minutes)
    end
  end
  if #observations > 0 then
    parts[#parts + 1] = string.format("|cff7fd1ae%s|r good to know.", plural(#observations, "thing"))
  end
  if not ctx.quests then
    parts[#parts + 1] = "Install " .. ns.Data.ADDON .. " for quest hubs and XP; dungeons are ranked by level fit and travel time."
  elseif level >= MAX_LEVEL then
    parts[#parts + 1] = "At the level cap quests give no XP, so they count by level fit."
  elseif not ctx.db then
    parts[#parts + 1] = "No quest XP in the data: quests count by level fit."
  end
  local ready, unfinished = 0, 0
  for _, e in ipairs(ctx.log) do
    if e.complete then ready = ready + 1 else unfinished = unfinished + 1 end
  end
  if ready + unfinished > 0 then
    local counted = {}
    if ready > 0 then counted[#counted + 1] = string.format("%d ready to hand in", ready) end
    if unfinished > 0 then counted[#counted + 1] = string.format("%d to finish (timed by objectives left)", unfinished) end
    parts[#parts + 1] = string.format("Quest log: %s.", table.concat(counted, ", "))
    if ctx.unplaced > 0 then
      parts[#parts + 1] = string.format("%s in your log can't be placed on the map%s.", plural(ctx.unplaced, "quest"),
        ctx.quests and "" or " without quest data")
    end
  end
  for _, note in ipairs(ctx.notes) do parts[#parts + 1] = note end
  return table.concat(parts, " ")
end

-- How long each part of the last refresh took, for /ww debug.
local parts
local function timed(name, fn, ...)
  ns.WarmStep()
  local started = debugprofilestop and debugprofilestop()
  local a, b, c = try(fn, ...)
  if started then parts[#parts + 1] = string.format("%s %.0f", name, debugprofilestop() - started) end
  return a, b, c
end

local builtObservations -- the observations of the build under way (read by finished)

local function build()
  parts = {}
  builtObservations = {}
  local start = ns.Geo.PlayerNode()
  if not start then
    summary = nil
    return {}, "Can't read your position here."
  end
  local net = ns.Network.Build()
  local level = UnitLevel("player")
  local db = xpTable()
  perQuest = ns.QuestTimes.Seconds() or SECONDS_PER_QUEST
  local active = ns.Nav and ns.Nav.active
  local ctx = { level = level, db = db, xpMode = db ~= nil and level < MAX_LEVEL,
    quests = ns.Quests.Available() and true or false, notes = {}, unplaced = 0, overZones = {},
    hereMap = ns.Geo.ZoneAt(start.instance, start.wx, start.wy),
    journeyMap = active and active.goal and zoneOf(active.goal) or nil }
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

  -- The needs: observations, not cards (professions are cards too, below).
  local needs = {}
  local function addNeed(n) if n then needs[#needs + 1] = n end end
  addNeed(timed("training", trainingNeed, ctx))
  for _, n in ipairs(timed("vendors", vendorNeeds, ctx) or {}) do addNeed(n) end
  addNeed(timed("flight", flightNeed, ctx, start, net))
  addNeed(timed("repair", repairSoonNeed))
  local professions = timed("professions", professionNeeds, start, net) or {}
  for _, n in ipairs(professions) do
    if n.capped then addNeed(n) end
  end
  addNeed(timed("abilities", abilitiesNeed, ctx))
  addNeed(timed("bags", bagsNeed))
  local toVendor = false
  for _, n in ipairs(needs) do
    if n.kind == "repair" or n.kind == "ammo" or n.kind == "food" or n.kind == "bags" then toVendor = true end
  end
  if not toVendor then addNeed(timed("vendor nearby", vendorNearbyNeed)) end

  -- Every option; journeys are planned only for the best of each kind, and
  -- scored again with their real trip time.
  local hubs = timed("hubs", hubOptions) or {}
  local handins = timed("handins", handinOptions, ctx, start, net) or {}
  local finishes = timed("finish", finishOptions, ctx, start, net) or {}
  local dungeons, plain, held = timed("dungeons", dungeonOptions, ctx)
  dungeons, plain, held = dungeons or {}, plain or {}, held or {}
  -- With quest data, a dungeon without quests for you isn't worth the run in
  -- Forever (its mobs give little XP); without it there's nothing better to go on.
  -- Classic Era's dungeon mobs give their full XP, so there they stay.
  if ctx.quests and ns.IsForever() then plain = {} end
  for _, list in ipairs({ hubs, handins, finishes, dungeons }) do
    for _, option in ipairs(list) do score(option, ctx) end
  end
  -- With a budget, what doesn't fit is kept aside: the quickest of it is
  -- offered when nothing fits. Dungeons need BUDGET_DUNGEON minutes.
  local over = {}
  local questHubs = hubs -- the best quest can come from a hub too big for the budget
  local allHandins = handins -- observations aren't filtered by the budget
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
  end
  -- The best XP for the time on offer: suitability's XP share is against it.
  local bestRate = 0
  for _, list in ipairs({ hubs, handins, finishes, dungeons }) do
    for _, option in ipairs(list) do bestRate = math.max(bestRate, option.rate or 0) end
  end
  ctx.bestRate = bestRate

  -- The best of a kind, by relevance from its route (before the journey is planned).
  local function preScore(option)
    option.mapID = option.mapID or zoneOf(option.goal)
    return relevanceOf({ suitability = suitability(option, ctx), proximity = proximity(travelTo(option)),
      progression = progression(option, ctx), novelty = novelty(option, ctx), intent = intent(option, ctx) })
  end
  local function best(list)
    local top, topScore
    for _, option in ipairs(list) do
      local s = preScore(option)
      if not topScore or s > topScore or (s == topScore and option.seconds < top.seconds) then top, topScore = option, s end
    end
    return top
  end
  local picks = {}
  local function pick(option) if option then picks[#picks + 1] = option end end
  local function journeyFor(option)
    if #option.stops > 0 then timed("journeys", questJourney, option, ctx, start, net) end
  end
  -- With a budget: the least travel first, the first whose planned journey still fits.
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
  if quest and not fits(quest.seconds) then
    over[#over + 1] = quest
    quest = nil
  end
  pick(quest)
  local notable = timed("don't miss", notableOption, hubs, ctx, start, net,
    quest and { [quest.quests[1].id] = true } or {})

  -- The other dungeons for your level, named on the dungeon card; and the
  -- ones held back until more of their quests open.
  local others = {}
  for _, list in ipairs({ dungeons, plain }) do
    for _, option in ipairs(list) do
      if option ~= dungeon and option ~= (not dungeon and plain[1] or nil) then
        local name, lvl = (option.title or ""):match("^Run (.-)%s+·%s+level (%d+)$")
        others[#others + 1] = name and string.format("%s (%s)", name, lvl) or option.name
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

  -- Every card is kept, scored: the page shows MAX_RESULTS of those not on
  -- your journey, picked by role (visible, below).
  local results = {}
  -- With a budget each card shows its time (`badge`, UI/Cards.lua).
  local function add(row, seconds)
    if not row then return end
    if ctx.budget and seconds then row.badge = ns.FormatDuration(seconds) end
    results[#results + 1] = row
  end
  if notable and (not ctx.budget or fits(notable.seconds or notable.trip)) then
    add(notableRow(notable, ctx), notable.seconds or notable.trip)
  end
  for _, need in ipairs(professions) do
    if fits(need.trip) then add(professionRow(need, ctx), need.trip) end
  end
  local zones = timed("zones", zoneOptions, ctx, start, net) or {}
  for _, zone in ipairs(zones) do add(zoneRow(zone, ctx), zone.seconds) end
  local dungeonRow, dungeonSeconds
  if dungeon then
    timed("dungeon journey", dungeonJourney, dungeon, ctx, start, net)
    if fits(dungeon.seconds) then
      dungeonRow, dungeonSeconds = optionRow(dungeon, ctx), dungeon.seconds
    else
      over[#over + 1] = dungeon
    end
  elseif plain[1] then
    -- Without quest data: the best one by level fit and travel time.
    dungeonRow, dungeonSeconds = plainRow(plain[1], ctx), plain[1].trip
  end
  if dungeonRow and #others > 0 then
    table.insert(dungeonRow.details, 3, { text = "Also for your level: " .. table.concat(others, ", ", 1, math.min(#others, 4)) .. "." })
  end
  if #soon > 0 then
    local line = "Dungeons later, once you can take most of their quests: " .. table.concat(soon, ", ") .. "."
    if dungeonRow then
      -- In the dungeon card's tooltip, not on the card.
      table.insert(dungeonRow.details, 3, { text = line, more = true })
    else
      ctx.notes[#ctx.notes + 1] = line
    end
  end
  add(dungeonRow, dungeonSeconds)
  for _, option in ipairs(picks) do add(optionRow(option, ctx), option.seconds) end

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
        row = optionRow(nearest, ctx)
      end
      row.category = (row.category or "") .. "  ·  a bit over"
      row.details[1].text = string.format("Nothing fits in %d min; this is the quickest. ", budget) .. row.details[1].text
      row.over = true
      ctx.nothingFits = true
      add(row, nearest.seconds)
    end
  end
  -- Most relevant first; the roles are picked from this order (visible).
  table.sort(results, function(a, b)
    if (a.relevance or 0) ~= (b.relevance or 0) then return (a.relevance or 0) > (b.relevance or 0) end
    return (a.title or "") < (b.title or "")
  end)

  -- The observations, most urgent first (the order they were found breaks ties).
  local observations = {}
  for _, need in ipairs(needs) do observations[#observations + 1] = observationFor(need) end
  for _, o in ipairs(handinObservations(allHandins, start)) do observations[#observations + 1] = o end
  for i, o in ipairs(observations) do o.order = i end
  table.sort(observations, function(a, b)
    if a.urgency ~= b.urgency then return a.urgency > b.urgency end
    return a.order < b.order
  end)
  builtObservations = observations

  summary = summaryFor(ctx, observations)
  return results, nil, net
end

function ForYou.SummaryText()
  return summary or "What to do next, for this character, from where you stand."
end

function ForYou.EmptyText()
  return "Nothing to suggest from here yet. Visit a trainer for your class, open a flight map, or install "
    .. "" .. ns.Data.ADDON .. " for quest hubs and XP estimates."
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

-- What the journey on now still has stops for: the quests ({ [questID] = true })
-- and the places (the route's goal, or the journey's open stops and finish).
local function tripStops()
  local a = ns.Nav and ns.Nav.active
  local root = a and a.journey and (a.journey.root or a.journey.def)
  local ids, nodes = {}, {}
  for _, stop in ipairs(root and root.stops or {}) do
    if not stop.done and not stop.skipped then
      if stop.action and stop.action.questID then ids[stop.action.questID] = true end
      nodes[#nodes + 1] = stop.node
    end
  end
  local finish = root and root.finish
  if finish and not finish.done and not finish.skipped then nodes[#nodes + 1] = finish.node end
  if a and not root then nodes[#nodes + 1] = a.goal end
  return ids, nodes
end

-- A dungeon's entrance this close to a place the journey still goes is that place.
local SAME_PLACE = 5

-- Roles for each page of three: `continue` is the most relevant card whose
-- strongest part is progression; `explore` the most relevant whose strongest
-- part is novelty and that is in another zone or of another kind; `alternative`
-- the most relevant of yet another kind. Later pages repeat that over what is
-- left. The list comes in most-relevant-first.
local function assignRoles(rows)
  local left = {}
  for _, r in ipairs(rows) do left[#left + 1] = r end
  local function take(test)
    for i, r in ipairs(left) do
      if test(r) then
        table.remove(left, i)
        return r
      end
    end
  end
  local function any() return true end
  local function differs(a, b) return a.zoneKey ~= b.zoneKey or a.kind ~= b.kind end
  -- A card's tag says what it is, whichever slot it filled: a card about a new
  -- zone is never tagged as carrying on, however few cards there are.
  local function roleOf(r)
    if r.lead == "progression" then return "continue" end
    if r.lead == "novelty" then return "explore" end
    return "alternative"
  end
  local out = {}
  while #left > 0 do
    local cont = take(function(r) return r.lead == "progression" end) or take(any)
    out[#out + 1] = cont
    local explore = take(function(r) return r.lead == "novelty" and differs(r, cont) end)
      or take(function(r) return differs(r, cont) end) or take(any)
    if explore then out[#out + 1] = explore end
    local alternative = take(function(r) return r.kind ~= cont.kind and (not explore or r.kind ~= explore.kind) end)
      or take(any)
    if alternative then out[#out + 1] = alternative end
  end
  for _, r in ipairs(out) do r.role = roleOf(r) end
  return out
end
ForYou.AssignRoles = assignRoles

-- The cards shown: at most MAX_RESULTS, none with a quest your journey already
-- has, no dungeon your journey already goes to (a run with its pickups done
-- still has the entrance), in role order. Checked on every look, so the
-- cards follow the journey without a rebuild.
local function visible(results)
  local trip, places = tripStops()
  -- A journey you set aside isn't suggested again piece by piece: the Good to
  -- know tile offers to resume it instead.
  local setAside = ns.Nav.SetAsideQuests and ns.Nav.SetAsideQuests() or {}
  local out = {}
  for _, r in ipairs(results or {}) do
    if #out >= MAX_RESULTS then break end
    local overlap = false
    for _, stop in ipairs(r.journey and r.journey.stops or {}) do
      local id = stop.action and stop.action.questID
      if id and (trip[id] or setAside[id]) then
        overlap = true
        break
      end
    end
    if r.kind == "dungeon" and r.goal and not overlap then
      for _, node in ipairs(places) do
        if ns.Geo.Distance(r.goal, node) <= SAME_PLACE then
          overlap = true
          break
        end
      end
    end
    if not overlap then out[#out + 1] = r end
  end
  return assignRoles(out)
end

-- Which quests and places are on the journey, to refresh the cards when that changes.
local function tripKey()
  local trip, places = tripStops()
  local ids = {}
  for id in pairs(trip) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, node in ipairs(places) do ids[#ids + 1] = string.format("%s:%.4f:%.4f", node.mapID, node.x, node.y) end
  return table.concat(ids, ",")
end

-- For you is built as a background job (ns.Warm): on Classic Era a build
-- after a login can run past the client's limit in one go. Meanwhile the page
-- shows the last cards (WORKING before the first) and is refreshed when the
-- job is done; ForYou.WhenReady hands the fresh results to code that waits
-- for them. A quick build (or one without a clock, in tests) is done at once.
local job      -- the build under way: { tries, started, stale (invalidated meanwhile) }
local last     -- the last results built: { results, err, net, observations }
local dirty = true -- nothing built since the last invalidation (or ever)
local waiters = {}
local asking = false -- inside ForYou.Results: the caller takes the results itself
local startJob

local function finished(ok, results, err, net)
  local j = job
  job = nil
  dirty = false
  if not ok then results, err = {}, "Couldn't work this out (the error has the details)." end
  for _, r in ipairs(results or {}) do r.icon, r.iconCoords = iconFor(r) end
  ForYou.runs = ForYou.runs + 1
  if j.started then
    ns.debugTimings = ns.debugTimings or {}
    ns.debugTimings.forYou = debugprofilestop() - j.started
    ForYou.lastParts = parts and table.concat(parts, ", ") or nil
  end
  local observations = ok and builtObservations or {}
  last = { results = results, err = err, net = net, observations = observations }
  -- Invalidated while it was built: once more (not forever).
  if j.stale and j.tries < 2 then return startJob(j.tries + 1) end
  local now = GetTime and GetTime()
  cache = now and { at = now, results = results, err = err, net = net, observations = observations } or nil
  local shown = visible(results)
  pcall(ForYou.CheckNew, shown)
  local list = waiters
  waiters = {}
  for _, fn in ipairs(list) do
    local fine, problem = pcall(fn, shown, err, net)
    if not fine then geterrorhandler()(problem) end
  end
  if not asking and ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
end

function startJob(tries)
  job = { tries = tries or 1, started = debugprofilestop and debugprofilestop() }
  ns.Warm(build, finished)
end

function ForYou.Results()
  local now = GetTime and GetTime()
  if cache and now and now - cache.at < CACHE_SECONDS then return visible(cache.results), cache.err, cache.net end
  -- Quest data still being indexed: wait (DATA_CHANGED when it's ready).
  if ns.Quests.Warm() then
    summary = WAITING
    return {}, WAITING
  end
  if not job then
    asking = true
    local ok, err = pcall(startJob)
    asking = false
    if not ok then geterrorhandler()(err) end
  end
  if last then return visible(last.results), last.err, last.net end
  summary = WORKING
  return {}, WORKING
end

-- The observations ("Good to know"), most urgent first: built with the cards
-- and cached and invalidated with them. Empty until the first build is done.
-- The newest journey set aside, as a tile that resumes it.
local function setAsideObservation()
  local entry = ns.charDB.journeys and ns.charDB.journeys[1]
  if not entry or (entry.stops or 0) == 0 then return nil end
  local left = plural(entry.stops, "stop")
  return {
    id = "obs:setaside", kind = "setaside", icon = entry.icon or "Interface\\Icons\\INV_Misc_Map_01",
    text = string.format("You set aside %s, %s left.", entry.title or "a journey", left),
    highlights = { left }, urgency = 0.6,
    action = { label = "Resume", kind = "resume", index = 1 },
  }
end

-- What the tiles show: nothing the journey on now already does (a hand-in
-- that is one of its stops, a repairer it already visits), and the newest
-- set-aside journey first among the rest of its urgency.
local function shownObservations(list)
  local out = {}
  local resume = setAsideObservation()
  for _, o in ipairs(list or {}) do
    local a = o.action
    local stops = a and a.kind == "detour" and (a.stops or { a.stop })
    if not (stops and ns.Nav.JourneyHas and ns.Nav.JourneyHas(stops)) then out[#out + 1] = o end
  end
  if resume then
    local at = #out + 1
    for i, o in ipairs(out) do
      if (o.urgency or 0) < resume.urgency then at = i break end
    end
    table.insert(out, at, resume)
  end
  return out
end

function ForYou.Observations()
  local now = GetTime and GetTime()
  if cache and now and now - cache.at < CACHE_SECONDS then return shownObservations(cache.observations) end
  -- The panel asks for the cards first, which starts the build; only when
  -- nothing was ever built (and no build is under way) is one started here,
  -- so a refresh never builds twice.
  if dirty and not job then ForYou.Results() end
  if cache and now and now - cache.at < CACHE_SECONDS then return shownObservations(cache.observations) end
  return shownObservations(last and last.observations)
end

-- fn(results, err, net) once For you's results are fresh: now, or when the
-- build under way is done.
function ForYou.WhenReady(fn)
  local now = GetTime and GetTime()
  if cache and now and now - cache.at < CACHE_SECONDS then return fn(visible(cache.results), cache.err, cache.net) end
  waiters[#waiters + 1] = fn
  ForYou.Results()
end

function ForYou.Invalidate()
  cache = nil
  dirty = true
  if job then job.stale = true end
end

-- Vendors you need to visit now (repairs, ammo, food, a repairer close by):
-- { {title, goal, why}, ... }, for suggestions along a journey (OnTheWay.lua).
function ForYou.ShoppingNeeds()
  local ctx = { level = UnitLevel("player"), notes = {} }
  local out = {}
  for _, n in ipairs(try(vendorNeeds, ctx) or {}) do out[#out + 1] = n end
  local soon = try(repairSoonNeed)
  if soon then out[#out + 1] = soon end
  return out
end

---------------------------------------------------------------- /ww debug cards

-- Each card's role, relevance and parts, and each observation.
function ForYou.Diagnose()
  local lines = {}
  local rows = last and visible(last.results) or {}
  if #rows == 0 then lines[1] = "For you: no cards built yet" end
  for i, r in ipairs(rows) do
    local p = r.relevance_parts or {}
    lines[#lines + 1] = string.format("card %d [%s] %s: relevance %.2f (suitability %.2f, proximity %.2f, progression %.2f, novelty %.2f, intent %.2f); why: %s",
      i, r.role or "-", r.title or "?", r.relevance or 0, p.suitability or 0, p.proximity or 0, p.progression or 0,
      p.novelty or 0, p.intent or 0, r.why or "-")
  end
  local observations = last and last.observations or {}
  if #observations == 0 then lines[#lines + 1] = "observations: none" end
  for i, o in ipairs(observations) do
    lines[#lines + 1] = string.format("observation %d [%s] urgency %.2f: %s%s", i, o.kind, o.urgency or 0, o.text or "?",
      o.action and string.format("  (%s: %s)", o.action.kind, o.action.label) or "")
  end
  return lines
end


---------------------------------------------------------------- learned intent

-- The kinds of journey this character starts most, a small weight per kind
-- (ns.charDB.startedKinds[kind]), for the intent part of relevance.
local function noteKind(kind)
  if not (ns.charDB and kind) then return end
  ns.charDB.startedKinds = ns.charDB.startedKinds or {}
  ns.charDB.startedKinds[kind] = (ns.charDB.startedKinds[kind] or 0) + 1
end

local notedJourney -- the journey NoteStarted just counted, so JOURNEY_STARTED doesn't count it again

-- A card's journey (or directions) was started from the card: learn its kind,
-- and the card is new again next time it is suggested.
function ForYou.NoteStarted(row)
  if not row then return end
  noteKind(row.kind)
  notedJourney = row.journey
  local seen = ns.charDB and ns.charDB.seenCards
  if seen then seen[(row.id or "?") .. "|" .. (row.title or "")] = 1 end
end

ns.Listen("JOURNEY_STARTED", function()
  local a = ns.Nav and ns.Nav.active
  local journey = a and a.journey
  if not journey then return end
  if journey == notedJourney then
    notedJourney = nil
    return
  end
  local def = journey.def or {}
  noteKind(def.kind or (def.root and def.root.kind))
end)

-- Zones you've been in (for novelty): recorded as you move about.
local function noteZone()
  if not ns.charDB then return end
  local start = ns.Geo.PlayerNode()
  local mapID = start and ns.Geo.ZoneAt(start.instance, start.wx, start.wy)
  if not mapID then return end
  ns.charDB.visitedZones = ns.charDB.visitedZones or {}
  ns.charDB.visitedZones[mapID] = true
end

ns.On("ZONE_CHANGED_NEW_AREA", noteZone)
ns.On("PLAYER_ENTERING_WORLD", noteZone)

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

ns.RegisterCommand("time", "/ww time <minutes> | off - For you suggests only what fits in that time", function(rest)
  local arg = (rest or ""):lower()
  local minutes = tonumber(arg:match("^(%d+)"))
  if arg == "off" or arg == "none" or arg == "any" then
    ForYou.SetBudget(nil)
    ns.print("time budget off: For you suggests anything")
  elseif minutes and minutes > 0 then
    ForYou.SetBudget(minutes)
    ns.print(string.format("For you suggests what fits in %d min (/ww time off to stop)", minutes))
  elseif arg == "" then
    local current = ForYou.Budget()
    ns.print(current and string.format("time budget: %d min (/ww time off to stop)", current)
      or "no time budget (/ww time 20: only what fits in 20 minutes)")
  else
    ns.print("/ww time <minutes> | off")
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

-- Counts a look at a card (ns.charDB.seenCards[key]: how many refreshes it
-- was shown on; older saved variables hold `true`). True when it's the first.
local function noteShown(seen, key)
  local n = seen[key]
  if type(n) ~= "number" then n = n and 1 or 0 end
  seen[key] = n + 1
  return n == 0
end

-- A card is new when its title is. A trainer card's title changes with the
-- number of spells and the nearest trainer's town, so it's new only for a
-- spell no card has shown yet (or, without a spell list, at a new level).
local function isNew(r, seen)
  if r.kind ~= "train" then
    return noteShown(seen, (r.id or "?") .. "|" .. (r.title or ""))
  end
  if not (r.spells and #r.spells > 0) then
    return noteShown(seen, (r.id or "?") .. "|level " .. tostring(UnitLevel("player")))
  end
  local new = false
  for _, name in ipairs(r.spells) do
    if noteShown(seen, "spell|" .. name) then new = true end
  end
  return new
end

function ForYou.CheckNew(results)
  local first = ns.charDB.seenCards == nil
  ns.charDB.seenCards = ns.charDB.seenCards or {}
  local seen = ns.charDB.seenCards
  for _, r in ipairs(results or {}) do
    if isNew(r, seen) and major(r) and not first and ns.Fanfare then ns.Fanfare.NewJourney(r) end
  end
end

-- After a journey (Navigator.lua): For you's top card that is a journey, not
-- the one just done, as "Up next". Nothing when you've set off on something
-- else already, are fighting or flying, or For you has nothing to go to.
function ForYou.SuggestNext(doneTitle)
  if ns.Nav.active or ns.OnTaxi() or (InCombatLockdown and InCombatLockdown()) then return nil end
  if not ns.Fanfare then return nil end
  ForYou.Invalidate()
  local suggested
  ForYou.WhenReady(function(results)
    -- Built in the background: you may have set off meanwhile.
    if suggested or ns.Nav.active or ns.OnTaxi() then return end
    for _, r in ipairs(results or {}) do
      if (r.journey or r.route) and r.title ~= doneTitle then
        ns.Fanfare.UpNext(r)
        suggested = r
        return
      end
    end
  end)
  return suggested
end

-- Looked at in the background when things change: a level, a quest handed
-- in, a new zone (not in combat: it plans many routes; not on a flight: the
-- zones passed over aren't where you'll be, so it waits for the landing).
local CHECK_DELAY = 4
local checking, deferred = false, false
local soon

local function check()
  checking = false
  if InCombatLockdown and InCombatLockdown() then
    deferred = true
    return
  end
  if ns.OnTaxi() then return ns.AfterFlight(soon) end
  -- A fresh build looks for new cards itself (CheckNew).
  ForYou.Invalidate()
  ForYou.WhenReady(function() end)
end

function soon()
  if checking then return end
  checking = true
  ns.After(CHECK_DELAY, check)
end

ns.On("PLAYER_LEVEL_UP", soon)
ns.On("QUEST_TURNED_IN", soon)
ns.On("ZONE_CHANGED_NEW_AREA", soon)
ns.On("PLAYER_REGEN_ENABLED", function()
  if deferred then
    deferred = false
    soon()
  end
end)

-- An abandoned quest leaves the cards (and journeys built on it) straight away.
ns.Listen("QUEST_ABANDONED", function()
  ForYou.Invalidate()
  if ns.Panel and ns.Panel.RefreshSoon then ns.Panel.RefreshSoon() end
end)

-- Registered before the panel's own listeners, so its refresh sees fresh data.
ns.Listen("DATA_CHANGED", function()
  ForYou.Invalidate()
  -- Someone waits for results that waited for the quest data: build them.
  if #waiters > 0 then ForYou.Results() end
end)
ns.Listen("FLIGHTS_CHANGED", ForYou.Invalidate)

-- A journey started, grown, done or ended: the cards it hid (or now doesn't) change.
local shownTrip = ""
ns.Listen("NAV_CHANGED", function()
  local key = tripKey()
  if key == shownTrip then return end
  shownTrip = key
  if ns.Panel and ns.Panel.RefreshSoon then ns.Panel.RefreshSoon() end
end)
ns.On("ZONE_CHANGED_NEW_AREA", ForYou.Invalidate)

ns.RegisterPage(ForYou)

ns.RegisterCommand("next", "/ww next - what to do next (opens the For you page)", function()
  ForYou.Invalidate()
  ns.Panel.Search(ForYou.id)
end)
