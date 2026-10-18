local _, ns = ...

-- Builds the travel network the router plans over: flight paths this
-- character knows (positions from C_TaxiMap, known state from Harvest.lua)
-- and the hand-made transports usable by the player's faction.

local Network = {}
ns.Network = Network

-- C_TaxiMap node.faction: 1 = Horde, 2 = Alliance, anything else is neutral.
local TAXI_FACTION = { Horde = 1, Alliance = 2 }

local function usableTaxi(node, faction)
  local other = faction == "Alliance" and TAXI_FACTION.Horde or TAXI_FACTION.Alliance
  return node.faction ~= other
end

-- Built once and reused while nothing it depends on changes (the planner
-- keeps its worked-out paths on it): your known flight paths, the recorded
-- and bundled transports, your faction.
local cached, cachedKey
local FLIGHT_MASTER_RADIUS = 60 -- yards from a flight path's map position

local function signature()
  local known, count = ns.charDB.knownTaxi, 0
  for _ in pairs(known) do count = count + 1 end
  return table.concat({ tostring(known), count, tostring(ns.db.transports), #ns.db.transports,
    tostring(ns.data.transports), #ns.data.transports, UnitFactionGroup("player") or "",
    tostring(C_TaxiMap), tostring(C_TaxiMap.GetTaxiNodesForMap) }, "|")
end

function Network.Build()
  local key = signature()
  if cached and cachedKey == key then return cached end
  local faction = UnitFactionGroup("player")
  local known = ns.charDB.knownTaxi
  local net = { flights = {}, transports = {}, knownFlights = 0 }

  for _, continent in pairs(ns.Geo.Continents()) do
    for _, t in ipairs(C_TaxiMap.GetTaxiNodesForMap(continent) or {}) do
      if known[t.nodeID] and usableTaxi(t, faction) and t.position then
        local node = ns.Geo.Node(continent, t.position.x, t.position.y, t.name)
        if node then
          node.isFlight, node.nodeID = true, t.nodeID
          -- Who you talk to there: one you've met, else QuestieDB's.
          node.npc = ns.Harvest.NPCNear("flightMaster", node, FLIGHT_MASTER_RADIUS)
            or ns.Questie.FlightMasterNear(node, FLIGHT_MASTER_RADIUS)
          net.flights[#net.flights + 1] = node
        end
      end
    end
  end
  net.knownFlights = #net.flights

  local transports = {}
  for _, t in ipairs(ns.data.transports) do transports[#transports + 1] = t end
  for _, t in ipairs(ns.db.transports) do transports[#transports + 1] = t end -- /wf dock

  for _, t in ipairs(transports) do
    if t.faction == nil or t.faction == faction then
      local a = ns.Geo.Node(t.a.mapID, t.a.x, t.a.y, t.a.label)
      local b = ns.Geo.Node(t.b.mapID, t.b.x, t.b.y, t.b.label)
      if a and b then
        net.transports[#net.transports + 1] = { kind = t.kind, time = t.time, a = a, b = b }
      end
    end
  end
  cached, cachedKey = net, key
  return net
end

ns.Listen("FLIGHTS_CHANGED", function() cached = nil end)
-- A newly met flight master names their flight path.
ns.Listen("DATA_CHANGED", function() cached = nil end)
