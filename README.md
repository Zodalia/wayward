# WoW Forever levelling helper

A "Google Maps for levelling" addon for WoW Forever: search or pick a category
("Class trainer", "Quest hubs", "Dungeons", "Vendors"), get options ranked for
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
  it), because Blizzard's on-screen navigation is off by default in Forever.
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

Install the same way as WFProbe below, with the `Wayfinder` folder.

Development: `lua tests/wayfinder_smoke.lua` runs routing, step advance,
harvesting and the panel against a fake two-continent world.

### Building on Wayfinder: pages and journeys

- **Pages** are the panel's tabs. A file that loads before `UI/Panel.lua`
  calls `ns.RegisterPage(page)`. The page contract (id, label, order,
  searchable, Summary/Empty/Results taking the search text, and the result
  shape with `route` or `journey` and optional row `actions`) is documented
  at the top of `UI/Panel.lua`. The lowest `order` opens by default; "Find"
  (the categories) is order 20. `ns.Panel.Search(pageID, text)` opens a page
  with a search, and shift-clicked links go into the search box.
- **Journeys** are trips with several stops (`Journey.lua`): stops are put in
  the quickest order, with an optional fixed final stop. A stop with
  `action = { kind = "pickup" | "turnin", questID }` waits until that quest is
  accepted or handed in; a quest done early is planned out of the rest of the
  trip. Start one with `ns.Nav.StartJourney(ns.Journey.Plan(start, def))`, or
  return it as a result's `journey`.

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
