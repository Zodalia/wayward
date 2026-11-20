local _, ns = ...

-- Following the party leader: a first take on journeys across a party.
--
-- The party leader is asked once per group whether to lead the party's
-- journeys. Leading, every party member with Wayward (there now, or joining
-- later) is asked once whether to follow. A follower's own journey is set
-- aside, and the directions box, arrow, minimap and map show the way to the
-- stop the leader is heading for; nothing on it can be added or changed.
-- Leaving follow mode (the box's x) picks their own journey up again.
--
-- What would have asked a follower about a detour (a quest picked up, or
-- progress on one not on the journey) goes to the leader instead, whose
-- Wayward handles it as their own, quest the leader doesn't have or not:
-- "Ruth picked up The Tome of Valor. Add it to your journey?". Its stops are
-- the follower's (Journey.MemberQuestStops), done when their Wayward says so.
--
-- Pillar 5 (player-owned progress) gives way for a follower, by their own
-- choice: they can leave whenever they like and get their journey back.
-- Pillar 2: each question is asked once per group; a "not now" sticks.
--
-- Messages (addon channel PREFIX, to the party or raid):
--   LEAD / UNLEAD          the leader leads, or stops
--   FOLLOW / UNFOLLOW      a member follows, or stops
--   STOP|mapID|x|y|title|label|text   where the leader is heading ("STOP" alone: nowhere)
--   Q|event|questID|finished          a follower's quest moved on (event: pickup,
--                                     progress, complete, turnin, abandon)
local Party = {}
ns.Party = Party

local PREFIX = "Wayward"
local GATHER_WAIT = 1.5  -- seconds a follower's pickups are gathered before asking, as for your own
local ENDED_WAIT = 1     -- seconds after a journey ends before "still following you" (not a switch)
local CHECK_DELAY = 3    -- seconds after a login before the group is looked at (it isn't ready sooner)
local MAX_TEXT = 90      -- characters of a name or stop text in a message (they're 255 at most)

Party.followers = {}     -- leading: [name] = true for each member following you

local askedLead = false  -- asked to lead in this group already
local declined = {}      -- [leader] = true: said "not now" to following them, in this group
local leads = {}         -- [leader] = true: they said they lead (LEAD), in this group
local lastStop           -- leading: the last STOP sent
local lastSize = 0       -- leading: the group's size when last told (a bigger one: tell again)
local memberDone = {}    -- leading: [name] = { [questID] = true }: objectives done in their log
local memberAsked = {}   -- leading: [name .. ":" .. questID] = true: asked about their progress
local pending = {}       -- leading: [name] = { questIDs picked up, waiting to be asked about }
local seen = {}          -- following: [questID] = { progress, complete } as last told

---------------------------------------------------------------- names and sending

local function unitName(unit)
  if not UnitName then return nil end
  local name, realm = UnitName(unit)
  if not name then return nil end
  if realm and realm ~= "" then return name .. "-" .. realm end
  return name
end

local function me() return unitName("player") end

-- A sender's name as the party shows it ("Name", or "Name-Realm" from another realm).
local function short(sender)
  if not sender then return nil end
  if Ambiguate then return (Ambiguate(sender, "none")) end
  return (sender:gsub("%-.*$", ""))
end

local function inGroup() return IsInGroup ~= nil and IsInGroup() or false end
local function inRaid() return IsInRaid ~= nil and IsInRaid() or false end

local function groupSize()
  return type(GetNumGroupMembers) == "function" and tonumber((GetNumGroupMembers())) or 0
end

-- The group's leader's name, or nil out of a group.
local function leaderName()
  if not inGroup() then return nil end
  if UnitIsGroupLeader and UnitIsGroupLeader("player") then return me() end
  local prefix, n = "party", 4
  if inRaid() then prefix, n = "raid", 40 end
  for i = 1, n do
    local unit = prefix .. i
    if (not UnitExists or UnitExists(unit)) and UnitIsGroupLeader and UnitIsGroupLeader(unit) then
      return unitName(unit)
    end
  end
  return nil
end
Party.LeaderName = leaderName

local function clean(text)
  text = tostring(text or ""):gsub("|", "/")
  return text:sub(1, MAX_TEXT)
end

local function send(msg)
  if not inGroup() then return false end
  local api = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
  if not api then return false end
  local ok = pcall(api, PREFIX, msg, inRaid() and "RAID" or "PARTY")
  return ok
end

do
  local register = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
  if register then pcall(register, PREFIX) end
end

local function save()
  if not ns.charDB then return end
  ns.charDB.party = (Party.leading or Party.following)
    and { leading = Party.leading or nil, following = Party.following } or nil
end

---------------------------------------------------------------- questions

-- Shows a game question (StaticPopup), with its sound. False where the game can't.
local function ask(which, dialog, text, data)
  if not (StaticPopupDialogs and StaticPopup_Show) then return false end
  StaticPopupDialogs[which] = StaticPopupDialogs[which] or dialog
  local ok = pcall(StaticPopup_Show, which, text, nil, data)
  if ok and ns.Sounds then ns.Sounds.Play("popup") end
  return ok
end

---------------------------------------------------------------- following

function Party.Following() return Party.following end
function Party.Leading() return Party.leading == true end

-- Something tried to start or change a journey while following.
function Party.Blocked()
  ns.print(string.format("you're following %s's journey. To plan your own, stop following "
    .. "(the x on the directions box, or /ww follow).", Party.following or "the party leader"))
end

-- What the quest log says of a quest now: { progress, complete }.
local function questState(questID)
  return { progress = ns.Nav.ProgressOf and ns.Nav.ProgressOf(questID) or "",
    complete = ns.QuestLog.IsComplete(questID) and true or false }
end

-- The quests in your log as they are now, so only what changes from here is told.
local function rememberLog()
  seen = {}
  for _, info in ns.QuestLog.Entries() do
    if info.questID and not info.isHeader then seen[info.questID] = questState(info.questID) end
  end
end

local function tell(event, questID, finished)
  send(string.format("Q|%s|%d|%s", event, questID, finished and "1" or "0"))
end

-- Follows `leader`: your journey is set aside (to come back when you stop),
-- and the leader is told, who sends where they're heading.
function Party.Follow(leader)
  leader = leader or leaderName()
  if not leader or leader == me() then return false end
  if Party.following == leader then return true end
  if Party.leading then Party.StopLeading() end
  local active = ns.Nav.active
  if active and not active.follow then
    local entry = ns.Nav.SetAside()
    if entry then
      -- The one to resume when you stop following: only this one.
      for _, e in ipairs(ns.Nav.SetAsideList()) do e.followAside = nil end
      entry.followAside = true
    end
  end
  Party.following = leader
  declined[leader] = nil
  save()
  rememberLog()
  send("FOLLOW")
  ns.print(string.format("following %s: the directions box shows the way to where they're heading. "
    .. "Quests you pick up are offered to their journey. The box's x stops following.", leader))
  ns.Fire("FOLLOW_CHANGED")
  return true
end

-- Stops following. Your own journey, set aside when you started, is picked
-- up again. `why`: what to say (else "stopped following X"); `quiet`: the
-- leader isn't told (they've gone, or stopped leading).
function Party.Unfollow(why, quiet)
  local leader = Party.following
  if not leader then return false end
  Party.following = nil
  save()
  if not quiet then send("UNFOLLOW") end
  if ns.Nav.active and ns.Nav.active.follow then ns.Nav.Stop() end
  ns.print(why or string.format("stopped following %s.", leader))
  for i, entry in ipairs(ns.Nav.SetAsideList()) do
    if entry.followAside then
      entry.followAside = nil
      ns.Nav.ResumeSetAside(i)
      break
    end
  end
  ns.Fire("FOLLOW_CHANGED")
  return true
end

-- The directions box's x while following: asks first.
function Party.AskLeave()
  local leader = Party.following
  if not leader then return end
  local shown = ask("WAYWARD_UNFOLLOW", {
    text = "%s",
    button1 = "Stop following", button2 = "Keep following",
    OnAccept = function() Party.Unfollow() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }, string.format("Stop following %s?\n\nYour own journey picks up where you left it.", leader))
  if not shown then Party.Unfollow() end
end

-- A leader said they lead: asked once whether to follow them.
local function askFollow(leader)
  if Party.following or Party.leading or declined[leader] then return end
  local shown = ask("WAYWARD_FOLLOW", {
    text = "%s",
    button1 = "Follow", button2 = "Not now",
    OnAccept = function(_, data)
      if leaderName() == data.leader then Party.Follow(data.leader) end
    end,
    OnCancel = function(_, data) declined[data.leader] = true end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }, string.format("%s is leading the party's journeys.\n\nFollow their directions? Your own journey is set "
    .. "aside while you follow, and picks up again when you stop. Quests you pick up are offered to "
    .. "their journey.", leader), { leader = leader })
  if not shown then
    declined[leader] = true
    ns.print(string.format("%s is leading the party's journeys: /ww follow to follow their directions.", leader))
  end
end

-- Where the leader is heading: directions there, or none while they have no journey.
local function followTo(leader, mapID, x, y, title, label, text)
  if not mapID then
    if ns.Nav.active and ns.Nav.active.follow then ns.Nav.Stop() end
    ns.print(string.format("%s has no journey on: waiting for their next one.", leader))
    return
  end
  local goal = ns.Geo.Node(mapID, x, y, label ~= "" and label or text)
  if not goal then return end
  local heading = text ~= "" and text or title
  ns.Nav.Follow(leader, string.format("Following %s: %s", leader, heading), goal)
end

---------------------------------------------------------------- leading

local function stopMessage()
  local a = ns.Nav.active
  if not a then return "STOP" end
  local stop = ns.Nav.HeadingFor()
  local node = stop and stop.node or a.goal
  if not node then return "STOP" end
  local text = stop and (stop.text or ns.Journey.DefaultText(stop)) or a.title
  return string.format("STOP|%d|%.4f|%.4f|%s|%s|%s", node.mapID, node.x, node.y, clean(a.title), clean(node.label),
    clean(text))
end

-- Tells the followers where you're heading, when it changed (or `force`).
local function sendStop(force)
  if not (Party.leading and next(Party.followers)) then return end
  local msg = stopMessage()
  if not force and msg == lastStop then return end
  lastStop = msg
  send(msg)
end
Party.SendStop = sendStop

function Party.Lead()
  if leaderName() ~= me() then
    ns.print("only the party leader can lead the party's journeys.")
    return false
  end
  if Party.following then Party.Unfollow(nil) end
  Party.leading, askedLead = true, true
  Party.followers, lastStop = {}, nil
  lastSize = groupSize()
  save()
  send("LEAD")
  ns.print("leading the party's journeys: party members with Wayward are asked whether to follow your directions.")
  ns.Fire("FOLLOW_CHANGED")
  return true
end

-- Stops leading; the followers go back to their own journeys.
function Party.StopLeading(why)
  if not Party.leading then return false end
  Party.leading = nil
  Party.followers, lastStop, pending = {}, nil, {}
  save()
  send("UNLEAD")
  ns.print(why or "stopped leading: your party's followers are back on their own journeys.")
  ns.Fire("FOLLOW_CHANGED")
  return true
end

-- The followers' names, sorted.
function Party.FollowerNames()
  local names = {}
  for name in pairs(Party.followers) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- Asked once per group, when you lead one with someone else in it.
local function askLead()
  askedLead = true
  local shown = ask("WAYWARD_LEAD", {
    text = "%s",
    button1 = "Lead", button2 = "Not now",
    OnAccept = function() Party.Lead() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }, "You're leading the party.\n\nLead its journeys too? Party members with Wayward are asked whether to follow "
    .. "your directions, and quests they pick up are offered to your journey.")
  if not shown then ns.print("you're leading the party: /ww lead to lead its journeys too.") end
end

-- A follower's pickups, gathered for a moment, then handled as yours would be.
local function askPending(name)
  local ids = pending[name]
  pending[name] = nil
  if not (ids and #ids > 0 and Party.followers[name]) then return end
  ns.Nav.MemberQuests({ name = name, finished = memberDone[name] or {} }, ids, "picked up")
end

-- Yours too (in your log, or on the journey as yours): your own Wayward
-- has it, and asking about theirs would ask twice.
local function yoursToo(questID)
  return ns.QuestLog.LogIndex(questID) ~= nil or ns.Nav.TripHasQuest(questID, false)
end

local function memberQuest(name, event, questID, finished)
  memberDone[name] = memberDone[name] or {}
  if finished then memberDone[name][questID] = true end
  if event == "pickup" then
    -- Picked up for a stop already on the journey (a quest it leads to): that's done.
    if ns.Nav.MemberQuestEvent(name, "pickup", questID) or yoursToo(questID) then return end
    local list = pending[name]
    if not list then
      list = {}
      pending[name] = list
      ns.After(GATHER_WAIT, function() askPending(name) end)
    end
    list[#list + 1] = questID
  elseif event == "progress" then
    local key = name .. ":" .. questID
    if memberAsked[key] or yoursToo(questID) or ns.Nav.TripHasQuest(questID, name) then return end
    memberAsked[key] = true
    ns.Nav.MemberQuests({ name = name, finished = memberDone[name] }, { questID }, "made progress on")
  elseif event == "complete" then
    memberDone[name][questID] = true
    ns.Nav.MemberQuestEvent(name, "complete", questID)
  elseif event == "turnin" or event == "abandon" then
    memberDone[name][questID] = nil
    memberAsked[name .. ":" .. questID] = nil
    for i = #(pending[name] or {}), 1, -1 do
      if pending[name][i] == questID then table.remove(pending[name], i) end
    end
    ns.Nav.MemberQuestEvent(name, event, questID)
  end
end

---------------------------------------------------------------- messages

local handlers = {}

function handlers.LEAD(from)
  if leaderName() ~= from then return end
  leads[from] = true
  -- Following them already (a reload on their side): say so again.
  if Party.following == from then
    send("FOLLOW")
    return
  end
  askFollow(from)
end

function handlers.UNLEAD(from)
  leads[from] = nil
  if Party.following == from then
    Party.Unfollow(string.format("%s stopped leading: back to your own journey.", from), true)
  end
end

function handlers.FOLLOW(from)
  if not Party.leading then return end
  local new = not Party.followers[from]
  Party.followers[from] = true
  if new then ns.print(string.format("%s is following your journey.", from)) end
  sendStop(true)
end

function handlers.UNFOLLOW(from)
  if not Party.followers[from] then return end
  Party.followers[from] = nil
  pending[from] = nil
  ns.print(string.format("%s stopped following your journey.", from))
end

function handlers.STOP(from, rest)
  if Party.following ~= from then return end
  local mapID, x, y, title, label, text = strsplit("|", rest or "")
  followTo(from, tonumber(mapID), tonumber(x), tonumber(y), title or "", label or "", text or "")
end

function handlers.Q(from, rest)
  if not (Party.leading and Party.followers[from]) then return end
  local event, id, finished = strsplit("|", rest or "")
  id = tonumber(id)
  if id then memberQuest(from, event, id, finished == "1") end
end

-- A message from another party member's Wayward (`sender` as the game gives it).
function Party.Receive(prefix, text, _, sender)
  if prefix ~= PREFIX or type(text) ~= "string" then return end
  local from = short(sender)
  if not from or from == me() then return end
  local cmd, rest = text:match("^(%u+)|?(.*)$")
  local handler = cmd and handlers[cmd]
  if handler then handler(from, rest) end
end

ns.On("CHAT_MSG_ADDON", Party.Receive)

---------------------------------------------------------------- the group

-- The group changed (or you logged in): who leads, who's gone, who's new.
function Party.CheckGroup()
  if not ns.charDB then return end
  local leader = leaderName()
  if not inGroup() then
    if Party.following then Party.Unfollow("you left the group: back to your own journey.", true) end
    if Party.leading then Party.StopLeading("you left the group: stopped leading.") end
    askedLead, declined, leads, memberDone, memberAsked, pending, lastSize = false, {}, {}, {}, {}, {}, 0
    return
  end
  if Party.following and leader ~= Party.following then
    Party.Unfollow(string.format("%s isn't leading the party any more: back to your own journey.",
      Party.following), true)
  end
  if Party.leading and leader ~= me() then
    Party.StopLeading("you're not the party leader any more: stopped leading.")
  end
  if leader ~= me() then
    askedLead = false -- leading a group again later asks again
    return
  end
  local size = groupSize()
  if Party.leading then
    -- Someone new: they're asked whether to follow (the rest have answered).
    if size > lastSize then send("LEAD") end
    lastSize = size
  elseif not askedLead and size > 1 and ns.db.settings.askToLead ~= false then
    askLead()
  end
end

ns.On("GROUP_ROSTER_UPDATE", function() Party.CheckGroup() end)
ns.On("PARTY_LEADER_CHANGED", function() Party.CheckGroup() end)

-- After a login or reload: leading or following as before, while the group
-- still is as it was.
ns.On("PLAYER_LOGIN", function()
  ns.After(CHECK_DELAY, function()
    local saved = ns.charDB and ns.charDB.party
    if saved then
      local leader = leaderName()
      if saved.following and leader == saved.following then
        Party.following = saved.following
        rememberLog()
        send("FOLLOW")
      elseif saved.leading and leader == me() then
        Party.leading, askedLead, lastSize = true, true, groupSize()
        send("LEAD")
      elseif saved.following then
        -- The leader has gone: what was set aside for them comes back.
        Party.following = saved.following
        Party.Unfollow(string.format("%s isn't leading your party any more: back to your own journey.",
          saved.following), true)
      end
      save()
    end
    Party.CheckGroup()
  end)
end)

---------------------------------------------------------------- what moves on

-- Leading: where you're heading, whenever it changes. A journey ended with
-- followers still following: they keep following (your next journey is
-- theirs too), unless you'd rather stop.
local hadJourney = false
ns.Listen("NAV_CHANGED", function()
  if not Party.leading then return end
  sendStop()
  local on = ns.Nav.active ~= nil
  if hadJourney and not on and next(Party.followers) then
    ns.After(ENDED_WAIT, function()
      if not (Party.leading and next(Party.followers)) or ns.Nav.active then return end
      local names = Party.FollowerNames()
      ns.Snackbar.Show({
        text = string.format("%s still following you. Your next journey is theirs too.",
          #names == 1 and (names[1] .. " is") or (#names .. " party members are")),
        actions = { { label = "Stop leading", tooltip = "Your followers go back to their own journeys.",
          run = function() Party.StopLeading() end } },
      })
    end)
  end
  hadJourney = on
end)

-- Following: your quests moving on are told to the leader.
ns.On("QUEST_ACCEPTED", function(...)
  if not Party.following then return end
  local questID = ns.QuestLog.AcceptedID(...)
  if not questID then return end
  local state = questState(questID)
  seen[questID] = state
  tell("pickup", questID, state.complete)
end)

ns.On("QUEST_TURNED_IN", function(questID)
  if not (Party.following and questID) then return end
  seen[questID] = nil
  tell("turnin", questID)
end)

ns.Listen("QUEST_ABANDONED", function(questID)
  if not (Party.following and questID) then return end
  seen[questID] = nil
  tell("abandon", questID)
end)

ns.On("QUEST_LOG_UPDATE", function()
  if not Party.following then return end
  for _, info in ns.QuestLog.Entries() do
    local id = info.questID
    if id and not info.isHeader then
      local now, before = questState(id), seen[id]
      if before then
        if now.complete and not before.complete then
          tell("complete", id, true)
        elseif now.progress ~= before.progress then
          tell("progress", id, now.complete)
        end
      end
      seen[id] = now
    end
  end
end)

---------------------------------------------------------------- commands

ns.RegisterCommand("lead", "/ww lead - lead your party's journeys (as party leader), or stop", function()
  if Party.leading then Party.StopLeading() else Party.Lead() end
end)

ns.RegisterCommand("follow", "/ww follow - follow the party leader's directions, or stop", function()
  if Party.following then return Party.Unfollow() end
  local leader = leaderName()
  if not leader or leader == me() then
    ns.print("follow mode follows your party leader's directions: you need to be in a party, not leading it.")
  elseif not leads[leader] then
    ns.print(string.format("%s isn't leading the party's journeys (they can with /ww lead).", leader))
  else
    Party.Follow(leader)
  end
end)
