# Continue watching: test report

Phase A (local engine). Run on Windows 11 with the repository's Flutter
SDK, 2026-11-13.

## Tests added

`test/intelligent_continue_watching_test.dart`, 21 tests:

| Group | Covers |
|---|---|
| The episode to continue | `continueAt`: unfinished last episode; next once watched; nothing after the finale |
| Cards | `Up next · S1 E4`; the next episode's own progress when it has some |
| What stays in Continue watching | Watched movie leaves, unfinished stays, no length stays, never started excluded; finished series leaves unless a next episode is known; series without episode records unchanged |
| Resume position | `validResume`: watched end → 0; past a shorter source → 0; inside → kept; unknown length → kept |
| Storage | `next` saved with a watched episode and dropped by an unfinished one, other episodes untouched; progress saved before `next` existed loads; accounts isolated (A, B, signed out, back to A); removal touches only the signed-in account; device history moves into its owner with the account's entries winning and old keys removed; a non-owner receives nothing and the old keys stay |
| Library | Finished titles leave `continueWatching` and stay in `history` |

## Results

| Command | Result |
|---|---|
| `flutter test test/intelligent_continue_watching_test.dart` | 21 passed |
| `flutter test` (whole suite) | 1343 passed, 4 skipped, 0 failed |
| `flutter analyze lib test integration_test test_driver --no-fatal-infos` | 15 info, no warnings or errors (baseline 16 info) |
| `dart run tool/docs/docs_tool.dart check` | See the changelog's validation section |

## A failure found and fixed

The first full run had 13 failures in other files (`ux_journeys_test`,
`profile_layout_test`, `player_session_test`, `home_startup_budget_test`,
`desktop_home_top_ten_test`); each passed alone and all passed on the base
commit. Cause: the migration future was a static, already-completed
`Future` created inside the first widget test's fake-async zone; awaiting it
from a later test resumed in that dead zone, so history reads never
finished. Fix: the future is kept only while a migration runs and is null
otherwise. All 13 pass since.

## Not verified

- **Devices.** No run on an Android phone, Android TV / Google TV or a
  Windows build: the lifecycle save (`onHide`), the Start over button's
  focus order on TV, and its layout on a small phone are untested on
  hardware.
- **Live playback.** The resume check against a real stream's length and
  the next-episode record were exercised through unit tests, not with a
  provider stream.
- **Migration on a real upgrade.** Covered by unit tests with the old keys;
  not run as an install-over-old-version on a device.
- **Cross-device scenarios 1–4 and 6 of the brief** need Phase B (sync).
  Scenario 5 (episode completion) and 7 (termination recovery up to the
  last checkpoint) are covered by the existing save behaviour plus the
  tests above, not by a device run.

## Phase B: sync

**Backend** (`backend/test/progress.test.ts`, 12 tests, in the Workers
runtime with real D1): a position read on a second device; a later change
from another device wins and a late older one is rejected; a rewind on the
newest change is kept; same-device ordering by counter despite a clock going
back; a future clock clamped; deterministic ties; episodes with `next` and
the series card; removal and return; account isolation (including a
reused device id); paged pull from a cursor; ten kinds of malformed change
rejected without storing anything; 401 without a session; rows deleted with
the account and pruned after 400 days.

**App** (`test/progress_sync_test.dart`, 8 tests, two or three simulated
devices against a fake API with the server's ordering rule): brief scenario
1 (a movie continues on another device, card included); scenario 2 (an
episode and its next episode); scenario 3 (offline save sent on
reconnection); scenario 4 (the older offline upload loses, both devices end
on the newer position); removal reaching another device; progress from
before sync filling gaps without replacing newer progress; a device clock
an hour fast corrected; a change saved during an account switch kept for
its own account.

| Command | Result |
|---|---|
| `npm test` (backend) | 194 passed (17 files) |
| `npm run typecheck` | Clean |
| `flutter test` (whole suite) | 1351 passed, 4 skipped, 0 failed |
| `flutter analyze …` | 15 info, no warnings or errors |
| Staging | Migration applied, Worker deployed; `/health` ok, progress routes 401 without a session |

**Not verified:** sync between real devices against staging (needs a
staging build signed in on two devices); brief scenario 6 (account switch)
is covered by Phase A's storage tests and the outbox test, not a device run;
the D1 row counts and request rates under real use.

## Performance

No new work runs per position update. Added costs:

- One history read (≤ 50 entries, local) per movie playback, started in
  `initState` alongside stream opening; the seek already waited on the
  start position, so start-up does not wait longer unless the read is
  slower than opening the stream.
- One save when the app is hidden.
- The Continue watching filter runs over ≤ 50 in-memory entries per
  history load.
