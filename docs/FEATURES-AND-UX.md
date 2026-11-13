# Wayward: features and UX spec

Written 2026-11-13 against `main` at a411a18 (0.4.0 beta 2 plus the 0.5
rework). It describes the addon as the code and README stand today, not a
plan. Sizes are in UI pixels at UI scale 1 and come from the constants at the
top of each `Wayward/UI/*.lua` file. Nothing here has been checked in game;
[docs/DESIGN.md](DESIGN.md) stays the authority on pillars and vocabulary,
and [docs/copy.md](copy.md) on exact strings.

Contents: [1. What Wayward is](#1-what-wayward-is) ·
[2. Pillars and vocabulary](#2-pillars-and-vocabulary) ·
[3. Features](#3-features) · [4. Surfaces](#4-ux-spec-surfaces) ·
[5. Interactions](#5-ux-spec-interactions-and-flows) ·
[6. States, copy and look](#6-ux-spec-states-copy-and-look) ·
[7. Settings and saved data](#7-settings-and-saved-data) ·
[8. Gaps and open questions](#8-gaps-and-open-questions)

## 1. What Wayward is

Wayward is a levelling helper that works like a map app, not a guide. It
suggests what is worth doing near the character and gives step-by-step
directions there: on foot, by flight path, boat, zeppelin, tram and portal.
It is not a speed-levelling route.

| | |
|---|---|
| Clients | WoW Forever (Interface 16001), Classic Era 1.15.9 (11509; 11508 test realm), including Season of Discovery and Hardcore. One folder, one TOC. |
| Locale | Directions work everywhere. Trainers, vendors, weapon masters, professions and dungeons from data sources are matched by English names. |
| Optional | QuestieDB (quests, items, NPCs, entrances, quest XP), TomTom (arrow and pins), LibDBIcon (minimap button), EllesmereUI / ElvUI (skin). |
| Entry points | `/ww` (`/wayward`, `/wf`), minimap button, addon compartment, one key binding (target the step's NPC). |
| Saved data | `WaywardDB` (account), `WaywardCharDB` (character). |

## 2. Pillars and vocabulary

Every surface below is held to the five pillars in DESIGN.md.

| # | Pillar | What it means on screen |
|---|---|---|
| 1 | Direction, not prescription | Suggest and explain. No grading, no nagging back onto a route. Offers make no sound and never move the arrow. |
| 2 | Guidance on demand | A glance gives the gist; hover, click or "+" gives the next level. Nothing extra is forced on screen. |
| 3 | Adventure over optimisation | XP per minute is one input to relevance, never the sort key or headline. XP lives in tooltips. |
| 4 | Respect the journey | Cut travel friction honestly (real crossings, real times) without reducing the world to waypoints. |
| 5 | Player-owned progress | Reorder, add, drop, pin, set aside, resume. Wayward re-plans around the player. |

Words the player reads:

| Term | Meaning | Never |
|---|---|---|
| Journey | The adventure the player chose. One active at a time. | trip, route, run |
| Stop | A meaningful objective or destination in a journey. | leg, waypoint |
| Step | One instruction on the way to a stop ("Fly to Stormwind"). | leg, hop |
| Detour | An optional stop added to a journey. | errand, side trip |
| Directions | Plain A-to-B with no journey. | trip |
| Suggestion | A possible journey on the home screen (a card). | recommendation |
| Observation | A small useful fact with at most one action (a Good to know tile). | need, alert, nag |
| On the way | The surface that offers detours. | shopping list |
| Set aside | A journey saved to resume later. | suspend, pause |

## 3. Features

### 3.1 Home screen ("For you")

| Feature | What it does |
|---|---|
| Your journey | The active journey: icon, title, current stop, "Stop 3 of 5 · 2 complete · ~6 min remaining", progress bar, "Then: ..." line, route map, **Continue journey**, **View details**. |
| Something to do next | Suggestion cards, three per page, picked by role (continue, explore, alternative) from a relevance score, not by rank. |
| Where to quest | Up to four zones: the one you're in first, then level fit, then distance. Never by XP. Not hidden by the time budget. |
| Good to know | Up to four observations, most urgent first, each with at most one action: **Add detour**, **Show ...**, **Go** or **Resume**. |
| Time budget | 15 / 30 / 60 / Any buttons (`/ww time`). Filters suggestions to what fits; if nothing fits, offers the quickest "a bit over". |
| Learned quest time | Times quests accepted and handed in within a session; after 5, the average of the last 20 replaces the 5-minute default. |
| Profile bar | A percentage of what makes suggestions good (flight map per continent, class trainer, Hearthstone, quest data). Gone the session after 100%. |

Suggestion providers: Don't miss (notable quest), Profession (next rank),
Hand in, Finish, Best quest, Questing zone, Dungeon / Raid.

Relevance = 0.30 suitability + 0.20 proximity + 0.20 progression + 0.15
novelty + 0.15 intent. Each card's one-sentence "why" names its two strongest
parts in words, never as scores.

Observations: gear broken or at 50% or lower, low or no ammo, low food and
drink, bags full, spells to train and affordable, profession at cap, quests
ready to hand in, undiscovered flight path within about 3 minutes, gear at
75% with a repairer under 2 minutes away, trainer visit due, spells you can't
afford, spells coming at the next level or two, a vendor close by while bags
fill, a set-aside journey to resume.

### 3.2 Journeys

| Feature | What it does |
|---|---|
| Planning | Stops are put in the quickest order, each quest in its own order (pick up, do, hand in), interleaved by travel time. |
| Stop kinds | pickup, complete, turnin, item, manual, talk, train (profession), explore, enter (dungeon), learn (class spells). |
| Whole-quest stops | Source items first, extra objectives in order, items bought or earned from another quest ("Buy 5 Rhapsody Malt from Innkeeper Firebrew"). |
| Objective areas | Spawns grouped into camps. Within 80 yards: "In the area". Leave past 120 yards. Cleared camps rest 5 minutes; "Next spot", "Camp looks cleared", "~3 min left here". |
| Re-planning | Automatic as you go, after hearth, portal or loading screen, at most every 10 seconds, never in flight. Only changes the next stop when another is clearly nearer. |
| Reorder, drop, pin | In the overview: drag a stop, drop it (with the stops that need it), or lock it in place. |
| Skip / do later | **Skip this stop** asks, then removes it. **Do this stop later** moves it after the next stop that doesn't need it. |
| Add detour | Any row, card, tile or offer can join the journey; it goes where it adds least travel. |
| Set aside and resume | Up to five journeys kept. They follow the quest log and leave the list when nothing is left to do. |
| Quest pickups | A quest that adds 3 minutes or less joins by itself with an undo. Others are asked about. Follow-ups on the way are offered. |
| Save and resume | The journey is saved per character and re-planned from where you are after login or reload (`/ww resume`). |
| Death | The journey holds still until you're alive; no re-plan, no "left the camp". |
| Quest log buttons | Buttons by the game's quest log: start a journey for the selected quest, add it, or start a new one. |

### 3.3 Directions and travel

| Feature | What it does |
|---|---|
| Routing | Walking, known flight paths, boats, zeppelins, Deeprun Tram, Rut'theran portal, Hearthstone (only where it saves 5 minutes or more). |
| Walking by zone links | Walks cross zones through gates, passes, bridges and tunnels. A link is a step, done once you're in the next zone wherever you crossed. |
| Talk steps | "Talk to Ariena Stormfeather, the flight master at Lakeshire", then "Pick Stormwind on the flight map", then "Fly to Stormwind". |
| Compass | Wayward's own arrow in the directions box. Without an arrow, the circle shows what is ahead. |
| Map pin | The game's waypoint per step (Forever only). TomTom's arrow and pins when chosen. |
| NPC marker | A star over the step's NPC nameplate, a line in their tooltip, and a target button with a key binding. |
| Route on world map | The rest of the journey drawn on any map: next three steps in full, later ones fading. |
| Route on minimap | The current and next step drawn round the player arrow, following zoom, rotation and shape. |
| Gathering as you go | What the journey collects on the way, with counts, nearest first. |
| On the way | Offers near the journey, plus a detour of your own (repair, vendor, mailbox, bank, inn, auction house, stable master). |

### 3.4 Find and the browse pages

| Page | What it does |
|---|---|
| Find ("?") | One search over quests, items, people (by name or role), dungeons, zones, flight towns, class spells, professions. Chips: All / Quests / Items / People / Places. With no text: likely questions for right now. |
| Quests | Journal (your log, quest search with status and reason) and Hubs (nearby quest givers grouped by place). "Hand in N completed quests". |
| Vendors | Vendors you need now by travel time: repair, food and drink, reagents, ammo. |
| Trainers | Class (nearest, with spells to learn there), Weapons (one row per weapon skill to learn), Professions (skill, next rank, nearest trainer). |
| Dungeons | Dungeons and raids for your level by fit and travel time, with their quests. |
| Items | Where an item comes from: dungeon drops, world drops, quest rewards, vendors. |
| Notable quests | Tags for class quests, epic lines, standout rewards, dungeon leads, new-in-Forever quests. |
| Chain lines | "Chain: 4 more quests (levels 18-24), ends in The Deadmines" on every quest tooltip. |
| Tooltip lines | Item and quest tooltips gain "Wayward: /ww find for directions" (never in combat). |

### 3.5 Feedback, learning and support

| Feature | What it does |
|---|---|
| Fanfare | "Journey complete!" (or "Journey ended") with the 2 to 4 stats that stand out. |
| Toasts | "New journey available" between journeys; "Up next" a few seconds after one ends. |
| Notes | Short notes over the directions box for pickups and undo. |
| Sounds | Game sounds for five moments: popup, step, start, complete, toast. Each can be changed or turned off. |
| Learning as you play | Records trainers, vendors, flight masters, innkeepers, bankers, mailboxes, flight paths, dungeon entrances, zone crossings, transport docks, what vendors sell. |
| Data sources | `Wayward.RegisterSource` API; QuestieDB and class spells built in. What you learned in game beats any source. |
| Welcome | A one-time introduction on first login. |
| Skins and movers | EllesmereUI / ElvUI skinning; four boxes movable in Edit Mode. |
| Diagnostics | `/ww debug`, `/ww debug cards`, `/ww debug quest`, `/ww plan`, `/ww perf`, `/ww where`. |

## 4. UX spec: surfaces

### 4.1 Surface map

| Surface | File | Size | Default position | Shown when | Movable |
|---|---|---|---|---|---|
| Main window (home) | `UI/Panel.lua` | 840+ wide × 728 high, fixed | Centre | `/ww`, minimap button | Drag |
| Side panel | `UI/Panel.lua` | 384 × 728, docked right | Beside main window | A side tab is selected | With window |
| Directions box | `UI/HUD.lua` | 330 wide, 84+ high (narrower without compass) | TOP, 0, -140 | Journey or directions on | Drag, Edit Mode |
| Idle bar | `UI/HUD.lua` | 34 high | Same as directions box | Nothing on, option enabled | Same |
| Gathering as you go | `UI/HUD.lua` | Box width, up to 5 lines of 14 | 3 above the box | The journey gathers something | With box |
| On the way drawer | `UI/Drawer.lua` | 330 wide, up to 8 lines of 20 | 4 under the box; above it if under 220 of room below | The box's + | With box |
| Target button | `UI/TargetButton.lua` | 26 × 26 | Beside the directions box | The step has an NPC | With box |
| Note (snackbar) | `UI/Snackbar.lua` | Box width (330 alone), 48+ high | Over the directions box | A pickup, an auto-add, an undo | No |
| Journey overview | `UI/JourneyOverview.lua` | 380 wide, 10 rows of 30 | Right of the box (TOP +170, -140) | View details | Drag, Edit Mode |
| Fanfare | `UI/Fanfare.lua` | 380 × 112 | TOP, 0, -150 | Journey done or ended, 12 s | Edit Mode |
| Toast | `UI/Fanfare.lua` | 320 × 64 | TOP, 0, -96 | New suggestion, Up next, 8 s | Edit Mode |
| Route map | `UI/RouteMap.lua` | 280 wide, 2:3 | Under a tooltip | Hover a row or card with a route | No |
| World map route | `UI/WorldMapRoute.lua` | Lines at 1.3× | On the world map | Map open, option on | No |
| Minimap route | `UI/MinimapRoute.lua` | Lines at 0.8× | On the minimap | Navigating, option on | No |
| Minimap button | `UI/MinimapButton.lua` | 31 × 31 | 225° | Option on | Drag round the rim |
| Quest log buttons | `UI/QuestLogButtons.lua` | 2 × (112 × 21) | By the quest log's details | A quest is selected | No |
| Welcome | `UI/Welcome.lua` | 460 × 330 | Centre | First login, 3 s after | No |
| Copy box | `UI/CopyBox.lua` | 520 × 260 | Centre | Reports and exports | No |
| Options | `UI/Options.lua` | Game's Settings | Options > AddOns > Wayward | `/ww options`, right-click minimap button | No |

### 4.2 Main window

```
+--------------------------------------------------------------------+----+
| [portrait 44] Level 8 · Dun Morogh        Time: [15][30][60][Any]  | ?  |
|               summary line                              [Options]  | Q  |
+--------------------------------------------------------------------+ V  |
| YOUR JOURNEY                                    156 high, or 26    | T  |
| [icon 56] title                              [ route map 220 ]     | D  |
|           current stop                                             | I  |
|           Stop 3 of 5 · 2 complete · ~6 min remaining              |    |
|           [progress bar 8]                                         |    |
|           Then: Do Frostmane Hold, and 3 more stops                |    |
|           [Continue journey] [View details]                        |    |
+--------------------------------------------------------------------+    |
| SOMETHING TO DO NEXT                            3 cards, 180 high  |    |
| [card] [card] [card]                            [<] page [>]       |    |
+--------------------------------------------------------------------+    |
| WHERE TO QUEST                                  up to 4, 42 high   |    |
| [zone] [zone] [zone] [zone]                                        |    |
+--------------------------------------------------------------------+    |
| GOOD TO KNOW                                    up to 4, 84 high   |    |
| [tile] [tile] [tile] [tile]                                        |    |
+--------------------------------------------------------------------+----+
  margin 18 · region heading 18 high, 10 above · side tabs 32 × 32
```

Rules:

- The window never changes size. Regions collapse, they don't resize it.
- The four regions have separate jobs and never share one ranking.
- Side tabs, in order: Find, Quests, Vendors, Trainers, Dungeons, Items.
  Clicking the selected tab, or the panel's close button, closes the panel.

**Your journey.** Three forms:

| Form | Content |
|---|---|
| On a journey | Icon (56), title, current stop on its own line, position line, progress bar, "Then:" line, route map (220 wide), **Continue journey** (primary), **View details** (lighter). On the last stop: "The last stop. View details to reorder, add a detour or set it aside." |
| Plain directions | Destination, "Directions", "Directions to one place. Starting a journey folds it in as a stop.", **Continue**. |
| Nothing on | One line, 26 high: "No journey on the go. Pick something below." plus an "N set aside" button only while there are any. |

**Suggestion card** (180 high, three equal per page, gap 10):

| Element | Spec |
|---|---|
| Icon | 48, round, top left. |
| Tag | QUESTING, EXPLORE, DUNGEON, RAID, PROFESSION, PVP. Says the kind of activity; the role stays internal. |
| Badge | Time in the top right ("~12 min") when a time budget is set; red when over. |
| Title | One line. |
| Why | One or two lines of plain words. If both reasons don't fit, the card shows the first and the tooltip the sentence. |
| Facts | Up to three, in one order: level range, "Nearby" (under 2 minutes) or "~4 min away", quest count. No XP. |
| Primary | **Start journey**, or **Directions** when there is only a route. |
| Secondary | **Add detour**, lighter, only while a journey is on. |
| Art | Adventure Guide pane where the client has it; otherwise plain parchment. |
| Paging | Arrows under the cards (28 high) or the mouse wheel; back to page 1 when the cards change. |

**Zone box** (42 high): zone name, state ("You're here" / "New to you"),
levels, quest count ("3 quests left" where you are), travel to its first hub.

**Observation tile** (84 high): icon (36), text with numbers in gold, at most
one light button. Empty region: "Nothing to flag right now."

**Side panel list row** (352 × 42, 11 rows a page): title (optionally
coloured by quest difficulty), subtitle or "zone · time · summary", one
action button (72 × 20). Search box 338 wide; up to five category buttons
(84 × 22); summary line; up and down arrows under the list.

### 4.3 Directions box

```
          Gathering as you go                    (own section, above)
          Murloc Fin 3/8 · Shimmerweed 0/6 ...
+--------------------------------------------------------------+
| (compass 42)  The Perfect Stout                  [>>][...]   |
|               [==== 2 of 5 done ====]                        |
|               Walk to Loch Modan through South Gate Pass     |
|               Step 2 of 4 to get there                       |
|               objectives (up to 4, then "+N more")           |
|               distance · time left                           |
|--------------------------------------------------------------|
| + On the way 3                                 View details  |
+--------------------------------------------------------------+
  On the way drawer hangs here when open
```

| Element | Spec |
|---|---|
| Compass | 42 circle. Arrow while walking; otherwise an icon of what is ahead (pickup, hand-in, flight, explore, dungeon). Hidden in the air. Off: the box is narrower, text only. |
| Title | Journey title; destination on plain directions. |
| Progress | 4-high bar, "2 of 5 done". Journeys only. |
| Step line | The current step. With detail set to "stops": the stop only, and the step on hover. |
| Step count | "Step %d of %d to get there". |
| Objectives | Up to four lines; "In the area", "Next spot", "Camp looks cleared", "~3 min left here"; an **Another spot** button (92 × 20). |
| Buttons (top right) | Do this stop later (>>, 22 × 22), a "..." menu (24 × 22; `UI/Menu.lua`). Journeys only. Plain directions have a close button instead (Stop directions); a journey has none, since the menu ends it. |
| "..." menu | Skip this stop (asks), Set journey aside (doesn't ask: nothing is lost), End journey (asks). The game's context menu where the client has one; else a box of our own. |
| Footer (20 high, under a rule) | Text actions. Left: **+ On the way**, opens the drawer; closed, it carries the count of offers and nothing else. Right: **View details** (journeys only; pulses 3 times at 0.8 s when the journey gains stops). |
| No recalculate | Re-planning is automatic. |

**Idle bar** (34 high): Wayward icon, **Suggest a journey** (124 wide; hover
for which and why), **Open Wayward** (96 wide), an x that turns the bar off.

**On the way drawer**:

| Part | Spec |
|---|---|
| Top row | Icon chips (28): repair, vendor, mailbox, bank, inn, auction house, stable master (hunters). Pick one: the five places that add least, each with the time added and **Add**. Pick it again to go back. |
| "You could add" | Up to four offers: a log quest on the way, a quest giver, a hand-in or a vendor adding 3 minutes or less ("+2 min"), a new suggestion ("new"). Each has **Add** (46 × 16) and an x (18) to wave it off for that journey. |
| Opens on | What's on the way; repairs when gear is at 75% or less; vendors when bags are full. |
| Stays open | Until closed, per character. |
| Empty | "Nothing on the way right now. The icons above add a stop of your own: a repair, a vendor, a mailbox..." |

### 4.4 Journey overview

| Part | Spec |
|---|---|
| Header | Journey title; **Set aside** (70 × 18). |
| Stop row (356 × 30) | Drag handle (16), map number (gold for a stop, red for the goal), text with zone, a lock while pinned (click to unpin), +/- for its steps, a "..." menu (24 × 16). States: done, now, next. |
| Steps | 15-high lines under a stop; open under the current stop, with the step you're on marked. |
| Finished stops | Fold into one line; by themselves from three, or when they would push open stops off the list. Skipped stops aren't listed. |
| "On the way: you could add" | The drawer's offers, up to four rows of 18, each with **Add**. |
| Set aside | Up to five rows, each with **Resume** (54 × 16) and **Forget** (50 × 16). |
| Map | The rest of the journey. |
| No journey on | Lists only the journeys set aside. |

### 4.5 Maps

| Mark | Look |
|---|---|
| Walk | White line. |
| Flight | Light blue. |
| Boat, zeppelin, tram, portal | Deeper blue. |
| Hearthstone | Purple, with its icon where you use it. |
| Line | 2 thick with a 2 dark outline; a chevron every 45 pixels, none on legs under 20; a travel icon (14) mid-leg. |
| Badges | Numbered in the order you reach them: start green, stop gold, goal red. Same numbers in the overview. |
| There and back | The two lines sit side by side. |
| World map | Next three steps in full; each later step 15% fainter, down to 30%. |
| Minimap | The current step and the next (fainter). Cut at the rim, round or square. The line goes once you're in the objectives' area; the badge stays. |

### 4.6 Banners, toasts and notes

| Surface | Content | Lifetime |
|---|---|---|
| Fanfare | Icon, title, "Journey complete!" or "Journey ended", 2 to 4 stats. Distance and time only pad a journey that achieved fewer than two things. | 12 s, 1 s fade; not while hovered; click closes. |
| Toast | "New journey available" or "Up next", icon (40), title, x. Click starts it (or asks the usual question). | 8 s; not while hovered. |
| Note: question | "You picked up X. Add it to your journey (about ~4 min more)?" with + (add) and a map icon (new journey). | 15 s, a gold bar drains behind the words. |
| Note: notice | "Added X to your journey." with an undo arrow. | 8 s. |

One note at a time; the next waits. Hovering holds the bar and shows the
detail. Letting it run out, or its x, changes nothing.

## 5. UX spec: interactions and flows

### 5.1 Universal row contract

Every row, card, zone box and tile uses one path (`Panel.Activate`,
`Panel.ShowTooltip`):

| Input | Result |
|---|---|
| Hover | Tooltip with every detail (up to 12 lines), the stops, and a route map under it. |
| Click | Start journey or directions. While a journey is on, asks (5.2). |
| Shift-click, or **Add detour** | Adds it to the journey on now; starts one if none. |
| "In journey" | Takes the quest out again. |
| Shift-click a link | Puts an item or quest link into the search box. |
| Mouse wheel | Scrolls a list or pages the cards. |
| Typing in search | Filters after 0.3 s. |

### 5.2 Starting something while a journey is on

Start journey on a card, a zone, a row or a toast asks one question with
three answers:

1. **Add as detour**: the stops join the journey where they add least travel.
2. **Switch journey**: the journey on now is set aside, the new one starts.
3. **Cancel**.

Plain directions started on a journey ask the same. Starting a journey while
on plain directions folds the destination in as a stop.

### 5.3 Journey lifecycle

```
suggestion / row / quest pickup / Suggest a journey
        |
        v
   [ planned ] --start--> [ active ] --all stops done--> Journey complete! --> Up next toast
                            |  ^  |
             add detour ----+  |  +---- End journey (asks: end, or Set aside)
             reorder, pin      |  |
             skip, do later    |  +---- Switch journey ----> [ set aside ] (5 at most)
                               |                                 |
                               +--------- Resume ----------------+
                                                                 |
                                         Forget, or nothing left to do --> gone
```

| Moment | What the player sees |
|---|---|
| Start | Start sound; the directions box appears. The overview opens only if the option is on. |
| Stop reached | The step advances by itself; waits at pickups and hand-ins until the quest is accepted or handed in; talk stops finish on talking. |
| Stops added | View details pulses three times; the overview does not pop open. |
| Quest picked up, adds 3 min or less | Joins by itself; a notice with undo. |
| Quest picked up, adds more | A question note: add, new journey, or let it fade for not now. Quests picked up one after another are asked together. Asked once per quest. |
| Quest picked up, nothing on | A note with the map icon: start a journey. |
| Giver doesn't offer the quest | The pickup and its hand-in are dropped; the quest counts as locked until a hand-in or level. |
| Skip this stop | Confirms, then removes the stop and the stops that need it. |
| Do this stop later | In a camp: the camp counts as cleared. At a manual step: it's done. Elsewhere: the stop moves after the next one that doesn't need it. |
| End journey | Asks: **End journey**, **Set aside** or **Keep going**. Ending early shows "Journey ended" when it came to anything. |
| Done | Fanfare, then "Up next" a few seconds later (optional). |
| Login or reload | The journey resumes, re-planned from here; retried for half a minute; `/ww resume` after. |

### 5.4 Overview interactions

| Input | Result |
|---|---|
| Drag a stop by its handle or row | Reorders; an insertion marker shows where. A stop can't go before one it needs. Dragging clears pins: the order is yours. |
| Click a stop (or its +/-) | Shows or folds its steps. Letting go of a drag isn't a click. |
| "..." > Pin stop / Unpin stop | Pins the stop: re-plans keep it in place, each side still ordered for you. Moving on from a pinned stop unpins it. Not offered once the order is yours. |
| "..." > Move up / Move down | The same as dragging it past the next open stop, without the drag: same rules, and the order is yours from then on. |
| "..." > Remove stop | Takes it off with the stops that need it. |
| Lock on a pinned stop | Unpins it. |
| Click the folded line | Opens the finished stops. |
| Add / Resume / Forget / Set aside | As labelled. |
| Mouse wheel | Scrolls. |

### 5.5 Other controls

| Control | Left-click | Right-click | Other |
|---|---|---|---|
| Minimap button | Open Wayward | Options | Shift-right-click: overview on a journey. Drag to move. |
| Addon compartment | Open Wayward | Options | |
| Target button | Target the step's NPC | | Key Bindings > AddOns > Wayward. Changes only out of combat. |
| Edit Mode box | Drag to move | Back to its start | Directions, overview, fanfare, toast. |
| TomTom question | Once, when TomTom is installed | | "Use TomTom" turns the compass off. |

### 5.6 Slash commands

`/ww`, `/wayward` and `/wf` are the same.

| Command | Does |
|---|---|
| `/ww` | Open or close the window. |
| `/ww help` | List the commands. |
| `/ww next` | Open the home screen. |
| `/ww find <text>` | Find anything, with directions. |
| `/ww quest <name>` · `/ww item <link or name>` | Find, on Quests or Items. |
| `/ww time <minutes>` · `off` | Time budget. |
| `/ww stop` | Stop directions. |
| `/ww resume` | Pick up the saved journey. |
| `/ww journeys [aside \| resume <n> \| forget <n>]` | The journey on now and those set aside. |
| `/ww detail steps\|stops` | What the directions box shows. |
| `/ww idle` · `/ww compass` · `/ww tomtom` · `/ww marker` · `/ww toasts` | Toggles. |
| `/ww worldmap` · `/ww minimap` · `/ww minimap journey` | Map toggles. |
| `/ww sounds ...` | List, play, keep, test and export sounds. |
| `/ww options` · `/ww reset` · `/ww welcome` · `/ww profile` · `/ww skin` | Options, window positions, welcome, profile, skin. |
| `/ww dock [boat\|zeppelin\|portal]` · `/ww dock list` | Record and copy a transport. |
| `/ww crossings [clear]` | Copy or forget recorded zone crossings. |
| `/ww where` · `/ww debug [cards \| quest <id\|name>]` · `/ww plan` · `/ww perf on\|off\|copy\|reset` | Diagnostics. |

## 6. UX spec: states, copy and look

### 6.1 Empty and degraded states

| Situation | What shows |
|---|---|
| No journey | Your journey is one line; the idle bar offers Suggest a journey and Open Wayward. |
| Nothing fits the time budget | Says so and offers the quickest option, "a bit over". |
| No zones to list | The Where to quest region isn't there. |
| No observations | "Nothing to flag right now." |
| Nothing to suggest from the log | "Nothing in your quest log to go on from here. Open Wayward (/ww) for other ideas." |
| No offers on the way | The drawer's empty line; the + has no count. |
| No quest data (no QuestieDB) | No quest search, hubs or item sources. The log lists without directions. Trainers and vendors are those you've visited. Dungeons rank by level fit and travel. The summary line says which. |
| No class trainer visit yet | "New spells" comes from the bundled class spell data. |
| Classic Era | No map pin; the compass or TomTom shows the way. |
| In flight | No compass, no TomTom arrow, no re-plan. |
| In combat | No tooltip lines, no progress questions; the target button waits. |
| Dead | The journey holds still. |
| A dungeon known only to the finder list | Listed last, without directions, until you walk in once. |
| A data source errors | Reported once and skipped. |
| A journey can't be re-planned at login | Stays saved; `/ww resume` tries again. |
| A template or atlas is missing | Plain backdrops and parchment. |

### 6.2 Copy rules

- Use the vocabulary in section 2. Module names (`ns.Errands`,
  `Nav.AddToTrip`) may keep old words; nothing the player reads does.
- Buttons are verbs: Start journey, Add detour, Continue journey, View
  details, Set aside, Resume, Forget, Go, Show.
- Say why in plain words, from a phrase library: "Picks up where your log
  left off, close by". Never show a score, a rank or "#N of M".
- Distance in words on the why line ("close by"); minutes in the facts row.
- Times are rough and say so: "~6 min", "<1 min", "~1 h 20 min", "+2 min".
- Steps name the way and the place: "Walk to Loch Modan through South Gate
  Pass", "Take the boat".
- Objects are "used", NPCs are "talked to".
- Chat lines are prefixed with a green "Wayward:".
- Every string is listed in [docs/copy.md](copy.md), generated by
  `tools/extract_copy.py`.

### 6.3 Attention rules

| Level | Used for | Channel |
|---|---|---|
| Unasked, on screen | The journey's own way: the step, objectives, Gathering as you go. | Directions box. |
| Answer to what you just did | A pickup, an auto-add, an undo. | A note over the box, with a sound. |
| Between journeys | A new major suggestion, Up next. | A toast, with a sound. |
| On a journey | Any new suggestion or nearby offer. | A count on **+ On the way**. No sound, no arrow change. |
| On request | Everything else. | Hover, click, the drawer, the overview, Find. |

A new-suggestion check runs after a level, a hand-in or a new zone; never in
combat or in flight.

### 6.4 Look

| Token | Value |
|---|---|
| Frames | Blizzard's templates (window, tabs, search box, tooltip boxes), so UI suites restyle them. |
| Font | Friz Quadrata (`FRIZQT__.TTF`), or the suite's font when skinned. |
| Gold (headings, numbers, stop badges) | 1, 0.82, 0 (`ffd200`) |
| Goal badge | 1, 0.3, 0.2 |
| Start badge | 0.3, 1, 0.3 |
| Walk / fly / transport / hearth | White · 0.45, 0.8, 1 · 0.25, 0.5, 1 · 0.8, 0.65, 1 |
| Card parchment | 0.86, 0.78, 0.6; title 0.20, 0.10, 0.02; text 0.22, 0.14, 0.06; over-budget red 0.62, 0.12, 0.03 |
| Zone state | 0.5, 0.82, 0.68; facts grey 0.72 |
| Profile bar | Green 0.25, 0.85, 0.3 |
| Note bar | Gold at 18% alpha |
| Chat prefix | `7fd1ae` |

### 6.5 Sounds

Five moments, each a game sound from a shortlist: `popup` (a question),
`step` (a stop added), `start`, `complete`, `toast`. When a journey starts
or grows and asks a question, only the question's sound plays. Offers are
silent.

## 7. Settings and saved data

Options > AddOns > Wayward. All checkboxes.

| Section | Option | Default | Scope | Command |
|---|---|---|---|---|
| Navigation aid | Compass in the directions box | On | Account | `/ww compass` |
| | TomTom's arrow | Off (asked once) | Account | `/ww tomtom` |
| | Every step in the directions box | On ("steps") | Character | `/ww detail` |
| | Small bar with no journey on | On | Account | `/ww idle` |
| NPCs | Star over the NPC you're heading for | On | Account | `/ww marker` |
| | Friendly NPC nameplates | The game's own setting | Game | |
| Journeys and quests | Automatically add quest pickups | On | Account | |
| | Ask about quests outside your journey | On | Account | |
| | Open the journey overview when a journey starts | Off | Account | |
| | New journey toasts | On | Account | `/ww toasts` |
| | Suggest a journey after one is done | On | Account | |
| Maps | Your journey on the world map | On | Account | `/ww worldmap` |
| | Your journey on the minimap | On | Account | `/ww minimap journey` |
| | Minimap button | Shown | Account | `/ww minimap` |
| Windows and help | Reset positions · Show welcome again · List slash commands | Buttons | | `/ww reset`, `/ww welcome`, `/ww help` |

Not in the options panel: the time budget (header buttons), sound choices
(`/ww sounds`), the skin (`/ww skin`), whether the drawer is open.

Saved per character: the active journey and up to five set aside, time
budget, detail setting, drawer state, learned quest times, the learned
weight per kind of journey, cards seen, profile completion. Saved per
account: settings, window positions, what was learned in game (NPCs, flight
paths, docks, crossings, entrances, vendor goods).

## 8. Gaps and open questions

Known and recorded in DESIGN.md or the README:

- Nothing is verified in game on Classic Era, and the Edit Mode movers are
  untried.
- Good to know still makes its own tiles rather than drawing from the one
  On the way list.
- "Near the way" has two measures: 3 minutes for routed offers, 250 yards
  for log quests.
- Where to quest has no "opens in a level or two" and no full browse list.
- Walks inside a zone are straight lines: lakes, cliffs and city walls
  aren't known.
- Holiday and reputation requirements aren't handled; profession-gated
  quests are left out.
- Bundled docks, zone links and dungeon entrances are approximate until
  recorded. Vendor goods tiers are unchecked in Forever.
- No explicit player preference feeds relevance's intent part yet (the hook
  exists).

Found while writing this, worth a decision:

1. **Scope of options.** Only the detail setting is per character. Whether
   toasts, pickup questions and the idle bar should be per character too is
   open.
2. **Overview from the keyboard.** Reorder no longer needs a drag (a
   stop's "..." menu has Move up and Move down), but there is still no
   keyboard way to reach the menu.
3. **Fixed window size.** 840 × 728 fits 1080p at UI scale 1; behaviour at
   larger UI scales or smaller screens isn't specified.

Fixed on 2026-11-13 after this was written: the README's stale "R button"
line, DESIGN.md's no-journey line and region count, and the toast option's
tooltip, which listed "spells to train" although training is an observation
and never raises a toast.
