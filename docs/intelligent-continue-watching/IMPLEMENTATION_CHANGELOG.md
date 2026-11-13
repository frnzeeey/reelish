# Continue watching: implementation changelog

## Phase A — local engine (2026-11-13)

### Files created

| File | Purpose |
|---|---|
| `lib/src/account/account_history.dart` | `AccountHistory`: points `StorageService` at the signed-in account and asks `DiscoveryStore` who owns the device's older history |
| `test/intelligent_continue_watching_test.dart` | 21 tests (see the [test report](CONTINUE_WATCHING_TEST_REPORT.md)) |
| `docs/intelligent-continue-watching/*` | These documents |

### Files changed

| File | Change |
|---|---|
| `lib/src/services/storage_service.dart` | Per-account history and episode keys (`useAccount`, `debugResetAccount`), one-time device-history move, `next` episode in the episode store; writes capture the account when called |
| `lib/src/models/episode_progress.dart` | `SeriesProgress.next`, `SeriesProgress.continueAt` |
| `lib/src/models/resume_summary.dart` | `Up next` card label; `ResumeSummary.continues` (what stays in Continue watching) |
| `lib/src/viewmodels/home_view_model.dart` | Home's row uses `continues` |
| `lib/src/viewmodels/library_view_model.dart` | `continueWatching` getter shared by the three library pages |
| `lib/src/screens/library_screen.dart`, `lib/src/screens/tv/tv_pages.dart`, `lib/src/desktop/desktop_pages.dart` | Library Continue watching from the view model |
| `lib/src/widgets/player/custom_video_player.dart` | Records `next` with a watched episode; movie start read from the saved history entry; `validResume`; `startFromBeginning`; save when the app is hidden |
| `lib/src/screens/player_screen.dart` | Passes `startFromBeginning` |
| `lib/src/screens/home_screen.dart` | `fromStart` through the play flow; Start over for movies in Continue watching; series resume and the episode list open on `continueAt` |
| `lib/src/screens/media_details_screen.dart`, `lib/src/screens/tv/tv_details_screen.dart`, `lib/src/desktop/desktop_details_screen.dart` | Resume / Start over buttons for a movie in progress |
| `lib/src/notifications/episode_alerts.dart` | The background episode check reads the account's own history |
| `lib/main.dart` | Attaches `AccountHistory` at start-up, after the session is restored |

### Existing behaviour preserved

- Checkpoint cadence (15 s, pause, exit, episode change) and the episode
  hand-off flag are unchanged.
- Engine selection, source handling, the seek-before-play order and its
  clamp to the end are unchanged; the resume check only replaces a saved
  start that falls in the watched end.
- Watch Party opening positions and source-recovery positions bypass the
  new check, as before.
- Remove from history and Undo work as before (now within the account).
- The 90 % completion rule and the next-episode offer's own setting are
  unchanged.
- Old SharedPreferences values load: entries without `next`, history and
  episode progress under the device-wide keys.

### Decisions

- **Per-account storage, migrated once** (user decision): the first account
  to claim the device's history gets it, using the owner personalised
  discovery already records.
- **Finished titles leave Continue watching, not the history**, so the
  Library, profile counts and recommendations keep them.
- **Up next only from the episode list** (`EpisodeContext.next`, aired
  episodes only); no guessed `episode + 1`.
- **Start over is a play option, not a deletion**: progress changes only
  when the new playback saves.
- **Sync through the Reelish API + D1** (user decision), Phase B; Trakt is
  not written to (user decision: not now).

### Dependencies

None added.

### Known limitations

- Closing the Windows window while playing keeps the last 15-second
  checkpoint (`WM_CLOSE` is not forwarded to Dart).
- My list (favourites), subtitle choices and saved stream links are still
  per device, not per account; only history and progress were separated.
- Device history owned by an account that never signs in again stays
  stored, unread, on the device.
- Start over is for movies; an episode in progress is restarted by seeking,
  and a watched episode already restarts from 0.
- Until the app runs once after updating, the Android background episode
  check does not see series still in the device-wide history.
- No cross-device sync yet (Phase B).

### Validation

`flutter test` (1343 passed, 4 skipped), `flutter analyze` (15 info, no
warnings), `dart run tool/docs/docs_tool.dart check`. No device run; see
the test report.

## Phase B — cross-device sync (2026-11-13)

Design and ordering: [sync strategy](CROSS_DEVICE_SYNC_STRATEGY.md).

### Files created

| File | Purpose |
|---|---|
| `backend/migrations/0011_playback_progress.sql` | `playback_progress` table and its pull index |
| `backend/src/progress.ts` | `POST/GET /progress`: validation, newest-wins upsert, paged pull, daily prune |
| `backend/test/progress.test.ts` | 12 tests: two devices, ordering, clock clamp, ties, episodes, removal, isolation, paging, validation, auth, deletion and pruning |
| `lib/src/account/progress_sync.dart` | `ProgressSync`: outbox, push/pull, clock offset, retries, first-sync upload |
| `test/progress_sync_test.dart` | 8 tests against a fake API with the server's ordering rule |

### Files changed

| File | Change |
|---|---|
| `backend/src/index.ts` | Routes under `SYNC_LIMITER`; prune in the daily cron |
| `lib/src/models/media_item.dart` | `progressAt` (optional, persisted) |
| `lib/src/models/episode_progress.dart` | `at` (optional third JSON element) |
| `lib/src/services/storage_service.dart` | Save times; `onProgressChanged`; `applySynced`; `allSeriesProgress`; `SyncedProgress`; Undo counts as a new change |
| `lib/src/account/account_api.dart` | `pushProgress`, `pullProgress`, `ProgressPage` |
| `lib/src/screens/home_screen.dart` | Reloads history when `ProgressSync.revision` changes |
| `lib/main.dart` | Attaches `ProgressSync` after `AccountHistory` |
| `lib/src/screens/legal_information_screen.dart` | Privacy policy: what the API stores for sync, deletion; date 13 November 2026 |
| `lib/src/support/help_content.dart` | Help answers: history follows the account; removal reaches other devices |
| `docs/backend/README.md` | Routes and table |

### Decisions

- Ordering by the corrected time of the change, clamped by the server, with
  a per-device counter; not by server first-sight (wrong for offline
  devices) and not by largest position.
- Card metadata travels with the row instead of TMDB lookups on the
  receiving device, to keep Worker requests down.
- Push after playback settles (30 s idle), at most every 15 minutes while
  saves continue, and when the app is hidden; never on the 15-second
  checkpoint.
- Sync is on for every signed-in account; there is no setting.

### Dependencies

None added.

### Known limitations

- A device's clock is corrected only after it has reached the server once.
- Pulls happen at start, sign-in and on return to the app (after 2 min);
  a device left open on Home does not see another device's progress until
  then.
- Personalised discovery learns only from playback on the device itself.
- Rows unchanged for 400 days are pruned.

### Deployment

Staging: migration `0011` applied and the Worker deployed on 2026-11-13
(`/health` answers, the progress routes answer 401 without a session).
Production: not touched; apply migration `0011` and deploy production
before a release that includes the app side.
