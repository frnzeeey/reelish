# Watch Party

Friends watch one title together: anyone signed in hosts or joins
with an 8-digit code, and every player follows the room. The protocol, the
sync thresholds and the room's limits are in
[the backend README](../backend/README.md#watch-party); this page covers how
the pieces fit, the reliability rules, and the social features.

| Piece | Where |
|---|---|
| Room (authority, one per code) | `backend/src/party-room.ts` (Durable Object, WebSocket Hibernation) |
| Routes: create, preview, socket, invitation page | `backend/src/watch-party.ts` |
| Connection, reconnects, clock, actions, chat | `lib/src/watch_party/watch_party_controller.dart` |
| Sync arithmetic (pure Dart) | `lib/src/watch_party/playback_sync.dart` |
| One player in step with the room | `lib/src/watch_party/party_player_sync.dart` |
| Invitation links | `lib/src/watch_party/party_links.dart`, `ReelishActivity.kt`, `windows/runner` |
| Waiting room, join, create | `lib/src/screens/watch_party/` |
| Reactions and chat | `lib/src/widgets/watch_party/party_chat_panel.dart`, `lib/src/widgets/player/party_activity.dart` |

## Audit (November 2026)

| Feature | Before | Now |
|---|---|---|
| Numeric codes | Working: uniform 8-digit codes without modulo bias, collisions retried, unknown and malformed codes answered alike, 20 lookups a minute per account and per IP, removals enforced by the room | Unchanged |
| Host-controlled sync | Working: room authority, sequence numbers, stale and duplicate states dropped, echo suppression, seek-cost lead, back-off, hold. One flaw: every repeat of a held seek key was its own control, which could close the host's socket (4029) and made every guest seek again | Actions coalesced; a device's own pending action is never overwritten by an older timeline |
| Reconnection | Working: backoff, fresh token, last offline action resent. Gaps: a seek made offline while paused was sent too far on; a host whose network died without closing stayed "connected", so guests reconnected every ~35 s and the host was never replaced; such sockets held places | Fixed; presence via text pings and a room sweep |
| Reactions | Missing | Relayed, never stored, own limit |
| Chat | Missing | Relayed, never stored, author set by the room, own limit |
| Invitation links | A copied message with the code | A link (web page → `reelish://party/{code}`) on Android and Windows; the code everywhere |
| Free hosting (late November 2026) | Hosting was a supporter perk | Open to everyone; a 12-rooms-an-hour quota per account and a D1 code index keep guesses and ended rooms from waking a Durable Object ([backend README](../backend/README.md#watch-party)) |

## Reliability rules

- **The room decides.** Only the host (or anyone, with *Everyone can play
  and pause*) can change the timeline; the room checks it, numbers every
  change, and every player drops anything older than what it has.
- **Remote commands are not viewer actions.** The player applies the room
  through `PartyPlayerHandle` (`remotePlay`, `remoteSeek`…), never through
  its own buttons, so nothing is echoed back.
- **Actions are paced.** At most one reaches the room every 800 ms: the first
  at once, the last of the rest when the interval ends. A held key still
  moves this player every press.
- **One's own action wins until it comes back.** Until the room answers with
  a timeline made by this device (or 3 s pass, for a refused one), no older
  timeline is applied and the host sends no heartbeat.
- **Offline, the last action waits.** It is sent on reconnecting, moved on by
  the time that passed only if playback kept running (a play, or a seek while
  playing).
- **Presence.** A text `ping` every 25 s (answered by Cloudflare without
  waking the room); the room closes sockets whose pings stopped for 2 minutes,
  checking every 2 minutes while anyone is connected and on every join. A
  host found gone gets the usual 60-second grace, then the longest-connected
  guest hosts. A device that comes back after that rejoins as a guest.
- **Leaving never ends the room for others.** Leaving hands host on; only
  *End party* ends it, and an empty room ends 30 minutes later.

## Reactions and chat

Both are optional and need a room that lists them in `welcome.features`
(older rooms do not, and then nothing is shown).

- **Reactions:** six emoji, sent at most every 700 ms from the app; the room
  relays 4 at once then 1 a second per person and drops the rest without a
  reply. Shown rising over the video for 2.6 s (held still under reduced
  motion), and as a line in the chat panel.
- **Chat:** single lines up to 300 characters, cleaned of control and
  direction characters, sent at most every 1.5 s; the room relays 5 at once
  then 1 every 2 s and answers more with `chat_rate_limited`. A line appears
  when the room relays it, so every device shows the room's order. The room
  stores nothing; this device keeps the last 100 lines for as long as it is in
  the party, across reconnects. Someone who joins later sees only what comes
  after.
- **Where:** the waiting room (a section on phone and TV, a card on Windows)
  and the player (the chat button in the top bar opens a player sheet; a dot
  shows unread lines; a new line shows under the party badge for 5 s while the
  chat is closed). On TV, typing uses the TV's own entry dialog.

## Invitation links

*Copy invitation* shares `https://<Reelish API>/api/v1/join/{code}` and the
code. The page is fixed: it never asks the room, so it reveals nothing about
which codes exist. Its button opens `reelish://party/{code}`:

- **Android (phone, tablet, TV):** an intent filter on `ReelishActivity`.
- **Windows:** the installer registers the per-user `reelish:` protocol. If
  Reelish is already open, a second launch hands the link to that window
  (`WM_COPYDATA`) and exits.
- **Not installed:** nothing opens; the page shows the code to type later.

Reelish then opens *Join a party* with the code filled in. The room is looked
up as for a typed code, and joining waits for the viewer. A link that arrives
before anyone is signed in on Android or Windows is kept until Home opens; one
that arrives while Reelish is on the sign-in screen is not.

## Cost (Cloudflare Workers Free plan)

No new service, table or binding. Per room, compared with before:

| | Change |
|---|---|
| Storage writes | Down when a key is held (one control per 800 ms instead of one per key repeat). Up by one alarm write every 2 minutes while anyone is connected |
| Room wake-ups | Up by one alarm every 2 minutes while connected (at most 360 over a 12-hour room). Text pings are answered without waking the room |
| WebSocket messages | Reactions and chat, bounded by the per-person limits above; nothing is stored |
| Worker requests | One per invitation page view (rate-limited per IP) |

The playing room's 10-second host heartbeat is still the largest cost, as
before. The Free plan's daily request and duration limits are shared by
every room; when they run out, room calls answer 503 `party_unavailable` and
ordinary watching is unaffected. Nothing here makes heavy use free.

## Tests

`watch_party_reliability_test` (pacing, own-action wait, offline seek,
refused actions, heartbeats, presence pings, pongs, reconnect on 4008,
reactions, chat, link parsing, the waiting room's chat, the player layer, a
link opening Join a party), `watch_party_test` (the existing controller, sync
and screen tests), `backend/test/watch-party.test.ts` (features, reactions,
chat cleaning and limits, the sweep handing over a vanished host, presence
alarms, the invitation page).

Not covered automatically: several real devices on different networks, a
real Android or Windows link launch, TV remote focus in the chat panel, and
Cloudflare's own timing for closing dead connections.
