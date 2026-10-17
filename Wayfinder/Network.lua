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

function Network.Build()
  local faction = UnitFactionGroup("player")
  local known = ns.charDB.knownTaxi
  local net = { flights = {}, transports = {}, knownFlights = 0 }

  for _, continent in pairs(ns.Geo.Continents()) do
    for _, t in ipairs(C_TaxiMap.GetTaxiNodesForMap(continent) or {}) do
      if known[t.nodeID] and usableTaxi(t, faction) and t.position then
        local node = ns.Geo.Node(continent, t.position.x, t.position.y, t.name)
        if node then
          node.isFlight, node.nodeID = true, t.nodeID
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
  return net
end
