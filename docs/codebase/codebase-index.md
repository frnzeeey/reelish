# Codebase index

The components a developer meets first, A–Z (case-insensitive). Every
class, function and file is in the generated references:

- [Class reference](class-reference.md): all 495 types, A–Z, with role,
  location, relations and reach.
- [Function reference](function-reference.md): public functions and
  methods, plus documented private ones, A–Z, with signatures and lines.
- [File reference](file-reference.md): every `lib/` file with purpose,
  imports, importers and tests.
- [Dependency map](dependency-map.md): folder graph, most depended-on files,
  package usage.
- [Directory reference](directory-reference.md): every folder in the
  repository.

[A](#a) · [C](#c) · [D](#d) · [E](#e) · [G](#g) · [H](#h) · [L](#l) ·
[M](#m) · [N](#n) · [P](#p) · [R](#r) · [S](#s) · [T](#t) · [W](#w)

## A

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `AccentSettingsController` | Notifier | [`lib/src/services/accent_settings_controller.dart`](../../lib/src/services/accent_settings_controller.dart) | Loads, applies and saves the accent colour | Shared |
| `AppPageRoute` | Route | [`lib/src/navigation/app_transitions.dart`](../../lib/src/navigation/app_transitions.dart) | The page transition every pushed screen uses | Shared |
| `AppServices` | Services container | [`lib/src/app/app_services.dart`](../../lib/src/app/app_services.dart) | Builds TMDB, storage, provider, plugin-library and playback-settings services for Home | Shared |
| `AppUpdateFlow` | Coordinator | [`lib/src/widgets/app_update_flow.dart`](../../lib/src/widgets/app_update_flow.dart) | The update prompt → download → permission → install flow (APK; Windows start-up check) | Android, Windows |

## C

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `CustomVideoPlayer` | Widget | [`lib/src/widgets/player/custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart) | The player session: engine attempts, recovery, controls, subtitles, tracks, progress, episodes | Shared |

## D

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `DesktopDetailsScreen` | Widget | [`lib/src/desktop/desktop_details_screen.dart`](../../lib/src/desktop/desktop_details_screen.dart) | Windows details page with episode panel | Windows |
| `DesktopGamepad` | Widget | [`lib/src/platform/desktop_gamepad.dart`](../../lib/src/platform/desktop_gamepad.dart) | Game-controller input as focus and action intents | Windows |
| `DesktopHero` | Widget | [`lib/src/desktop/desktop_hero.dart`](../../lib/src/desktop/desktop_hero.dart) | The Spotlight: backdrop, text, actions and the looping rail | Windows |
| `DesktopHomePage` | Widget | [`lib/src/desktop/desktop_pages.dart`](../../lib/src/desktop/desktop_pages.dart) | Windows Home: hero, Top 10 and catalog rows | Windows |
| `DesktopResumeShelf` | Model | [`lib/src/desktop/desktop_shell.dart`](../../lib/src/desktop/desktop_shell.dart) | What the sidebar's Continue watching shows and does | Windows |
| `DesktopShell` | Widget | [`lib/src/desktop/desktop_shell.dart`](../../lib/src/desktop/desktop_shell.dart) | The Windows frame: hover-open sidebar and retained pages | Windows |
| `DesktopShortcuts` | Widget | [`lib/src/platform/desktop_window.dart`](../../lib/src/platform/desktop_window.dart) | F11, Escape and Backspace on every screen | Windows |
| `DetailsViewModel` | View model | [`lib/src/viewmodels/details_view_model.dart`](../../lib/src/viewmodels/details_view_model.dart) | Details, seasons and episodes for every details screen | Shared |
| `DeviceCapabilities` | Platform adapter | [`lib/src/platform/device_capabilities.dart`](../../lib/src/platform/device_capabilities.dart) | Which device this is (`isTv`, `isDesktop`, `usesTvLayout`) | Shared |

## E

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `EpisodeContext` | Model | [`lib/src/models/episode_context.dart`](../../lib/src/models/episode_context.dart) | The playing episode within its series: Previous/Next and auto-play | Shared |
| `EpisodePanel` | Widget | [`lib/src/widgets/player/episode_panel.dart`](../../lib/src/widgets/player/episode_panel.dart) | Season and episode list with progress | Shared |
| `EpisodeProgress` / `SeriesProgress` | Model | [`lib/src/models/episode_progress.dart`](../../lib/src/models/episode_progress.dart) | Per-episode positions and the episode watched last | Shared |

## G

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `GitHubUpdateService` | Service | [`lib/src/services/github_update_service.dart`](../../lib/src/services/github_update_service.dart) | Release checks and verified downloads from GitHub Releases | Android, Windows |
| `GlassTheme` | Theme | [`lib/src/theme/glass_theme.dart`](../../lib/src/theme/glass_theme.dart) | Colours, accent palettes, Material themes | Shared |

## H

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `HomeScreen` | Widget | [`lib/src/screens/home_screen.dart`](../../lib/src/screens/home_screen.dart) | Home and orchestration: the three builds, `_openItem`, `_showDetails` | Shared |
| `HomeViewModel` | View model | [`lib/src/viewmodels/home_view_model.dart`](../../lib/src/viewmodels/home_view_model.dart) | Catalog rows, Top 10 seeds, Continue watching, My list | Shared |

## L

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `LibraryViewModel` | View model | [`lib/src/viewmodels/library_view_model.dart`](../../lib/src/viewmodels/library_view_model.dart) | History, My list and series progress for library pages | Shared |
| `LiquidGlass` | Widget | [`lib/src/widgets/liquid_glass.dart`](../../lib/src/widgets/liquid_glass.dart) | Bounded glass surface with a quality ceiling (low on TV) | Android |

## M

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `Media3PlayerEngine` | Engine | [`lib/src/services/player_engine.dart`](../../lib/src/services/player_engine.dart) | Android Media3 through video_player | Android |
| `MediaDetailsScreen` | Widget | [`lib/src/screens/media_details_screen.dart`](../../lib/src/screens/media_details_screen.dart) | Phone details page | Android |
| `MediaItem` | Model | [`lib/src/models/media_item.dart`](../../lib/src/models/media_item.dart) | A movie or series, with resume data; JSON for storage | Shared |
| `MpvPlayerEngine` | Engine | [`lib/src/services/player_engine.dart`](../../lib/src/services/player_engine.dart) | libmpv through video_player_media_kit | Android, Windows |

## N

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `NetworkDestinationValidator` | Service | [`lib/src/services/network_target_policy.dart`](../../lib/src/services/network_target_policy.dart) | Public destinations only, redirect checks, pinned connections | Shared |

## P

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `PagedFeedController` | Notifier | [`lib/src/services/paged_feed_controller.dart`](../../lib/src/services/paged_feed_controller.dart) | One row's pages with request guards | Shared |
| `PlaybackCoordinator` | Policy | [`lib/src/services/playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart) | Prepare and open, source ranking, attempt budget | Shared |
| `PlaybackFailure` | Model | [`lib/src/services/playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart) | Error classification and user messages | Shared |
| `PlaybackSettings` / `PlaybackSettingsController` | Model / Notifier | [`lib/src/models/playback_settings.dart`](../../lib/src/models/playback_settings.dart), [`lib/src/services/playback_settings_controller.dart`](../../lib/src/services/playback_settings_controller.dart) | The viewer's playback preferences | Shared |
| `PlayerControlsOverlay` | Widget | [`lib/src/widgets/player/player_controls.dart`](../../lib/src/widgets/player/player_controls.dart) | Controls over the video | Shared |
| `PlayerEngineFactory` / `PlayerEngineGate` | Factory / gate | [`lib/src/services/player_engine.dart`](../../lib/src/services/player_engine.dart) | Engine per platform and scheme; no engine switch under a live player | Shared |
| `PlayerScreen` | Widget | [`lib/src/screens/player_screen.dart`](../../lib/src/screens/player_screen.dart) | The route hosting `CustomVideoPlayer` | Shared |
| `PluginLibraryRepository` / `PluginLibraryService` | Service | [`lib/src/services/plugin_library_repository.dart`](../../lib/src/services/plugin_library_repository.dart), [`lib/src/services/plugin_library_service.dart`](../../lib/src/services/plugin_library_service.dart) | The community provider catalog: network, cache, bundle | Shared |
| `ProviderExecutionScheduler` | Service | [`lib/src/services/provider_execution_scheduler.dart`](../../lib/src/services/provider_execution_scheduler.dart) | 4 workers, 2 live runtimes | Shared |
| `ProviderFetchBridge` | Service | [`lib/src/services/provider_fetch_bridge.dart`](../../lib/src/services/provider_fetch_bridge.dart) | `fetch` / XHR for scripts on validated Dart HTTP | Shared |
| `ProviderPluginService` | Notifier | [`lib/src/services/provider_plugin_service.dart`](../../lib/src/services/provider_plugin_service.dart) | Repositories, approval, `discoverStreams` | Shared |
| `ProviderRunner` | Service | [`lib/src/services/provider_runner.dart`](../../lib/src/services/provider_runner.dart) | One isolate and QuickJS runtime per provider run | Shared |

## R

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `ReelishApp` | Widget | [`lib/main.dart`](../../lib/main.dart) | MaterialApp, theme, navigator, Windows input wrappers | Shared |
| `ResumeSummary` | Model | [`lib/src/models/resume_summary.dart`](../../lib/src/models/resume_summary.dart) | Continue watching text and progress, never estimated | Shared |

## S

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `SearchViewModel` | View model | [`lib/src/viewmodels/search_view_model.dart`](../../lib/src/viewmodels/search_view_model.dart) | Debounced TMDB search for TV and Windows | Android TV, Windows |
| `SettingsScreen` | Widget | [`lib/src/screens/playback_settings_screen.dart`](../../lib/src/screens/playback_settings_screen.dart) | Phone and TV settings; sub-pages reused on Windows | Shared |
| `SoftGlassDock` | Widget | [`lib/src/widgets/soft_glass_dock.dart`](../../lib/src/widgets/soft_glass_dock.dart) | Phone and tablet bottom navigation | Android |
| `SourcePreparer` | Service | [`lib/src/services/source_preparer.dart`](../../lib/src/services/source_preparer.dart) | Validates a source before an engine opens it | Shared |
| `SplashGate` | Widget | [`lib/src/screens/splash_screen.dart`](../../lib/src/screens/splash_screen.dart) | Runs startup work behind the splash | Shared |
| `StorageService` | Service | [`lib/src/services/storage_service.dart`](../../lib/src/services/storage_service.dart) | All on-device data; serialised writes | Shared |
| `StreamDiscovery` | Service type | [`lib/src/services/stream_discovery.dart`](../../lib/src/services/stream_discovery.dart) | One progressive provider lookup | Shared |
| `StreamSelectorSheet` | Widget | [`lib/src/widgets/player/stream_selector_sheet.dart`](../../lib/src/widgets/player/stream_selector_sheet.dart) | Manual source choice | Shared |
| `StreamSource` / `PlayableSource` | Model | [`lib/src/models/stream_source.dart`](../../lib/src/models/stream_source.dart), [`lib/src/models/playable_source.dart`](../../lib/src/models/playable_source.dart) | A provider's source; the prepared input for an engine | Shared |
| `SubtitleAddonService` / `SubtitleLoader` | Service | [`lib/src/services/subtitle_addon_service.dart`](../../lib/src/services/subtitle_addon_service.dart), [`lib/src/services/subtitle_loader.dart`](../../lib/src/services/subtitle_loader.dart) | Stremio subtitle addons; download and parse subtitle files | Shared |

## T

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `TmdbResponseCache` / `TmdbCacheTtl` | Service | [`lib/src/services/tmdb_response_cache.dart`](../../lib/src/services/tmdb_response_cache.dart) | Disk cache and lifetimes for TMDB responses | Shared |
| `TmdbService` | Service | [`lib/src/services/tmdb_service.dart`](../../lib/src/services/tmdb_service.dart) | TMDB API client with limiter, retries, in-flight sharing | Shared |
| `TorrentSourcePreparer` / `TorrentSupport` | Service | [`lib/src/services/torrent_source_preparer.dart`](../../lib/src/services/torrent_source_preparer.dart) | Torrent → loopback stream; 64-bit Android only | Android |
| `TvCatalog` | Model | [`lib/src/viewmodels/home_catalog.dart`](../../lib/src/viewmodels/home_catalog.dart) | Home's data handed to TV and Windows pages | Android TV, Windows |
| `TvDestination` | Enum | [`lib/src/navigation/app_destination.dart`](../../lib/src/navigation/app_destination.dart) | Top-level places for the TV rail and Windows sidebar | Android TV, Windows |
| `TvFocusable` | Widget | [`lib/src/widgets/tv/tv_focus.dart`](../../lib/src/widgets/tv/tv_focus.dart) | Focusable target with a visible ring | Android TV |
| `TvHomeShell` | Widget | [`lib/src/screens/tv/tv_home_shell.dart`](../../lib/src/screens/tv/tv_home_shell.dart) | The TV frame: rail and retained pages | Android TV |
| `TvMediaDetailsScreen` | Widget | [`lib/src/screens/tv/tv_details_screen.dart`](../../lib/src/screens/tv/tv_details_screen.dart) | TV details page | Android TV |

## W

| Component | Type | File location | Responsibility | Platform |
|---|---|---|---|---|
| `WindowsInstallation` | Platform adapter | [`lib/src/platform/windows_installation.dart`](../../lib/src/platform/windows_installation.dart) | Installed or portable copy; installer inspection and launch | Windows |
| `WindowsUpdateController` | Notifier | [`lib/src/services/windows_update_controller.dart`](../../lib/src/services/windows_update_controller.dart) | Windows update check, download, verification, handover | Windows |
