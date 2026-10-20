local _, ns = ...

-- The camp you're in while doing a quest's objectives there (Journey's
-- objective areas): which of its mobs you can see, from their nameplates
-- (about 40-60 yards; enemy nameplates have to be on), and how the
-- objectives go. From those:
--   * the camp looks cleared: you've killed there, its mobs were in sight,
--     and for EMPTY_SECONDS none you could kill are (dead, or tapped by
--     someone else). Leaving then counts it as cleared at once.
--   * the time left here: what the objectives still need at your pace in
--     this camp (after MIN_KILLS kills).
-- Whatever the game keeps secret (Midnight-era clients) counts as not seen,
-- so without nameplates the trip goes by the time you spent there instead.
-- The state is per visit, on the stop (stop.visit, from Journey.EnterArea).

local Camps = {}
ns.Camps = Camps

local EMPTY_SECONDS, SCAN_EVERY, MIN_KILLS = 10, 1, 2

local function secret(v)
  return type(issecretvalue) == "function" and issecretvalue(v)
end

-- The NPC ID and name on a unit, as far as the game shows them.
local function identify(unit)
  local id
  local guid = UnitGUID and UnitGUID(unit)
  if type(guid) == "string" and not secret(guid) then
    local kind, _, _, _, _, npc = strsplit("-", guid)
    if kind == "Creature" then id = tonumber(npc) end
  end
  local name = UnitName and UnitName(unit)
  if secret(name) or type(name) ~= "string" then name = nil end
  return id, name
end

-- How many of a quest's objective mobs are in sight that you could kill, and
-- how many are in sight at all; nil when nameplates can't tell.
function Camps.InSight(questID)
  if not (C_NamePlate and C_NamePlate.GetNamePlates and UnitIsDead) then return nil end
  local mobs = ns.Quests.ObjectiveMobs(questID)
  if next(mobs.ids) == nil and next(mobs.names) == nil then return nil end
  local live, seen = 0, 0
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
    local unit = plate.namePlateUnitToken
    if unit then
      local id, name = identify(unit)
      if (id and mobs.ids[id]) or (not id and name and mobs.names[name]) then
        local dead = UnitIsDead(unit)
        local taken = UnitIsTapDenied and UnitIsTapDenied(unit) or false
        if not (secret(dead) or secret(taken)) then
          seen = seen + 1
          if not dead and not taken then live = live + 1 end
        end
      end
    end
  end
  return live, seen
end

-- Called while you're in a stop's area (Nav.Tick); looks again every SCAN_EVERY seconds.
function Camps.Watch(stop)
  local visit = stop and stop.visit
  local action = stop and stop.action
  if not (visit and action and action.questID) then return end
  local now = time()
  if visit.scanned and now - visit.scanned < SCAN_EVERY then return end
  visit.scanned = now

  -- Progress here: kills (or loot) since you came.
  local left = ns.Quests.ObjectivesLeft(action.questID)
  if left then
    if visit.left and left < visit.left then
      visit.kills = (visit.kills or 0) + (visit.left - left)
      visit.last = now
    end
    visit.left = left
  end

  local live, seen = Camps.InSight(action.questID)
  if not live then return end
  if seen > 0 then visit.seen = true end
  if live > 0 then
    visit.emptySince = nil
  else
    visit.emptySince = visit.emptySince or now
  end
  visit.looksCleared = visit.seen == true and (visit.kills or 0) > 0 and visit.emptySince ~= nil
    and now - visit.emptySince >= EMPTY_SECONDS
end

function Camps.LooksCleared(stop)
  return stop ~= nil and stop.inArea == true and stop.visit ~= nil and stop.visit.looksCleared == true
end

-- Seconds the stop's objectives should still take at your pace in this camp, or nil.
function Camps.TimeLeft(stop)
  local visit = stop and stop.inArea and stop.visit
  if not (visit and (visit.kills or 0) >= MIN_KILLS and visit.left and visit.last) then return nil end
  return visit.left * (visit.last - visit.since) / visit.kills
end
