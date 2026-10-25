# Configuration reference

Build-time settings, CI secrets (names only), and everything Reelish stores
on the device. Values here are placeholders; real secrets never appear in
the repository or its documentation.

## Local files

| File | Purpose | In git? |
|---|---|---|
| `lib/tmdb_config.local.dart` | `const tmdbApiKey = 'YOUR_TMDB_API_KEY';`, read by `TmdbService`. CI writes it from a secret and deletes it after the build. | No (ignored) |
| Release keystore | Android release signing. Gradle reads `ONFEED_RELEASE_STORE_FILE`, `ONFEED_RELEASE_STORE_PASSWORD`, `ONFEED_RELEASE_KEY_ALIAS` and `ONFEED_RELEASE_KEY_PASSWORD` from Gradle properties or environment variables ([`build.gradle.kts`](../../android/app/build.gradle.kts)); CI restores the keystore from a secret. | No |

## Build-time defines

| Define | Default | Read by | Purpose |
|---|---|---|---|
| `REELISH_FORCE_TV` | `false` | `DeviceCapabilities.forceTv` | Show the TV interface on any device |
| `REELISH_GIT_SHA` | `unknown` | `AppMetadata.gitSha` | Commit shown in About; set by CI |
| `REELISH_BUILD_TAG` | `local` | `AppMetadata.buildTag` | Release tag shown in About; set by CI |

Pass with `--dart-define=NAME=value`.

## Version

`version: MAJOR.MINOR.PATCH+BUILD` in [`pubspec.yaml`](../../pubspec.yaml),
with `BUILD = MAJOR*1000000 + MINOR*1000 + PATCH`. It is the single
version source for Android (`versionCode`) and Windows; tags are
`vMAJOR.MINOR.PATCH`. See [`docs/releasing.md`](../releasing.md#version).

## CI secrets (GitHub Actions)

Names only; set them in the repository's settings.

| Secret | Used for |
|---|---|
| `ONFEED_TMDB_API_KEY` | Writes `lib/tmdb_config.local.dart` for the build |
| `ONFEED_RELEASE_KEYSTORE_BASE64` | The Android release keystore |
| `ONFEED_RELEASE_STORE_PASSWORD`, `ONFEED_RELEASE_KEY_ALIAS`, `ONFEED_RELEASE_KEY_PASSWORD` | Android signing |
| `ONFEED_SYMBOLS_PASSPHRASE` | Encrypts the uploaded debug symbols |

Release builds use `--obfuscate --split-debug-info`; see
[`docs/code_protection.md`](../code_protection.md).

## Runtime configuration in code

| Setting | Where | Value |
|---|---|---|
| Update source, asset names, check interval | [`update_config.dart`](../../lib/src/services/update_config.dart) | GitHub Releases of `frnzeeey/reelish`; `reelish.apk`, `Reelish-Setup-x64.exe`, `Reelish-Windows-x64.zip` |
| TMDB cache lifetimes | `TmdbCacheTtl` in [`tmdb_response_cache.dart`](../../lib/src/services/tmdb_response_cache.dart) | 20 min catalog, 3 min search, 24 h metadata, 7 days identifiers |
| TMDB concurrency | `TmdbService.maxConcurrentRequests` | 4 |
| Provider limits | `ProviderRunRequest`, `ProviderRunner`, `ProviderExecutionScheduler`, `ProviderFetchBridge` | 64 MiB heap; interrupt 40 s; `getStreams` 30 s; hard timeout 45 s; 4 workers, 2 runtimes; 2 MiB bodies; 5 redirects |
| Provider script cache | `ProviderScriptCache` | 30 min; stale copy up to 24 h |
| Playback attempts | `PlaybackCoordinator.maxAutomaticAttempts` | 5 distinct sources |
| Player startup | `CustomVideoPlayer._initialize` | 20 s (7 s for a reused cached link); `play()` 10 s |

## Stored data

SharedPreferences keys (Flutter stores them with a `flutter.` prefix). They
are viewers' data: keep old values loadable, add fields with defaults, and
give a key a new name if its meaning changes.

| Key | Written by | Holds |
|---|---|---|
| `onfeed.appearance.accent` | `AccentSettingsController` | Accent palette id |
| `onfeed.favorites` | `StorageService` | My list (`MediaItem` JSON list) |
| `onfeed.history` | `StorageService` | Watch history with resume position and length (50 most recent) |
| `onfeed.history.episodes.v1` | `StorageService` | Per-episode progress and the episode watched last (100 series) |
| `onfeed.nuvio.plugin.enabled` | `StorageService` | Provider enabled overrides |
| `onfeed.nuvio.plugin.repositories` | `StorageService` | Installed repository URLs |
| `onfeed.playback.lastStreams.v1` | `StorageService` | Legacy location of last-used streams (now a file, below) |
| `onfeed.playback.settings.v1` | `PlaybackSettingsController` | `PlaybackSettings` JSON |
| `onfeed.player.subtitleChoice.v1` | `StorageService` | Remembered subtitle choice per title |
| `onfeed.plugin.knownScripts.v1` | `StorageService` | Script URLs each repository listed at install |
| `onfeed.plugin.scriptHashes.v1` | `StorageService` | SHA-256 of each approved provider script |
| `onfeed.subtitleAddons.v1` | `SubtitleAddonService` | Installed subtitle addons |
| `onfeed.torrent.clearPending` | `StorageService` | Clear torrent data at next start |
| `onfeed.update.github.lastCheckedAt`, `onfeed.update.github.lastResult.v2`, `onfeed.update.github.nextCheckAt.v2` | `GitHubUpdateService` | Update check throttle and last result |
| `onfeed.update.windows.autoCheck`, `onfeed.update.windows.dismissedTag` | `WindowsUpdateController` | Automatic checks; the release "Later" was chosen for |
| `reelish.desktop.sidebarPinned` | `DesktopShell` | Windows sidebar kept open |
| `reelish.desktop.sidebarExpanded` | — | Old sidebar preference, no longer read |
| `reelish.legal.documentsAccepted.v1` | `FirstRunConsentScreen` | Privacy policy and terms accepted |

Files in the app's files folder (`path_provider`):

| File | Holds |
|---|---|
| `provider_manifests.v1.json` | Last downloaded manifest per repository, with HTTP validators (≤ 1 MiB each) |
| `last_streams.v1.json` | Last working stream per title or episode, for "Reuse last link" |
| `updates/` | Downloaded update files |
| Torrent cache folder | Torrent data, capped at 5 GiB |

The TMDB response cache is kept on disk by `TmdbResponseCache` (bounded
number of entries).
