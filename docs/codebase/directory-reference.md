# Directory reference

Every folder that matters, A–Z by path. `lib/` folders are described in
more depth in the [file reference](file-reference.md), and how they depend
on each other is in the [dependency map](dependency-map.md).

| Directory | Purpose | Platform |
|---|---|---|
| [`.claude/skills/`](../../.claude/skills) | Task guides for AI coding agents (architecture, playback, providers, UI, Windows, regressions, performance, security, releases); [`CLAUDE.md`](../../CLAUDE.md) is their rulebook | Tooling |
| [`.github/workflows/`](../../.github/workflows) | `release.yml` (APK) and `release-windows.yml` (installer and ZIP), triggered by a `v*` tag | CI |
| [`android/`](../../android) | Gradle project, `MainActivity.kt`, manifest, launcher and TV banner resources | Android, Android TV |
| [`assets/data/`](../../assets/data) | `plugins.json`, the bundled copy of the community plugin catalog | Shared |
| [`assets/fonts/`](../../assets/fonts) | Montserrat and its licence | Shared |
| [`assets/icons/`](../../assets/icons) | App icon | Shared |
| [`assets/images/`](../../assets/images) | README screenshots and the TMDB logo | Shared |
| [`assets/js/`](../../assets/js) | `cheerio_bundle.js`: Cheerio and CryptoJS for provider scripts | Shared |
| `build/` | Build output (ignored) | — |
| [`docs/`](..) | This documentation, plus guides and audit records | — |
| [`integration_test/`](../../integration_test) | Tests that drive the real app or engines on a device, emulator or Windows | Per test |
| `ios/`, `linux/`, `macos/`, `web/` | Generated Flutter platform folders; not shipped | — |
| [`lib/`](../../lib) | The app: `main.dart` and `src/` | Shared |
| [`lib/src/app/`](../../lib/src/app) | `AppServices`, the services container | Shared |
| [`lib/src/desktop/`](../../lib/src/desktop) | The Windows interface | Windows |
| [`lib/src/models/`](../../lib/src/models) | Data types: media, sources, progress, settings, plugins, updates | Shared |
| [`lib/src/navigation/`](../../lib/src/navigation) | `TvDestination` and the shared route transitions | Shared |
| [`lib/src/platform/`](../../lib/src/platform) | Device detection, Windows window, shortcuts, gamepad and installation | Shared, Windows |
| [`lib/src/screens/`](../../lib/src/screens) | Phone screens and screens shared with TV (Plugins, Settings, legal, About) | Android, shared |
| [`lib/src/screens/tv/`](../../lib/src/screens/tv) | The TV interface: shell, pages, details | Android TV |
| [`lib/src/services/`](../../lib/src/services) | Business logic and I/O: TMDB, storage, providers, playback, subtitles, updates | Shared |
| [`lib/src/theme/`](../../lib/src/theme) | `GlassTheme` | Shared |
| [`lib/src/viewmodels/`](../../lib/src/viewmodels) | `ChangeNotifier` view models shared by every interface | Shared |
| [`lib/src/widgets/`](../../lib/src/widgets) | Shared and phone widgets: cards, glass, dock, dialogs | Shared, Android |
| [`lib/src/widgets/player/`](../../lib/src/widgets/player) | The player UI and its sheets and overlays | Shared |
| [`lib/src/widgets/plugin_library/`](../../lib/src/widgets/plugin_library) | Plugin Library cards, filters, badges, notices | Shared |
| [`lib/src/widgets/settings/`](../../lib/src/widgets/settings) | Settings layout components and TMDB attribution | Shared |
| [`lib/src/widgets/tv/`](../../lib/src/widgets/tv) | TV focus helpers and poster card | Android TV |
| [`packages/flutter_go_torrent_streamer/`](../../packages/flutter_go_torrent_streamer) | Vendored Go torrent streamer (Android); see its `REELISH_PATCH.md` | Android |
| [`packages/video_player_media_kit/`](../../packages/video_player_media_kit) | Vendored libmpv bridge for package:video_player (Windows frame-request patch, see [`docs/windows.md`](../windows.md)) | Android, Windows |
| [`test/`](../../test) | Unit and widget tests; `flutter_test_config.dart` preloads the QuickJS library | Shared |
| [`test_driver/`](../../test_driver) | The `flutter drive` driver for integration tests (frame timings) | — |
| [`third_party/flutter_js/`](../../third_party/flutter_js) | Vendored QuickJS for Flutter with Reelish's patch (memory limit, interrupt, quiet release logs) | Shared |
| [`tool/`](../../tool) | `generate_plugin_catalog.dart`, `build_quickjs_bridge_windows.ps1`, `branding/` (platform brand assets from `assets/icons/`), and [`tool/docs/docs_tool.dart`](../../tool/docs/docs_tool.dart) (these references) | Tooling |
| [`windows/`](../../windows) | Windows runner (`runner/`), CMake project, Inno Setup script (`installer/reelish.iss`) | Windows |
