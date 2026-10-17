local _, ns = ...

-- "Vendors" category: the vendors a levelling character needs right now
-- (repairs, food & drink, class reagents, ammo), ranked by travel time.
-- Sources: vendors you visited (what they sold, whether they repair, recorded
-- at the merchant window) and QuestieDB when installed (ItemDB sellers of the
-- goods in Data/VendorGoods.lua, the NPC repair flag and English subtitles).

local Vendors = { id = "vendors", label = "Vendors" }
ns.Vendors = Vendors

local ROWS = 7              -- rows the panel shows
local CANDIDATES = 4        -- nearest vendors per need (straight line) that get a full route
local LOW_DURABILITY = 0.5  -- lowest item at or below this: repairs come first

local NEED_ORDER = { "repair", "food", "reagent", "ammo" }
local NEED_LABEL = { repair = "Repair", food = "Food & drink", reagent = "Reagents", ammo = "Ammo" }

-- Item classes from GetItemInfoInstant, for goods not in Data/VendorGoods.lua.
local ITEM_CLASS = { Consumable = 0, Weapon = 2, Reagent = 5, Projectile = 6 }
local FOOD_SUBCLASS = 5 -- Consumable: Food & Drink
local AMMO_BY_PROJECTILE = { [2] = "arrow", [3] = "bullet" }
local AMMO_BY_WEAPON = { [2] = "arrow", [18] = "arrow", [3] = "bullet" } -- bows, crossbows, guns

-- English QuestieDB subtitles (read with GetRaw, which skips localisation).
local SELLS_BY_SUBTITLE = {
  ["Food & Drink"] = { food = true }, ["Innkeeper"] = { food = true }, ["Baker"] = { food = true },
  ["Butcher"] = { food = true }, ["Fruit Vendor"] = { food = true }, ["Mushroom Vendor"] = { food = true },
  ["General Goods"] = { food = true }, ["General Supplies"] = { food = true },
  ["Reagents"] = { reagent = true }, ["Reagent Vendor"] = { reagent = true },
  ["Bowyer"] = { arrow = true }, ["Gunsmith"] = { bullet = true },
  ["Armorer"] = { repair = true }, ["Weaponsmith"] = { repair = true },
}

local GREEN = { r = 0.5, g = 0.82, b = 0.68 }
local GREY = { r = 0.6, g = 0.6, b = 0.6 }
local ORANGE = { r = 1, g = 0.5, b = 0.25 }

local summary

---------------------------------------------------------------- goods

local goodsByItem -- [itemID] = { need = "food"|"ammo"|"reagent", ammo = "arrow"|"bullet", entries }

local function goodsIndex()
  if goodsByItem then return goodsByItem end
  goodsByItem = {}
  local goods = ns.data.vendorGoods
  for _, e in ipairs(goods.food) do goodsByItem[e.id] = { need = "food" } end
  for ammo, list in pairs(goods.ammo) do
    for _, e in ipairs(list) do goodsByItem[e.id] = { need = "ammo", ammo = ammo } end
  end
  for _, list in pairs(goods.reagents) do
    for _, e in ipairs(list) do goodsByItem[e.id] = { need = "reagent" } end
  end
  return goodsByItem
end

local function itemInstant(itemID)
  local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not (fn and itemID) then return nil end
  local _, _, _, _, _, classID, subClassID = fn(itemID)
  return classID, subClassID
end

-- Category guess for a merchant item: "food", "arrow", "bullet", "reagent" or nil.
function Vendors.GoodsKind(itemID)
  local known = goodsIndex()[itemID]
  if known then return known.ammo or known.need end
  local classID, subClassID = itemInstant(itemID)
  if classID == ITEM_CLASS.Projectile then return AMMO_BY_PROJECTILE[subClassID] end
  if classID == ITEM_CLASS.Reagent then return "reagent" end
  if classID == ITEM_CLASS.Consumable and subClassID == FOOD_SUBCLASS then return "food" end
  return nil
end

local function itemName(e)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)
  if not name and GetItemInfo then name = GetItemInfo(e.id) end
  return name or e.name
end

-- The highest tier at or below your level in a list.
local function topTier(list, level)
  local top
  for _, e in ipairs(list) do
    if e.level <= level and (not top or e.level > top) then top = e.level end
  end
  return top
end

---------------------------------------------------------------- your needs

-- Lowest durability of any equipped item (0-1), or nil if nothing has any.
function Vendors.Durability()
  if not GetInventoryItemDurability then return nil end
  local lowest
  for slot = 1, 19 do
    local current, maximum = GetInventoryItemDurability(slot)
    if current and maximum and maximum > 0 then
      local ratio = current / maximum
      if not lowest or ratio < lowest then lowest = ratio end
    end
  end
  return lowest
end

-- GetInventorySlotInfo raises an error for slot names the client lacks.
local function slotItem(name)
  local ok, slot = pcall(GetInventorySlotInfo or error, name)
  if not (ok and slot) then return nil end
  return slot, GetInventoryItemID and GetInventoryItemID("player", slot)
end

-- Ammo your ranged weapon fires; hunters without one are shown both kinds.
local function ammoKinds(class)
  local _, weapon = slotItem("RangedSlot")
  local classID, subClassID = itemInstant(weapon)
  local kind = classID == ITEM_CLASS.Weapon and AMMO_BY_WEAPON[subClassID]
  if kind then return { [kind] = true } end
  if class == "HUNTER" then return { arrow = true, bullet = true } end
  return nil
end

-- What you need from vendors right now. `wanted` maps item IDs to the goods
-- worth buying at your level; `current` marks the best tier you can use.
function Vendors.Needs()
  local _, class = UnitClass("player")
  local level = UnitLevel("player")
  local goods = ns.data.vendorGoods
  local p = { level = level, class = class, wanted = {}, needs = { repair = true, food = true } }

  p.durability = Vendors.Durability()
  p.urgent = p.durability ~= nil and p.durability <= LOW_DURABILITY

  local function want(e, need, top)
    if e.level <= level then
      p.wanted[e.id] = { id = e.id, name = e.name, level = e.level, need = need,
        current = top == nil or e.level == top }
    end
  end

  p.foodTier = topTier(goods.food, level)
  for _, e in ipairs(goods.food) do want(e, "food", p.foodTier) end

  p.ammo = ammoKinds(class)
  if p.ammo then
    p.needs.ammo = true
    for kind in pairs(p.ammo) do
      local top = topTier(goods.ammo[kind], level)
      for _, e in ipairs(goods.ammo[kind]) do want(e, "ammo", top) end
    end
    local slot = slotItem("AmmoSlot")
    p.ammoCount = slot and GetInventoryItemCount and GetInventoryItemCount("player", slot)
  end

  p.reagents = {}
  for _, e in ipairs(goods.reagents[class] or {}) do
    if e.level <= level then
      want(e, "reagent")
      p.reagents[#p.reagents + 1] = e
      p.needs.reagent = true
    end
  end
  return p
end

---------------------------------------------------------------- recording

local function merchantItemID(index)
  local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and C_MerchantFrame.GetItemInfo(index)
  if type(info) == "table" and info.itemID then return info.itemID end
  local id = GetMerchantItemID and GetMerchantItemID(index)
  if id then return id end
  local link = GetMerchantItemLink and GetMerchantItemLink(index)
  return link and tonumber(link:match("item:(%d+)"))
end

-- Stores item IDs, a category guess and whether the vendor repairs.
local function readMerchant()
  local n = GetMerchantNumItems and GetMerchantNumItems() or 0
  local goods, sells = {}, {}
  for i = 1, n do
    local itemID = merchantItemID(i)
    if itemID then
      goods[#goods + 1] = itemID
      local kind = Vendors.GoodsKind(itemID)
      if kind then sells[kind] = true end
    end
  end
  local repairs = CanMerchantRepair and CanMerchantRepair() and true or false
  if #goods == 0 and not repairs then return end
  ns.Harvest.RecordNPC("vendor", { goods = goods, sells = sells, repairs = repairs })
end

-- The item list can still be empty at MERCHANT_SHOW; read again shortly after.
ns.On("MERCHANT_SHOW", function()
  readMerchant()
  C_Timer.After(0.5, readMerchant)
end)
ns.On("UPDATE_INVENTORY_DURABILITY", function() ns.Fire("DATA_CHANGED") end)

---------------------------------------------------------------- QuestieDB

local npcScan       -- [npcID] = { repairs, sells } from flags and subtitles
local sellersCache = {}
local npcCache = {}

-- Masks can exceed 32 bits, so test bits arithmetically.
local function hasBit(mask, bit)
  return bit ~= nil and bit > 0 and math.floor(mask / bit) % 2 == 1
end

local function friendlyTo(friendly, faction)
  if friendly == nil or friendly == "" then return true end
  return friendly:find(faction == "Alliance" and "A" or "H", 1, true) ~= nil
end

local function now()
  return debugprofilestop and debugprofilestop() or 0
end

-- One scan per session, like the trainer scan in QuestieBridge.lua.
local function scanNpcs()
  npcScan = {}
  local started = now()
  local flags = LibQuestieDB.Enum.npcFlags or {}
  for _, id in ipairs(NpcDB.GetAllIds()) do
    local f = NpcDB.Get(id, "npcFlags") or 0
    if f ~= 0 and (hasBit(f, flags.VENDOR) or hasBit(f, flags.REPAIR)) then
      local sells = SELLS_BY_SUBTITLE[NpcDB.GetRaw(id, "subName") or ""]
      local repairs = hasBit(f, flags.REPAIR) or (flags.REPAIR == nil and sells and sells.repair)
      if repairs or sells then npcScan[id] = { repairs = repairs or nil, sells = sells } end
    end
  end
  ns.debugTimings = ns.debugTimings or {}
  ns.debugTimings.questieVendors = now() - started
end

local function itemSellers(itemID)
  if sellersCache[itemID] == nil then
    local keys = LibQuestieDB.Meta and LibQuestieDB.Meta.ItemMeta and LibQuestieDB.Meta.ItemMeta.itemKeys
    local items = LibQuestieDB.Item or ItemDB
    local sellers
    if keys and keys.vendors and items then
      local ok, value = pcall(items.Get, itemID, "vendors")
      sellers = ok and type(value) == "table" and value or nil
    end
    sellersCache[itemID] = sellers or false
  end
  return sellersCache[itemID] or {}
end

local function npcInfo(id)
  if npcCache[id] == nil then
    local name = NpcDB.Get(id, "name")
    npcCache[id] = name and {
      name = name,
      friendly = NpcDB.Get(id, "friendlyToFaction"),
      nodes = ns.Questie.SpawnNodes(NpcDB.Get(id, "spawns"), name),
    } or false
  end
  return npcCache[id] or nil
end

-- { [npcID] = { name, node, goods = {[itemID] = true}, sells, repairs } } for your faction.
local function questieVendors(p, faction, here)
  local out = {}
  if not ns.Questie.Available() then return out end
  if not npcScan then scanNpcs() end
  local function add(id)
    if out[id] == nil then
      local info = npcInfo(id)
      local node = info and friendlyTo(info.friendly, faction) and ns.Questie.Nearest(info.nodes, here)
      out[id] = node and { name = info.name, node = node, goods = {}, sells = {} } or false
    end
    return out[id] or nil
  end
  for itemID in pairs(p.wanted) do
    for _, id in ipairs(itemSellers(itemID)) do
      local v = add(id)
      if v then v.goods[itemID] = true end
    end
  end
  for id, s in pairs(npcScan) do
    local v = add(id)
    if v then
      v.repairs = s.repairs
      for kind in pairs(s.sells or {}) do v.sells[kind] = true end
    end
  end
  for id, v in pairs(out) do
    if not v then out[id] = nil end
  end
  return out
end

---------------------------------------------------------------- ranking

-- What a vendor does for you: { [need] = { items, current, guess } }.
local function coverage(v, p)
  local c = {}
  if v.repairs then c.repair = { items = {}, current = true } end
  for itemID in pairs(v.goods) do
    local w = p.wanted[itemID]
    if w then
      local cover = c[w.need]
      if not cover or cover.guess or w.level > cover.level then
        c[w.need] = { items = { w }, level = w.level, current = w.current }
      elseif w.level == cover.level then
        table.insert(cover.items, w)
      end
    end
  end
  local function guess(need, kind)
    if p.needs[need] and v.sells[kind] and not c[need] then c[need] = { items = {}, guess = true } end
  end
  guess("food", "food")
  guess("reagent", "reagent")
  for kind in pairs(p.ammo or {}) do guess("ammo", kind) end
  return c
end

local function seconds(r)
  return r.route and r.route.seconds or math.huge
end

local function itemList(cover)
  table.sort(cover.items, function(a, b) return a.id < b.id end)
  local names = {}
  for _, w in ipairs(cover.items) do names[#names + 1] = itemName(w) end
  return table.concat(names, ", ")
end

local function detailLines(c, p, visited, known)
  local lines = {}
  for _, need in ipairs(NEED_ORDER) do
    local cover = c[need]
    if cover then
      local text, color
      if need == "repair" then
        text, color = "Repairs your gear", p.urgent and ORANGE or GREEN
      elseif cover.guess then
        text, color = "Sells " .. NEED_LABEL[need]:lower(), GREY
      else
        text = NEED_LABEL[need] .. ": " .. itemList(cover)
        if need ~= "reagent" then
          text = text .. string.format(" (level %d%s)", cover.level, cover.current and "" or ", older tier")
        end
        color = cover.current and GREEN or GREY
      end
      lines[#lines + 1] = { text = text, color = color }
    end
  end
  if visited and not known then
    lines[#lines + 1] = { text = "Visit once more to record what they sell", color = GREY }
  end
  return lines
end

local function titleFor(name, c, p)
  local labels = {}
  for _, need in ipairs(NEED_ORDER) do
    if c[need] then
      local label = NEED_LABEL[need]
      if need == "repair" and p.urgent then label = "|cffff7f3f" .. label .. "|r" end
      labels[#labels + 1] = label
    end
  end
  if #labels == 0 then return name end
  return name .. "  ·  " .. table.concat(labels, ", ")
end

local function durabilityText(p)
  if not p.durability or p.durability >= 1 then return nil end
  if p.durability <= 0 then return "|cffff4040Some of your gear is broken: repair first.|r" end
  local percent = math.floor(p.durability * 100 + 0.5)
  if p.urgent then return string.format("|cffff7f3fGear at %d%%: repair soon.|r", percent) end
  return string.format("Gear at %d%%", percent)
end

local function summaryText(p)
  local parts = { durabilityText(p) }
  if p.foodTier then parts[#parts + 1] = string.format("Food & drink: level %d", p.foodTier) end
  if #p.reagents > 0 then
    local names = {}
    for _, e in ipairs(p.reagents) do names[#names + 1] = itemName(e) end
    parts[#parts + 1] = "Reagents: " .. table.concat(names, ", ")
  end
  if p.ammo then
    local count = type(p.ammoCount) == "number" and p.ammoCount > 0
      and string.format(" (%d left)", math.floor(p.ammoCount)) or ""
    parts[#parts + 1] = "Ammo" .. count
  end
  return table.concat(parts, " · ")
end

function Vendors.SummaryText()
  return summary or summaryText(Vendors.Needs())
end

function Vendors.EmptyText()
  return "No vendors known yet. Talk to any vendor once and Wayfinder remembers where they are and what "
    .. "they sell, or install QuestieDB."
end

-- Results: one row per vendor, labelled with what it does for you. The
-- fastest vendor for each need is always listed; the rest fill by travel time.
function Vendors.Results()
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()
  local p = Vendors.Needs()
  local faction = UnitFactionGroup("player")
  summary = summaryText(p)

  local vendors = questieVendors(p, faction, start)
  -- Visited vendors: positions and goods measured in Forever win over QuestieDB.
  for id, npc in pairs(ns.Harvest.AllNPCs()) do
    local friendly = npc.faction == nil or npc.faction == faction or npc.faction == "Neutral"
    if npc.kinds.vendor and friendly then
      local node = ns.Geo.Node(npc.mapID, npc.x, npc.y, npc.name)
      if node then
        local v = vendors[id] or { goods = {}, sells = {} }
        v.known = npc.goods ~= nil or vendors[id] ~= nil
        v.name, v.node, v.visited = npc.name, node, true
        for _, itemID in ipairs(npc.goods or {}) do v.goods[itemID] = true end
        for kind in pairs(npc.sells or {}) do v.sells[kind] = true end
        if npc.repairs ~= nil then v.repairs = npc.repairs or nil end
        vendors[id] = v
      end
    end
  end

  -- Candidates per need by straight-line distance; only those get a route.
  local list = {}
  for id, v in pairs(vendors) do
    v.id, v.covers = id, coverage(v, p)
    v.distance = ns.Geo.Distance(start, v.node)
    if next(v.covers) or (v.visited and not v.known) then list[#list + 1] = v end
  end
  table.sort(list, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.id < b.id
  end)
  local routed = {}
  local function pick(test)
    local n = 0
    for _, v in ipairs(list) do
      if n >= CANDIDATES then return end
      if test(v) then
        routed[v] = true
        n = n + 1
      end
    end
  end
  for need in pairs(p.needs) do
    pick(function(v) return v.covers[need] and v.covers[need].current end)
    pick(function(v) return v.covers[need] ~= nil end)
  end
  pick(function(v) return v.visited and not v.known end)

  local results = {}
  for v in pairs(routed) do
    results[#results + 1] = {
      id = v.id,
      title = titleFor(v.name, v.covers, p),
      zone = ns.MapName(v.node.mapID),
      goal = v.node,
      route = ns.Router.Plan(start, v.node, net),
      details = detailLines(v.covers, p, v.visited, v.known),
      covers = v.covers,
    }
  end
  table.sort(results, function(a, b)
    if seconds(a) ~= seconds(b) then return seconds(a) < seconds(b) end
    return a.id < b.id
  end)

  -- Keep the fastest vendor per need (current tier first), fill the rest by time.
  local keep, kept = {}, 0
  local function fastest(test)
    for _, r in ipairs(results) do
      if test(r) then return r end
    end
  end
  for _, need in ipairs(NEED_ORDER) do
    if p.needs[need] then
      local best = fastest(function(r) return r.covers[need] and r.covers[need].current end)
        or fastest(function(r) return r.covers[need] ~= nil end)
      if best and not keep[best] then
        keep[best] = true
        kept = kept + 1
      end
      if need == "repair" then p.repairResult = best end
    end
  end
  for _, r in ipairs(results) do
    if kept >= ROWS then break end
    if not keep[r] then
      keep[r] = true
      kept = kept + 1
    end
  end
  local out = {}
  for _, r in ipairs(results) do
    if keep[r] then out[#out + 1] = r end
  end

  -- Damaged gear: the fastest repair goes to the top.
  if p.urgent and p.repairResult and out[1] ~= p.repairResult then
    for i, r in ipairs(out) do
      if r == p.repairResult then
        table.remove(out, i)
        table.insert(out, 1, r)
        break
      end
    end
  end
  return out, nil, net
end
