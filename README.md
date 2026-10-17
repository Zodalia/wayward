# WoW Forever levelling helper

A "Google Maps for levelling" addon for WoW Forever: search or pick a page
(Quests, Vendors, Trainers, Dungeons, Items), get options ranked for
your character (level fit, travel time, why it's worth going), then step-by-step
directions including flight paths, boats and zeppelins.

Status: **MVP, "Class trainer" with directions.** Phase 0 used the WFProbe
dev addon (described below) to find out what the Forever client provides and
what we have to ship or learn as you play.

## Wayfinder (the addon)

`Wayfinder/` is the levelling helper. `/wf` opens the panel.

What works in this MVP:

- **Class trainer**: trainers for your class, ranked by travel time from where
  you stand, with what you can train now ("1 new spell to train for 10s · next:
  4 spells at level 22"). Hover a row to preview the route, click for directions.
- **Directions**: walking, flight paths you know, boats, zeppelins, the Deeprun
  Tram and the Rut'theran portal. Each step places the map waypoint and moves on
  when you get there. The directions box has its own arrow (`/wf arrow` hides
  it), because Blizzard's on-screen navigation is off by default in Forever;
  without an arrow its circle shows what's ahead (quest pickup or hand-in,
  flight). It also shows the trip, a bar of stops done, the step, which stop
  you're on, and distance and time left, with Blizzard's square buttons for
  previous / next step, all stops, recalculate and stop.
- **Learning as you play**: talking to a trainer, vendor, flight master,
  innkeeper or banker records where they are. Opening a flight map records
  which flight paths you know. Your class spell list is read at the trainer.

- **QuestieDB (optional)**: if [QuestieDB](https://github.com/Questie/QuestieDB)
  is installed, Wayfinder reads it at runtime through its public API (contract
  4). Class trainer gains every trainer for your class, and **Quest hubs**
  lists nearby quest givers you can take quests from (level, race, class,
  prerequisites, not done, not in your log, not grey), grouped by place
  ("Auberdine", named after the nearest flight path's town or an explored
  subzone) and ranked by travel time. Hover a hub for its quests. Nothing from QuestieDB is
  copied into Wayfinder: it has no licence file, so we only read the copy the
  player installed. `/wf debug` shows the data source and first-scan times.

- **Dungeons**: dungeons and raids that fit your level (3 under to 6 over; raids
  only from their level), ranked by level fit and travel time to the entrance.
  Levels come from the client's dungeon finder list, matched to our dungeons by
  name. Entrances come from QuestieDB if installed, otherwise from
  `Wayfinder/Data/Dungeons.lua`. Those are approximate vanilla positions, and
  the Stockade, Stratholme and Naxxramas points are likely off in Forever
  without QuestieDB. With QuestieDB, a row also counts the dungeon's quests you
  can take or have in your log, and the tooltip lists them.

Data limits to know about:

- Without QuestieDB, trainer locations are only what you have visited, plus
  one seeded trainer (Stormwind warlock trainer). The client has no
  trainer-location API.
- Quest hubs hide grey and red quests, quests whose chain you haven't reached
  (or have moved past), and quests whose parent, start or end conditions
  aren't met. Holiday/event and reputation requirements aren't handled yet,
  and quests needing a profession skill are left out.
- Class trainers from QuestieDB are recognised by their English subtitle
  ("Warlock Trainer").
- Boat, zeppelin, tram and portal docks in `Wayfinder/Data/Transports.lua` are
  approximate, and Forever's new routes (e.g. Auberdine - Stormwind) are
  missing. Record one yourself: `/wf dock` where you board, ride, `/wf dock`
  where you get off. Routes use it immediately; `/wf dock list` copies the
  data line to add to `Data/Transports.lua` for everyone.
- "New spells" needs one visit to a trainer for your class first.
- Weapon masters are only recognised on English clients.

### Vendors

**Vendors** lists the vendors you need now, ranked by travel time: repairs,
food & drink for your level, your class reagents, and ammo for your ranged
weapon (hunters). Each row says what the vendor does for you; hover it for the
goods. The fastest vendor for each need is always listed. When a piece of gear
is at 50% durability or lower, the summary warns and the nearest repair comes
first. Opening a merchant window records what that vendor sells and whether
they repair. With QuestieDB, sellers come from its ItemDB (`vendors`), the NPC
repair flag and English subtitles ("Food & Drink", "Bowyer"); without it, only
vendors you visited are listed. Food, ammo and reagent tiers in
`Data/VendorGoods.lua` are vanilla item IDs, not yet checked in Forever.

### Items

**Items** tells you where an item comes from, with directions. Shift-click an
item into its search box, type `/wf item <link>` in chat, or type part of the
name. Each source is a row: dungeon drops ("Drops from Edwin VanCleef in The
Deadmines", routed to the entrance, with a **+N quests** button that picks up
the dungeon's quests on the way), mobs and objects in the world (nearest spawn,
one row per zone), quests that reward it (can take now, in your log, needs
earlier quests or a higher level) and the nearest vendor that sells it. Things
you can do now come first, then shorter trips. Drops and quest rewards need
QuestieDB (ItemDB); without it only vendors you visited that sold the item are
known. Item tooltips get a "Wayfinder: /wf item for directions" line when an
item has known sources (never in combat).

### For you

The page is laid out like the Suggested Content tab of modern WoW's Adventure
Guide: the top suggestion on a large card (icon, title, why, details, a Go or
Start trip button, and arrows to step through the rest), the next two on
smaller cards beside it. The card art comes from the client when it has the
Adventure Guide textures (Forever does); otherwise the cards are plain
parchment. Hover a card for the full tooltip; shift-click adds it to your
trip.

The window keeps one size: For you is the main window, and **Quests**
(Journal: your quest log and quest search; Hubs), **Vendors**, **Trainers**
(Class; Weapons: weapon masters, with the weapons they teach once visited),
**Dungeons** and **Items** are icon tabs inside its right edge that open a
list panel docked beside them (click the tab again, or the panel's close
button, to close it). The search box filters any list. If the cards ever show no text, `/wf debug cards` reports what
each card holds and which font it uses. Pages opt into the main window with `layout = "cards"`; every other
page is a list in the side panel.

**For you** is the first tab (`/wf next` opens it): a handful of things to do
next, each with a one-line why; click one for directions or a journey. Needs
come first when due: spells you can train and afford (after one trainer
visit), repairs at 50% durability or lower, ammo under 200, food and drink
under 5 (not mages, from level 6), and an undiscovered flight path within
about 3 minutes. The rest is ranked by estimated XP per minute: quest hubs and
dungeons with their quests, XP over the trip plus 5 minutes per quest
(`SECONDS_PER_QUEST` in `ForYou.lua`). XP comes from QuestieDB's quest XP
table, with the vanilla penalty for quests below your level; quests it has no
XP for (Forever-only ones) get the average for their level. Without that
table the ranking falls back to quests per hour weighted by level fit, and
without QuestieDB to dungeons by level fit and travel time; the summary line
says which. A need on the way to the best option becomes one journey ("Train
in Stormwind, then pick up 3 quests in ..."), and dungeon rows pick up their
quests before the entrance. `/wf debug` shows how long a refresh took.

Quests already in your log count at full XP, with only the time left for
them. Ones ready to hand in are grouped by where you hand them in ("Hand in 3
quests in Lakeshire", 30 seconds each), so they usually rank first; a quest
hub where you also hand quests in takes them along ("Pick up 3 quests and hand
in 2 in Lakeshire", with a Hand in only button). Unfinished quests whose
objectives are close together become one whole-quest trip ("Finish 2 quests
near Lakeshire"), timed at 5 minutes times the share of objectives left (at
least a quarter). A dungeon's quests in your log count toward its XP.

### Getting around

- **Directions** add a step whenever you walk into another zone ("Walk to
  Elwynn Forest"); it counts as done as soon as you're in that zone.
- **Re-routing is automatic** after a hearthstone, portal or loading screen,
  when you're on another continent than the current step expects, or when
  you've walked well away from the current target. Never during a flight,
  and at most every 10 seconds. The R button still re-plans on demand.
- **TomTom**: when it's installed, Wayfinder puts each step on TomTom's arrow
  and map pins instead of its own, titled with what to do there (`/wf tomtom`
  switches back, or retries after TomTom failed).
- **Flight paths** are learned per continent: a flight map only lists the
  continent you're on, so open one once per continent. "New flight path
  discovered!" also marks the nearest one as known.
- **Waypoint height**: addons can only give the game a map position (the game
  reports heights as 0 to addons in Forever), so the height of the in-world
  marker is the game's own guess and can be off on multi-level places.
- **Journey stops** show their zone in the overview and in previews.
- **Class trainers** in the same room are one row ("3 warlock trainers in
  Stormwind City").
- **Minimap button**: left-click opens Wayfinder, right-click opens the journey
  overview during a trip. It uses LibDBIcon when another addon provides it
  (so button managers can handle it), otherwise a plain button you can drag
  around the minimap. `/wf minimap` hides it. Wayfinder is also in the addon
  compartment menu.

### Look

Wayfinder's windows use Blizzard's standard templates (window, tabs, search
box, tooltip-style boxes), so they follow UI addons that restyle those, and
fall back to a plain look if a template is missing. Long result lists scroll
with the mouse wheel or the arrows under the list.

With [EllesmereUI](https://github.com/EllesmereGaming/EllesmereUI) installed,
Wayfinder also registers with its public skinning API (`EllesmereUI.RegisterSkin`)
and takes on your theme, accent colour and font. This needs EllesmereUI's
"Blizz UI Enhanced" module (`EllesmereUIBlizzardSkin`) turned on, with skins
for other addons allowed. ElvUI's Skins module is used when present
(unverified). `/wf skin` turns the skin off; windows already restyled keep it
until `/reload`.

Install the same way as WFProbe below, with the `Wayfinder` folder.

Development: `lua tests/wayfinder_smoke.lua` runs routing, step advance,
harvesting and the panel against a fake two-continent world.

### Quests

The **Quests** tab (or `/wf quest <name>`) searches QuestieDB quests by name,
or takes a shift-clicked quest link. Each quest shows its level and whether you
can take it: available (grey and red quests say so), in your log, done, needs
earlier quests (naming the first one you can take, or the one in your log to
finish), too low, not for your race or class, or not available (closed by a
quest you did, outlevelled, needs a profession). Click a quest to go to its
quest giver, to where you hand it in, or to the start of its chain; the trip
waits there until you accept or hand in the quest. When a search matches
dungeon quests, and on the Dungeons tab ("Quests" button), one trip picks up
every quest you can take for that dungeon and ends at the entrance. The rules
are the Quest hubs rules (`ns.Questie.QuestStatus(id)` and
`ns.Questie.ChainStart(id)` give the status, reason and first chain step).
Needs QuestieDB.

With an empty search the tab lists your quest log: level, zone and the first
objective not done yet (or "ready to hand in"). Click a quest for a trip for
what is left of it. "Add" (on log quests and search results) puts the quest
into the trip you're on, or starts one; "In trip" takes it out again. The
trip is re-ordered from where you are each time, each quest in its own order
(pick up, objectives, hand in) but interleaved by travel time. "Hand in N
completed quests" visits every finisher in one trip, and can be added to the
current trip too. Without QuestieDB the log still lists, but without
directions.

**Trips are flexible:** starting new directions while a trip is on asks
whether to add them to the trip or replace it. Shift-click any row in the
panel to add it to the trip you're on.

### Building on Wayfinder: pages and journeys

- **Pages** are the panel's tabs. A file that loads before `UI/Panel.lua`
  calls `ns.RegisterPage(page)`. The page contract (id, label, order,
  searchable, Summary/Empty/Results taking the search text, and the result
  shape with `route` or `journey` and optional row `actions`) is documented
  at the top of `UI/Panel.lua`. The lowest `order` opens by default. Pages
  with `categories` (Quests, Trainers) show them as buttons; `categoryPage` in
  `UI/Panel.lua` builds such a page from providers. `ns.Panel.Search(pageID, text)` opens a page
  with a search, and shift-clicked links go into the search box.
- **Journeys** are trips with several stops (`Journey.lua`): stops are put in
  the quickest order, with an optional fixed final stop. A stop with
  `action = { kind = "pickup" | "turnin", questID }` waits until that quest is
  accepted or handed in; a quest done early is planned out of the rest of the
  trip. Start one with `ns.Nav.StartJourney(ns.Journey.Plan(start, def))`, or
  return it as a result's `journey`.
  - A stop can list `after = { otherStop }` (it must come later), and
    `resolve = { kind = "objectives", questID }` to find its place at planning
    time. Action kinds: `pickup`, `complete` (the objectives; done when the game
    reports the quest complete) and `turnin`.
  - `ns.Journey.QuestStops(questID, here)` gives the stops for a whole quest
    from where it stands now: pick it up, do the objectives (the game's quest
    area marker once it's in your log, else QuestieDB's objective mobs, objects,
    item drops and explore points), hand it in.
  - The current trip is saved per character and resumed after a login or
    reload, re-planned from where you are. The directions box's book button
    opens an overview of every stop (done / now / next); a stop can be dropped
    there, together with the stops that need it, or dragged up or down to
    reorder the trip. A reordered trip keeps your order (`Journey.Move`);
    stops added later go where they add the least travel, and a stop can't
    move before one it needs (a hand-in before its pickup).
- **Commands**: `ns.RegisterCommand(name, help, run)` adds `/wf <name>`; `run`
  gets the rest of the line in its original case, so item links survive.
- **Quest helpers** on `ns.Questie`: `Quest(id)`, `AllQuests()`,
  `PlayerQuestState()`, `IsQuestAvailable(id)` (the Quest hubs rules) and
  `QuestGiver(id, here)`.
- **Dungeons** for other pages: `ns.Dungeons.Catalogue()` and `ns.Dungeons.ForArea(areaID)`.

## WFProbe (dev tool)

`WFProbe/` is a throwaway addon that records which APIs exist and return usable
data, and tests whether NPC positions can be "harvested" as you play.

### Install

Symlink (or copy) the `WFProbe` folder into the Forever client's AddOns folder,
the `_forever_…` folder next to `_retail_` in your WoW install:

```bash
ln -s "$PWD/WFProbe" "/Applications/World of Warcraft/<forever folder>/Interface/AddOns/WFProbe"
```

The TOC targets interface `16001` (confirmed on beta build 1.60.1.70450). If the
addon shows as out of date after a patch, tick **Load out of date AddOns** on the
character-select AddOns screen; the probe reports the new number.

### Run

1. Log in, stand in the open world (a town is ideal), out of combat.
2. `/reload` once (this tests whether SavedVariables survive a reload).
3. `/wfprobe` runs all probes and opens the report window.
4. `/wfprobe waypoint` places a test waypoint. Note whether the map pin and the
   on-screen arrow appear. `/wfprobe nav` explains a missing arrow (setting,
   frame, target state, and whether player facing is readable for our own
   arrow). `/wfprobe waypoint clear` removes it.
5. Visit and interact with: a class trainer, a vendor, a flight master, the
   bank, a quest giver (open a quest and accept it), an NPC with a gossip menu.
   Each one is captured automatically ("captured …" in chat).
6. `/wfprobe show`, then Ctrl+A, Ctrl+C, and paste the report back.
7. Settings comparison: in the world map filter menu, turn on **Quest
   Objectives** and **Low-Level Quests** (and any modern-experience options
   Forever offers), `/wfprobe` again and paste that report too. Each run
   records the experience preset and relevant settings, so we can tell API
   limits apart from player settings.

If copying fails, the same data is in
`WTF/Account/<ACCOUNT>/SavedVariables/WFProbe.lua` after you log out.

### What it answers

| Question | Probe |
|---|---|
| Quest givers with coordinates from the client? | `C_QuestLine.GetAvailableQuestLines`, `C_QuestLog.GetQuestsOnMap` |
| Where to go for quests in the log? | `C_QuestLog.GetNextWaypoint` |
| Flight paths (known/unknown) anywhere? | `C_TaxiMap.GetTaxiNodesForMap` |
| Dungeon entrances and level ranges? | `C_EncounterJournal.GetDungeonEntrancesForMap`, `GetLFGDungeonInfo` |
| Upcoming spells without trainer data? | `C_SpellBook` future spells and level learned |
| Native waypoint arrow usable? | `C_Map.SetUserWaypoint`, `C_SuperTrack` |
| Can we record NPC IDs and positions? | trainer, vendor, flight master, gossip, quest captures |
| Do SavedVariables persist on the beta? | load counter across `/reload` |
| Forever-specific APIs? | `_G` scan for "Forever"/"Camelot", full `C_*` namespace list |

### Development

```bash
lua tests/smoke.lua
```

Runs the addon against stubbed WoW APIs. This checks our own code paths only,
not real Forever behaviour.
