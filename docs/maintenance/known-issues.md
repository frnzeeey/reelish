# Known issues and limitations

Limitations that are verified in the code, tests or existing docs. Each
names its evidence. Speculative problems are not listed; see
[technical debt](technical-debt.md) for maintainability observations.

| Issue | Platforms | Evidence | Notes |
|---|---|---|---|
| Native player engines make their own network requests, so redirects inside an engine are not re-validated by `NetworkDestinationValidator` (accepted risk SEC-01) | All | [`docs/streaming_security.md`](../streaming_security.md) | The first destination is validated by `SourcePreparer`; the risk and its limits are documented there |
| Torrent sources are unavailable in 32-bit Android processes (many Android TV / Google TV devices) and on Windows | Android TV, Google TV, Windows | `TorrentSupport` in [`torrent_source_preparer.dart`](../../lib/src/services/torrent_source_preparer.dart) | The streamer's native library is built for `arm64-v8a` and `x86_64` only |
| Release APKs contain ARM code only | Android | [`android/app/build.gradle.kts`](../../android/app/build.gradle.kts) | Real x86_64 Android devices cannot run release builds; debug builds keep x86_64 for emulators |
| Embedded subtitle tracks are only offered when libmpv plays the stream | Android | `_bindEmbeddedSubtitles` in [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) | Media3 does not expose text tracks through package:video_player |
| libmpv's OpenGL output cannot start on Android emulators; Reelish uses MediaCodec output there, which intermittently never presents a surface | Android emulators | `PlayerEngineBootstrap` in [`player_engine.dart`](../../lib/src/services/player_engine.dart); [`player_long_session_test.dart`](../../integration_test/player_long_session_test.dart) | Real devices are unaffected; libmpv tests skip themselves on emulators |
| A provider script stuck in native QuickJS code on a build without the interrupt export keeps its isolate running after the 45 s hard timeout | Builds lacking `JS_SetInterruptHandler` | `ProviderRunner.hardTimeout` in [`provider_runner.dart`](../../lib/src/services/provider_runner.dart) | The shipped Android runtime and Windows DLL export it (CI checks the DLL); the runtime slot is freed either way |
| The Windows build is not code-signed, so SmartScreen may warn before the first launch | Windows | Root [README](../../README.md#windows) | Update verification accepts `valid` or `unsigned` installers and refuses invalid signatures |
| Up to 15 s of progress can be lost if the app is killed while playing | All | `_tick` in [`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) | Progress is also saved on pause and on close |
| A series saved before per-episode progress was recorded shows no progress in Continue watching | All | [`resume_summary.dart`](../../lib/src/models/resume_summary.dart) | Deliberate: progress is never estimated |
| Picture-in-picture, brightness and rotation are not available on TV and Windows | Android TV, Windows | `DeviceCapabilities`, [`docs/windows.md`](../windows.md) | |

Platform-specific limitations are also listed in
[`docs/android_tv.md`](../android_tv.md#known-limitations) and
[`docs/windows.md`](../windows.md).

## Documentation gaps found while writing these docs

- `GitHubUpdateService`'s class comment says it checks for and installs
  APKs only, but the class also downloads and verifies Windows installers
  and ZIPs (it branches on the platform). The generated references use a
  corrected, hand-written purpose for its file.
- Some older audit reports in `docs/` and `docs/security/` name files that
  no longer exist; they are marked as historical records.
