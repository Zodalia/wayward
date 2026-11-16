# Controller support

Status: **the main window works with a controller on WoW Forever; the other
windows have joined it but are not yet tried in game. The directions box
stays out of the cursor's way; a key binding gives it the cursor.** Findings are from Forever
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
  `frame.skipGamepadAutoFocus` set is added without it, and a frame with
  `returnToPlayerControl` gives the controller back to the game as it
  closes; but an addon can't use either (see Taint). The game's own
  always-on frames (chat, buffs) join only when its radial menu asks, which
  addons can't add to, and leave again on B.
- **Is the controller in use?** `InputUtil.IsGamepadUIEnabled()`, which
  reads `C_InputInterfaceStyle.GetCurrentStyle()`. It follows the device
  last used, and `INPUT_DEVICE_INTERFACE_TRANSITION` (new style, old style)
  fires as it changes; addons can register it.
- **Putting the controller down** resets the frame manager
  (`UninitializeGamepad` → `ResetVars`): it forgets every window it had.
  Picking it up doesn't bring any back.
- **Scrolling.** The right stick scrolls the window's "current scroll
  frame" (`SmartNavigation:SetScrollFrameForFrame`, which needs the window
  to have had the cursor). It knows three kinds: a ScrollFrame, a ScrollBox,
  and anything with `isScrollingMessageFrame` (chat), which it moves by
  whole lines through `GetMaxScrollRange`, `GetScrollOffset` (counting up
  from the bottom) and `ScrollByAmount`, at
  `smartNavRightStickMaxScrollSpeed` lines a second if set. The d-pad only
  scrolls buttons it found inside a ScrollFrame or ScrollBox.
- **Events.** None for addons to register. `SmartNavigation` is a callback
  registry: `HitLeftEdge`, `HitRightEdge`, `HitTopEdge`, `HitBottomEdge`,
  `FocusedFrame`, `UnfocusedFrame`, `SelectedButtonUpdated` (no arguments;
  read `GetCurrentButton`). `FocusedFrame` and `UnfocusedFrame` are declared
  but never fired.
- **Per-button overrides** (`SmartNavigation_AddJumpNavigationOverride`):
  a frame or `true` is laundered and works in combat; a function is refused
  in combat with the "interface action blocked" message each time it is
  used. Scrolling a list needs to decide per press, so it uses the callbacks
  instead.

#- **Button prompts.** `GamepadMode.AddGamepadIconToButton(button, key)`
  (`Blizzard_GamepadSharedUtility/FrameReformUtility.lua`) puts an
  `InputIconTextureFrameTemplate` (shared XML, always loaded) on a button:
  beside its text, or over its middle when it has none. The game labels only
  buttons that a face button presses directly, as its popups do (A on
  Accept, B on Cancel, X and Y on a third and fourth); under the cursor, A
  presses whatever the cursor is on. The manager's `isUIFocused` and
  `focusedFrame` say which window has the cursor.

## Taint

Learnt the hard way (an `ADDON_ACTION_FORBIDDEN` for
`SetPreferredGamepadInteractTarget()` at login): the game launders what an
addon passes in (`SmartNavigationSecureHelper` reads the arguments through
`securecallfunction`), but **not the fields it reads off those frames**. We
had set `skipGamepadAutoFocus` on the directions box; the manager copied it
into its own `isUIFocused`, so its state carried Wayward's taint, and when
the chat window joined at login the manager's next protected call was
refused in Wayward's name.

So:

- Set nothing on a window that the manager or Smart Navigation reads
  (`skipGamepadAutoFocus`, `returnToPlayerControl`, `skipFrameDeactivation`,
  `useCustomNavigation`, `FrameControlManagerGroup`, `dismissOnUnfocus`,
  `disallowGamepadUnfocus`, `isScrollingMessageFrame`, ...), and hand it no
  table of ours whose fields or functions it reads or calls in its own code
  (the right-stick scroll frame is one). The smoke test checks the window
  fields.
- Safe: arguments to the wrapped calls; values set through the
  `SmartNavigation_Set...` / `_Mark...` / `_Add...` helpers (they go through
  `SecureHelper:SetSecureValue`, which launders them, a function excepted);
  `SmartNavigationCloseHandler`, called through `securecallfunction`; and
  callbacks on the `SmartNavigation` registry, each run through
  `securecallfunction`.

## The main menu wheel

The controller's main menu wheel (`Blizzard_Gamepad/UI/Radials/GamepadRadial.lua`)
has no way for addons to add an entry. Its entries are hard-coded in
`GamepadRadial.segmentOptions` and placed on three pages in
`GamepadRadial.mainMenuPages`; the right page has five empty slots. Both
tables are reachable, so an addon *could* write a handler into an empty slot,
but it would be the taint above again: as the wheel fills a page
(`FillSegmentData`) it reads our handler, and the segments after it are set
up from tainted code, so pressing one of the game's own entries (PvP on the
same page) could be refused in Wayward's name. The game's own always-on
frames (chat, buffs) are reached from it only because they're its own
entries. So: no wheel entry; the key binding instead.

## What addons may call, and when

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
used; one given as a *frame* is not (`SetSecureValue` launders a frame, and
wraps a function to run insecurely).

## What is built

`Wayward/UI/Pad.lua`, loaded before the windows.

- `Pad.Window(frame, opts)` adds a window: it tells the frame manager on
  show and hide, and gives B a close handler. B hides the window, or calls
  `opts.close` when closing is more than that. Call it after the window's
  own `OnShow` / `OnHide` are set, since `SetScript` drops the hook.
- **Quiet windows** (`opts.quiet`, true or a function asked as the window
  opens) mustn't take the cursor, and can't be in the manager's list without
  taking it (see Taint), so they stay out of it until reached:
  `Pad.Reach(frame)` joins an open one normally, and `Pad.LetGo(frame)`
  takes it out again, the manager handing the cursor back to the window that
  had it, or to the game.
- **The directions box** (`UI/HUD.lua`) is quiet. Its key binding,
  "Controller cursor to the directions box" (Key Bindings > AddOns >
  Wayward, `WAYWARD_DIRECTIONS_CURSOR` in `Bindings.xml`, which the player
  can put on a controller button), gives it the cursor, and gives it back
  when pressed again. B there is `Pad.LetGo` too: it never ends the
  journey, as the box's x (which the manager would otherwise press) does.
  `Pad.Reach` does nothing with a keyboard, and in combat it shows the
  game's "can't do that in combat" line rather than waiting (a wait would
  take the cursor when the fight ends, long after it was asked for).
- **On the way** is quiet when it comes back by itself with a new journey
  (you left it open), and joins when you open it.
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
- **Lists.** `Pad.List(window, { rows, at, scroll })` hands a window's list
  to the controller: the main window's list pane and the journey overview's
  stops. When the cursor moves down off the last row shown into something
  below the list (or there is nothing below: `HitBottomEdge`), and the list
  has more, it scrolls one line and the cursor goes back onto that row, on
  the same button if it still shows. The same going up off the first row.
  In combat it doesn't scroll (the call would be refused); the cursor then
  leaves the list as it would without this. **No right stick**: the stand-in
  we tried (a table that looked like a chat window) would have tainted Smart
  Navigation's update code, which reads its fields and calls its functions.
  A real hidden ScrollFrame, whose `OnVerticalScroll` script moves our list,
  might be safe (the game would only call its C methods), but whether a
  script it fires that way taints the caller is untested.
- **Picking up and putting down.** On `INPUT_DEVICE_INTERFACE_TRANSITION`,
  a tick later (after the game's own handlers): put down, we forget which
  windows joined, as the manager does; picked up, every Wayward window open
  then joins, the directions box and an On the way that came back by itself
  quietly. In combat that waits for combat to end, like any other join.
- **B on the x.** `Pad.Window(frame, { closeButton = x })`: while that
  window has the cursor (the manager's `focusedFrame`, checked as the cursor
  moves), B's glyph stands in for its x, the x's own textures faded (a
  skin's extra frames are left alone). Elsewhere, closed, or with a keyboard,
  the x is back. On the main window, the overview, On the way, welcome and
  the copy box. Not on the directions box (its x ends the journey, and B
  there gives the cursor back) or the fallback menu (no x). No other
  prompts: A presses whatever the cursor is on, so a glyph on one button
  would say something untrue of the rest.
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
- That the `ADDON_ACTION_FORBIDDEN` at login is gone, and no other turns
  up (BugGrabber), with a controller, the directions box up, and windows
  opened and closed in and out of combat.
- The directions box's key binding: bound to a controller button, that it
  gives the box the cursor and gives it back, and that B on the box does
  too.
- Picking up the controller with a window open: the cursor should appear
  in it at once. With more than one of ours open, the last to join takes
  it (they join in the order they were first made).
- B's glyph on the x: that it shows, its size and look on our close buttons
  and under a skin, and that it goes when the game's "toggle UI focus" takes
  the cursor away (we hear of that only if the game reports the cursor
  leaving its button, which isn't confirmed).
- List scrolling: the d-pad off a list's end. After a scroll the
  cursor stays on a row that now shows another line: its tooltip may still
  show the old one until the cursor moves.
- The row fix (cone and row-end jump). The two numbers are first guesses.
- A pressing a button, and B closing the window.
- Switching page or category with the cursor on a button that goes away.
- Opening and closing the window in combat without "interface action
  blocked" messages. The game's own hooks on our window (its `OnHide` hook,
  the `CreateFrame` hook) run when we hide it or make rows in a fight;
  whether they complain is unknown.

## Still to do

1. ~~The other windows~~: done (see above), to try in game.
2. ~~The directions box~~: never takes the cursor (decided 2026-11-16), so
   it stays out of the manager's list (see Taint); a key binding reaches it
   (decided 2026-11-16). To try in game.
3. ~~Lists~~: the d-pad done (see above), to try in game. The right stick
   isn't (see Lists above).
4. ~~Picking up the controller with a window already open~~: done (see
   above), to try in game. This also fixed putting the controller down and
   picking it up again with a window open, which had left that window
   without the cursor until it was closed and opened again.
5. **Labels as stops.** If crossing a row is tedious, mark them ignored
   (`SmartNavigation_MarkFrameIgnored`); the cost is that a controller
   player loses those tooltips.
6. ~~Button prompts~~: B on the x (see above), to try in game.

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
