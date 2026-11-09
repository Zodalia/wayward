local _, ns = ...

-- Where you can walk from one zone into the next: gates, passes, bridges,
-- tunnels and lifts. The client exposes none of this, so it is hand-made.
-- Walk.lua routes a walk between zones through these; two zones with links
-- but no chain of them between the two can't be walked between at all
-- (Teldrassil and Darkshore: that's the boat). A zone with no link here and
-- none recorded is "uncharted": walks into and out of it are a straight
-- line, as every walk used to be.
--
-- `a` and `b` are the two zones' Era map IDs; mapID, x, y is the point
-- (on either zone's map). Which zones adjoin is vanilla knowledge and
-- reliable. The points are APPROXIMATE (not yet checked in game): a step to
-- one counts as done once you're in the zone it leads to, wherever you
-- crossed, and a crossing you walk yourself is recorded and replaces the
-- nearest point here for the same two zones (/ww crossings lists them, as
-- lines to paste over these). `label` reads after "through".
--
-- Left out on purpose: swims, one-way drops, and ways that need a key
-- (Stonewrought Pass, the Searing Gorge gate).

ns.data.zoneLinks = {
  ---------------------------------------------------------------- Eastern Kingdoms
  { a = 1429, b = 1453, mapID = 1429, x = 0.322, y = 0.497, label = "the gates of Stormwind" },
  { a = 1429, b = 1436, mapID = 1429, x = 0.207, y = 0.798, label = "the Westfall bridge" },
  { a = 1429, b = 1433, mapID = 1429, x = 0.935, y = 0.722, label = "Three Corners" },
  { a = 1429, b = 1431, mapID = 1431, x = 0.745, y = 0.165, label = "the bridge north of Darkshire" },
  { a = 1433, b = 1431, mapID = 1431, x = 0.930, y = 0.110, label = "the bridge south of Three Corners" },
  { a = 1436, b = 1431, mapID = 1431, x = 0.045, y = 0.630, label = "the bridge west of Raven Hill" },
  { a = 1433, b = 1428, mapID = 1428, x = 0.780, y = 0.870, label = "Blackrock Pass" },
  { a = 1431, b = 1430, mapID = 1431, x = 0.945, y = 0.420, label = "Deadwind Pass" },
  { a = 1430, b = 1435, mapID = 1435, x = 0.040, y = 0.600, label = "the road out of Deadwind Pass" },
  { a = 1435, b = 1419, mapID = 1419, x = 0.510, y = 0.070, label = "the road south of Stonard" },
  { a = 1431, b = 1434, mapID = 1431, x = 0.450, y = 0.880, label = "the road south out of Duskwood" },
  { a = 1426, b = 1455, mapID = 1426, x = 0.535, y = 0.350, label = "the gates of Ironforge" },
  { a = 1426, b = 1432, mapID = 1426, x = 0.870, y = 0.510, label = "South Gate Pass" },
  { a = 1426, b = 1432, mapID = 1426, x = 0.860, y = 0.310, label = "North Gate Pass" },
  { a = 1432, b = 1437, mapID = 1432, x = 0.250, y = 0.105, label = "Dun Algaz" },
  { a = 1432, b = 1418, mapID = 1432, x = 0.470, y = 0.790, label = "the pass south of the Loch" },
  { a = 1418, b = 1427, mapID = 1418, x = 0.060, y = 0.610, label = "the pass west of Kargath" },
  { a = 1427, b = 1428, mapID = 1427, x = 0.350, y = 0.850, label = "Blackrock Mountain" },
  { a = 1437, b = 1417, mapID = 1417, x = 0.455, y = 0.885, label = "the Thandol Span" },
  { a = 1417, b = 1424, mapID = 1417, x = 0.200, y = 0.290, label = "Thoradin's Wall" },
  { a = 1424, b = 1416, mapID = 1424, x = 0.540, y = 0.180, label = "the road north of Tarren Mill" },
  { a = 1424, b = 1421, mapID = 1424, x = 0.140, y = 0.460, label = "the road west out of Hillsbrad" },
  { a = 1424, b = 1425, mapID = 1424, x = 0.850, y = 0.320, label = "the path past Durnholde Keep" },
  { a = 1416, b = 1422, mapID = 1422, x = 0.430, y = 0.880, label = "Chillwind Point" },
  { a = 1420, b = 1422, mapID = 1420, x = 0.835, y = 0.690, label = "the Bulwark" },
  { a = 1422, b = 1423, mapID = 1422, x = 0.700, y = 0.505, label = "the Thondroril River bridge" },
  { a = 1420, b = 1458, mapID = 1420, x = 0.617, y = 0.665, label = "the Ruins of Lordaeron" },
  { a = 1420, b = 1421, mapID = 1421, x = 0.665, y = 0.050, label = "the road south out of Tirisfal" },

  ---------------------------------------------------------------- Kalimdor
  { a = 1438, b = 1457, mapID = 1438, x = 0.365, y = 0.540, label = "the gates of Darnassus" },
  { a = 1439, b = 1440, mapID = 1439, x = 0.435, y = 0.940, label = "the road south out of Darkshore" },
  { a = 1440, b = 1448, mapID = 1440, x = 0.555, y = 0.290, label = "the road north into Felwood" },
  { a = 1440, b = 1413, mapID = 1413, x = 0.485, y = 0.055, label = "the Mor'shan Rampart" },
  { a = 1440, b = 1442, mapID = 1440, x = 0.420, y = 0.710, label = "the Talondeep Path" },
  { a = 1440, b = 1447, mapID = 1440, x = 0.945, y = 0.480, label = "the road east into Azshara" },
  { a = 1448, b = 1452, mapID = 1452, x = 0.275, y = 0.345, label = "Timbermaw Hold" },
  { a = 1448, b = 1450, mapID = 1448, x = 0.645, y = 0.075, label = "Timbermaw Hold" },
  { a = 1411, b = 1454, mapID = 1411, x = 0.455, y = 0.120, label = "the gates of Orgrimmar" },
  { a = 1411, b = 1413, mapID = 1413, x = 0.625, y = 0.195, label = "the Southfury bridge" },
  { a = 1413, b = 1412, mapID = 1412, x = 0.690, y = 0.605, label = "the pass west of Camp Taurajo" },
  { a = 1412, b = 1456, mapID = 1412, x = 0.385, y = 0.310, label = "the lifts of Thunder Bluff" },
  { a = 1413, b = 1442, mapID = 1413, x = 0.350, y = 0.275, label = "Honor's Stand" },
  { a = 1413, b = 1445, mapID = 1413, x = 0.495, y = 0.785, label = "the road east into Dustwallow Marsh" },
  { a = 1413, b = 1441, mapID = 1413, x = 0.440, y = 0.915, label = "the Great Lift" },
  { a = 1441, b = 1444, mapID = 1444, x = 0.890, y = 0.410, label = "the road west into Feralas" },
  { a = 1441, b = 1446, mapID = 1446, x = 0.510, y = 0.210, label = "the pass south of the Shimmering Flats" },
  { a = 1446, b = 1449, mapID = 1446, x = 0.270, y = 0.520, label = "the ramp into Un'Goro Crater" },
  { a = 1449, b = 1451, mapID = 1449, x = 0.290, y = 0.210, label = "the pass into Silithus" },
  { a = 1442, b = 1443, mapID = 1443, x = 0.535, y = 0.040, label = "the Charred Vale" },
  { a = 1443, b = 1444, mapID = 1443, x = 0.440, y = 0.970, label = "the road south out of Desolace" },
}
