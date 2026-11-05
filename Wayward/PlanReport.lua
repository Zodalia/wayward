local _, ns = ...

-- /ww plan: what the journey planner sees from where you stand, as text to
-- copy into a bug report. Where each open stop is and how far, where a
-- quest's objectives can be done (every area the data has, which you've
-- cleared, which the plan aims for, and the game's own quest marker),
-- whether re-planning as you go can run now and why not, the order the plan
-- follows against a fresh one from here, and the recent re-plans
-- (Nav.TraceLines). Building it plans routes, so it runs as a background
-- job; it changes nothing on the journey.

local PlanReport = {}
ns.PlanReport = PlanReport

local function place(node)
  if not node then return "nowhere known" end
  local zone = ns.Geo.ZoneAt(node.instance, node.wx, node.wy) or node.mapID
  return string.format("%s (map %s) %.3f, %.3f", ns.MapName(zone), tostring(node.mapID), node.x or 0, node.y or 0)
end

local function yards(a, b)
  local d = ns.Geo.Distance(a, b)
  return d < math.huge and string.format("%.0f yd", d) or "another continent"
end

-- " (quest 13: in log, 2/10)" for a quest stop: quests in a chain often share
-- a name, so the report says which one, and where it stands.
local function questTag(stop)
  local id = stop and stop.action and stop.action.questID
  if not id then return "" end
  local done, logged = ns.Quests.PlayerQuestState()
  local state = done[id] and "done" or logged[id] and "in log" or "not taken"
  if logged[id] then
    local complete = ns.QuestLog.IsComplete(id)
    local left = not complete and ns.Quests.ObjectivesLeft(id)
    state = state .. (complete and ", ready to hand in" or left and (", " .. left .. " to go") or "")
  end
  return string.format(" (quest %d: %s)", id, state)
end

local function names(stops)
  local out = {}
  for _, s in ipairs(stops) do out[#out + 1] = ns.Nav.StopName(s) end
  return table.concat(out, " > ")
end

-- Travel seconds from `here` through `stops` in order (no waits), or nil
-- when a leg has no route.
local function travel(here, stops, net)
  local total, from = 0, here
  for _, s in ipairs(stops) do
    local route = s.node and ns.Router.Plan(from, s.node, net)
    if not route then return nil end
    total, from = total + route.seconds, s.node
  end
  return total
end

local function duration(seconds)
  return seconds and ns.FormatDuration(seconds) or "no route"
end

-- Where a quest's objectives are, for a "complete" stop: lines.
local function objectiveLines(stop, here)
  local questID = stop.action.questID
  local out = {}
  local marker, source = ns.Quests.ObjectiveNode(questID, here)
  out[#out + 1] = string.format("      game's quest marker: %s",
    source == "log" and (place(marker) .. ", " .. yards(here, marker)) or "none (from the data: " .. place(marker) .. ")")
  local groups = {}
  for g, group in ipairs(ns.Quests.ObjectiveGroups(questID)) do groups[g] = group.name or ("group " .. g) end
  local all = ns.Quests.ObjectiveAreas(questID)
  local open = {}
  for _, area in ipairs(ns.Journey.OpenAreas(questID)) do open[area.index] = area end
  out[#out + 1] = string.format("      areas in the data: %d (%d still needed)", #all,
    #ns.Journey.OpenAreas(questID))
  for index, area in ipairs(all) do
    local kinds, seen, nodes = {}, {}, {}
    for _, m in ipairs(area) do
      nodes[#nodes + 1] = m.node
      local name = groups[m.group] or "?"
      if not seen[name] then
        seen[name] = true
        kinds[#kinds + 1] = name
      end
    end
    local nearest = ns.Data.Nearest(nodes, here)
    local flags = {}
    if not open[index] then
      local fromMarker
      if source == "log" then fromMarker = select(2, ns.Data.Nearest(nodes, marker)) end
      flags[#flags + 1] = fromMarker and fromMarker > ns.Journey.MARKER_YARDS and "far from the game's marker: left out"
        or "done"
    end
    if stop.aimArea == index then flags[#flags + 1] = "aimed for" end
    if stop.inArea and stop.areaAt == index then flags[#flags + 1] = "you're in it" end
    if ns.Journey.Cleared(stop, index) then flags[#flags + 1] = "cleared lately" end
    out[#out + 1] = string.format("      #%d: %d spots of %s; nearest %s, %s%s", index, #area, table.concat(kinds, ", "),
      place(nearest), yards(here, nearest), #flags > 0 and ("  [" .. table.concat(flags, ", ") .. "]") or "")
  end
  local respawn = ns.Journey.RespawnIn(stop)
  if respawn > 0 then out[#out + 1] = "      every area cleared: respawns in " .. ns.FormatDuration(respawn) end
  return out
end

-- The report, as text. Runs inside a background job (ns.Warm) or directly.
function PlanReport.Build()
  local lines = {}
  local function add(fmt, ...)
    lines[#lines + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  end
  add("Wayward %s (%s) plan report%s", ns.VERSION, ns.GameName(), date and (", " .. date("%Y-%m-%d %H:%M")) or "")
  local here = ns.Geo.PlayerNode()
  add("You: %s%s", place(here), here and here.stale and " (last known)" or "")
  local a = ns.Nav.active
  if not a then
    add("No journey or directions on.")
  else
    local net = ns.Network.Build()
    local journey = a.journey
    local root = journey and (journey.root or journey.def)
    add("%s: %s%s", journey and "Journey" or "Directions", a.title or "?",
      root and (root.manual and ", your own order (dragged)" or ", ordered for you") or "")
    local step = a.route.steps[a.index]
    if step then
      add("Step %d of %d: %s, %s to %s%s", a.index, #a.route.steps, ns.Router.Describe(a.route, a.index) or "?",
        tostring(step.mode), place(step.to), here and (", " .. yards(here, step.to)) or "")
    end
    local flags = {}
    if a.waiting then flags[#flags + 1] = "waiting at the stop" end
    if ns.Nav.InArea() then flags[#flags + 1] = "in its objective area" end
    local gathering = ns.Nav.GatheringHere()
    if gathering then
      flags[#flags + 1] = string.format("gathering where you are (%s to go at your pace)", duration(gathering.seconds))
    end
    if ns.Nav.Flying() then flags[#flags + 1] = "flying" end
    if #flags > 0 then add("Now: %s", table.concat(flags, ", ")) end
    add("Re-planning as you go: %s (padding %d yd)", ns.Nav.LiveBlocker() or "can run now", ns.Journey.STICK_YARDS)

    if journey then
      -- The open stops in the plan's order, then any it left out.
      local order, planned = {}, {}
      for k = a.index, #a.route.steps do
        local s = a.route.steps[k].stop
        if s and not s.done and not s.skipped and not planned[s] then
          order[#order + 1], planned[s] = s, true
        end
      end
      add("")
      add("Open stops, in the plan's order:")
      for i, s in ipairs(order) do
        ns.WarmStep()
        local tags = {}
        if s.pinned then tags[#tags + 1] = "pinned" end
        if s.joined then tags[#tags + 1] = "done together with " .. ns.Nav.StopName(s.joined) end
        if s.later then tags[#tags + 1] = "you moved on from it" end
        if ns.Journey.WaitsOnGathering(s) then
          tags[#tags + 1] = string.format("waits on gathering, %s to go", duration(ns.Journey.GatherSeconds(s.action.questID)))
        end
        if s.after then
          for _, before in ipairs(s.after) do
            if not before.done and not before.skipped then
              tags[#tags + 1] = "after " .. ns.Nav.StopName(before) .. questTag(before)
            end
          end
        end
        add("  %d. %s%s%s", i, ns.Nav.StopName(s), questTag(s), #tags > 0 and ("  [" .. table.concat(tags, "; ") .. "]") or "")
        local route = here and s.node and ns.Router.Plan(here, s.node, net)
        add("      at %s, %s, %s from here", place(s.node), here and yards(here, s.node) or "?",
          duration(route and route.seconds))
        if s.action and s.action.kind == "complete" and s.action.questID and here then
          for _, line in ipairs(objectiveLines(s, here)) do add(line) end
        end
      end
      local missing, gathered = {}, {}
      for _, s in ipairs(ns.Journey.AllStops(journey)) do
        if not planned[s] and not s.done and not s.skipped then
          local list = s.gather and gathered or missing
          list[#list + 1] = ns.Nav.StopName(s) .. questTag(s)
        end
      end
      if #gathered > 0 then add("Gathered as you go (not headed for): %s", table.concat(gathered, "; ")) end
      -- How each quest's spawns lie: spread (gathered as you go) or crowded in one spot (a stop).
      local seenQuest, spreadLines = {}, {}
      for _, s in ipairs(ns.Journey.AllStops(journey)) do
        local id = s.action and s.action.kind == "complete" and s.action.questID
        if id and not s.done and not s.skipped and not seenQuest[id] then
          seenQuest[id] = true
          local info = ns.Journey.SpreadInfo(id)
          spreadLines[#spreadLines + 1] = string.format(
            "  %s: %d areas over %.0f yd, %d of %d spawns (%.0f%%) round the busiest spot, %d around you  >  %s",
            ns.Nav.StopName(s), info.areas, info.span, info.busiest, info.total, info.share * 100,
            here and ns.Journey.SpawnsAround(id, here) or 0, info.spread and "spread: gathered as you go" or "a stop")
        end
      end
      if #spreadLines > 0 then
        add("How the objectives lie:")
        for _, line in ipairs(spreadLines) do add(line) end
      end
      if #missing > 0 then add("Open but not in the plan (no route?): %s", table.concat(missing, "; ")) end

      -- A fresh plan from here, as a re-plan would make it, put back after.
      if here and not root.manual then
        local saved = {}
        for _, s in ipairs(root.stops or {}) do saved[s] = { node = s.node, aim = s.aimArea } end
        local ok, fresh = ns.Protect(ns.Journey.Replan, journey, here, net)
        for s, v in pairs(saved) do s.node, s.aimArea = v.node, v.aim end
        add("")
        add("From here, travel only:")
        add("  plan's order:  %s, %s", names(order), duration(travel(here, order, net)))
        if not ok then
          add("  a fresh plan failed: %s", tostring(fresh))
        elseif not fresh then
          add("  a fresh plan found no route")
        else
          add("  a fresh plan: %s, %s", names(fresh.stops), duration(travel(here, fresh.stops, net)))
          local same = #fresh.stops == #order
          for i, s in ipairs(fresh.stops) do
            if s ~= order[i] then same = false end
          end
          add("  %s", same and "same order: a re-plan now keeps it"
            or "different: a re-plan now would switch to the fresh one")
        end
      end
    end
  end
  add("")
  add("Recent re-plans:")
  local trace = ns.Nav.TraceLines()
  if #trace == 0 then add("  none yet") end
  for _, line in ipairs(trace) do add("  " .. line) end
  return table.concat(lines, "\n")
end

ns.RegisterCommand("plan", "/ww plan - what the journey planner sees from here, to copy into a bug report", function()
  ns.print("building the plan report...")
  ns.Warm(PlanReport.Build, function(ok, text)
    if ok then ns.ShowCopyBox("Wayward plan report", text) end
  end)
end)
