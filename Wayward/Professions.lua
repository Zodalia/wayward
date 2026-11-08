local _, ns = ...

-- Professions: which you have and how far along (skill / cap), the next rank
-- you can train (Journeyman at 50 skill and level 10, Expert at 125 and 20,
-- Artisan at 200 and 35: the classic rules), and the trainers for them, from
-- your visits and the data sources (English subtitles: "Tailoring Trainer",
-- "Expert Tailor"...), or the vendors selling the book for a rank no trainer
-- teaches (Expert Fishing...). Trainers > Professions lists them; For you
-- shows a card when you can train the next rank.

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
    if next(out) or not (GetNumSkillLines and GetSkillLineInfo) then return out end
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

-- Ranks that come from a quest instead (the classic rules): Artisan Cooking,
-- First Aid and Fishing. Its giver teaches the rank once you hand it in, and
-- it asks for QUEST_SKILL (the Expert cap), not the 200 a trainer would.
-- Quest IDs by your faction ("any": either).
local QUEST_SKILL = 225
local QUESTS = {
  Cooking = { Artisan = { any = 6610 } }, -- Clamlette Surprise: Dirge Quikcleave, Gadgetzan
  ["First Aid"] = { Artisan = { Alliance = 6624, Horde = 6622 } }, -- Triage: Theramore, Hammerfall
  Fishing = { Artisan = { any = 6607 } }, -- Nat Pagle, Angler Extreme: Dustwallow Marsh
}

-- The quest that leads to a rank (its ID, for your faction), or nil when a
-- trainer or a book teaches it.
function Professions.Quest(profession, rank)
  local q = QUESTS[profession] and QUESTS[profession][rank]
  return q and (q[UnitFactionGroup("player")] or q.any) or nil
end

-- The next rank you could train in a profession you have: the rank, and
-- whether you can now ("ready") or what's missing ("skill" or "level").
-- `profession`: its name, for the ranks that ask for more skill (a quest's).
function Professions.NextRank(have, profession)
  for _, r in ipairs(RANKS) do
    if r.cap > (have.cap or 0) then
      local skill = profession and Professions.Quest(profession, r.name) and QUEST_SKILL or r.skill
      if UnitLevel("player") < r.level then return r, "level" end
      if (have.rank or 0) < skill then return r, "skill", skill end
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

-- Ranks no trainer teaches: in the classic rules Expert Cooking, First Aid
-- and Fishing come from a book you buy and read. The item, with its English
-- name until the client has it cached.
local BOOKS = {
  Cooking = { Expert = { id = 16072, name = "Expert Cookbook" } },
  ["First Aid"] = { Expert = { id = 16084, name = "Expert First Aid - Under Wraps" } },
  Fishing = { Expert = { id = 16083, name = "Expert Fishing - The Bass and You" } },
}

-- The book that teaches a rank ({id, name}), or nil when a trainer does.
function Professions.Book(profession, rank)
  local book = BOOKS[profession] and BOOKS[profession][rank]
  if not book then return nil end
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(book.id)
  if not name and GetItemInfo then name = GetItemInfo(book.id) end
  return { id = book.id, name = name or book.name }
end

-- Where to learn a rank: the nearest trainer for it; for a rank that comes
-- from a book, the nearest vendor selling the book ({id, name, node, book});
-- for one that comes from a quest, its giver, who teaches it once you hand
-- it in ({name, node, quest = {id, name, done}}). Returns it, the route, and
-- whether it's known to teach the rank; nil when nobody known does.
function Professions.WhereToLearn(profession, rank, start, net)
  local questID = rank and Professions.Quest(profession, rank)
  if questID then
    local giver, node = ns.Quests.QuestGiver(questID, start)
    local route = node and ns.Router.Plan(start, node, net)
    if not route then return nil end
    local q = ns.Quests.Quest(questID)
    local done = ns.Quests.PlayerQuestState()
    return { name = giver, node = node, quest = { id = questID, name = q and q.name or ("quest " .. questID),
      done = done[questID] == true } }, route, true
  end
  local book = rank and Professions.Book(profession, rank)
  if not book then return Professions.NearestTrainer(profession, rank, start, net) end
  local name, node, id = ns.Vendors.NearestSeller(book.id, start)
  local route = node and ns.Router.Plan(start, node, net)
  if not route then return nil end
  return { id = id, name = name, node = node, book = book }, route, true
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
  return "No profession trainers known yet. Talk to one once and Wayward remembers where they are, or install " .. ns.Data.ADDON .. "."
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
      local rank, state, needSkill
      if have then rank, state, needSkill = Professions.NextRank(have, p.name) end
      local book = rank and Professions.Book(p.name, rank.name)
      local questID = rank and Professions.Quest(p.name, rank.name)
      local trainer, route, sure = Professions.WhereToLearn(p.name, rank and rank.name or "Apprentice", start, net)
      local what
      if not have then
        what = "learn it"
      elseif not rank then
        what = string.format("%d/%d, nothing more to train", have.rank, have.cap)
      elseif state == "ready" then
        what = string.format("%d/%d: |cff7fd1ae%s %s now|r", have.rank, have.cap,
          (book or questID) and "learn" or "train", rank.name)
      elseif state == "skill" then
        what = string.format("%d/%d: %s at %d skill", have.rank, have.cap, rank.name, needSkill or rank.skill)
      else
        what = string.format("%d/%d: %s at level %d", have.rank, have.cap, rank.name, rank.level)
      end
      if trainer then trainer.node.npc = trainer.name end
      rows[#rows + 1] = {
        id = "profession" .. p.name, kind = "profession", icon = p.icon,
        title = trainer and string.format("%s  |cff9d9d9d(%s)|r", have and p.name or ("Learn " .. p.name), trainer.name)
          or (have and p.name or ("Learn " .. p.name)),
        subtitle = string.format("%s  ·  %s%s", trainer and ns.MapName(trainer.node.mapID)
          or (book and "no seller known yet") or (questID and "no quest giver known yet")
          or "no trainer known yet", what,
          route and ("  ·  " .. ns.FormatDuration(route.seconds)) or ""),
        goal = trainer and trainer.node, route = route,
        details = book and { { text = string.format("%s comes from a book, not a trainer: %s%s.", rank.name, book.name,
            trainer and (", sold by " .. trainer.name) or "; Wayward finds who sells it when you visit them, or install "
            .. ns.Data.ADDON) } }
          or questID and { { text = not trainer
            and string.format("%s comes from a quest, not a trainer; Wayward finds it with %s.", rank.name, ns.Data.ADDON)
            or trainer.quest.done and string.format("%s comes from a quest, not a trainer: you did %s, so %s teaches it now.",
              rank.name, trainer.quest.name, trainer.name)
            or string.format("%s comes from a quest, not a trainer: %s, from %s, who teaches it once you hand it in.",
              rank.name, trainer.quest.name, trainer.name) } }
          or rank and trainer and not sure and { { text = "Not every trainer teaches " .. rank.name
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
  for _, row in ipairs(rows) do ns.Search.WithDetour(row) end
  return rows, nil, net
end
