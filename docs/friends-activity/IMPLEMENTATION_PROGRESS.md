# Friends & Activity: implementation progress

| Phase | State |
|---|---|
| 0. Audit and plan | Done; approved 2026-11-13 (decisions D1–D10 as recommended) |
| 1. Foundation | Done; on staging |
| 2. Friends | Done; on staging |
| 3. Recommendations | Done; on staging |
| 4. Shared collections | Done; on staging |
| 5. Watching now | Done; on staging |
| 6. Polish and platforms | Done (app only) |
| 7. Final audit | Done; fixes on staging, awaiting review |

## Phase 7 — final audit (2026-11-13)

The review, its findings and the cost check are in
[the final audit](FINAL_AUDIT.md); production steps are in
[the deployment guide](DEPLOYMENT_GUIDE.md).

| File | Change |
|---|---|
| `backend/src/index.ts` | `maskPath`: handles and record ids in Friends paths are masked in the request log |
| `backend/src/social/recommendations.ts` | The other person's name and avatar on a card only while still friends |
| `backend/src/social/profiles.ts` | Display names containing "reelish" are refused |
| `backend/test/social-audit.test.ts` | 7 tests: every route without and with an ended session, non-JSON bodies, log masking, ex-friend cards, names |
| `docs/friends-activity/FINAL_AUDIT.md`, `DEPLOYMENT_GUIDE.md` | New |
| `docs/friends-activity/SECURITY_AND_PRIVACY.md` | The three fixes in the threat model |

Staging: Worker version `4ce5c7be`. No app change in this phase.

### Follow-up: the fixable risks

| File | Change |
|---|---|
| `backend/src/social/profiles.ts` | 10 "taken" answers an hour per account (security log `social.handle_taken`), then 429 `too_many_attempts` |
| `backend/src/social/friends.ts`, `backend/src/auth.ts` | `forgetReportsAbout`: account deletion leaves reports about it with reason and date only |
| `backend/src/collections.ts` | A collection change without `visibility` keeps the stored value (column and pulled body) |
| `lib/src/account/collection_sync.dart` | Always sends `visibility` (`private` or `friends`) |
| `lib/src/social/activity_publisher.dart`, `lib/main.dart` | A publish is noted on the device (`reelish.activity.published.v1`) until cleared; `attach` at launch clears a leftover for the signed-in account |
| Tests | `social-audit` (+2), `social-shared-collections` (older app keeps sharing), `watching_now_test` (+3), `collection_sync_test` (explicit private) |

Staging: Worker version `36b7a3b2`. No migration.

## Phase 6 — polish and platforms (2026-11-13)

A pass over every Friends page on the three interfaces. The audit and its
outcome:

| Area | State before | Change |
|---|---|---|
| Loading, empty, offline, error | Every page already had them (Phases 1–5): spinner, saved copy with an offline note, *Try again*, empty-state text; share and add dialogs keep errors inline | None needed |
| Refresh | Only on opening a page | Phone: pull to refresh on Friends (a fresh read even within two minutes). All: returning to the app after two minutes or more reads again. Nothing polls |
| Screen readers | Person rows, shared collection rows and poster cards read as several fragments | Person rows without their own buttons, shared collection rows and poster cards each read as one item. Rows with Accept, Decline or Cancel keep those buttons separate. The Profile dot is spoken as "n friend requests, n new recommendations" |
| TV focus | Not tested end to end | Tested: Down goes through the left column (watching, recommended, add, requests and their Accept/Decline, sent); Right crosses to the friends list; Select opens a friend. No pull to refresh on a remote |
| Windows | Hover and keyboard come from the same rows as Settings; two columns from Phase 2 | None needed; covered by the Phase 2–4 Windows tests |
| Long names, large text | Untested | Tested on a 320-pixel phone at 200% text, a phone and a TV, with 40-character names, 20-character handles, long titles, a 200-character note and a 300-character description: nothing overflows on Friends, a friend's page, Recommendations or Friends & privacy |
| Light theme | Colours come from `GlassTheme` tokens throughout; the cover badge uses `artworkScrim` and `onArtwork` | None needed |

### App

| File | Change |
|---|---|
| `lib/src/screens/social/friends_screen.dart` | Pull to refresh (not where `usesTvLayout`), reload on return after `staleAfter` |
| `lib/src/widgets/social/social_widgets.dart` | `PersonTile` merges its semantics when it has no buttons of its own |
| `lib/src/screens/social/friend_collection_screen.dart` | Shared collection rows and poster cards merge their semantics |
| `test/friends_polish_test.dart` | 10 tests |

No backend change, so nothing deployed in this phase.

## Phase 5 — watching now (2026-11-13)

What a person can do: turn on *Share what I'm watching* in Friends &
privacy (off by default). While it is on, a title that starts playing (not
in a Watch Party) shows on friends' Friends page under *Watching now*, with
the season and episode for a series; it goes away shortly after the player
closes, or on its own if the app never says so. Opening a row goes to the
title.

### Server

| File | Change |
|---|---|
| `backend/src/social/activity.ts` | Publish (only with sharing on; one row per account, upserted; the same title and episode keeps its start), clear, and friends watching now (friends who share, unexpired, latest first, 100 at most). The expiry is the server's: remaining time from the device plus 10 minutes, between 15 minutes and 4 hours, 3 hours when unknown |
| `backend/src/social/recommendations.ts` | `parseMedia` exported (the same card checks) |
| `backend/src/index.ts` | `GET`/`PUT`/`DELETE /social/activity` |
| `backend/test/social-activity.test.ts` | 8 tests |
| `docs/backend/README.md` | The routes |

No migration: `current_activity` came with `0013`, turning sharing off
already deleted the row (Phase 1), and the cron already prunes expired rows.

### App

| File | Change |
|---|---|
| `lib/src/social/activity_publisher.dart` | `ActivityPublisher` and `ActivitySession`: a session exists only while sharing is on for a TMDB title; `playing` and `stopped` return at once; the latest state is sent at most once a minute; a repeat of what was sent is skipped; a stop clears after 20 seconds unless the next title starts (no flicker between episodes); any attempt counts as possibly published, so a clear always follows; every failure is dropped |
| `lib/src/widgets/player/custom_video_player.dart` | 20 added lines, nothing changed: the nullable `_activity` created beside the Watch Party hook (null in a party, D8), `playing` at the existing first-frame point with the remaining time, `stopped` in `dispose`. No engine, source, header, subtitle or audio code touched |
| `lib/src/social/friends_controller.dart` | `WatchingFriend`, `watching`, `loadWatching` (not saved: it is out of date within the hour) |
| `lib/src/screens/social/friends_screen.dart` | *Watching now* at the top of the Friends page |
| `lib/src/screens/social/friends_privacy_screen.dart` | The *Share what I'm watching* switch |
| `lib/src/account/account_api.dart` | Three calls |
| `lib/src/screens/legal_information_screen.dart` | What is sent, when, and how long it lasts |
| `test/watching_now_test.dart` | 10 tests |

### Deviations from the plan

- Episode changes inside one player are not published separately: the
  player opens a new session for the next episode, and the publisher turns
  the stop and start into a single update.
- Sign-out does not clear the activity itself: the player has already
  closed (and cleared) by then, and the expiry covers anything left.

### Deployed

- Staging: Worker version `dd3ee015`. No migration.
- Production: not touched.

## Phase 4 — shared collections (2026-11-13)

What a person can do: in a collection's options (phone, TV, Windows) choose
*Share with friends* while Friends is on, or *Make private* at any time. A
shared collection's cover carries a small people badge everywhere it shows.
On a friend's page, *Shared collections* lists what they share (cover,
name, number of titles, description); opening one shows its titles as
poster cards, read-only, each opening the title's details.

### Server

| File | Change |
|---|---|
| `backend/src/collections.ts` | A collection change may carry `visibility: "friends"`; anything else (and every older app, which sends nothing) is private, and folders, titles and deletions are always private. Stored in the `visibility` column (indexed reads) and in the body (so the owner's devices pull it) |
| `backend/src/social/shared-collections.ts` | `sharedCollectionsOf` (only `visibility = 'friends'` and not deleted; counts; up to four posters, the chosen cover first) and `GET /social/friends/{handle}/collections/{id}` (friend checked at that moment; titles read only through a shared collection, by key range, 200 a page) |
| `backend/src/social/friends.ts` | A friend's page adds `collections` |
| `backend/src/social/profiles.ts` | Friends off makes shared collections private as the server's own newer change (`device_id = 'reelish-server'`, `client_at` = now, visibility removed from the body), so every device of the account pulls it |
| `backend/src/index.ts` | The route |
| `backend/test/social-shared-collections.test.ts` | 8 tests |
| `docs/backend/README.md` | The route and the `visibility` field |

No migration: the column and its index came with `0013`.

### App

| File | Change |
|---|---|
| `lib/src/collections/collection_models.dart` | `MediaCollection.shared`, saved as `visibility: "friends"`; a copy without it reads private |
| `lib/src/collections/collection_store.dart` | `setShared`; synced records carry it |
| `lib/src/account/collection_sync.dart` | Sends and reads `visibility` |
| `lib/src/widgets/collections/collection_actions.dart` | *Share with friends* (while Friends is on) and *Make private* in the collection's options |
| `lib/src/widgets/collections/collection_cover.dart` | The shared badge (scrim and on-artwork colour from the theme), labelled for screen readers |
| `lib/src/screens/collections/collection_pages.dart`, `lib/src/screens/tv/tv_collections.dart`, `lib/src/desktop/desktop_collections.dart` | Each tile passes `shared` to the cover |
| `lib/src/social/friends_controller.dart` | `SharedCollection`, `sharedTitleFrom` (TMDB artwork only), `friend()` returns the page with collections, `sharedCollection()` |
| `lib/src/screens/social/friend_collection_screen.dart` | `SharedCollectionTile`, `FriendCollectionScreen` (poster cards sorted by name; "no longer shared" when the server says so; TV focuses the first title) |
| `lib/src/screens/social/friends_screen.dart` | *Shared collections* on a friend's page |
| `lib/src/account/account_api.dart` | `friendCollection` |
| `lib/src/screens/legal_information_screen.dart` | What a shared collection shows and what hides it |
| `test/shared_collections_test.dart` | 11 tests |
| `test/collection_sync_test.dart` | Sharing across devices, and the server's Friends-off change reaching them |

### Deviations from the plan

- Visibility is chosen in the collection's options, not also in the
  creation dialog: a new collection is empty, and sharing an empty one is
  rarely wanted. One menu entry covers the three interfaces.
- The friend's view is a poster grid of its own rather than the owner's
  collection pages reused read-only: those pages carry editing throughout
  (options, reorder, remove, cover), and a separate read-only page cannot
  offer them by mistake.

### Deployed

- Staging: Worker version `de7ff37f`. No migration.
- Production: not touched.

## Phase 3 — recommendations (2026-11-13)

What a person can do: on any title's details page (phone, TV, Windows),
press *Share*, tick up to ten friends, add a short note (not on TV) and send.
Friends see it at the top of their Friends page (the latest three, with a
dot while unopened) and on the *Recommendations* page, which also lists what
they sent; opening one goes to the title's details. Profile's Friends row
says "n new recommendations" with the dot.

### Server

| File | Change |
|---|---|
| `backend/src/social/recommendations.ts` | Send (each recipient checked at that moment: friend, accepts recommendations, no block; everyone else in one `notSent` list), inbox (newest first, 30 a page, `unread`), sent (never says whether read), mark read, remove. The card is checked field by field: TMDB id, title, year, `image.tmdb.org` artwork only; the note is 200 characters, no links, control and direction characters removed. `clientId` makes a retry send nothing new; the same title to the same friend refreshes that card. 50 recipients a day |
| `backend/src/social/profiles.ts` | `counts.unread`; `linkPattern` exported |
| `backend/src/collections.ts` | `artworkPattern` exported (same rule as collection cards) |
| `backend/src/index.ts` | The five routes |
| `backend/test/social-recommendations.test.ts` | 11 tests |
| `backend/test/social-friends.test.ts` | The counts now include `unread` |
| `docs/backend/README.md` | The routes |

No migration: the `recommendations` table came with `0013`. Its 180-day
pruning was already in the daily cron.

### App

| File | Change |
|---|---|
| `lib/src/account/account_api.dart` | Five calls |
| `lib/src/social/social_controller.dart` | `SocialCounts.unread` and `anyNew`, `setUnread` |
| `lib/src/social/recommendations_controller.dart` | `SocialTitles.open` (Home's details opener, as `PartyPlayerLauncher` is for parties), `cardOf` (the same checks as the server), `Recommendation`, `RecommendationsController`: inbox, paging, mark read (one or all), remove, send, `sentByMe`, a saved first page per account (`reelish.recommendations.v1.<userId>`), `forget` |
| `lib/src/widgets/social/share_dialog.dart` | *Share with friends*: friends to tick (up to 10), an optional note off TV, one key per share reused on retry, a one-line summary of who got it |
| `lib/src/widgets/social/social_widgets.dart` | `RecommendationTile` (poster, title, from or to, note, unread dot, Remove) |
| `lib/src/screens/social/friends_screen.dart` | *Recommended to you* section (latest 3), `RecommendationsScreen` (inbox, marks all read on open, *You sent*) |
| `lib/src/screens/social/friends_privacy_screen.dart` | Turning Friends off also forgets the saved inbox |
| `lib/src/screens/media_details_screen.dart`, `lib/src/screens/tv/tv_details_screen.dart`, `lib/src/desktop/desktop_details_screen.dart` | An optional `onShare` and its *Share* button beside *Collections*, in each page's own button style |
| `lib/src/screens/home_screen.dart` | Passes `onShare` only while Friends is on (as last known on the device), and sets `SocialTitles.open` |
| `lib/src/screens/profile_screen.dart` | The Friends row counts new recommendations; the dot covers both |
| `lib/src/screens/legal_information_screen.dart` | What a shared title sends and how long it is kept |
| `test/recommendations_test.dart` | 14 tests |
| `test/details_screens_test.dart` | Share on the three details pages, and none while Friends is off |

### Deviations from the plan

- No persistent outbox: a failed send keeps the dialog open with its key,
  and *Send* again reuses it, so a retry never sends twice. A send is never
  queued silently in the background, which matches "actions need a
  connection and say so".

### Deployed

- Staging: Worker version `e63f7cc0`. No migration.
- Production: not touched.

## Phase 2 — friends (2026-11-13)

What a person can do: add someone by friend code (typed any way) or exact
@handle when its owner allows it; see requests both ways and accept,
decline or cancel them; see their friends (handle order, 50 a page) and a
friend's page; remove, block and report; see and undo their blocks. Profile
shows a Friends row with the count and a dot for waiting requests.

### Server

| File | Change |
|---|---|
| `backend/src/social/friends.ts` | Send (code or handle; two people asking each other become friends inside one D1 batch), accept, decline, cancel, list (pages plus requests and counts), a friend's profile, remove, block (friendship, requests and recommendations both ways), list and remove blocks, report. People are named by handle; unknown, hidden and blocked people get one identical 404. Limits: 20 new requests a day, 30 waiting, 100 waiting for one person, 500 friends |
| `backend/src/social/profiles.ts` | `GET /social/profile` adds `counts` (friends, incoming) for the Profile dot |
| `backend/src/index.ts` | The routes; `POST /social/requests` also behind `SOCIAL_LOOKUP_LIMITER` (10 a minute per account and per address). Handles in paths are not URI-decoded (a handle never needs it, and a bad escape would have been a 500) |
| `backend/test/social-friends.test.ts` | 19 tests |
| `docs/backend/README.md` | The routes |

Reports about people use the existing `support_reports` table
(`kind = 'person'`, `category` = the reason, the reported account in
`diagnostics`), share its 5-a-day limit, its 180-day retention and its
deletion with the reporter's account. No migration in this phase.

### App

| File | Change |
|---|---|
| `lib/src/account/account_api.dart` | The eleven Friends calls |
| `lib/src/social/social_controller.dart` | `SocialCounts`, `counts`, `refreshIfStale` (at most every 2 minutes, never while Friends is known to be off), `adjustCounts`; 404 messages shown as the server wrote them |
| `lib/src/social/friends_controller.dart` | `SocialPerson`, `ReportReason`, `friendTarget` (code or handle), `FriendsController`: lists, paging, every action updating the lists and counts in place, a saved first page per account (`reelish.friends.v1.<userId>`), `forget` when Friends is turned off |
| `lib/src/widgets/social/social_widgets.dart` | `PersonAvatar` (preset or initial), `PersonTile`, Add friend (inline errors; TV text entry), Report (reason, optional note off TV, "Also block" on by default), a confirm dialog with the safe choice focused |
| `lib/src/screens/social/friends_screen.dart` | `FriendsScreen` (two columns on TV and Windows, stacked on phones), `FriendScreen`, `BlockedPeopleScreen` |
| `lib/src/screens/social/friends_privacy_screen.dart` | Turning Friends off forgets the saved list |
| `lib/src/screens/profile_screen.dart` | *Friends* row (count, "n requests" and a dot) above *Friends & privacy*; Profile refreshes the counts with `refreshIfStale` |
| `lib/src/screens/legal_information_screen.dart` | Friendships, requests, blocks and reports in the policy |
| `test/friends_test.dart` | 17 tests |
| `test/profile_layout_test.dart` | Reads the Account section's new first row |

### Deviations from the plan

- The planned `tv_social.dart` and `desktop_social.dart` were not needed:
  the Friends pages are one set of pages whose layout changes by interface
  (two columns where `usesTvLayout` and there is room), built from the same
  settings rows TV focus already works with.
- No summary route: the counts come with `GET /social/profile`, which the
  app already calls, so the dot costs no extra request.

### Deployed

- Staging: Worker version `82a3944a`. No migration.
- Production: not touched.

## Phase 1 — foundation (2026-11-13)

What a person can do: turn Friends on with a handle, see and copy their
friend code (or get a new one), choose the name and built-in avatar friends
see (or none), set who can find them and whether friends may send
recommendations, and turn Friends off, which deletes everything social.
Nobody can find or add anyone yet: lookups, requests and friend lists are
Phase 2.

### Server

| File | Change |
|---|---|
| `backend/migrations/0013_social.sql` | Every table in [the schema](DATABASE_SCHEMA.md), plus `released_handles` (the 30-day handle hold) and `collection_records.visibility` (`private` by default, checked) with its partial index |
| `backend/src/social/profiles.ts` | `GET`/`PUT`/`DELETE /social/profile`, `POST /social/profile/code`: handle rules (3–20, reserved names, case-insensitive uniqueness, the hold, once-a-week changes with the first one free), friend codes (8 of 32 characters, unbiased), display name (40, control and direction characters removed, links refused), avatar presets, settings; turning activity sharing off deletes the current activity; Friends off removes every social row in one batch; `holdHandleOf` for account deletion |
| `backend/src/social/relationship.ts` | `relationship(viewer, owner)` → self, friend, blocked, none (a block wins), and `orderedPair`; used by every Phase 2+ read |
| `backend/src/social/retention.ts` | `pruneSocial`: held handles after 30 days, requests after 30, recommendations after 180, expired activity, counters older than 2 days |
| `backend/src/index.ts` | `/social/*` routes behind `authenticate`; `SOCIAL_LIMITER` (60 a minute per account) on all, `SOCIAL_LOOKUP_LIMITER` (10 a minute per account and per address) on handle claims and code resets; `pruneSocial` in the daily cron |
| `backend/src/auth.ts` | Account deletion holds the handle before the cascade |
| `backend/src/env.ts`, `backend/wrangler.toml` | The two limiter bindings in every environment (namespaces 1006/1007, 2006/2007, 3006/3007) |
| `backend/test/social-profiles.test.ts` | 19 tests ([testing report](TESTING_REPORT.md)) |
| `docs/backend/README.md` | The four routes |

### App

| File | Change |
|---|---|
| `lib/src/account/account_api.dart` | `socialProfile`, `updateSocialProfile`, `resetFriendCode`, `disableFriends` on the existing `_send` (no separate `SocialApi` class: the calls are four lines each) |
| `lib/src/social/social_controller.dart` | `SocialProfile`, `SocialSetting`, `SocialController`: per-account saved copy (`reelish.social.v1.<userId>`), refresh, changes that return a message to show, never the Trakt username |
| `lib/src/screens/social/friends_privacy_screen.dart` | *Friends & privacy*: one settings page for phone, TV and Windows, as Manage account is. Text dialogs check handles before sending and keep the server's refusal on screen; TV uses `TvTextEntryDialog` and shows the code without a Copy action |
| `lib/src/screens/profile_screen.dart` | *Friends & privacy* row first in the Account section (all three interfaces), showing `@handle` or Off from the saved copy, with no request on open |
| `lib/src/screens/legal_information_screen.dart` | Privacy policy: a *Friends* section for what Phase 1 stores |
| `test/friends_privacy_test.dart` | 14 tests |
| `test/profile_layout_test.dart` | The Windows layout test reads the Account section's new first row |

### Deviations from the plan

- One page for the three interfaces instead of the planned separate TV
  (`tv_social.dart`) and Windows (`desktop_social.dart`) files: in Phase 1
  it is a settings page, and settings pages are shared. Those files come
  with the friends list in Phase 2, where the layouts differ.
- The entry is a row in Profile's Account section rather than its own
  section, so the TV and Windows layout keeps two columns.
- The activity switch is not shown yet: it would do nothing until Phase 5.

### Deployed

- Staging: migration `0013_social.sql` applied to `reelish-staging`; Worker
  deployed (version `1a8fb249`) with both limiters bound.
- Production: not touched. It needs migrations `0011`–`0013` and a deploy
  before a release that includes Friends.
