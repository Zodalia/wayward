local _, ns = ...

-- How long a quest takes this character, learned as you play: when you hand
-- in a quest you accepted this session, the minutes since you accepted it
-- (or since the last quest you handed in, if that was later: quests done side
-- by side share the time between them), at most MAX_MINUTES. The last KEEP
-- of those are averaged; from MIN_SAMPLES on, For you uses the average in
-- place of its fixed time per quest. A logout forgets the quests in progress
-- (a /reload doesn't), so time offline is never counted.

local QuestTimes = {}
ns.QuestTimes = QuestTimes

local MAX_MINUTES = 60
local KEEP = 20
QuestTimes.MIN_SAMPLES = 5

-- ns.charDB.questTimes = { samples = { minutes, ... }, accepted = { [questID] = time() }, last = time() }
local function state()
  local s = ns.charDB.questTimes
  if type(s) ~= "table" then
    s = {}
    ns.charDB.questTimes = s
  end
  s.samples = s.samples or {}
  s.accepted = s.accepted or {}
  return s
end

function QuestTimes.Record(minutes)
  local samples = state().samples
  samples[#samples + 1] = math.floor(math.min(minutes, MAX_MINUTES) * 10 + 0.5) / 10
  while #samples > KEEP do table.remove(samples, 1) end
end

-- The average in minutes and how many quests it is over (average nil under MIN_SAMPLES).
function QuestTimes.Average()
  local samples = ns.charDB and state().samples or {}
  if #samples < QuestTimes.MIN_SAMPLES then return nil, #samples end
  local sum = 0
  for _, m in ipairs(samples) do sum = sum + m end
  return sum / #samples, #samples
end

-- The average in seconds, or nil while there are too few samples.
function QuestTimes.Seconds()
  local minutes = QuestTimes.Average()
  return minutes and minutes * 60 or nil
end

-- For /ww debug.
function QuestTimes.Describe(default)
  local minutes, n = QuestTimes.Average()
  if minutes then
    return string.format("quest time: ~%.1f min, the average of your last %d quests (used for For you's estimates)",
      minutes, n)
  end
  return string.format("quest time: %d of %d quests timed; For you uses %d min per quest until then",
    n, QuestTimes.MIN_SAMPLES, (default or 300) / 60)
end

ns.On("PLAYER_ENTERING_WORLD", function(isLogin)
  if not (isLogin and ns.charDB) then return end
  local s = state()
  s.accepted, s.last = {}, nil
end)

ns.On("QUEST_ACCEPTED", function(questID)
  if ns.charDB and questID then state().accepted[questID] = time() end
end)

-- An abandoned quest's time isn't counted.
ns.Listen("QUEST_ABANDONED", function(questID)
  if ns.charDB then state().accepted[questID] = nil end
end)

ns.On("QUEST_TURNED_IN", function(questID)
  if not (ns.charDB and questID) then return end
  local s, now = state(), time()
  local at = s.accepted[questID]
  s.accepted[questID] = nil
  if at then
    local from = math.max(at, s.last or at)
    QuestTimes.Record(math.max(0, now - from) / 60)
  end
  s.last = now
end)
