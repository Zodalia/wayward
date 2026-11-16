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

local listening = false

local function listen()
  local nav = SmartNavigation
  if listening or type(nav) ~= "table" or type(nav.RegisterCallback) ~= "function" then return end
  listening = true
  pcall(nav.RegisterCallback, nav, "HitLeftEdge", function() pcall(offRow, -1) end, Pad)
  pcall(nav.RegisterCallback, nav, "HitRightEdge", function() pcall(offRow, 1) end, Pad)
end

-- A window's contents changed: any new buttons keep to their rows too.
function Pad.Refresh(frame)
  if frame and joined[frame] then narrow(frame) end
end

-- How many degrees wide the sideways cone is (for tests).
function Pad.RowCone() return ROW_CONE end

---------------------------------------------------------------- windows

-- Brings the manager's idea of one window in line with whether it's open.
local function sync(frame)
  local m = manager()
  if not m then return end
  local shown = frame:IsShown() and true or false
  if shown == (joined[frame] == true) then return end
  -- Leaving is owed even after the controller is put down; joining isn't.
  if shown and not padStyle() then return end
  if restricted() then
    waiting = true
    return
  end
  if shown then
    joined[frame] = pcall(m.FrameShown, m, frame) or nil
    if joined[frame] then
      listen()
      narrow(frame)
    end
  else
    joined[frame] = nil
    pcall(m.FrameHidden, m, frame)
  end
end

local function syncAll()
  waiting = false
  for _, frame in ipairs(windows) do sync(frame) end
end

-- Adds a window: the controller's cursor works in it while it's open, and B
-- closes it.
function Pad.Window(frame)
  if not frame then return end
  for _, known in ipairs(windows) do
    if known == frame then return end
  end
  windows[#windows + 1] = frame
  -- What B does (the manager looks for this by name).
  frame.SmartNavigationCloseHandler = function(self)
    self:Hide()
    return true
  end
  frame:HookScript("OnShow", sync)
  frame:HookScript("OnHide", sync)
  if frame:IsShown() then sync(frame) end
end

-- Whether the controller's cursor has been given this window (for tests).
function Pad.Joined(frame)
  return joined[frame] == true
end

-- Whether a window is waiting for combat to end (for tests).
function Pad.Waiting()
  return waiting
end

local RETRY = 1

ns.On("PLAYER_REGEN_ENABLED", function()
  if not waiting then return end
  syncAll()
  -- The restriction can outlast the event by a moment: one more go.
  if waiting then ns.After(RETRY, function() if waiting then syncAll() end end) end
end)
