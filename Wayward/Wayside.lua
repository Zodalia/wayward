local _, ns = ...

-- On the way: the one list of what's near the journey you're on, for the
-- one place it shows (the drawer on the directions box, UI/Drawer.lua, and
-- the journey overview's "Detours on the way"). Two kinds of row:
--
--   gathering  what the journey is already gathering as you go, with counts
--              (Journey.ShoppingList). Nothing to add: it's on the journey.
--   offers     what you could add, each with a + and the time it adds where
--              that's known: quests in your log with something on the way,
--              quest givers, hand-ins and vendors you need near the way
--              (OnTheWay.lua), and a new suggestion from For you (which
--              would have been a toast, were you not on a journey).
--
-- Wayside.Get(routed) -> { gathering = { row... }, more (gathering things
--   past the rows), offers = { row... } }
-- row = { id, kind ("gather" | "log" | "way" | "card"), text, right (the
--   time it adds, or a word), tip = { title, line... }, entry / questID /
--   suggestion / result (what it's made from) }
--
-- An offer is a suggestion and no more (pillar 1): it makes no sound, the
-- arrow doesn't move for it, and one you dismiss stays away for the rest of
-- the journey. `routed`: also the offers that need routes worked out
-- (OnTheWay.Get); without it only what's cheap to know, for the count on
-- the closed drawer's button.

local Wayside = {}
ns.Wayside = Wayside

local GATHER_ROWS = 4   -- things gathered listed; the rest is one "+N more"
local OFFER_ROWS = 4    -- offers listed
local GREY = "|cff9d9d9d"

local function countText(e)
  return (e.have and e.need) and string.format("%d/%d", e.have, e.need) or nil
end

local function placeOf(node)
  if not (node and ns.Places) then return nil end
  local ok, place = pcall(ns.Places.NameFor, node)
  return ok and place or nil
end

-- "Goretusk  0/3 · Redridge Stew" around you; farther off, dimmer, and where
-- the nearest is when that has a name ("· near Lakeshire").
local function thingText(e)
  local count = countText(e)
  local where = ""
  if not e.near then
    local place = placeOf(e.node)
    where = place and ("  ·  near " .. place) or ""
  end
  return string.format("%s%s|r  %s%s%s%s|r", e.near and "|cffffffff" or "|cffb0b0b0", e.name, GREY,
    count and (count .. "  ·  ") or "", e.quest, where)
end

-- Everything still wanted near the way: the journey's things gathered as
-- you go, and its way ahead for the quests in your log that aren't on it.
local function wanted(a)
  if not a then return {} end
  return ns.Journey.ShoppingList(a.journey, ns.Geo.PlayerNode(), a.route, a.index)
end

-- Things as lines, top to bottom: { text, entry } for up to GATHER_ROWS
-- (around you first, then nearest: Journey.ShoppingList's order), then
-- { text, entries } for the rest. Empty when there's nothing wanted.
function Wayside.Lines(list)
  list = list or wanted(ns.Nav.active)
  local lines, rest = {}, {}
  for _, e in ipairs(list) do
    if #lines < GATHER_ROWS then
      lines[#lines + 1] = { text = thingText(e), entry = e }
    else
      rest[#rest + 1] = e
    end
  end
  if #rest > 0 then
    lines[#lines + 1] = { text = string.format("%s+%d more|r", GREY, #rest), entries = rest }
  end
  return lines
end

local function dismissed(a)
  a.waysideDismissed = a.waysideDismissed or {}
  return a.waysideDismissed
end

local function gatherRow(line)
  if line.entries then
    local tip = { "Also gathering" }
    for _, e in ipairs(line.entries) do
      local place = placeOf(e.node)
      tip[#tip + 1] = string.format("%s%s  %s%s|r", e.name, countText(e) and (" " .. countText(e)) or "", GREY,
        place and ("near " .. place) or "elsewhere")
    end
    return { id = "gather:more", kind = "gather", text = line.text, tip = tip, entries = line.entries }
  end
  local e = line.entry
  local place = not e.near and placeOf(e.node)
  return { id = "gather:" .. e.questID .. ":" .. e.name, kind = "gather", text = line.text, entry = e,
    tip = { e.name, string.format("For %s. %s.", e.quest, e.near and "Around you" or place and ("Nearest near " .. place)
      or "Farther off"), "The journey takes you through these when they're on the way; it carries on whenever you do." } }
end

-- A quest in your log, off the journey, with things on the way: one row a quest.
local function logRows(entries)
  local rows, byQuest = {}, {}
  for _, e in ipairs(entries) do
    local row = byQuest[e.questID]
    if not row then
      row = { id = "log:" .. e.questID, kind = "log", questID = e.questID, quest = e.quest, things = {}, near = false }
      byQuest[e.questID] = row
      rows[#rows + 1] = row
    end
    row.things[#row.things + 1] = e
    row.near = row.near or e.near
  end
  for _, row in ipairs(rows) do
    local first = row.things[1]
    local count = countText(first)
    row.text = string.format("|cffffffff%s|r  %s%s%s%s|r", row.quest, GREY, first.name, count and (" " .. count) or "",
      #row.things > 1 and string.format(", +%d more", #row.things - 1) or "")
    row.right = row.near and "around you" or "on the way"
    row.tip = { row.quest, "In your quest log, not on this journey: its objectives are on your way." }
    for _, e in ipairs(row.things) do
      row.tip[#row.tip + 1] = string.format("%s%s", e.name, countText(e) and (" " .. countText(e)) or "")
    end
    row.tip[#row.tip + 1] = "Add it and the journey takes in the rest of the quest."
  end
  return rows
end

local function wayRow(s)
  return { id = "way:" .. s.kind .. ":" .. s.label, kind = "way", suggestion = s, text = s.label,
    right = "+" .. ns.FormatDuration(s.extra), extra = s.extra,
    tip = { s.label, string.format("A detour of %s on your journey.", ns.FormatDuration(s.extra)) } }
end

local function cardRow(r)
  local title = (r.title or "?"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return { id = "card:" .. tostring(r.id or r.title), kind = "card", result = r, text = title, right = "new",
    tip = { title, r.why or r.subtitle or "A new suggestion from For you.", "Add it to this journey as a detour." } }
end

function Wayside.Get(routed)
  local a = ns.Nav.active
  local out = { gathering = {}, offers = {}, more = 0 }
  if not a then return out end
  local mine, fromLog = {}, {}
  for _, e in ipairs(wanted(a)) do
    if e.fromLog then fromLog[#fromLog + 1] = e else mine[#mine + 1] = e end
  end
  for _, line in ipairs(Wayside.Lines(mine)) do out.gathering[#out.gathering + 1] = gatherRow(line) end
  out.things = #mine

  local gone = dismissed(a)
  local offers = {}
  local function offer(row)
    if not gone[row.id] then offers[#offers + 1] = row end
  end
  -- A new suggestion first (it's the one you haven't seen), then the quests
  -- you already have, then what's least out of the way.
  for _, r in ipairs(a.waysideCards or {}) do offer(cardRow(r)) end
  for _, row in ipairs(logRows(fromLog)) do offer(row) end
  if routed and ns.OnTheWay then
    local ok, list = pcall(ns.OnTheWay.Get)
    for _, s in ipairs(ok and list or {}) do offer(wayRow(s)) end
  end
  out.more = math.max(0, #offers - OFFER_ROWS)
  for i = 1, math.min(#offers, OFFER_ROWS) do out.offers[i] = offers[i] end
  return out
end

-- How many things there are to glance at: what you're gathering and what's
-- on offer (the cheap ones: see `routed`).
function Wayside.Count()
  local w = Wayside.Get(false)
  return (w.things or 0) + #w.offers + w.more
end

-- Adds an offer to the journey. Returns true when the journey changed.
function Wayside.Add(row)
  local a = ns.Nav.active
  if not (a and row) then return false end
  if row.kind == "way" then return ns.OnTheWay.Add(row.suggestion) end
  if row.kind == "log" then
    local here = ns.Geo.PlayerNode()
    local stops = here and ns.Journey.QuestStops(row.questID, here) or {}
    return ns.Nav.AddToTrip(stops, row.quest)
  end
  if row.kind == "card" then
    local added = ns.Nav.AddToTrip(ns.Nav.StopsFor(row.result), row.text)
    -- Added or already there: either way it's no longer on offer.
    for i, r in ipairs(a.waysideCards or {}) do
      if r == row.result then table.remove(a.waysideCards, i) break end
    end
    return added
  end
  return false
end

-- Not for you: gone for the rest of this journey.
function Wayside.Dismiss(row)
  local a = ns.Nav.active
  if not (a and row and row.kind ~= "gather") then return false end
  dismissed(a)[row.id] = true
  ns.Fire("WAYSIDE_CHANGED")
  return true
end

-- A new suggestion from For you while you're on a journey: a row on the
-- list rather than a toast over what you're doing. False with no journey on
-- (then it's a toast, UI/Fanfare.lua).
function Wayside.Offer(result)
  local a = ns.Nav.active
  if not (a and result) then return false end
  a.waysideCards = a.waysideCards or {}
  for _, r in ipairs(a.waysideCards) do
    if r == result or (r.id ~= nil and r.id == result.id) then return true end
  end
  table.insert(a.waysideCards, 1, result)
  ns.Fire("WAYSIDE_CHANGED")
  return true
end
