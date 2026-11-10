# Changelog

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
- **Journeys you control**: skip a stop or do it later, and Wayward
  re-plans as you go. The + on the directions box opens **On the way**:
  quests, vendors and detours you could add near your journey.
- **Gathering as you go**: what your quests need you to collect along the
  way, nearest first.
- **Class trainer, Vendors, Quests, Items and Find**: where to train, repair,
  restock, pick up a quest or find an item, with directions there.
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
