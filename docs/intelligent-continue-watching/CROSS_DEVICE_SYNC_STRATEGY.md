# Cross-device sync: strategy

**Status:** implemented (Phase B). Server: `backend/src/progress.ts`,
migration `0011_playback_progress.sql`. App: `ProgressSync`
(`lib/src/account/progress_sync.dart`), `StorageService.applySynced`.

## Where it runs

| Option | Verdict |
|---|---|
| Firebase / Firestore | Not used. The app has no Firestore or Firebase Auth; Firebase runs only through the Android SDK after analytics or crash-report consent, and FlutterFire would build the C++ SDK into Windows (ruled out in CLAUDE.md). |
| Trakt playback progress (`/scrobble`, `/sync/playback`) | Not used. Percent-only, writes to the user's Trakt history, bound by Trakt rate limits, and the app holds no Trakt token (the Worker does). |
| **Reelish API (Cloudflare Worker + D1)** | **Used.** Already authenticates every request to a Reelish account, runs per-user routes, and stays on the free plan. No new service. |

## Source of truth

| Data | Source of truth |
|---|---|
| Position while playing on this device | The local store (Phase A). Playback never waits on the network. |
| Latest position across devices | The Reelish API's `playback_progress` row, chosen by the ordering below |
| Trakt watch history | Trakt; Reelish does not write to it (decided: not now; a later opt-in) |
| Completion | Derived from position/length with the same 90 % rule on every device |

## Data on the server

One row per account and title (`PRIMARY KEY (user_id, media_key)`):

| Key | Holds |
|---|---|
| `movie:<tmdb>` | Position, length, removal flag, card (title, year, TMDB poster/backdrop) |
| `series:<tmdb>` | The series' place in Continue watching: its history entry's position, removal flag, card |
| `episode:<tmdb>:<season>:<episode>` | That episode's position and length, and the next episode once it is watched |

Plus the ordering fields: `device_id` (random per app install and account,
never a hardware id), `seq`, `client_at`, and `changed_at` (server time of
the last accepted change, the pull cursor).

The card travels with the row so a device that never played a title can
show it in Continue watching without TMDB requests (which would spend the
shared Worker quota). Artwork must be an `https://image.tmdb.org/t/p/…`
URL; the server rejects anything else and the app checks again on receipt
(`SyncedProgress.artwork`).

## Routes

- `POST /api/v1/progress` `{device, changes}`: at most 50 changes, 32 KB.
  Every field is validated (key pattern, whole milliseconds within a day,
  `next` only on episodes, text lengths, artwork host). The batch is one D1
  batch of conditional upserts. Answers `{accepted, serverTime}`.
- `GET /api/v1/progress?since=<cursor>`: rows with `changed_at >= cursor`,
  oldest first, 200 a page, with `{cursor, more, serverTime}`. Rows from
  the cursor's own millisecond come again; applying them twice is harmless.

Both sit behind `authenticate`, `requireLiveSession` and `SYNC_LIMITER`
(30 a minute per account). `user_id` is always the session's, never the
body's: one account cannot read or write another's rows, and that is
enforced in SQL on the server, not filtered in Flutter.

## Conflict resolution

The server keeps, per title, the newest change (the `WHERE` of the upsert
in `progress.ts`):

1. **Same device:** the higher `seq` wins. Each device counts its own
   changes, so a repeated or reordered request is dropped whatever the
   device's clock does.
2. **Different devices:** the later `client_at` wins. `client_at` is the
   time the change was *made*, on the device's clock corrected by its
   measured offset from the server (`serverTime` in every response,
   compared with the request's send/receive midpoint). The server clamps it
   to its own time, so a clock running ahead cannot make a change newer
   than the moment it arrives.
3. **Tie:** the larger `device_id` wins, so every device reaches the same
   result.

Why the time of the change and not the server's first sight of it: a
device that was offline uploads late, and "first seen" would make its old
position win. Why not the largest position: rewinding or starting over on
the newer device must be respected.

Example (brief scenario 4): Android plays 25:00 offline at 20:00, Windows
plays 31:00 at 20:05 and syncs. Android reconnects at 21:00 and uploads
25:00 stamped 20:00: rejected. Its pull then brings 31:00.

Removal ("Remove from history") is a change with `removed: true` under the
same rule, so it reaches other devices; playing the title again later
brings it back. A restore (Undo) is a new change and outranks the removal.

Limitation: a device's clock is corrected only once it has reached the
server; a change made offline before its first contact is clamped to its
upload time.

## On the device (`ProgressSync`)

**Local first.** Saves happen exactly as in Phase A; `StorageService` then
tells `ProgressSync` the key and time (`onProgressChanged`). Each saved
movie position and episode position carries its save time
(`MediaItem.progressAt`, `EpisodeProgress.at`), so the newest value is
known without a separate log.

**Outbox.** Per account in `onfeed.progressSync.v1`:
`{userId: {device, seq, cursor, offset, seeded, outbox: {key: at}}}`. One
entry per title, so a title saved 400 times waits once (no duplicate
writes). The outbox is written when a title first waits, not on every
15-second checkpoint; the position itself is read from local storage when
sent, so it is always the latest.

**When it talks to the API.**

| Trigger | Request |
|---|---|
| Sign-in or app start (account restored) | Pull, then push |
| No save for 30 s (playback paused or closed) | Push |
| Saves for 15 min without a pause (a long film) | Push |
| App hidden (background, screen off, minimised) | Push |
| App shown again, last pull over 2 min ago | Pull, then push |
| Failure | Retry after 30 s, doubling to 30 min, 8 times; then on the next trigger |

A 401 refreshes the token once (as watchlist sync does). Network errors
never touch local progress.

**Applying pulled rows** (`StorageService.applySynced`, in the write
queue): a row replaces local data only when its time (converted to this
device's clock) is newer than the local value's; a title still waiting in
the outbox with a newer local change is skipped (it is pushed next). Rows
this device sent are skipped. An episode becomes the series' "watched last"
when it is the newest episode change. Applied rows are not reported back to
sync or to personalised discovery. Home and the Library re-read the history
when `ProgressSync.revision` changes.

**First sync of an account on a device** (`seeded`): everything already
held is queued. Progress from before sync has no save time and goes with
time 0: it fills titles the server does not have and never replaces
another device's progress. The pull runs before the push, so remote
progress lands first.

**Accounts.** Sync follows `AccountController`; history is per account
(Phase A). A change saved while the account is switching waits in *its*
account's outbox for that account's next sign-in, never sent with another
account's token.

## Free-tier budget

Cloudflare free plan (check current limits before relying on this):
Workers 100,000 requests/day for the whole account, D1 5 M rows read and
100 k rows written per day.

| Per active user per day (typical) | Requests | D1 rows written |
|---|---|---|
| App start / return: pull (~3) | 3 | 0 |
| Viewing sessions: push after each (~3), plus 15-min pushes in long films (~4) | ~7 | ~2 per push (movie or series + episode) |
| **Total** | **~10** | **~15** |

A push of an unchanged title writes nothing (the upsert's `WHERE` rejects
it). A device's first sync uploads what it holds once, 50 titles a request.
The Worker request quota is shared with the TMDB gateway and is the
binding limit: about 10 requests per user means sync alone would use the
whole quota at about 10,000 daily active users. Measure the TMDB gateway's
current share in the Worker analytics before a wide release; if the margin
is thin, raise the 15-minute push interval or drop the pull on return to
the app.
