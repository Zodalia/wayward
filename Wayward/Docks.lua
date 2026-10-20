local _, ns = ...

-- Records boats, zeppelins and portals the shipped data doesn't know (Forever
-- added routes such as Auberdine - Stormwind). /ww dock where you board, ride,
-- /ww dock again where you get off. Recorded routes are used straight away
-- and can be copied out (/ww dock list) to add to Data/Transports.lua.

local Docks = {}
ns.Docks = Docks

local KINDS = { boat = true, zeppelin = true, tram = true, portal = true }
local MIN_TRIP = 30 -- seconds; a shorter "trip" means the timer started late

local function round(v)
  return math.floor(v * 1000 + 0.5) / 1000
end

local function here()
  local node = ns.Geo.PlayerNode()
  if not node then return nil end
  local subZone = GetSubZoneText and GetSubZoneText() or ""
  return { mapID = node.mapID, x = round(node.x), y = round(node.y),
    label = subZone ~= "" and subZone or ns.MapName(node.mapID) }
end

local function endpoint(e)
  return string.format('{ mapID = %d, x = %.3f, y = %.3f, label = "%s" }', e.mapID, e.x, e.y,
    (e.label:gsub('"', '\\"')))
end

function Docks.LuaLine(t)
  return string.format('{ kind = "%s", faction = "%s", time = %d, verified = true,\n  a = %s,\n  b = %s },',
    t.kind, t.faction, t.time, endpoint(t.a), endpoint(t.b))
end

local function list()
  local recorded = ns.db.transports
  if #recorded == 0 then
    ns.print("no recorded transports yet. Type /ww dock where you board a boat or zeppelin.")
    return
  end
  local lines = { "-- Recorded with /ww dock. Paste into Wayward/Data/Transports.lua." }
  for _, t in ipairs(recorded) do lines[#lines + 1] = Docks.LuaLine(t) end
  ns.ShowCopyBox("Recorded transports", table.concat(lines, "\n"))
end

function Docks.Command(arg)
  local word = (arg or ""):match("^(%S*)")
  if word == "list" then return list() end
  if word == "clear" then
    ns.db.transports = {}
    ns.print("recorded transports cleared.")
    ns.Fire("DATA_CHANGED")
    return
  end
  if word == "cancel" then
    ns.charDB.pendingDock = nil
    ns.print("dock recording cancelled.")
    return
  end

  local position = here()
  if not position then
    ns.print("can't read your position here.")
    return
  end
  local pending = ns.charDB.pendingDock
  if not pending then
    local kind = KINDS[word] and word or "boat"
    ns.charDB.pendingDock = { kind = kind, a = position, started = time() }
    ns.print(string.format("recording a %s from %s. Ride it, then type /ww dock again where you get off "
      .. "(/ww dock cancel to stop).", kind, position.label))
    return
  end

  local a = ns.Geo.Node(pending.a.mapID, pending.a.x, pending.a.y)
  local b = ns.Geo.Node(position.mapID, position.x, position.y)
  if a and b and ns.Geo.Distance(a, b) < 50 then
    ns.print("you haven't moved from where you started recording. Type /ww dock again when you get off.")
    return
  end
  local t = {
    kind = pending.kind,
    faction = UnitFactionGroup("player"),
    time = math.max(MIN_TRIP, time() - pending.started),
    verified = true,
    a = pending.a,
    b = position,
  }
  table.insert(ns.db.transports, t)
  ns.charDB.pendingDock = nil
  ns.print(string.format("saved %s: %s to %s (%s). Routes use it now; /ww dock list to copy it.",
    t.kind, t.a.label, t.b.label, ns.FormatDuration(t.time)))
  ns.Fire("DATA_CHANGED")
end
