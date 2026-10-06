# Reelish production sanity check

**Date:** 2026-10-06
**Branch:** `feature/plugin-library` (uncommitted working tree)
**Builds on:** [production_readiness_audit.md](production_readiness_audit.md) (2026-10-03). Findings from that audit are referenced, not repeated.

**Method and limits.** This is a source-level trace of the real workflows: startup, home, search, details, playback, episode switching, plugins, updates and lifecycle. It also covers `flutter analyze`, `flutter test`, an integration test, release builds, and debug runs on an Android emulator (`sdk_gphone16k_x86_64`, API 37). DevTools profiling and long-session memory measurements were **not** performed. The emulator's decoders and video output differ from a phone's (see PLY-02).

## Overall health

| Area | Score | Notes |
|---|---|---|
| Stability | 8/10 | No crash path found in Dart. Data-loss bugs in plugin state and storage races fixed. |
| Security | 7/10 | Strong Dart-side network policy and pinned provider code. Native media redirects remain an accepted, documented risk (SEC-01). |
| Performance | 7/10 | Lazy lists, sized image decodes, provider work off the UI isolate, deduplicated TMDB requests. Not profiled on device. |
| Memory management | 7/10 | Controllers, timers and subscriptions are disposed. Torrent-session leak fixed. Not measured on device. |
| Networking | 7/10 | Timeouts, size caps, redirect validation, retries with backoff. Offline launch handling fixed. |
| Plugin architecture | 8/10 | Clear service, runtime and scheduler split. Repository state is serialized. Code changes are pinned. |
| Plugin security | 7/10 | Sandboxed JS. Changed code needs approval. Still unsigned (trust on first use), and results can point at any public host. |
| Plugin reliability | 7/10 | Per-provider failure isolation and bounded timeouts. Offline launch recovers. |
| Playback architecture | 7/10 | One player state owns the lifecycle. Torrent setup extracted. The player widget is still large. |
| Playback reliability | 7/10 | Recoverable libmpv decoder messages no longer discard playable sources. A manual engine switch covers black-picture failures. |
| App lifecycle | 7/10 | Timers stop in the background. `video_player` pauses on background. Progress is saved on pause and every 15 s. |
| Code quality | 6/10 | Well commented and well tested on core policies. `custom_video_player.dart` and `home_screen.dart` are still very large. |
| Production readiness | 7/10 | Ready for release once the reinstall note for the new app ID is published. See Remaining risks. |

## Architecture map

```text
main() → PlayerEngineBootstrap (Media3 default; libmpv loaded lazily)
  → ReelishApp (AccentSettingsController)
    → consent gate (FirstRunConsentScreen) → HomeScreen  ← owns every service instance
        ├─ TmdbService ─ TmdbResponseCache (memory 64 + disk, TTLs) ─ request limiter ─ NetworkDestinationValidator
        ├─ StorageService (SharedPreferences: history, favourites, progress, settings, script hashes;
        │                  files/last_streams.v1.json: cached stream links, outside backup)
        ├─ PlaybackSettingsController
        ├─ PluginLibraryRepository → PluginLibraryService (GitHub raw catalog → disk cache → bundled asset)
        └─ ProviderPluginService
             ├─ manifests: _readRepository → _secureGet (HTTPS, DNS-pinned, ≤5 redirects, 4 MiB)
             ├─ ProviderScriptCache (30 min TTL, 24 h stale fallback) → SHA-256 approval (pending updates)
             ├─ ProviderExecutionScheduler (4 workers, 2 QuickJS runtimes)
             └─ ProviderRunner → Isolate.run → QuickJS (64 MiB, 20 s) + ProviderFetchBridge (fetch/XHR only)
                  → StreamNormalizer → StreamValidator → StreamDiscovery (progressive, deduplicated per title/episode)

Play: Details → HomeScreen._openItem (single-flight token)
  → [series] EpisodePanel → ProviderSearchDialog (cancellable)
  → last-link cache or StreamDiscovery.startingSource()
  → PlayerScreen → CustomVideoPlayer
       _initialize (generation + cancellation) → PlaybackCoordinator.prepareAndOpen
         → SourcePreparer (scheme allowlist, DNS preflight) | TorrentSourcePreparer
         → PlayerEngine (Media3 | libmpv) → VideoPlayerController
       _tick → progress (15 s buckets + on pause) → StorageService
       failure → reconnect (2 per 2 min) → other engine (once) → next ranked source (≤5)
       settings → "Switch to …" engine (manual recovery)
       episode switch → EpisodeHandOff → _openItem → release old engine → pushReplacement
```

## Findings

Status: **Fixed** (changed and tested), **Accepted** (documented residual risk), **Open** (not changed).

### Critical

None confirmed. Running remote provider JavaScript is the product's design, not a defect (see Plugin architecture).

### High

#### PLG-01 — Installing during startup could erase every saved repository · Fixed
- **File:** `lib/src/services/provider_plugin_service.dart`, `install`, `remove`, `_load`
- **Problem:** `install` saved `repositories` (the in-memory list) as the stored URL list. That list is empty until the launch load finishes (up to 15 s per manifest), so installing during that window replaced all saved URLs with the new one. Separately, a refresh could undo an install or removal made while it ran.
- **Reproduce:** Launch with repositories A and B installed → open the Plugin Library immediately → install C. Next launch shows only C.
- **Fix:** Load, install and remove run one at a time (`_serialized`). They commit against the saved list, not memory. Duplicate installs are rejected.
- **Validation:** `test/provider_repository_state_test.dart`. On the emulator, the saved list held both URLs after a library install.

#### PLG-02 — "Dismiss" on a load error uninstalled the repository · Fixed
- **File:** `lib/src/screens/plugins_screen.dart`, `_RepositoryError`; service `removeFailed`
- **Problem:** The "Needs attention" ✕ ("Dismiss") deleted the repository URL from storage. Load errors are usually transient (offline launch).
- **Fix:** Load failures show **Retry** and **Remove repository**, and Remove asks for confirmation. Lookup errors keep **Dismiss**, which only hides the message.
- **Validation:** Unit test. On the emulator, offline refresh → Retry/Remove, and Retry recovered once online.

#### PLG-03 — Opening the app offline disabled providers for the whole session · Fixed
- **File:** `provider_plugin_service.dart`, `streams`, `_load`
- **Problem:** A failed launch load left no repositories until a manual refresh, and every play attempt said "No providers are installed". A failed refresh dropped repositories that had loaded fine earlier.
- **Fix:** Lookups retry failed repositories (at most every 30 s). The message is accurate. A failed refresh keeps the copy loaded earlier.
- **Validation:** Unit tests and the emulator (airplane mode).

#### PLY-01 — Torrent session leaked when the player closed during torrent start-up · Fixed
- **Files:** `lib/src/services/torrent_source_preparer.dart` (extracted), `custom_video_player.dart`
- **Problem:** The session was recorded only after `startStream` returned. Back or a source switch during start-up left a native torrent downloading until the process died.
- **Fix:** The generation is checked before and after `startStream` and while metadata loads. A superseded session is stopped.
- **Validation:** On the emulator, Back about 1 s into a torrent start. The engine's data stopped growing at 5.2 MB.

#### PLY-02 — libmpv treated recoverable decoder messages as fatal · Fixed
- **File:** `packages/video_player_media_kit/lib/src/media_kit_video_player.dart`, `player.stream.error` listener
- **Problem:** media_kit sends libmpv's error-level log lines to `stream.error`, and the adapter forwarded each one as a fatal error. One of them, `Could not open codec.` (the hardware decoder failing to open while the software decoder takes over), arrived about 200 ms after video output began. The app then discarded the working source. On the emulator this burned the whole 5-source budget on MobLand S1E1: a 2160p Dolby Vision file and a torrent were both thrown away.
- **Fix:** Before the media opens, errors still fail at once. After it opens, network and stream errors still fail at once. Decoder messages (`codec`/`decod`) are held for 5 s and reported only if playback stalled or the video track was lost. The one exception is MediaCodec output (`vo=mediacodec_embed`, used on emulators), which can only show hardware-decoded frames, so a codec failure there fails at once.
- **Validation:** On the emulator without the MediaCodec exception, libmpv kept playing after the message: position advanced and the check logged `stalled=false videoLost=false`. The emulator's MediaCodec output showed a black picture, though, which is why that mode keeps failing at once. With the exception, the emulator fails over as before. On a phone, libmpv's GPU output displays software frames, so these sources should now play. **Confirm with a 4K HEVC/Dolby Vision source on a phone.**
- **Risk:** Low to medium. Decoder errors that really break playback surface up to 5 s later.

#### SEC-01 — Native playback requests bypass destination validation · Accepted
Native engines resolve DNS again and follow HTTP/HLS/DASH redirects without the Dart private-address policy, so a hostile provider or stream host could make the player request local-network addresses (blind request forgery). This is accepted and documented in `docs/streaming_security.md` ("Accepted risk: native media requests"), with its impact, mitigations and when to revisit. The in-app terms now tell users that the video engine follows redirects chosen by stream hosts.

### Medium

#### PLY-03 — "Searching providers…" could not be cancelled for up to about 60 s · Fixed
- **Files:** `home_screen.dart`, `lib/src/widgets/provider_search_dialog.dart` (extracted)
- **Fix:** A **Cancel** button stops the discovery and returns at once. During an episode switch, the current episode keeps playing.
- **Validation:** On the emulator, Cancel 1 s into a search: no player opened.

#### STO-01 — "Clear torrent cache" never deleted anything; torrent data grew without limit · Fixed
- **Files:** `storage_service.dart`, `playback_settings_screen.dart`, `home_screen.dart`
- **Problem:** flutter_go_torrent_streamer ignores the save path passed to `startStream`. It keeps all data in `<documents>/flutter_torrent_streamer_global` and never deletes it. Clear removed an always-empty folder. The emulator held 396 MB that it couldn't remove.
- **Fix:**
  - Clear deletes the engine's folder: immediately if the engine hasn't started this session, otherwise at the next launch (with a message saying so).
  - At launch, the folder is deleted when its real disk usage (`du`; torrent files are sparse) exceeds 5 GB.
  - The whole folder goes or none of it, so the engine's piece-completion database never describes missing pieces.
  - The settings text explains the limit.
- **Validation:** On the emulator, Clear during a session gave the next-launch message, and relaunch deleted the folder. An early version measured file length and wiped 396 MB of emulator test data on launch; replaced by `du`.

#### AND-02 — Auto Backup included tokens and caches · Fixed
- **Files:** `AndroidManifest.xml`, `res/xml/data_extraction_rules.xml`, `res/xml/backup_rules.xml`, `storage_service.dart`
- **Fix:** Cloud backup and device transfer include only `FlutterSharedPreferences.xml` (history, favourites, installed repositories, settings, script approvals). Cached stream links (signed URLs and provider headers) moved from SharedPreferences to `files/last_streams.v1.json`, which isn't backed up; old entries migrate on the next save. Torrent data and caches are excluded.
- **Validation:** Migration test. The merged manifest has both rules attached.

#### PLG-04 — Provider code could change silently · Fixed
- **Files:** `provider_plugin_service.dart`, `storage_service.dart`, `plugins_screen.dart`, `docs/streaming_security.md`
- **Fix:** SHA-256 pinning with trust on first use. A changed script pauses that provider. The Plugins screen lists "N providers changed their code" under Needs attention with **Allow update**. Removing a repository forgets its approvals.
- **Validation:** Unit test covering first use, a change being paused, approval, persistence across launches, and removal.

#### PLY-04 — Audio over a black picture had no recovery · Fixed (manual)
A rendering failure that raises no error can't be detected reliably (`VideoPlayerValue.size` comes from the track format). Player settings now offer **Switch to the Android player / the compatibility player** when the other engine can open the source. It reopens the source at the current position and uses that engine for the rest of the session. The libmpv adapter also reports decoder messages when the video track is dropped (`videoLost`).
- **Validation:** Widget tests for the sheet. The engine switch reuses the existing engine-fallback path.

#### AND-01 — Template application ID · Fixed
The `applicationId` is now `io.github.frnzeeey.reelish`, and the release workflow reads it from Gradle. **Existing installs (`com.example.onfeed`) can't update in place.** Their in-app updater rejects an APK with a different package, so the release notes must tell those users to install the new app (local history and plugins don't carry over).

### Low

| ID | Area | Issue | Status |
|---|---|---|---|
| PLG-05 | Plugins | Two `load()` calls ran two full manifest loads. | Fixed: calls share the running load |
| PLG-06 | Plugins | Lookup and load errors share one map with different keys. | Mitigated by `failedRepositoryUrls` |
| LIFE-01 | Lifecycle | `notifyListeners()` after `dispose()` when Home is torn down mid-request. | Fixed: guarded; in-flight discoveries cancelled on dispose |
| AND-03 | Android | Unused foreground service and its permissions (from the torrent plugin). | Fixed: removed from the merged manifest (`tools:node="remove"`) |
| STO-02 | Storage | Read-modify-write on history, favourites, progress, subtitle choices and stream links without a lock. | Fixed: serialized |
| PLY-05 | Player | A second rediscovery didn't cancel the first. | Fixed (shared lookups are not cancelled) |
| UI-02 | UI | Repository card `ListTile` inside a coloured box: invisible ripple, repeated debug assertion. | Fixed: transparent `Material`; no assertion on the emulator |
| UI-01 | About | `PackageInfo.fromPlatform()` created in `build`. | Fixed: read once |
| DEP-01 | Dependencies | Plugins applying the Kotlin Gradle Plugin will stop building on future Flutter. | Partly fixed: vendored `flutter_js` migrated to built-in Kotlin. `flutter_go_torrent_streamer` (pub.dev) still applies it and needs an upstream release |
| CODE-02 | Quality | `custom_video_player.dart` and `home_screen.dart` mix orchestration and UI. | Partly fixed: torrent setup and the search dialog extracted. A full split is a separate refactor |

### Informational: verified as sound

- **TMDB.** In-flight deduplication, memory and disk caches with TTLs, a request limiter, bounded retries with jitter and `Retry-After`, 12 s timeout.
- **Search.** 450 ms debounce, plus a request counter that discards stale responses.
- **Rapid episode switching.** Single-flight `_openItem`, `_switchingEpisode`, and the modal search dialog.
- **Player lifecycle.** The generation counter and cancellation completer discard stale opens. Old controllers are disposed before a new engine activates.
- **Next episode.** The offer fires once per player. The old engine is released before the new player opens.
- **Resume.** Saved every 15 s, on pause and on dispose, per episode. History is capped at 50 and series progress at 100.
- **Pause overlay.** Notifier-driven, precached artwork, no second player.
- **Images.** Every `Image.network` sets a cache size.
- **Updates.** Single-flight, throttled, 512 MiB cap, SHA-256 check when a digest is published. The signer and `versionCode` are checked natively.
- **Plugin failure isolation.** Per-provider isolates and error capture. Four workers. 60 s discovery cap.
- **No WebView, no deep links.** The FileProvider isn't exported and is limited to `cache/updates`.

## Plugin architecture

- **Discovery.** The Plugin Library catalog (GitHub `main` → disk cache → bundled asset) or a pasted manifest or GitHub URL.
- **Validation.** HTTPS, public destinations (DNS-pinned), at most 5 validated redirects, 4 MiB, 15 s. CloudStream and add-on manifests are rejected.
- **Installation.** Download and parse first. Then, under the lock, check for duplicates and append to the saved list. A failed download stores nothing.
- **Update.** Manifests refresh every launch and refresh. Scripts refresh after 30 min (24 h stale fallback). Changed script content needs approval (PLG-04).
- **Removal.** Clears the repository, its overrides, approvals and pending updates, and the script cache.
- **Trust model.** JS runs in QuickJS on a background isolate (64 MiB, 20 s), with `fetch`/XHR to public HTTPS hosts and bundled Cheerio/CryptoJS. It has no filesystem, storage, credentials or Dart bindings. A hostile plugin can send the title identifiers anywhere and return streams pointing at public hosts (subject to SEC-01). It can't read app data, install itself, or swap its code without approval.

## Playback architecture

See the architecture map and the verified list. Remaining risk: SEC-01 (accepted). PLY-02 still needs a check on a real phone (the emulator can't show libmpv software frames).

## Validation

| Check | Result |
|---|---|
| `flutter analyze` | No errors or warnings. App code, tests and the adapter: 22 informational notes. Whole tree: 300, almost all in vendored `third_party`. |
| `flutter test` | 310 passed (297 at the start of the audit). |
| `flutter test integration_test -d emulator-5554` | Passed: launch → Plugins → Plugin Library → back. |
| `flutter build apk --release` | Succeeded, 78.7 MB. Only `flutter_go_torrent_streamer` still triggers the Kotlin Gradle Plugin warning. |
| Merged manifest | Package `io.github.frnzeeey.reelish`. Permissions: INTERNET, WAKE_LOCK, REQUEST_INSTALL_PACKAGES, ACCESS_NETWORK_STATE. No foreground service. Backup rules attached. |
| Emulator runs | PLG-01/02/03, PLY-01/02/03, STO-01 and UI-02 verified as described above. |
| DevTools, long session | Not run. |

## Remaining risks

1. **New app ID.** Users of v1.5.0 or earlier must reinstall; their data stays with the old app. Say so in the release notes.
2. **SEC-01.** Accepted and documented.
3. **PLY-02 on phones.** Verified on the emulator only; check a 4K HEVC source on a phone.
4. **DEP-01.** `flutter_go_torrent_streamer` must ship built-in Kotlin support before Flutter drops KGP-applying plugins. Otherwise fork it (about 50 MB of prebuilt native libraries).
5. **Trust on first use.** A repository that is malicious from the start is trusted at install. The install dialog already warns about this.
6. **Plugin catalog.** `assets/data/plugins.json` must be on GitHub `main` for the library's remote refresh; until then the bundled copy is shown.
7. **Large files.** `custom_video_player.dart` (about 2,650 lines) and `home_screen.dart` (about 1,930 lines) still warrant a dedicated refactor.
