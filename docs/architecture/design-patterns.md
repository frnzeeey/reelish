# Design patterns in use

The patterns Reelish actually uses, where they are, and what to keep when
changing them. Reelish is **not** a strict MVVM or Clean Architecture
codebase: view models exist for the data each screen shows, while
`HomeScreen` still orchestrates navigation and playback.

| Pattern | Where | Why it is there |
|---|---|---|
| Services container | `AppServices` ([`app_services.dart`](../../lib/src/app/app_services.dart)) | One place builds the long-lived services; tests pass their own `TmdbService` and `StorageService` |
| `ChangeNotifier` view models | [`lib/src/viewmodels/`](../../lib/src/viewmodels) | Screen data shared by the phone, TV and Windows layouts; no UI types inside |
| One controller per list | `PagedFeedController` ([`paged_feed_controller.dart`](../../lib/src/services/paged_feed_controller.dart)) | Each row loads, fails and pages on its own |
| Generation numbers | `PagedFeedController`, `HomeViewModel` reads, `CustomVideoPlayer._initializationGeneration`, `SearchViewModel` | A late answer to an older request is dropped instead of overwriting a newer one |
| Request de-duplication | `ProviderPluginService.discoverStreams` (one `StreamDiscovery` per request key), `ProviderScriptCache`, `GitHubUpdateService.checkForUpdate`, TMDB in-flight sharing | Concurrent callers share one network request |
| Serialised writes | `StorageService._serialized` | Read-modify-write of the history list never interleaves |
| Bounded concurrency | `ProviderExecutionScheduler` (4 workers, 2 runtimes), TMDB limiter (4 requests), `ProviderFetchBridge` (4 requests per run) | Many providers or rows cannot exhaust memory or sockets |
| Isolate per untrusted run | `ProviderRunner` ([`provider_runner.dart`](../../lib/src/services/provider_runner.dart)) | Provider scripts never block frames and get a fresh QuickJS runtime each time |
| Strategy (engines) | `PlayerEngine`, `Media3PlayerEngine`, `MpvPlayerEngine`, `PlayerEngineFactory` ([`player_engine.dart`](../../lib/src/services/player_engine.dart)) | The player UI drives one `VideoPlayerController` API whatever engine decodes |
| Gate around a global | `PlayerEngineGate` | package:video_player has one app-wide platform instance; switching engines waits for the other engine's players to close |
| Policy object | `PlaybackCoordinator` ([`playback_coordinator.dart`](../../lib/src/services/playback_coordinator.dart)) | Source ranking, attempt budget and failure classification are testable without widgets |
| Platform flags, not subclasses | `DeviceCapabilities` | One build serves phone, TV and Windows; each screen picks its layout from flags |
| Separate widget per platform | `MediaDetailsScreen` / `TvMediaDetailsScreen` / `DesktopDetailsScreen`, and likewise for Home, Library, Search, Plugins, Settings | Platform UI changes cannot break the other platforms |
| Offstage page retention | `TvHomeShell`, `DesktopShell` | Visited pages keep scroll position; `TickerMode` stops their animations while hidden |
| Fail closed for untrusted input | `NetworkDestinationValidator`, `StreamValidator`, script hash approval | Provider output and URLs are validated before anything acts on them |
| Development-only logging | `PlaybackLog`, `PerfTimeline`, `kDebugMode` checks | Release builds log nothing that could carry stream URLs or tokens |

## Conventions that follow from these

- Put data loading in a view model or service, not in a widget's `build`.
- A new list that pages gets its own `PagedFeedController`.
- Anything async that can be superseded checks a generation or `mounted`
  before applying its result.
- Platform-specific UI goes in that platform's folder; a shared widget that
  must differ checks `DeviceCapabilities` and stays inert elsewhere.
- Never log full stream URLs, headers or cookies; use `PlaybackLog.describe`.

See [coding standards](../development/coding-standards.md) for the rest.
