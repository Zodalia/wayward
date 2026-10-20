# Releasing Wayward

Notes for the first public release: what ships, what the data situation is,
and the checklist. Written 2026-10-20 against version 0.4.0.

## What ships

Only `Wayward/` (see `.pkgmeta` and `tools/package.sh`). `WFProbe/` (the dev
probe), `tests/`, `tools/` and `docs/` stay in the repository.

The addon bundles no third-party data. `Wayward/Data/` holds our own
hand-made tables: one seeded trainer, boat/zeppelin/tram/portal docks, dungeon
entrances and vendor goods tiers, all approximate vanilla knowledge marked
`verified = false` until someone records them in Forever.

## Data: what to release, and what not

Checked 2026-10-20 (GitHub API, repo docs, CurseForge listings).

| Source | Licence | Verdict |
|---|---|---|
| QuestieDB, read at runtime through its consumer API (`LibQuestieDB`, contract 4) | none stated, but `docs/api.md` is written for third-party addons ("This is what a third-party addon registers") and `README.md` says the API docs exist so "a third-party addon author needs no source reading" | **Ship the bridge.** No data is copied; the player installs QuestieDB themselves (GitHub releases, addon managers; several Forever addons on CurseForge already depend on it). Keep `## OptionalDeps: QuestieDB`. |
| QuestieDB snapshot (our offline export, ~6 MB) | none: all rights reserved | **Do not ship.** Redistribution needs permission the project has not been given. |
| Class spells from the Forever client tables (wago.tools DB2: SpellLevels, SkillLineAbility, SkillLine, TaxiPath) | Blizzard game data; addons commonly ship DB2-derived tables | **Ship** (about 100 lines). |
| WhatsTraining's class spell lists | MIT | **Ship**, with `LICENSES/WhatsTraining.txt`. |
| VMaNGOS trainer lists (which NPC teaches what) | GPL-2.0 | **Do not ship** unless the whole data addon is released under the GPL. Without it, trainer lists come from visiting trainers and from QuestieDB's NPC flags; weapon masters list what they teach once you visit them. |
| Wowhead | no API, scraping disallowed | never |

Done 2026-10-20: the QuestieDB bridge (`Wayward/Sources/QuestieLive.lua`,
`Sources/Questie.lua`) and the class spells source (`Sources/Spells.lua`,
`Data/ClassSpells.lua`, `LICENSES/WhatsTraining.txt`) are part of Wayward
itself, with `## OptionalDeps: QuestieDB`; every in-game hint says "install
QuestieDB" (`Data.ADDON` in `Wayward/Sources.lua`). The private companion
(`~/Repositories/wayfinder-data`, addons Wayward_Data and
Wayward_Data_Questie) keeps the snapshot and the VMaNGOS lists for personal
use: its sources register the same ids (`questie`, `spells`) at the same or
higher priority, so installing it next to Wayward replaces the built-in
ones. The class spell table is generated there (`tools/build.py spells`) and
copied into `Wayward/Data/ClassSpells.lua`.

Wayward is MIT licensed (`LICENSE`, `## X-License: MIT`; the zip carries it
as `Wayward/LICENSE.txt`).

## Names

"Forever Wayfinder" (a quest companion for Forever) and "Wayfinder" (a
compass banner) already exist, which is why this addon is Wayward. Checked
2026-10-20: no addon called "Wayward" on CurseForge or WoWInterface. Create
the project page early to hold the name.

## Checklist

- [x] `LICENSE` file in the repository and `## X-License` in the TOC.
- [ ] `lua tests/wayward_smoke.lua` and `lua tests/smoke.lua` pass.
- [ ] `tools/package.sh`; install the zip (not the symlink) on a clean
      AddOns folder and log in: the welcome shows, `/ww` opens, no Lua errors
      with script errors on (`/console scriptErrors 1`).
- [ ] Same with QuestieDB installed: `/ww debug` lists "QuestieDB (baked),
      Class spells" and the Quests tab searches. Then with the private
      companion too: its sources replace the built-in ones.
- [ ] Walk one trip end to end in the beta (flight, boat, quest pickup and
      hand-in), and one with TomTom installed.
- [ ] Screenshots: the For you cards, the directions box, the quick menu.
- [ ] CurseForge project: game version Forever, category Quests & Leveling,
      description from the README's first three sections, QuestieDB named
      as the optional dependency.
- [ ] Tag `v0.4.0` on the branch that ships; merge to `main` (empty today).

## Audit, 2026-10-20

A read-only pass over every file for performance, client compatibility
(retail 12.x API with the Midnight restrictions), error safety and locale.
Fixed in this release:

- `DATA_CHANGED` went out on every NPC window, every trainer click, every
  flight map and every durability tick, and each one cleared every cache and
  rebuilt For you at once, in combat too. Now an NPC fires it only when
  something about them changed, a trainer list is read once, flight maps
  only when a path or continent is new, durability only when it crosses the
  repair lines, and the panel refreshes once per burst and never in combat.
- The flight network no longer rebuilds for unrelated NPCs; flight-master
  and visited-goods lookups are built once instead of per flight path or
  per item tooltip; `QUEST_LOG_UPDATE` (every kill) no longer throws away
  the per-version quest lists; Notable only reacts to item info it asked for.
- The For you background check got stuck for the session after a level-up
  in combat (a flag was reused); fixed and tested.
- Timer callbacks, the 10 Hz directions update and the unit tooltip hook now
  report errors instead of spamming or breaking Blizzard code; a trip saved
  by an older version that fails to resume is dropped instead of failing
  every login; an empty continent list isn't cached forever.
- `C_Item.GetItemCount` and `C_SpellBook.IsSpellKnown` are tried before
  the deprecated globals; `GetProfessions` falls back to skill lines when it
  returns nothing; the `Wayfinder` alias no longer overwrites another
  addon's global.
- On non-English clients a weapon master could be recorded as your class
  trainer and overwrite your class spell list; a service-count guard stops
  that.

Left for later (low impact): the directions box re-anchors and re-sets its
text every tick (cheap in practice); the journey overview's drag OnUpdate
is only cleared on drag stop; `readService` calls `GetTrainerServiceInfo`
twice per row.

## Known limits to say on the listing

- English client for data-source trainers, vendors and weapon masters.
- Shipped docks and entrances are approximate until recorded in Forever.
- Without QuestieDB: trainers, vendors and flight masters you have
  visited plus every class's spell list; no quest search, hubs or item
  sources.
- The in-world marker's height is the game's guess (addons get no height).
- Flight paths are learned per continent (open a flight map once on each).
