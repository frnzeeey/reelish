# Personalised discovery: implementation changelog

Branch: `playback-audit-phase-1` (uncommitted at the time of writing).

## Created

| File | Why |
|---|---|
| `lib/src/discovery/viewing_activity.dart` | The history had no completion, rewatch or abandonment state; these rules derive it from positions the player already saves. |
| `lib/src/discovery/discovery_data.dart` | Per-account activity, feedback and picked genres, with readable-forever JSON. |
| `lib/src/discovery/discovery_store.dart` | Per-account persistence on the existing SharedPreferences and private-file patterns; no new database. |
| `lib/src/discovery/taste_profile.dart` | Genre affinity, seeds, exclusions; every weight in `DiscoveryWeights`. |
| `lib/src/discovery/discovery_engine.dart` | Scoring, diversity, exploration and rows; pure so it is tested without network. |
| `lib/src/discovery/tmdb_genres.dart` | Genre names for the picker and row titles. |
| `lib/src/discovery/discovery_controller.dart` | Orchestration: account binding, recording, cached rows, single-flight refresh, feedback, reset. |
| `lib/src/widgets/recommendation_feedback_sheet.dart` | Phone feedback sheet with Undo. |
| `lib/src/screens/recommendation_settings_screen.dart` | Genres you like, show hidden titles, reset (phone, TV, Windows). |
| `test/discovery_*_test.dart` (4 files) | 47 tests; see the test report. |
| `docs/personalized-discovery/*.md` (6 files) | This documentation. |

## Modified

| File | Change | Effect elsewhere |
|---|---|---|
| `lib/src/services/storage_service.dart` | Static `onProgressSaved` listener (null by default), called at the end of `saveProgress` and `saveEpisodeProgress` inside their existing write; `SavedProgress` typedef. | None while null; errors in the listener are swallowed so a save never fails. Saved data unchanged. No player code touched. |
| `lib/src/screens/home_screen.dart` | Owns a `DiscoveryController`; follows the account; refreshes on catalog settled, history reload and resume; phone rows in For you before Top 10; long press on those cards; passes the controller to TV and Windows via `TvCatalog`. `_loadHistory` now also asks for a refresh. | `_section`/`_rowList`/`_mediaCard` gained an optional `onLongPress`; other rows pass nothing. |
| `lib/src/widgets/media_card.dart` | Optional `onLongPress`. | Null keeps the old behaviour (a long press opens the title, as a tap does); verified by test. |
| `lib/src/viewmodels/home_catalog.dart` | Optional `discovery`. | Callers that omit it show no personalised rows. |
| `lib/src/screens/tv/tv_pages.dart` | `TvMediaRow` per section after New movies and Series. | Focus still starts on the first catalog row. |
| `lib/src/desktop/desktop_pages.dart` | `DesktopMediaRow` per section under Top 10, Not interested on the cross / Delete, reasons as captions in the mixed row. | — |
| `lib/src/desktop/desktop_widgets.dart` | `DesktopMediaRow.removeLabel` (default unchanged), passed to the card. | Existing rows unchanged. |
| `lib/src/desktop/desktop_settings_page.dart` | `recommendations` section under General. | The exhaustive switch gained its page. |
| `lib/src/screens/playback_settings_screen.dart` | Settings > General > Recommendations tile (phone and TV). | — |
| `docs/README.md` | Link to these pages. | — |

## Preserved

All existing rows (spotlight, Continue watching, New movies, Series worth the
queue, Top 10, New releases, Trending), their order relative to each other,
their requests and caching; Continue watching and My list storage; Trakt
watchlist sync; playback, sources and providers (untouched); the backend
(untouched). Existing Home tests run signed out, where discovery is inert and
makes no request, so their request-budget assertions are unaffected.

## Decisions

1. **Local-first, no backend change.** The gateway already allows
   `/recommendations`; scoring is a few hundred items on device. No paid
   service, Firebase product, Cloud Function, R2 or new database.
2. **Candidates from seeds plus Home's rows**, not new discover queries:
   the gateway's discover routes take no genre or cast filter, and widening
   the allowlist means a backend deploy to staging and production first.
3. **Actors and directors left out** rather than approximated, for the
   same reason; documented as a follow-up.
4. **Old device history goes to the first account only**, since history was
   never per account and guessing whose it is would leak tastes between
   people on a shared device.
5. **No per-card feedback on TV**: there is no secondary action on TV cards
   today; adding one is a TV focus/interaction change of its own. Settings
   covers reset and hidden titles there.
6. **Recording through a storage hook, not the player**: playback code is
   off limits unless the task is about it (CLAUDE.md rule 3).

## Follow-ups

- Gateway: allow `with_genres` (and `with_cast`/`with_crew`) on discover and
  `/person/{id}/combined_credits` → genre rows beyond loaded titles and
  "More from actors you watch". Staging first; production before the release
  that uses it.
- Backend route for Trakt history and ratings → seed new devices and a
  shared profile across devices.
- TV: a long-press or menu-key action on recommended cards for feedback.
- Profile frame timings with the rows on a low-end Android TV.
- `TmdbGenres` duplicates the short genre map in `desktop_hero.dart`; they
  could share one.

## Builds

- `flutter build windows --release`: built `Reelish.exe`.
- `flutter build apk --profile`: built `app-profile.apk`.
- `dart run tool/docs/docs_tool.dart check`: all checks passed (after
  `generate`).
