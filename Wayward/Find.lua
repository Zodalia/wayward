local _, ns = ...

-- "Find": the one place to ask "where is...?". Its search box looks through
-- everything Search.lua indexes (quests, items, people by name or role,
-- dungeons, zones, towns, your class's spells and professions) and shows the
-- same rows the Quests, Items, Trainers, Vendors and Dungeons pages show, with
-- the same actions: click for directions or a journey, "Add detour" while a
-- journey is on, details on hover. The category buttons narrow it: All /
-- Quests / Items / People / Places.
--
-- With nothing typed it answers "where am I stuck?" for right now: the
-- current stop's NPC or objective, each quest in your log with something left
-- to do ("Where do I find Shimmerweed?"), your class trainer, the nearest
-- repair and flight master.
--
-- /ww find <text> opens it; /ww quest and /ww item open it on Quests / Items.

local Find = { id = "find", label = "Find", order = 5, searchable = true,
  icon = "Interface\\Icons\\INV_Misc_QuestionMark", selected = 1 }
ns.Find = Find

local MAX_RESULTS = 12  -- rows for a search over several kinds
local MIN_LENGTH = 2

local CATEGORIES = {
  { label = "All", key = "all", placeholder = "A quest, item, person, dungeon, zone or spell" },
  { label = "Quests", key = "quests", kinds = { "quest" }, placeholder = "Quest name (or shift-click a quest link)" },
  { label = "Items", key = "items", kinds = { "item" }, placeholder = "Shift-click an item, or type its name" },
  { label = "People", key = "people", kinds = { "npc", "spell", "profession" },
    placeholder = "A name or a role: warlock trainer, innkeeper, repair" },
  { label = "Places", key = "places", kinds = { "zone", "place", "dungeon" }, placeholder = "A zone, town or dungeon" },
}
Find.categories = CATEGORIES

local GREY = { r = 0.6, g = 0.6, b = 0.6 }
local GREEN = { r = 0.5, g = 0.82, b = 0.68 }

local summary

local function trim(text)
  return ((text or ""):match("^%s*(.-)%s*$"))
end

local function current()
  return CATEGORIES[Find.selected or 1] or CATEGORIES[1]
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

-- A row's "zone · time" tail for a subtitle.
local function whereText(row)
  local parts = {}
  local node = row.goal or (row.journey and row.journey.stops[1] and row.journey.stops[1].node)
  if node then parts[#parts + 1] = ns.MapName(node.mapID) end
  local seconds = row.journey and row.journey.seconds or (row.route and row.route.seconds)
  parts[#parts + 1] = seconds and ns.FormatDuration(seconds) or "no route found from here"
  return table.concat(parts, "  ·  ")
end

-- The same row under another question: title, id and the first subtitle part.
local function asQuestion(row, id, title, lead)
  local out = {}
  for k, v in pairs(row) do out[k] = v end
  out.id, out.title, out.titleColor = id, title, nil
  out.subtitle = (lead and (lead .. "  ·  ") or "") .. whereText(row)
  return out
end

-- A route node for an NPC as a destination (a talk stop when added).
local function npcGoal(node, name)
  local goal = ns.Geo.Node(node.mapID, node.x, node.y, name) or node
  goal.npc = name
  return goal
end

---------------------------------------------------------------- rows per kind

local builders = {}

function builders.quest(m, ctx)
  return ns.QuestsPage.RowFor(m.id, ctx.start, ctx.net, ctx.done, ctx.inLog)
end

function builders.item(m)
  return ns.Items.MatchRow(m.id, m.name)
end

-- Your own class trainer gets the Trainers page's row (spells, learn stop).
local function trainerRowFor(id, ctx)
  if not ctx.trainers then ctx.trainers = ns.Trainers.Results() or {} end
  for _, r in ipairs(ctx.trainers) do
    if r.id == id then return r end
  end
  return nil
end

function builders.npc(m, ctx)
  local faction = UnitFactionGroup("player")
  local friendly
  if m.met then
    friendly = m.faction == nil or m.faction == faction or m.faction == "Neutral"
  else
    friendly = ns.Data.FriendlyTo(m.faction, faction)
  end
  if not friendly then return nil end
  local _, class = UnitClass("player")
  if m.roles.classTrainer and m.class == class then
    local row = trainerRowFor(m.id, ctx)
    if row then return row end
  end
  local role = ns.Search.RoleText(m)
  local row = { id = "npc" .. m.id, kind = "npc", title = m.name, details = role and { { text = role, color = GREY } } or nil }
  local node = #m.nodes > 0 and ns.Data.Nearest(m.nodes, ctx.start)
  if not node then
    row.subtitle = (role and (role .. "  ·  ") or "") .. "where they are isn't known yet"
    return row
  end
  row.goal = npcGoal(node, m.name)
  row.route = ns.Router.Plan(ctx.start, row.goal, ctx.net)
  row.subtitle = (role and (role .. "  ·  ") or "") .. whereText(row)
  return ns.Search.WithDetour(row)
end

function builders.dungeon(m, ctx)
  return ns.Dungeons.RowFor(m.dungeon, ctx.start, ctx.net)
end

-- Directions to a zone: its nearest flight-path town by travel time, else
-- the point where the way into it crosses its border (Router's zone steps),
-- else its middle.
function builders.zone(m, ctx)
  local mapID = m.id
  local row = { id = "zone" .. mapID, kind = "zone", title = m.name }
  local best
  for _, p in ipairs(ns.Search.Index("place")) do
    if ns.Geo.ZoneAt(p.node.instance, p.node.wx, p.node.wy) == mapID then
      local route = ns.Router.Plan(ctx.start, p.node, ctx.net)
      if route and (not best or route.seconds < best.route.seconds) then best = { place = p, route = route } end
    end
  end
  local here = ns.Geo.ZoneAt(ctx.start.instance, ctx.start.wx, ctx.start.wy) == mapID
  if best then
    row.goal = ns.Geo.Node(best.place.node.mapID, best.place.node.x, best.place.node.y,
      string.format("%s (%s)", m.name, best.place.name)) or best.place.node
    row.route = best.route
    row.details = { { text = (here and "You're in it. " or "") .. "Directions go to " .. best.place.name
      .. ", its flight path.", color = GREY } }
  else
    local centre = ns.Geo.Node(mapID, 0.5, 0.5, m.name)
    local route = centre and ns.Router.Plan(ctx.start, centre, ctx.net)
    if route then
      local zoned = ns.Router.WithZoneSteps(route)
      local steps, seconds, entry = {}, 0, nil
      for _, step in ipairs(zoned.steps) do
        steps[#steps + 1] = step
        seconds = seconds + (step.seconds or 0)
        if step.zoneEntry == mapID then
          entry = step.to
          break
        end
      end
      if entry then
        row.goal, row.route = entry, { steps = steps, seconds = seconds, zoned = true }
        row.details = { { text = "Directions go to where the way crosses into it.", color = GREY } }
      else
        row.goal, row.route = centre, route
        row.details = { { text = here and "You're in it." or "Directions go to the middle of the zone.", color = GREY } }
      end
    else
      row.goal = centre
    end
  end
  row.subtitle = "Zone  ·  " .. whereText(row)
  return ns.Search.WithDetour(row)
end

function builders.place(m, ctx)
  local row = { id = "place" .. tostring(m.id), kind = "place", title = m.name,
    goal = ns.Geo.Node(m.node.mapID, m.node.x, m.node.y, m.name) or m.node,
    details = { { text = m.full .. ": a flight path town. Directions go to its flight master.", color = GREY } } }
  row.route = ns.Router.Plan(ctx.start, row.goal, ctx.net)
  row.subtitle = "Town  ·  " .. whereText(row)
  return ns.Search.WithDetour(row)
end

-- A spell: where to learn it (your class trainer, with its learn stop).
function builders.spell(m, ctx)
  local name = m.name .. (m.rank and (" (" .. m.rank .. ")") or "")
  local level, cost, known
  if m.service then
    level, cost, known = m.service.levelReq, m.service.cost, m.service.type == "used"
  elseif m.spell then
    level, cost, known = m.spell.level, m.spell.cost, ns.KnowsSpell(m.spell.spellID) == true
  end
  local details = {}
  if known then
    details[#details + 1] = { text = "You know this spell.", color = GREY }
  else
    if level then details[#details + 1] = { text = "Learn it at level " .. level .. ".", color = GREEN } end
    if cost then details[#details + 1] = { text = "Costs " .. ns.FormatMoney(cost) .. ".", color = GREY } end
  end
  if not ctx.trainers then ctx.trainers = ns.Trainers.Results() or {} end
  local trainer = ctx.trainers[1]
  local row = { id = "spell" .. tostring(m.id), kind = "spell", title = name, details = details }
  if trainer then
    row.goal, row.route, row.journey = trainer.goal, trainer.route, trainer.journey
    local lead = known and "You know it" or (level and level > UnitLevel("player")) and ("At level " .. level)
      or ("Learn it from " .. trainer.title)
    row.subtitle = lead .. "  ·  " .. whereText(trainer)
    for _, line in ipairs(trainer.details or {}) do details[#details + 1] = line end
  else
    row.subtitle = known and "You know it" or "No trainer for your class known yet"
  end
  return ns.Search.WithDetour(row)
end

function builders.profession(m, ctx)
  if not ctx.professions then ctx.professions = ns.Professions.Results() or {} end
  for _, r in ipairs(ctx.professions) do
    if r.id == "profession" .. m.id then return r end
  end
  return nil
end

local function searchRows(text, cat, ctx)
  local found = ns.Search.Find(text, cat.kinds)
  local rows, seen = {}, {}
  for _, m in ipairs(found) do
    if #rows >= MAX_RESULTS then break end
    local ok, row = ns.Protect(builders[m.kind], m, ctx)
    if not ok then geterrorhandler()(row) end
    if ok and row and not seen[row] then
      seen[row] = true
      rows[#rows + 1] = row
    end
  end
  return rows, #found
end

---------------------------------------------------------------- where am I stuck?

-- The objective text without its count ("3/8 Murloc Forager slain").
local function objectiveName(text)
  text = text:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
  return trim(text)
end

local function lowerFirst(text)
  return (text:gsub("^%u", string.lower))
end

-- The stop you're heading for now.
local function stopRow(ctx)
  local a = ns.Nav.active
  local step = a and a.journey and ns.Nav.CurrentStep()
  local stop = step and step.stop
  if not (stop and stop.node) or stop.done then return nil end
  local who = stop.npc or stop.giver
  local action = stop.action or {}
  local title
  if who then
    title = "Where is " .. who .. "?"
  elseif action.kind == "complete" and action.questID then
    local q = ns.Quests.Quest(action.questID)
    title = "Where do I do " .. (q and q.name or ns.QuestLog.Title(action.questID) or "this quest") .. "?"
  else
    title = "Where is " .. (stop.node.label or "my next stop") .. "?"
  end
  local row = { id = "stop", kind = "stop", title = title, goal = stop.node,
    route = ns.Router.Plan(ctx.start, stop.node, ctx.net),
    details = { { text = "Your current stop: " .. (stop.text or "?"), color = GREEN } },
    npc = who, questID = action.questID }
  row.subtitle = (stop.text or "Current stop") .. "  ·  " .. whereText(row)
  return row
end

-- One row per quest in your log with objectives left: where to work on it.
local function objectiveRows(ctx, out)
  for _, entry in ipairs(ns.QuestsPage.LogQuests()) do
    if not entry.complete then
      local node = ns.Quests.ObjectiveNode(entry.id, ctx.start)
      local stops = ns.Quests.Available() and ns.Journey.QuestStops(entry.id, ctx.start) or {}
      local journey = #stops > 0 and ns.Journey.Plan(ctx.start, { title = entry.title, stops = stops }, ctx.net) or nil
      if node or journey then
        local what = entry.progress and objectiveName(entry.progress)
        local row = { id = "objective" .. entry.id, kind = "objective", questID = entry.id,
          title = what and what ~= "" and ("Where do I find " .. what .. "?") or ("Where do I do " .. entry.title .. "?"),
          journey = journey, details = {} }
        if node then
          row.goal = ns.Geo.Node(node.mapID, node.x, node.y, entry.title) or node
          row.route = ns.Router.Plan(ctx.start, row.goal, ctx.net)
        end
        for _, o in ipairs(C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(entry.id) or {}) do
          if o.text and o.text ~= "" then
            row.details[#row.details + 1] = { text = o.text, color = o.finished and GREY or nil }
          end
        end
        row.subtitle = string.format("[%d] %s  ·  %s", entry.level, entry.title, whereText(row))
        out[#out + 1] = ns.Search.WithDetour(row, entry.title)
      end
    end
  end
end

local function trainerRow(ctx)
  local r = (ns.Trainers.Results() or {})[1]
  if not r then return nil end
  return asQuestion(r, "trainer", "Where is my class trainer?", r.title)
end

local function repairRow()
  for _, r in ipairs(ns.Vendors.Results() or {}) do
    if r.covers and r.covers.repair and r.route then
      return asQuestion(r, "repair", "Nearest repair", r.goal.npc or r.goal.label or r.title)
    end
  end
  return nil
end

local function nearestRow(role, id, title, ctx)
  local best = ns.Search.NearestNPC(role, ctx.start, ctx.net)
  if not best then return nil end
  local row = { id = id, kind = "npc", title = title, goal = npcGoal(best.node, best.name), route = best.route,
    details = { { text = best.name, color = GREY } } }
  row.subtitle = best.name .. "  ·  " .. whereText(row)
  return ns.Search.WithDetour(row)
end

-- The questions worth asking right now (All; People and Places keep theirs).
local function situation(cat, ctx)
  local key = cat.key
  local rows = {}
  local function add(row) if row then rows[#rows + 1] = row end end
  -- The current stop: under People only when it's someone to talk to.
  local stop = key ~= "places" and stopRow(ctx) or nil
  if stop and key == "people" and not stop.npc then stop = nil end
  add(stop)
  if key == "all" then objectiveRows(ctx, rows) end
  if key == "all" or key == "people" then
    add(trainerRow(ctx))
    add(repairRow())
    add(nearestRow("flightMaster", "flight", "Nearest flight master", ctx))
  end
  if key == "places" then
    add(nearestRow("flightMaster", "flight", "Nearest flight master", ctx))
    add(nearestRow("innkeeper", "inn", "Nearest inn", ctx))
  end
  if #rows > 0 then summary = "Likely questions right now. Click one for directions, or type to find anything." end
  return rows
end

---------------------------------------------------------------- the page

function Find.Placeholder()
  return current().placeholder
end

-- The Quests and Items views are those pages (the Journal with your log when
-- nothing is typed, the Items hint); the rest is Find's own.
function Find.SummaryText(query)
  local cat = current()
  if cat.key == "quests" then return ns.QuestsPage.SummaryText(query) end
  if cat.key == "items" then return ns.Items.SummaryText(query) end
  if summary then return summary end
  return "Stuck? Type what you're looking for: a quest, an item, someone (by name or role), a dungeon, a zone "
    .. "or a spell. In chat: /ww find <text>."
end

function Find.EmptyText(query)
  local cat, text = current(), trim(query)
  if cat.key == "quests" then return ns.QuestsPage.EmptyText(query) end
  if cat.key == "items" then return ns.Items.EmptyText(query) end
  if text == "" then
    return "Nothing to ask right now: no journey on and nothing left to do in your log. "
      .. "Type what you're looking for."
  end
  if #text < MIN_LENGTH then return "Type at least " .. MIN_LENGTH .. " letters." end
  return string.format("Nothing called \"%s\" among %s.", text,
    cat.key == "people" and "the people and spells Wayward knows"
    or cat.key == "places" and "the zones, towns and dungeons Wayward knows"
    or "quests, items, people and places")
end

function Find.Results(query)
  summary = nil
  local cat, text = current(), trim(query)
  local kind = ns.Search.Parse(text)
  -- A linked quest or item shows its own page's rows (status, sources).
  if cat.key == "quests" or (text ~= "" and kind == "quest") then return ns.QuestsPage.Results(query) end
  if cat.key == "items" or (text ~= "" and kind == "item") then return ns.Items.Results(query) end
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local ctx = { start = start, net = ns.Network.Build() }
  if text == "" then return situation(cat, ctx), nil, ctx.net end
  if #text < MIN_LENGTH then return {}, nil, ctx.net end
  ctx.done, ctx.inLog = ns.Quests.PlayerQuestState()
  local rows, total = searchRows(text, cat, ctx)
  if total > #rows then
    summary = string.format("First %d of %s matching \"%s\". Type more to narrow it down.", #rows,
      plural(total, "match"), text)
  elseif #rows > 0 then
    summary = string.format("%s matching \"%s\". Click one to go there.", plural(#rows, "match"), text)
  end
  return rows, nil, ctx.net
end

ns.RegisterPage(Find)

-- Opens Find on a category ("all", "quests", "items", "people", "places")
-- with a search.
function Find.Open(category, text)
  local index = 1
  for i, c in ipairs(CATEGORIES) do
    if c.key == category then index = i end
  end
  ns.Panel.Search("find", text or "")
  if index ~= 1 then ns.Panel.Select(index) end
end

ns.RegisterCommand("find", "/ww find <text> - find a quest, item, person, dungeon, zone or spell, with directions",
  function(rest) Find.Open("all", rest) end)
