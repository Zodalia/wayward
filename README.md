# WoW Forever levelling helper

A "Google Maps for levelling" addon for WoW Forever: search or pick a category
("Class trainer", "Quest hubs", "Dungeons", "Vendors"), get options ranked for
your character (level fit, travel time, why it's worth going), then step-by-step
directions including flight paths, boats and zeppelins.

Status: **phase 0, API probe.** Forever runs the retail (Mainline 12.1.5) API
with Midnight addon restrictions, and adds a lot of new content that no existing
database covers. Before designing the data layer we need to know which client
APIs actually return data in Forever.

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
   on-screen arrow appear. `/wfprobe waypoint clear` removes it.
5. Visit and interact with: a class trainer, a vendor, a flight master, the
   bank, a quest giver (open a quest and accept it), an NPC with a gossip menu.
   Each one is captured automatically ("captured …" in chat).
6. `/wfprobe show`, then Ctrl+A, Ctrl+C, and paste the report back.

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
