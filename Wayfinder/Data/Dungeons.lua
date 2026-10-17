local _, ns = ...

-- Dungeon and raid entrances. The client has none (C_EncounterJournal and
-- C_Map.GetMapLinksForMap are empty in Forever), so these are hand-made and
-- used when QuestieDB is not installed or doesn't know a dungeon.
--
-- Coordinates are APPROXIMATE: vanilla (Era) positions from memory, rounded
-- to whole map percent, on the outdoor zone map, not checked in Forever.
-- Forever moved the Stormwind City and Eastern Plaguelands maps (also Mulgore
-- and Redridge), so the Stockade, Stratholme and Naxxramas points are likely
-- off there; with QuestieDB installed they are converted with its EraToForever
-- helper. To fix one: stand at the entrance, run /wf where, update x/y and set
-- verified = true.
--
-- `level` is a fallback; the client's dungeon finder list (GetLFGDungeonInfo)
-- overrides it, matched by name or `aliases`. `faction` lists a dungeon only
-- for the faction whose capital it's in. `areaID` links QuestieDB entrances
-- and dungeon quests.

ns.data.dungeons = {
  { areaID = 2437, name = "Ragefire Chasm", level = 15, faction = "Horde", verified = false,
    entrances = { { mapID = 1454, x = 0.52, y = 0.49 } } },
  { areaID = 718, name = "Wailing Caverns", level = 17, verified = false,
    entrances = { { mapID = 1413, x = 0.46, y = 0.36 } } },
  { areaID = 1581, name = "The Deadmines", level = 16, verified = false,
    entrances = { { mapID = 1436, x = 0.42, y = 0.72 } } },
  { areaID = 209, name = "Shadowfang Keep", level = 22, verified = false,
    entrances = { { mapID = 1421, x = 0.45, y = 0.68 } } },
  { areaID = 719, name = "Blackfathom Deeps", level = 24, verified = false,
    entrances = { { mapID = 1440, x = 0.14, y = 0.14 } } },
  { areaID = 717, name = "The Stockade", aliases = { "Stormwind Stockade" }, level = 24, faction = "Alliance",
    verified = false, entrances = { { mapID = 1453, x = 0.42, y = 0.59 } } },
  { areaID = 721, name = "Gnomeregan", level = 29, verified = false,
    entrances = { { mapID = 1426, x = 0.24, y = 0.40 } } },
  { areaID = 491, name = "Razorfen Kraul", level = 30, verified = false,
    entrances = { { mapID = 1413, x = 0.43, y = 0.90 } } },
  { areaID = 796, name = "Scarlet Monastery", level = 33, verified = false,
    entrances = { { mapID = 1420, x = 0.83, y = 0.34 } } },
  { areaID = 722, name = "Razorfen Downs", level = 37, verified = false,
    entrances = { { mapID = 1413, x = 0.49, y = 0.94 } } },
  { areaID = 1337, name = "Uldaman", level = 42, verified = false,
    entrances = { { mapID = 1418, x = 0.44, y = 0.12, label = "Uldaman (north entrance)" },
      { mapID = 1418, x = 0.65, y = 0.43, label = "Uldaman (east entrance)" } } },
  { areaID = 1176, name = "Zul'Farrak", level = 46, verified = false,
    entrances = { { mapID = 1446, x = 0.39, y = 0.20 } } },
  { areaID = 2100, name = "Maraudon", level = 46, verified = false,
    entrances = { { mapID = 1443, x = 0.29, y = 0.62 } } },
  { areaID = 1477, name = "The Temple of Atal'Hakkar", aliases = { "Sunken Temple" }, level = 50, verified = false,
    entrances = { { mapID = 1435, x = 0.70, y = 0.54 } } },
  { areaID = 1584, name = "Blackrock Depths", level = 52, verified = false,
    entrances = { { mapID = 1427, x = 0.35, y = 0.84, label = "Blackrock Mountain (Searing Gorge)" },
      { mapID = 1428, x = 0.29, y = 0.38, label = "Blackrock Mountain (Burning Steppes)" } } },
  { areaID = 1583, name = "Blackrock Spire", aliases = { "Lower Blackrock Spire", "Upper Blackrock Spire" },
    level = 56, verified = false,
    entrances = { { mapID = 1427, x = 0.35, y = 0.84, label = "Blackrock Mountain (Searing Gorge)" },
      { mapID = 1428, x = 0.29, y = 0.38, label = "Blackrock Mountain (Burning Steppes)" } } },
  -- The outer approach; the wing doors are further north.
  { areaID = 2557, name = "Dire Maul", level = 56, verified = false,
    entrances = { { mapID = 1444, x = 0.59, y = 0.45 } } },
  { areaID = 2057, name = "Scholomance", level = 57, verified = false,
    entrances = { { mapID = 1422, x = 0.70, y = 0.73 } } },
  { areaID = 2017, name = "Stratholme", level = 58, verified = false,
    entrances = { { mapID = 1423, x = 0.31, y = 0.16 } } },

  { areaID = 2717, name = "Molten Core", level = 60, raid = true, verified = false,
    entrances = { { mapID = 1427, x = 0.35, y = 0.84, label = "Blackrock Mountain (Searing Gorge)" },
      { mapID = 1428, x = 0.29, y = 0.38, label = "Blackrock Mountain (Burning Steppes)" } } },
  { areaID = 2159, name = "Onyxia's Lair", level = 60, raid = true, verified = false,
    entrances = { { mapID = 1445, x = 0.53, y = 0.77 } } },
  { areaID = 2677, name = "Blackwing Lair", level = 60, raid = true, verified = false,
    entrances = { { mapID = 1427, x = 0.35, y = 0.84, label = "Blackrock Mountain (Searing Gorge)" },
      { mapID = 1428, x = 0.29, y = 0.38, label = "Blackrock Mountain (Burning Steppes)" } } },
  { areaID = 1977, name = "Zul'Gurub", level = 60, raid = true, verified = false,
    entrances = { { mapID = 1434, x = 0.54, y = 0.17 } } },
  { areaID = 3429, name = "Ruins of Ahn'Qiraj", level = 60, raid = true, verified = false,
    entrances = { { mapID = 1451, x = 0.29, y = 0.92 } } },
  { areaID = 3428, name = "Temple of Ahn'Qiraj", aliases = { "Ahn'Qiraj Temple" }, level = 60, raid = true,
    verified = false, entrances = { { mapID = 1451, x = 0.29, y = 0.92 } } },
  { areaID = 3456, name = "Naxxramas", level = 60, raid = true, verified = false,
    entrances = { { mapID = 1423, x = 0.40, y = 0.26 } } },
}
