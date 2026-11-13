# Friends & Activity: current architecture audit

Phase 0. What Reelish already has that a social layer can reuse, what it
does not have, and where each kind of data lives today. Verified in the
code on 2026-11-13 (branch `playback-audit-phase-1`, commit `a96434c`).

## Summary

| Question | Answer |
|---|---|
| Is a backend needed? | Yes. Friendships, recommendations and shared activity involve two accounts and must be enforced by a server. |
| Is Firebase configured for data? | No. Firebase runs only Analytics and Crashlytics, through the Android SDK and the app's own method channels (CLAUDE.md, `docs/features/analytics.md`). There is no Firestore, no Firebase Auth, no FCM, and no FlutterFire. |
| Is there an existing authenticated backend? | Yes: the **Reelish API**, a Cloudflare Worker with D1 (`backend/`), deployed to staging and production. |
| Recommendation | Build on the Reelish API + D1. No new service, no new SDK. |

## Source of truth by data type

| Data | Source of truth | Where | Notes |
|---|---|---|---|
| Account identity | Trakt account → `users` row | D1 `users` (`trakt_uuid`, `trakt_username`, `trakt_avatar_url`) | Sign-in is Trakt only (device code or browser PKCE). `AccountGate` means there is no guest state. |
| Sessions | Reelish API | D1 `sessions`; app `AccountController`, `SessionStore` | Short access tokens, rotating refresh tokens; every route uses `authenticate` + `requireLiveSession`. |
| Display name, chosen avatar, photo | The device | `ProfileController`, SharedPreferences `{userId: {displayName, avatar, preset, photo}}` | **Never uploaded.** A photo never leaves the device (privacy policy says so). |
| Trakt username and avatar | Trakt, cached in D1 | `backend/src/profile.ts`, re-read daily | Public on Trakt, but Reelish has never shown it to other users. |
| Badges, frames, entitlements | Reelish API | `badges.ts`, `frames.ts`, `entitlements.ts` | Identity only; nothing gates on a badge. |
| My list (favourites and watchlist) | The device | `StorageService.favorites()`, `onfeed.favorites` | One list. Per device, not per account. Optional sync with the Trakt watchlist (`WatchlistSync`, `backend/src/trakt-sync.ts`). |
| Watch history, Continue watching | The device, per account, synced | `StorageService` per-account keys; D1 `playback_progress` via `ProgressSync` | Server-ordered sync, deployed to staging. |
| Custom collections and folders | The device, per account, synced | `CollectionStore`; D1 `collection_records` via `CollectionSync` | One row per folder, collection and title. Body rebuilt from checked fields. No visibility field yet. |
| Recommendations (personalised discovery) | The device | `lib/src/discovery/` | On-device only; unrelated to friend recommendations. |
| Watch Party | Durable Object per 8-digit code | `backend/src/party-room.ts`, `lib/src/watch_party/` | Only social feature today. Joining needs a code; hosting is a supporter perk. |
| Notifications | The device | `episode_alerts.dart` (`flutter_local_notifications`, WorkManager on Android) | Local notifications only. The background check uses a narrow `rnt_` alert token. **No push.** |
| Bug reports and feedback | Reelish API | D1 `support_reports`, `support.ts` | 5 a day per account; reporter stored as a hash. Could carry a "report a user" kind. |
| Rate limiting | Workers Rate Limiting bindings | `wrangler.toml`: `AUTH`, `TMDB_USER`, `TMDB_IP`, `SYNC`, `PARTY` | A `SOCIAL_LIMITER` binding costs nothing extra. |
| TMDB metadata | Reelish API TMDB gateway, app cache | `backend/src/tmdb/`, `TmdbService` | Allowlisted routes. It shares the Worker request quota with everything else. |

## Reusable pieces

- **Authentication and sessions**: `authenticate`, `requireLiveSession`,
  401 versus 409 semantics, and `AccountController.accessToken()` refresh in
  the app. No second auth system.
- **Account deletion** is `DELETE /me`, with `ON DELETE CASCADE` from
  `users`. Every new table references `users(id)` the same way.
- **Validation and response helpers**: `readJsonBody` with byte limits,
  `shortText`, `ApiError`, `json`, and the audit log
  (`audit.ts`, ids only).
- **The sync pattern** (`ProgressSync`, `CollectionSync`): outbox, retries
  with backoff, pull on start and return, lifecycle hooks. Social reads are
  simpler (fetch on open), but failed sends can reuse the outbox idea.
- **Collections**: records already sync per account. Friends' collections
  need a visibility field and a read route, not a second store.
- **Card snapshots**: progress and collections already carry title, year
  and TMDB artwork URLs (checked against the `image.tmdb.org` pattern), so
  a receiving device needs no TMDB request. Recommendations and activity can
  do the same.
- **Playback hook point**: `CustomVideoPlayer` already reports positions to
  `StorageService` and has a lifecycle listener. A one-way, fire-and-forget
  "now watching" notice can sit beside it without touching engines or
  sources.
- **UI**: `ProfileScreen` (phone, TV, Windows), `TvFocusable`, the
  `CollectionActions` dialog patterns, `DesktopPageHeader`, `AppPageRoute`,
  and the Library collection pages.
- **Reporting**: `support_reports` can take a `user_report` kind, bounded
  the same way.

## Missing infrastructure

| Needed | Status |
|---|---|
| A handle other people can find | None. The Trakt username exists, but showing it is a privacy decision (see the requirements doc). |
| A profile other people can see | None. Display name and avatar are device-local by design. |
| Friend requests, friendships, blocks | None. |
| Privacy settings stored server-side | None. |
| Friend recommendations | None. |
| Shared "now watching" | None. |
| Collection visibility | None. All collections are private (they sync only within the account). |
| Push notifications | None. Adding FCM would be a new SDK and Firebase product; out of scope (in-app indicators instead). |

## Platform navigation today

| Interface | Navigation | Where Friends could live |
|---|---|---|
| Phone | `SoftGlassDock` tabs: Home, Library, Plugins, Settings; Profile from the avatar | Profile → Friends, plus a details-page *Share* action |
| TV | `TvDestination` rail (Profile first) | Profile page section; a new rail entry would need a page on TV **and** Windows |
| Windows | `DesktopShell` sidebar (same `TvDestination`) | Same as TV |

A new `TvDestination` value is exhaustive in `home_screen.dart` and appears
on both the TV rail and the Windows sidebar, so it needs a page for each.

## Risks found in the audit

- **Identity exposure.** The only cross-account identifier today is the
  Trakt username. Using it as the friend handle would link Reelish activity
  to a public Trakt profile without asking.
- **Device-local profile.** Friends would otherwise see a Trakt username
  and nothing the user chose. Uploading a display name must be opt-in and
  bounded.
- **Shared Worker quota.** The Workers free plan's daily request allowance
  is shared with the TMDB gateway, progress sync and collection sync.
  Social traffic must stay small and on demand.
- **"Collection" naming.** Plugins already call provider repositories
  "collections", so the social UI should say "shared collections" or
  similar.
- **My list is per device.** Recommendations should not write into My list
  automatically; the inbox is the place.
