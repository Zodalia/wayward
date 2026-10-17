-- Minimal WoW API stubs to execute WFProbe's own logic outside the game.
-- Checks our code paths only, not real Forever API behaviour.
-- Usage (from repo root): lua tests/smoke.lua
local dir = arg[1] or "WFProbe"
local frames, timers, out = {}, {}, {}

local function newObj()
  local o = { scripts = {}, events = {} }
  return setmetatable(o, { __index = function(t, k)
    return function(self, ...)
      if k == "SetScript" then local name, fn = ...; self.scripts[name] = fn
      elseif k == "RegisterEvent" then
        local ev = ...
        if ev == "QUESTLINE_UPDATE" then error("Attempt to register unknown event") end
        self.events[ev] = true
      elseif k == "SetText" then self.text = ...
      elseif k == "GetText" then return self.text
      elseif k == "IsShown" then return self.shown
      elseif k == "Show" then self.shown = true
      elseif k == "Hide" then self.shown = false
      elseif k == "CreateFontString" then return newObj()
      end
    end
  end })
end

CreateFrame = function() local f = newObj(); frames[#frames + 1] = f; return f end
print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
date, time = os.date, os.time
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
UISpecialFrames = {}
ChatFontNormal = {}
strsplit = function(sep, s) local r = {} for p in (s .. sep):gmatch("(.-)%" .. sep) do r[#r + 1] = p end return table.unpack(r) end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
SlashCmdList = {}
InCombatLockdown = function() return false end

local SECRET = setmetatable({}, { __tostring = function() error("secret!") end })
issecretvalue = function(v) return v == SECRET end
UnitHealth = function() return SECRET end

GetBuildInfo = function() return "1.60.1", "70291", "Oct 8 2026", 16001 end
WOW_PROJECT_ID = 99
UnitName = function(u) if u == "npc" then return "Innkeeper Bob" end return "Tester" end
GetRealmName = function() return "Forever" end
UnitGUID = function() return "Creature-0-1-2-3-6741-0000" end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitRace = function() return "Human", "Human", 1 end
UnitLevel = function() return 12 end
UnitFactionGroup = function() return "Alliance" end
GetMoney = function() return 12345 end

Enum = {
  UIMapType = { Continent = 2, Zone = 3 },
  BagIndex = { Backpack = 0, Bag_1 = 1, Bank = -1 },
  SpellBookSpellBank = { Player = 0 },
  SpellBookItemType = { Spell = 1, FutureSpell = 2 },
  PlayerInteractionType = { Merchant = 5 },
}

local vec = function(x, y) return { x = x, y = y, GetXY = function(s) return s.x, s.y end } end
C_Map = {
  GetBestMapForUnit = function() return 1429 end,
  GetMapInfo = function(id)
    if id == 1429 then return { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 } end
    if id == 1415 then return { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 0 } end
  end,
  GetPlayerMapPosition = function() return vec(0.42, 0.65) end,
  GetWorldPosFromMapPos = function() return 0, vec(-9000.5, 120.25) end,
  GetMapChildrenInfo = function() return { { mapID = 1429, name = "Elwynn Forest" }, { mapID = 1426, name = "Dun Morogh" } } end,
  CanSetUserWaypointOnMap = function() return true end,
  SetUserWaypoint = function() end,
}
C_TaxiMap = { GetTaxiNodesForMap = function() return { { nodeID = 2, name = "Stormwind", state = 0, position = vec(0.1, 0.2) } } end }
C_QuestLog = {
  GetNumQuestLogEntries = function() return 2 end,
  GetInfo = function(i) if i == 1 then return { isHeader = true, title = "Elwynn" } end
    return { questID = 33, title = "Wolves Across the Border", level = 6, isComplete = false } end,
  GetNextWaypoint = function() return 1429, 0.5, 0.5 end,
  GetQuestObjectives = function() return { { text = "Wolf Meat 0/8", finished = false } } end,
  GetAllCompletedQuestIDs = function() return { 1, 2, 3 } end,
  IsQuestFlaggedCompleted = function() return false end,
}
C_QuestLine = { RequestQuestLinesForMap = function() end,
  GetAvailableQuestLines = function() return { { questLineName = "Riverpaw", questName = "Bounty", questID = 46, x = 0.3, y = 0.4 } } end }
C_Container = {
  GetContainerNumSlots = function(bag) return bag <= 1 and 4 or 0 end,
  GetContainerItemInfo = function(bag, slot) if slot == 1 then return { itemID = 6948, stackCount = 1, quality = 1 } end end,
}
GetInventorySlotInfo = function(name) if name == "AmmoSlot" or name == "RangedSlot" then error("Invalid inventory slot") end return 5 end
GetInventoryItemLink = function(_, slot) return "|cffffffff|Hitem:2361::::|h[Battleworn Hammer]|h|r" end
C_Item = { GetItemInfo = function() return "Battleworn Hammer", nil, 1, 2, 1, "Weapon", "Two-Handed Maces", 1, "INVTYPE_2HWEAPON" end,
  GetDetailedItemLevelInfo = function() return 2 end }
GetProfessions = function() return nil, nil, nil, 4, 5 end
GetProfessionInfo = function(i) return i == 4 and "Fishing" or "Cooking", nil, 1, 75 end
GetMerchantItemLink = function() return "|cffffffff|Hitem:159::::|h[Refreshing Spring Water]|h|r" end
GetMerchantNumItems = function() return 2 end
GetMerchantItemInfo = function(i) return "Item" .. i, nil, 100, 1, -1, true end

local ns = {}
for _, f in ipairs({ "Core.lua", "Serialize.lua", "Probes.lua", "Events.lua", "Export.lua" }) do
  assert(loadfile(dir .. "/" .. f))("WFProbe", ns)
end

local function fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end

fire("ADDON_LOADED", "WFProbe")
fire("PLAYER_ENTERING_WORLD", true, false)
SlashCmdList.WFPROBE("")
runTimers()
fire("MERCHANT_SHOW")
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
fire("QUEST_ACCEPTED", 33)
SlashCmdList.WFPROBE("waypoint")
runTimers()
SlashCmdList.WFPROBE("show")

for _, line in ipairs(out) do io.write("[chat] ", line, "\n") end
local text
for _, f in ipairs(frames) do local t = rawget(f, "text"); if type(t) == "string" and #t > 200 then text = t end end
assert(text, "no export text produced")
io.write("\nexport length: ", #text, " chars\n\n", text, "\n...\n")
assert(text:find("Wolves Across the Border"), "quest missing from export")
assert(text:find("\\124Hitem"), "pipe not escaped")
assert(text:find("playerHealthIsSecret = true"), "secret flag missing"); assert(ns.serialize({ hp = SECRET }):find("<secret table>"), "secret not marked")
assert(text:find('AmmoSlot = "<no such slot>"'), "slot error not captured")
io.write("SMOKE OK\n")
