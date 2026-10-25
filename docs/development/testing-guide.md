# Testing guide

## Kinds of tests

| Kind | Where | Runs on | How |
|---|---|---|---|
| Unit and widget | [`test/`](../../test) | Any host | `flutter test` |
| Integration (real app, engines, runtimes) | [`integration_test/`](../../integration_test) | Device, emulator or Windows | `flutter test integration_test/<name>_test.dart -d <device>`, one file per run |
| Frame timings | [`integration_test/ui_perf_test.dart`](../../integration_test/ui_perf_test.dart) with [`test_driver/integration_test.dart`](../../test_driver/integration_test.dart) | Device or emulator | `flutter drive --profile -d <device> --driver=test_driver/integration_test.dart --target=integration_test/ui_perf_test.dart` |

[`test/flutter_test_config.dart`](../../test/flutter_test_config.dart)
preloads the QuickJS library so provider sandbox tests run on the host. CI
points it at the Linux build with `LIBQUICKJSC_TEST_PATH`.

## Integration tests

| File | Platform | Checks |
|---|---|---|
| `app_smoke_test` | Any | Launch, the Plugins page, the Plugin Library |
| `libmpv_playback_test` | Windows, real Android devices (skips on emulators) | libmpv plays public test streams |
| `player_long_session_test` | Android | Memory settles over 25 player opens |
| `provider_runtime_test` | Any | The provider sandbox on the real runtime |
| `torrent_streamer_test` | Android | The torrent streamer end to end |
| `ui_perf_test` | Android | Phone frame times (profile, `flutter drive`) |
| `windows_playback_test` | Windows | libmpv playback paths |
| `windows_player_ui_test` | Windows | Player controls with mouse and keys |
| `windows_soak_test` | Windows | Memory over repeated player opens and provider runs |
| `windows_update_channel_test` | Windows | The runner's update channel |

Several need internet (public test streams). **Device runs reinstall or
uninstall the app, which wipes its data**: back up first, or use a device
whose data can go. Run one file per invocation; a crashed run can leave
the next one hanging.

## Writing tests

- **Fonts.** Widget tests use the Ahem font, much wider than Montserrat:
  text can overflow where the real font fits, and taps can land on the wrong
  widget. Find by tooltip or key rather than text for small controls; load
  the real font with `FontLoader` when measuring layout.
- **Platforms.** Use `TargetPlatformVariant.only(TargetPlatform.windows)`
  for Windows UI and `DeviceCapabilities.debugOverride` for TV.
- **Hover** highlights need traditional focus highlighting (Android's
  default in tests is touch):
  `FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional`.
- **Timers.** `pumpAndSettle` does not wait for timers that schedule no
  frames, and never settles with a running spinner: pump explicit durations.
- **Services.** Pass a `TmdbService` with `testClient: MockClient(...)` and
  a `NetworkDestinationValidator(lookup: ...)`; see
  [`desktop_home_top_ten_test.dart`](../../test/desktop_home_top_ten_test.dart)
  for a full Home harness, and `SharedPreferences.setMockInitialValues`
  plus `StorageService.debugResetWrites()` for stored data.
- **Visual checks.** Render to PNG in a scratch test outside `test/` (the
  `ui-refinement` skill's `render-audit.md` has the recipe); never commit it.

## Before a commit

1. `dart format` on the files you touched.
2. `flutter analyze lib test integration_test test_driver`: no warnings or
   errors (16 info notes are the baseline).
3. `flutter test`: all pass.
4. Build what you touched: `flutter build apk --profile` and/or
   `flutter build windows --release`.
5. Integration tests for the area you changed, on each affected platform.
6. `dart run tool/docs/docs_tool.dart check`, if code moved or docs
   changed.
7. Report what you could not verify (device, TV, live provider, display
   scaling).

The `regression-check` skill has the full per-platform checklist.
