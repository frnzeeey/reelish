# Friends & Activity: implementation plan

Each phase ends with tests, a staging deployment where the backend changed,
an updated `IMPLEMENTATION_PROGRESS.md` and `TESTING_REPORT.md`, and a stop
for review. Production is deployed only when the owner says so.

The order differs from the brief: recommendations and shared collections
come **before** activity, because they are useful when no friend is watching
anything (owner's note). Activity is last, and can be dropped without
affecting the rest.

| Phase | Delivers | Backend | App |
|---|---|---|---|
| **0** | Audit and plan (this) | — | — |
| **1. Foundation** | Social profile on/off, handle, friend code, privacy settings, relationship check, rate limits, Friends off and account deletion | Migration `0013`, `social/profiles.ts`, `SOCIAL_LIMITER`, cron pruning, tests for every privacy rule | `SocialApi`, `SocialController`; *Friends & privacy* page (phone, TV, Windows); privacy policy draft |
| **2. Friends** | Find by code or handle, requests, accept, decline, cancel, remove, block, unblock, report | `social/friends.ts`, user-report kind in `support.ts` | Friends page with tabs (friends, requests), friend profile page, summary dot; TV: code entry with the on-screen keyboard |
| **3. Recommendations** | Share from details pages, inbox, read and remove, sent list | `social/recommendations.ts`, counters, idempotency | *Share with friends* dialog on three details pages; inbox in Friends; outbox for retries |
| **4. Shared collections** | Collection visibility (Private / Friends), a friend's shared collections | Visibility column, `CollectionSync` route accepts it, `social/shared-collections.ts` | Visibility in the collection's options and creation dialog with a clear indicator; friend's collections on their profile page, reusing the collection grid pages read-only |
| **5. Watching now** | Optional activity sharing with expiry | `social/activity.ts`, expiry and cron | `ActivityPublisher` hooked into `CustomVideoPlayer` (asynchronous, inert when off); *Watching now* section on the Friends page |
| **6. Polish and platforms** | Loading, empty, offline and error states everywhere; TV focus order; Windows keyboard and hover; accessibility labels | — | Widget tests per interface (`TargetPlatformVariant`, `DeviceCapabilities.debugOverride`) |
| **7. Final audit** | Security review of every route, direct-request tests, cost review against real staging numbers, deployment guide | Review | Review |

## Files (expected)

Backend: `backend/migrations/0013_social.sql`, `backend/src/social/*.ts`,
`backend/test/social-*.test.ts`, `backend/src/index.ts` (routes),
`backend/wrangler.toml` (`SOCIAL_LIMITER`), `docs/backend/README.md`.

App: lib/src/social/ (planned) (api, controller, models, activity publisher),
lib/src/screens/social/ (planned), lib/src/screens/tv/tv_social.dart (planned),
lib/src/desktop/desktop_social.dart (planned), lib/src/widgets/social/ (planned), and small
changes to the three details pages (*Share* button), `ProfileScreen`
(entry), `collection_models.dart` / `collection_store.dart` /
`collection_sync.dart` (visibility), `custom_video_player.dart` (one
nullable hook, Phase 5 only), `legal_information_screen.dart`,
`help_content.dart`.

No new dependencies are expected.

## Decisions needing approval before Phase 1

| # | Decision | Recommendation |
|---|---|---|
| D1 | Backend | Reelish API + D1, not Firebase |
| D2 | What friends see | A Reelish handle the user picks, plus an optional display name and preset avatar; the Trakt username is never shown |
| D3 | Discovery | Friend code (on) and exact handle (off by default); no search lists |
| D4 | Collection visibility | Private / Friends in this project; *Public* links later |
| D5 | Phase order | Recommendations and collections before activity |
| D6 | Card snapshots | Store title, year and TMDB poster with recommendations and activity (no TMDB requests to show them), as collections do |
| D7 | Notifications | In-app indicators only; no push |
| D8 | Activity during Watch Party | Not published (the party is already shared) |
| D9 | Navigation | Friends inside Profile on all three interfaces, plus *Share* on details pages; no new dock tab or rail entry |
| D10 | Recommendations after unfriending | Kept by the recipient; removed after a block |
