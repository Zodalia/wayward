local _, ns = ...

-- Your Hearthstone, for the journey planner (Journey.lua): where it takes you
-- and how soon it's ready. The client only names the bind location
-- (GetBindLocation: "Stormwind City", "Goldshire"), so where it is comes from
-- us: where you stood when you set it (HEARTHSTONE_BOUND, next to the
-- innkeeper) or where you landed after using it; else an innkeeper you've met
-- in a place of that name (Harvest.lua records their subzone).

local Hearth = {}
ns.Hearth = Hearth

Hearth.ITEM = 6948      -- Hearthstone
Hearth.SPELL = 8690     -- its spell
Hearth.CAST = 15        -- seconds: the 10 s cast and the landing (or a loading screen)
local LANDED_AFTER = 4  -- seconds after the cast to read where you landed

local function bindName()
  local name = GetBindLocation and GetBindLocation()
  return name ~= "" and name or nil
end

local function remember()
  local name, here = bindName(), ns.Geo.PlayerNode()
  if not (name and here) then return end
  ns.charDB.hearth = { name = name, mapID = here.mapID, x = here.x, y = here.y }
  ns.Fire("DATA_CHANGED", "hearth")
end

ns.On("HEARTHSTONE_BOUND", remember)
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
  if unit == "player" and spellID == Hearth.SPELL then ns.After(LANDED_AFTER, remember) end
end)

-- An innkeeper you've met in the place you're bound to.
local function innkeeperIn(name)
  for _, entry in ipairs(ns.Harvest.NodesOf("innkeeper")) do
    local npc = entry.npc
    if npc.subZone == name or (npc.mapID and ns.MapName(npc.mapID) == name) then return entry.node end
  end
  return nil
end

-- Where your Hearthstone takes you: a node labelled with the bind location, or nil.
function Hearth.Node()
  local name = bindName()
  if not name then return nil end
  local saved = ns.charDB and ns.charDB.hearth
  local node
  if saved and saved.name == name then node = ns.Geo.Node(saved.mapID, saved.x, saved.y) end
  node = node or innkeeperIn(name)
  if not node then return nil end
  return { label = name, mapID = node.mapID, x = node.x, y = node.y, instance = node.instance, wx = node.wx,
    wy = node.wy, hearth = true }
end

-- Seconds until the Hearthstone is ready (0: now).
function Hearth.ReadyIn()
  local cooldown = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
  if not (cooldown and GetTime) then return 0 end
  local start, duration = cooldown(Hearth.ITEM)
  if not (start and duration) or start <= 0 or duration <= 0 then return 0 end
  return math.max(0, start + duration - GetTime())
end

-- { node, readyIn } when you have a Hearthstone in your bags and we know
-- where it takes you, else nil.
function Hearth.Get()
  if ns.ItemCount(Hearth.ITEM) <= 0 then return nil end
  local node = Hearth.Node()
  if not node then return nil end
  return { node = node, readyIn = Hearth.ReadyIn() }
end
