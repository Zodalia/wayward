local _, ns = ...

-- Controller support. WoW Forever has a cursor of its own for controllers
-- (Smart Navigation): the d-pad moves it between a window's buttons, A presses
-- one, B closes the window, the triggers step between open windows. Its own
-- windows join by themselves; ours tell its frame manager when they open and
-- close (GamepadMode.FrameControlsManager, as Blizzard_ScriptErrorsFrame
-- does). It then finds the window's buttons itself, runs their OnEnter as the
-- cursor lands and clicks them as a mouse would.
--
-- Those calls are refused while the game restricts addons in combat, each
-- refusal with an "interface action blocked" message, so in combat we wait and
-- tell it once combat ends. A window opened in a fight has no cursor until
-- then. Classic Era has none of this: everything here does nothing there.

local Pad = {}
ns.Pad = Pad

local windows = {}   -- each frame added, in order
local joined = {}    -- frame -> true once the manager has been told it's open
local quiet = {}     -- frame -> true while it's open but joins only when reached
local reached = {}   -- frame -> true: a quiet window asked for (Pad.Reach)
local waiting = false

local function manager()
  local mode = GamepadMode
  local m = type(mode) == "table" and mode.FrameControlsManager
  if type(m) == "table" and type(m.FrameShown) == "function" and type(m.FrameHidden) == "function" then
    return m
  end
end

-- The interface is in its controller style (it follows the device in use).
local function padStyle()
  local util = InputUtil
  if type(util) ~= "table" or type(util.IsGamepadUIEnabled) ~= "function" then return false end
  local ok, on = pcall(util.IsGamepadUIEnabled)
  return ok and on == true
end

local function restricted()
  local actions, kinds = C_RestrictedActions, Enum and Enum.AddOnRestrictionType
  if actions and actions.IsAddOnRestrictionActive and kinds and kinds.Combat ~= nil then
    local ok, on = pcall(actions.IsAddOnRestrictionActive, kinds.Combat)
    if ok then return on == true end
  end
  return InCombatLockdown ~= nil and InCombatLockdown() == true
end

---------------------------------------------------------------- rows

-- Smart Navigation moves to the nearest button whose centre is within 45
-- degrees of the way pressed. Our rows are wide and close together, so going
-- left or right the nearest centre is often in the row above or below. Each
-- of our buttons gets a narrow cone sideways instead, which keeps the cursor
-- on its row; up and down keep the game's own.
local ROW_CONE = 15
-- At the end of a row nothing is in that cone. Then the cursor goes to the
-- button on that side that is nearest, counting a step up or down as this
-- many steps sideways (so the rail is still one press left of every row).
local OFF_ROW_COST = 2

local narrowed = setmetatable({}, { __mode = "k" })   -- frames looked at already

-- What the cursor can land on: the game's own test.
local function focusable(f)
  if not f.IsObjectType then return false end
  if f:IsObjectType("Button") or f:IsObjectType("EditBox") then return true end
  return f.GetScript ~= nil and (f:GetScript("OnMouseUp") ~= nil or f:GetScript("OnMouseDown") ~= nil)
end

local function each(frame, fn)
  if not frame.GetChildren then return end
  for _, child in ipairs({ frame:GetChildren() }) do
    fn(child)
    each(child, fn)
  end
end

-- Gives every button in the window its narrow sideways cone. Only new ones
-- need it; like the rest, it has to wait for combat to end.
local function narrow(frame)
  local set, dirs = SmartNavigation_SetDirectionBufferThreshold, SMART_NAV_INPUT_DIRECTION
  if type(set) ~= "function" or type(dirs) ~= "table" or not (dirs.LEFT and dirs.RIGHT) then return end
  if restricted() then return end
  each(frame, function(child)
    if narrowed[child] then return end
    narrowed[child] = true
    local ok, can = pcall(focusable, child)
    if ok and can then
      pcall(set, child, dirs.LEFT, ROW_CONE)
      pcall(set, child, dirs.RIGHT, ROW_CONE)
    end
  end)
end

-- Of `spots` ({ x, y } centres), the index of the one to go to from `from`
-- when nothing is on its row to that side (`side`: -1 left, 1 right).
function Pad.Beyond(from, spots, side)
  local best, bestCost
  for i, spot in ipairs(spots) do
    local dx, dy = (spot.x - from.x) * side, math.abs(spot.y - from.y)
    if dx > 0.5 then
      local cost = dx + dy * OFF_ROW_COST
      if not bestCost or cost < bestCost then best, bestCost = i, cost end
    end
  end
  return best
end

local function centre(f)
  if not (f.IsVisible and f:IsVisible()) then return end
  local left, bottom, width, height
  if f.GetScaledRect then left, bottom, width, height = f:GetScaledRect() end
  if not left and f.GetRect then left, bottom, width, height = f:GetRect() end
  if not (left and bottom and width and height) then return end
  return { x = left + width / 2, y = bottom + height / 2 }
end

-- The window of ours that a frame is in.
local function windowOf(f)
  local hops = 0
  while f and hops < 40 do
    if joined[f] then return f end
    f = f.GetParent and f:GetParent()
    hops = hops + 1
  end
end

-- The cursor ran out of row: on to the nearest button on that side.
local function offRow(side)
  local nav = SmartNavigation
  if type(nav) ~= "table" or restricted() then return end
  local current = nav.GetCurrentButton and nav:GetCurrentButton()
  local window = current and windowOf(current)
  local from = window and centre(current)
  if not from then return end
  local frames, spots = {}, {}
  local ignored = SmartNavigation_IsFrameIgnored
  each(window, function(child)
    if child == current or not focusable(child) then return end
    if type(ignored) == "function" and ignored(child) then return end
    local spot = centre(child)
    if spot then
      frames[#frames + 1], spots[#spots + 1] = child, spot
    end
  end)
  local pick = Pad.Beyond(from, spots, side)
  if pick and nav.SetTargetButtonForFrame then nav:SetTargetButtonForFrame(window, frames[pick]) end
end

---------------------------------------------------------------- prompts

-- The game labels a button with the controller button that presses it (its
-- popups: A on Accept, B on Cancel). With the cursor, A presses whatever it's
-- on, so the one label that holds for our windows is B on the close button,
-- B closing the window. While the window has the cursor, B's glyph stands
-- in for the x (the x's own textures fade; a skin's stay its own); otherwise,
-- and with a keyboard, the x is back. Not on the directions box: its x ends
-- the journey, and B there doesn't.
local prompts = {}   -- window -> { button, icon, faded = { region -> alpha } }
local PROMPT_SCALE = 0.8 -- of the close button's height, as the game's

local function promptShown(window, on)
  local p = prompts[window]
  if not p or p.failed or (p.on or false) == on then return end
  if on and not p.icon then
    local ok, icon = pcall(CreateFrame, "Frame", nil, p.button, "InputIconTextureFrameTemplate")
    if not (ok and icon and icon.SetInputKey) then
      p.failed = true
      return
    end
    pcall(icon.SetInputKey, icon, GAMEPAD_FACE_RIGHT or "PAD2")
    local size = math.floor((p.button:GetHeight() or 24) * PROMPT_SCALE)
    icon:SetSize(size, size)
    icon:SetPoint("CENTER", p.button, "CENTER", 0, 0)
    icon:SetFrameLevel((p.button:GetFrameLevel() or 0) + 2)
    p.icon = icon
  end
  p.on = on
  if p.icon then p.icon:SetShown(on) end
  if on then
    p.faded = {}
    for _, region in ipairs({ p.button:GetRegions() }) do
      if region.GetAlpha then
        p.faded[region] = region:GetAlpha()
        region:SetAlpha(0)
      end
    end
  else
    for region, alpha in pairs(p.faded or {}) do region:SetAlpha(alpha) end
    p.faded = nil
  end
end

-- B's glyph on the window that has the cursor, on none other.
local function refreshPrompts()
  local m = padStyle() and manager()
  local focused = m and m.isUIFocused and m.focusedFrame
  for window in pairs(prompts) do
    promptShown(window, focused == window and joined[window] == true and window:IsShown())
  end
end

-- Whether B's glyph shows on a window's close button (for tests).
function Pad.Prompted(window)
  local p = prompts[window]
  return p ~= nil and p.on == true
end

---------------------------------------------------------------- lists

-- Our lists draw a fixed set of rows and move an offset; the game only
-- scrolls its own scroll frames. So we scroll them ourselves: the d-pad
-- moving off the last row shown (or the first) scrolls one line and keeps
-- the cursor on that row. Not the right stick: it reads the frame it scrolls
-- from the game's own update code, and anything of ours it read there would
-- carry our taint into Smart Navigation (see "Taint" in docs/CONTROLLER.md).
local lists = {}    -- window -> { rows = fn, at = fn, scroll = fn }
local previous      -- the button the cursor was on
local moving = false -- we're moving the cursor ourselves

local function inside(f, ancestor)
  local hops = 0
  while f and hops < 40 do
    if f == ancestor then return true end
    f = f.GetParent and f:GetParent()
    hops = hops + 1
  end
  return false
end

local function visibleRows(list)
  local out = {}
  for _, row in ipairs(list.rows() or {}) do
    if row.IsShown and row:IsShown() then out[#out + 1] = row end
  end
  return out
end

-- The button to land on in `row` after it scrolled: `prefer` if it still
-- shows, else the first that does.
local function landing(row, prefer)
  if prefer and prefer.IsVisible and prefer:IsVisible() and inside(prefer, row) then return prefer end
  if focusable(row) and row:IsVisible() then return row end
  local found
  each(row, function(child)
    if not found and child.IsVisible and child:IsVisible() and focusable(child) then found = child end
  end)
  return found
end

-- Scrolls `list` one line `way` (1 down, -1 up) if it has more that way.
local function step(list, way)
  local at, max = list.at()
  if not (at and max) then return false end
  if way > 0 and at >= max or way < 0 and at <= 0 then return false end
  list.scroll(-way)
  return true
end

-- Puts the cursor (back) on `button` in `window`.
local function land(window, button)
  local nav = SmartNavigation
  if not (button and nav and nav.SetTargetButtonForFrame) then return end
  moving = true
  pcall(nav.SetTargetButtonForFrame, nav, window, button)
  moving = false
  previous = button
end

-- The cursor went from `from` to `to`. Off the end of a list with more in
-- it: scroll instead, and back onto that row.
local function offList(from, to, way)
  local window = from and windowOf(from)
  local list = window and lists[window]
  if not list then return end
  local rows = visibleRows(list)
  local edge = way > 0 and rows[#rows] or rows[1]
  if not (edge and inside(from, edge)) then return end
  if to then
    -- Still in the list, or not past that edge: nothing to do.
    for _, row in ipairs(rows) do
      if inside(to, row) then return end
    end
    local a, b = centre(from), centre(to)
    if not (a and b) or (way > 0 and b.y >= a.y) or (way < 0 and b.y <= a.y) then return end
  end
  if step(list, way) then land(window, landing(edge, from)) end
end

local function selected()
  if moving then return end
  local nav = SmartNavigation
  local current = nav and nav.GetCurrentButton and nav:GetCurrentButton()
  local from = previous
  previous = current
  refreshPrompts()
  if restricted() then return end
  local window = current and windowOf(current)
  if from and current and from ~= current and windowOf(from) == window then
    offList(from, current, 1)
    if previous == current then offList(from, current, -1) end
  end
end

-- Nothing at all below (or above) the cursor: scroll if it's on a list's edge.
local function hitEdge(way)
  if restricted() then return end
  local nav = SmartNavigation
  local current = nav and nav.GetCurrentButton and nav:GetCurrentButton()
  if current then offList(current, nil, way) end
end

local listening = false

local function listen()
  local nav = SmartNavigation
  if listening or type(nav) ~= "table" or type(nav.RegisterCallback) ~= "function" then return end
  listening = true
  pcall(nav.RegisterCallback, nav, "HitLeftEdge", function() pcall(offRow, -1) end, Pad)
  pcall(nav.RegisterCallback, nav, "HitRightEdge", function() pcall(offRow, 1) end, Pad)
  pcall(nav.RegisterCallback, nav, "HitBottomEdge", function() pcall(hitEdge, 1) end, Pad)
  pcall(nav.RegisterCallback, nav, "HitTopEdge", function() pcall(hitEdge, -1) end, Pad)
  pcall(nav.RegisterCallback, nav, "SelectedButtonUpdated", function() pcall(selected) end, Pad)
end

-- Gives a window's list to the controller. `list`:
--   rows():  its row frames, top to bottom (the hidden ones are skipped)
--   at():    lines scrolled past at the top, and the most there can be
--   scroll(delta): moves it, positive going up (as the mouse wheel)
function Pad.List(window, list)
  if window and list then lists[window] = list end
end

-- A window's contents changed: any new buttons keep to their rows too.
function Pad.Refresh(frame)
  if frame and joined[frame] then narrow(frame) end
end

-- How many degrees wide the sideways cone is (for tests).
function Pad.RowCone() return ROW_CONE end

---------------------------------------------------------------- windows

-- Taint: the game launders the windows we pass it, but not the fields it
-- reads off them. Anything we set on a window that its frame manager reads
-- (skipGamepadAutoFocus, returnToPlayerControl, ...) taints the manager's
-- own state, and the next protected call it makes for any frame is refused
-- in Wayward's name. So we pass windows and set nothing on them that it
-- reads; the only field we set is the close handler, which it calls through
-- securecallfunction. Hence a quiet window (one that mustn't take the
-- cursor) can't be in its list without taking it: it stays out until it's
-- reached (Pad.Reach), as the game's own chat window does.
local function join(m, frame)
  return pcall(m.FrameShown, m, frame)
end

local function leave(m, frame)
  pcall(m.FrameHidden, m, frame)
end

-- Brings the manager's idea of one window in line with whether it's open
-- (and, for a quiet one, reached).
local function sync(frame)
  local m = manager()
  if not m then return end
  local shown = frame:IsShown() and (not quiet[frame] or reached[frame] == true) or false
  if shown == (joined[frame] == true) then return end
  -- Leaving is owed even after the controller is put down; joining isn't.
  if shown and not padStyle() then return end
  if restricted() then
    waiting = true
    return
  end
  if shown then
    joined[frame] = join(m, frame) or nil
    if joined[frame] then
      listen()
      narrow(frame)
    end
  else
    joined[frame] = nil
    leave(m, frame)
  end
end

local function syncAll()
  waiting = false
  for _, frame in ipairs(windows) do sync(frame) end
end

-- Adds a window: the controller's cursor works in it while it's open, and B
-- closes it. Options (`opts`, all optional):
--   close: how B closes it, when that's more than hiding it (as with its own
--          close button); otherwise B hides it.
--   quiet: true, or a function asked each time it opens: it opens without
--          taking the cursor, and so without joining (see join) until it's
--          reached (Pad.Reach).
--   closeButton: its x, which shows B's glyph while the window has the
--          cursor (see prompts).
-- Call it after the window's own OnShow and OnHide are set: setting one
-- replaces our hook.
function Pad.Window(frame, opts)
  if not frame then return end
  for _, known in ipairs(windows) do
    if known == frame then return end
  end
  opts = opts or {}
  windows[#windows + 1] = frame
  -- What B does (the manager looks for this by name).
  frame.SmartNavigationCloseHandler = function(self)
    if opts.close then opts.close(self) else self:Hide() end
    return true
  end
  local function shown(self)
    -- Decided as it opens, not when combat lets it join.
    local q = opts.quiet
    if type(q) == "function" then q = q(self) end
    quiet[self] = q and true or nil
    sync(self)
  end
  if opts.closeButton then prompts[frame] = { button = opts.closeButton } end
  frame:HookScript("OnShow", shown)
  frame:HookScript("OnHide", function(self)
    reached[self] = nil
    sync(self)
    promptShown(self, false)
  end)
  if frame:IsShown() then shown(frame) end
end

-- Gives an open quiet window the cursor, as asked. Only now: with a
-- keyboard it does nothing, and in combat (the game would refuse it) it
-- returns false, "combat" rather than waiting, which would take the cursor
-- when the fight ends, long after it was asked for.
function Pad.Reach(frame)
  if not (frame and frame:IsShown() and padStyle() and manager()) then return false end
  if restricted() then return false, "combat" end
  reached[frame] = true
  sync(frame)
  return joined[frame] == true
end

-- Gives the cursor back without closing the window (B on the directions box):
-- to the window that had it, or to the game. It leaves the game's list until
-- it's reached again.
function Pad.LetGo(frame)
  quiet[frame] = true
  reached[frame] = nil
  sync(frame)
end

-- Whether the controller's cursor has been given this window (for tests).
function Pad.Joined(frame)
  return joined[frame] == true
end

-- Whether it's open, kept out of the cursor's way (for tests).
function Pad.Quiet(frame)
  return quiet[frame] == true
end

-- Whether a window is waiting for combat to end (for tests).
function Pad.Waiting()
  return waiting
end

-- The controller picked up or put down (the interface follows the device in
-- use). Put down, the game's frame manager forgets every window it had
-- (ResetVars), so we forget them too; picked up, every window open now
-- joins, but for quiet ones not reached. A tick later: the game's own handlers for the
-- same event set its cursor up first.
local function transition()
  if not padStyle() then
    for frame in pairs(joined) do joined[frame] = nil end
    previous = nil
    refreshPrompts()
    return
  end
  syncAll()
end

ns.On("INPUT_DEVICE_INTERFACE_TRANSITION", function()
  ns.After(0, transition)
end)

local RETRY = 1

ns.On("PLAYER_REGEN_ENABLED", function()
  if not waiting then return end
  syncAll()
  -- The restriction can outlast the event by a moment: one more go.
  if waiting then ns.After(RETRY, function() if waiting then syncAll() end end) end
end)
