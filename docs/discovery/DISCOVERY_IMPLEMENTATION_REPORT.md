# Genre onboarding and discovery preferences

What this change added to Home discovery, why, and how it was checked. The
section-by-section audit it is based on is
[DISCOVERY_AUDIT.md](DISCOVERY_AUDIT.md). The engine that was already there
is described in [personalised discovery](../personalized-discovery/PERSONALIZED_DISCOVERY_ARCHITECTURE.md)
and its [scoring model](../personalized-discovery/RECOMMENDATION_SCORING_MODEL.md).

## 1. What existed

Most of the requested engine already existed (commit `00092d0`): per-account
viewing activity derived from saved positions, a weighted, deterministic
scorer with a genre cap and exploration slots, four row kinds with reasons,
per-account cached rows, feedback, and a genre picker in Settings >
Recommendations. The gaps were these:

| Gap | Effect |
|---|---|
| No `with_genres` on the TMDB gateway | Picked genres only re-ranked ~150 recent titles; a Western or Documentary fan got no row |
| No first-run genre step | A new account saw a generic Home until it had watched something |
| No personalisation switch | The only opt-out was Reset |
| Preferences per device | Genres picked on the phone did not reach the TV |
| "Top 10 recommendations" | Labelled as personal, but the same for everyone |
| Trending not de-duplicated | It repeated cards from the personalised rows and Top 10 |

## 2. Sections retained, changed, added, removed

| Section | Decision |
|---|---|
| Spotlight, Continue watching, New releases, New movies, Series worth the queue, Recommended for you, Because you watched, Something different | Retained, unchanged |
| Top 10 | Retained; relabelled **Top 10 picks** (visible text only; TV's widget key is unchanged) |
| Trending now (Home row) | Retained; drops titles the personalised rows and Top 10 show, as long as 10 remain. The phone's Trending tab is unchanged |
| Top picks in a genre | Retained; skipped for a genre that has its own "Because you like" row |
| **Because you like a genre** | Added: up to two, from TMDB `discover` with `with_genres` |
| **Genre prompt** | Added: a dismissible card for existing accounts without preferences |
| Popular, Upcoming | Not added (see the audit); nothing removed |

`DiscoveryEngine.maxSections` went from 4 to 5 so that a genre row does not
push out "Because you watched".

## 3. Home hierarchy

Phone (For you): Spotlight → Top 10 picks → Continue watching → *genre prompt* →
personal rows → New releases → Trending → New movies → Series.
Windows: hero → Top 10 picks → *genre prompt* → personal rows → Trending →
Watch together → New movies → Series → New releases. TV: Continue watching
→ New movies → Series → *genre prompt* → personal rows → Watch together →
Top 10 picks → New releases → Trending. TV order is unchanged on purpose:
rows that appear above the focused row move focus on a remote (see the
audit).

## 4. Genre onboarding

`GenreOnboardingScreen` (`lib/src/screens/genre_onboarding_screen.dart`) is
one page for all three interfaces. Its tiles are ordinary focusable buttons,
so they work with touch, the D-pad (focus starts on the first genre) and the
keyboard. Focus draws an outline that is distinct from the chosen fill.

- Heading "What do you love watching?" and the supporting text from the
  brief. A live count ("2 selected · a few more helps"). Continue needs one
  genre, and three are suggested without being required. Skip for now is
  always there. There is no Select all, because choosing everything says
  nothing about taste.
- The genres come from TMDB's `/genre/movie/list` and `/genre/tv/list`
  (`TmdbService.genreCatalog`). The built-in copy shows first and is
  replaced when TMDB answers, so the page never waits. Picks are checked
  against TMDB's lists (`GenreCatalog.valid`) before they are saved.
- One pick, two queries: `GenreCatalog.movieQueryId` / `tvQueryId` map a pick
  to TMDB's movie genre and TV genre (Science fiction → 878 / 10765 Sci-Fi &
  Fantasy, Action → 28 / 10759; Horror is movie-only; Kids is TV-only;
  Documentary is movie-only because the series rows keep to scripted shows).
  TMDB publishes both lists but not how they relate, so `TmdbGenres.equivalents`
  remains Reelish's own mapping, and it is documented in code.

**Who sees it** (`OnboardingPolicy.decide`, `lib/src/discovery/discovery_preferences.dart`):

| Account | Result |
|---|---|
| Answered (completed or skipped) on any device, picked genres in Settings, or personalisation off | Nothing |
| Created < 24 h ago (`GET /me` `createdAt`), nothing watched on this device, server reachable | Full-screen step, once, before the consent prompts |
| Any other account without preferences | Home card ("Tell us what you love watching"). Never blocks Home |
| Server not reachable at launch | The card, never the full screen, so a step answered elsewhere is not asked again |

Home gives the decision 8 seconds (`_decideGenreStep`). If it takes longer,
nothing takes over the screen. Back from the step leaves it unanswered, and
the card stays. Skip, or the card's Not now, answers it as `skipped` on
every device. TV has no separate dismiss target: the row opens the step,
whose Skip dismisses it. Guest browsing does not exist in Reelish
(`AccountGate` requires sign-in), so there was no guest path to preserve.

## 5. Preference persistence

| Where | What |
|---|---|
| `onfeed.discovery.v1.<userId>` (SharedPreferences, existing key) | New optional fields `onboarding`, `personalization`, `prefsAt`, `prefsUnsent`; omitted at defaults, so data written before reads unchanged ([data model](../personalized-discovery/PERSONALIZATION_DATA_MODEL.md)) |
| `onfeed.discoveryPrefsSync.v1` | Per account: random device id, change counter, server clock offset |
| D1 `discovery_preferences` (migration `0014`) | One row per account: `{onboarding, genres, personalization}` rebuilt from checked fields, device id, `seq`, `client_at`, `changed_at`; `ON DELETE CASCADE` with the account |

Routes: `GET` / `PUT /api/v1/discovery/preferences` (`backend/src/discovery-preferences.ts`,
rate limited by `SYNC_LIMITER`). The existing API was enough; no new
service or dependency was added.

**Sync** (`DiscoveryController.syncPreferences`, transport `DiscoveryPreferencesSync`):

- A change is saved locally at once and marked unsent. It is pushed 3 s
  after the last change, so several taps make one request, and again when
  the app is hidden.
- At bind, a pull. If the server has nothing but this device has genres
  from before sync existed, they are pushed and become the account's.
- On return to the app, a pull at most every 2 minutes.
- **Conflicts:** the server keeps the newer change, ordered as playback
  progress is: by a per-device counter on one device, and by the change time
  (corrected by the measured clock offset and clamped to the server's time)
  between devices. A `PUT` answers with what is stored, so a device whose
  older offline change lost adopts the winner rather than overwriting it.
- **Failures:** offline or 5xx leaves the local copy in place and still
  marked unsent. It is retried at the next change, launch or return to the
  app.

## 6. Recommendation algorithm

The scorer is unchanged ([scoring model](../personalized-discovery/RECOMMENDATION_SCORING_MODEL.md)):
genre affinity, seed relevance, quality (vote-weighted rating), popularity
and movie/series fit, with a 40 % cap per leading genre, about a quarter of
the main row exploratory, and no title twice. What changed:

- **Genre candidates.** `DiscoveryController.genresToQuery` takes the picked
  genre with the highest profile affinity, plus one of the others chosen by
  the day, so over time every pick gets a turn. For each, TMDB `discover`
  (popularity, ≥ 150 votes for movies, ≥ 60 for series, rating ≥ 6.5,
  released by today, series scripted only) is asked for movies and series.
  The results join the candidate pool (`GenreCandidates`).
- **"Because you like" a genre** (`DiscoveryEngine._likedGenreRow`): that
  genre's candidates not already used above, best score first, movies and
  series alternating, 6–12 titles. Reason: "Based on your preferred
  genres", which is exactly why they are there.
- **Personalisation off:** no rows, no TMDB requests, and viewing is not
  recorded. What was learned before is kept. Turning it back on rebuilds
  the rows rather than showing the old ones.
- **Reset** forgets activity and feedback but keeps the preferences, as
  before. Watch history, My list and ratings are untouched.

## 7. TMDB and Trakt

New requests, all through the Reelish API's allowlisted gateway and the
app's existing cache, limiter and in-flight de-duplication:
`/discover/{movie,tv}?with_genres=` (deferred priority, 20 min) and
`/genre/{movie,tv}/list` (24 h). The allowlist accepts `with_genres` as an
id list (≤ 21 ids) and the two list routes with no parameters. Trakt
integration is unchanged. Trakt history and ratings still need a backend
route, as noted in the architecture doc.

## 8. Cache and performance

| Event | TMDB requests |
|---|---|
| Launch | 0 for discovery (rows from disk); Home's own rows as before |
| Refresh due (6 h, or tastes changed) | ≤ 4 seeds + ≤ 4 genre lists; page 1 each; shared edge cache keyed by URL, not account |
| Refresh not due | 0 |
| Personalisation off | 0 |
| Genre lists | ≤ 2 a day |

The rows' fingerprint now includes the queried genres, so picking genres
rebuilds the rows at once, and Home listens for preference changes from
Settings, the step or another device. The Trending de-duplication is a
linear pass over ≤ 20 titles during build. No timings were measured; the
request counts are asserted in tests (section 11).

## 9. Security

- The server derives the account from the session token. No client account
  id is trusted, and one account cannot read or write another's row (tested).
- Every field is validated (`onboarding` enum, ≤ 40 integer genre ids in
  range, boolean switch, 4 KB body, device id pattern). The stored body is
  rebuilt from the checked fields, never the device's JSON.
- Nothing personal beyond the preferences is stored: no viewing data, no
  feedback, no names. The device id is random, not a hardware identifier.
  The in-app privacy policy (Settings > Legal) describes this, and account
  deletion removes the row.
- No secrets were added. The app still has no TMDB credential. Nothing is
  logged.

## 10. Free-tier implications

One D1 row per account. One write per settled change, typically a handful
per account in its lifetime. One read per launch and at most one per 2
minutes in use. Genre `discover` responses are shared across accounts at
the edge cache (same URL for the same genre and day). This is well within
the Workers Free plan and D1's free limits. No paid service was introduced.

## 11. Tests

| Suite | Result |
|---|---|
| `test/discovery_preferences_test.dart` (23): old data reads unchanged; round trip; malformed values dropped; onboarding policy (new, existing, offline, answered); genre mapping and TMDB-list validation; Trending de-duplication; genre-only account gets genre rows with exact request set and none on a second refresh; daily genre rotation; failed genre requests; personalisation off (no rows, requests or recording) and back on; sync to a second device; newer remote change wins and older offline change loses; pre-sync genres pushed; offline launch never full screen; skip remembered; account isolation, including an account bound while another's sync is still out (fails without the fix); reset keeps preferences; six-title minimum | Pass |
| `test/genre_onboarding_test.dart` (6): phone at 360 dp in Montserrat (no overflow, semantics with tap and selected state, Continue disabled at 0, saved picks); Skip vs system Back; TV focus starts on a genre, Select and arrow keys; Windows card opens / Not now dismisses; TV row opens; Settings switch | Pass |
| `test/tmdb_catalog_service_test.dart` (+2): genre requests use only parameters the gateway allows; genre list fallback | Pass |
| `backend/test/discovery-preferences.test.ts` (10), `allowlist.test.ts` (+9 checks) | Pass |
| `flutter test` (whole app) | 1,504 passed, 4 skipped (as before) |
| `npm test` (backend) | 25 files, 288 tests pass; `npm run typecheck` clean |
| `flutter analyze lib test integration_test test_driver` | 15 info-level notes, all pre-existing; no warnings |

`flutter build windows --release` and `flutter build apk --profile` both built.

**Not verified:** a real Android phone, Android TV / Google TV device or
Windows window; the live Reelish API (migration `0014` and the allowlist
change are not deployed anywhere); live TMDB results for each genre; Home's
full-screen decision end to end (the policy, the controller and the step are
tested separately, and Home's wiring is not); load times and memory.

## 12. Known limitations

- Deploy order: until the Worker with this allowlist is deployed, genre
  requests are refused (400) and the rows fall back to Home's loaded titles,
  as before. Until migration `0014` and the route are deployed, preferences
  stay on the device and the full-screen step is never shown (the card is).
  Both must reach production before a release that relies on them.
- The full-screen decision depends on `/me` `createdAt`. An account created
  long ago that signs in for the first time on a new device gets the card,
  not the full screen, by design.
- Viewing activity and feedback are still per device.
- TV cards still have no per-card feedback action.

## 13. Future improvements

- Move TV's personalised rows above New movies with focus-preserving
  insertion, after a device test.
- Trakt history and ratings as signals (needs a backend route).
- `with_cast` / `with_crew` for "More from people you watch".
- A Windows hover "Why this?" for every row, not only Recommended for you.
