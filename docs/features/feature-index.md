# Feature index

Every user-facing feature, A–Z, mapped to the code that implements it. Each
section says where it starts, which UI and services implement it, where its
state and data live, and which tests cover it. Tests are in
[`test/`](../../test) unless the path says otherwise.

| Feature | Primary implementation | Supporting components |
|---|---|---|
| [Audio and video tracks](#audio-and-video-tracks) | `CustomVideoPlayer._applyPreferredAudio`, `_applyPreferredVideoTrack` | `AudioTrackSheet`, `PlayerSettingsSheet`, `selectPreferredVideoHeight` |
| [Continue watching and resume](#continue-watching-and-resume) | `HomeViewModel.loadHistory`, `CustomVideoPlayer._saveProgress` / `_startPosition` | `StorageService`, `ResumeSummary`, `DesktopResumeShelf` |
| [Details pages](#details-pages) | `DetailsViewModel` | `MediaDetailsScreen`, `TvMediaDetailsScreen`, `DesktopDetailsScreen` |
| [Episode navigation](#episode-navigation) | `EpisodeContext`, `CustomVideoPlayer._playEpisode` | `EpisodePanel`, `NextEpisodeCard`, `EpisodeHandOff` |
| [First-run consent and legal](#first-run-consent-and-legal) | `FirstRunConsentScreen` | `LegalInformationScreen`, `CreditsScreen` |
| [Home catalog rows](#home-catalog-rows) | `HomeViewModel`, `PagedFeedController` | `TmdbService`, `media_catalog_rules.dart`, `media_discovery_ranking.dart` |
| [My list (favorites)](#my-list-favorites) | `HomeViewModel.toggleFavorite` | `StorageService.toggleFavorite`, card heart actions |
| [Playback](#playback) | `HomeScreen._openItem`, `CustomVideoPlayer` | `PlaybackCoordinator`, `PlayerEngineFactory`, `SourcePreparer` |
| [Player controls](#player-controls) | `PlayerControlsOverlay` | `PlayerProgressBar`, `ReelishPausedOverlay`, `PlayerLockOverlay`, `GestureTouchLayer` |
| [Plugin Library](#plugin-library) | `PluginLibraryScreen`, `PluginLibraryRepository` | `PluginLibraryService`, `PluginLibraryQuery`, `lib/src/widgets/plugin_library/` |
| [Provider repositories](#provider-repositories) | `ProviderPluginService` | `PluginsScreen`, `DesktopPluginsPage`, `ProviderInstallerModal` |
| [Search](#search) | `SearchViewModel`, `HomeScreen._loadSearch` | `TvSearchPage`, `DesktopSearchPage`, `TmdbService` |
| [Settings](#settings) | `SettingsScreen`, `DesktopSettingsPage` | `PlaybackSettingsController`, `AccentSettingsController`, `SubtitleAddonsScreen` |
| [Source selection](#source-selection) | `StreamDiscovery`, `StreamSelectorSheet` | `PlaybackSettings` (automatic selection, reuse last link), `isPlaybackSourceAllowed` |
| [Spotlight](#spotlight) | `DesktopHero` (Windows), `HomeScreen._featured` (phone), `TvBrowseFrame` (TV) | `TmdbService.spotlight`, `MediaDiscoveryRanking` |
| [Subtitles](#subtitles) | `SubtitleAddonService`, `SubtitleLoader` | `SubtitlePickerSheet`, `ExternalCueClock`, `SubtitlePositionPanel` |
| [Top 10](#top-10) | `HomeViewModel.top10` | `DesktopTopTenRow`, `MediaDiscoveryRanking.recommendations` |
| [Torrent (P2P) playback](#torrent-p2p-playback) | `TorrentSourcePreparer` | `TorrentSupport`, `flutter_go_torrent_streamer` |
| [TV interface](#tv-interface) | `TvHomeShell` | `TvFocusable`, `TvSafeArea`, TV pages |
| [Updates](#updates) | `GitHubUpdateService`, `WindowsUpdateController` | `AppUpdateFlow`, update dialogs, `WindowsInstallation` |
| [Windows interface](#windows-interface) | `DesktopShell` | `DesktopShortcuts`, `DesktopGamepad`, `DesktopWindow`, desktop pages |

---

## Audio and video tracks

Picks the audio language and video resolution the viewer prefers when a
source opens, and lets them switch in the player.
**Entry:** `CustomVideoPlayer._initialize` (tracks queried for up to 2 s).
**UI:** [`audio_track_sheet.dart`](../../lib/src/widgets/player/audio_track_sheet.dart),
[`player_settings_sheet.dart`](../../lib/src/widgets/player/player_settings_sheet.dart).
**Logic:** [`video_quality_selector.dart`](../../lib/src/services/video_quality_selector.dart).
**State:** player session; preferences in `PlaybackSettings`.
**Tests:** `player_settings_sheet_test`, `playback_settings_test`.

## Continue watching and resume

Started titles, most recent first, with real progress; playback resumes
where it stopped, a series in the episode watched last.
**Entry:** `HomeViewModel.loadHistory`
([`home_view_model.dart`](../../lib/src/viewmodels/home_view_model.dart)).
**UI:** phone and TV rows in Home; Windows sidebar (`DesktopResumeShelf` in
[`desktop_shell.dart`](../../lib/src/desktop/desktop_shell.dart), resume
via `HomeScreen._resumeFromSidebar`); library pages.
**Data:** `onfeed.history` and `onfeed.history.episodes.v1` via
[`storage_service.dart`](../../lib/src/services/storage_service.dart);
card text from [`resume_summary.dart`](../../lib/src/models/resume_summary.dart).
**Saving:** every 15 s, on pause, on close
(`CustomVideoPlayer._saveProgress`).
**Modify safely:** keep old history JSON readable (see
[configuration reference](../reference/configuration-reference.md#stored-data)).
**Tests:** `continue_watching_test`, `home_view_model_test`,
`episode_selection_test`, `desktop_ui_test`, `desktop_home_top_ten_test`.

## Details pages

Synopsis, genres, runtime, cast, related titles, seasons and episodes, and
Play/Episodes, My list actions.
**Entry:** `HomeScreen._showDetails`.
**UI:** [`media_details_screen.dart`](../../lib/src/screens/media_details_screen.dart),
[`tv_details_screen.dart`](../../lib/src/screens/tv/tv_details_screen.dart),
[`desktop_details_screen.dart`](../../lib/src/desktop/desktop_details_screen.dart).
**State:** [`details_view_model.dart`](../../lib/src/viewmodels/details_view_model.dart).
**Tests:** `details_screens_test`, `details_view_model_test`,
`desktop_redesign_test`.

## Episode navigation

Episode panel in the player, Previous/Next, the next-episode card and its
8 s auto-play countdown.
**Entry:** `CustomVideoPlayer._playEpisode` (the only path), which calls
`HomeScreen._openItem` with an `EpisodeHandOff`.
**Model:** [`episode_context.dart`](../../lib/src/models/episode_context.dart).
**UI:** [`episode_panel.dart`](../../lib/src/widgets/player/episode_panel.dart),
`NextEpisodeCard` in [`player_controls.dart`](../../lib/src/widgets/player/player_controls.dart).
**Tests:** `episode_context_test`, `episode_selection_test`.

## First-run consent and legal

The privacy policy and terms must be accepted on first launch; legal text,
third-party notices and credits are always available.
**Entry:** `_StartupScreen` in [`main.dart`](../../lib/main.dart).
**UI:** [`first_run_consent_screen.dart`](../../lib/src/screens/first_run_consent_screen.dart),
[`legal_information_screen.dart`](../../lib/src/screens/legal_information_screen.dart),
[`credits_screen.dart`](../../lib/src/screens/credits_screen.dart),
[`app_information_screens.dart`](../../lib/src/screens/app_information_screens.dart).
**Data:** `reelish.legal.documentsAccepted.v1`.
**Tests:** `widget_test`, `settings_ui_test`.

## Home catalog rows

New movies, Series worth the queue, New releases, Top 10 and Trending.
**Entry:** `HomeViewModel` constructor (one `PagedFeedController` per row).
**Logic:** [`paged_feed_controller.dart`](../../lib/src/services/paged_feed_controller.dart),
[`tmdb_service.dart`](../../lib/src/services/tmdb_service.dart),
[`media_catalog_rules.dart`](../../lib/src/services/media_catalog_rules.dart),
[`media_discovery_ranking.dart`](../../lib/src/services/media_discovery_ranking.dart).
**UI:** `HomeScreen._pagedRow` (phone), `TvPagedRow`, `DesktopPagedRow`.
**Data:** TMDB responses cached on disk ([`tmdb_response_cache.dart`](../../lib/src/services/tmdb_response_cache.dart)).
**Tests:** `paged_feed_controller_test`, `tmdb_catalog_service_test`,
`tmdb_scalability_test`, `media_catalog_rules_test`,
`media_discovery_ranking_test`, `home_startup_budget_test`.

## My list (favorites)

Save titles from cards and details pages; shown in the library.
**Entry:** `HomeViewModel.toggleFavorite` (Home's pages) and
`LibraryViewModel.toggleFavorite`.
**Data:** `onfeed.favorites` via `StorageService.toggleFavorite`.
**Tests:** `desktop_remove_favorites_test`, `search_library_view_models_test`,
`desktop_home_top_ten_test`.

## Playback

Find a source with the installed providers and play it, recovering from
failures. Described in full in
[playback architecture](../playback/playback-architecture.md).
**Entry:** `HomeScreen._openItem`.
**Logic:** [`playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart),
[`player_engine.dart`](../../lib/src/services/player_engine.dart),
[`source_preparer.dart`](../../lib/src/services/source_preparer.dart).
**UI:** [`player_screen.dart`](../../lib/src/screens/player_screen.dart),
[`custom_video_player.dart`](../../lib/src/widgets/player/custom_video_player.dart).
**Tests:** `playback_pipeline_test`, `playback_reliability_test`,
`stream_source_test`, `app_reliability_test`; integration tests in
[`integration_test/`](../../integration_test).

## Player controls

Play/pause, seek bar, skip, speed (and hold for speed), fit, lock, pause
screen, buffering and error views, desktop keys and mouse, TV remote.
**UI:** [`player_controls.dart`](../../lib/src/widgets/player/player_controls.dart),
[`player_progress_bar.dart`](../../lib/src/widgets/player/player_progress_bar.dart),
[`paused_overlay.dart`](../../lib/src/widgets/player/paused_overlay.dart),
[`player_lock_overlay.dart`](../../lib/src/widgets/player/player_lock_overlay.dart),
[`gesture_touch_layer.dart`](../../lib/src/widgets/player/gesture_touch_layer.dart).
**Tests:** `player_ui_test`, `paused_overlay_test`;
[`windows_player_ui_test.dart`](../../integration_test/windows_player_ui_test.dart).

## Plugin Library

Browse and search a community catalog of provider repositories, filter by
language and content type, and install one.
**Entry:** Plugins → Browse; `PluginLibraryRepository` (loaded on first open).
**Logic:** [`plugin_library_service.dart`](../../lib/src/services/plugin_library_service.dart)
(network → device cache → bundled `assets/data/plugins.json`),
[`plugin_library_query.dart`](../../lib/src/services/plugin_library_query.dart),
[`plugin_catalog.dart`](../../lib/src/models/plugin_catalog.dart).
**UI:** [`plugin_library_screen.dart`](../../lib/src/screens/plugin_library_screen.dart),
[`plugin_details_screen.dart`](../../lib/src/screens/plugin_details_screen.dart),
[`lib/src/widgets/plugin_library/`](../../lib/src/widgets/plugin_library).
**Catalog updates:** `dart run tool/generate_plugin_catalog.dart`.
**Tests:** `plugin_library_test`.

## Provider repositories

Install repositories from a manifest URL or the library, enable providers,
approve changed scripts.
**Logic:** [`provider_plugin_service.dart`](../../lib/src/services/provider_plugin_service.dart);
see [provider integration](../playback/provider-integration.md).
**UI:** [`plugins_screen.dart`](../../lib/src/screens/plugins_screen.dart),
[`desktop_plugins_page.dart`](../../lib/src/desktop/desktop_plugins_page.dart),
[`provider_installer_modal.dart`](../../lib/src/widgets/provider_installer_modal.dart).
**Data:** `onfeed.nuvio.plugin.repositories`, `onfeed.nuvio.plugin.enabled`,
`onfeed.plugin.scriptHashes.v1`, `onfeed.plugin.knownScripts.v1`, cached
manifests file.
**Tests:** `provider_repository_state_test`, `desktop_settings_plugins_test`.

## Search

TMDB title search.
**Phone:** inline on Home (`HomeScreen._searchChanged`, `_loadSearch`).
**TV and Windows:** [`search_view_model.dart`](../../lib/src/viewmodels/search_view_model.dart)
in `TvSearchPage` and `DesktopSearchPage` (Ctrl+F on Windows).
**Tests:** `search_library_screens_test`, `search_library_view_models_test`.

## Settings

Playback (sources, providers allowed, P2P, subtitles, gestures, next
episode), appearance (accent), subtitle addons, About and updates, legal.
**UI:** [`playback_settings_screen.dart`](../../lib/src/screens/playback_settings_screen.dart)
(phone and TV), [`desktop_settings_page.dart`](../../lib/src/desktop/desktop_settings_page.dart)
(Windows, reusing the sub-pages), [`subtitle_addons_screen.dart`](../../lib/src/screens/subtitle_addons_screen.dart).
**State:** [`playback_settings_controller.dart`](../../lib/src/services/playback_settings_controller.dart),
[`accent_settings_controller.dart`](../../lib/src/services/accent_settings_controller.dart).
**Data:** `onfeed.playback.settings.v1`, `onfeed.appearance.accent`.
**Tests:** `settings_ui_test`, `playback_settings_test`,
`desktop_settings_plugins_test`.

## Source selection

Which source plays: the first good one automatically, or the viewer's pick
from a list that keeps filling while providers answer.
**Logic:** `StreamDiscovery.startingSource`; with automatic selection off,
`StreamSelectorSheet` after all providers answer or the selection timeout;
`Reuse last link` reads `StorageService.lastStream`.
**UI:** [`stream_selector_sheet.dart`](../../lib/src/widgets/player/stream_selector_sheet.dart).
**Tests:** `stream_discovery_test`, `playback_reliability_test`.

## Spotlight

Featured titles at the top of Home.
**Phone:** a rotating carousel in `HomeScreen._featured` (6 s).
**TV:** the focused title in `TvBrowseFrame` (follows focus, no rotation).
**Windows:** [`desktop_hero.dart`](../../lib/src/desktop/desktop_hero.dart):
full-bleed backdrop, actions, a looping "In the Spotlight" rail, 8 s
rotation.
**Data:** `TmdbService.spotlight` over page 1 of Movies and Series.
**Tests:** `desktop_redesign_test`, `tv_home_test`.

## Subtitles

Provider tracks, Stremio subtitle addons (OpenSubtitles v3 preinstalled)
and embedded tracks (libmpv), drawn by Reelish's own renderer.
**Logic:** [`subtitle_addon_service.dart`](../../lib/src/services/subtitle_addon_service.dart),
[`subtitle_loader.dart`](../../lib/src/services/subtitle_loader.dart),
[`subtitle_language.dart`](../../lib/src/models/subtitle_language.dart).
**UI:** [`subtitle_picker_sheet.dart`](../../lib/src/widgets/player/subtitle_picker_sheet.dart),
[`subtitle_position_panel.dart`](../../lib/src/widgets/player/subtitle_position_panel.dart),
[`external_cue_clock.dart`](../../lib/src/widgets/player/external_cue_clock.dart).
**Data:** `onfeed.subtitleAddons.v1`, `onfeed.player.subtitleChoice.v1`.
**Tests:** `subtitles_test`, `external_cue_clock_test`.

## Top 10

Ten recommendations seeded from the best movie and series on page 1 of the
catalog, ranked with vote-weighted scores.
**Logic:** `HomeViewModel._fetchTop10Page`,
`MediaDiscoveryRanking.recommendations`.
**UI:** Home rows; [`desktop_top_ten.dart`](../../lib/src/desktop/desktop_top_ten.dart) on Windows.
**Tests:** `desktop_top_ten_test`, `desktop_home_top_ten_test`.

## Torrent (P2P) playback

Compatible providers may return torrent sources on 64-bit Android.
**Logic:** [`torrent_source_preparer.dart`](../../lib/src/services/torrent_source_preparer.dart),
[`packages/flutter_go_torrent_streamer/`](../../packages/flutter_go_torrent_streamer).
**Data:** torrent cache folder (5 GiB cap), `onfeed.torrent.clearPending`.
**Tests:** `torrent_source_preparer_test`;
[`torrent_streamer_test.dart`](../../integration_test/torrent_streamer_test.dart).

## TV interface

See [Android TV](../platforms/android-tv.md).
**Tests:** `tv_home_test`, `tv_layout_test`, `tv_support_test`.

## Updates

Android: APK from GitHub Releases, verified, handed to the package
installer. Windows: installer or ZIP, verified, installed on request.
**Logic:** [`github_update_service.dart`](../../lib/src/services/github_update_service.dart),
[`windows_update_controller.dart`](../../lib/src/services/windows_update_controller.dart),
[`update_config.dart`](../../lib/src/services/update_config.dart).
**UI:** [`app_update_flow.dart`](../../lib/src/widgets/app_update_flow.dart),
[`update_dialog.dart`](../../lib/src/widgets/update_dialog.dart),
[`desktop_update_dialogs.dart`](../../lib/src/desktop/desktop_update_dialogs.dart),
[`desktop_update_section.dart`](../../lib/src/desktop/desktop_update_section.dart).
**Data:** `onfeed.update.github.*`, `onfeed.update.windows.*`.
**Tests:** `github_update_check_test`, `windows_update_test`;
[`windows_update_channel_test.dart`](../../integration_test/windows_update_channel_test.dart).

## Windows interface

See [Windows](../platforms/windows.md).
**Tests:** `desktop_ui_test`, `desktop_gamepad_test`,
`desktop_redesign_test`, `desktop_settings_plugins_test`.
