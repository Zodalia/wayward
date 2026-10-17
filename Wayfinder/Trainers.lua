local _, ns = ...

-- Trainers page categories: "Class" (known trainers for your class, ranked by
-- travel time, plus what you could train right now) and "Weapons" (weapon
-- masters).

local Trainers = { id = "classTrainer", label = "Class" }
ns.Trainers = Trainers

local WeaponMasters = { id = "weaponMaster", label = "Weapons" }
ns.WeaponMasters = WeaponMasters

-- Uses the spell list from your last class trainer visit. Learning happens at
-- a trainer, which refreshes the list, so "not used and level reached" means
-- trainable now.
function Trainers.SpellSummary()
  local cs = ns.charDB.classSpells
  if not cs then return nil end
  local level = UnitLevel("player")
  local out = { trainable = 0, cost = 0, nextCount = 0, updated = cs.updated }
  for _, s in ipairs(cs.services) do
    if s.type ~= "used" and s.levelReq then
      if s.levelReq <= level then
        out.trainable = out.trainable + 1
        out.cost = out.cost + (s.cost or 0)
      elseif not out.nextLevel or s.levelReq < out.nextLevel then
        out.nextLevel = s.levelReq
      end
    end
  end
  for _, s in ipairs(cs.services) do
    if s.type ~= "used" and s.levelReq == out.nextLevel then out.nextCount = out.nextCount + 1 end
  end
  return out
end

function Trainers.SummaryText()
  local s = Trainers.SpellSummary()
  if not s then return "Visit any trainer for your class once to see which spells you can learn." end
  local parts = {}
  if s.trainable > 0 then
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
  return table.concat(parts, " · ")
end

function Trainers.EmptyText()
  local className = UnitClass("player")
  return string.format("No %s trainers known yet. Talk to one once and Wayfinder remembers where "
    .. "they are, or install QuestieDB. City guards can point you to one.", className:lower())
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
-- their positions were measured in Forever), then QuestieDB's.
local function collect(kind, fits, questie)
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
  for _, t in ipairs(questie) do
    if not seen[t.id] then trainers[#trainers + 1] = { id = t.id, name = t.name, node = t.node } end
  end
  return trainers
end

-- Results: { title, zone, goal (route node), route, details } sorted by travel time.
-- Sources: trainers you visited, Data/Seed.lua, and QuestieDB when installed.
function Trainers.Results()
  local className, class = UnitClass("player")
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local trainers = collect("classTrainer", function(npc) return npc.class == class end,
    ns.Questie.ClassTrainers(class, UnitFactionGroup("player"), start))
  return results(trainers, (className or class):lower() .. " trainers", start, net), nil, net
end

---------------------------------------------------------------- weapon masters

function WeaponMasters.SummaryText()
  return "Weapon masters teach weapon skills. Visit one to see which weapons they teach."
end

function WeaponMasters.EmptyText()
  return "No weapon masters known yet. Talk to one once and Wayfinder remembers where they are, "
    .. "or install QuestieDB."
end

function WeaponMasters.Results()
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local trainers = collect("weaponMaster", nil, ns.Questie.WeaponMasters(UnitFactionGroup("player"), start))
  return results(trainers, "weapon masters", start, net), nil, net
end
