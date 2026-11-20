# Changelog

## 0.4.0 beta 3

- **Follow the party leader** (new, a first take): the party leader can lead
  the party's journeys (`/ww lead`), and party members can follow their
  directions (`/ww follow`). While you follow, your own journey is set
  aside, and you get it back when you stop. Quests a follower picks up are
  offered to the leader's journey, even ones the leader can't take.
- **Quests over two camps** (prototype): when one camp shouldn't drop enough
  of what a quest needs, the journey gives it two stops, Progress at one camp
  and Continue at another. Drop chances come from pfQuest. Staying for the
  respawn in a camp that looks cleared is up to you.
- **Controllers** (Forever): every Wayward window works with the game's
  controller cursor. Lists scroll with the d-pad and right stick, and B closes.
  A key binding (Key Bindings > AddOns > Wayward) moves the cursor to the
  directions box.
- **On the way** is a pane of its own, showing what's around where you
  stand. Its rows say "+ Add", and you wave one off from its "...".
- **Directions box**: "Stop 3 of 5" under the title, and the time to that
  stop.
- **Journey overview**: walk through the stops one step at a time, with the
  map following. The stop you're on is lit, and Do later is in its menu.
- The window fits smaller screens. Notes, toasts and the banner share one
  close button, one time bar and labelled buttons. List rows are wider, each
  with a labelled button.
- Fixes: the route shows on OpenMap's seamless world map; no more blocked
  action errors with a controller at login; "in the area" means among the
  spawns, not a field away.

## 0.4.0 beta 2

The first public beta. Wayward is a levelling helper for WoW Forever and
Classic Era (Season of Discovery and Hardcore too) that works like a map app,
not a guide: it suggests what's worth doing near you and gives step-by-step
directions there. Explore as you like.

- **For you**: the home screen. The journey you're on, suggestions for what
  to do next, where to quest, and good-to-know notes, for your level and
  where you are. `/ww` or the minimap button opens it.
- **Directions** on foot, by flight path, boat, zeppelin, tram and portal,
  with a compass in the directions box. Walks between zones go through the
  gates, passes and tunnels, not over the mountains.
- **Journeys you control**: skip a stop or do it later, pin, move or remove
  stops in the journey overview, and Wayward re-plans as you go. Set a
  journey aside and resume it when you like. **+ On the way** on the
  directions box offers quests, vendors and detours you could add near your
  journey.
- **Gathering as you go**: what your quests need you to collect along the
  way, nearest first.
- **Find, Quests, Vendors, Trainers, Dungeons and Items**: a page each on
  the window's rail. Where to train, repair, restock, pick up a quest or
  find an item, with directions there. Quests done inside a dungeon join a
  journey as one stop.
- Learns flight paths, trainers and vendors as you meet them. Optional:
  install QuestieDB for quests, items and every trainer. TomTom's arrow is
  supported.

Known limits:

- English client for trainers, vendors and weapon masters from data
  sources; directions work on any locale.
- Boat and zeppelin docks and dungeon entrances are approximate until
  recorded in Forever (`/ww dock`, or walk into the dungeon).
- Classic Era, Season of Discovery and Hardcore are not yet tried in game.
  There's no map pin there; the directions box and TomTom show the way.
- Without QuestieDB: trainers, vendors and flight masters you've visited plus
  every class's spell list; no quest search, quest hubs or item sources.
- Flight paths are learned per continent: open a flight map once on each.
