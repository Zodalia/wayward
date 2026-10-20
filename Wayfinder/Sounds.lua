local _, ns = ...

-- Wayfinder's sounds: one for each moment below, picked from a shortlist of
-- the game's own sound kits. Every kit here is in Forever's sound tables
-- (build 1.60.1.70450), and most are ones its own UI plays.
--   /wf sounds                       the moments and their sounds
--   /wf sounds <moment>              a moment's shortlist
--   /wf sounds <moment> <n|next>     plays one, to compare
--   /wf sounds use <moment> <n|off|default>   keeps one (for the account)
--   /wf sounds test <moment> [n]     the real banner, toast or question, with
--                                    sample text, and its sound (or sound n)

local Sounds = {}
ns.Sounds = Sounds

-- { kit, name shown, what it is }; the first is the default. A kit is a
-- sound kit ID (the game's SOUNDKIT name shown when it has one), or "race".
local MOMENTS = {
  { key = "popup", label = "the question when you pick up a quest or a chain continues", options = {
    { 23404, "UI_AUTO_QUEST_COMPLETE", "the quest tracker's \"!\" popup" },
    { 43936, "UI_QUEST_ROLLING_FORWARD_01", "a new objective rolling into the tracker" },
    { 7355, "TUTORIAL_POPUP", "a short text ping" },
    { 3093, "IG_WRITE_QUEST", "quill scribble" },
    { 3175, "MAP_PING", "minimap ping" },
    { 618, "#618", "the vanilla quest chime" },
  } },
  { key = "step", label = "a stop added to your trip", options = {
    { 206497, "UI_PROFESSION_TRACK_RECIPE_CHECKBOX", "tiny tick, the quietest" },
    { 856, "IG_MAINMENU_OPTION_CHECKBOX_ON", "the same tick, louder (every checkbox)" },
    { 62538, "UI_TRANSMOG_ITEM_CLICK", "the same tick, louder still" },
    { 170272, "UI_MAP_WAYPOINT_CONTROL_CLICK", "map table click" },
    { 73276, "UI_WORLDQUEST_MAP_SELECT", "selecting a world quest on the map" },
    { 207765, "UI_CLASS_TALENT_NODE_SPEND", "soft talent-point click" },
    { 44319, "UI_GARRISON_COMMAND_TABLE_ASSIGN_FOLLOWER", "slotting a follower in" },
    { 838, "IG_ABILITY_ICON_DROP", "a spell dropped on the action bar" },
    { 852, "IG_MAINMENU_OPTION", "the standard button click" },
    { 841, "IG_CHARACTER_INFO_TAB", "tab click" },
    { 1212, "PUT_DOWN_SMALL_CHAIN", "item put-down jingle" },
    { 170266, "UI_MAP_WAYPOINT_BUTTON_CLICK_ON", "mechanical gear ka-chunk" },
    { 836, "IG_ABILITY_PAGE_TURN", "spellbook page turn" },
    { 43936, "UI_QUEST_ROLLING_FORWARD_01", "a new objective rolling into the tracker" },
    { 3093, "IG_WRITE_QUEST", "quill scribble" },
  } },
  { key = "start", label = "a trip or directions started", options = {
    { 44323, "UI_GARRISON_COMMAND_TABLE_MISSION_START", "a mission sent off" },
    { 73275, "UI_WORLDQUEST_START", "world quest banner swell" },
    { 231912, "CONTENT_TRACKING_OBJECTIVE_TRACKING_START", "starting to track something" },
    { 45142, "UI_BONUS_EVENT_SYSTEM_VIGNETTES", "bonus objective banner" },
    { 25478, "UI_BATTLEGROUND_COUNTDOWN_FINISHED", "battleground gates open" },
    { 809, "GS_CHARACTER_SELECTION_ENTER_WORLD", "Enter World" },
    { 278769, "UI_EVENT_SCHEDULER_CHIME", "gentle chime" },
    { 25716, "UI_ETHEREAL_WINDOW_OPEN", "magical shimmer" },
    { 273123, "WOWLABS_AREA_CONFIRM_SELECTION", "drop zone confirmed on the map" },
    { 167517, "UI_CHROMIE_TIME_SELECT_EXPANSION", "soft magical ring" },
    { 875, "IG_QUEST_LIST_OPEN", "quest log opening" },
    { 170270, "UI_MAP_WAYPOINT_SUPER_TRACK_ON", "map waypoint tracked (quiet)" },
    { 1519, "#1519", "new flight path discovered" },
    { "race", "#4140-4147", "your race's exploration sting" },
  } },
  { key = "complete", label = "the \"Journey complete!\" banner", options = {
    { 44330, "UI_GARRISON_COMMAND_TABLE_MISSION_SUCCESS_STINGER", "mission success stinger" },
    { 218518, "TRADING_POST_UI_COMPLETED_ACTIVITY", "Traveler's Log activity done" },
    { 73277, "UI_WORLDQUEST_COMPLETE", "world quest complete" },
    { 43502, "UI_GARRISON_MISSION_COMPLETE_MISSION_SUCCESS", "mission success" },
    { 165974, "UI_ADVENTURES_ADVENTURE_SUCCESS_COMPLETE", "adventure success" },
    { 44294, "UI_GARRISON_TOAST_MISSION_COMPLETE", "mission complete toast" },
    { 44332, "UI_GARRISON_COMMAND_TABLE_CHEST_UNLOCK_GOLD_SUCCESS", "gold reward chest" },
    { 38326, "UI_DIG_SITE_COMPLETION_TOAST", "dig site done" },
    { 72548, "UI_MISSION_200_PERCENT", "mission chance hits 200%" },
    { 31757, "UI_SCENARIO_STAGE_END", "small stage-complete chime" },
    { 72978, "UI_70_BOOST_THANKSFORPLAYING_SMALLER", "soft sting" },
    { 54127, "UI_70_ARTIFACT_FORGE_TRAIT_FINALRANK", "trait unlocked" },
    { 218238, "TRADING_POST_UI_REWARD_TIER_COMPLETE", "Traveler's Log reward tier (big)" },
    { 33338, "UI_CHALLENGES_NEW_RECORD", "challenge mode new record (big)" },
    { 31754, "UI_SCENARIO_ENDING", "scenario complete (big)" },
    { 17316, "LFG_REWARDS", "dungeon finder rewards (big)" },
    { 50111, "UI_RAID_BOSS_DEFEATED", "boss defeated (the biggest)" },
    { 74702, "UI_MISSION_SUCCESS_CHEERS", "a crowd cheering" },
    { 878, "IG_QUEST_LIST_COMPLETE", "quest hand-in (the old sound)" },
  } },
  { key = "toast", label = "the \"New journey available\" toast", options = {
    { 878, "IG_QUEST_LIST_COMPLETE", "quest hand-in" },
    { 73280, "UI_ORDERHALL_TALENT_READY_TOAST", "research ready toast" },
    { 73919, "UI_PROFESSIONS_NEW_RECIPE_LEARNED_TOAST", "recipe learned toast" },
    { 44296, "UI_GARRISON_TOAST_FOLLOWER_GAINED", "follower gained toast" },
    { 7355, "TUTORIAL_POPUP", "a short text ping" },
    { 23404, "UI_AUTO_QUEST_COMPLETE", "the quest tracker's \"!\" popup" },
    { 18019, "UI_BNET_TOAST", "Battle.net toast (also friends coming online)" },
    { 1519, "#1519", "new flight path discovered" },
  } },
}

-- The exploration stings, by race file name.
local RACE_KITS = { Human = 4140, Orc = 4141, Scourge = 4142, Tauren = 4143, Troll = 4144, NightElf = 4145,
  Gnome = 4146, Dwarf = 4147 }

local function find(key)
  for _, m in ipairs(MOMENTS) do
    if m.key == key then return m end
  end
end

-- The sound kit ID for a kit, or nil.
local function kitID(kit)
  if kit == "race" then
    local race = UnitRace and select(2, UnitRace("player"))
    return RACE_KITS[race] or RACE_KITS.Human
  end
  return kit or nil
end

-- A moment's chosen kit: the saved one, else the default; false when off.
local function chosen(m)
  local saved = ns.db and ns.db.settings.sounds and ns.db.settings.sounds[m.key]
  if saved == false then return false end
  return saved or m.options[1][1]
end

local function current(m)
  local kit = chosen(m)
  for i, o in ipairs(m.options) do
    if o[1] == kit then return i end
  end
end

local function describe(m, i)
  local o = m.options[i]
  return string.format("%d. %s - %s", i, o[2], o[3])
end

-- A moment's shortlist ({ kit, name, what it is }), for the tests.
function Sounds.Options(key)
  local m = find(key)
  return m and m.options or {}
end

-- The sound kit a moment plays, or nil when it's off.
function Sounds.Kit(key)
  local m = find(key)
  return m and kitID(chosen(m))
end

-- Plays a moment's sound, or `kit` instead (to try one).
function Sounds.Play(key, kit)
  local id = kitID(kit) or Sounds.Kit(key)
  if id and PlaySound then pcall(PlaySound, id) end
end

---------------------------------------------------------------- /wf sounds

local cursor = {} -- [moment] = the one last tried, for "next"

local function usage()
  ns.print("/wf sounds <moment> <n|next> plays one; /wf sounds use <moment> <n|off|default> keeps it; "
    .. "/wf sounds test <moment> [n] shows it. Moments: popup, step, start, complete, toast.")
end

local function overview()
  for _, m in ipairs(MOMENTS) do
    local i = current(m)
    local now = chosen(m) == false and "off" or i and describe(m, i) or ("#" .. tostring(chosen(m)))
    ns.print(string.format("%s (%s): %s", m.key, m.label, now))
  end
  ns.print("/wf sounds <moment> lists its choices.")
  usage()
end

local function list(m)
  ns.print(m.key .. " - " .. m.label .. ":")
  local now = current(m)
  for i in ipairs(m.options) do
    ns.print((i == now and "|cff7fd1ae> " or "  ") .. describe(m, i) .. (i == now and " (now)|r" or ""))
  end
end

-- The option numbered `n` (a word from the command), or nil after saying why.
local function pick(m, n)
  local i = tonumber(n)
  if i and m.options[i] then return i end
  ns.print(string.format("%s has sounds 1 to %d (/wf sounds %s lists them)", m.key, #m.options, m.key))
end

local function try(m, n)
  local i = pick(m, n)
  if not i then return end
  cursor[m.key] = i
  Sounds.Play(m.key, m.options[i][1])
  ns.print(string.format("%s %s  (keep it: /wf sounds use %s %d)", m.key, describe(m, i), m.key, i))
end

local function use(m, n)
  local sounds = ns.db.settings.sounds or {}
  if n == "off" then
    sounds[m.key] = false
  elseif n == "default" then
    sounds[m.key] = nil
  else
    local i = pick(m, n)
    if not i then return end
    sounds[m.key] = m.options[i][1]
  end
  ns.SetSetting("sounds", sounds)
  local i = current(m)
  ns.print(m.key .. " sound: " .. (chosen(m) == false and "off" or describe(m, i)))
end

-- Sample moments for "test", each playing `kit` or the chosen sound.
local TESTS = {
  popup = function(kit)
    if not (StaticPopupDialogs and StaticPopup_Show) then return end
    StaticPopupDialogs.WAYFINDER_SOUND_TEST = StaticPopupDialogs.WAYFINDER_SOUND_TEST or {
      text = "%s",
      button1 = "Start trip", button2 = "Not now",
      OnAccept = function() ns.print("that was a sound test: nothing started.") end,
      timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
    StaticPopup_Show("WAYFINDER_SOUND_TEST", "You picked up Sample Quest.\n\nStart a trip for it (~4 min)?")
    Sounds.Play("popup", kit)
  end,
  step = function(kit)
    ns.print("added Sample Quest to your trip: 4 stops, ~12 min (a sound test)")
    Sounds.Play("step", kit)
  end,
  start = function(kit)
    ns.print("journey: Sample journey, 3 stops, ~9 min (a sound test)")
    Sounds.Play("start", kit)
  end,
  complete = function(kit) ns.Fanfare.Preview("trip", kit) end,
  toast = function(kit) ns.Fanfare.Preview("toast", kit) end,
}

local function test(m, n)
  local kit, i = nil, current(m)
  if n then
    i = pick(m, n)
    if not i then return end
    kit, cursor[m.key] = m.options[i][1], i
  end
  local off = not kit and chosen(m) == false
  ns.print("sound test, " .. m.key .. ": " .. (off and "sound off" or i and describe(m, i) or "?"))
  TESTS[m.key](kit)
end

ns.RegisterCommand("sounds", "/wf sounds - try Wayfinder's sounds and pick one for each moment", function(rest)
  local words = {}
  for w in (rest or ""):lower():gmatch("%S+") do words[#words + 1] = w end
  local verb = words[1]
  if not verb then return overview() end
  if verb == "use" or verb == "test" then
    local m = find(words[2])
    if not m or (verb == "use" and not words[3]) then return usage() end
    return (verb == "use" and use or test)(m, words[3])
  end
  local m = find(verb)
  if not m then return usage() end
  if not words[2] then return list(m) end
  if words[2] == "next" then return try(m, ((cursor[m.key] or current(m) or 0) % #m.options) + 1) end
  try(m, words[2])
end)
