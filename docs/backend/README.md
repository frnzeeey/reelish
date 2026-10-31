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
| `GET /api/v1/me` | Bearer | `{user, traktLinked, sessionId}` |
| `DELETE /api/v1/me` | Bearer | Revoke Trakt access, delete the account and its sessions |
| `GET /api/v1/trakt/watchlist` | Bearer | `{items: [{type, tmdbId, listedAt}]}` (`movie` or `series`) |
| `POST /api/v1/trakt/watchlist` | Bearer | `{add, remove}` (≤ 100 `{type, tmdbId}` each) → `{added, removed, notFound}`; 409 `trakt_limit` or `trakt_reauth_required` |
| `POST /api/v1/notifications/token` | Bearer | `{token}`: an episode-check token for this session (replaces the previous one) |
| `POST /api/v1/notifications/episodes` | Alert token | `{series: [tmdbId] (≤ 150), popular}` → each series' `lastEpisode`, and TMDB's popular series when asked |
| `GET /api/v1/sessions` | Bearer | The account's signed-in devices |
| `DELETE /api/v1/sessions/{id}` | Bearer | End one of the account's own sessions |
| `GET /api/v1/tmdb/{tmdb path}` | Bearer | Allowlisted TMDB v3 request (below) |
| `POST /api/v1/party` | Bearer | `{content, settings?, profile?}` → `201 {code, expiresAt, settings}`; ends the caller's previous party |
| `GET /api/v1/party/{code}` | Bearer | `{code, phase, content, host, participants, capacity}`; 404 `party_not_found` |
| `GET /api/v1/party/{code}/socket` | Bearer | WebSocket upgrade into the room (below); 409 `party_full`, 403 `party_removed` |

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

### TMDB gateway

The app's `TmdbService` keeps its own cache, deduplication, concurrency
limit and retries; only its base URL and authentication changed. The
gateway accepts exactly these requests (paths relative to TMDB v3):

| Path | Parameters | Edge cache |
|---|---|---|
| `/movie/popular`, `/tv/popular`, `/trending/all/day` | `page` | 20 min |
| `/discover/movie` | `page`, `sort_by`, vote and release-date filters, `with_release_type`, `region` | 20 min |
| `/discover/tv` | `page`, `sort_by`, vote and air-date filters, `with_type`, `without_genres` | 20 min |
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
| `audit_events` | Security events by id (sign-in, logout, reuse, deletion) | Reelish |

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
| Cross-account access | Every account route filters by the token's user id; foreign ids answer 404 | — |
| Secrets in logs | Logs carry paths, statuses and ids only; no query strings, tokens or codes | — |
| Supply chain | Zero runtime dependencies in the Worker; pinned dev tools; lockfile; CI audit | Advisories in local dev tooling (miniflare, wrangler) |

## Tests

`cd backend && npm test` runs the Worker in workerd with a local D1
(`@cloudflare/vitest-pool-workers`); Trakt and TMDB are faked at the fetch
layer. The app's side is covered by `test/account_test.dart`, plus the
TMDB service tests, which now pass a session token instead of a key.
