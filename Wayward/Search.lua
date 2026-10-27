local _, ns = ...

-- One index and one matcher for everything a player might look for: quests,
-- items, NPCs (by name and by role: "warlock trainer", "weapon master",
-- "innkeeper"...), dungeons, zones, flight-path towns, your class's spells
-- and professions. The Find page searches all of it; the Quests and Items
-- pages search their own kind through it. Link and ID parsing lives here too.
--
--   ns.Search.Find(text, kinds?) -> { {kind, id, name, score, ...}, ... }
--     ranked: an exact name first, then names starting with the text, then
--     names containing it, then matches on a role or alias; shorter names
--     first within a rank. `kinds` is a list ({ "quest", "item" }); nil is all.
--   ns.Search.Parse(text) -> kind, id, name
--     a shift-clicked link (|Hquest:, |Hitem:, |Hspell:), "item:N", "quest:N",
--     or "#N" / a bare number (kind nil: the page decides). name is the
--     link's [Name], or nil.
--
-- Indexes are built on the first search of each kind and dropped when the
-- data changes (DATA_CHANGED, SOURCES_CHANGED); the spells one also when
-- your spells change.
--
-- This file is also home to the row helpers every page shares, so that
-- results of every kind come out in one shape with one set of actions (the
-- Panel row contract, UI/Panel.lua): Search.WithDetour adds the "Add detour"
-- action while a journey is on.

local Search = {}
ns.Search = Search

Search.KINDS = { "quest", "item", "npc", "dungeon", "zone", "place", "spell", "profession" }

-- Match ranks (score), best first.
local EXACT, PREFIX, SUBSTRING, ALIAS = 400, 300, 200, 100

-- NPC roles the index knows, with the data sources' flag (Sources.lua
-- NpcIDs) and the words a search can use for them.
local ROLES = {
  { key = "classTrainer", words = { "trainer", "class trainer" } },
  { key = "weaponMaster", words = { "weapon master", "weapons", "trainer" } },
  { key = "professionTrainer", words = { "trainer", "profession trainer" } },
  { key = "vendor", flag = "vendor", words = { "vendor", "merchant" } },
  { key = "repair", flag = "repair", words = { "repair", "repairs" } },
  { key = "flightMaster", flag = "flightMaster", words = { "flight master", "flight path", "gryphon", "wind rider" } },
  { key = "innkeeper", flag = "innkeeper", words = { "innkeeper", "inn" } },
  { key = "banker", flag = "banker", words = { "banker", "bank" } },
  { key = "auctioneer", flag = "auctioneer", words = { "auctioneer", "auction house" } },
  { key = "stableMaster", flag = "stableMaster", words = { "stable master", "stable" } },
}
Search.ROLES = ROLES

local ROLE_LABEL = {
  classTrainer = "Class trainer", weaponMaster = "Weapon master", professionTrainer = "Profession trainer",
  vendor = "Vendor", repair = "Repairs", flightMaster = "Flight master", innkeeper = "Innkeeper",
  banker = "Banker", auctioneer = "Auctioneer", stableMaster = "Stable master",
}

local function trim(text)
  return ((text or ""):match("^%s*(.-)%s*$"))
end

local function now()
  return debugprofilestop and debugprofilestop() or 0
end

---------------------------------------------------------------- parsing

function Search.Parse(text)
  text = trim(text)
  local name = text:match("|h%[(.-)%]|h")
  -- (A command's text may have been lower-cased: |hquest: counts too.)
  for _, kind in ipairs({ "quest", "item", "spell" }) do
    local id = text:match("|[Hh]" .. kind .. ":(%d+)")
    if id then return kind, tonumber(id), name end
  end
  local kind, id = text:match("^(%a+):(%d+)$")
  if kind == "item" or kind == "quest" or kind == "spell" then return kind, tonumber(id), name end
  id = text:match("^#(%d+)$") or text:match("^(%d+)$")
  if id then return nil, tonumber(id), name end
  return nil, nil, name
end

---------------------------------------------------------------- indexes

-- [kind] = { {kind, id, name, key = lower-case name, aliases = { lower-case, ... }?, ...}, ... }
local indexes = {}

function Search.Forget(kind)
  if kind then indexes[kind] = nil else indexes = {} end
end

ns.Listen("DATA_CHANGED", function() Search.Forget() end)
ns.Listen("SOURCES_CHANGED", function() Search.Forget() end)
ns.On("SPELLS_CHANGED", function() Search.Forget("spell") end)

local builders = {}

local function entry(kind, id, name, extra)
  local e = { kind = kind, id = id, name = name, key = name:lower() }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

function builders.quest()
  local out = {}
  if not ns.Quests.Available() then return out end
  for id, q in pairs(ns.Quests.Index()) do
    ns.WarmStep()
    if type(q.name) == "string" and q.name ~= "" then out[#out + 1] = entry("quest", id, q.name, { quest = q }) end
  end
  return out
end

-- The client's name for an item it has seen (nil until it loads).
local function clientItemName(id)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local ok, name = pcall(getInfo, id)
  return ok and type(name) == "string" and name or nil
end

-- Item data when a source has it; else the goods of vendors you visited,
-- named by the client.
function builders.item()
  local out = {}
  if ns.Data.Has("Item") then
    for _, id in ipairs(ns.Data.ItemIDs()) do
      ns.WarmStep()
      local item = ns.Data.Item(id)
      local name = item and item.name
      if type(name) == "string" and name ~= "" then out[#out + 1] = entry("item", id, name) end
    end
    return out
  end
  local seen = {}
  for _, npc in pairs(ns.Harvest and ns.Harvest.AllNPCs() or {}) do
    if npc.kinds and npc.kinds.vendor then
      for _, id in ipairs(npc.goods or {}) do
        if not seen[id] then
          seen[id] = true
          local name = clientItemName(id)
          if name then out[#out + 1] = entry("item", id, name) end
        end
      end
    end
  end
  return out
end

-- NPCs with a role: from the data sources (by flag; class, weapon and
-- profession trainers through Data.NPCsOfKind) and the ones you met
-- (Harvest.lua). Each knows its roles, its nodes and its faction.
function builders.npc()
  local out, byID = {}, {}
  local function add(id, name, roles, nodes, faction, extra)
    local e = byID[id]
    if not e then
      e = entry("npc", id, name, { roles = {}, nodes = {}, aliases = {}, faction = faction })
      byID[id] = e
      out[#out + 1] = e
    end
    for role in pairs(roles) do e.roles[role] = true end
    if nodes and #nodes > 0 and #e.nodes == 0 then e.nodes = nodes end
    for k, v in pairs(extra or {}) do e[k] = v end
  end
  if ns.Data.Has("Npc") then
    for _, role in ipairs(ROLES) do
      if role.flag then
        for _, id in ipairs(ns.Data.NpcIDs(role.flag)) do
          ns.WarmStep()
          local npc = ns.Data.Npc(id)
          if npc and type(npc.name) == "string" then
            add(id, npc.name, { [role.key] = true }, ns.Data.Nodes(npc.positions, npc.name), npc.faction,
              { subName = npc.subName })
          end
        end
      end
    end
    for _, kind in ipairs({ "classTrainer", "weaponMaster", "professionTrainer" }) do
      for _, t in ipairs(ns.Data.NPCsOfKind(kind)) do
        ns.WarmStep()
        local npc = ns.Data.Npc(t.id)
        add(t.id, t.name, { [kind] = true }, t.nodes, t.faction,
          { class = t.class, profession = t.profession, subName = npc and npc.subName })
      end
    end
  end
  -- NPCs you met: their roles and positions (measured in this client) win.
  for id, npc in pairs(ns.Harvest and ns.Harvest.AllNPCs() or {}) do
    if type(npc.name) == "string" and npc.kinds then
      local node = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.name)
      local roles = {}
      for kind in pairs(npc.kinds) do roles[kind] = true end
      if npc.kinds.vendor and npc.repairs then roles.repair = true end
      local e = byID[id]
      if e then
        for role in pairs(roles) do e.roles[role] = true end
        if node then e.nodes = { node } end
        e.class = e.class or npc.class
      else
        add(id, npc.name, roles, node and { node } or {}, npc.faction, { class = npc.class, met = true })
      end
    end
  end
  -- What a search can call them besides their name.
  for _, e in ipairs(out) do
    local seen = {}
    local function alias(text)
      if type(text) == "string" and text ~= "" and not seen[text:lower()] then
        seen[text:lower()] = true
        e.aliases[#e.aliases + 1] = text:lower()
      end
    end
    alias(e.subName)
    for _, role in ipairs(ROLES) do
      if e.roles[role.key] then
        for _, word in ipairs(role.words) do alias(word) end
      end
    end
    if e.class then
      alias(e.class:lower() .. " trainer")
      alias(e.class:lower())
    end
    if e.profession then alias(e.profession:lower() .. " trainer") end
  end
  return out
end

function builders.dungeon()
  local out = {}
  for _, d in ipairs(ns.Dungeons and ns.Dungeons.Catalogue() or {}) do
    out[#out + 1] = entry("dungeon", d.keys[1], d.name, { dungeon = d, aliases = {} })
    for i = 2, #d.keys do out[#out].aliases[#out[#out].aliases + 1] = d.keys[i] end
  end
  return out
end

-- Zones: the continents' zone maps (C_Map). Guarded against a client (or a
-- stub) that answers the continents themselves.
function builders.zone()
  local out, seen = {}, {}
  local continents = {}
  for _, mapID in pairs(ns.Geo.Continents()) do continents[mapID] = true end
  local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone
  for _, continent in pairs(ns.Geo.Continents()) do
    for _, info in ipairs(C_Map.GetMapChildrenInfo(continent, zoneType, true) or {}) do
      local mapID = info.mapID
      if mapID and not continents[mapID] and not seen[mapID] then
        seen[mapID] = true
        local name = info.name or ns.MapName(mapID)
        if type(name) == "string" and name ~= "" and name ~= "?" then
          out[#out + 1] = entry("zone", mapID, name, { continent = continent })
        end
      end
    end
  end
  return out
end

-- Places: flight-path towns ("Lakeshire"), each at its flight master.
function builders.place()
  local out = {}
  if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return out end
  for _, continent in pairs(ns.Geo.Continents()) do
    for _, t in ipairs(C_TaxiMap.GetTaxiNodesForMap(continent) or {}) do
      if t.position and t.name then
        local short = t.name:match("^([^,]+)") or t.name
        local node = ns.Geo.Node(continent, t.position.x, t.position.y, short)
        if node then out[#out + 1] = entry("place", t.nodeID or short, short, { node = node, full = t.name }) end
      end
    end
  end
  return out
end

local function spellName(spellID)
  if C_Spell and C_Spell.GetSpellName then
    return C_Spell.GetSpellName(spellID), C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(spellID)
  end
  if GetSpellInfo then return (GetSpellInfo(spellID)), GetSpellSubtext and GetSpellSubtext(spellID) end
  return nil
end

-- Your class's trainer spells: from your last trainer visit when there was
-- one (Trainers.Services), else the data sources, named by the client.
function builders.spell()
  local out, seen = {}, {}
  local services = ns.Trainers and ns.Trainers.Services()
  for _, s in ipairs(services or {}) do
    local key = (s.name or "") .. "|" .. tostring(s.rank or "")
    if s.name and not seen[key] then
      seen[key] = true
      out[#out + 1] = entry("spell", s.spellID or key, s.name, { service = s, rank = s.rank,
        aliases = s.rank and { (s.name .. " " .. s.rank):lower() } or nil })
    end
  end
  if #out > 0 then return out end
  local _, class = UnitClass("player")
  for _, spell in ipairs(ns.Data.ClassSpells(class)) do
    ns.WarmStep()
    local name, rank = spellName(spell.spellID)
    if name then
      rank = rank ~= "" and rank or nil
      out[#out + 1] = entry("spell", spell.spellID, name, { spell = spell, rank = rank,
        aliases = rank and { (name .. " " .. rank):lower() } or nil })
    end
  end
  return out
end

function builders.profession()
  local out = {}
  for _, p in ipairs(ns.Professions and ns.Professions.LIST or {}) do
    out[#out + 1] = entry("profession", p.name, p.name, { profession = p, aliases = { p.noun:lower() } })
  end
  return out
end

local function index(kind)
  if not indexes[kind] then
    local started = now()
    local ok, built = ns.Protect(builders[kind])
    indexes[kind] = ok and built or {}
    if not ok then geterrorhandler()(built) end
    ns.debugTimings = ns.debugTimings or {}
    ns.debugTimings["search " .. kind] = now() - started
  end
  return indexes[kind]
end

-- The index of one kind (for pages that need the entries themselves).
function Search.Index(kind)
  return index(kind)
end

-- The big indexes are built a slice per frame with the quest data
-- (Quests.Warm), not on the first keystroke. Quests.lua loads after this
-- file, so the warmer is registered once everything has loaded.
ns.Listen("DB_READY", function()
  if ns.Quests and ns.Quests.AddWarmer then
    ns.Quests.AddWarmer("search", function()
      for _, kind in ipairs({ "quest", "item", "npc" }) do index(kind) end
    end)
  end
end)

---------------------------------------------------------------- matching

local function rankOf(e, key)
  if e.key == key then return EXACT end
  if e.key:sub(1, #key) == key then return PREFIX end
  if e.key:find(key, 1, true) then return SUBSTRING end
  for _, alias in ipairs(e.aliases or {}) do
    if alias == key or alias:find(key, 1, true) then return ALIAS end
  end
  return nil
end

local function better(a, b)
  if a.score ~= b.score then return a.score > b.score end
  if #a.name ~= #b.name then return #a.name < #b.name end
  if a.name ~= b.name then return a.name < b.name end
  if a.kind ~= b.kind then return a.kind < b.kind end
  return tostring(a.id) < tostring(b.id)
end

local function wanted(kinds)
  if not kinds then return Search.KINDS end
  if type(kinds) == "string" then return { kinds } end
  return kinds
end

-- One entry by kind and ID, or nil.
function Search.Get(kind, id)
  for _, e in ipairs(index(kind)) do
    if e.id == id then return e end
  end
  return nil
end

-- Every entry of `kinds` whose name (or alias) matches `text`, best first.
-- A link or ID finds that one thing when the data knows it (kind nil in
-- "#N": the first of `kinds` that has it).
function Search.Find(text, kinds)
  local kind, id = Search.Parse(text)
  local key = trim(text):lower()
  kinds = wanted(kinds)
  local out = {}
  if id then
    for _, k in ipairs(kind and { kind } or kinds) do
      if k == kind or kind == nil then
        local e = Search.Get(k, id)
        if e then
          local copy = {}
          for field, v in pairs(e) do copy[field] = v end
          copy.score = EXACT
          out[#out + 1] = copy
          if kind == nil then break end
        end
      end
    end
    return out
  end
  if key == "" then return out end
  for _, k in ipairs(kinds) do
    for _, e in ipairs(index(k)) do
      local score = rankOf(e, key)
      if score then
        local copy = {}
        for field, v in pairs(e) do copy[field] = v end
        copy.score = score
        out[#out + 1] = copy
      end
    end
  end
  table.sort(out, better)
  return out
end

-- The nearest NPC with a role ("repair", "flightMaster", "innkeeper"...)
-- friendly to you: { id, name, node, route } by travel time among the
-- CANDIDATES nearest in a straight line, or nil.
local CANDIDATES = 4

function Search.NearestNPC(role, start, net)
  local faction = UnitFactionGroup("player")
  local list = {}
  for _, e in ipairs(index("npc")) do
    if e.roles[role] and #e.nodes > 0 then
      local friendly
      if e.met then
        friendly = e.faction == nil or e.faction == faction or e.faction == "Neutral"
      else
        friendly = ns.Data.FriendlyTo(e.faction, faction)
      end
      if friendly then
        local node, distance = ns.Data.Nearest(e.nodes, start)
        if node and distance < math.huge then list[#list + 1] = { id = e.id, name = e.name, node = node, distance = distance } end
      end
    end
  end
  table.sort(list, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.name < b.name
  end)
  local best
  for i = 1, math.min(CANDIDATES, #list) do
    local c = list[i]
    local route = ns.Router.Plan(start, c.node, net)
    if route and (not best or route.seconds < best.route.seconds) then
      c.route = route
      best = c
    end
  end
  return best
end

---------------------------------------------------------------- shared rows

-- The label of an NPC's roles for a row ("Warlock Trainer", "Vendor, Repairs").
function Search.RoleText(e)
  if type(e.subName) == "string" and e.subName ~= "" then return e.subName end
  local parts = {}
  for _, role in ipairs(ROLES) do
    if e.roles and e.roles[role.key] then parts[#parts + 1] = ROLE_LABEL[role.key] end
  end
  return #parts > 0 and table.concat(parts, ", ") or nil
end

-- The "Add detour" action for a result row: puts its stops (a journey's open
-- stops, or a visit to its destination) into the journey you're on, or starts
-- one. Every page uses this one, so rows of every kind act the same.
function Search.DetourAction(row, label)
  return { label = "Add detour", run = function(r)
    r = r or row
    local stops = ns.Nav.StopsFor(r)
    if #stops == 0 then
      ns.print("no known places for " .. (label or r.title or "that") .. ".")
      return
    end
    local add = ns.Nav.AddDetour or ns.Nav.AddToTrip
    add(stops, label or r.title)
  end }
end

-- Puts "Add detour" first among a row's actions while a journey is on, for a
-- row that has somewhere to go. Returns the row.
function Search.WithDetour(row, label)
  -- Nothing to add when the journey already has it (the objective of a quest
  -- on it, the NPC it is heading for).
  if row and ns.Nav.active and (row.journey or (row.goal and row.route))
    and not (ns.Nav.JourneyHas and ns.Nav.JourneyHas(ns.Nav.StopsFor(row))) then
    row.actions = row.actions or {}
    table.insert(row.actions, 1, Search.DetourAction(row, label))
  end
  return row
end
