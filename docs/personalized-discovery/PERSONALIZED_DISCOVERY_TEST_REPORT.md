# Personalised discovery: test report

Run on Windows 11 (developer machine), 2026-11-13, with `flutter test`.

| Suite | Result |
|---|---|
| `test/discovery_viewing_activity_test.dart` | 11 passed |
| `test/discovery_engine_test.dart` | 18 passed |
| `test/discovery_controller_test.dart` | 13 passed |
| `test/discovery_rows_ui_test.dart` | 5 passed |
| Whole suite (`flutter test`) | 1322 passed, 4 skipped (pre-existing skips), 0 failed |
| `flutter analyze lib test integration_test test_driver` | no errors or warnings; 15 pre-existing infos |

## Required scenarios

| # | Scenario | Covered by | Result |
|---|---|---|---|
| 1 | Brand-new user | controller: *a brand-new viewer gets no personalised rows and no requests*; engine: *a new viewer has no profile* | Pass: no rows, 0 requests, Home's ordinary rows unchanged |
| 2 | Extensive movie history | engine: genre affinity, rewatch, diversity, dedupe tests; controller: history seeding | Pass |
| 3 | Mostly TV shows | engine: *series fans get series first*; activity: *series count finished episodes* | Pass |
| 4 | Strong preference for one genre | engine: *one genre cannot take the whole row; some titles explore* | Pass: ≤ 40 % per leading genre, ~25 % exploration |
| 5 | Frequently watched actors | — | **Not implemented**: no cast data or person route through the gateway (see architecture, Limits) |
| 6 | Trakt connected | engine: *My list counts and is excluded* (the Trakt watchlist reaches discovery through My list) | Pass for the watchlist; Trakt history is not reachable (no backend route) |
| 7 | Trakt not connected | every controller test runs without Trakt | Pass |
| 8 | Disconnects Trakt | — | Same as 7: discovery never calls Trakt; not separately tested |
| 9 | Logs out and switches accounts | controller: *a second account … does not inherit …*, *signed out: nothing is loaded …*, *records … only for the signed-in account* | Pass |
| 10 | Clears recommendation history | controller: *reset forgets viewing and rows …*; UI: *Settings: … reset* | Pass |
| 11 | Poor connectivity | controller: *rows are cached …* (restart offline, then 7 h later offline) | Pass: cached rows kept |
| 12 | TMDB unavailable | controller: *TMDB unavailable: rows come from what Home already has* | Pass |
| 13 | Empty TMDB recommendations | controller: *empty TMDB recommendations and an empty catalog …*; engine: *empty TMDB answers still give rows …* | Pass: no empty or short rows |
| 14 | Duplicates across sections | engine: *builds explained rows without duplicates*; controller: seeding test | Pass |
| 15 | Already completed title | engine: *never recommends a watched, saved, hidden or unreleased title*; controller: *a title started since … leaves them* | Pass |
| 16 | Very limited activity | engine: *rows with too few titles are left out*; controller: picked-genres test | Pass |
| 17 | Diverse preferences | engine: seeds mix movies and series; exploration | Pass |
| 18 | Repeated Not interested | controller: *repeated Not interested adapts the rows and never breaks them*; engine: *Not interested lowers a genre but never excludes it* | Pass |

Also tested: failed starts under 90 s never count; abandonment after 10
days; unknown runtimes never count as finished; persisted shapes round-trip
and bad entries are skipped; activity is bounded; simultaneous refreshes
share one; the phone long-press sheet and Undo; a card without the new
long-press keeps its old behaviour (it opens the title — checked against the
code before this change); the Windows row's reasons and Not interested; the
TV row is present.

## Performance

Measured by tests: request counts (above and in
[TMDB usage](TMDB_API_OPTIMIZATION.md)).

**Not measured:** scoring time on a device, frame timings with the new rows,
and memory. Scoring is a single linear pass plus sorts over at most a few
hundred items, run once per refresh, not per frame; it was not profiled.

## Not verified

- No run on a real Android phone, Android TV / Google TV device or a
  Windows window against the live Reelish API and TMDB.
- TV D-pad navigation into and along the new rows was not exercised (the TV
  test checks the row is built; it is the existing `TvMediaRow`).
- The Settings genre chips were not tried with a remote.
- The Windows release and Android profile builds compile (see the
  changelog) but were not run.
