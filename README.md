# Wayward

A levelling helper for World of Warcraft: Forever and WoW Classic Era
(including Season of Discovery and Hardcore realms) that works like a map app,
not a guide. It suggests what to do next for your character (quests to hand
in or pick up, where to quest, a dungeon, spells to train, repairs) and gives
step-by-step directions there: on foot, by flight path, boat, zeppelin, tram
and portal.

It is not a speed-levelling route. Explore as you like; Wayward tells you
what is worth doing near you and gets you there.

## Install

1. Put the `Wayward` folder in `World of Warcraft/_forever_/Interface/AddOns/`
   (Forever) or `World of Warcraft/_classic_era_/Interface/AddOns/` (Classic
   Era, Season of Discovery, Hardcore), from a release zip, `tools/package.sh`,
   or a symlink to this checkout. The same folder works in both.
2. Log in. A short welcome explains the basics; `/ww` or the minimap button
   opens the window, and right-clicking the button opens the options.
3. Open a flight map once on each continent and visit your class trainer.
   Wayward learns flight paths, trainers and vendors as you meet them.

Optional: install [QuestieDB](https://github.com/Questie/QuestieDB) (the
Questie team's free database, for Forever and Classic Era alike) and Wayward reads it for
quests, items and every trainer; nothing to configure. TomTom's arrow is
supported.

**Requirements and limits.** The Forever client (Interface 16001) or the
Classic Era client (1.15.9, Interface 11509; 11508 for its test realm). English
(enUS/enGB) client: directions work on any locale, but trainers and vendors
from data sources are recognised by their English subtitles ("Warlock
Trainer", "Food & Drink"), weapon masters and professions by English names,
dungeons by their English names, and the nameplate star and target button
look for the data's English NPC names. Boat and zeppelin docks and dungeon
entrances shipped with the addon are approximate until you record them
(`/ww dock`, or walk into the dungeon).

### Classic Era, Season of Discovery and Hardcore

One TOC lists both clients' Interface numbers, and Wayward tells them apart
when it loads (`ns.Game()`: `WOW_PROJECT_ID`; on Era `ns.Season()` reads the
realm's season, `C_Seasons`, and `C_GameRules.IsHardcoreActive`). `/ww debug`
names the game it thinks it's in. What differs on Classic Era:

- The quest log is read through `ns.QuestLog` (Core.lua): Forever's
  `C_QuestLog.GetInfo` family where the client has it, Era's
  `GetQuestLogTitle`, `IsQuestComplete`, `GetQuestLogIndexByID` and
  `GetQuestsCompleted` where it doesn't.
- No map pin: Era has no user waypoints, so the directions box and its
  compass (or TomTom's arrow) show the way.
- Forever-only data stays out: the Auberdine - Stormwind Harbor boat, the
  seeded trainer (measured on Forever's moved Stormwind map), the conversion
  of Era coordinates to Forever's, "New in Forever" tags and the chains
  inferred for Forever's own quests (Season of Discovery's quest IDs are high
  too, and aren't Forever's).
- Dungeon mobs give their full XP on Era, so For you still suggests a
  dungeon you have no quests for.
- Hardcore: quests three levels above you (orange) count as too hard, not
  only red ones at five, wherever Wayward hides or flags hard quests.
- Season of Discovery: whatever the installed QuestieDB knows about the
  season (its quests, its NPCs) comes through it; Wayward has no runes or
  other season features of its own.

Not yet tried in game on Classic Era: the tests run every check as both
clients (`WAYWARD_GAME=era`), against stubs.

## Options

Options > AddOns > Wayward has every setting, in sections: **Navigation
aid** (the compass in the directions box, TomTom's arrow), **NPCs** (the
star over the NPC you are heading for, and the game's friendly nameplates it
needs), **Trips and quests** (the question when you pick up a quest, whether
the journey overview opens by itself when a trip starts, the new-journey
toasts), **Minimap** (the button), and **Windows and help** (reset window
positions, show the welcome again, list the slash commands). Right-click the
minimap button or the addon compartment entry, or click Options in the
window's title bar, to open them.
`/ww options` opens the panel, `/ww help` lists the commands, `/ww welcome`
shows the introduction again, `/ww reset` puts every window back.

## What it does

`Wayward/` is the addon; `/wayward` (or `/ww`) opens the panel. In detail:

- **Class trainer**: trainers for your class, ranked by travel time from where
  you stand, with what you can train now ("1 new spell to train for 10s · next:
  4 spells at level 22"). Hover a row to preview the route, click for directions.
- **Directions**: walking, flight paths you know, boats, zeppelins, the Deeprun
  Tram and the Rut'theran portal. Each step places the map waypoint and moves on
  when you get there. The directions box has its own compass (`/ww compass` hides
  it), because Blizzard's on-screen navigation is off by default in Forever;
  without an arrow its circle shows what's ahead (quest pickup or hand-in,
  flight). It also shows the trip, a bar of stops done, the step, which stop
  you're on, and distance and time left, with Blizzard's square buttons for
  skip and move on (on a trip), all stops, recalculate and stop.
- **Add a stop**: the directions box's + button (bottom right) lists
  errands to fit into the trip, like a road map's "petrol on the way": repair,
  vendor (sell and buy), mailbox, bank, inn, auction house and, for hunters,
  stable master. Pick a kind along the top; under it, the five places that add
  least to the trip, each with the time it adds ("+2 min") and Add. It opens on
  repairs when your gear is at 75% or less, on vendors when your bags are
  full, else on the kind you last added from. Plain directions become a trip
  with the place as one more stop. NPCs come from the ones you've talked to
  and from the data source's NPC flags (your faction's); mailboxes from the
  ones you've opened and the data source's objects named "Mailbox" in your
  side's towns (judged by the nearest innkeeper or flight master).
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
  the game's setting), a Wayward line in their tooltip, and a target button
  beside the directions box that targets them (`/target`, with a key binding
  under Key Bindings > AddOns > Wayward). Raid markers would be simpler,
  but addons may not set them. `/ww marker` or the options turn the star and
  the tooltip line off. Quests handed in to (or started from) an object, like
  Buzzbox 323, say "use" instead, with nothing to target.
- **Learning as you play**: talking to a trainer, vendor, flight master,
  innkeeper or banker records where they are, and so does opening a mailbox. Opening a flight map records
  which flight paths you know. Your class spell list is read at the trainer.

- **Data sources (optional)**: Wayward bundles only hand-made data and what
  it learns in game. A separate data addon can register a source with more
  (see [Data sources](#data-sources) below). With quest and NPC data, Class
  trainer gains every trainer for your class, and **Quest hubs** lists nearby
  quest givers you can take quests from (level, race, class, prerequisites,
  not done, not in your log, not grey), grouped by place ("Auberdine", named
  after the nearest flight path's town or an explored subzone) and ranked by
  travel time. Hover a hub for its quests. With class spell data, "new
  spells" works before your first trainer visit. `/ww debug` shows the data
  sources and first-scan times.

- **Dungeons**: dungeons and raids that fit your level (3 under to 6 over; raids
  only from their level), ranked by level fit and travel time to the entrance.
  Levels come from the client's dungeon finder list, matched to our dungeons by
  name; dungeons only that list has (Forever's new ones, such as Hall of
  Thanes) are listed too, at the end and without directions until you walk in
  once. Walking into a dungeon or raid records its entrance (where you were
  when the loading screen started; dungeon finder teleports don't count), and
  a recorded entrance beats every other source. Otherwise entrances come from a data source if one has them, otherwise from
  `Wayward/Data/Dungeons.lua`. Those are approximate vanilla positions, and
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
- Boat, zeppelin, tram and portal docks in `Wayward/Data/Transports.lua` are
  approximate, and Forever's new routes (e.g. Auberdine - Stormwind) are
  missing. Record one yourself: `/ww dock` where you board, ride, `/ww dock`
  where you get off. Routes use it immediately; `/ww dock list` copies the
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
item into its search box, type `/ww item <link>` in chat, or type part of the
name. Each source is a row: dungeon drops ("Drops from Edwin VanCleef in The
Deadmines", routed to the entrance, with a **+N quests** button that picks up
the dungeon's quests on the way), mobs and objects in the world (nearest spawn,
one row per zone), quests that reward it (can take now, in your log, needs
earlier quests or a higher level) and the nearest vendor that sells it. Things
you can do now come first, then shorter trips. Drops and quest rewards need
item data from a data source; without it only vendors you visited that sold the item are
known. Item tooltips get a "Wayward: /ww item for directions" line when an
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
button, to close it). The search box filters any list. If the cards ever show no text, `/ww debug cards` reports what
each card holds and which font it uses. Pages opt into the main window with `layout = "cards"`; every other
page is a list in the side panel.

**For you** is the first tab (`/ww next` opens it): a short, curated list of
things to do next, one card per kind of thing, each labelled with its kind:

- **Due now** (at most two, always first): spells you can train and afford
  (the card lists them, with rank and cost)
  (after one trainer visit; spells you could have learned when you last
  closed the trainer's window and didn't are left out, and only the Class
  page still lists them), repairs at 50% durability or lower, ammo under
  200, food and drink under 5 (not mages, from level 6), and an undiscovered
  flight path within about 3 minutes.
- **Don't miss** (right after what's due): the quest that stands out most
  among those you can take nearby or have in your log, with its first stop
  under 10 minutes away, whatever its XP. The card says why in plain words.
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
  ranked by XP. Below level 10 your starting zone comes first (the one
  you're in, else your race's) and no other starting zone is suggested
  while yours still has quests for you.
- **Dungeon** (or **Raid**): the best one, with its quests picked up on the
  way to the entrance, and the others for your level named on the card.
  Mobs in Forever's dungeons give little XP, so the quests make the run: a
  dungeon is suggested only when you can take most (60%) of its quests now,
  and one without quests for you isn't suggested at all. Those held back are
  named with the level their quests open at ("The Stockade at level 22").
  Without quest data, the best by level fit and travel time.

Due now, Don't miss and Worth a visit come first, then the zones, then the dungeon; hand
in, finish and best quest follow in order of estimated XP per minute: XP over the
trip plus 5 minutes per quest (`SECONDS_PER_QUEST` in `ForYou.lua`). XP comes
from a data source's quest XP table, with the vanilla penalty for quests below your
level; quests it has no XP for (Forever-only ones) get the average for their
level. Without that table the ranking falls back to quests per hour weighted
by level fit, and without quest data to dungeons by level fit and travel time;
the summary line says which. Quests already in your log count at full XP, with
only the time left for them; a dungeon's quests in your log count toward it.
A card with a quest your trip on now already has isn't shown until the trip
is done. The Quests page has every hub and your whole log. `/ww debug` shows how long a
refresh took.

**Notable quests.** XP isn't everything: Wayward also asks "am I missing
something cool here?". A quest is notable when it is your class's quest, part
of an epic or legendary line, rewards a green weapon or a blue piece of
armour your class would use (weapon skills, and only the heaviest armour you
wear at the item's level; the quality only once the game has the item cached,
which Wayward asks for but never waits on, so until then a reward is only
mentioned), leads
into a dungeon or an epic quest further down its chain, or is new in Forever
(an ID from 90000 whose name no original quest has). Profession and holiday
quests and reputation outside your own cities are mentioned but don't tag a
quest on their own. Notable quests carry a short tag on the Quests tab and on
For you's quest lines; the tooltip says why, and a standout reward shows in
its own tooltip beside it (Don't miss cards, Quests tab log and search rows,
Quest hubs rows). `/ww debug quest <id|name>`
prints a quest's sort, flags, reward items and reasons
(`ns.Quests.Notable(id)`, `ns.Quests.QuestSort(id)`, `ns.Quests.RewardItems(id)`).

**Only have 20 minutes?** The buttons at the right of the summary line (15,
30, 60, Any), or `/ww time 20` and `/ww time off`, set how long you have,
per character. For you then shows only what its estimate (trip plus quest
time) says fits, with each card's time in its corner: hand-ins and finishes
by least travel rather than XP per minute, a questing zone only when the trip
to its first hub plus one quest fits, and no dungeon under an hour. When
nothing fits it says so and offers the quickest option anyway, "a bit over".
The estimates are rough, so Wayward learns yours: each quest you accept
and hand in in one session is timed (from the later of accepting it and your
last hand-in, so quests done side by side share the time; at most an hour),
and once 5 are timed the average of your last 20 replaces the 5 minutes per
quest. `/ww debug` shows it.

**Fanfare.** When a trip is done, a frame near the top of the screen says
what it came to: the 2 to 4 stats that stand out most. Each kind has a
priority (levels, quests handed in, profession ranks trained, flight paths
learned, money in, quests taken, XP across level-ups) and scores more the
more of it you got, so 4 gold can beat 3 quests taken; nothing you got none
of is shown. Distance and time only make up the numbers when a trip
achieved less than two things. When For you has a new major suggestion (a questing
zone, a dungeon, spells to train, a profession's next rank) a short "New
journey available" toast pops up; click it to start the journey, or to add
it to the trip you're on (the usual question). Both fade after a few seconds,
not while the mouse is over them. For you checks for new ones after a level,
a quest handed in or a new zone (not in combat, and not on a flight: the
zones flown over wait for the landing); the first look after this update
only learns what's there. A trainer card pops up only for a spell no toast
has shown yet, whichever town's trainer is nearest. `/ww toasts` or the options turn the toasts
off.

**Sounds.** Wayward plays one of the game's own sounds when it asks about a
quest you picked up (or one that continues a chain), when a stop is added to
your trip, when a trip starts, when it's done, and for the toast. When a trip
starts or grows and asks about a follow-up quest, you hear the question's
sound alone. `/ww sounds` lists each moment's shortlist;
`/ww sounds <moment> <n|next>` plays one to compare,
`/ww sounds use <moment> <n|off|default>` keeps it, and
`/ww sounds test <moment> [n]` shows the real banner, toast or question with
sample text. Instead of a number, `id <kit>` is any sound kit ID, on the list
or not (`/ww sounds step id 12345`); Wayward says so when the game doesn't
play it. `/ww sounds export` opens your choices as one line to copy
(`popup=7355 step=836 …`). Moments: `popup`, `step`, `start`,
`complete`, `toast`.

### Getting around

- **Directions** add a step whenever you walk into another zone ("Walk to
  Elwynn Forest"); it counts as done as soon as you're in that zone.
- **Re-routing is automatic** after a hearthstone, portal or loading screen,
  when you're on another continent than the current step expects, or when
  you've walked well away from the current target. Never during a flight,
  and at most every 10 seconds. The R button still re-plans on demand.
- **TomTom**: when it's installed, Wayward asks once whether to use it
  (yes turns Wayward's compass off; the options can turn it back on); then
  each step goes on TomTom's arrow and map pins, titled with what to do
  there (`/ww tomtom` or the options switch it, or retry after TomTom failed).
  The game keeps its own map pin (Forever only: Classic Era has none) across a logout or reload; Wayward takes
  its pin from last time down when TomTom shows the way or no trip resumes
  (a pin you placed yourself since stays).
- **Options** (see [Options](#options) above): the compass and TomTom are
  separate: use either, both, or neither for text directions only; with the
  compass off the directions box is narrower.
- **Flight paths** are learned per continent: a flight map only lists the
  continent you're on, so open one once per continent. "New flight path
  discovered!" also marks the nearest one as known.
- **Waypoint height**: addons can only give the game a map position (the game
  reports heights as 0 to addons in Forever), so the height of the in-world
  marker is the game's own guess and can be off on multi-level places.
- **Journey stops** show their zone in the overview and in previews.
- **Class trainers** in the same room are one row ("3 warlock trainers in
  Stormwind City").
- **Minimap button**: left-click opens Wayward, right-click opens the
  options, shift-right-click the journey overview during a trip. It uses LibDBIcon when another addon provides it
  (so button managers can handle it), otherwise a plain button you can drag
  around the minimap. `/ww minimap` hides it. Wayward is also in the addon
  compartment menu.

### Look

Wayward's windows use Blizzard's standard templates (window, tabs, search
box, tooltip-style boxes), so they follow UI addons that restyle those, and
fall back to a plain look if a template is missing. Long result lists scroll
with the mouse wheel or the arrows under the list.

With [EllesmereUI](https://github.com/EllesmereGaming/EllesmereUI) installed,
Wayward also registers with its public skinning API (`EllesmereUI.RegisterSkin`)
and takes on your theme, accent colour and font. This needs EllesmereUI's
"Blizz UI Enhanced" module (`EllesmereUIBlizzardSkin`) turned on, with skins
for other addons allowed. ElvUI's Skins module is used when present
(unverified). `/ww skin` turns the skin off; windows already restyled keep it
until `/reload`.

Moving things: drag the directions box or the journey overview anywhere. In
the game's Edit Mode, the directions, the journey overview, the "Journey
complete!" banner and the "New journey available" toast each show a box you
can drag, even while they're hidden; right-click one to put it back where it
started. With EllesmereUI, the same four are in its unlock mode (group
"Wayward", through `EllesmereUI:RegisterUnlockElements`). The toast's box is
left out while toasts are off. Not yet tried in game.

Install by symlinking (or copying) the `Wayward` folder into the Forever
client's AddOns folder, as for WFProbe below:

```bash
ln -s "$PWD/Wayward" "/Applications/World of Warcraft/<forever folder>/Interface/AddOns/Wayward"
```

Development: `lua tests/wayward_smoke.lua` runs routing, step advance,
harvesting and the panel against a fake two-continent world.

### Quests

The **Quests** tab (or `/ww quest <name>`) searches quests in the quest data by name,
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
current trip too. Adding or starting a trip for one quest that has a chain
asks which of its next steps to add as well (ticked when on the way); a trip
of several quests only asks about follow-ups on the way. Without quest data
the log still lists, but without directions.

**Where a chain leads:** every quest list (Quests tab log and search, For you
cards, the journey overview's quest stops) has a tooltip line on what follows
the quest: "Chain: 4 more quests (levels 18-24), ends in The Deadmines" or
"Leads to a Shadowfang Keep quest". A quest whose chain reaches a dungeon
quest says so on its row too, and picking up a quest that starts a long chain
(3+ quests) or leads to a dungeon quest says so in the "start a trip?"
question. The chain is walked forward from the data (next quest, quests that
need it, inferred Forever links), up to 12 steps; quests that close each other
count as one step, and only quests your race, class and level can do count.
`ns.Quests.ChainAhead(id)` returns the steps and summary,
`ns.Quests.ChainText(id)` the line; `/ww debug quest <id|name>` lists the steps.

**Trips are flexible:** starting new directions while a trip is on asks
whether to add them to the trip or replace it. Shift-click any row in the
panel to add it to the trip you're on.

### Building on Wayward: pages and journeys

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
    tell is done; the directions box's move on button confirms it there).
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
  - Spawns close together are one area (a camp; `ns.Quests.ObjectiveAreas`),
    and a quest's objectives can have several. The trip heads for the one
    least out of the way between the stops either side (`ns.Journey.PickArea`).
    Leave an area after 30 seconds or more in it and it counts as cleared for
    5 minutes (about a respawn): the trip is re-planned from where you are, on
    to another area, or to the stops on the way there first, and the
    directions box says "Next spot". A short step out points at the nearest
    area you haven't cleared. When every area is cleared (a quest with one
    camp, say), the stop waits for the first to respawn: the trip does other
    stops first when they fit, and the directions box says when it respawns.
    The trip's time counts the wait (and it shrinks as the camp respawns).
    Cleared areas are saved with the trip.
  - Making progress on a later stop's objectives while you're in their area
    (another quest's camp on the way) makes that stop the next one.
  - In a camp, its mobs on nameplates count (`Camps.lua`; enemy nameplates
    have to be on, about 40-60 yards): once you've killed there and for 10
    seconds none are in sight that you could kill (dead, or tapped by someone
    else), the box says "Camp looks cleared", and leaving counts it as cleared
    straight away. After two kills there it also says how long the rest should
    take at your pace ("~3 min left here"), and the trip's time counts it.
    Whatever the game keeps secret counts as not seen, so without nameplates
    the 30 seconds in the area decide.
  - Dying holds the trip still until you're alive again: releasing to a
    graveyard doesn't count as leaving the camp (the visit just ends, not
    cleared), doesn't re-plan, and the way still points where it did.
  - Picking up a quest that isn't in your trip asks whether to add it (with
    how much longer the trip gets), start a new trip for it (with its time),
    or not now; quests picked up one after another are asked about together,
    once the trip has no more pickups right where you are. The options turn
    the question off.
  - When a trip gains a quest's hand-in, the quests that follow it (picked
    up where you hand it in, often from the same NPC) are offered if adding
    them costs 3 minutes of travel or less.
  - **Move on** (the directions box's >> button) works on the stop you're
    heading for: in one of its camps, that camp counts as cleared and the
    trip goes on (another camp, or other stops while it respawns; the camp
    isn't "the area" again until you've walked out of it); at a quest step
    only you can tell is done, it's done; anywhere else, the stop comes after
    the next one that doesn't need it (a pickup never goes after its own
    hand-in). In a trip planned for you that's a rule the later plans keep
    (`Journey.Postpone`, saved with the trip; your newest choice wins), so the
    rest is still ordered for you; in a trip you ordered yourself it moves.
  - **Skip** (the box's x button) asks first, then takes the stop off the trip
    with the stops that need it (a hand-in when you skip the objectives), like
    the overview's x.
  - Quest data can miss a step of a chain, so a follow-up looks available
    when it isn't. When you talk to a quest giver, the game lists what they
    offer you: a trip's pickup there that isn't on the list is dropped (with
    its hand-in), and that quest counts as locked everywhere until you hand
    something in or level up. `/ww debug quest <name or ID>` prints what
    the quest data says about a quest's chain.
  - Forever's own quests (IDs from 90000) often have no chain data at all,
    like the second Return the Statuette (98189) after the original 286.
    For those, the earlier quest is inferred: one of the same name with a
    lower ID, else the quest one ID lower when its hand-in NPC starts this
    one. An inferred link only counts while you could do that earlier quest
    (so the other faction's quest of the same name never holds one up).
  - The current trip is saved per character and resumed after a login or
    reload, re-planned from where you are (tried again for half a minute
    while the game isn't ready to place you; a trip it still can't re-plan
    stays saved, and `/ww resume` tries again). The directions box's book button
    (it flashes a few times when stops are added to the trip, rather than
    the overview popping open) opens an overview of every stop (done / now / next; stops you skipped
    aren't listed; finished stops fold
    into one line you can click open, by themselves from three of them or
    when they'd push open stops off the list; under the current stop, the
    steps that get you there, walk, fly, boat, with the one you're on
    marked, and any stop's +/- shows or hides its own, so you can see where
    it's taking you and hearth instead; under the stops, "On the way": up
    to four things near the route that add 3 minutes of travel or less,
    quest givers with quests for you, quests in your log ready to hand in
    and vendors you need, each with an Add button (a quest whose objectives
    and hand-in add under a minute more comes whole, not asked about once you
    pick it up); and a map of the rest of
    the trip; the mouse wheel scrolls the list when it doesn't all fit); a
    stop can be dropped
    there, together with the stops that need it, or dragged up or down by its
    handle to reorder the trip. A reordered trip keeps your order (`Journey.Move`);
    stops added later go where they add the least travel, and a stop can't
    move before one it needs (a hand-in before its pickup).
- **Commands**: `ns.RegisterCommand(name, help, run)` adds `/ww <name>`; `run`
  gets the rest of the line in its original case, so item links survive.
- **Quest helpers** on `ns.Quests`: `Quest(id)`, `AllQuests()`,
  `PlayerQuestState()`, `IsQuestAvailable(id)` (the Quest hubs rules) and
  `QuestGiver(id, here)`. Game data from the data sources is on `ns.Data`
  (`Npc(id)`, `Item(id)`, `NPCsOfKind(kind, faction)`, `ClassSpells(class)`, ...).
- **Dungeons** for other pages: `ns.Dungeons.Catalogue()` and `ns.Dungeons.ForArea(areaID)`.

### Data sources

Wayward ships no third-party quest database: none for Forever is under a
licence that allows bundling it. What it knows comes from the game client,
from what it records while you play (`Harvest.lua`), from the hand-made
files in `Wayward/Data/` (a seeded trainer, transports, dungeon entrances,
vendor goods: our own, approximate, vanilla knowledge), and from two
**sources** of its own in `Wayward/Sources/`:

- **QuestieDB** (`Sources/QuestieLive.lua`, `Sources/Questie.lua`): when the
  [QuestieDB](https://github.com/Questie/QuestieDB) addon is installed
  (`## OptionalDeps: QuestieDB`), Wayward reads it at runtime through its
  documented consumer API (contract 4): quests, NPCs, objects, items, dungeon
  entrances and quest XP. Nothing of it is copied or shipped; the player
  installs it from the Questie team's releases.
- **Class spells** (`Sources/Spells.lua`, `Data/ClassSpells.lua`): every
  class's trainer spells with level, cost and required ranks, what weapon
  masters teach, and flight costs, generated from the Forever client's own
  tables (wago.tools) and [WhatsTraining](https://github.com/fusionpit/WhatsTraining)
  (MIT, `Wayward/LICENSES/WhatsTraining.txt`). Regenerated in the author's
  data repository and copied in.

`docs/RELEASE.md` has the licensing notes. Any addon can add another source
(or replace one of those by registering its id again); `Wayward/Sources.lua`
documents the interface in full. In short:

```lua
-- In a companion addon whose TOC has "## Dependencies: Wayward":
Wayward.RegisterSource({
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
  classes are sets. `zoneOrSort` is signed, as in QuestieDB: positive, the
  AreaID the quest belongs to (a dungeon's for a dungeon quest); negative, a
  QuestSort (class, profession, holiday, legendary...). Optional quest fields
  `questFlags`, `specialFlags`, `reputationReward` and `childQuests`, and item
  `class`/`subClass`, feed the notable-quest reasons; without them those
  reasons are left out (item classes then come from the client). An optional
  `QuestRewards()` hands over the quest -> reward items index; without it
  Wayward reads every item's `questRewards` once.
- When sources overlap, the higher `priority` wins: per record for quests,
  items and objects, field by field for NPCs and class spells. What you
  learned in game beats any source.
- A source that errors is reported once and skipped; Wayward keeps going.
  `Wayward.UnregisterSource(id)` takes a source away again.

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
   `/wfprobe plates` near some mobs, once out of combat and once fighting,
   records what nameplates show (GUID, name, dead, tapped, each readable or
   secret), which camps rely on.
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
lua tests/wayward_smoke.lua
```

```bash
WAYWARD_GAME=era lua tests/wayward_smoke.lua
```

```bash
python3 -I tools/lua51.py tests/wayward_smoke.lua
```

Run the addons against stubbed WoW APIs (the second one is Wayward, with a
fixture data source; the third is Wayward again as the Classic Era client:
Era's older quest-log functions, no map pins, Forever-only checks swapped for
Era ones; the fourth is Wayward on Lua 5.1, the game's version, which needs
`pip install lupa`: only 5.1 refuses to pause a background job inside a
`pcall`, as the game does).

**Finding slow spots in game:** `/ww perf on` times what the window does
(it stays on across reloads, so first-open costs are caught too). Every tab
switch, refresh, search or internal message becomes a trace: a tree of the
Wayward and data-source functions it called, with time, call counts and
memory allocated. `/ww perf` prints the last trace, `/ww perf copy` opens the
whole report to copy, `/ww perf reset` clears it and `/ww perf off` puts
everything back. The timers add a little overhead of their own, and Blizzard's
APIs are never wrapped. This checks our own code paths only,
not real Forever behaviour.
