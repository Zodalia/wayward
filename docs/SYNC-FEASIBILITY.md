# Journey sync with friends and party: feasibility

Status: **technical investigation done, nothing built, player-facing design
not started.** Findings are from WoW Forever 1.60.1 (build 70938), tested in
game on 2026-11-16 with the WFProbe dev addon. Classic Era was not tested.

The idea: two or more players with Wayward installed connect, and their
journeys stay in step.

## Verdict

Feasible. Addon messages work solo, in a party, inside a dungeon and in
dungeon combat. A whole journey fits in one to three messages. The limits
below shape the design but don't block it.

## What was measured

| Question | Answer | How sure |
|---|---|---|
| Can addons send messages? | Yes: `C_ChatInfo.SendAddonMessage`, after `RegisterAddonMessagePrefix` | Tested |
| Which channels work? | `WHISPER` (to yourself) and `PARTY` both sent and echoed back | Tested, sender's side only |
| Round trip | About 0.3 s | Tested |
| Maximum message size | 255 bytes. Longer messages return `Success` and arrive **cut to 255** | Tested (256 and 1024) |
| Which bytes survive? | 1 to 250 arrive unchanged. 0 and 251 to 255 were not sent | Tested |
| Throttle in the open world | None seen at 25 messages in two seconds | Tested |
| Throttle inside an instance | About 10 messages, then about one a second. Refused sends return `AddonMessageThrottle` and are dropped | Budget inferred from two runs, not measured directly |
| Lockdown in a dungeon | `InChatMessagingLockdown` false, in and out of combat | Tested on a normal pull |
| Lockdown on a boss | Unknown. Retail ties `AddOnMessageLockdown` to encounters | **Not tested** |
| Does a bad target fail? | No. Whispers to a name nobody has still return `Success` | Tested |
| Encoding | `C_EncodingUtil` has CBOR, JSON, Deflate/Zlib/Gzip, Base64, Hex | Tested |
| Journey size | 12-stop sample: 627 bytes CBOR, 144 compressed, 192 as Base64 (JSON: 874 / 167 / 224) | Tested, round trip intact |
| Battle.net | `C_BattleNet.SendGameData` exists; account connected | **Not tested** |

`C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()` returned `true` in
every run, and nothing was restricted. Don't gate on it.

## Player names on Forever

Forever gives each character a second name.

- `UnitName("player")` and `UnitFullName("player")` return
  `"Maximillian", "Kirby"`: the second return is the second name, **not** a
  realm.
- `GetUnitName("player")` returns `"Maximillian Kirby"`.
- Whispers arrive when addressed to `"Maximillian Kirby"` or
  `"Maximillian-Kirby"`. The first name alone, or any form with the realm
  appended, is silently dropped.
- `CHAT_MSG_ADDON` gives the sender as `"Maximillian Kirby"`.

Use the name the client reports for the sender, and build whisper targets
from both parts. Whether the same holds for *another* player's name has not
been confirmed with a second client.

## Constraints the design must respect

1. **Chunk everything.** Split at 255 bytes with a sequence number and
   reassemble; never trust `Success` for size.
2. **Acknowledge everything.** `Success` only means the client accepted the
   send. The receiver has to reply, and no reply means not delivered.
3. **Queue and pace.** Keep bursts under 10 and the rest at about one a
   second; resend on `AddonMessageThrottle`; hold on `AddOnMessageLockdown`.
4. **Batch updates.** Sharing a journey is cheap. Broadcasting every small
   progress change to a five-person party is not.
5. **Encode as CBOR, Deflate, then Base64.** Compressed data contains zero
   bytes, which were not shown to survive.
6. **Version the payload.** Players will run different Wayward versions.

## What to send

`Journey.Save` and `Journey.Load` in `Wayward/Journey.lua` already turn a
journey into a plain table and back, so the payload exists. Related pieces:
`Journey.SyncQuestState`, the `root.manual` flag for a hand-ordered journey,
`Nav.AddToTrip`, `Nav.SetAside`.

Journeys are personal: quest state, class, level, faction, known flight
paths and hearth all differ between players. A received journey has to be
re-planned for the receiver, not copied stop for stop.

## Options, cheapest first

1. **Send a copy.** One player sends their journey; the other gets an offer
   to take it, re-planned for them. No ongoing link.
2. **Follow a leader.** Followers get the leader's changes as offers and can
   stop following at any time.
3. **A shared journey.** Everyone edits one journey. Needs conflict rules
   and much more traffic; the throttle makes this the expensive one.

## Pillars to settle before building (docs/DESIGN.md)

- **Player-owned progress (5).** A follower must still reorder, add, drop,
  set aside and resume. Sync that overwrites those choices breaks the pillar.
- **Direction, not prescription (1).** Incoming changes should arrive as
  offers that explain themselves, not as a route the player is put back on.
- **Guidance on demand (2).** The invitation and incoming changes need a
  quiet home; a prompt on every change would be forced on screen.

No vocabulary has been chosen for the feature. Check new terms against the
Vocabulary table in DESIGN.md.

## Still to verify

- A second client actually receiving, over party and over whisper.
- Size, byte and burst behaviour on the `PARTY` channel itself (the probe
  ran those over a whisper to self).
- The throttle's real budget and refill rate.
- A boss encounter, for `AddOnMessageLockdown`.
- Battle.net sending, for friends outside the party.
- Bytes 0 and 251 to 255.
- Classic Era.

## How to re-run the probes

WFProbe lives in `WFProbe/` and is linked into the Forever AddOns folder.

- `/wfprobe` runs the static probes: `comms.addonMessages` and
  `comms.encoding`.
- `/wfprobe comms [name]` sends the live test: pings to every name form and
  to the party, then sizes, bytes and a burst. Results are in
  `comms.sendTest`.
- `/wfprobe show` opens the report to copy.

The probe code is `WFProbe/PadComms.lua`; its harness is `tests/smoke.lua`.

## Next step

Player-facing design: how a connection is offered and accepted, what the
follower sees when the other journey changes, and how they diverge and come
back. Option 1 is the smallest thing that would be useful.
