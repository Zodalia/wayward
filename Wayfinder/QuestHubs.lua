local _, ns = ...

-- "Quest hubs" category: places with quest givers you can take quests from,
-- ranked by travel time. Needs quest data (see Quests.lua).

local QuestHubs = { id = "questHubs", label = "Quest hubs" }
ns.QuestHubs = QuestHubs

local ROUTED_HUBS = 10 -- nearest hubs (straight line) that get a full route
local summary

-- Accepting or handing in a quest changes what's available.
ns.On("QUEST_ACCEPTED", function() ns.Fire("DATA_CHANGED") end)
ns.On("QUEST_TURNED_IN", function() ns.Fire("DATA_CHANGED") end)

local function unavailableText()
  return "No quest data. Install a Wayfinder data addon to see quest hubs near you."
end

function QuestHubs.SummaryText()
  if not ns.Quests.Available() then return unavailableText() end
  return summary or "Quest givers you can take quests from, nearest first."
end

function QuestHubs.EmptyText()
  return "No quests for your level found nearby. Try another zone, or check the quests you already have."
end

function QuestHubs.Results()
  if not ns.Quests.Available() then return {}, unavailableText() end
  local start = ns.Geo.PlayerNode()
  if not start then return {}, "Can't read your position here." end
  local net = ns.Network.Build()

  -- Name each hub after its place, and merge hubs that turn out to be the same
  -- place (a town's quest givers can be spread over more than one cluster).
  local named, byPlace = {}, {}
  for _, hub in ipairs(ns.Quests.QuestHubs(start, ROUTED_HUBS)) do
    local place = ns.Places.NameFor(hub.anchor.node)
    local key = place and (place .. "@" .. hub.anchor.node.mapID)
    local existing = key and byPlace[key]
    if existing then
      for _, giver in ipairs(hub.givers) do table.insert(existing.givers, giver) end
      existing.count = existing.count + hub.count
      if #hub.anchor.quests > #existing.anchor.quests then existing.anchor = hub.anchor end
    else
      hub.place = place
      named[#named + 1] = hub
      if key then byPlace[key] = hub end
    end
  end

  local results, total = {}, 0
  for i, hub in ipairs(named) do
    total = total + hub.count
    local lowest, highest, details, quests = math.huge, 0, {}, {}
    for _, giver in ipairs(hub.givers) do
      for _, q in ipairs(giver.quests) do
        quests[#quests + 1] = { id = q.id, name = q.name, level = q.level, giver = giver.name }
        lowest, highest = math.min(lowest, q.level), math.max(highest, q.level)
        details[#details + 1] = {
          text = string.format("[%d] %s  -  %s", q.level, q.name or ("Quest " .. q.id), giver.name or "?"),
          color = GetQuestDifficultyColor and GetQuestDifficultyColor(q.level),
        }
      end
    end
    local anchor = hub.anchor.node
    local place = hub.place or ("Near " .. (hub.anchor.name or "?"))
    -- Directions end at the main quest giver, labelled with the place.
    local goal = ns.Geo.Node(anchor.mapID, anchor.x, anchor.y,
      hub.place and string.format("%s (%s)", hub.place, hub.anchor.name or "?") or hub.anchor.name)
    local levels = lowest == highest and ("level " .. lowest) or string.format("levels %d-%d", lowest, highest)
    results[#results + 1] = {
      id = "hub" .. i,
      title = string.format("%s  ·  %d quest%s", place, hub.count, hub.count == 1 and "" or "s"),
      zone = string.format("%s  ·  %s  ·  %d quest giver%s", ns.MapName(anchor.mapID), levels, #hub.givers,
        #hub.givers == 1 and "" or "s"),
      goal = goal,
      route = goal and ns.Router.Plan(start, goal, net),
      details = details,
      -- For other pages (For you): the quests and place behind this row.
      quests = quests,
      place = hub.place,
      anchorName = hub.anchor.name,
    }
  end

  table.sort(results, function(a, b)
    return (a.route and a.route.seconds or math.huge) < (b.route and b.route.seconds or math.huge)
  end)
  summary = string.format("|cff7fd1ae%d quest%s|r for you at the %d nearest places with quests.", total,
    total == 1 and "" or "s", #results)
  return results, nil, net
end
