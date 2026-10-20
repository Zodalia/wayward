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

Recommendation: publish a second, public addon, **Wayward Data**, that
contains only the QuestieDB bridge (`Sources/QuestieLive.lua` +
`Questie.lua`) and the class spells source (`Sources/Spells.lua` +
`Generated/ClassSpells.lua`, from the private companion repository), with
the WhatsTraining licence file. The private companion keeps the snapshot and
the VMaNGOS lists for personal use. Then set `Data.ADDON` in
`Wayward/Sources.lua` to the published name (every hint in the addon uses
it) and link both addons from each other's listing.

Simpler for players: fold those two sources into Wayward itself (one
install, "install QuestieDB for quests"). The bridge is our code and the
spell table is Blizzard data plus MIT, so this keeps Wayward clean as well;
it only departs from the earlier "no QuestieDB calls in Wayward" split, which
was made before the consumer API's intended use was confirmed.

Either way, Wayward itself needs a licence file before it is public. MIT
matches the sources we build on (pfQuest, WhatsTraining) and is what most
addons use; the choice is the author's.

## Names

"Forever Wayfinder" (a quest companion for Forever) and "Wayfinder" (a
compass banner) already exist, which is why this addon is Wayward. Checked
2026-10-20: no addon called "Wayward" on CurseForge or WoWInterface. Create
the project page early to hold the name.

## Checklist

- [ ] `LICENSE` file in the repository and `## X-License` in the TOC.
- [ ] `lua tests/wayward_smoke.lua` and `lua tests/smoke.lua` pass.
- [ ] `tools/package.sh`; install the zip (not the symlink) on a clean
      AddOns folder and log in: the welcome shows, `/ww` opens, no Lua errors
      with script errors on (`/console scriptErrors 1`).
- [ ] Same with QuestieDB and the data addon installed: `/ww debug` lists the
      sources.
- [ ] Walk one trip end to end in the beta (flight, boat, quest pickup and
      hand-in), and one with TomTom installed.
- [ ] Screenshots: the For you cards, the directions box, the quick menu.
- [ ] CurseForge project: game version Forever, category Quests & Leveling,
      description from the README's first three sections, the data addon
      linked.
- [ ] Tag `v0.4.0` on the branch that ships; merge to `main` (empty today).

## Known limits to say on the listing

- English client for data-source trainers, vendors and weapon masters.
- Shipped docks and entrances are approximate until recorded in Forever.
- Without a data addon: trainers, vendors and flight masters you have
  visited; no quest search, hubs or item sources.
- The in-world marker's height is the game's guess (addons get no height).
- Flight paths are learned per continent (open a flight map once on each).
