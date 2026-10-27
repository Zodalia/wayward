# Wayward

The design pillars, vocabulary and rework plan live in
[docs/DESIGN.md](docs/DESIGN.md). Read its Pillars section before changing
anything a player sees or does.

## Challenge changes against the pillars

The owner wants pushback, not just compliance. Before implementing a change
that affects player-facing behaviour, UI, copy, ranking or journey planning,
check it against the five pillars:

1. **Direction, not prescription**: does it suggest and explain, or does it
   grade, nag or push the player back onto a route?
2. **Guidance on demand**: is the extra information opt-in (hover, click,
   "+"), or is it forced on screen?
3. **Adventure over optimisation**: does it make XP per minute (or any single
   number) the sort key or the headline?
4. **Respect the journey**: does it cut friction, or does it reduce the world
   to waypoints and skip the place, quest or story?
5. **Player-owned progress**: can the player still reorder, add, drop, set
   aside and resume, with Wayward re-planning around them?

When a request strains a pillar:

- Say so before writing code: name the pillar, describe the concrete way the
  change works against it, and offer at least one alternative that gets the
  same goal without the cost.
- Ask whether to proceed as asked, take the alternative, or drop it. Don't
  silently water the request down, and don't refuse it: the owner decides.
- If two pillars pull against each other, say which one you'd let win and
  why. Once decided, record that in the commit message, as DESIGN.md asks.
- Also flag vocabulary drift (trip, leg, errand, waypoint, recommendation...)
  against the Vocabulary table in DESIGN.md.

Keep it proportionate: bug fixes, refactors, tests and tooling that don't
change what the player experiences need no pillar review. One or two
sentences is enough for a minor concern; save the full challenge for changes
that genuinely cut against a pillar. If a change clearly fits the pillars,
don't narrate the check.

## Before committing

Run all three, as DESIGN.md requires:

```bash
lua tests/wayward_smoke.lua
WAYWARD_GAME=era lua tests/wayward_smoke.lua
python3 -I tools/lua51.py tests/wayward_smoke.lua
```
