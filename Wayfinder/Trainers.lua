local _, ns = ...

-- Trainers page categories: "Class" (known trainers for your class, ranked by
-- travel time, plus what you could train right now) and "Weapons" (weapon
-- masters).

local Trainers = { id = "classTrainer", label = "Class" }
ns.Trainers = Trainers

local WeaponMasters = { id = "weaponMaster", label = "Weapons" }
ns.WeaponMasters = WeaponMasters

local function knowsSpell(spellID)
  if IsPlayerSpell then return IsPlayerSpell(spellID) and true or false end
  if IsSpellKnown then return IsSpellKnown(spellID) and true or false end
  return false
end

local function spellName(spellID)
  if C_Spell and C_Spell.GetSpellName then
    return C_Spell.GetSpellName(spellID), C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(spellID)
  end
  if GetSpellInfo then return (GetSpellInfo(spellID)), GetSpellSubtext and GetSpellSubtext(spellID) end
  return nil
end

local dataServices -- { level, services } built from ns.Data.ClassSpells

ns.Listen("SOURCES_CHANGED", function() dataServices = nil end)
ns.On("SPELLS_CHANGED", function() dataServices = nil end)

-- Your class's spells in the shape of a trainer reading (Harvest.lua), from
-- the data sources: "used" when you know it, "available" from its level.
local function servicesFromData()
  local level = UnitLevel("player")
  if dataServices and dataServices.level == level then return dataServices.services end
  local _, class = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local faction = UnitFactionGroup("player")
  local services = {}
  for _, spell in ipairs(ns.Data.ClassSpells(class)) do
    -- Spells for another race or faction, or for a talent you don't have,
    -- aren't on your trainer's list.
    if (not spell.races or spell.races[raceID]) and (not spell.faction or spell.faction == faction)
      and (not spell.talent or knowsSpell(spell.talent)) then
      local name, rank = spellName(spell.spellID)
      local known = knowsSpell(spell.spellID)
      services[#services + 1] = { name = name or ("Spell " .. spell.spellID), rank = rank ~= "" and rank or nil,
        spellID = spell.spellID, levelReq = spell.level, cost = spell.cost,
        type = known and "used" or ((spell.level or 0) <= level and "available" or "unavailable") }
    end
  end
  dataServices = { level = level, services = services }
  return services
end

-- Your class's trainer services and where they come from: your last trainer
-- visit ("trainer"; it knows Forever's own list and prices) or the data
-- sources ("data"), or nil without either.
function Trainers.Services()
  local cs = ns.charDB.classSpells
  if cs then return cs.services, "trainer", cs end
  local services = servicesFromData()
  if #services > 0 then return services, "data" end
  return nil
end

-- Spells named under the Class page's summary line; the rest are counted.
local SUMMARY_SPELLS = 6

local function spellKey(s)
  return s.name .. (s.rank and (" (" .. s.rank .. ")") or "")
end

-- Spells you could learn when you last closed a class trainer's window and
-- didn't: For you leaves them out (the Class page still lists them). Each
-- visit replaces the list, since it shows every spell you can learn again.
function Trainers.RecordSkipped(services)
  local skipped = {}
  for _, s in ipairs(services or {}) do
    if s.type == "available" and s.name then skipped[spellKey(s)] = true end
  end
  ns.charDB.skippedSpells = next(skipped) and skipped or nil
  ns.Fire("DATA_CHANGED")
end

function Trainers.Skipped(s)
  local skipped = ns.charDB.skippedSpells
  return skipped ~= nil and s.name ~= nil and skipped[spellKey(s)] == true
end

-- Learning happens at a trainer, which refreshes the list, so "not used and
-- level reached" means trainable now. `leaveOutSkipped`: not the spells you
-- left at the trainer (counted in `skipped` instead).
function Trainers.SpellSummary(leaveOutSkipped)
  local services, from, cs = Trainers.Services()
  if not services then return nil end
  local level = UnitLevel("player")
  local out = { trainable = 0, cost = 0, nextCount = 0, skipped = 0, updated = cs and cs.updated,
    level = cs and cs.level, fromData = from == "data", names = {} }
  for _, s in ipairs(services) do
    if s.type ~= "used" and s.levelReq then
      if s.levelReq <= level and leaveOutSkipped and Trainers.Skipped(s) then
        out.skipped = out.skipped + 1
      elseif s.levelReq <= level then
        out.trainable = out.trainable + 1
        out.cost = out.cost + (s.cost or 0)
        out.names[#out.names + 1] = spellKey(s)
        if not s.cost then out.costUnknown = true end
      elseif not out.nextLevel or s.levelReq < out.nextLevel then
        out.nextLevel = s.levelReq
      end
    end
  end
  for _, s in ipairs(services) do
    if s.type ~= "used" and s.levelReq == out.nextLevel then out.nextCount = out.nextCount + 1 end
  end
  return out
end

function Trainers.SummaryText()
  local s = Trainers.SpellSummary()
  if not s then return "Visit any trainer for your class once to see which spells you can learn." end
  local parts = {}
  if s.trainable > 0 and s.costUnknown then
    parts[#parts + 1] = string.format("|cff7fd1ae%d new spell%s to train|r", s.trainable, s.trainable == 1 and "" or "s")
  elseif s.trainable > 0 then
    local afford = GetMoney() >= s.cost and "" or " (you're short)"
    parts[#parts + 1] = string.format("|cff7fd1ae%d new spell%s to train|r for %s%s", s.trainable,
      s.trainable == 1 and "" or "s", ns.FormatMoney(s.cost), afford)
  else
    parts[#parts + 1] = "Nothing new to train yet"
  end
  if s.nextLevel then
    parts[#parts + 1] = string.format("next: %d spell%s at level %d", s.nextCount,
      s.nextCount == 1 and "" or "s", s.nextLevel)
  end
  if s.fromData then parts[#parts + 1] = "from spell data until you visit a trainer" end
  local text = table.concat(parts, " · ")
  if #s.names > 0 then
    local shown = {}
    for i = 1, math.min(#s.names, SUMMARY_SPELLS) do shown[i] = s.names[i] end
    local more = #s.names - #shown
    text = text .. "\n" .. table.concat(shown, ", ") .. (more > 0 and string.format(" and %d more", more) or "")
  end
  return text
end

function Trainers.EmptyText()
  local className = UnitClass("player")
  return string.format("No %s trainers known yet. Talk to one once and Wayfinder remembers where "
    .. "they are, or install a Wayfinder data addon. City guards can point you to one.", className:lower())
end

-- Trainers this close together (one room or building) are one result.
local GROUP_RADIUS = 40

-- Results for trainers { id, name, node, weapons? }: those in one room are one
-- result ("3 warlock trainers in Stormwind City", `plural` names them), sorted
-- by travel time.
local function results(trainers, plural, start, net)
  local groups = {}
  for _, t in ipairs(trainers) do
    local home
    for _, g in ipairs(groups) do
      for _, member in ipairs(g) do
        if ns.Geo.Distance(member.node, t.node) <= GROUP_RADIUS then home = g break end
      end
      if home then break end
    end
    if home then table.insert(home, t) else groups[#groups + 1] = { t } end
  end

  local out = {}
  for _, g in ipairs(groups) do
    table.sort(g, function(a, b) return ns.Geo.Distance(start, a.node) < ns.Geo.Distance(start, b.node) end)
    local goal = g[1].node
    local title, details = g[1].name, nil
    if #g > 1 then
      local place = ns.Places.NameFor(goal) or ns.MapName(goal.mapID)
      title = string.format("%d %s in %s", #g, plural, place)
    end
    for _, t in ipairs(g) do
      local line = t.weapons and #t.weapons > 0 and table.concat(t.weapons, ", ") or nil
      if #g > 1 or line then
        details = details or {}
        details[#details + 1] = { text = #g > 1 and line and (t.name .. ": " .. line) or line or t.name }
      end
    end
    goal.npc = g[1].name
    out[#out + 1] = {
      id = g[1].id,
      title = title,
      zone = ns.MapName(goal.mapID),
      goal = goal,
      route = ns.Router.Plan(start, goal, net),
      details = details,
    }
  end
  table.sort(out, function(a, b)
    local ta = a.route and a.route.seconds or math.huge
    local tb = b.route and b.route.seconds or math.huge
    if ta ~= tb then return ta < tb end
    return a.title < b.title
  end)
  return out
end

-- Known NPCs of one kind for your faction (visited ones and Data/Seed.lua;
-- their positions were measured in Forever), then the data sources'.
local function collect(kind, fits, fromSources)
  local trainers, seen = {}, {}
  local faction = UnitFactionGroup("player")
  for id, npc in pairs(ns.Harvest.AllNPCs()) do
    if npc.kinds[kind] and (npc.faction == nil or npc.faction == faction) and (not fits or fits(npc)) then
      local node = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.name)
      if node then
        seen[id] = true
        trainers[#trainers + 1] = { id = id, name = npc.name, node = node, weapons = npc.weapons }
      end
    end
  end
  for _, t in ipairs(fromSources) do
    if not seen[t.id] then trainers[#trainers + 1] = { id = t.id, name = t.name, node = t.node } end
  end
  return trainers
end

-- Results: { title, zone, goal (route node), route, details } sorted by travel time.
-- Sources: trainers you visited, Data/Seed.lua, and the data sources (Sources.lua).
function Trainers.Results()
  local className, class = UnitClass("player")
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local trainers = collect("classTrainer", function(npc) return npc.class == class end,
    ns.Data.NearestOfKind("classTrainer", UnitFactionGroup("player"), start, function(t) return t.class == class end))
  return results(trainers, (className or class):lower() .. " trainers", start, net), nil, net
end

---------------------------------------------------------------- weapon masters

-- Weapon skills: the spell that means you know one, and which classes can
-- learn it (the classic rules; wands come with the class, not a trainer).
local WEAPONS = {
  { name = "Axes", spell = 196, classes = "WARRIOR PALADIN HUNTER SHAMAN" },
  { name = "Two-Handed Axes", spell = 197, classes = "WARRIOR PALADIN HUNTER SHAMAN" },
  { name = "Maces", spell = 198, classes = "WARRIOR PALADIN ROGUE PRIEST SHAMAN DRUID" },
  { name = "Two-Handed Maces", spell = 199, classes = "WARRIOR PALADIN SHAMAN DRUID" },
  { name = "Polearms", spell = 200, classes = "WARRIOR PALADIN HUNTER" },
  { name = "Swords", spell = 201, classes = "WARRIOR PALADIN HUNTER ROGUE MAGE WARLOCK" },
  { name = "Two-Handed Swords", spell = 202, classes = "WARRIOR PALADIN HUNTER" },
  { name = "Staves", spell = 227, classes = "WARRIOR HUNTER PRIEST SHAMAN MAGE WARLOCK DRUID" },
  { name = "Daggers", spell = 1180, classes = "WARRIOR HUNTER ROGUE PRIEST SHAMAN MAGE WARLOCK DRUID" },
  { name = "Fist Weapons", spell = 15590, classes = "WARRIOR HUNTER ROGUE SHAMAN DRUID" },
  { name = "Bows", spell = 264, classes = "WARRIOR HUNTER ROGUE" },
  { name = "Crossbows", spell = 5011, classes = "WARRIOR HUNTER ROGUE" },
  { name = "Guns", spell = 266, classes = "WARRIOR HUNTER ROGUE" },
  { name = "Thrown", spell = 2567, classes = "WARRIOR HUNTER ROGUE" },
}
WeaponMasters.WEAPONS = WEAPONS

local GREEN, RED, GREY = "|cff7fd1ae", "|cffff7f3f", "|cff9d9d9d"

-- Whether you know a weapon skill: true / false, or nil when this client can't say.
local function knows(weapon)
  if IsPlayerSpell then return IsPlayerSpell(weapon.spell) and true or false end
  if IsSpellKnown then return IsSpellKnown(weapon.spell) and true or false end
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      if GetSkillLineInfo(i) == weapon.name then return true end
    end
    return false
  end
  return nil
end

-- The weapons your class can use: { {weapon, known}, ... } in the order above.
function WeaponMasters.Weapons()
  local _, class = UnitClass("player")
  local out = {}
  for _, w in ipairs(WEAPONS) do
    if (" " .. w.classes .. " "):find(" " .. class .. " ", 1, true) then out[#out + 1] = { weapon = w, known = knows(w) } end
  end
  return out
end

function WeaponMasters.SummaryText()
  local known, toLearn, unknown = {}, 0, false
  for _, w in ipairs(WeaponMasters.Weapons()) do
    if w.known == nil then unknown = true elseif w.known then known[#known + 1] = w.weapon.name else toLearn = toLearn + 1 end
  end
  if unknown then return "Weapon masters teach weapon skills. This client doesn't say which ones you know." end
  return string.format("You know %s. %s Your purse: %s.", #known > 0 and table.concat(known, ", ") or "no weapon skills yet",
    toLearn > 0 and string.format("You can learn %d more, below.", toLearn) or "Nothing more to learn for your class.",
    ns.FormatMoney(GetMoney()))
end

function WeaponMasters.EmptyText()
  local knowsAll = true
  for _, w in ipairs(WeaponMasters.Weapons()) do
    if w.known ~= true then knowsAll = false end
  end
  if knowsAll then return "You know every weapon skill your class can learn." end
  return "No weapon masters known yet. Talk to one once and Wayfinder remembers where they are and what they teach, "
    .. "or install a Wayfinder data addon."
end

-- One row per weapon you can learn, "Polearms (Woo Ping)": the nearest weapon
-- master known to teach it to your class, with the cost against your purse.
-- Weapons no visited master teaches go to the nearest master you haven't
-- visited (they list what they teach).
function WeaponMasters.Results()
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local _, class = UnitClass("player")
  local masters = collect("weaponMaster", nil, ns.Data.NearestOfKind("weaponMaster", UnitFactionGroup("player"), start))
  local npcs = ns.Harvest.AllNPCs()
  local routes = {}
  local function routeTo(m)
    if routes[m] == nil then routes[m] = ns.Router.Plan(start, m.node, net) or false end
    return routes[m] or nil
  end

  -- Who teaches what to your class: from your visits, else from the data
  -- sources' trainer lists (matched by the weapon skill's spell).
  local weaponBySpell = {}
  for _, w in ipairs(WEAPONS) do weaponBySpell[w.spell] = w end
  local teachers, unvisited = {}, {}
  for _, m in ipairs(masters) do
    local npc = npcs[m.id]
    local list = npc and npc.teaches and npc.teaches[class]
    if list then
      for _, t in ipairs(list) do
        teachers[t.name] = teachers[t.name] or {}
        table.insert(teachers[t.name], { master = m, cost = t.cost })
      end
    else
      local fromData = false
      for _, sp in ipairs(ns.Data.TrainerSpells(m.id) or {}) do
        local w = weaponBySpell[sp.spellID]
        if w then
          fromData = true
          teachers[w.name] = teachers[w.name] or {}
          table.insert(teachers[w.name], { master = m, cost = sp.cost })
        end
      end
      if not fromData then unvisited[#unvisited + 1] = m end
    end
  end
  local nearestUnvisited
  for _, m in ipairs(unvisited) do
    local r = routeTo(m)
    if r and (not nearestUnvisited or r.seconds < routeTo(nearestUnvisited).seconds) then nearestUnvisited = m end
  end

  local money = GetMoney()
  local rows = {}
  for _, w in ipairs(WeaponMasters.Weapons()) do
    if w.known == false then
      local best, bestRoute
      for _, t in ipairs(teachers[w.weapon.name] or {}) do
        local r = routeTo(t.master)
        if r and (not bestRoute or r.seconds < bestRoute.seconds) then best, bestRoute = t, r end
      end
      if best then
        local cost = best.cost
        local price = cost and (money >= cost and (GREEN .. ns.FormatMoney(cost) .. "|r")
          or string.format("%s%s|r (you have %s)", RED, ns.FormatMoney(cost), ns.FormatMoney(money))) or "cost unknown"
        local details = { { text = string.format("Learn %s from %s for %s.", w.weapon.name, best.master.name,
          cost and ns.FormatMoney(cost) or "a fee") } }
        local others = {}
        for _, t in ipairs(teachers[w.weapon.name]) do
          if t ~= best then others[#others + 1] = t.master.name end
        end
        if #others > 0 then details[#details + 1] = { text = "Also taught by " .. table.concat(others, ", ") .. "." } end
        best.master.node.npc = best.master.name
        rows[#rows + 1] = {
          id = "weapon" .. w.weapon.spell, title = string.format("%s  %s(%s)|r", w.weapon.name, GREY, best.master.name),
          subtitle = string.format("%s  ·  %s  ·  %s", ns.MapName(best.master.node.mapID), price,
            ns.FormatDuration(bestRoute.seconds)),
          goal = best.master.node, route = bestRoute, details = details,
          rank = (cost and money < cost) and 1 or 0, seconds = bestRoute.seconds,
        }
      else
        local r = nearestUnvisited and routeTo(nearestUnvisited)
        rows[#rows + 1] = {
          id = "weapon" .. w.weapon.spell, title = w.weapon.name,
          subtitle = nearestUnvisited and string.format("who teaches it isn't known yet  ·  ask %s  ·  %s",
            nearestUnvisited.name, ns.FormatDuration(r.seconds)) or "who teaches it isn't known yet",
          goal = nearestUnvisited and nearestUnvisited.node, route = r,
          details = { { text = "Weapon masters list what they teach when you talk to them; Wayfinder remembers it." } },
          rank = 2, seconds = r and r.seconds or math.huge,
        }
      end
    end
  end
  -- Affordable first, then too dear, then not known where; nearest first in each.
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.seconds ~= b.seconds then return a.seconds < b.seconds end
    return a.title < b.title
  end)
  return rows, nil, net
end
