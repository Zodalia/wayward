local _, ns = ...

-- "Class trainer" category: known trainers for your class, ranked by travel
-- time, plus what you could train right now.

local Trainers = { id = "classTrainer", label = "Class trainer" }
ns.Trainers = Trainers

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

-- Results: { title, subtitle, goal (route node), route } sorted by travel time.
function Trainers.Results()
  local _, class = UnitClass("player")
  local faction = UnitFactionGroup("player")
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()

  local results = {}
  for id, npc in pairs(ns.Harvest.AllNPCs()) do
    if npc.kinds.classTrainer and npc.class == class and (npc.faction == nil or npc.faction == faction) then
      local goal = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.name)
      local route = goal and ns.Router.Plan(start, goal, net)
      results[#results + 1] = {
        id = id,
        title = npc.name,
        zone = ns.MapName(npc.mapID),
        goal = goal,
        route = route,
      }
    end
  end
  table.sort(results, function(a, b)
    local ta = a.route and a.route.seconds or math.huge
    local tb = b.route and b.route.seconds or math.huge
    if ta ~= tb then return ta < tb end
    return a.title < b.title
  end)
  return results, nil, net
end
