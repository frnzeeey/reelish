# Custom collections: test report

Phase 1 (local). Run on Windows 11 with the repository's Flutter SDK,
2026-11-13.

## Tests added

`test/custom_collections_test.dart`, 31 tests:

| Group | Covers |
|---|---|
| Collections | Create (name trimmed), edit, delete (deletion mark kept, titles dropped); empty, 81-character name and 301-character description refused; a title listed once however often added; a movie and a series with the same TMDB id kept apart; one title in several collections; a change naming a missing collection changes nothing; removed then added again; sort by newest, oldest, title, year; reorder by one place, stopping at the ends; cover from the chosen title, then the newest |
| Folders | Moving into and out of a folder keeps titles; no move into a deleted folder; deleting a folder keeps its collections (moved to the top level) unless asked to delete them; a collection whose folder is missing shows at the top level |
| Storage | Survives a restart; accounts isolated (A, B, signed out, back to A); a change queued for one account is never saved to another; unreadable records skipped; a corrupt document loads empty; deletion marks older than 400 days dropped |
| My list dates | `toggleFavorite` dates new titles; older entries load undated; Trakt watchlist additions stay undated |
| Smart collections | Recently added (dated, 30 days, newest first, undated excluded); My list unchanged; Not started (30-second start does not count, a series counts by any episode past 90 s); Finished |
| Library view model | Follows collection changes without reloading |
| Screens | Details → Collections → New collection adds the title, unticking removes it, Done closes; an empty name is refused; delete asks first with Cancel focused; phone collection page lists titles and opens one; TV collection page focuses the first poster; Windows library section shows smart collections, folders and loose collections, with foldered ones only in their folder |

## Results

| Command | Result |
|---|---|
| `flutter test test/custom_collections_test.dart` | 31 passed |
| `flutter test` (whole suite) | 1382 passed, 4 skipped, 0 failed |
| `flutter analyze lib test integration_test test_driver --no-fatal-infos` | 15 info, no warnings or errors (baseline) |
| `dart run tool/docs/docs_tool.dart check` | All checks passed |
| `flutter build windows --release`, `flutter build apk --profile` | Both built |

## Problems found and fixed

- **Existing Windows library tests failed** (3 in
  `desktop_remove_favorites_test`) when the Collections section sat above
  Watch history: the history row moved out of the 800×600 test window and
  was not built, and the smart *My list* tile added a second "My list". The
  section now comes after Watch history on all three interfaces, so the
  existing rows keep their places and focus order; the tests pass unchanged.
- **A change could stall in widget tests.** The store kept its completed
  read and write futures for ever; awaited from a later zone they never
  resumed (the same pitfall Continue watching Phase A hit). Both are now kept
  only while they run.

## Not verified

- **Devices.** Not run on an Android phone, Android TV / Google TV or a
  Windows build: D-pad focus through the TV row, dialogs and text fields on
  a real remote and on-screen keyboard; long press on a phone; hover and
  right-click on Windows; layouts at real window scaling and on a small
  phone.
- **Large libraries.** Not measured: a library of thousands of titles
  should rebuild and save well within a frame, but this is an estimate.
- **Cross-device scenarios** (brief steps 4–8, 11) are covered by Phase 2's
  simulated devices below, not by real devices.
- **Trakt** (brief steps 9 and Trakt import/export) is out of scope by
  decision; collections do not depend on Trakt, so disconnecting it cannot
  affect them.
- **Brief step 12 (account switching)** is covered by the storage tests, not
  a device run.

## Phase 2: sync

**Backend** (`backend/test/collections.test.ts`, 10 tests, in the Workers
runtime with real D1): a collection made on one device and a title added
on another both kept; the same title from two devices is one record; the
later change wins and an older offline edit does not undo a deletion (which
keeps no content); same-device ordering by counter, replays dropped, future
clocks clamped; folders, moves, covers, descriptions and removals travel;
account isolation (same record key and device id under two accounts);
paged pull from a cursor (210 records); fifteen kinds of malformed record,
a bad device id, an oversized batch and a bad cursor rejected without
storing anything; 401 without a session; only deletion marks pruned, live
records kept; everything deleted with the account.

**App** (`test/collection_sync_test.dart`, 9 tests, devices simulated with
their own storage against a fake API using the server's rule): a collection
in a folder, with titles and a cover, made on Android appears on Windows;
edits made offline on two devices both kept; the same title added on two
devices listed once; a deletion not undone by an older offline rename; a
title removed on one device leaves another; a library made before sync
uploaded on the first sync; a device clock an hour fast cannot win over a
newer change; a title arriving before its collection kept; records for
another account never applied.

| Command | Result |
|---|---|
| `npm run typecheck` | Clean |
| `npm test` (backend) | 204 passed (18 files) |
| `flutter test test/collection_sync_test.dart` | 9 passed |
| `flutter test` (whole suite) | 1391 passed, 4 skipped, 0 failed |
| `flutter analyze …` | 15 info, no warnings or errors |
| Staging | Migration `0012` applied, Worker deployed; `/health` ok, `/api/v1/collections` answers 401 without a session |

**Not verified:** sync between real devices signed in to staging (brief
steps 1–8, 10–12 on hardware); D1 row counts and request rates under real
use; a device whose clock is changed between sessions.
