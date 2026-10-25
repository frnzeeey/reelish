# Third-party dependencies

Every package in [`pubspec.yaml`](../../pubspec.yaml), why it is there and
where it is used. The files that import each package are listed by the
generated [dependency map](../codebase/dependency-map.md#package-usage).

## Runtime

| Dependency | Purpose | Used in | Configuration |
|---|---|---|---|
| `crypto` | SHA-256 of provider scripts and update files | `provider_plugin_service.dart`, `github_update_service.dart` | — |
| `flutter_go_torrent_streamer` (vendored, [`packages/flutter_go_torrent_streamer`](../../packages/flutter_go_torrent_streamer)) | Go torrent engine that serves a torrent's file on a loopback URL | `torrent_source_preparer.dart` | Built for `arm64-v8a` and `x86_64` by its `go/build_android.ps1`; see its `REELISH_PATCH.md` |
| `flutter_js` (vendored, [`third_party/flutter_js`](../../third_party/flutter_js)) | QuickJS runtime for provider scripts | `provider_runner.dart`, `provider_fetch_bridge.dart` | Reelish patch: memory limit, interrupt deadline, quiet release logs ([`REELISH_PATCH.md`](../../third_party/flutter_js/REELISH_PATCH.md)); Windows DLL from [`tool/build_quickjs_bridge_windows.ps1`](../../tool/build_quickjs_bridge_windows.ps1) |
| `http` | HTTP for TMDB, manifests, scripts, subtitles, updates | services | Destinations for untrusted URLs go through `NetworkDestinationValidator` |
| `material_symbols_icons` | Icons | UI files | — |
| `media_kit_libs_android_video` | libmpv native libraries for Android | engine fallback | Loaded lazily by `MpvPlayerEngine.activate` |
| `media_kit_libs_windows_video` | libmpv native libraries for Windows | the Windows player | The only Windows engine |
| `package_info_plus` | Installed version | `AppMetadata`, update checks | — |
| `path_provider` | App files and cache folders | `StorageService` (manifests, last streams, torrent cache), `TmdbResponseCache`, `PluginLibraryService`, `GitHubUpdateService` | — |
| `shared_preferences` | On-device key-value storage | `StorageService`, preference readers | Keys in the [configuration reference](configuration-reference.md#stored-data) |
| `url_launcher` | Opening links (legal, credits, support) | screens | — |
| `video_player` | The controller API the player UI drives | `player_engine.dart`, player widgets | One app-wide platform instance; see the engine gate |
| `video_player_android` | Media3 (ExoPlayer) on Android | `Media3PlayerEngine` | Never replace an active instance |
| `video_player_media_kit` (vendored, [`packages/video_player_media_kit`](../../packages/video_player_media_kit)) | Bridges video_player to libmpv (media_kit) | `MpvPlayerEngine` | Windows frame-request patch, see [`docs/windows.md`](../windows.md) |
| `video_player_platform_interface` | Selecting the platform instance | `player_engine.dart` | — |

## Development

| Dependency | Purpose |
|---|---|
| `flutter_test`, `integration_test` | Unit, widget and integration tests |
| `flutter_lints` | Lint rules ([`analysis_options.yaml`](../../analysis_options.yaml)) |
| `flutter_launcher_icons` | Generates the Android launcher icon from `assets/icons/reelish_icon.png` |

## Bundled assets with their own licences

- Montserrat font ([`assets/fonts/Montserrat-OFL.txt`](../../assets/fonts/Montserrat-OFL.txt)).
- Cheerio and CryptoJS in [`assets/js/cheerio_bundle.js`](../../assets/js/cheerio_bundle.js).
- The TMDB logo, used under TMDB's attribution rules
  ([`tmdb_attribution.dart`](../../lib/src/widgets/settings/tmdb_attribution.dart)).

Credits shown in the app: [`credits_screen.dart`](../../lib/src/screens/credits_screen.dart).

## Upgrading safely

1. One dependency per change; read its changelog.
2. Player packages (`video_player*`, `media_kit_libs_*`, the vendored
   bridge): run `playback_pipeline_test`, `playback_reliability_test`, and
   on devices `libmpv_playback_test`, `player_long_session_test`,
   `windows_playback_test`, `windows_soak_test`.
3. `flutter_js`: re-apply the patch, verify the native symbol names on
   every runtime (Android library, Windows DLL), run `provider_runner_test`,
   `quickjs_windows_limits_test` and `provider_runtime_test`.
4. The torrent streamer: rebuild the native libraries and run
   `torrent_streamer_test` on a device.
5. `shared_preferences`: confirm existing keys still read back
   (viewers' data).
6. Flutter itself: change `FLUTTER_VERSION` in both workflows and run the
   full [validation](../development/testing-guide.md#before-a-commit) on
   every platform.
