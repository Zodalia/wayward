# Controller support

Status: **the main window works with a controller on WoW Forever; the other
windows and the directions box have joined it but are not yet tried in
game.** Findings are from Forever
1.60.1 (build 70938), read from the game's exported interface code and
tested in game on 2026-11-16. Classic Era has no controller interface;
nothing here runs there.

The goal: every Wayward window can be used with a controller.

## Approach

Forever has a controller cursor of its own, **Smart Navigation**: the d-pad
moves it between a window's buttons, A presses one, B closes the window and
the triggers step between open windows. Wayward joins it instead of building
a focus system of its own, so its windows behave like the game's.

## How Smart Navigation works

Source: `BlizzardInterfaceCode/Interface/AddOns/Blizzard_GamepadSmartNavigation/`
(`SmartNavigation.lua`, `Utility.lua`, `SecureHelper.lua`) and
`Blizzard_GamepadSharedUtility/FrameControlsManager.lua`.

- **Joining.** `GamepadMode.FrameControlsManager:FrameShown(frame)` when a
  window opens and `:FrameHidden(frame)` when it closes. Windows shown with
  `ShowUIPanel` and native menus are registered by the game; anything else
  calls these itself, as `Blizzard_ScriptErrorsFrame` does.
- **Finding buttons.** It walks the window's children and takes every
  Button, EditBox and any frame with an `OnMouseUp` or `OnMouseDown` script.
  New children of a joined window are picked up through a `CreateFrame`
  hook.
- **Moving.** From the current button it takes the nearest button centre
  within 45 degrees of the direction pressed. The cone can be set per button
  and direction with `SmartNavigation_SetDirectionBufferThreshold`.
- **Hover and press.** Landing on a button calls its `FocusEnter`, which
  runs `OnEnter` (tooltips work unchanged). A sends `MouseDown` and
  `MouseUp`, which runs `OnClick`.
- **Closing.** B calls the window's `SmartNavigationCloseHandler` if it has
  one, else clicks `frame.CloseButton`, else a visible button with
  "CloseButton" in its name.
- **Focus.** Joining normally takes the cursor (the manager's "UI focus").
  A frame shown as a popup (`FrameShown(frame, true)`) with
  `frame.skipGamepadAutoFocus` set is added without it: if nothing has the
  cursor it becomes the frame "toggle UI focus" goes to, and if another
  window has it, it stays there. Closing the focused window passes the cursor
  to the leftmost open one, unless that window has `returnToPlayerControl`,
  which gives the controller back to the game. The game's own always-on
  frames (chat, buffs) instead join only when its radial menu asks, which
  addons can't add to.
- **Is the controller in use?** `InputUtil.IsGamepadUIEnabled()`, which
  reads `C_InputInterfaceStyle.GetCurrentStyle()`. It follows the device
  last used.
- **Events.** None for addons to register. `SmartNavigation` is a callback
  registry: `HitLeftEdge`, `HitRightEdge`, `HitTopEdge`, `HitBottomEdge`,
  `FocusedFrame`, `UnfocusedFrame`, `SelectedButtonUpdated`.

### What addons may call, and when

The system guards itself against addon taint. Calls reach it through
`SmartNavigationSecureHelper`, which allows them **only while the game is
not restricting addons for combat**
(`C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Combat)`).
A refused call shows the "interface action blocked" message.

Allowed outside combat: `FrameShown`, `FrameHidden`,
`SmartNavigation:HandlePanelOpen`, `:RefreshButtonGroups`,
`:SetTargetButtonForFrame`, `:SetScrollFrameForFrame`, `:SetWrapping`,
`:SetUseGridNavigation`, `:SelectFirstButton`, and every
`SmartNavigation_Mark...` / `..._Set...` / `..._Add...` helper in
`Utility.lua`.

Never for addons (they check for secure code and refuse): `SelectButton`,
`SetActiveFrame`, `Navigate`, `ActivateBinding`.

A jump override given as a *function* is refused in combat each time it is
used; one given as a *frame* is not.

## What is built

`Wayward/UI/Pad.lua`, loaded before the windows.

- `Pad.Window(frame, opts)` adds a window: it tells the frame manager on
  show and hide, and gives B a close handler. B hides the window, or calls
  `opts.close` when closing is more than that. Call it after the window's
  own `OnShow` / `OnHide` are set, since `SetScript` drops the hook.
- **Quiet windows** (`opts.quiet`, true or a function asked as the window
  opens) join as the game's unasked popups do, never taking the cursor (see
  Focus above). Closing a window with only quiet ones left sets
  `returnToPlayerControl`, so the controller goes back to the game rather
  than to the directions box.
- **The directions box** (`UI/HUD.lua`) is quiet: you reach it with the
  game's "toggle UI focus" binding or the triggers. B there is `Pad.LetGo`:
  the cursor goes back to the window that had it, or to the game, and the box
  stays reachable. It never ends the journey, as the box's x (which the
  manager would otherwise press) does.
- **On the way** is quiet when it comes back by itself with a new journey
  (you left it open), and takes the cursor when you open it.
- Windows that call it: the main window (`UI/Panel.lua`), the journey
  overview (`UI/JourneyOverview.lua`), the On the way pane (`UI/Drawer.lua`,
  B going through `Drawer.Hide` so it stays closed for the next journey as
  with its close button), the welcome window, the copy box, and Wayward's own
  menu (`UI/Menu.lua`, B hiding its click catcher too). The options are the
  game's Settings panel, and the TomTom question a `StaticPopup`: the game
  looks after both, as it does the native context menu.
- **Combat.** If the game is restricting addons, nothing is called; the
  window is brought in line on `PLAYER_REGEN_ENABLED`, with one retry a
  second later. A window opened in a fight has no cursor until then.
- **Rows.** The 45-degree cone made the cursor jump to the row above or
  below when going sideways, because Wayward's rows are wide and close
  together. Every button gets a 15-degree cone for left and right
  (`ROW_CONE`). Up and down keep the game's.
- **Row ends.** With a narrow cone nothing is in range at a row's end. On
  `HitLeftEdge` / `HitRightEdge` the cursor goes to the nearest button on
  that side, a step up or down counting as two sideways (`OFF_ROW_COST`),
  so the rail is one press left of every row.
- `Pad.Refresh(frame)` gives buttons made since the last look their cone;
  `Panel.Refresh` calls it.
- With a keyboard, or on Classic Era, none of it does anything.

Covered in `tests/wayward_smoke.lua` under "controller".

## Seen working in game

From a recording of the main window: the cursor appears, moves through the
rail, cards and lists, tooltips show as it lands, and labels with tooltips
(a card's level tag, for one) are stops too.

## Not yet verified in game

- Any window but the main one with the cursor: the overview, On the way,
  welcome, the copy box (its text is an EditBox: does A put the cursor in it,
  and does B still close it?) and the fallback menu.
- The directions box: that "toggle UI focus" reaches it, that it doesn't
  take the cursor as it appears, and that B on it gives the cursor back.
- Closing a game window (bags, say) while the box is up: the game passes the
  cursor to the leftmost open frame, which can be the box. We can only set
  `returnToPlayerControl` on our own windows. If it happens and grates, the
  fallback is to join the box only on demand (as chat and buffs do), from an
  edge of another window, at the cost of not reaching it with nothing else
  open.
- B on the box in combat does nothing (the manager refuses us then).
- The row fix (cone and row-end jump). The two numbers are first guesses.
- A pressing a button, and B closing the window.
- Switching page or category with the cursor on a button that goes away.
- Opening and closing the window in combat without "interface action
  blocked" messages. The game's own hooks on our window (its `OnHide` hook,
  the `CreateFrame` hook) run when we hide it or make rows in a fight;
  whether they complain is unknown.

## Still to do

1. ~~The other windows~~: done (see above), to try in game.
2. ~~The directions box~~: done, it never takes the cursor (decided
   2026-11-16), to try in game.
3. **Lists.** `SmartNavigation:SetScrollFrameForFrame` turns on right-stick
   scrolling. Wayward's lists reuse a fixed set of rows and move an offset,
   so the cursor reaching the last row needs to scroll the list itself.
4. **Picking up the controller with a window already open.** Nothing tells
   us the style changed, so the cursor appears only when the window is next
   opened.
5. **Labels as stops.** If crossing a row is tedious, mark them ignored
   (`SmartNavigation_MarkFrameIgnored`); the cost is that a controller
   player loses those tooltips.
6. **Button prompts.** The game can draw a controller glyph on a button
   (`GamepadMode.AddGamepadIconToButton`); not looked into.

## Pillars (docs/DESIGN.md)

This is access to what is already there, so it strains none of them. One to
keep in view: **guidance on demand (2)**. Tooltips are how Wayward keeps
detail off the screen, and with a controller the cursor landing on something
is the hover. Anything that removes cursor stops removes that detail for
controller players.

## Reading the game's source again

After a client update the files above may have changed.

1. Add `-console` to the game's launch arguments.
2. At the login or character screen press the backtick key and run
   `ExportInterfaceFiles code`.
3. The code lands in `_forever_/BlizzardInterfaceCode/`.

## Probes

WFProbe (`WFProbe/PadComms.lua`) records what the client offers:

- `/wfprobe` runs `input.gamepad` (the `C_GamePad` API, frame scripts,
  settings) and `input.smartNavigation` (its globals, methods and events).
- `/wfprobe pad` listens for 10 seconds on a frame of ours and records the
  buttons and sticks that reach it. This is the fallback if Smart Navigation
  ever stops accepting addon windows: a frame can read the controller
  directly (`OnGamePadButtonDown`, `OnGamePadStick`).
- `/wfprobe show` opens the report.
