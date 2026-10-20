local _, ns = ...

-- Professions: which you have and how far along (skill / cap), the next rank
-- you can train (Journeyman at 50 skill and level 10, Expert at 125 and 20,
-- Artisan at 200 and 35: the classic rules), and the trainers for them, from
-- your visits and the data sources (English subtitles: "Tailoring Trainer",
-- "Expert Tailor"...). Trainers > Professions lists them; For you shows a card
-- when you can train the next rank.

local Professions = { id = "professionTrainer", label = "Professions" }
ns.Professions = Professions

-- name, the trainer subtitle noun, primary or secondary, icon
local LIST = {
  { name = "Alchemy", noun = "Alchemist", primary = true, icon = "Interface\\Icons\\Trade_Alchemy" },
  { name = "Blacksmithing", noun = "Blacksmith", primary = true, icon = "Interface\\Icons\\Trade_BlackSmithing" },
  { name = "Enchanting", noun = "Enchanter", primary = true, icon = "Interface\\Icons\\Trade_Engraving" },
  { name = "Engineering", noun = "Engineer", primary = true, icon = "Interface\\Icons\\Trade_Engineering" },
  { name = "Herbalism", noun = "Herbalist", primary = true, icon = "Interface\\Icons\\Trade_Herbalism" },
  { name = "Leatherworking", noun = "Leatherworker", primary = true, icon = "Interface\\Icons\\INV_Misc_ArmorKit_17" },
  { name = "Mining", noun = "Miner", primary = true, icon = "Interface\\Icons\\Trade_Mining" },
  { name = "Skinning", noun = "Skinner", primary = true, icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
  { name = "Tailoring", noun = "Tailor", primary = true, icon = "Interface\\Icons\\Trade_Tailoring" },
  { name = "Cooking", noun = "Cook", icon = "Interface\\Icons\\INV_Misc_Food_15" },
  { name = "First Aid", noun = "Physician", icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
  { name = "Fishing", noun = "Fisherman", icon = "Interface\\Icons\\Trade_Fishing" },
}
Professions.LIST = LIST
local BY_NAME = {}
for _, p in ipairs(LIST) do BY_NAME[p.name] = p end
Professions.BY_NAME = BY_NAME

-- Ranks: the skill cap each gives, and what you need to learn it.
local RANKS = {
  { name = "Apprentice", cap = 75, level = 5, skill = 0 },
  { name = "Journeyman", cap = 150, level = 10, skill = 50 },
  { name = "Expert", cap = 225, level = 20, skill = 125 },
  { name = "Artisan", cap = 300, level = 35, skill = 200 },
}
Professions.RANKS = RANKS
local MAX_PRIMARY = 2

-- The profession a trainer subtitle is for, and the rank it names if any
-- ("Expert Tailor": Tailoring, Expert), or nil.
function Professions.FromSubtitle(subName)
  if type(subName) ~= "string" or subName == "" then return nil end
  for _, p in ipairs(LIST) do
    if subName == p.name .. " Trainer" then return p.name end
    for _, r in ipairs(RANKS) do
      if subName == r.name .. " " .. p.noun then return p.name, r.name end
    end
    if subName == "Master " .. p.noun then return p.name, "Artisan" end
  end
  return nil
end

-- The profession a trainer's services are for (from a visit), or nil.
function Professions.FromServices(services)
  for _, s in ipairs(services) do
    if s.skillLine and BY_NAME[s.skillLine] then return s.skillLine end
    for _, r in ipairs(RANKS) do
      local name = type(s.name) == "string" and s.name:match("^" .. r.name .. " (.+)$")
      if name and BY_NAME[name] then return name end
    end
  end
  return nil
end

-- Your professions: { [name] = {rank, cap} }, or nil when this client can't say.
function Professions.Mine()
  local out = {}
  if GetProfessions and GetProfessionInfo then
    local indexes = { GetProfessions() }
    for i = 1, 6 do
      local index = indexes[i]
      if index then
        local name, _, rank, cap = GetProfessionInfo(index)
        if name and BY_NAME[name] then out[name] = { rank = rank or 0, cap = cap or 0 } end
      end
    end
    return out
  end
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, header, _, rank, _, _, cap = GetSkillLineInfo(i)
      if not header and BY_NAME[name] then out[name] = { rank = rank or 0, cap = cap or 0 } end
    end
    return out
  end
  return nil
end

-- The next rank you could train in a profession you have: the rank, and
-- whether you can now ("ready") or what's missing ("skill" or "level").
function Professions.NextRank(have)
  for _, r in ipairs(RANKS) do
    if r.cap > (have.cap or 0) then
      if UnitLevel("player") < r.level then return r, "level" end
      if (have.rank or 0) < r.skill then return r, "skill" end
      return r, "ready"
    end
  end
  return nil
end

-- Known trainers for a profession: { {id, name, node, rank?} }, visited ones first.
local function trainersFor(profession, start)
  local faction = UnitFactionGroup("player")
  local out, seen = {}, {}
  for id, npc in pairs(ns.Harvest.AllNPCs()) do
    if npc.kinds and npc.kinds.professionTrainer and npc.profession == profession
      and (npc.faction == nil or npc.faction == faction) then
      local node = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.name)
      if node then
        seen[id] = true
        out[#out + 1] = { id = id, name = npc.name, node = node, ranks = npc.ranks }
      end
    end
  end
  for _, t in ipairs(ns.Data.NearestOfKind("professionTrainer", faction, start,
    function(t) return t.profession == profession end)) do
    if not seen[t.id] then out[#out + 1] = t end
  end
  return out
end

-- Can this trainer teach `rank`? true / false, or nil when not known.
local function teaches(t, rank)
  if t.ranks then
    for _, r in ipairs(t.ranks) do
      if r == rank then return true end
    end
    return false
  end
  if t.rank then
    -- A subtitle names the highest rank they teach.
    for i, r in ipairs(RANKS) do
      if r.name == t.rank then
        for j, want in ipairs(RANKS) do
          if want.name == rank then return j <= i end
        end
      end
    end
  end
  return nil
end

-- The nearest trainer for a profession (who can teach `rank`, when known):
-- trainer, route; one known to teach it beats one that might.
function Professions.NearestTrainer(profession, rank, start, net)
  local best, bestRoute, bestSure
  for _, t in ipairs(trainersFor(profession, start)) do
    local can = rank and teaches(t, rank)
    if can ~= false then
      local route = ns.Router.Plan(start, t.node, net)
      local sure = can == true
      if route and (not best or (sure and not bestSure) or (sure == bestSure and route.seconds < bestRoute.seconds)) then
        best, bestRoute, bestSure = t, route, sure
      end
    end
  end
  return best, bestRoute, bestSure
end

---------------------------------------------------------------- the Professions tab

function Professions.SummaryText()
  local mine = Professions.Mine()
  if not mine then return "Profession trainers. This client doesn't say which professions you have." end
  local parts = {}
  for _, p in ipairs(LIST) do
    local have = mine[p.name]
    if have then parts[#parts + 1] = string.format("%s %d/%d", p.name, have.rank, have.cap) end
  end
  return #parts > 0 and ("Your professions: " .. table.concat(parts, ", ") .. ".") or "You have no professions yet."
end

function Professions.EmptyText()
  return "No profession trainers known yet. Talk to one once and Wayward remembers where they are, or install a Wayward data addon."
end

-- Your professions first (the next rank, and where to train it), then the
-- ones you could still learn (up to two primary professions, and the
-- secondary ones).
function Professions.Results()
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local mine = Professions.Mine() or {}
  local primaries = 0
  for name in pairs(mine) do
    if BY_NAME[name].primary then primaries = primaries + 1 end
  end
  local rows = {}
  for _, p in ipairs(LIST) do
    local have = mine[p.name]
    if have or not p.primary or primaries < MAX_PRIMARY then
      local rank, state
      if have then rank, state = Professions.NextRank(have) end
      local trainer, route, sure = Professions.NearestTrainer(p.name, rank and rank.name or "Apprentice", start, net)
      local what
      if not have then
        what = "learn it"
      elseif not rank then
        what = string.format("%d/%d, nothing more to train", have.rank, have.cap)
      elseif state == "ready" then
        what = string.format("%d/%d: |cff7fd1aetrain %s now|r", have.rank, have.cap, rank.name)
      elseif state == "skill" then
        what = string.format("%d/%d: %s at %d skill", have.rank, have.cap, rank.name, rank.skill)
      else
        what = string.format("%d/%d: %s at level %d", have.rank, have.cap, rank.name, rank.level)
      end
      if trainer then trainer.node.npc = trainer.name end
      rows[#rows + 1] = {
        id = "profession" .. p.name, kind = "profession", icon = p.icon,
        title = trainer and string.format("%s  |cff9d9d9d(%s)|r", have and p.name or ("Learn " .. p.name), trainer.name)
          or (have and p.name or ("Learn " .. p.name)),
        subtitle = string.format("%s  ·  %s%s", trainer and ns.MapName(trainer.node.mapID) or "no trainer known yet", what,
          route and ("  ·  " .. ns.FormatDuration(route.seconds)) or ""),
        goal = trainer and trainer.node, route = route,
        details = rank and trainer and not sure and { { text = "Not every trainer teaches " .. rank.name
          .. "; Wayward learns who does when you visit." } } or nil,
        order = (have and state == "ready") and 0 or have and 1 or 2,
        seconds = route and route.seconds or math.huge,
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.seconds < b.seconds
  end)
  return rows, nil, net
end
