local _, ns = ...

-- "Quest hubs" category: places with quest givers you can take quests from,
-- ranked by travel time. Needs QuestieDB (see QuestieBridge.lua).

local QuestHubs = { id = "questHubs", label = "Quest hubs" }
ns.QuestHubs = QuestHubs

local ROUTED_HUBS = 10 -- nearest hubs (straight line) that get a full route
local summary

-- Accepting or handing in a quest changes what's available.
ns.On("QUEST_ACCEPTED", function() ns.Fire("DATA_CHANGED") end)
ns.On("QUEST_TURNED_IN", function() ns.Fire("DATA_CHANGED") end)

local function unavailableText()
  local _, reason = ns.Questie.Available()
  return (reason or "QuestieDB is not available") .. ". Install QuestieDB to see quest hubs near you."
end

function QuestHubs.SummaryText()
  if not ns.Questie.Available() then return unavailableText() end
  return summary or "Quest givers you can take quests from, nearest first."
end

function QuestHubs.EmptyText()
  return "No quests for your level found nearby. Try another zone, or check the quests you already have."
end

function QuestHubs.Results()
  if not ns.Questie.Available() then return {}, unavailableText() end
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()

  local results, total = {}, 0
  for i, hub in ipairs(ns.Questie.QuestHubs(start, ROUTED_HUBS)) do
    total = total + hub.count
    local lowest, highest, details = math.huge, 0, {}
    for _, giver in ipairs(hub.givers) do
      for _, q in ipairs(giver.quests) do
        lowest, highest = math.min(lowest, q.level), math.max(highest, q.level)
        details[#details + 1] = {
          text = string.format("[%d] %s  -  %s", q.level, q.name or ("Quest " .. q.id), giver.name or "?"),
          color = GetQuestDifficultyColor and GetQuestDifficultyColor(q.level),
        }
      end
    end
    local goal = hub.anchor.node
    local levels = lowest == highest and ("level " .. lowest) or string.format("levels %d-%d", lowest, highest)
    results[#results + 1] = {
      id = "hub" .. i,
      title = string.format("%d quest%s at %s", hub.count, hub.count == 1 and "" or "s", hub.anchor.name or "?"),
      zone = ns.MapName(goal.mapID) .. "  ·  " .. levels,
      goal = goal,
      route = ns.Router.Plan(start, goal, net),
      details = details,
    }
  end

  table.sort(results, function(a, b)
    return (a.route and a.route.seconds or math.huge) < (b.route and b.route.seconds or math.huge)
  end)
  summary = string.format("|cff7fd1ae%d quest%s|r for you at the %d nearest places with quests.", total,
    total == 1 and "" or "s", #results)
  return results, nil, net
end
