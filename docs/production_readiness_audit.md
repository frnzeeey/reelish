# Reelish production readiness audit

**Audit date:** 2026-10-03  
**Scope:** Dart/Flutter application, existing tests, local QuickJS fork, Android app configuration, and dependency manifest. This is a source review; native Android playback, device memory, release artifact size, and real provider compatibility were not measured on devices.

## Executive summary

Reelish has unusually strong application-level controls for a provider-driven streaming app: the QuickJS bridge is intentionally narrow, provider work and memory are bounded, Dart HTTP destinations are checked and pinned, response sizes and redirects are limited, TMDB requests are cached/deduplicated, and playback keeps source headers and has bounded source/engine fallback. Home recommendations and New Releases are deferred, grids and poster decoding are lazy/sized, and player/widget resources have explicit cleanup paths.

The primary unresolved production security risk is at the native media boundary. `SourcePreparer` checks a stream's initial DNS answer, then gives its hostname URL to the native player. Native libmpv can resolve again and follow HLS/DASH redirects and segment URLs without the Dart destination policy. A hostile provider or compromised public stream host can therefore bypass the private-address checks for later native requests. This is a confirmed policy gap; exploitability depends on native behavior and the target network and needs device validation. Fixing it without losing real-world provider compatibility requires a controlled native request/proxy design or a documented residual risk.

No confirmed critical crash or unbounded QuickJS execution path was found in the reviewed Dart paths. One concrete reliability/resource issue remains in the GitHub update download: it has no maximum APK size or streamed byte cap. The Android application ID is still `com.example.onfeed`, which is a release identity placeholder and must be replaced with the publisher's chosen permanent ID before publishing.

## Architecture discovered

- **Startup/navigation:** `main.dart` initializes the player backend and starts `ReelishApp`; a consent gate leads to `HomeScreen`. Home owns a tabbed/stacked navigation flow to catalog, plugins, library, settings, title details, and player routes. Shared accent/playback settings use `ChangeNotifier` controllers.
- **State/services:** Stateful screens own presentation state. `StorageService` uses `shared_preferences` for settings, favorite/history records, enabled provider overrides, and a bounded last-stream cache. TMDB and provider execution are service classes rather than injected repositories throughout the app.
- **Catalog/startup:** Home immediately requests movie and TV popular catalogs in parallel. Search and trending replace that path. Recommendations and New Releases are behind deferred section gates. TMDB adds persistent/memory caching, in-flight deduplication, a four-request priority limiter, bounded redirects/responses, and retries with jitter/Retry-After. GitHub update checks are Android-only, run after first frame/resume, and are throttled to six hours.
- **Providers:** `NuvioPluginService` loads user-installed Nuvio JSON manifests, downloads provider scripts at discovery time, selects enabled/media-compatible providers, and runs them with up to four workers and two simultaneous QuickJS runtimes. Provider scripts receive the media identifier/type/season/episode and empty settings. Their only host capabilities are the fetch/XHR bridge and a small `require` allowlist (bundled Cheerio/CryptoJS). There is no filesystem, credential store, native command, or general-purpose Dart binding.
- **QuickJS/network bridge:** The local `flutter_js` fork applies a 20-second synchronous evaluation limit and 64 MiB runtime memory limit. Promise calls, discovery, script/network operations, request concurrency, fetch response/request bodies, and timer count have bounds. `ProviderFetchBridge` manually validates every HTTPS redirect, strips sensitive headers across origins, maintains runtime-local cookies, and closes per-request clients after the bounded operation. Cancellation suppresses response delivery but does not abort an already-running Dart HTTP operation immediately.
- **Source/playback:** Provider records pass through `StreamNormalizer`, basic `StreamValidator`, then `SourcePreparer` and `NetworkDestinationValidator`. Sources preserve headers and format hints. Home opens the custom player; `PlaybackCoordinator` applies source identity including headers and caps automatic attempts. Android initially registers MediaKit/libmpv behind `video_player`; other platforms use Flutter's registered backend. Android can attempt the alternate Media3 engine after a failure. Player initialization disposes replaced controllers and torrent sessions; its screen cancels timers/subscriptions and starts async disposal on exit.
- **Android/native:** MainActivity hosts Flutter and two method channels (brightness/PiP and APK installation). Manifest includes INTERNET, WAKE_LOCK, FOREGROUND_SERVICE, and REQUEST_INSTALL_PACKAGES. MainActivity is exported for launcher use, has no custom deep-link filter, and FileProvider is non-exported. The app-wide cleartext override is absent. Release signing inputs are required for release Gradle tasks. There is no project-owned native playback implementation; libmpv/media_kit and video_player_android supply native playback.
- **Secrets/diagnostics:** `lib/tmdb_config.local.dart` exists in this checkout but is ignored and not tracked. TMDB keys are client-side/public by design. Debug diagnostics are generally behind `kDebugMode` and provider/playback messages sanitize URL query/path data. There is no analytics/telemetry implementation found in the inspected app code.

## Findings

Severity reflects user impact and release risk. “Confirmed” means visible in source; where exploitation needs native/device confirmation, that dependency is stated.

### Critical

None confirmed in the inspected source paths.

### High

#### SEC-01 — Native playback requests bypass destination validation after initial preflight

- **Category:** Security / SSRF boundary / playback
- **File:** `lib/src/services/source_preparer.dart:31-58`; `lib/src/widgets/player/custom_video_player.dart:172-180`; `docs/streaming_security.md` (native playback limitations)
- **Problem:** The app resolves and rejects private/special-use addresses before handing a URL to native playback, but the native engine receives the original hostname. Native DNS is not pinned, and HLS/DASH playlist redirects, nested playlists, and segments are not passed through Dart validation.
- **Evidence:** Source preparation ends after resolving the initial URL. The security note explicitly says native playback may resolve again and follows playlist/media redirects internally.
- **Impact:** A plugin-supplied public URL that later resolves/redirects to loopback, LAN, link-local, or metadata endpoints could make native networking reach destinations excluded by the Dart bridge. Exact reachability and data exposure depend on libmpv/platform behavior and must be validated on Android.
- **Root cause:** The player abstraction accepts a URL plus headers, while the native engine owns subsequent network requests.
- **Recommended fix:** Design a narrow controlled media proxy/request integration that validates every redirect and playlist/segment URI while preserving provider headers and cookies; alternatively use an engine-level network policy with verified redirect/DNS pinning. Keep direct provider compatibility as a requirement and measure the compatibility impact before rollout.
- **Risk of fix:** A proxy or custom demuxer changes HLS/DASH behavior, signed URL handling, range requests, and throughput; a blanket host/scheme restriction would break legitimate providers.
- **Status:** Unfixed; requires architecture/device investigation.

### Medium

#### NET-01 — Update APK downloads have no size ceiling

- **Category:** Network / storage exhaustion / update reliability
- **File:** `lib/src/services/github_update_service.dart:182-230`
- **Problem:** Downloads stream directly to a temporary file without rejecting an excessive Content-Length or stopping after a maximum number of bytes. `downloadApk` accepts any `GitHubUpdate` caller and has a three-minute response timeout but no body-size bound.
- **Evidence:** Each response chunk is written before any length validation; completion only checks nonzero and declared-length equality.
- **Impact:** A bad/misconfigured release asset or unexpectedly large response can consume substantial temporary storage and delay/fail the update flow.
- **Root cause:** Time bounds were added, but transfer size was not bounded.
- **Recommended fix:** Set a documented maximum APK size; reject larger declared lengths and enforce the same ceiling while streaming. Delete the partial file on rejection.
- **Risk of fix:** An overly small ceiling could reject a future legitimate APK; choose it based on measured release artifact sizes.
- **Status:** Fixed in `lib/src/services/github_update_service.dart`: reject an advertised body above 512 MiB and enforce the same cap against streamed bytes when Content-Length is absent or inaccurate. The partial file is removed on failure by the existing cleanup path.

#### AND-01 — Android application identity is still a template ID

- **Category:** Release configuration
- **File:** `android/app/build.gradle.kts:39-41`
- **Problem:** `applicationId` remains `com.example.onfeed`.
- **Evidence:** The configured ID is the Flutter template-style package and the Gradle file retains template comments.
- **Impact:** Publishing under a placeholder creates a poor/ambiguous permanent app identity and makes later package-name changes a separate app migration. It can also collide with another installation using that ID.
- **Root cause:** The publisher's reverse-domain identity has not been selected in project configuration.
- **Recommended fix:** Select and set the publisher's permanent unique application ID before the first public release; align namespace/deep links/signing/update distribution as needed.
- **Risk of fix:** Changing it after publication prevents Android from treating builds as an in-place update.

#### STORE-01 — Persistent user history/favorites are plaintext app preferences

- **Category:** Privacy / local storage
- **File:** `lib/src/services/storage_service.dart:41-89`
- **Problem:** History, favorites, and preferences are serialized into SharedPreferences without encryption.
- **Evidence:** JSON strings and lists are persisted directly. Android app sandboxing still protects these files from ordinary apps, but the content is readable on rooted/debug devices and may be included in device backup depending on platform policy.
- **Impact:** Viewing history is personal data and can be exposed through device access or backup extraction. No remote exfiltration path from Reelish itself was found outside provider scripts receiving the title identifiers used for a lookup.
- **Root cause:** Storage favors simple persistence and contains no privacy/backup policy.
- **Recommended fix:** Document the stored data, review Android backup defaults, and offer clear-history controls. Encrypt only if the threat model warrants key management overhead.
- **Risk of fix:** Encryption can impair backup/restore and increase migration complexity.

#### COMPAT-01 — README describes Stremio add-ons but implementation installs Nuvio manifests

- **Category:** Compatibility / documentation
- **File:** `README.md`; `lib/src/services/nuvio_plugin_service.dart:130-170`
- **Problem:** README advertises Stremio-compatible add-on support, while the active plugin installer parses Nuvio provider manifests and explicitly rejects add-on manifests containing `resources`.
- **Impact:** Users following the repository documentation can install the wrong kind of URL and believe compatibility is broken.
- **Root cause:** README describes a different/older protocol than the current implementation.
- **Recommended fix:** Align README terminology and instructions with the Nuvio provider flow, or implement a separate Stremio protocol adapter if that compatibility is still intended.
- **Risk of fix:** Documentation-only update is low risk; implementing another protocol expands the security and maintenance surface.

#### OBS-01 — Native playback policy is not verified by automated tests

- **Category:** Testing / Android reliability
- **File:** `test/playback_pipeline_test.dart`; `test/network_destination_validator_test.dart`
- **Problem:** Existing tests exercise the Dart destination/source policy and playback coordinator, but cannot prove MediaKit/libmpv's redirect, DNS, header-forwarding, or renderer behavior on Android.
- **Evidence:** The source policy hands the URI and headers to `VideoPlayerController`; the tests are Dart-level. No Android instrumentation/device evidence was available in this audit.
- **Impact:** Important differences between initial validation and actual HLS/DASH requests, or between MediaKit and Media3, may escape regression coverage.
- **Root cause:** Native playback is behind a platform plugin and the repository has no recorded Android device matrix results.
- **Recommended fix:** Add device-level acceptance coverage for signed headers, HLS/DASH redirects/segments, pause/seek/rotation/background/exit, engine fallback, and repeated open/close resource behavior.
- **Risk of fix:** Instrumentation may require stable network fixtures and emulator/device CI capacity.

### Low

#### PERF-01 — Glass blur is used in persistent high-visibility surfaces

- **Category:** Rendering performance / GPU
- **File:** `lib/src/widgets/soft_glass_dock.dart:31-32`; `lib/src/widgets/glass_box.dart:20-21`; `lib/src/widgets/player/glass_controls_overlay.dart:329-330`
- **Problem:** BackdropFilter blur is used in navigation and glass surfaces. This is visually intentional but can be expensive on lower-end GPUs, especially over moving video.
- **Evidence:** Blur sigma values are 18–22 and player controls can overlay continuous video.
- **Impact:** Potential extra GPU work/jank; no device frame-time measurements establish a current user-visible regression.
- **Root cause:** Glass style uses live backdrop sampling instead of a static/tinted approximation.
- **Recommended fix:** Profile on lower-end Android hardware; if frame timing shows pressure, reduce blur area/sigma or use a static translucent fill while preserving the design.
- **Risk of fix:** Visual appearance changes; no change recommended without measurements.

#### CODE-01 — Local QuickJS fork requires upstream maintenance discipline

- **Category:** Maintainability / dependency risk
- **File:** `third_party/flutter_js/REELISH_PATCH.md`; `third_party/flutter_js/lib/quickjs/ffi.dart`
- **Problem:** Reelish maintains a local copy of `flutter_js` and a native symbol fallback for the memory-limit API.
- **Evidence:** The patch note identifies the exact binding change and warns that native exported symbols must be reverified for runtime updates.
- **Impact:** A dependency/runtime update can silently invalidate the configured heap limit or break provider execution if symbols/ABIs change.
- **Root cause:** Upstream package does not expose the needed Android memory-limit API consistently.
- **Recommended fix:** Keep the patch isolated, record upstream base version, and add a release check that verifies the binding and effective memory cap on supported ABIs.
- **Risk of fix:** Replacing the fork could remove current compatibility; do not upgrade blindly.

## Security and plugin trust assessment

- The repository and every provider script are explicitly untrusted and are fetched over HTTPS with manifest/script response caps and bounded redirect handling. There are no signatures, checksums, or immutable script snapshots; a repository owner or compromised hosting account can replace executed script content. This is a disclosed trust limitation rather than evidence of a code vulnerability.
- Provider capability includes requests to arbitrary **public HTTPS** hosts and access to the requested title/episode identifiers. That enables a provider to exfiltrate those identifiers. Providers cannot access local files, SharedPreferences, TMDB credentials, arbitrary Dart APIs, or native commands through the inspected bridge.
- `NetworkDestinationValidator` checks resolved IPs, rejects special/private ranges and ambiguous numeric hosts, pins Dart sockets to checked addresses, verifies TLS, validates redirects independently, and restricts provider fetch to HTTPS. The native playback gap is SEC-01.
- QuickJS has synchronous timeout and memory bounds. Async provider fetches have request/body/concurrency/timer limits; `handlePromise` and provider discovery also have timeouts. A Dart timeout does not preempt already executing work, but the runtime's synchronous interrupt limit and bounded network calls constrain the observed path. Runtime, bridge, and scheduler slot cleanup is in `finally` blocks.
- There is no durable malicious-provider state mechanism in the plugin API beyond repository URLs and enabled overrides. Provider cookies live only in one bridge instance and are discarded at disposal.
- Android global cleartext permission is not enabled. Provider fetches are HTTPS-only; stream preparation intentionally accepts HTTP and multiple media transport schemes to preserve provider compatibility. Dart policy validates the initial target, while later native traffic is outside the policy.
- No committed TMDB secret was found: the local configuration file is ignored and not tracked. The compiled mobile client still contains its configured TMDB key; treat it as a public/restricted API key and enforce usage limits at TMDB.

## Playback and source review

The observed path is title selection → metadata/episode lookup → allowed enabled provider filtering → secure script fetch → isolated QuickJS execution → provider fetch bridge → JSON stream parsing/normalization → lightweight URL/header checks → progressive source discovery → initial DNS/public-address preflight → source/engine attempt → `video_player` controller → MediaKit/libmpv on Android (Media3 alternate) or the platform video player elsewhere.

Provider headers are preserved in `StreamSource`, passed into `PlayableSource`, and passed via `httpHeaders` by each player engine. Deduplication identity includes URL plus headers. `StreamValidator` deliberately does not issue HEAD/GET probes, so sources are not rejected solely because a server rejects HEAD. Playback fallback is capped at five automatic attempts and tracks source plus engine; decoder/render/engine failures do not trigger unlimited candidate cycling. Source probing is therefore delegated to actual playback, which supports servers with unusual MIME types but gives less pre-play diagnostic detail.

Player state uses generation/cancellation checks, disposes a prior controller before replacement, stops a prior torrent session, and has timer/subscription/listener cleanup in widget disposal. Failure handling is broad in some optional metadata/track operations but those catches allow playback to proceed and prevent optional UI features from taking down video. Async dispose/stop calls in widget `dispose()` are necessarily unawaited and native repeated open/close behavior still needs device measurement.

## Startup, networking, performance, and storage

- The cold startup path waits on local consent state before Home. Home first loads playback settings, begins catalog requests, loads plugin repositories, and then history. Plugin manifests are loaded on startup, but scripts are fetched only when sources are discovered. GitHub update check runs post-frame, is local-throttled to six hours, and persists its check/result; an update check can still overlap Home's first render/network activity.
- Startup catalog uses two calls (popular movies and popular TV). New Releases and recommendations are deferred until their section approaches; category/search request generation counters avoid stale results overwriting the current catalog. TMDB caches, deduplicates, caps concurrency, retries transient errors, honors bounded Retry-After, and caps response size. Cache read/write errors fall back to networking.
- Poster/backdrop images use cache dimensions, and home/library grids/carousels use lazy builders. The app contains multiple BackdropFilter surfaces; performance impact remains a profiling question rather than a confirmed regression.
- SharedPreferences lists are capped for history and last-stream entries; favorites have no explicit item cap. Cache TTL/size and stale behavior are implemented in `tmdb_response_cache.dart`; provider stream cache entries expire by caller-supplied max age and may contain signed URLs/headers in local preferences. Never treat those cached streams as credentials protected from device access.
- The GitHub update check/download flow uses standard HTTPS and Android PackageInstaller confirmation; Android signature/package rules still gate an in-place install. APK transfer now has the 512 MiB cap from NET-01, but has no focused download-size regression test yet. TMDB API key is a query parameter sent only to the TMDB configured host and is excluded from request diagnostics.

## Android and dependency review

- Manifest: INTERNET, WAKE_LOCK, FOREGROUND_SERVICE, REQUEST_INSTALL_PACKAGES; launcher activity exported; non-exported FileProvider; no custom deep links or app-wide cleartext override. REQUEST_INSTALL_PACKAGES is used by the in-app updater and remains a sensitive store-policy consideration.
- Gradle: Flutter SDK min/target SDK defaults; release builds require explicit signing configuration; app ID is still a template ID (AND-01). No app-owned ABI filters, release shrinking rules, or MPV packaging rules were found in the app Gradle file; final native ABI and bundle sizes were not measured.
- `pubspec.yaml` includes `video_player`, `video_player_android`, local MediaKit adapter, Android video libraries, QuickJS fork, torrent streamer, HTTP, SharedPreferences, and UI/support dependencies. No dependency was upgraded. A reliable vulnerability/outdated-package conclusion requires dependency advisory data and an available successful package-status command; none is claimed here.

## Memory/resource audit

Reviewed resource owners include player controllers/torrent sessions/subscriptions/timers, Home search/focus/page/value controllers and observer/plugin listener, MediaCard notifiers, navigation animation controller, legal scroll controller, plugin installer text controller, QuickJS runtime/bridge/scheduler slots, HTTP clients, and service ChangeNotifiers. The inspected owners have corresponding disposal/cancellation or `finally` cleanup. No definite orphaned Flutter controller or QuickJS runtime was confirmed. Remaining evidence gap: no repeated on-device movie open/exit memory measurement was available.

## Static analysis and tests

Existing tests cover transitions, TMDB scalability/cache/retry behavior, provider fetch bridge and destination validation, provider/source normalization, playback pipeline/settings, update checks, and ranking. No tests were added during the report-first audit pass.

`dart analyze` completed its project scan and reported **310 info-level lint findings** (many in the vendored `flutter_js` fork and existing UI code) with no error or warning diagnostics after fixing a test constructor call exposed by the user's uncommitted `HomeScreen` settings change. Dart then exited nonzero because it could not update `C:\Users\USER\AppData\Roaming\.dart-tool\dart-flutter-telemetry-session.json` in the restricted profile. `flutter analyze --no-pub` and the focused Flutter tests (`github_update_check_test.dart`, `tmdb_scalability_test.dart`) were attempted but remained silent for 30 seconds and were interrupted. Run both in a normal Flutter SDK environment before release. No performance baseline or Android device run was performed.

## Remediation order

1. Resolve SEC-01 with an Android native networking design or explicitly accept/mitigate its residual risk while preserving headers, redirects, and provider compatibility.
2. Add focused tests for declared and streamed APK-size limits and malformed update assets (NET-01).
3. Choose the permanent publisher application ID and set it before public distribution (AND-01).
4. Add Android playback acceptance coverage for redirects, nested manifests, headers, lifecycle transitions, fallback, and repeated open/close memory stabilization (OBS-01).
5. Correct protocol documentation (COMPAT-01), review backup/history privacy expectations, and profile glass rendering on target hardware before optimizing (STORE-01/PERF-01).
6. Keep QuickJS fork/runtime symbol verification in the dependency update checklist (CODE-01).

## Files changed by this audit

- `docs/production_readiness_audit.md` — records the source-reviewed architecture, confirmed findings, evidence boundaries, and remediation order.
- `lib/src/services/github_update_service.dart` — added a declared and streamed 512 MiB update APK limit to prevent excessive cache consumption.
- `test/tmdb_scalability_test.dart` — supplies and disposes the required accent settings controller in the Home startup test; this was the sole analyzer error caused by the existing uncommitted `HomeScreen` constructor change.

No test files were added for the APK size guard; the existing update tests cover check-result throttling rather than file downloads. Add injectable download transport/temp-directory seams and targeted size tests before changing this update path further.
