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
  when you get there. The directions box has its own compass (`/wf compass` hides
  it), because Blizzard's on-screen navigation is off by default in Forever;
  without an arrow its circle shows what's ahead (quest pickup or hand-in,
  flight). It also shows the trip, a bar of stops done, the step, which stop
  you're on, and distance and time left, with Blizzard's square buttons for
  previous / next step, all stops, recalculate and stop.
- **Talking to NPCs** is a step of its own. At a flight path it's "Talk to
  Ariena Stormfeather, the flight master at Lakeshire" (named once you've met
  them, or from a data source) until the flight map opens, then "Fly to
  Stormwind" ("Pick Stormwind on the flight map" until you take off). In
  the air there's no compass or TomTom arrow and nothing is re-planned;
  landing picks up from where you are. A
  trainer or vendor you're heading for is done when you talk to them, not on
  arrival. The NPC the step is for (flight master, quest giver, the one you
  hand in to, trainer, vendor) is easy to find near there: a star over their
  nameplate (friendly NPC nameplates have to be on; the options can switch
  the game's setting), a Wayfinder line in their tooltip, and a target button
  beside the directions box that targets them (`/target`, with a key binding
  under Key Bindings > AddOns > Wayfinder). Raid markers would be simpler,
  but addons may not set them. `/wf marker` or the options turn the star and
  the tooltip line off. Quests handed in to (or started from) an object, like
  Buzzbox 323, say "use" instead, with nothing to target.
- **Learning as you play**: talking to a trainer, vendor, flight master,
  innkeeper or banker records where they are. Opening a flight map records
  which flight paths you know. Your class spell list is read at the trainer.

- **Data sources (optional)**: Wayfinder bundles only hand-made data and what
  it learns in game. A separate data addon can register a source with more
  (see [Data sources](#data-sources) below). With quest and NPC data, Class
  trainer gains every trainer for your class, and **Quest hubs** lists nearby
  quest givers you can take quests from (level, race, class, prerequisites,
  not done, not in your log, not grey), grouped by place ("Auberdine", named
  after the nearest flight path's town or an explored subzone) and ranked by
  travel time. Hover a hub for its quests. With class spell data, "new
  spells" works before your first trainer visit. `/wf debug` shows the data
  sources and first-scan times.

- **Dungeons**: dungeons and raids that fit your level (3 under to 6 over; raids
  only from their level), ranked by level fit and travel time to the entrance.
  Levels come from the client's dungeon finder list, matched to our dungeons by
  name; dungeons only that list has (Forever's new ones, such as Hall of
  Thanes) are listed too, at the end and without directions until you walk in
  once. Walking into a dungeon or raid records its entrance (where you were
  when the loading screen started; dungeon finder teleports don't count), and
  a recorded entrance beats every other source. Otherwise entrances come from a data source if one has them, otherwise from
  `Wayfinder/Data/Dungeons.lua`. Those are approximate vanilla positions, and
  the Stockade, Stratholme and Naxxramas points are likely off in Forever
  without a data source. With quest data, a row also counts the dungeon's quests you
  can take or have in your log, and the tooltip lists them.

Data limits to know about:

- Without a data source, trainer locations are only what you have visited, plus
  one seeded trainer (Stormwind warlock trainer). The client has no
  trainer-location API.
- Quest hubs hide grey and red quests, quests whose chain you haven't reached
  (or have moved past), and quests whose parent, start or end conditions
  aren't met. Holiday/event and reputation requirements aren't handled yet,
  and quests needing a profession skill are left out.
- Class trainers from a data source are recognised by their English subtitle
  ("Warlock Trainer").
- Boat, zeppelin, tram and portal docks in `Wayfinder/Data/Transports.lua` are
  approximate, and Forever's new routes (e.g. Auberdine - Stormwind) are
  missing. Record one yourself: `/wf dock` where you board, ride, `/wf dock`
  where you get off. Routes use it immediately; `/wf dock list` copies the
  data line to add to `Data/Transports.lua` for everyone.
- "New spells" needs one visit to a trainer for your class first, or a data
  source with class spells (then costs show only when the source has them).
- Weapon masters are only recognised on English clients.

### Vendors

**Vendors** lists the vendors you need now, ranked by travel time: repairs,
food & drink for your level, your class reagents, and ammo for your ranged
weapon (hunters). Each row says what the vendor does for you; hover it for the
goods. The fastest vendor for each need is always listed. When a piece of gear
is at 50% durability or lower, the summary warns and the nearest repair comes
first. Opening a merchant window records what that vendor sells and whether
they repair. With a data source, sellers come from its item records (`vendors`), the NPC
repair flag and English subtitles ("Food & Drink", "Bowyer"); without one, only
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
item data from a data source; without it only vendors you visited that sold the item are
known. Item tooltips get a "Wayfinder: /wf item for directions" line when an
item has known sources (never in combat).

### For you

The page is laid out like the Suggested Content tab of modern WoW's Adventure
Guide: the top suggestion on a large card (icon, title, why, details, a Go or
Start trip button, and arrows to step through the rest), the next two on
smaller cards beside it. The card art comes from the client when it has the
Adventure Guide textures (Forever does); otherwise the cards are plain
parchment. Each card shows the trip's key numbers (level, travel time,
quests, XP per minute) and its quests; hover it for every detail and step.
The tooltip of a card, or of any row with directions or a trip, has a small
map under it with the route drawn on it (the zone, the continent or the world
map, whichever holds it all, zoomed in on the route; walking white, flights
light blue, boats and the like deeper blue). The arrows under the cards page through the rest, three at a time (back to page 1 when the cards change); shift-click adds a card to
your trip.

The window keeps one size: For you is the main window, and **Quests**
(Journal: your quest log and quest search; Hubs), **Vendors**, **Trainers**
(Class; Weapons: one row per weapon your class can learn and you don't know,
"Polearms (Woo Ping)", with the nearest weapon master who teaches it to your
class and the cost against your purse; weapon masters list what they teach
when you visit, so ones not seen yet point to a master you haven't visited;
Professions: each of your professions with its skill, the next rank and the
nearest trainer for it, then the ones you could still learn),
**Dungeons** and **Items** are icon tabs inside its right edge that open a
list panel docked beside them (click the tab again, or the panel's close
button, to close it). The search box filters any list. If the cards ever show no text, `/wf debug cards` reports what
each card holds and which font it uses. Pages opt into the main window with `layout = "cards"`; every other
page is a list in the side panel.

**For you** is the first tab (`/wf next` opens it): a short, curated list of
things to do next, one card per kind of thing, each labelled with its kind:

- **Due now** (at most two, always first): spells you can train and afford
  (the card lists them, with rank and cost)
  (after one trainer visit), repairs at 50% durability or lower, ammo under
  200, food and drink under 5 (not mages, from level 6), and an undiscovered
  flight path within about 3 minutes.
- **Profession**: the next rank of a profession you can train now
  (Journeyman at 50 skill and level 10, Expert at 125 and 20, Artisan at 200
  and 35), at the nearest trainer known to teach it; due when you're at your
  cap, worth a visit before that. Its trip ends with buying the rank: done
  when the game raises that profession's skill cap, not just on talking.
- **Worth a visit** (sharing those two slots, after what's due): your class
  trainer at an even level (when classes get new spells) before your first
  visit or two levels after the last one, and a repair when your gear is at
  75% or lower and a repairer is under 2 minutes away.
- **Hand in**: the best group of quests ready to hand in, grouped by where you
  hand them in (30 seconds each).
- **Finish**: the best group of unfinished quests in your log whose
  objectives are close together, as one whole-quest trip, timed at 5 minutes
  times the share of objectives left (at least a quarter).
- **Best quest**: the single quest worth the most XP that you can pick up
  nearby, as a whole-quest trip (pick it up, do it, hand it in).
- **Questing zone** (up to three, anywhere in the world): where to quest at
  your level. Each counts the quests you can take there now and the ones
  their chains unlock (follow-ups whose first step you can take or have in
  your log), all fitting your level, with their XP. Its trip goes to the hub
  with the most quests for you and picks all of them up, giver by giver; the
  card names the next hubs and where the chains lead on to. A zone needs 4 quests you can take now; zones are
  ranked by XP.
- **Dungeon** (or **Raid**): the best one, with its quests picked up on the
  way to the entrance, and the others for your level named on the card.
  Mobs in Forever's dungeons give little XP, so the quests make the run: a
  dungeon is suggested only when you can take most (60%) of its quests now,
  and one without quests for you isn't suggested at all. Those held back are
  named with the level their quests open at ("The Stockade at level 22").
  Without quest data, the best by level fit and travel time.

Due now and Worth a visit come first, then the zones, then the dungeon; hand
in, finish and best quest follow in order of estimated XP per minute: XP over the
trip plus 5 minutes per quest (`SECONDS_PER_QUEST` in `ForYou.lua`). XP comes
from a data source's quest XP table, with the vanilla penalty for quests below your
level; quests it has no XP for (Forever-only ones) get the average for their
level. Without that table the ranking falls back to quests per hour weighted
by level fit, and without quest data to dungeons by level fit and travel time;
the summary line says which. Quests already in your log count at full XP, with
only the time left for them; a dungeon's quests in your log count toward it.
The Quests page has every hub and your whole log. `/wf debug` shows how long a
refresh took.

**Fanfare.** When a trip is done, a frame near the top of the screen says
what it came to: XP earned (across level-ups), time taken, distance travelled
and quests handed in. When For you has a new major suggestion (a questing
zone, a dungeon, spells to train, a profession's next rank) a short "New
journey available" toast pops up; click it to start the journey, or to add
it to the trip you're on (the usual question). Both fade after a few seconds,
not while the mouse is over them. For you checks for new ones after a level,
a quest handed in or a new zone (not in combat); the first look after this
update only learns what's there. `/wf toasts` or the options turn the toasts
off.

**Sounds.** Wayfinder plays one of the game's own sounds when it asks about a
quest you picked up (or one that continues a chain), when a stop is added to
your trip, when a trip starts, when it's done, and for the toast. When a trip
starts or grows and asks about a follow-up quest, you hear the question's
sound alone. `/wf sounds` lists each moment's shortlist;
`/wf sounds <moment> <n|next>` plays one to compare,
`/wf sounds use <moment> <n|off|default>` keeps it, and
`/wf sounds test <moment> [n]` shows the real banner, toast or question with
sample text. Moments: `popup`, `step`, `start`, `complete`, `toast`.

### Getting around

- **Directions** add a step whenever you walk into another zone ("Walk to
  Elwynn Forest"); it counts as done as soon as you're in that zone.
- **Re-routing is automatic** after a hearthstone, portal or loading screen,
  when you're on another continent than the current step expects, or when
  you've walked well away from the current target. Never during a flight,
  and at most every 10 seconds. The R button still re-plans on demand.
- **TomTom**: when it's installed, Wayfinder asks once whether to use it;
  then each step goes on TomTom's arrow and map pins, titled with what to do
  there (`/wf tomtom` or the options switch it, or retry after TomTom failed).
- **Options** (Options > AddOns > Wayfinder, or `/wf options`): the compass in
  the directions box, TomTom's arrow and the minimap button. The compass and
  TomTom are separate: use either, both, or neither for text directions
  only; with the compass off the directions box is narrower.
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

The **Quests** tab (or `/wf quest <name>`) searches quests in the quest data by name,
or takes a shift-clicked quest link. Each quest shows its level and whether you
can take it: available (grey and red quests say so), in your log, done, needs
earlier quests (naming the first one you can take, or the one in your log to
finish), too low, not for your race or class, or not available (closed by a
quest you did, outlevelled, needs a profession). Click a quest to go to its
quest giver, to where you hand it in, or to the start of its chain; the trip
waits there until you accept or hand in the quest. When a search matches
dungeon quests, and on the Dungeons tab ("Quests" button), one trip picks up
every quest you can take for that dungeon and ends at the entrance. The rules
are the Quest hubs rules (`ns.Quests.QuestStatus(id)` and
`ns.Quests.ChainStart(id)` give the status, reason and first chain step).
Needs quest data.

With an empty search the tab lists your quest log: level, zone and the first
objective not done yet (or "ready to hand in"). Click a quest for a trip for
what is left of it. "Add" (on log quests and search results) puts the quest
into the trip you're on, or starts one; "In trip" takes it out again. The
trip is re-ordered from where you are each time, each quest in its own order
(pick up, objectives, hand in) but interleaved by travel time. "Hand in N
completed quests" visits every finisher in one trip, and can be added to the
current trip too. Without quest data the log still lists, but without
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
    reports the quest complete), `turnin`, `item` (collect an item a quest
    needs; done when it's in your bags) and `manual` (a quest step only you can
    tell is done; the directions box's next button confirms it).
  - `ns.Journey.QuestStops(questID, here)` gives the stops for a whole quest
    from where it stands now: pick it up, do the objectives (the game's quest
    area marker once it's in your log, else the quest data's objective mobs, objects,
    item drops and explore points), hand it in. Before the objectives come
    what the quest data says the quest needs first: its source items you don't have
    (where they drop or lie) and its extra objectives in order (e.g.
    "Fill the bowl at the moonwell").
  - A quest's objectives are an area, not a point: every spawn of what you
    still need (the quest data's creatures, objects and item sources). Within 80
    yards of any of them you're in the area: the compass and waypoints step
    aside and the directions box says "In the area" with your progress.
    Past 120 yards you've left, and the way points at the nearest spawn from
    where you are. A finished objective's spawns stop counting.
  - Picking up a quest that isn't in your trip asks whether to add it (with
    how much longer the trip gets), start a new trip for it (with its time),
    or not now; quests picked up one after another are asked about together,
    once the trip has no more pickups right where you are. The options turn
    the question off.
  - When a trip gains a quest's hand-in, the quests that follow it (picked
    up where you hand it in, often from the same NPC) are offered if adding
    them costs 3 minutes of travel or less.
  - Skipping a stop with next marks it skipped, not done; going back reopens
    it, and doing it anyway (the quest log or your bags say so) marks it done.
  - Quest data can miss a step of a chain, so a follow-up looks available
    when it isn't. When you talk to a quest giver, the game lists what they
    offer you: a trip's pickup there that isn't on the list is dropped (with
    its hand-in), and that quest counts as locked everywhere until you hand
    something in or level up. `/wf debug quest <name or ID>` prints what
    the quest data says about a quest's chain.
  - Forever's own quests (IDs from 90000) often have no chain data at all,
    like the second Return the Statuette (98189) after the original 286.
    For those, the earlier quest is inferred: one of the same name with a
    lower ID, else the quest one ID lower when its hand-in NPC starts this
    one. An inferred link only counts while you could do that earlier quest
    (so the other faction's quest of the same name never holds one up).
  - The current trip is saved per character and resumed after a login or
    reload, re-planned from where you are. The directions box's book button
    opens an overview of every stop (done / now / next; finished stops fold
    into one line you can click open, by themselves from three of them or
    when they'd push open stops off the list; under the current stop, the
    steps that get you there, walk, fly, boat, with the one you're on
    marked, and any stop's +/- shows or hides its own, so you can see where
    it's taking you and hearth instead; under the stops, "On the way": up
    to four things near the route that add 3 minutes of travel or less,
    quest givers with quests for you, quests in your log ready to hand in
    and vendors you need, each with an Add button; and a map of the rest of
    the trip; the mouse wheel scrolls the list when it doesn't all fit); a
    stop can be dropped
    there, together with the stops that need it, or dragged up or down by its
    handle to reorder the trip. A reordered trip keeps your order (`Journey.Move`);
    stops added later go where they add the least travel, and a stop can't
    move before one it needs (a hand-in before its pickup).
- **Commands**: `ns.RegisterCommand(name, help, run)` adds `/wf <name>`; `run`
  gets the rest of the line in its original case, so item links survive.
- **Quest helpers** on `ns.Quests`: `Quest(id)`, `AllQuests()`,
  `PlayerQuestState()`, `IsQuestAvailable(id)` (the Quest hubs rules) and
  `QuestGiver(id, here)`. Game data from the data sources is on `ns.Data`
  (`Npc(id)`, `Item(id)`, `NPCsOfKind(kind, faction)`, `ClassSpells(class)`, ...).
- **Dungeons** for other pages: `ns.Dungeons.Catalogue()` and `ns.Dungeons.ForArea(areaID)`.

### Data sources

Wayfinder ships no third-party data. Everything it knows comes from the game
client, from what it records while you play (`Harvest.lua`), and from the
hand-made files in `Wayfinder/Data/`. Other addons can add data by
registering a **source**; `Wayfinder/Sources.lua` documents the interface in
full. In short:

```lua
-- In a companion addon whose TOC has "## Dependencies: Wayfinder":
Wayfinder.RegisterSource({
  id = "mydata", label = "My data", priority = 30,
  ClassSpells = function(class) return { { spellID = 686, level = 1, cost = 10 } } end,
  Npc = function(id) ... end, NpcIDs = function(flag) ... end,
  Quest = function(id) ... end, QuestIDs = function() ... end,
})
```

- Every function is optional: `Quest`/`QuestIDs`, `Npc`/`NpcIDs`, `Object`,
  `Item`/`ItemIDs`, `Dungeons`, `QuestXP`, `EraToForever`, `ClassSpells`,
  `TrainerSpells` and `TaxiCost`. A page that needs one a source doesn't
  have says so and falls back to harvested data.
- Records are plain tables. Positions are `{ mapID, x, y, areaID }` with x and
  y 0-1 in Forever coordinates. Quest records use QuestieDB-style field names
  (`startedBy`, `preQuestSingle`, `objectives`, ...) except that races and
  classes are sets.
- When sources overlap, the higher `priority` wins: per record for quests,
  items and objects, field by field for NPCs and class spells. What you
  learned in game beats any source.
- A source that errors is reported once and skipped; Wayfinder keeps going.
  `Wayfinder.UnregisterSource(id)` takes a source away again.

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

```bash
lua tests/wayfinder_smoke.lua
```

Run the addons against stubbed WoW APIs (the second one is Wayfinder, with a
fixture data source).

**Finding slow spots in game:** `/wf perf on` times what the window does
(it stays on across reloads, so first-open costs are caught too). Every tab
switch, refresh, search or internal message becomes a trace: a tree of the
Wayfinder and data-source functions it called, with time, call counts and
memory allocated. `/wf perf` prints the last trace, `/wf perf copy` opens the
whole report to copy, `/wf perf reset` clears it and `/wf perf off` puts
everything back. The timers add a little overhead of their own, and Blizzard's
APIs are never wrapped. This checks our own code paths only,
not real Forever behaviour.
