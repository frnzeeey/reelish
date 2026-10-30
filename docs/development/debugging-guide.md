# Debugging guide

Where to look when something goes wrong, by area. Playback symptoms have
their own [troubleshooting guide](../playback/troubleshooting.md).

## Logs

Diagnostics print only in debug builds (`kDebugMode`); release builds are
quiet by design (provider errors can quote URLs). None of the lines below
contain stream URLs, headers or cookies.

| Prefix | Source | What it tells you |
|---|---|---|
| `[Perf]` | `PerfTimeline` ([`perf_timeline.dart`](../../lib/src/services/perf_timeline.dart)) | Milestones since process start: `HOME_USABLE`, `DETAIL_OPEN`, `PLAY_PRESSED` → `FIRST_SOURCE` → `PLAYER_OPEN` |
| `[HomeFeed][<row>]` | `PagedFeedController` | Cache hits, loaded counts and stops per row |
| `[TMDB]` | `TmdbService` | Persistent cache hits per endpoint |
| `[Provider Perf]` | `ProviderPluginService.streams` | Each provider's start, candidate count or failure |
| `[Stream]` | `StreamDiscovery` | Time to first candidate (TTF) and first valid source (TTR) |
| `[Playback][Player\|Failure\|Fallback\|Engine\|Subtitle]` | `PlaybackLog`, `CustomVideoPlayer`, `player_engine.dart` | Engine opens, timings, failure kind, retries, engine gate waits |

Reading them:

- **Android:** `flutter run` prints them, or `adb logcat -s flutter`.
- **Windows:** `flutter run -d windows` prints them.
- **Integration tests** print them in the test output.

## Debugging entry points

| Area | Start at | Then |
|---|---|---|
| App start, blank screen | `_StartupScreenState._initialize` ([`main.dart`](../../lib/main.dart)) | `DeviceCapabilities.load`, `SplashGate` |
| Wrong interface (phone UI on a TV) | `DeviceCapabilities.load` | `ReelishActivity.deviceCapabilities()`; force with `REELISH_FORCE_TV` |
| A row is empty or stale | `HomeViewModel`, the row's `PagedFeedController` state | `TmdbService`, `TmdbResponseCache`, catalog rules |
| Continue watching wrong | `HomeViewModel.loadHistory` | `StorageService.history`, `seriesProgress`, `ResumeSummary` |
| Navigation or Back | `HomeScreen._showDetails`, the shells | `DesktopShortcuts`, `DesktopGamepad`, `TvPopupFocusObserver` |
| Focus lost on TV | `TvFocusable`, `TvPopupFocusObserver` | [`docs/android_tv.md`](../android_tv.md#how-focus-management-works) |
| Windows sidebar stays open | `_SidebarState` ([`desktop_shell.dart`](../../lib/src/desktop/desktop_shell.dart)) | the pin preference, focus inside the rail |
| Providers | `ProviderPluginService.streams` | the `provider-debugging` skill |
| Playback | `HomeScreen._resolveAndOpenPlayer`, `CustomVideoPlayer._initialize` / `_handleFailure` | [troubleshooting](../playback/troubleshooting.md) |
| Updates | `GitHubUpdateService.checkForUpdate`, `WindowsUpdateController.check` | `UpdateConfig`, the update channels |

## Common failure scenarios

- **"setState() called during build" at startup on Windows.**
  `DeviceCapabilities.load` defers its notification by a microtask for this
  reason; keep that when touching it.
- **Text in yellow double underline.** A widget tree without a `Material`
  ancestor (for example an overlay in a `Stack` above the shell); wrap it in
  `Material(type: MaterialType.transparency)`.
- **A stuck `pumpAndSettle` in a test.** A continuous animation (a spinner,
  a repeating timer that schedules frames). Pump a fixed duration instead.
- **Release-only failures** (missing names, reflection): builds are
  obfuscated; see [`docs/code_protection.md`](../code_protection.md).
- **Build or release failures:** [`docs/releasing.md`](../releasing.md#troubleshooting)
  and the workflow logs (`gh run view <id> --log`).

## Performance and memory

Measure before changing anything, in profile mode (`flutter run --profile`)
with DevTools. Existing measurements:

- [`integration_test/ui_perf_test.dart`](../../integration_test/ui_perf_test.dart):
  phone frame times; run with `flutter drive --profile` (reinstalls the
  app, clearing its data).
- [`integration_test/player_long_session_test.dart`](../../integration_test/player_long_session_test.dart):
  memory over repeated player opens on Android.
- [`integration_test/windows_soak_test.dart`](../../integration_test/windows_soak_test.dart):
  memory over repeated player opens and provider runs on Windows.

The `performance-memory` skill describes the method.
