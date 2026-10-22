local _, ns = ...

-- Errands: stops you add to a trip for yourself, not for a quest (repair,
-- sell, mail, bank, ...), like a road map's "add a stop: petrol". Each kind
-- lists the places that add least to the trip on now (OnTheWay.Added), from
-- NPCs you've talked to (Harvest.lua), the data sources' NPC flags and, for
-- mailboxes, the ones you've opened and the sources' objects named "Mailbox".
-- UI/ErrandPicker.lua is the list behind the directions box's + button.

local Errands = {}
ns.Errands = Errands

local CANDIDATES = 8   -- nearest places to the way (straight line) that get a full route
local MAX = 5          -- places listed per kind
local KEEP = 20        -- seconds a list is reused
local WORN = 0.75      -- gear at or under this: the list opens on repairs
local FULL_BAGS = 2    -- free bag slots at or under this: it opens on vendors
local SAME_MAILBOX = 10 -- yards: a mailbox opened again where one is recorded

-- npc: the Harvest kind and source NPC flag; class: only for that class.
Errands.KINDS = {
  { key = "repair", label = "Repair", npc = "repair", text = "Repair at %s",
    icon = "Interface\\Minimap\\Tracking\\Repair" },
  { key = "vendor", label = "Vendor", npc = "vendor", text = "Sell and buy at %s",
    icon = "Interface\\GossipFrame\\VendorGossipIcon" },
  { key = "mailbox", label = "Mailbox", text = "Check your mail",
    icon = "Interface\\Minimap\\Tracking\\Mailbox" },
  { key = "banker", label = "Bank", npc = "banker", text = "Bank with %s",
    icon = "Interface\\Minimap\\Tracking\\Banker" },
  { key = "innkeeper", label = "Inn", npc = "innkeeper", text = "Visit %s",
    icon = "Interface\\Minimap\\Tracking\\Innkeeper" },
  { key = "auctioneer", label = "Auction house", npc = "auctioneer", text = "Auction house: %s",
    icon = "Interface\\Minimap\\Tracking\\Auctioneer" },
  { key = "stableMaster", label = "Stable master", npc = "stableMaster", text = "Stable with %s", class = "HUNTER",
    icon = "Interface\\Minimap\\Tracking\\StableMaster" },
}

local byKey = {}
for _, kind in ipairs(Errands.KINDS) do byKey[kind.key] = kind end

-- The kinds for your character, in chip order.
function Errands.Kinds()
  local _, class = UnitClass("player")
  local out = {}
  for _, kind in ipairs(Errands.KINDS) do
    if not kind.class or kind.class == class then out[#out + 1] = kind end
  end
  return out
end

function Errands.Kind(key) return byKey[key] end

local function freeBagSlots()
  local get = C_Container and C_Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots
  if not get then return nil end
  local free = 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    local n = get(bag)
    if type(n) == "number" then free = free + n end
  end
  return free
end

-- The kind the list opens on: repairs when your gear is worn, a vendor when
-- your bags are full, else the last one you picked.
function Errands.DefaultKind()
  local durability = ns.Vendors.Durability()
  if durability and durability <= WORN then return "repair" end
  local free = freeBagSlots()
  if free and free <= FULL_BAGS then return "vendor" end
  return Errands.lastKind or "repair"
end

---------------------------------------------------------------- places

local sourceIndex = {} -- [flag] = { {id, name, faction, nodes}, ... }, until the sources change
local mailboxIndex     -- { {node, faction}, ... } from the sources' objects

-- Source NPCs with a flag, one pass per flag.
local function sourceNPCs(flag)
  if sourceIndex[flag] then return sourceIndex[flag] end
  local out = {}
  if ns.Data.Has("Npc") then
    for _, id in ipairs(ns.Data.NpcIDs(flag)) do
      local npc = ns.Data.Npc(id)
      local nodes = npc and npc.name and ns.Data.Nodes(npc.positions, npc.name) or {}
      if #nodes > 0 then out[#out + 1] = { id = id, name = npc.name, faction = npc.faction, nodes = nodes } end
    end
  end
  sourceIndex[flag] = out
  return out
end

local function friendlyHarvested(npc, faction)
  return npc.faction == nil or npc.faction == faction or npc.faction == "Neutral"
end

-- Harvested NPCs count for a kind: a vendor that repairs counts for repairs.
local function harvestedAs(npc, kind)
  if kind.key == "repair" then return npc.kinds.vendor and npc.repairs end
  return npc.kinds[kind.npc]
end

-- An NPC kind's places: { {npc, node}, ... } for your faction, each at its
-- spawn nearest `here`. Where you met them (measured in this client) wins.
local function npcPlaces(kind, here)
  local faction = UnitFactionGroup("player")
  local out, seen = {}, {}
  for id, npc in pairs(ns.Harvest.AllNPCs()) do
    if npc.kinds and harvestedAs(npc, kind) and friendlyHarvested(npc, faction) then
      local node = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.name)
      if node then
        out[#out + 1] = { id = id, npc = npc.name, node = node }
        seen[id] = true
      end
    end
  end
  for _, e in ipairs(sourceNPCs(kind.npc)) do
    if not seen[e.id] and ns.Data.FriendlyTo(e.faction, faction) then
      out[#out + 1] = { id = e.id, npc = e.name, node = (ns.Data.Nearest(e.nodes, here)) }
    end
  end
  return out
end

-- Whose town a point is in: the side of the nearest innkeeper or flight
-- master ("A", "H", "AH"), or nil when the sources know none on its continent.
local function townSide(node, towns)
  local best, bestDistance
  for _, t in ipairs(towns) do
    for _, n in ipairs(t.nodes) do
      local d = ns.Geo.Distance(node, n)
      if d < (bestDistance or math.huge) then best, bestDistance = t, d end
    end
  end
  return best and best.faction
end

local function now()
  return debugprofilestop and debugprofilestop() or 0
end

-- The sources' mailboxes (by their English name), once until the sources change.
local function sourceMailboxes()
  if mailboxIndex then return mailboxIndex end
  mailboxIndex = {}
  if not ns.Data.Has("ObjectIDs") then return mailboxIndex end
  local started = now()
  local towns = {}
  for _, e in ipairs(sourceNPCs("innkeeper")) do towns[#towns + 1] = e end
  for _, e in ipairs(sourceNPCs("flightMaster")) do towns[#towns + 1] = e end
  for _, id in ipairs(ns.Data.ObjectIDs("Mailbox")) do
    local object = ns.Data.Object(id)
    for _, node in ipairs(object and ns.Data.Nodes(object.positions, "Mailbox") or {}) do
      mailboxIndex[#mailboxIndex + 1] = { node = node, faction = townSide(node, towns) }
    end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.sourceMailboxes = now() - started
  return mailboxIndex
end

-- Mailboxes: the ones you've opened, then the sources' in friendly towns.
local function mailboxPlaces()
  local faction = UnitFactionGroup("player")
  local out = {}
  for _, m in ipairs(ns.db.mailboxes or {}) do
    local node = ns.Geo.Node(m.mapID, m.x, m.y, "Mailbox")
    if node then out[#out + 1] = { node = node } end
  end
  for _, m in ipairs(sourceMailboxes()) do
    local known = false
    for _, p in ipairs(out) do
      if ns.Geo.Distance(p.node, m.node) <= SAME_MAILBOX then known = true break end
    end
    if not known and ns.Data.FriendlyTo(m.faction, faction) then out[#out + 1] = { node = m.node } end
  end
  return out
end

local function places(kind, here)
  if kind.key == "mailbox" then return mailboxPlaces() end
  return npcPlaces(kind, here)
end

ns.Listen("SOURCES_CHANGED", function() sourceIndex, mailboxIndex = {}, nil end)

---------------------------------------------------------------- ranking

local cache = {}

-- The NPCs the trip already goes to, and its objects' places (mailboxes).
local function inTrip(a)
  local names, objects = {}, {}
  local root = a.journey and (a.journey.root or a.journey.def)
  for _, stop in ipairs(root and root.stops or {}) do
    if not stop.done and not stop.skipped then
      if stop.npc then names[stop.npc] = true end
      if stop.node and stop.node.object then objects[#objects + 1] = stop.node end
    end
  end
  if a.goal and a.goal.npc then names[a.goal.npc] = true end
  return function(p)
    if p.npc then return names[p.npc] or nil end
    for _, node in ipairs(objects) do
      if ns.Geo.Distance(node, p.node) <= SAME_MAILBOX then return true end
    end
    return nil
  end
end

-- A kind's places for the trip on now, least out of the way first:
-- { {npc?, node, place, extra (seconds it adds), inTrip}, ... }, and a line
-- to show instead when there are none.
function Errands.Get(key)
  local kind = byKey[key]
  local a = ns.Nav.active
  local here = ns.Geo.PlayerNode()
  if not (kind and a and here) then return {}, "Can't read your position here." end
  local now = GetTime and GetTime() or 0
  local tripKey = tostring(a) .. ":" .. a.index .. ":" .. #(a.journey and a.journey.stops or {})
  local hit = cache[key]
  if hit and hit.tripKey == tripKey and now - hit.at < KEEP then return hit.list, hit.empty end

  local stops, near = ns.OnTheWay.RoutePoints(a, here)
  local all = places(kind, here)
  for _, p in ipairs(all) do
    local d = math.huge
    for _, n in ipairs(near) do d = math.min(d, ns.Geo.Distance(n, p.node)) end
    p.distance = d
  end
  table.sort(all, function(x, y) return x.distance < y.distance end)
  local net = ns.Network.Build()
  local going = inTrip(a)
  local list = {}
  for i = 1, math.min(#all, CANDIDATES) do
    local p = all[i]
    if p.distance < math.huge then
      p.extra = ns.OnTheWay.Added(p.node, stops, net)
      if p.extra < math.huge then
        p.place = ns.Places.NameFor(p.node) or ns.MapName(p.node.mapID)
        p.inTrip = going(p)
        list[#list + 1] = p
      end
    end
  end
  table.sort(list, function(x, y)
    if x.extra ~= y.extra then return x.extra < y.extra end
    return x.distance < y.distance
  end)
  while #list > MAX do table.remove(list) end

  local empty
  if #list == 0 then
    if key == "mailbox" then
      empty = "No mailboxes known yet. Open one once and Wayward remembers it, or install " .. ns.Data.ADDON .. "."
    else
      empty = string.format("None known near your trip. Talk to one once and Wayward remembers where they are, "
        .. "or install %s.", ns.Data.ADDON)
    end
  end
  cache[key] = { tripKey = tripKey, at = now, list = list, empty = empty }
  return list, empty
end

-- The stop for a place from Errands.Get.
function Errands.Stop(key, p)
  local kind = byKey[key]
  if p.npc then
    return { node = p.node, npc = p.npc, text = string.format(kind.text, p.npc),
      action = { kind = "talk", npc = p.npc } }
  end
  -- An object: nobody to target, done on arrival.
  local node = ns.Geo.Node(p.node.mapID, p.node.x, p.node.y, p.node.label)
  if node then node.object = true end
  return { node = node or p.node, text = kind.text }
end

-- Adds a place to the trip. Returns true when the trip changed.
function Errands.Add(key, p)
  local kind = byKey[key]
  if not (kind and p) or p.inTrip then return false end
  Errands.lastKind = key
  cache = {}
  local label = p.npc and string.format("%s (%s)", kind.label, p.npc) or kind.label
  return ns.Nav.AddToTrip({ Errands.Stop(key, p) }, label)
end

ns.Listen("JOURNEY_STARTED", function() cache = {} end)
ns.Listen("JOURNEY_EXTENDED", function() cache = {} end)
ns.Listen("DATA_CHANGED", function() cache = {} end)
ns.Listen("SOURCES_CHANGED", function() cache = {} end)

---------------------------------------------------------------- mailboxes you open

-- Where you stand when a mailbox opens is where it is (to a few yards).
local function recordMailbox()
  local here = ns.Geo.PlayerNode()
  if not here then return end
  ns.db.mailboxes = ns.db.mailboxes or {}
  for _, m in ipairs(ns.db.mailboxes) do
    local node = ns.Geo.Node(m.mapID, m.x, m.y)
    if node and ns.Geo.Distance(node, here) <= SAME_MAILBOX then return end
  end
  table.insert(ns.db.mailboxes, { mapID = here.mapID, x = here.x, y = here.y })
  ns.Fire("DATA_CHANGED", "mailbox")
end

ns.On("MAIL_SHOW", recordMailbox)
