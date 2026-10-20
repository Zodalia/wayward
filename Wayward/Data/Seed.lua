local _, ns = ...

-- NPCs shipped with the addon. Only entries confirmed in the Forever beta go
-- here; everything else is learned by talking to NPCs (Harvest.lua), and a
-- harvested entry replaces a seed entry with the same NPC ID.
--
-- Source of each entry: WFProbe beta report, 2026-10-17.

ns.data.seedNPCs = {
  [461] = { name = "Demisette Cloyce", kinds = { classTrainer = true }, class = "WARLOCK",
    faction = "Alliance", mapID = 1453, x = 0.3938, y = 0.8483 },
}
