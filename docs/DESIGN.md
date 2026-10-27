# Wayward design: pillars, vocabulary and the 0.5 rework

Written 2026-10-27 against version 0.4.0 (branch `feat/errand-stops`,
commit 454a8a0). This is the reference for the four work streams in
[Work streams](#work-streams); each stream reads this before touching code.

## Pillars

1. **Direction, not prescription.** Wayward helps players decide what to do,
   without dictating how they play. We suggest and explain; we never grade the
   player's choice or nag them back onto a route.
2. **Guidance on demand.** Provide the information and assistance players need,
   when they need it, at the level of detail they want. A glance gives the
   gist; a hover, a click or a "+" gives the next level down. Nothing is
   forced on screen.
3. **Adventure over optimisation.** Prioritise interesting, relevant
   experiences over numerical efficiency. XP per minute is one signal among
   several, never the sort key, and never the headline.
4. **Respect the journey.** Minimise unnecessary friction and travel without
   reducing Azeroth to a series of waypoints. Directions get you there; the
   place, the quest and the story are the point.
5. **Player-owned progress.** Journeys are flexible plans that adapt to the
   player's decisions, rather than fixed routes that must be followed. The
   player reorders, adds, drops, sets aside and resumes; Wayward re-plans
   around them.

When a change could serve one pillar at another's expense, say which pillar
wins and why in the commit message.

## Vocabulary

| Term | Meaning | Not this |
|---|---|---|
| **Journey** | The overall adventure or goal the player has chosen: "The Perfect Stout", "Quest in Redridge Mountains", "Run The Deadmines". One journey is active at a time. | trip, route, run |
| **Stop** | A meaningful objective or destination within a journey: pick up a quest, kill the boars, hand in, talk to the trainer, enter the dungeon, reach a zone. | leg, waypoint, objective (as a UI word) |
| **Step** | An individual instruction required to reach or complete a stop: "Walk to Lakeshire", "Fly to Stormwind", "Take the boat". The directions box shows the current step. | leg, hop |
| **Detour** | An optional stop inserted into an existing journey: a repair, a mailbox, a nearby pickup, a vendor on the way. The "+" on the directions box adds one. | errand, side trip, convenience stop |
| **Directions** | The plain A-to-B case with no journey: steps to one place. Starting a journey while on plain directions folds the destination into the journey as a stop. | trip |
| **Suggestion** | A possible journey on the home screen (a card). | recommendation, option |
| **Observation** | A small useful fact on the home screen (a "Good to know" tile), usually with a one-click action. | need, alert, nag |

### String mapping

Apply in every file a stream owns (code identifiers may stay; player-facing
strings, tooltips, README and comments that face the reader change):

| Today | Becomes |
|---|---|
| "Start trip", "New trip", "Add to trip", "In trip", "your trip", "You're on a trip" | "Start journey", "New journey", "Add to journey", "In journey", "your journey", "You're on a journey" |
| "Your trip" (the renamed merged journey) | "Your journey" |
| "Stop directions" (the HUD ×) | "End journey" on a journey, "Stop directions" on plain directions |
| "Skip this step" / "Move to the next step and do this later" (HUD; they act on the stop) | "Skip this stop" / "Do this stop later" |
| "Step %d of %d to get there" | unchanged (these are steps) |
| "Add a stop: repair, vendor, mailbox, bank..." | "Add a detour: repair, vendor, mailbox, bank..." |
| "On the way (3 min or less more)" | "Detours on the way (3 min or less)" |
| "See full journey" | "View details" (and the button in the Your Journey box) |
| "Journey complete!", "New journey available", "Up next" | unchanged |
| "Due now", "Worth a visit" (card categories) | gone as cards; these become observations |

`Nav.Stop()` (end navigation) keeps its name in code. Module names
(`ns.Errands`, `ErrandPicker`, `Nav.AddToTrip`) may stay for now; a
`Nav.AddDetour` alias is welcome, a mass rename is not (it churns every file).

## The home screen

Reference: the mockup `art/mockup-home-2026-10-27.webp` (the
layout is described here so it can be built without it).

```
+----------------------------------------------------------------------+---+
| [portrait] Level 8 · Dun Morogh            Time: [15][30][60][Any]   | ? |
|            A few good options from where you are.                    | $ |
+----------------------------------------------------------------------+ B |
| YOUR JOURNEY                                                         | K |
| [icon] The Perfect Stout                        [ route map        ] | S |
|        Stop 3 of 5 · Find Shimmerweed in Dun Morogh                  |   |
|        2 of 5 stops complete · ~6 min remaining                      |   |
|        [=========------]                                             |   |
|        A flexible plan you can continue, reorder or expand.          |   |
|        [Continue journey] [View details]                             |   |
+----------------------------------------------------------------------+   |
| SOMETHING TO DO NEXT                                                 |   |
| [QUESTING card] [EXPLORE card] [ALTERNATIVE card]   (page arrows)    |   |
|  title, why, meta row (nearby · level · time), [Start journey]       |   |
+----------------------------------------------------------------------+   |
| GOOD TO KNOW                                                         |   |
| [obs][obs][obs][obs]  text with highlights, [Add detour]/[Show]/[Go] |   |
+----------------------------------------------------------------------+---+
```

Three regions with distinct roles; they never compete on one ranking:

1. **Your journey** (`ns.Nav.active`): what the player chose. Title, the
   current *stop* ("Stop 3 of 5 · Find Shimmerweed in Dun Morogh"; the
   mockup says "Step 1 of 2" there, which is the old vocabulary and is
   wrong), stops done, time remaining, progress bar, a RouteMap of the rest
   of the journey, **Continue journey** (closes the panel and makes sure the
   directions box is showing the current step) and **View details** (opens
   the journey overview). With plain directions the box shows the
   destination and "Directions". With nothing active the region collapses to
   one line ("No journey on the go. Pick something below, or search with ?")
   so the suggestions move up.
2. **Something to do next** (`ForYou.Results()`): suggestions as cards, three
   per page, chosen by *role* (see [Relevance](#relevance)): a continuation,
   an exploration, an alternative. Each card: kind tag, title, one or two
   lines of *why* in plain words, a meta row of up to three facts (distance
   or "Nearby", level range, travel time or transport), **Start journey**.
   Hover for every detail, the stops and the route map, as today. Shift-click
   or, while a journey is active, the button offers **Add as detour** /
   **Switch journey** (keeps the current one set aside) / Cancel.
3. **Good to know** (`ForYou.Observations()`): up to four tiles. Each: icon,
   text with highlighted numbers, and at most one action: **Add detour**
   (`Nav.AddToTrip` of the observation's stop; starts a journey if none),
   **Show ...** (opens a side page), or **Go** (plain directions). Ordered
   by urgency, then usefulness. No time budget filtering.

The header keeps the summary line and the time buttons; the side tabs stay
(the mockup's "?" becomes the unified Find page, see
[One assistance system](#one-assistance-system-im-stuck)).

### Contracts between modules

So the streams can build in parallel:

- `ForYou.Results()` returns suggestion rows in today's shape (`id`, `kind`,
  `category`, `title`, `subtitle`/`place`, `stats`, `details`, `journey` or
  `goal`+`route`, `badge`, `icon`) **plus** `role` ("continue" | "explore" |
  "alternative" | nil), `why` (one plain sentence) and `relevance` (0..1,
  with `relevance_parts = {suitability=, proximity=, progression=, novelty=,
  intent=}` for `/ww debug cards`). Needs are no longer rows here.
- `ForYou.Observations()` returns a list of `{ id, kind, icon, text,
  highlights = {"81%", "level 10"}?, urgency = 0..1, action = { label,
  kind = "detour" | "show" | "go", stop? , page? , goal? , route? } }`,
  ordered. Cached and invalidated like `Results()`.
- `ns.Nav.active` is read as today for the Your Journey box; stream C adds
  `Nav.Progress()` → `{ done, total, seconds, stopIndex, stopText }` so the
  box and the HUD share one computation.
- The row/tooltip/activate helpers in `Panel.lua` (`Panel.ShowTooltip`,
  `Panel.Activate`, `Nav.StopsFor`) stay the single path for "go here" and
  "add this", for cards, tiles and side-panel rows alike.

Until the ForYou side lands, the UI treats a missing `ForYou.Observations`
as an empty list and a missing `role` as "alternative"; until the UI lands,
the extra fields are simply unread. Tests for the UI use synthetic rows, as
the existing "cards" section does.

## Relevance

Replace "best XP per minute" with a relevance score per suggestion, and pick
cards by role rather than by rank.

```
relevance = 0.30 suitability + 0.20 proximity + 0.20 progression
          + 0.15 novelty     + 0.15 intent            (each 0..1)
```

- **Suitability**: does it fit this character now. Level fit (1.0 from
  level-2 to level+2, falling to 0 at grey and at too-hard; Hardcore's
  stricter cutoff applies), class and race fit (already filters), group
  quests lower when solo, reward usefulness (Notable's armour/weapon
  reasoning), and XP worth it (XP for the time, normalised against the best
  option on offer, so XP still counts, as one fifth of one third).
- **Proximity**: travel time to the first stop. 1.0 within 2 minutes, 0.5
  at about 8, near 0 past 25; transports count as time, not distance. The
  time budget stays a hard filter on top.
- **Progression**: does it continue something under way. Quests in the log,
  a chain's next step, the zone you are questing in with quests left, a
  dungeon whose quests you hold, a profession at its cap, the next ability
  level coming up.
- **Novelty**: is it new or remarkable. A zone or dungeon you have not
  explored (map exploration or no recorded visit), a notable quest (class,
  epic, dungeon lead, new in Forever), a transport you have not used. A card
  shown on several refreshes and never started loses novelty slowly
  (`seenCards` gains a shown count); nothing is hidden for it.
- **Intent**: what the player has told us. The time budget, the kind of
  journey they start most (a small learned weight per kind in `charDB`),
  the zone of the active journey, and an explicit preference when they set
  one (none yet; leave the hook).

Roles for the three slots on a page: **continue** is the highest-relevance
suggestion whose progression part is the largest; **explore** the highest
whose novelty part is largest and that is in a different zone or of a
different kind than *continue*; **alternative** the highest remaining of yet
another kind. Later pages repeat the pattern over what is left. Every card's
`why` names its two strongest parts in words ("Picks up where your log left
off, 4 min away", "A zone you haven't seen, with 6 quests at your level").
`/ww debug cards` prints the parts.

What stays: all candidate providers (zones, dungeons, hand-ins, finishes,
best quest, Don't miss, professions), the time budget, the learned
per-quest time, the hiding of cards already on the journey. What goes:
`rank` "#N of M by XP per minute" text, the fixed category order, the
needs-as-cards (they become observations: repairs, ammo, food, training,
flight paths, repair-soon, hand-in-ready, new abilities at the next even
level, vendors nearby, full bags).

## The journey model

Keep `Journey.Plan`, `orderStops`, `manualOrder`, `Extend`, `Replan`,
`Save`/`Load` and the detour (errand) picker as they are: they already make
journeys flexible. Add what the pillars need:

- **Stop kinds a journey can hold**, beyond quest phases, talk, train and
  item: `explore {mapID}` (done when the zone is entered or a subzone in it
  is discovered), `enter {dungeon}` (today's `finish` "Enter X" becomes an
  ordinary stop kind so a dungeon can sit in the middle of a journey),
  `learn {spells}` for class training (done on `TRAINER_SHOW` + spells
  learned, replacing plain directions for the training card). `finish` stays
  for compatibility but new code uses stop kinds.
- **A journey carries a `kind` and an `icon`** (`def.kind` = "quest" |
  "zone" | "dungeon" | "hand-in" | "finish" | "profession" | "custom"...) so
  the Your Journey box and the fanfare can show it.
- **Set aside and resume**: `Nav.SetAside()` saves the active journey def
  (with done flags) into `charDB.journeys[]` and ends navigation;
  `Nav.ResumeSetAside(i)` re-plans it from here. The "Switch journey" choice
  on the home screen uses it, so starting something new never loses the
  current plan. The journey overview lists set-aside journeys under the
  active one with Resume and Forget.
- **Detail on demand** (pillar 2): the directions box gains a detail
  setting, "steps" (today) or "stops" (show only the current stop and the
  compass; steps on hover). Per character, in Options and `/ww detail`.
- **`Nav.Progress()`** as in the contract above; `Nav.AddDetour` as an
  alias of `Nav.AddToTrip`.
- The vocabulary pass over Navigator, HUD, JourneyOverview, ErrandPicker,
  Errands, OnTheWay, Fanfare, Options strings and README.

## One assistance system ("I'm stuck")

Today quest, item, trainer and vendor lookup are four pages with four
matching routines and four result shapes. Make them one **Find** system with
four views:

- **One index and one matcher** (`Wayward/Search.lua`): `ns.Search.Find(text)
  → {kind, id, name, score}` over quests, items, NPCs (by name and by role:
  trainer, vendor, flight master, innkeeper...), dungeons, zones and
  subzones, class spells and professions. Exact, prefix, substring, then
  shorter names; link parsing (`|Hquest:`, `|Hitem:`, `|Hspell:`, `#id`) in
  one place. Quests page and Items page use it instead of `FindQuests` /
  `buildNameIndex`.
- **One result shape** (the Panel row contract) and **one set of actions**:
  every result has directions or a journey, and the same buttons:
  "Directions" / "Start journey", "Add as detour" while a journey is on,
  and details on hover (then "+" to unfold the steps). Item sources, quest
  phases, trainer rows and vendor rows all come out as rows of this shape.
  The duplicated quest logic in `ItemsPage.lua` (`questStatus`,
  `questFinisher`, `dungeonJourney`) moves to `Quests.lua` / `QuestsPage`
  and is called from both.
- **One entry**: `/ww find <text>` (with `/ww quest` and `/ww item` kept
  as aliases that pre-select a kind), a **Find** side tab (the "?" in the
  mockup, first tab) whose search box searches everything and whose
  category chips are All / Quests / Items / People / Places; the existing
  Quests, Vendors, Trainers, Dungeons tabs stay as browse views of the same
  system (no text = browse what's relevant now, as today).
- **Where am I stuck?** With no text, the Find page lists likely questions
  for the current situation: the current stop's NPC or objective, quests in
  the log with unfinished objectives ("Where do I find Shimmerweed?"),
  "Where is my class trainer?", "Nearest repair". Each is a row like any
  other.
- The tooltip lines on items and quests become actionable: "Wayward: /ww
  find" and, where the client allows, a click target.

## Work streams

Four streams, one session each, all branched from `feat/pillars` (this
document's branch, which is `feat/errand-stops` plus this file). Each owns
the files listed; a stream that needs a change in another stream's file
writes down the change it needs in its PR description instead of making it,
unless it is a one-line string from the mapping above.

| Stream | Owns | Done when |
|---|---|---|
| **A. Relevance** | `Wayward/ForYou.lua`, `QuestTimes.lua`, `Notable.lua` (scoring only), `Dungeons.lua` (ranking only), the "for you", "warm-up", "notable quests", "for you: quest log", "for you: time budget", "fanfare" test sections | `Results()` carries `role`, `why`, `relevance`; needs come from `Observations()`; cards chosen by role; `/ww debug cards` prints parts; README "For you" rewritten |
| **B. Home screen** | `Wayward/UI/Panel.lua`, `UI/Cards.lua`, new `UI/JourneyBox.lua`, new `UI/Observations.lua`, `UI/RouteMap.lua` (reuse), `UI/Profile.lua`, the "cards", "side panel", "panel scrolling", "route map" test sections | The three regions render from the contracts, with synthetic data in tests; window resized to fit; Start journey while active offers detour / switch / cancel; README "For you" layout paragraphs |
| **C. Journey model** | `Wayward/Journey.lua`, `Navigator.lua`, `Errands.lua`, `OnTheWay.lua`, `UI/HUD.lua`, `UI/JourneyOverview.lua`, `UI/ErrandPicker.lua`, `UI/Fanfare.lua`, `UI/Options.lua`, `UI/Welcome.lua`, `Sounds.lua` strings, the "trips", "on the way", "errands", "adding to a trip", "reordering a trip", "move on and skip", "trip polish", "journeys + pages" test sections | New stop kinds plan and complete; set aside / resume; `Nav.Progress()`; detail setting; vocabulary pass done in its files and README |
| **D. Find** | new `Wayward/Search.lua`, new `Wayward/Find.lua`, `QuestsPage.lua`, `ItemsPage.lua`, `Quests.lua` (lookup helpers), `Trainers.lua`, `Vendors.lua`, `Professions.lua`, `QuestHubs.lua`, `Core.lua` (commands), the "quests page", "items page", "professions", "vendors", "trainers", "data sources" test sections | `ns.Search.Find` serves every page; Find page registered (`ns.RegisterPage`, order 5, searchable) with the situation list; one row shape and action set; ItemsPage duplicates removed; README "Items"/"Quests" sections updated |

Rules for every stream:

- Run `lua tests/wayward_smoke.lua`, `WAYWARD_GAME=era lua
  tests/wayward_smoke.lua` and `python3 -I tools/lua51.py
  tests/wayward_smoke.lua` before each commit; all three pass on the base.
- New checks go in a new section appended at the **end** of
  `tests/wayward_smoke.lua`, headed `-- ===== <stream>: ... =====`, so
  merges conflict only at the file end. Edit existing checks only where the
  behaviour they assert is what you changed.
- Don't regenerate `docs/copy.md` (it is regenerated once at integration).
- Small, regular commits on the stream's branch; conventional prefixes as in
  the log (`feat(foryou):`, `feat(journey):`...). No co-author lines.
- Nothing here is verified in game. Say so in the PR; list what to try.

Integration order, after all four: C, A, B, D onto `feat/pillars`, then
`tools/extract_copy.py`, then one in-game pass on Forever and on Era.
