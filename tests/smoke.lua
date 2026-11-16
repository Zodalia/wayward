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
strsplit = function(sep, s) local r = {} for p in (s .. sep):gmatch("(.-)%" .. sep) do r[#r + 1] = p end return (table.unpack or unpack)(r) end
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
C_QuestHub = { GetHubsForMap = function(mapID) assert(mapID, "needs map"); return { { name = "Auberdine", x = 0.37, y = 0.44 } } end,
  AcceptSomething = function() error("explorer must not call non-read functions") end }
C_GameRules = { GetForeverExperiencePreset = function() return 2 end }
C_TaxiMap.GetAllTaxiNodes = function() return { { name = "Auberdine", position = vec(0.42, 0.25) } } end
GetPlayerFacing = function() return 1.5708 end
C_CVar = { GetCVar = function(name) return ({ showInGameNavigation = "0", questPOI = "0", foreverQuestHelpers = "1" })[name] end }
ConsoleGetAllCommands = function() return { { command = "foreverQuestHelpers" }, { command = "gxMaxFPS" } } end
C_SuperTrack = { IsSuperTrackingUserWaypoint = function() return true end }
EJ_GetNumTiers = function() return 1 end
EJ_GetCurrentTier = function() return 0 end
EJ_GetTierInfo = function() return "Classic" end
EJ_SelectTier = function(i) if i == 0 then error("Usage: EJ_SelectTier(index) Invalid index 0") end end
EJ_GetInstanceByIndex = function(i, isRaid) if i == 1 then return isRaid and 741 or 227, isRaid and "Molten Core" or "Blackfathom Deeps" end end
GetMerchantNumItems =function() return 2 end
GetMerchantItemInfo = function(i) return "Item" .. i, nil, 100, 1, -1, true end

local ns = {}
-- Addon messages loop straight back, except past 255 bytes and past ten in a row.
local fire
local sends = 0
Enum.SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, InvalidMessage = 5 }
C_ChatInfo = {
  RegisterAddonMessagePrefix = function() registered = (registered or 0) + 1; return registered > 1 and 1 or 0 end,
  SendAddonMessage = function(prefix, text, channel, target)
    -- A whisper only arrives under both names; the send succeeds either way.
    if channel == "WHISPER" and target ~= "Tester Smith" then return 0 end
    if #text > 255 then return 5 end
    sends = sends + 1
    if sends > 10 then return 3 end
    fire("CHAT_MSG_ADDON", prefix, text, channel, "Tester-Forever")
    return 0
  end,
}
-- Forever's own controller navigation, and the client's packing of tables.
SmartNavigationMixin = { RegisterFrame = function() end, SetFocus = function() end }
C_InputInterfaceStyle = { GetCurrentStyle = function() return 1 end }
C_EncodingUtil = {
  SerializeCBOR = function(t) packed = t; return string.rep("c", 120) end,
  DeserializeCBOR = function() return packed end,
  CompressString = function(s) return s:sub(1, 60) end,
  DecompressString = function() return string.rep("c", 120) end,
  EncodeBase64 = function(s) return s .. s:sub(1, 20) end,
  DecodeBase64 = function(s) return s:sub(1, 60) end,
}
Enum.RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1 }
UnitFullName = function() return "Tester", "Smith" end
GetNormalizedRealmName = function() return "Forever" end
C_GamePad = { IsEnabled = function() return true end, SetVibration = function() error("probe must not call setters") end }
UIParent = {}

for _, f in ipairs({ "Core.lua", "Serialize.lua", "Probes.lua", "PadComms.lua", "Events.lua", "Export.lua" }) do
  assert(loadfile(dir .. "/" .. f))("WFProbe", ns)
end

function fire(event, ...)
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
SlashCmdList.WFPROBE("nav")
-- Nameplates: one readable, one with a secret GUID and death state.
C_NamePlate = { GetNamePlates = function()
  return { { namePlateUnitToken = "nameplate1" }, { namePlateUnitToken = "nameplate2" } }
end }
local plainGUID = UnitGUID
UnitGUID = function(u) if u == "nameplate2" then return SECRET end return plainGUID(u) end
UnitIsDead = function(u) if u == "nameplate2" then return SECRET end return false end
InCombatLockdown = function() return true end
SlashCmdList.WFPROBE("plates")
InCombatLockdown = function() return false end
-- Controller: the listening frame gets a button, then its time runs out.
SlashCmdList.WFPROBE("pad")
for _, f in ipairs(frames) do
  if f.scripts.OnGamePadButtonDown then f.scripts.OnGamePadButtonDown(f, "PADDUP") end
end
runTimers()
-- Addon messages: sent, looped back, counted.
SlashCmdList.WFPROBE("comms")
runTimers()
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
assert(text:find("Blackfathom Deeps"), "encounter journal tiers lost")
assert(text:find('calls = "a_none=error b_zone=ok%(table:1%)'), "explorer did not record calls")
assert(not text:find("AcceptSomething"), "explorer touched a non-read function")
assert(text:find("preset = {"), "experience preset missing")
assert(not ns.serialize({ position = vec(1, 2) }):find("GetXY"), "function fields not skipped")
assert(text:find("diagManual"), "nav diag not stored")
assert(text:find("playerFacingIsSecret = false"), "facing check missing")
assert(text:find('foreverQuestHelpers = "1"'), "discovered cvar missing")
assert(not text:find("gxMaxFPS"), "unrelated cvar included")
assert(text:find('questPOI = "0"'), "known cvar missing")
assert(text:find('guid = "secret"') and text:find('isDead = "secret"') and text:find("npcID = 6741"),
  "nameplate facts missing")
assert(text:find("inCombat = true"), "plate snapshot doesn't say it was in combat")
assert(text:find("gamepadAPI = true"), "gamepad headline missing")
assert(text:find("PADDUP = 1"), "controller button not captured")
assert(text:find("an addon frame received controller buttons"), "pad verdict missing")
assert(text:find('whisper 1 to \\"Tester\\" %-> Success'), "addon message send result missing")
assert(text:find('whisperName = "Tester Smith"'), "the name a whisper reaches wasn't found")
assert(text:find('UnitFullName = "Tester \\124 Smith"'), "name facts missing")
assert(text:find('"256 bytes %-> InvalidMessage"'), "over-long message result missing")
assert(text:find("AddonMessageThrottle"), "throttle result missing")
assert(text:find("receivedCount = 10"), "looped-back messages not counted")
assert(text:find("SmartNavigationMixin = {") and text:find('functions = "RegisterFrame, SetFocus"'), "smart navigation mixin not listed")
assert(text:find("smartNavigationTables = 2"), "smart navigation headline missing")
assert(text:find("roundTrip = true") and text:find("base64 = 80"), "encoding round trip missing")
assert(text:find('registerPrefix = "DuplicatePrefix"'), "prefix registration not read in its own codes")
assert(text:find("arrived intact"), "binary message not checked")
io.write("SMOKE OK\n")
