local _, ns = ...

-- Opt-in profiler for finding what makes the window slow. `/ww perf on`
-- wraps Wayward's own module functions (never Blizzard's APIs) and the
-- registered data sources' functions with timers. Every outermost call (a tab
-- switch, a refresh, a search, an internal message) becomes one trace: a tree
-- of what it called, with time, call counts and the memory it allocated.
-- `/ww perf copy` opens the report for copying; `/ww perf` prints the last
-- trace. The setting survives a reload, so first-open costs are caught too.
-- Off, nothing is wrapped and nothing is measured.

local Perf = {}
ns.Perf = Perf

local KEEP_TRACES = 40      -- outermost calls kept for the report
local TRACE_MS = 2          -- outermost calls faster than this go to the background tally (per-frame work)
local MIN_MS = 0.5          -- report lines faster than this (and called once) are left out
local MAX_DEPTH = 8

-- Modules whose functions are timed, and functions left alone (called too
-- often to time, or trivial).
local MODULES = { "Panel", "Cards", "Data", "Quests", "Router", "Network", "Geo", "Places", "Harvest", "Journey",
  "Dungeons", "Trainers", "WeaponMasters", "Professions", "Vendors", "Items", "ForYou", "QuestHubs", "QuestsPage",
  "OnTheWay", "Nav", "RouteMap" }
local SKIP = { ["Geo.Distance"] = true, ["Geo.Bearing"] = true, ["Data.FriendlyTo"] = true, ["Panel.IsShown"] = true,
  ["Panel.SideShown"] = true }

local clock = function() return debugprofilestop and debugprofilestop() or 0 end
local memory = function() return collectgarbage("count") end

local enabled = false
local originals = {} -- { {table, key, fn}, ... } to put back on `off`
local wrapped = setmetatable({}, { __mode = "k" }) -- wrapper functions
local stack = {}
local traces = {}
local background = {} -- [label] = { calls, ms }: quick outermost calls (HUD ticks and the like)

local function enter(label)
  local parent = stack[#stack]
  local node
  if parent then
    node = parent.children[label]
    if not node then
      node = { label = label, ms = 0, calls = 0, children = {}, list = {} }
      parent.children[label] = node
      parent.list[#parent.list + 1] = node
    end
  else
    node = { label = label, ms = 0, calls = 0, children = {}, list = {}, at = time and time() or 0, kb = memory() }
  end
  node.calls = node.calls + 1
  stack[#stack + 1] = node
  return node, clock()
end

local function leave(node, started)
  node.ms = node.ms + (clock() - started)
  stack[#stack] = nil
  if #stack == 0 then
    node.kb = memory() - node.kb
    local window = node.label:find("^Panel%.") or node.label:find("^page:")
    if node.ms >= TRACE_MS or window then
      traces[#traces + 1] = node
      if #traces > KEEP_TRACES then table.remove(traces, 1) end
    else
      local key = node.label:match("^[^(]+")
      local b = background[key] or { calls = 0, ms = 0 }
      background[key] = b
      b.calls, b.ms = b.calls + 1, b.ms + node.ms
    end
  end
end

local function finish(node, started, ok, ...)
  leave(node, started)
  if not ok then
    -- An error unwinds past the inner wrappers: drop what is left open.
    for i = #stack, 1, -1 do stack[i] = nil end
    error((...), 0)
  end
  return ...
end

-- Outermost calls name their first arguments (which tab, which message).
local function describe(label, ...)
  if #stack > 0 then return label end
  local args = {}
  for i = 1, math.min(select("#", ...), 2) do
    local v = select(i, ...)
    if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then args[#args + 1] = tostring(v) end
  end
  return #args > 0 and (label .. "(" .. table.concat(args, ", ") .. ")") or label
end

local function wrap(tbl, key, label)
  local fn = tbl[key]
  if type(fn) ~= "function" or wrapped[fn] or SKIP[label] then return end
  local w = function(...)
    local node, started = enter(describe(label, ...))
    return finish(node, started, pcall(fn, ...))
  end
  wrapped[w] = true
  originals[#originals + 1] = { tbl, key, fn }
  tbl[key] = w
end

local function wrapAll(tbl, prefix)
  if type(tbl) ~= "table" then return end
  local keys = {}
  for key, value in pairs(tbl) do
    if type(key) == "string" and type(value) == "function" then keys[#keys + 1] = key end
  end
  for _, key in ipairs(keys) do wrap(tbl, key, prefix .. "." .. key) end
end

local PAGE_FUNCTIONS = { "Results", "SummaryText", "EmptyText" }

local function wrapPages()
  for _, page in ipairs(ns.pages or {}) do
    for _, fn in ipairs(PAGE_FUNCTIONS) do wrap(page, fn, "page:" .. tostring(page.id) .. "." .. fn) end
    for _, category in ipairs(page.categories or {}) do
      local provider = category.provider
      if type(provider) == "table" then
        for _, fn in ipairs(PAGE_FUNCTIONS) do
          wrap(provider, fn, "page:" .. tostring(page.id) .. "/" .. tostring(provider.id or category.label) .. "." .. fn)
        end
      end
    end
  end
end

local function wrapSources()
  for _, source in ipairs(ns.Data and ns.Data.Sources() or {}) do wrapAll(source, "source:" .. tostring(source.id)) end
end

function Perf.Enable()
  if enabled then return end
  enabled = true
  for _, name in ipairs(MODULES) do wrapAll(ns[name], name) end
  wrapPages()
  wrapSources()
  wrap(ns, "Fire", "Fire")
end

function Perf.Disable()
  if not enabled then return end
  enabled = false
  for i = #originals, 1, -1 do
    local o = originals[i]
    o[1][o[2]] = o[3]
  end
  originals, stack = {}, {}
end

function Perf.Enabled() return enabled end
function Perf.Reset() traces, background = {}, {} end
function Perf.Traces() return traces end

-- Sources register after Wayward loads: wrap them as they come.
ns.Listen("SOURCES_CHANGED", function() if enabled then wrapSources() end end)

ns.Listen("DB_READY", function()
  if ns.db.settings.perf then Perf.Enable() end
end)

---------------------------------------------------------------- report

local function lines(node, depth, out)
  table.sort(node.list, function(a, b) return a.ms > b.ms end)
  local childMS = 0
  for _, child in ipairs(node.list) do childMS = childMS + child.ms end
  for _, child in ipairs(node.list) do
    if child.ms >= MIN_MS or child.calls > 1 then
      out[#out + 1] = string.format("%s%-40s %8.1f ms  x%d", string.rep("  ", depth), child.label, child.ms, child.calls)
      if depth < MAX_DEPTH then lines(child, depth + 1, out) end
    end
  end
  local own = node.ms - childMS
  if #node.list > 0 and own >= MIN_MS then
    out[#out + 1] = string.format("%s%-40s %8.1f ms", string.rep("  ", depth), "(own work)", own)
  end
end

-- Totals per function over all kept traces (time, calls).
local function totals(out)
  local byLabel = {}
  local function add(node)
    for _, child in ipairs(node.list) do
      local t = byLabel[child.label] or { label = child.label, ms = 0, calls = 0 }
      byLabel[child.label] = t
      t.ms, t.calls = t.ms + child.ms, t.calls + child.calls
      add(child)
    end
  end
  for _, trace in ipairs(traces) do add(trace) end
  local list = {}
  for _, t in pairs(byLabel) do list[#list + 1] = t end
  table.sort(list, function(a, b) return a.ms > b.ms end)
  for i = 1, math.min(#list, 25) do
    out[#out + 1] = string.format("  %-40s %8.1f ms  x%d", list[i].label, list[i].ms, list[i].calls)
  end
end

-- One trace (the last when `index` is nil) as text lines.
function Perf.TraceLines(index)
  local trace = traces[index or #traces]
  if not trace then return { "no traces yet" } end
  local out = { string.format("%s  %.1f ms  %+.0f KB", trace.label, trace.ms, trace.kb) }
  lines(trace, 1, out)
  return out
end

function Perf.Report()
  local out = {
    string.format("Wayward %s perf report, %s, %d traces (newest last)", ns.VERSION,
      date and date("%Y-%m-%d %H:%M") or "?", #traces),
    "data sources: " .. tostring(ns.Data and ns.Data.Status() or "none"),
    string.format("memory: %.0f KB Lua, framerate %s", memory(), GetFramerate and string.format("%.0f", GetFramerate()) or "?"),
    "",
    "Slowest functions over all traces (nested calls count inside their callers too):",
  }
  totals(out)
  local quick = {}
  for label, b in pairs(background) do quick[#quick + 1] = { label = label, calls = b.calls, ms = b.ms } end
  table.sort(quick, function(a, b) return a.ms > b.ms end)
  if #quick > 0 then
    out[#out + 1] = ""
    out[#out + 1] = string.format("Quick calls outside the traces (each under %d ms; per-frame work shows here):", TRACE_MS)
    for i = 1, math.min(#quick, 12) do
      out[#out + 1] = string.format("  %-40s %8.1f ms  x%d", quick[i].label, quick[i].ms, quick[i].calls)
    end
  end
  for i, trace in ipairs(traces) do
    out[#out + 1] = ""
    out[#out + 1] = string.format("#%d  %s  %.1f ms  %+.0f KB", i, trace.label, trace.ms, trace.kb)
    lines(trace, 1, out)
  end
  return table.concat(out, "\n")
end

ns.RegisterCommand("perf", "/ww perf on|off|copy|reset - time what the window does (copy: a report to send)",
  function(rest)
    local cmd = (rest or ""):lower()
    if cmd == "on" then
      ns.db.settings.perf = true
      Perf.Enable()
      ns.print("perf tracking on (stays on after a reload). Use the window, then /ww perf copy.")
    elseif cmd == "off" then
      ns.db.settings.perf = nil
      Perf.Disable()
      ns.print("perf tracking off")
    elseif cmd == "reset" then
      Perf.Reset()
      ns.print("perf traces cleared")
    elseif cmd == "copy" then
      ns.ShowCopyBox("Wayward perf report", Perf.Report())
    else
      if not enabled then return ns.print("perf tracking is off: /ww perf on") end
      for _, line in ipairs(Perf.TraceLines()) do ns.print(line) end
    end
  end)
