# Reelish API

The Reelish API is a Cloudflare Worker (`backend/`) that does three things
the app cannot do safely on a user's device:

1. **Signs users in with Trakt.** Trakt is the only account system; there
   are no Reelish passwords.
2. **Issues Reelish sessions.** A Trakt sign-in becomes a Reelish session
   that the app sends with every request.
3. **Holds the TMDB credential.** The app reaches TMDB only through an
   allowlisted gateway; no TMDB key ships in any build.

Operations (setup, secrets, deploy, rotation, incidents) are in
[operations.md](operations.md).

## Architecture

```
Reelish app ──HTTPS──▶ Cloudflare Worker  /api/v1
 (Android, TV,           ├─ /auth/*   Trakt device sign-in, sessions ──▶ api.trakt.tv
  Windows)               ├─ /tmdb/*   allowlist → edge cache → TMDB   ──▶ api.themoviedb.org
                         └─ D1 (SQLite): users, sessions, encrypted Trakt tokens, audit
```

| Concern | Where | Notes |
|---|---|---|
| Routing, rate limits, error shape | `backend/src/index.ts` | Every failure becomes `{error:{code,message,requestId}}` |
| Reelish sessions | `backend/src/sessions.ts` | Signed access tokens, rotating refresh tokens |
| Trakt OAuth and token custody | `backend/src/trakt.ts` | Device flow, identity, encrypted tokens, refresh |
| Account routes | `backend/src/auth.ts` | Sign-in, refresh, logout, sessions, deletion |
| TMDB allowlist | `backend/src/tmdb/allowlist.ts` | Mirrors `lib/src/services/tmdb_service.dart` |
| TMDB gateway | `backend/src/tmdb/gateway.ts` | Cache, dedup, retries, timeout, size cap |
| Crypto helpers | `backend/src/crypto.ts` | Web Crypto only: HMAC-SHA256, AES-256-GCM, SHA-256 |
| Watch party routes | `backend/src/watch-party.ts` | Create, preview by code, open the room's WebSocket |
| Watch party room | `backend/src/party-room.ts` | One SQLite-backed Durable Object per code: playback authority, participants, expiry |
| Schema | `backend/migrations/0001_init.sql` | |
| App: account state | `lib/src/account/account_controller.dart` | Restore, refresh, sign-in, sign-out |
| App: API client | `lib/src/account/account_api.dart` | Typed errors, timeouts |
| App: session storage | `lib/src/account/session_store.dart` | `flutter_secure_storage` (Keystore / DPAPI) |
| App: API address | `lib/src/account/backend_config.dart` | `--dart-define=REELISH_API_URL` |
| App: sign-in UI | `lib/src/screens/sign_in_screen.dart` | `AccountGate` in front of Home |
| App: Account settings | `lib/src/screens/account_settings_screen.dart` | Phone, TV and Windows Settings |

## Decisions

**Cloudflare Workers + D1, not Supabase or Firebase.** One vendor, one
deploy, one set of secrets, and no database connection limits to manage
from a serverless runtime. D1 holds a few small tables. Supabase Auth and
Firebase Auth were not used: Trakt is the identity, and a second identity
system would only duplicate it.

**Browser sign-in on phone and Windows, a code on TV.** Phones and
Windows open Trakt's authorization page (authorization-code flow with
PKCE S256; Trakt keeps a client-supplied `code_challenge`, checked
2026-10-30). The redirect URI is the Worker's own HTTPS callback, not the
app, so there is no custom URL scheme or loopback listener to intercept
and the Trakt code never reaches the device. The callback exchanges the
code with the client secret and the verifier, which never leave the
server; the app learns the outcome by polling with its own token, as in
the device flow. TV uses the device flow (a code entered at trakt.tv on
another device), which is also every platform's fallback and the whole
flow wherever `PUBLIC_URL` is unset.

**Sign-in is required.** Every TMDB request needs a Reelish session (the
product decision for this release). Data kept on the device (My list,
history, plugins) is unaffected by signing in or out.

**Signed access tokens, opaque refresh tokens.** Access tokens are
HMAC-signed, carry only the session and user ids, and last 15 minutes, so
catalog requests need no database read. Refresh tokens are random, stored
only as SHA-256 hashes, last 30 days from last use, and rotate on every
refresh. A rotated token presented again revokes its session (theft
detection). Consequence: a revoked session's access token keeps working for
at most 15 minutes on catalog routes; account routes check the session row.

**Trakt tokens stay on the server.** Exchanging and refreshing Trakt tokens
needs the client secret, and Trakt access tokens now last 24 hours, so the
server refreshes them. They are AES-256-GCM encrypted with associated data
binding each value to its user and field. Trakt returns a new refresh token
on each refresh, so refreshes use optimistic locking on a row version.
Each grant records the redirect URI it was issued for (the callback for
browser sign-ins, out-of-band for device sign-ins), and refreshing names
it; grants saved before that was recorded try the callback, then
out-of-band. The watchlist routes use `traktAccessToken()`; history sync
and scrobbling will too.

**Watchlist ↔ My list, merged by the app.** The API only reads and edits
the Trakt watchlist (by TMDB id). The app, when the user turns sync on,
merges three ways against the state after its last sync: changes on
either side since then reach the other, and a first sync (or the first
after turning it back on) only combines the two lists. Titles Trakt
cannot find, or that have no TMDB id, are left alone on My list. A lost
Trakt grant answers 409, never 401, so the app is not signed out.

**Stable identity.** Users are keyed by Trakt's account UUID
(`/users/settings` → `user.ids.uuid`), never by the username, which can
change. Sign-in fails closed if Trakt does not return the UUID.

## API (v1)

All bodies are JSON. Authenticated routes take `Authorization: Bearer
<accessToken>`. Every response carries `X-Request-Id` (the app may send
its own).

| Method and path | Auth | Purpose |
|---|---|---|
| `GET /health` | — | Liveness |
| `POST /api/v1/auth/device/start` | — | `{platform, deviceName}` → `{pollToken, userCode, verificationUrl, expiresIn, interval}` |
| `POST /api/v1/auth/device/poll` | — | `{pollToken}` → `202 {status:"pending", interval}` or `200 {status:"authorized", session, user}` |
| `POST /api/v1/auth/web/start` | — | `{platform, deviceName}` → `{pollToken, authorizeUrl, expiresIn, interval}`; 503 `web_sign_in_unavailable` without `PUBLIC_URL` |
| `GET /api/v1/auth/web/callback` | — | Trakt's redirect target (`code`, `state`); answers a fixed HTML page |
| `POST /api/v1/auth/web/poll` | — | As `device/poll`; also 502 `sign_in_failed` |
| `POST /api/v1/auth/refresh` | — | `{refreshToken}` → `{session}` (the old refresh token stops working) |
| `POST /api/v1/auth/logout` | Bearer | End this session |
| `POST /api/v1/auth/logout-all` | Bearer | End every session of the account |
| `DELETE /api/v1/me` | Bearer | Revoke Trakt access, delete the account and its sessions |
| `GET /api/v1/trakt/watchlist` | Bearer | `{items: [{type, tmdbId, listedAt}]}` (`movie` or `series`) |
| `POST /api/v1/webhooks/buymeacoffee` | Signature | Buy Me a Coffee events ([supporters](supporters.md)); 503 until configured |
| `GET /api/v1/me` | Bearer | `{user: {id, username, avatarUrl, profileCheckedAt, createdAt}, traktLinked, sessionId, badges}`; reads Trakt again when the profile is a day old ([Trakt profile](../features/trakt-profile.md)); `badges` holds `founder` and `supporter` ([badges](badges.md)); `frames` is `{equipped, available, collected}` ([avatar frames](frames.md)) |
| `PUT /api/v1/me/frame` | Bearer | `{frame: id | null}`: wears a frame, or none. 403 `supporter_required` or `founder_only`, 409 `frame_unavailable` for a closed limited edition, 400 `unknown_frame`; returns `{frames}` ([avatar frames](frames.md)) |
| `GET /api/v1/supporters/me` | Bearer | `{code, status, since, recognition, entitlement}`; `status` is `none`, `pending` or `verified` (the donation); `entitlement` is `free`, `supporter` or `founder` ([entitlements](entitlements.md)) |
| `POST /api/v1/supporters/claim` | Bearer | Asks for a review; shows as pending, grants nothing |
| `PUT /api/v1/supporters/recognition` | Bearer | `{listed, name}`; supporters only (409) |
| `GET /api/v1/supporters/public` | Bearer | `{supporters: [{name, since}]}`, opted-in only |
| `POST /api/v1/trakt/watchlist` | Bearer | `{add, remove}` (≤ 100 `{type, tmdbId}` each) → `{added, removed, notFound}`; 409 `trakt_limit` or `trakt_reauth_required` |
| `POST /api/v1/notifications/token` | Bearer | `{token}`: an episode-check token for this session (replaces the previous one) |
| `POST /api/v1/notifications/episodes` | Alert token | `{series: [tmdbId] (≤ 150), popular}` → each series' `lastEpisode`, and TMDB's popular series when asked |
| `GET /api/v1/sessions` | Bearer | The account's signed-in devices |
| `DELETE /api/v1/sessions/{id}` | Bearer | End one of the account's own sessions |
| `GET /api/v1/tmdb/{tmdb path}` | Bearer | Allowlisted TMDB v3 request (below) |
| `POST /api/v1/party` | Bearer | Supporters only (`403 supporter_required` otherwise). `{content, settings?, profile?}` → `201 {code, expiresAt, settings}`; ends the caller's previous party |
| `GET /api/v1/party/{code}` | Bearer | `{code, phase, content, host, participants, capacity}`; 404 `party_not_found` |
| `GET /api/v1/party/{code}/socket` | Bearer | WebSocket upgrade into the room (below); 409 `party_full`, 403 `party_removed` |
| `POST /api/v1/progress` | Bearer | `{device, changes}` (≤ 50 `{key, positionMs, durationMs, next?, removed?, title?, year?, poster?, backdrop?, seq, at}`, 32 KB) → `{accepted, serverTime}`; a change replaces a stored row only when newer ([sync strategy](../intelligent-continue-watching/CROSS_DEVICE_SYNC_STRATEGY.md), `src/progress.ts`) |
| `GET /api/v1/progress?since=` | Bearer | Rows changed at or after the cursor, oldest first, 200 a page → `{items, cursor, more, serverTime}` |
| `POST /api/v1/collections` | Bearer | `{device, changes}` (≤ 50 records `{kind, key, deleted?, seq, at, …fields}`, 64 KB): folders and collections by id, titles by `collectionId\|type:id`; a collection carries `visibility`: `"friends"` shares it, any other value is private, and none at all (older apps) keeps the stored value; stored in its own column; fields checked and the stored body rebuilt from them → `{accepted, serverTime}`; newer changes only ([collection sync](../custom-collections/COLLECTION_SYNC_STRATEGY.md), `src/collections.ts`) |
| `GET /api/v1/collections?since=` | Bearer | Records changed at or after the cursor, oldest first, 200 a page → `{items, cursor, more, serverTime}` |
| `GET /api/v1/discovery/preferences` | Bearer | The account's discovery preferences → `{stored: null \| {preferences: {onboarding, genres, personalization}, device, at}, serverTime}` (`src/discovery-preferences.ts`) |
| `PUT /api/v1/discovery/preferences` | Bearer | `{device, seq, at, preferences}` (`onboarding`: `completed`/`skipped`/null; `genres`: ≤ 40 TMDB genre ids; `personalization`: boolean; 4 KB); stored only when newer, ordered like progress → `{accepted, stored, serverTime}`, so a device that lost adopts the winner ([report](../discovery/DISCOVERY_IMPLEMENTATION_REPORT.md)) |
| `GET /api/v1/social/profile` | Bearer | Friends: the caller's own `{profile, counts}`: `counts` is `{friends, incoming, unread}`, `profile` is `{handle, friendCode, displayName, avatar, findByCode, findByHandle, allowRecommendations, shareActivity, handleChangeableAt, createdAt}`; or `{profile: null}` while Friends is off. Never another user's data ([Friends](../friends-activity/SECURITY_AND_PRIVACY.md), `src/social/profiles.ts`) |
| `PUT /api/v1/social/profile` | Bearer | Turns Friends on (`handle` required, `201`) or changes it; fields left out keep their value, `null` clears `displayName` or `avatar`. 400 `invalid_handle`, `handle_reserved`, `invalid_display_name` (links refused), `invalid_avatar`, `invalid_setting`; 409 `handle_taken` (also a handle held for 30 days after it was given up); 429 `handle_change_too_soon` (once a week), 429 `too_many_attempts` after 10 "taken" answers in an hour. Limited to 10 a minute per account and per address |
| `POST /api/v1/social/profile/code` | Bearer | A new friend code; the old one stops working. 409 `friends_off` |
| `DELETE /api/v1/social/profile` | Bearer | Turns Friends off: deletes the profile (handle held 30 days), friendships and requests both ways, blocks it made, its activity and received recommendations; its collections become private |
| `POST /api/v1/social/requests` | Bearer | `{code}` (case, spaces, dashes ignored) or `{handle}` (only if its owner allows it) → `201 {status:"requested", person}`, or `{status:"friends", person}` when they had asked first or already are. Unknown, hidden and blocked people all get the same 404 `not_found`; 400 `that_is_you`; 429 `request_limit` (20 a day), 409 `too_many_pending` (30 waiting), `friend_limit` (500). Limited to 10 a minute per account and per address (`src/social/friends.ts`) |
| `POST /api/v1/social/requests/{handle}/accept` | Bearer | Receiver only → `{status:"friends", person}`; anything else 404 |
| `POST /api/v1/social/requests/{handle}/decline` | Bearer | Receiver only; the sender is not told |
| `DELETE /api/v1/social/requests/{handle}` | Bearer | Sender only: withdraws the request |
| `GET /api/v1/social/friends?cursor=` | Bearer | Friends in handle order, 50 a page, `{friends, cursor}`; the first page adds `incoming`, `outgoing` (30 each, newest first) and `counts`. Each person is `{handle, displayName, avatar, since}`, never an account id |
| `GET /api/v1/social/friends/{handle}` | Bearer | `{friend, collections}` for a current friend; anyone else 404. `collections` lists only those the friend shares: `{id, name, description, count, posters}` (up to 4, the chosen cover first), at most 100 (`src/social/shared-collections.ts`) |
| `GET /api/v1/social/friends/{handle}/collections/{id}?cursor=` | Bearer | A shared collection of a current friend: `{items: [{type, id, title, year, poster, addedAt}], cursor}`, 200 a page; the first adds `collection`. 404 for a private, deleted or unknown collection and for anyone not a friend |
| `DELETE /api/v1/social/friends/{handle}` | Bearer | Ends the friendship for both |
| `GET /api/v1/social/blocks` | Bearer | `{blocked}`: people the caller blocked |
| `POST /api/v1/social/blocks` | Bearer | `{handle}` of a friend or a request either way (anyone else 404): ends the friendship, requests and recommendations both ways; all contact refused after |
| `DELETE /api/v1/social/blocks/{handle}` | Bearer | Unblock; nothing is restored |
| `POST /api/v1/social/reports` | Bearer | `{handle, reason, note?}` about a friend or a request either way; `reason` is `spam`, `harassment`, `impersonation`, `inappropriate` or `other`. Kept in `support_reports` (`kind = person`) with the reported account, the reporter as a hash; shares the 5-a-day report limit |
| `POST /api/v1/social/recommendations` | Bearer | `{recipients: [handle] (1–10), media: {type, id, title, year?, poster?}, message?, clientId}` → `{sent, notSent}` (201 when anything new was stored). Each recipient must be a friend who accepts recommendations, with no block either way; everyone else is in `notSent`, all alike. `poster` only `image.tmdb.org`; `message` ≤ 200, no links. The same `clientId` again sends nothing new; the same title to the same friend refreshes that card. 429 `recommendation_limit` after 50 recipients a day (`src/social/recommendations.ts`) |
| `GET /api/v1/social/recommendations?cursor=` | Bearer | Titles sent to me, newest first, 30 a page: `{items: [{id, from, media, message, createdAt, read}], cursor}`; the first page adds `unread`. `from` is null once the sender turned Friends off |
| `GET /api/v1/social/recommendations/sent` | Bearer | My last 30 sends `{items: [{id, to, media, message, createdAt}]}`; never whether they were read |
| `POST /api/v1/social/recommendations/read` | Bearer | `{ids?}` (≤ 100): marks mine read, all when no ids |
| `DELETE /api/v1/social/recommendations/{id}` | Bearer | The recipient removes one; anyone else 404 |
| `PUT /api/v1/social/activity` | Bearer | `{media: {type, id, title, poster?}, season?, episode?, remainingMs?}`: what I am watching; 409 `sharing_off` unless I share activity. One row per account (never a history); the server sets `expiresAt` = now + remaining + 10 min, kept between 15 min and 4 h (3 h without `remainingMs`); the same title and episode keeps its start (`src/social/activity.ts`) |
| `DELETE /api/v1/social/activity` | Bearer | I stopped watching |
| `GET /api/v1/social/activity` | Bearer | `{watching: [{person, media, season, episode, startedAt}]}`: friends who share activity, with an unexpired activity, latest first, at most 100 |
| `POST /api/v1/support/reports` | Bearer | `{kind, category, platform, title, description, steps?, diagnostics?}` (16 KB; `kind` is `bug` or `feedback`) → `201 {id, createdAt}`; a repeat within 10 minutes → `200 {id, duplicate: true}`; 429 `report_limit` after 5 a day per account (`backend/src/support.ts`) |

`session` is `{sessionId, accessToken, accessExpiresAt, refreshToken,
refreshExpiresAt}` (Unix seconds). `platform` is `android`, `android_tv`
or `windows`; `deviceName` is a generic label, not a device identifier.

Device sign-in errors: `sign_in_denied` (403), `sign_in_expired` (410),
`unknown_sign_in` (404). Session errors (401): `missing_token`,
`invalid_token`, `token_expired`, `invalid_refresh`, `refresh_conflict`,
`session_revoked`. Limits: `rate_limited` (429, `Retry-After`).

### Watch party

A room is a Durable Object named by its 8-digit code (Workers Free plan:
SQLite-backed only). Sockets use the Hibernation API; the app keeps them
alive with WebSocket protocol pings, which Cloudflare answers without
waking the room or counting a request (a text `ping` still gets `pong`).
Storage is written only when the room's state changes; host heartbeats
are kept in memory unless the host has drifted. Rooms end 30 minutes after the last
participant leaves (60 if nobody joined), and after 12 hours at most. A
host who disconnects keeps the room for 60 seconds; then the
longest-connected participant hosts. `PARTY_MAX_CAPACITY` (default 5) caps
every room. When a Free plan daily limit is spent, room calls fail with
503 `party_unavailable` and normal watching is unaffected.

Only supporters create rooms: `createParty` reads the account's donation
record (one D1 read, at creation only) and answers 403 `supporter_required`
otherwise. Anyone signed in can preview and join. A room carries on if its
host's support ends, and a handover (by the host, or after the grace above)
may pass it to anyone; neither extends its 12 hours.

The `content` is `{tmdbId, type: "movie"|"series", season, episode, title,
posterPath?}` (season and episode for series). Participants are named by
`pid`, a per-room hash of the account; account ids are never sent.

| Client → room | Who | Fields |
|---|---|---|
| `hello` | anyone | `name` (≤ 40), `avatar` (`avatar1`–`avatar8` or null) |
| `time` | anyone, ≤ 8 | `c` (client clock) → `time {c, s}` |
| `status` | anyone | `state`: `joined`, `loading`, `ready`, `playing`, `paused`, `buffering`, `unavailable`, `error` |
| `control` | host, or anyone with `guestControl` | `action`: `play`, `pause`, `seek`, `ended`; `positionMs`; `at` (server-time estimate) |
| `heartbeat` | host | `seq`, `positionMs`, `at` (while playing) |
| `start`, `content`, `settings`, `kick`, `transfer`, `end` | host | `content`; `guestControl`, `waitForAll`, `capacity`; `pid` |
| `leave` | anyone | (a leaving host hands over at once) |

The room sends `welcome {you, room, serverTime}`, `room {room}`, `state
{playback}`, `participants {participants, hostConnected}`, `time`, `error
{code}`, `removed` and `ended {reason}`. `playback` is `{status, positionMs,
rate, at, seq, by}`: the position was true at server time `at`, and `seq`
grows with every change. Close codes: 4000 ended, 4001 replaced by another
connection of the same account, 4003 removed, 4004 not found, 4029 too
many messages.

Clients follow the room in `PartyPlayerSync`, with the arithmetic in
`playback_sync.dart`. The room's timeline gives the expected position
(`positionMs + (serverNow - at) × rate`, using the clock offset from `time`
round trips), and each player compares itself with that:

| Gap to the room | What the player does |
|---|---|
| Up to 500 ms | Nothing |
| 500 ms to 3 s | Plays at 1.05x or 0.95x until within 150 ms |
| Behind by more than 3 s | Seeks, at most as often as `seekBackoffMs` allows (2 s doubling to 30 s), and nudges in between |
| Ahead by up to 15 s | Holds the frame until the room arrives |
| Ahead by more than 15 s | Seeks back |

A seek aims ahead of the room by `SeekCost`, the measured time seeks take on
that device and stream: aiming at where the room is now arrives that much
late, which on a slow stream repeats forever. A buffering player is never
sought unless the room has changed, because Media3 reports "not playing"
while it buffers and a second seek discards the buffer. A change from the room
overrides waiting and resets the back-off. While reconnecting nothing is
corrected, because the room as last seen may be out of date; the viewer's last
action is kept and sent on reconnecting. A player opens at the room's position
at that moment and does not start if the room is paused. Parties always play
at 1x, whatever the viewer's default speed. `[PartySync]` lines in debug and
profile logs summarize seeks, holds, drift, reconnects and delivery time. A
playing room silent for 35 seconds counts as a dead socket and reconnects.

### TMDB gateway

The app's `TmdbService` keeps its own cache, deduplication, concurrency
limit and retries; only its base URL and authentication changed. The
gateway accepts exactly these requests (paths relative to TMDB v3):

| Path | Parameters | Edge cache |
|---|---|---|
| `/movie/popular`, `/tv/popular`, `/trending/all/day` | `page` | 20 min |
| `/discover/movie` | `page`, `sort_by`, vote and release-date filters, `with_release_type`, `region`, `with_genres` | 20 min |
| `/discover/tv` | `page`, `sort_by`, vote and air-date filters, `with_type`, `with_genres`, `without_genres` | 20 min |
| `/genre/{movie,tv}/list` | — | 24 h |
| `/{movie,tv}/{id}` | `append_to_response=credits,external_ids` | 24 h |
| `/{movie,tv}/{id}/recommendations` | `page` | 20 min |
| `/{movie,tv}/{id}/images` | `include_image_language` | 24 h |
| `/tv/{id}/season/{n}` | — | 24 h |
| `/search/multi` | `query` (required), `page` | 3 min |
| `/find/{imdb id}` | `external_source=imdb_id` | 7 days |

`language` is accepted everywhere. Any other path, parameter, repeated
parameter or malformed value is refused (404 or 400) before TMDB is
contacted. Adding a TMDB request to the app means adding it to
`backend/src/tmdb/allowlist.ts` and its test, and deploying the API before
the app release.

Poster and backdrop images still load directly from `image.tmdb.org`,
which needs no credential.

## Data

| Table | Holds | Owner |
|---|---|---|
| `users` | Internal id, Trakt UUID, Trakt username (display) | Reelish |
| `trakt_credentials` | Encrypted Trakt access/refresh tokens, expiry, version, the grant's redirect URI | Reelish, on Trakt's behalf |
| `sessions` | Hashed refresh token, previous hash, platform, generic device label, timestamps | Reelish |
| `device_authorizations` | Pending sign-ins: hashed poll token, encrypted Trakt device code | Reelish (minutes) |
| `web_authorizations` | Pending browser sign-ins: hashed state and poll token, encrypted PKCE verifier, outcome | Reelish (minutes) |
| `playback_progress` | Per account and title (`movie:`, `series:`, `episode:` keys): position, length, next episode, removal, card title/year/TMDB artwork, device id (random), order fields; pruned after 400 days unchanged; deleted with the account | Reelish |
| `collection_records` | Per account and record (folder, collection, or title in a collection): the checked fields, deletion mark, device id (random), order fields; deletion marks pruned after 400 days, live records kept; deleted with the account | Reelish |
| `discovery_preferences` | One row per account: whether the genre step was completed or skipped, picked TMDB genre ids, personalised rows on/off, device id (random), order fields; deleted with the account. Viewing activity and feedback are not stored | Reelish |
| `audit_events` | Security events by id (sign-in, logout, reuse, deletion); erased after 12 months by the daily cron (`src/retention.ts`) | Reelish |

Trakt owns the user's profile, history and lists; Reelish stores none of
it. Watch history, My list and plugins stay in the app's local storage,
as before.

## Threat model

| Threat | Mitigation | Residual risk |
|---|---|---|
| TMDB key extracted from the app | No key in any build; Worker secret only | Old app versions still carry the old key until it is rotated |
| Gateway used as a free TMDB proxy | Sign-in required; per-user and per-IP limits; allowlist; edge cache | A real Trakt account can still use its quota (240 req/min) |
| TMDB rate limit hit by the Worker's shared IPs | Edge cache shared by all users; one upstream request per key | Cold-cache bursts after a deploy |
| Stolen access token | 15-minute lifetime, signature check, no user data inside | Usable until it expires |
| Stolen refresh token | Rotation with reuse detection revokes the session | The thief wins if they refresh before the owner and the owner never refreshes again |
| Stolen Trakt tokens (database leak) | AES-256-GCM with per-field associated data; key held as a secret | Database and key leaked together |
| Sign-in replay / CSRF | Poll tokens are random, hashed, single use; device code never leaves the server | — |
| Device-flow phishing (a code sent to a victim) | Trakt shows the app name on approval | Inherent to device flows |
| Browser sign-in: stolen or intercepted code | Redirect to the Worker only (Trakt checks registered URIs); PKCE verifier and client secret stay on the server; state single use, 10 minutes | — |
| Browser sign-in: a victim sent someone else's sign-in link | Trakt's consent page names the app; the link expires in 10 minutes | Same as device-flow phishing |
| Background task reusing a rotated refresh token (which revokes the session) | Background checks never refresh: they carry a per-session alert token (`rnt_…`, stored hashed) that opens only `/notifications/episodes` | The token reads public TMDB data until its session is revoked or expires |
| Callback page injection | Fixed pages, nothing from the request echoed; CSP `default-src 'none'`, no scripts, `no-referrer` | — |
| SSRF through the gateway | Fixed upstream host and HTTPS; regex-allowlisted paths; manual redirects | — |
| A token sent over plain HTTP (workers.dev answers HTTP too) | The app only builds `https://` addresses; the Worker refuses every non-HTTPS request with 403 `https_required` before routing, without a redirect | A token already sent in clear text should be treated as exposed: sign out that device |
| Two app copies sharing one sign-in on Windows (installed + portable, or a dev build) | — | Both rotate the same refresh token; the second use reads as reuse and revokes the session (by design) |
| Cross-account access | Every account route filters by the token's user id; foreign ids answer 404 | — |
| Secrets in logs | Logs carry paths, statuses and ids only; no query strings, tokens or codes | — |
| Supply chain | Zero runtime dependencies in the Worker; pinned dev tools; lockfile; CI audit | Advisories in local dev tooling (miniflare, wrangler) |

## Tests

`cd backend && npm test` runs the Worker in workerd with a local D1
(`@cloudflare/vitest-pool-workers`); Trakt and TMDB are faked at the fetch
layer. The app's side is covered by `test/account_test.dart`, plus the
TMDB service tests, which now pass a session token instead of a key.
