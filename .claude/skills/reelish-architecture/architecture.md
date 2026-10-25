# Reelish architecture reference

Verified against the code; open the files when details matter. Paths are
relative to the repository root.

## Layers

| Layer | Where | Notes |
|---|---|---|
| Entry | `lib/main.dart` | `ReelishApp`, startup screen, first-run consent |
| Services container | `lib/src/app/app_services.dart` | `AppServices`, owned by Home; tests pass their own `tmdb`/`storage` |
| ViewModels | `lib/src/viewmodels/` | `ChangeNotifier`s shared by all three UIs: `HomeViewModel`, `DetailsViewModel`, `LibraryViewModel`, `SearchViewModel`; `TvCatalog` (`home_catalog.dart`) is Home's data handed to TV and Windows pages |
| Services | `lib/src/services/` | TMDB, storage, providers, playback, updates, settings |
| Models | `lib/src/models/` | `MediaItem`, `StreamSource`, `PlayableSource`, `EpisodeProgress`/`SeriesProgress`, `ProviderPlugin`/`ProviderRepository`, … |
| Phone UI | `lib/src/screens/`, `lib/src/widgets/` | `HomeScreen` tabs + `SoftGlassDock` |
| TV UI | `lib/src/screens/tv/`, `lib/src/widgets/tv/` | `TvHomeShell`, `TvFocusable`, `TvSafeArea`, `TvTextEntryDialog` |
| Windows UI | `lib/src/desktop/` | `DesktopShell`, `DesktopHero`, desktop pages, `DesktopDetailsScreen`, `DesktopSettingsPage`, `DesktopPluginsPage` |
| Player UI | `lib/src/widgets/player/` | Shared by all platforms: `CustomVideoPlayer`, `PlayerControlsOverlay`, `PlayerProgressBar`, `ReelishPausedOverlay`, lock overlay, sheets |
| Platform glue | `lib/src/platform/` | `DeviceCapabilities`, `DesktopWindow`/`DesktopShortcuts`, `DesktopGamepad`, `windows_installation.dart` |
| Theme | `lib/src/theme/glass_theme.dart` | `GlassTheme.dark` / `.tv`, accent palettes (coral `#FF4D6D` default) |

State is mostly ViewModels + services, but `home_screen.dart` still owns
much orchestration (catalog wiring, `_openItem`, `_showDetails`, the three
`build*` paths). It is not a strict MVVM codebase.

## Platform matrix

| Concern | Phone/tablet | Android TV / Google TV | Windows |
|---|---|---|---|
| Selected by | default | `DeviceCapabilities.isTv` (from `onfeed/device` channel) | `isDesktop` (target platform) |
| `usesTvLayout` | false | true | true |
| Navigation | Dock tabs | `TvHomeShell` sidebar, D-pad | `DesktopShell` sidebar, mouse/keys/gamepad |
| Details | `MediaDetailsScreen` | `TvMediaDetailsScreen` | `DesktopDetailsScreen` |
| Player engine | Media3, libmpv fallback | Media3, libmpv fallback | libmpv only |
| Torrents | 64-bit Android only (`TorrentSupport`) | same; many TV devices are 32-bit | not supported |
| Updates | APK updater (`onfeed/app_update`) | same | `WindowsUpdateController` + installer (`reelish/app_update`) |
| Glass | `LiquidGlass` balanced/high | capped to low | desktop surfaces |

Method channels: `onfeed/device`, `onfeed/player` (brightness, keep screen
on, emulator check, picture-in-picture), `onfeed/app_update` (Android);
`reelish/window`, `reelish/gamepad`, `reelish/app_update` (Windows runner in
`windows/runner/`). Android native code is only `MainActivity.kt`.

The full documentation, including generated A–Z references to every file,
class and function, starts at `docs/README.md`.

## Data flow

**Browsing.** `HomeViewModel` builds one `PagedFeedController` per row
(`lib/src/services/paged_feed_controller.dart`) backed by `TmdbService`
(request limiter, retries, `TmdbResponseCache` on disk with TTLs in
`tmdb_response_cache.dart`). Ranking and filtering rules:
`media_catalog_rules.dart`, `media_discovery_ranking.dart`.

**Library.** `StorageService` (SharedPreferences, writes serialised through
a static queue) holds history with resume points, per-episode progress,
favorites, provider repositories and settings. `LibraryViewModel` and
`HomeViewModel` read it; Home reloads on tab/page return.

**Play.** `HomeScreen._openItem` →
`ProviderPluginService.discoverStreams` (one `StreamDiscovery` per request,
providers run through `ProviderRunner` on background isolates with QuickJS)
→ sources shown or auto-selected (`StreamSelectorSheet`,
`playback_source_policy.dart`) → `PlayerScreen` / `CustomVideoPlayer` →
`PlaybackCoordinator.prepareAndOpen` (`SourcePreparer`, `StreamValidator`,
`StreamNormalizer`, `TorrentSourcePreparer`) → `PlayerEngineFactory`
(`player_engine.dart`) creates the `VideoPlayerController`. Subtitles:
`subtitle_loader.dart`, `subtitle_addon_service.dart`.

**Providers.** `ProviderPluginService` installs repositories (manifests),
caches scripts (`ProviderScriptCache`), tracks script hashes and holds
changed scripts until approved (`pendingScriptUpdates`).
`ProviderFetchBridge` gives scripts `fetch`/XHR backed by Dart HTTP with
`NetworkDestinationValidator` (public addresses only, DNS pinned).
`ProviderExecutionScheduler` bounds concurrency (4 workers, 2 live 64 MiB
runtimes).

## Vendored code

- `packages/video_player_media_kit`: libmpv bridge for video_player
  (Windows frame-request patch, see `docs/windows.md`).
- `packages/flutter_go_torrent_streamer`: Go torrent streamer (Android).
- `third_party/flutter_js`: QuickJS with Reelish patches
  (`third_party/flutter_js/REELISH_PATCH.md`); Windows DLL built by
  `tool/build_quickjs_bridge_windows.ps1`.

## Docs worth reading

`docs/android_tv.md` (TV detection, focus), `docs/windows.md` (Windows
build, tests, differences), `docs/streaming_security.md` (trust boundary,
accepted risk SEC-01), `docs/releasing.md` (release pipeline),
`docs/code_protection.md` (obfuscation). The audit files in `docs/` and
`docs/security/` record past findings and may describe older states.
