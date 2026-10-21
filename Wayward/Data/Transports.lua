local _, ns = ...

-- Boats, zeppelins, the tram and portals. The client exposes none of these
-- (C_Map.GetMapLinksForMap is empty in Forever), so they are hand-made.
-- Era map IDs, used on Classic Era too; `forever = true` marks one only Forever has.
--
-- Coordinates are APPROXIMATE (vanilla knowledge, not yet checked in Forever).
-- To fix one: stand where you board, run /ww where, update x/y and set
-- verified = true. `time` is seconds including a typical wait.

ns.data.transports = {
  { kind = "boat", faction = "Alliance", time = 180, verified = false,
    a = { mapID = 1437, x = 0.049, y = 0.634, label = "Menethil Harbor" },
    b = { mapID = 1445, x = 0.716, y = 0.564, label = "Theramore Isle" } },
  { kind = "boat", faction = "Alliance", time = 180, verified = false,
    a = { mapID = 1437, x = 0.046, y = 0.571, label = "Menethil Harbor" },
    b = { mapID = 1439, x = 0.325, y = 0.438, label = "Auberdine" } },
  { kind = "boat", faction = "Alliance", time = 150, verified = false,
    a = { mapID = 1439, x = 0.330, y = 0.400, label = "Auberdine" },
    b = { mapID = 1438, x = 0.550, y = 0.970, label = "Rut'theran Village" } },
  -- New in Forever (forever: not on Classic Era). Recorded with /ww dock in the beta, 2026-10-17.
  { kind = "boat", faction = "Alliance", time = 130, verified = true, forever = true,
    a = { mapID = 1439, x = 0.307, y = 0.410, label = "Auberdine (Mist's Edge)" },
    b = { mapID = 1453, x = 0.226, y = 0.560, label = "Stormwind Harbor" } },
  { kind = "portal", faction = "Alliance", time = 15, verified = false,
    a = { mapID = 1438, x = 0.559, y = 0.896, label = "Rut'theran Village" },
    b = { mapID = 1457, x = 0.366, y = 0.500, label = "Darnassus" } },
  { kind = "boat", time = 180, verified = false,
    a = { mapID = 1434, x = 0.259, y = 0.731, label = "Booty Bay" },
    b = { mapID = 1413, x = 0.637, y = 0.386, label = "Ratchet" } },
  { kind = "zeppelin", faction = "Horde", time = 180, verified = false,
    a = { mapID = 1411, x = 0.508, y = 0.137, label = "Orgrimmar zeppelin towers" },
    b = { mapID = 1420, x = 0.607, y = 0.588, label = "Undercity zeppelin tower" } },
  { kind = "zeppelin", faction = "Horde", time = 180, verified = false,
    a = { mapID = 1411, x = 0.506, y = 0.126, label = "Orgrimmar zeppelin towers" },
    b = { mapID = 1434, x = 0.314, y = 0.302, label = "Grom'gol Base Camp" } },
  { kind = "zeppelin", faction = "Horde", time = 180, verified = false,
    a = { mapID = 1420, x = 0.619, y = 0.591, label = "Undercity zeppelin tower" },
    b = { mapID = 1434, x = 0.315, y = 0.291, label = "Grom'gol Base Camp" } },
  { kind = "tram", faction = "Alliance", time = 90, verified = false,
    a = { mapID = 1453, x = 0.663, y = 0.346, label = "Deeprun Tram (Stormwind)" },
    b = { mapID = 1455, x = 0.765, y = 0.510, label = "Deeprun Tram (Ironforge)" } },
}
