local _, ns = ...

-- Why a quest is worth doing beyond its XP, so "am I missing something cool
-- nearby?" has an answer. From the quest data (Sources.lua): its QuestSort (a
-- negative zoneOrSort: class, legendary, profession, holiday...), its flags,
-- the items it rewards (the item records' questRewards), reputation, and
-- where its chain leads. From the client: item quality and equip slot, only
-- when it already has the item (never waited for).
--
--   Quests.QuestSort(questID)    name, detail: "class", "WARLOCK"; "legendary"; "epic";
--                                "profession:Blacksmithing", "Blacksmithing"; "holiday", "Darkmoon Faire"; ...
--   Quests.RewardItems(questID)  { {itemID, name, class, subClass, requiredLevel, itemLevel}, ... }
--   Quests.Notable(questID)      { {kind, text, weight, tag}, ... }, heaviest first
--   Quests.NotableTag(questID)   a short tag ("Class quest") when a reason is strong enough, else nil
--
-- Kept conservative: a reason is something you would be sorry to miss, said in
-- plain words. Common things (reputation with your own cities, white rewards,
-- armour your class doesn't wear) don't count.

local Quests = ns.Quests
local Data = ns.Data

local STRONG = 2               -- a reason this heavy tags the quest
local FOREVER_QUEST_IDS = 90000 -- Forever's own quests; Era's IDs stop well below
local CHAIN_DEPTH = 5          -- follow-ups looked at for a dungeon or epic further on
local EPIC_FLAG = 32
local MIN_QUALITY = 2          -- uncommon (green): white and grey rewards aren't worth a mention
local RARE_QUALITY = 3
local HEAVY_ARMOUR_LEVEL = 40  -- warriors and paladins wear plate, hunters and shamans mail, from here

---------------------------------------------------------------- quest sorts

-- QuestieDB's sortKeys (a negative zoneOrSort).
local CLASS_SORTS = { [-61] = "WARLOCK", [-81] = "WARRIOR", [-82] = "SHAMAN", [-141] = "PALADIN", [-161] = "MAGE",
  [-162] = "ROGUE", [-261] = "HUNTER", [-262] = "PRIEST", [-263] = "DRUID", [-372] = "DEATHKNIGHT", [-395] = "MONK" }
local PROFESSION_SORTS = { [-24] = "Herbalism", [-101] = "Fishing", [-121] = "Blacksmithing", [-181] = "Alchemy",
  [-182] = "Leatherworking", [-201] = "Engineering", [-264] = "Tailoring", [-304] = "Cooking", [-324] = "First Aid",
  [-371] = "Inscription", [-373] = "Jewelcrafting", [-377] = "Archaeology", [-398] = "Riding" }
local HOLIDAY_SORTS = { [-21] = "Hallow's End", [-22] = "Seasonal", [-41] = "Day of the Dead",
  [-364] = "Darkmoon Faire", [-366] = "Lunar Festival", [-369] = "Midsummer", [-370] = "Brewfest",
  [-374] = "Noblegarden", [-375] = "Pilgrim's Bounty", [-376] = "Love is in the Air", [-378] = "Children's Week",
  [-402] = "Harvest Festival", [-404] = "Winter Veil" }
local OTHER_SORTS = { [-344] = { "legendary" }, [-1] = { "epic" }, [-367] = { "reputation" },
  [-284] = { "special" }, [-1000] = { "special" }, [-221] = { "treasure map" }, [-25] = { "battleground" },
  [-368] = { "event", "Invasion" }, [-365] = { "event", "Ahn'Qiraj War" }, [-241] = { "event", "Tournament" },
  [-666] = { "forever", "Camping" }, [-660] = { "forever", "The High Order" }, [-676] = { "forever", "Night Elf" } }

local function sortOf(q)
  local sort = q and tonumber(q.zoneOrSort)
  if not sort or sort >= 0 then return nil end
  if CLASS_SORTS[sort] then return "class", CLASS_SORTS[sort] end
  if PROFESSION_SORTS[sort] then return "profession:" .. PROFESSION_SORTS[sort], PROFESSION_SORTS[sort] end
  if HOLIDAY_SORTS[sort] then return "holiday", HOLIDAY_SORTS[sort] end
  local other = OTHER_SORTS[sort]
  if other then return other[1], other[2] end
  return "other", tostring(sort)
end

-- The quest's QuestSort as a name and a detail (see the top), or nil when its
-- zoneOrSort is a place (or unknown).
function Quests.QuestSort(questID)
  return sortOf(Quests.Quest(questID))
end

local function hasFlag(mask, flag)
  return type(mask) == "number" and math.floor(mask / flag) % 2 == 1
end

local function className(class)
  local names = LOCALIZED_CLASS_NAMES_MALE
  if names and names[class] then return names[class] end
  return class:sub(1, 1) .. class:sub(2):lower()
end

---------------------------------------------------------------- reward items

local WEAPON, ARMOUR = 2, 4
local rewardIndex -- [questID] = { itemID, ... }
local rewardCache = {} -- [questID] = { reward, ... }, built on the first ask per quest

local function itemInstant(itemID)
  local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not fn then return nil end
  local ok, _, _, _, equipLoc, _, classID, subClassID = pcall(fn, itemID)
  if not ok then return nil end
  return classID, subClassID, equipLoc
end

-- quest -> items: a source's own index when it has one (cheap), else every
-- item record's questRewards (a pass over all items, once).
local function buildRewards()
  local started = debugprofilestop and debugprofilestop() or 0
  rewardIndex = Data.QuestRewards()
  if not rewardIndex then
    rewardIndex = {}
    for _, itemID in ipairs(Data.ItemIDs()) do
      local item = Data.Item(itemID)
      for _, questID in ipairs(item and type(item.questRewards) == "table" and item.questRewards or {}) do
        rewardIndex[questID] = rewardIndex[questID] or {}
        table.insert(rewardIndex[questID], itemID)
      end
    end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.questRewards = (debugprofilestop and debugprofilestop() or 0) - started
end

-- The items a quest rewards (choices included), from the data. The index is
-- built on the first ask and kept until the sources change. Read-only.
function Quests.RewardItems(questID)
  if rewardCache[questID] then return rewardCache[questID] end
  if not (Data.Has("ItemIDs") or Data.Has("QuestRewards")) then return {} end
  if not rewardIndex then buildRewards() end
  local out = {}
  for _, itemID in ipairs(rewardIndex[questID] or {}) do
    local item = Data.Item(itemID)
    if item then
      out[#out + 1] = { itemID = itemID, name = item.name, class = item.class, subClass = item.subClass,
        requiredLevel = item.requiredLevel, itemLevel = item.itemLevel }
    end
  end
  rewardCache[questID] = out
  return out
end

---------------------------------------------------------------- usable by your class

-- Weapon subclasses each class can learn (the classic weapon skills).
local WEAPONS = {
  [0] = "WARRIOR PALADIN HUNTER SHAMAN",                         -- one-handed axes
  [1] = "WARRIOR PALADIN HUNTER SHAMAN",                         -- two-handed axes
  [2] = "WARRIOR HUNTER ROGUE",                                  -- bows
  [3] = "WARRIOR HUNTER ROGUE",                                  -- guns
  [4] = "WARRIOR PALADIN ROGUE PRIEST SHAMAN DRUID",             -- one-handed maces
  [5] = "WARRIOR PALADIN SHAMAN DRUID",                          -- two-handed maces
  [6] = "WARRIOR PALADIN HUNTER",                                -- polearms
  [7] = "WARRIOR PALADIN HUNTER ROGUE MAGE WARLOCK",             -- one-handed swords
  [8] = "WARRIOR PALADIN HUNTER",                                -- two-handed swords
  [10] = "WARRIOR HUNTER PRIEST SHAMAN MAGE WARLOCK DRUID",      -- staves
  [13] = "WARRIOR HUNTER ROGUE SHAMAN DRUID",                    -- fist weapons
  [15] = "WARRIOR HUNTER ROGUE PRIEST SHAMAN MAGE WARLOCK DRUID", -- daggers
  [16] = "WARRIOR HUNTER ROGUE",                                 -- thrown
  [18] = "WARRIOR HUNTER ROGUE",                                 -- crossbows
  [19] = "PRIEST MAGE WARLOCK",                                  -- wands
}
-- Shields, librams, idols, totems.
local ARMOUR_EXTRAS = { [6] = "WARRIOR PALADIN SHAMAN", [7] = "PALADIN", [8] = "DRUID", [9] = "SHAMAN" }
-- Rings, necks, trinkets and cloaks suit anyone; off-hand frills, casters.
local ANYONE_SLOTS = { INVTYPE_FINGER = true, INVTYPE_NECK = true, INVTYPE_TRINKET = true, INVTYPE_CLOAK = true }
local CASTERS = "PRIEST MAGE WARLOCK DRUID SHAMAN PALADIN"

-- The armour a class wants at a level (1 cloth, 2 leather, 3 mail, 4 plate):
-- only its heaviest counts, so a warrior isn't sent after a cloth robe.
local function armourFor(class, level)
  if class == "WARRIOR" or class == "PALADIN" then return level >= HEAVY_ARMOUR_LEVEL and 4 or 3 end
  if class == "HUNTER" or class == "SHAMAN" then return level >= HEAVY_ARMOUR_LEVEL and 3 or 2 end
  if class == "ROGUE" or class == "DRUID" then return 2 end
  return 1
end

local function listed(list, class)
  return list ~= nil and (" " .. list .. " "):find(" " .. class .. " ", 1, true) ~= nil
end

-- Would this class equip the item (at the level it can wear it)?
function Quests.UsableBy(reward, class, level)
  local itemClass, subClass = reward.class, reward.subClass
  local instantClass, instantSub, equipLoc = itemInstant(reward.itemID)
  itemClass, subClass = itemClass or instantClass, subClass or instantSub
  if itemClass == WEAPON then return listed(WEAPONS[subClass], class) end
  if itemClass ~= ARMOUR then return false end
  if equipLoc and ANYONE_SLOTS[equipLoc] then return true end
  if equipLoc == "INVTYPE_HOLDABLE" then return listed(CASTERS, class) end
  if ARMOUR_EXTRAS[subClass] then return listed(ARMOUR_EXTRAS[subClass], class) end
  if subClass and subClass >= 1 and subClass <= 4 then
    return subClass == armourFor(class, math.max(level, reward.requiredLevel or 0))
  end
  return false -- misc armour without a known slot: shirts and tabards too
end

-- The client's quality for an item it has cached, else nil: never waited
-- for, but asked for once, so a later look (GET_ITEM_INFO_RECEIVED) knows.
local requested = {}

local function quality(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local ok, name, _, q = pcall(getInfo, itemID)
  if ok and type(name) == "string" and type(q) == "number" then return q end
  if not requested[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
    requested[itemID] = true
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end
  return nil
end

---------------------------------------------------------------- reasons

-- Reputation everyone gets from their own side's quests doesn't count.
local HOME_FACTIONS = { [72] = true, [47] = true, [54] = true, [69] = true, [930] = true, [469] = true,
  [76] = true, [68] = true, [81] = true, [530] = true, [911] = true, [67] = true }

local function factionName(id)
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, data = pcall(C_Reputation.GetFactionDataByID, id)
    if ok and type(data) == "table" and data.name then return data.name end
  end
  if GetFactionInfoByID then
    local ok, name = pcall(GetFactionInfoByID, id)
    if ok and type(name) == "string" then return name end
  end
  return nil
end

local oldNames -- names of quests below FOREVER_QUEST_IDS, built on the first ask

local function foreverOnly(q)
  if q.id < FOREVER_QUEST_IDS then return false end
  if not oldNames then
    oldNames = {}
    for _, id in ipairs(Data.QuestIDs()) do
      if id < FOREVER_QUEST_IDS then
        local other = Quests.Quest(id)
        if other and other.name then oldNames[other.name] = true end
      end
    end
  end
  return not oldNames[q.name]
end

local function forYou(q, p)
  if q.races and not q.races[p.raceID] then return false end
  if q.classes and not q.classes[p.class] then return false end
  return true
end

local function epicSort(q)
  local sort = sortOf(q)
  return sort == "legendary" or sort == "epic" or hasFlag(q.questFlags, EPIC_FLAG), sort == "legendary"
end

-- The dungeon a quest is done in, or nil. Dungeons.lua caches the dungeon
-- finder list on first use, so not before the API exists.
local function dungeonOf(q)
  local area = Quests.QuestArea(q)
  if not area or type(GetLFGDungeonInfo) ~= "function" or not ns.Dungeons then return nil end
  return ns.Dungeons.ForArea(area)
end

-- Where the chain goes from `q` (breadth first, CHAIN_DEPTH steps, quests you
-- could ever do): the first quest in a dungeon other than q's own, and the
-- first epic or legendary one.
local function chainLeads(q, p)
  local own = dungeonOf(q)
  local dungeonStep, dungeon, epicStep, legendary
  local seen, frontier = { [q.id] = true }, { q }
  for _ = 1, CHAIN_DEPTH do
    local nextFrontier = {}
    for _, at in ipairs(frontier) do
      for _, after in ipairs(Quests.After(at.id)) do
        if not seen[after.id] and forYou(after, p) then
          seen[after.id] = true
          nextFrontier[#nextFrontier + 1] = after
          local d = not dungeonStep and dungeonOf(after)
          if d and d ~= own then dungeonStep, dungeon = after, d end
          local epic, isLegendary = epicSort(after)
          if epic and not epicStep then epicStep, legendary = after, isLegendary end
        end
      end
    end
    if (dungeonStep and epicStep) or #nextFrontier == 0 then break end
    frontier = nextFrontier
  end
  return dungeonStep, dungeon, epicStep, legendary
end

local function profile()
  local _, class = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  return { class = class, raceID = raceID, level = UnitLevel("player") or 1 }
end

local function reasonsFor(q, p)
  local out = {}
  local function add(kind, weight, tag, text) out[#out + 1] = { kind = kind, weight = weight, tag = tag, text = text } end

  local sort, detail = sortOf(q)
  local onlyClass
  if sort == "class" then onlyClass = detail end
  if not onlyClass and q.classes then
    local n, last = 0, nil
    for class in pairs(q.classes) do n, last = n + 1, class end
    if n == 1 then onlyClass = last end
  end
  if sort == "legendary" then
    add("legendary", 5, "Legendary", "Legendary quest line: among the rarest and best rewarded in the game.")
  elseif sort == "epic" or hasFlag(q.questFlags, EPIC_FLAG) then
    add("epic", 4, "Epic", "Epic quest line: a long chain with a big reward at the end.")
  end
  -- Only your own class's: another class's quest is closed to you anyway.
  if onlyClass and onlyClass == p.class then
    local name = className(onlyClass)
    add("class", 3, "Class quest", string.format("Class quest (%s): only %ss get it, often for a class reward or spell.",
      name, name:lower()))
  end

  -- Rewards your class would wear or wield. White and grey ones don't count;
  -- one whose quality the client doesn't know yet is only mentioned. A
  -- green weapon tags the quest; armour needs to be blue.
  local usable, best = 0, nil
  for _, reward in ipairs(Quests.RewardItems(q.id)) do
    local qual = quality(reward.itemID)
    if (not qual or qual >= MIN_QUALITY) and Quests.UsableBy(reward, p.class, p.level) then
      usable = usable + 1
      local weapon = (reward.class or itemInstant(reward.itemID)) == WEAPON
      local weight = 1
      if qual and qual >= RARE_QUALITY then weight = weapon and 3 or 2
      elseif qual and weapon then weight = 2 end
      if not best or weight > best.weight or (weight == best.weight and (reward.itemLevel or 0) > (best.reward.itemLevel or 0)) then
        best = { reward = reward, weight = weight, quality = qual }
      end
    end
  end
  if best then
    local reward = best.reward
    local rare = best.quality and best.quality >= RARE_QUALITY
    local level = (reward.requiredLevel or 0) > 0 and (", level " .. reward.requiredLevel) or ""
    local more = usable > 1 and string.format(" and %d more you can use", usable - 1) or ""
    add("reward", best.weight, "Reward for you", string.format("Rewards %s%s (your class can use it%s)%s.",
      reward.name or ("item " .. reward.itemID), rare and ", a rare item" or "", level, more))
    out[#out].itemID = reward.itemID
  end

  if foreverOnly(q) then
    add("forever", 2, "New in Forever", "Forever-only quest: new in WoW Forever, not in the original game.")
  end

  local dungeonStep, dungeon, epicStep, legendary = chainLeads(q, p)
  if dungeonStep then
    add("dungeon", 2, "Leads to a dungeon", string.format("Leads to a quest in %s (%s).", dungeon.name,
      dungeonStep.name or ("quest " .. dungeonStep.id)))
  end
  if epicStep and not (sort == "legendary" or sort == "epic" or hasFlag(q.questFlags, EPIC_FLAG)) then
    add("chain", 3, legendary and "Legendary chain" or "Epic chain", string.format("Starts the way to %s, part of %s quest line.",
      epicStep.name or ("quest " .. epicStep.id), legendary and "a legendary" or "an epic"))
  end

  if sort and sort:find("^profession:") then
    local mine = ns.Professions and ns.Professions.Mine and ns.Professions.Mine()
    local yours = mine and mine[detail]
    add("profession", yours and 2 or 1, yours and "Profession quest" or nil,
      string.format("%s quest%s.", detail, yours and ": for your profession" or ""))
  elseif sort == "holiday" then
    add("holiday", 1, nil, string.format("Holiday quest (%s): only while the event is on.", detail))
  end

  local factions = {}
  for _, rep in ipairs(type(q.reputationReward) == "table" and q.reputationReward or {}) do
    local id, value = rep[1], tonumber(rep[2])
    if id and not HOME_FACTIONS[id] and value and value > 0 then
      factions[#factions + 1] = factionName(id) or ("faction " .. id)
    end
  end
  if #factions > 0 then
    add("reputation", 1, nil, "Gives reputation with " .. table.concat(factions, " and ") .. ".")
  end

  -- Heaviest first; ties keep the order above.
  for i, r in ipairs(out) do r.order = i end
  table.sort(out, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    return a.order < b.order
  end)
  return out
end

local notableCache, cacheKey = {}, nil

-- Why the quest is worth doing beyond its XP, heaviest first:
-- { {kind, text, weight, tag, itemID?}, ... } (empty when nothing stands out;
-- itemID: the reward, on a "reward" reason). Kept per quest until your level,
-- the sources or the client's item cache change.
function Quests.Notable(questID)
  local q = Quests.Quest(questID)
  if not q then return {} end
  local p = profile()
  local key = tostring(p.class) .. ":" .. p.level
  if key ~= cacheKey then notableCache, cacheKey = {}, key end
  if not notableCache[questID] then
    local ok, reasons = pcall(reasonsFor, q, p)
    if not ok then geterrorhandler()(reasons) end
    notableCache[questID] = ok and reasons or {}
  end
  return notableCache[questID]
end

-- A short tag when the quest has a strong reason ("Class quest"), else nil;
-- and the reasons.
function Quests.NotableTag(questID)
  local reasons = Quests.Notable(questID)
  local top = reasons[1]
  if top and top.weight >= STRONG and top.tag then return top.tag, reasons end
  return nil, reasons
end

-- All reasons' weights added up: how much a quest stands out (0: not at all).
function Quests.NotableScore(questID)
  local score = 0
  for _, r in ipairs(Quests.Notable(questID)) do score = score + r.weight end
  return score
end

---------------------------------------------------------------- /ww debug quest

local FLAG_NAMES = { { 32, "epic" }, { 64, "raid" }, { 4096, "daily" }, { 32768, "weekly" }, { 2, "party accept" },
  { 8, "sharable" } }

-- Sort, flags, reward items and the reasons, for /ww debug quest.
function Quests.DescribeNotable(questID)
  local q = Quests.Quest(questID)
  if not q then return {} end
  local sort, detail = sortOf(q)
  local flags = {}
  for _, f in ipairs(FLAG_NAMES) do
    if hasFlag(q.questFlags, f[1]) then flags[#flags + 1] = f[2] end
  end
  if hasFlag(q.specialFlags, 1) then flags[#flags + 1] = "repeatable" end
  local p = profile()
  local rewards = {}
  for _, r in ipairs(Quests.RewardItems(questID)) do
    local qual = quality(r.itemID)
    rewards[#rewards + 1] = string.format("%s (%d; class %s/%s, level %s, ilvl %s, quality %s%s)", r.name or "?",
      r.itemID, tostring(r.class), tostring(r.subClass), tostring(r.requiredLevel), tostring(r.itemLevel),
      qual and tostring(qual) or "not cached", Quests.UsableBy(r, p.class, p.level) and ", yours" or "")
  end
  local lines = {
    string.format("  sort: %s  ·  zoneOrSort %s  ·  flags: %s", sort and (sort .. (detail and (" " .. detail) or "")) or "-",
      tostring(q.zoneOrSort), #flags > 0 and table.concat(flags, ", ") or "-"),
    "  rewards: " .. (#rewards > 0 and table.concat(rewards, "; ") or "-"),
  }
  local reasons = Quests.Notable(questID)
  if #reasons == 0 then lines[#lines + 1] = "  notable: nothing stands out" end
  for _, r in ipairs(reasons) do
    lines[#lines + 1] = string.format("  notable: [%s %d] %s", r.kind, r.weight, r.text)
  end
  return lines
end

-- Item info arrives for every item the client loads: only one we asked about matters.
ns.On("GET_ITEM_INFO_RECEIVED", function(itemID) if requested[itemID] then notableCache = {} end end)
ns.Listen("SOURCES_CHANGED", function()
  rewardIndex, rewardCache, oldNames, notableCache = nil, {}, nil, {}
end)
