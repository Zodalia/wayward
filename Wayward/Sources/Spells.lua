local _, ns = ...

-- Class trainer spells, what weapon masters teach and flight costs, from
-- Data/ClassSpells.lua (Forever client tables + WhatsTraining; see its
-- header for sources and licences).

local data = ns.data
if not data.classSpells then return end

local records = {} -- [CLASS] = Wayward class spell records, built on the first ask

local function classSpells(class)
  if records[class] then return records[class] end
  local out = {}
  for _, row in ipairs(data.classSpells[class] or {}) do
    local races
    if row[6] then
      races = {}
      for _, raceID in ipairs(row[6]) do races[raceID] = true end
    end
    out[#out + 1] = { spellID = row[1], level = row[2], cost = row[3], requires = row[4], talent = row[5],
      races = races, faction = row[7] }
  end
  records[class] = out
  return out
end

local function trainerSpells(npcID)
  local teaches = data.weaponMasters and data.weaponMasters[npcID]
  if not teaches then return nil end
  local out = {}
  for _, row in ipairs(teaches) do out[#out + 1] = { spellID = row[1], level = row[2], cost = row[3] } end
  return out
end

local function taxiCost(from, to)
  local paths = data.taxiCost and data.taxiCost[from]
  return paths and paths[to]
end

Wayward.RegisterSource({ id = "spells", label = "Class spells", priority = 30,
  ClassSpells = classSpells, TrainerSpells = trainerSpells, TaxiCost = taxiCost })
