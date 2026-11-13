# Playback audit report (2026-11-13)

Scope: the whole path from Play to a running picture, on Android phone,
Android TV / Google TV and Windows, at commit `6d3c7ae` (v1.33.1). The
audit was static: no application code was changed, and nothing was run on
a device. The architecture it refers to is in
[PLAYBACK_ARCHITECTURE_OVERVIEW.md](PLAYBACK_ARCHITECTURE_OVERVIEW.md).

**Evidence levels**

- **Confirmed:** the defect follows from the code as written; the path is cited.
- **Confirmed path, impact unmeasured:** the behaviour is certain, but how
  often it happens or how much it costs needs a runtime measurement.
- **Potential:** depends on engine or provider behaviour that static reading
  cannot settle. It says how to reproduce.

Code references name the file and symbol. Line numbers are as of `6d3c7ae`
and will drift.

## Summary

The playback design is sound and already defends against most of the
failure modes in the brief. It has generation tokens, open cancellation, an
engine gate, bounded dispose, progressive discovery, failure
classification, per-engine fallback, reconnect and link-refresh budgets, a
stall watchdog, and turns libmpv's early end of file into an error. **The
audit found no reason to rewrite it.** The problems are concentrated in
three places:

1. **Provider execution capacity (PB-01, PB-02, PB-08, PB-09).** Two QuickJS
   runtimes serve the whole app, and cancelling a lookup cannot stop a
   provider that is already running. Slow or abandoned providers therefore
   delay the next lookup. This is the most likely structural cause of a slow
   start from Reelish's own code, as opposed to slow providers.
2. **Failure-policy edge cases in the session widget (PB-03, PB-04, PB-05).**
   These are small state bugs in the 3,800-line `_CustomVideoPlayerState`.
   Its failure policy had no test that drives it (PB-15). PB-03 and PB-15
   have since been addressed, and PB-04 was found to be narrower than first
   reported.
3. **Sequential pre-play steps (PB-06, PB-07).** Several bounded platform
   round trips run between `initialize()` and `play()`, and resuming buffers
   the start of the file before seeking.

| ID | Title | Severity | Evidence |
|---|---|---|---|
| PB-01 | Cancelled lookups keep running providers and hold the app's 2 runtime slots | High | Confirmed path, impact unmeasured |
| PB-02 | Two slow providers at the top of the priority order delay every first source by up to 30 s | High | Confirmed path, impact unmeasured |
| PB-03 | A live failure classified as "cancelled" leaves the player on a permanent spinner | Medium | Confirmed by test; **fixed** |
| PB-04 | Rediscovery can open a source during an episode switch (corrected) | Low | Confirmed path, narrow; not fixed |
| PB-05 | Link refresh can reuse the still-running lookup and replay the dead link | Low | Potential |
| PB-06 | Up to five sequential engine round trips between initialize and play | Medium | Confirmed path, impact unmeasured |
| PB-07 | Resuming buffers the start of the file, then seeks and buffers again | Medium | Confirmed path, impact unmeasured |
| PB-08 | Each provider run builds an isolate and runtime and parses a 702 KB bundle | Medium | Confirmed path, impact unmeasured |
| PB-09 | Windows: a provider stuck in synchronous code keeps its isolate and heap after the timeout | Medium | Confirmed (documented in code) |
| PB-10 | Production telemetry cannot separate source resolution from player start | Medium | Confirmed |
| PB-11 | Three different source-identity keys | Low | Confirmed |
| PB-12 | Media3 playing video with no audio is not detected | Low | Potential |
| PB-13 | Engine buffer and network settings are package defaults and were never measured | Low | Observation |
| PB-14 | Architecture notes say Windows has no torrents | Low | Confirmed (documentation) |
| PB-15 | The failure policy has no test that drives it | Medium | Confirmed |

No Critical findings: nothing found makes playback fail for every viewer
or corrupts saved data.

---

## PB-01: Cancelled lookups keep running providers and hold the app's 2 runtime slots

- **Severity:** High. **Category:** Plugin integration / cancellation / startup latency.
- **Evidence:** Confirmed path, impact unmeasured.
- **Affected:** [stream_discovery.dart](../../lib/src/services/stream_discovery.dart)
  `StreamDiscovery.cancel`; [provider_plugin_service.dart](../../lib/src/services/provider_plugin_service.dart)
  `streams` → `runProviderWorker`; [provider_runner.dart](../../lib/src/services/provider_runner.dart)
  `ProviderRunner.run`; [provider_execution_scheduler.dart](../../lib/src/services/provider_execution_scheduler.dart).
- **Explanation:** `cancel()` only sets `_cancelled`. `runProviderWorker`
  checks `isCancelled` before claiming a provider and again before and
  after `acquireRuntime()`. A provider already inside `ProviderRunner.run`
  is not told: `Isolate.run` has no cancellation, and the run lasts until
  `getStreams` returns or hits 30 s (45 s hard cap). There is one
  `ProviderExecutionScheduler` per `ProviderPluginService`, and the app has
  one service, so the **2 runtime slots are shared by every lookup**. When
  the viewer cancels a search, closes the player early, or moves to another
  title or episode, the abandoned providers still hold the slots. The new
  lookup's providers queue behind them.
- **Root cause:** Cancellation was designed as "stop starting work", not
  "stop work". The runner has no channel for an abort.
- **Reproduction (runtime):** Enable two slow providers (or a test provider
  that `await`s a 25 s timer). Press Play on title A, cancel the search
  after 1 s, then press Play on title B. In a debug log, compare
  `[Provider Perf] <id> started at` for B's first provider with the time
  of the Play press. Expected today: B's first provider starts only when
  A's providers finish (up to about 30 s).
- **User impact:** After a cancel or a quick change of mind, the next title
  sits on "Finding best stream" for up to tens of seconds, though its own
  providers might answer in two.
- **Recommendation:** Add a cooperative abort to `ProviderRunner`. Start
  the isolate with `Isolate.spawn` and a control `SendPort`, and on cancel
  send a message that (a) sets the QuickJS interrupt deadline to now, where
  supported, and (b) makes `ProviderFetchBridge` fail its pending requests
  and refuse new ones. The isolate then reaches its `finally` and disposes
  its runtime as it does today. Release the slot when the abort is
  acknowledged or after a short grace (for example 2 s). Do not use
  `Isolate.kill`: it would skip `runtime.dispose()` and leak the 64 MiB
  native heap.
- **Validation:** A unit test with an injectable runner: a cancelled lookup
  releases both slots within the grace period, and a second lookup's first
  provider starts at once. On a device, the reproduction above shows B's
  provider starting within about 2 s.

## PB-02: Two slow providers at the top of the priority order delay every first source by up to 30 s

- **Severity:** High. **Category:** Plugin integration / startup latency.
- **Evidence:** Confirmed path, impact unmeasured.
- **Affected:** `ProviderPluginService.streams` (providers sorted by
  `priority` only), `ProviderExecutionScheduler(runtimeLimit: 2)`,
  `ProviderRunner.getStreamsTimeout` (30 s).
- **Explanation:** Providers start strictly in manifest priority order.
  Four workers fetch scripts, but only two can execute. If the two
  highest-priority providers are slow or dead for a title, every other
  provider waits up to 30 s for a slot. Nothing remembers that a provider
  was slow, empty or failing in earlier lookups. One malfunctioning
  provider cannot block the others, because the second slot keeps working.
  **Two can.**
- **Root cause:** A fixed runtime limit (chosen for memory: 2 × 64 MiB)
  combined with a static order and a long uniform timeout.
- **Reproduction:** Two test providers with the highest priority that never
  resolve, plus one fast provider. Time from Play to `FIRST_SOURCE`
  (`PerfTimeline`, debug) is about 30 s; disable the two and it is about the
  fast provider's own time.
- **User impact:** Slow first source for every title on a setup with
  unreliable top providers. This would look like "Reelish is slow" when
  the providers are at fault.
- **Recommendation (in order of risk):**
  1. Keep a small on-device record of each provider's recent outcome:
     time to first result, empty, error or timeout. Store it as a new
     SharedPreferences key; existing keys are untouched. Order providers by
     priority, then demote ones that recently timed out or returned
     nothing.
  2. Once the first source has been found, the 30 s limit only adds
     fallback candidates, so it can stay. The cost is before the first
     source: consider a shorter first-wave deadline for a provider with no
     recent success.
  3. Measure QuickJS heap use per run before considering a third slot on
     devices with more memory. Do not raise the limit blindly: Android TV
     devices are memory-constrained.
- **Validation:** A pure-Dart test with a fake runner and the measured
  replay timings mentioned in `ProviderRunner.getStreamsTimeout`'s comment:
  first-source time with two dead top providers falls to roughly the fast
  provider's time after one demotion.

## PB-03: A live failure classified as "cancelled" leaves the player on a permanent spinner

- **Severity:** Medium. **Category:** Lifecycle / state management.
- **Evidence:** Confirmed code path. How often engines emit such text needs
  runtime confirmation.
- **Affected:** [custom_video_player.dart](../../lib/src/widgets/player/custom_video_player.dart)
  `_handleFailure`; [playback_coordinator.dart](../../lib/src/services/playback_coordinator.dart)
  `PlaybackFailure.classify`.
- **Explanation:** `_handleFailure` sets `_handlingFailure = true`, sets
  `_controller = null` and disposes the controller *before* it classifies
  the error. `classify` returns `cancelled` for any message containing "was
  cancelled" or "was canceled". The handler then returns. `_ready` stays
  true, `_error` stays false and `_controller` is null, so the build shows
  `PlayerStatusView` (spinner plus stale status) with no error panel.
  Because `_handlingFailure` stays true, every later failure is ignored too.
  The only exit is Back. A real cancellation always comes with a stale
  generation and returns earlier, so this branch only runs when an engine
  or network message for the *current* player happens to contain those
  words (for example an HTTP library reporting "request was cancelled").
- **Root cause:** Cancellation is inferred from message text instead of from
  the session's own state.
- **Reproduction:** A widget test with a fake `VideoPlayerPlatform` whose
  controller reports `VideoEvent` error "Request was cancelled" after
  initialization. Expected today: spinner, no error panel, no fallback.
- **User impact:** A playing video turns into an endless spinner.
- **Recommendation:** Return silently for `cancelled` only when the
  generation is stale or `_openCancellation` was completed by Reelish. A
  `cancelled` kind on a live generation should be handled as `unknown`, or
  as `network` if the text also says so. Alternatively, stop matching "was
  cancelled" in `classify` and detect Reelish's own cancellation by type
  (throw a dedicated `PlaybackCancelled` from `prepareAndOpen`).
- **Validation:** The widget test above shows the next source or the error
  panel. `playback_reliability_test` "cancellation never moves to another
  source" still passes with the dedicated type.
- **Status (2026-11-13): fixed.** `_handleFailure` now treats a `cancelled`
  classification on the current generation as `unknown`. Reelish's own
  cancellations always move the generation on first and return earlier.
  This is a smaller change than the dedicated-type option above, and
  `classify` is unchanged. `test/player_session_test.dart` covers both
  cases: an error while opening moves to the next source, and an error
  during playback reconnects. Both tests failed before the change.

## PB-04: Rediscovery can open a source during an episode switch (corrected)

- **Severity:** Low (first reported as Medium). **Category:** Race condition.
- **Evidence:** Confirmed path, narrow.
- **Affected:** `_CustomVideoPlayerState._rediscoverAndPlay`.
- **Correction:** The first version of this finding said the viewer could
  pick another source while "Finding best stream…" shows, and that
  rediscovery would then override the choice. **That cannot happen.** The
  source sheet (`onSources`) and the error panel (`onTryAnother`) are built
  only while the player is playable or in error, and during rediscovery it
  is neither.
- **What remains:** `_rediscoverAndPlay` awaits `discovery.firstSource` (up
  to 60 s) and then calls `_initialize` without re-checking the generation.
  The only other way to start an open during that wait is the remote's or
  keyboard's next-track key (`mediaTrackNext`), which `_onRemoteKey` accepts
  while loading. There are two outcomes:
  - If rediscovery finishes while the next episode is still being looked
    up, a player opens behind the hand-off and is disposed when the next
    episode's route replaces this one.
  - If the next episode finds no source, the current episode reopens its
    old (dead) source, and rediscovery then replaces it with the fresh one.
    That is arguably the better result.
- **Recommendation:** Do not add a plain generation guard: in the second
  case it would keep the dead link instead of the fresh one. If this is
  worth addressing, skip the open in `_rediscoverAndPlay` only while
  `_switchingEpisode` is true. It is low priority.

## PB-05: Link refresh can reuse the still-running lookup and replay the dead link

- **Severity:** Low. **Category:** Recovery correctness.
- **Evidence:** Potential (needs a failure within the first 60 s of a lookup).
- **Affected:** `ProviderPluginService.discoverStreams` (returns the
  in-flight discovery for the same key), `_rediscoverAndPlay`.
- **Explanation:** `onRediscover` calls `discoverStreams` with the same key.
  While the original lookup is still running (it can run up to 60 s after
  Play), that call returns *the same* `StreamDiscovery`, whose sources
  include the link that just died. `_rediscoverAndPlay` resets the attempt
  budget and prefers the source with the same name, provider and
  description, which is the failed one.
- **Reproduction:** Start a source, cut the network for about 30 s within
  the first minute, and restore it. Watch the `[Playback][Fallback]` logs
  for "link stopped working; rediscovering" followed by an open of the same
  host.
- **User impact:** One wasted attempt and a reset budget. Bounded by
  `LinkRefreshBudget` (2 per session).
- **Recommendation:** Give rediscovery a fresh lookup. Add a `fresh: true`
  parameter that bypasses `_inflightDiscoveries`, or have the player skip
  sources whose `sourceKey` has already failed.
- **Validation:** A unit test of `discoverStreams(fresh: true)` returning a
  new object.

## PB-06: Up to five sequential engine round trips between initialize and play

- **Severity:** Medium. **Category:** Startup latency.
- **Evidence:** Confirmed path, impact unmeasured.
- **Affected:** `_CustomVideoPlayerState._initialize`, after `prepareAndOpen`.
- **Explanation:** After `initialize()` the session awaits, in order:
  `getVideoTracks` and `getAudioTracks` together (≤2 s);
  `_applyPreferredAudio` (≤2 s when a track matches); `setPlaybackSpeed`
  (≤2 s, only when the speed is not 1); `setVolume` (≤2 s, only when the
  volume is not 1); `seekTo(resume)` (≤2 s); then `play()` (≤10 s). The video
  track query runs even when the quality preference is Auto
  (`preferredVideoHeight == 0`), where its only use is the quality menu.
  Each step is bounded, so this cannot hang. On a healthy engine each step
  is probably a short platform-channel round trip, but nothing has measured
  it.
- **Root cause:** Correct ordering for audio and resume ("set before play")
  was implemented as a strictly serial chain.
- **Reproduction / measurement:** In a debug build, the gap between
  `[Playback][Player] initialized in X ms` and `play accepted after Y ms` is
  exactly this chain plus `play()`. Record it on a phone, a TV and Windows.
- **User impact:** Unknown until measured; worst case several seconds per
  attempt on a slow engine.
- **Recommendation:** Only after measurement shows a meaningful gap:
  (1) skip `getVideoTracks` before play when the quality preference is Auto,
  and load it after the first frame for the menu; (2) issue speed and
  volume concurrently; (3) keep the audio selection and the seek before
  `play()`, since their order matters.
- **Validation:** The same log gap before and after, on each engine.
  `audio_tracks_test` and `media3_audio_track_test` still pass.

## PB-07: Resuming buffers the start of the file, then seeks and buffers again

- **Severity:** Medium. **Category:** Startup latency / buffering.
- **Evidence:** Confirmed path, impact unmeasured.
- **Affected:** `_initialize` (`seekTo(safeResume)` after `initialize()`);
  `prepareAndOpen`.
- **Explanation:** `VideoPlayerController.initialize()` completes once the
  engine is ready to play from position 0. On Media3 that means data from
  the start of the file is already buffered. A resumed session then seeks
  and buffers again at the resume point. For a progressive MP4 on a slow
  host that is a second range request plus an initial buffer; for HLS, a
  second set of segments.
- **Root cause:** `package:video_player` has no start-position parameter.
- **User impact:** Resumed playback (Continue Watching, the most common
  start) has a longer time to first frame than a fresh start. Not measured.
- **Recommendation:** Measure first (the metric is below). If the cost is
  real, libmpv can be given a start position at open time through the
  vendored bridge (mpv's `start` option, through a `Media` start parameter
  if the media_kit version in use supports it, or a property set before
  `open`). The bridge is vendored, so this stays inside
  `packages/video_player_media_kit` and does not change engine selection.
  Media3 has no equivalent through `video_player_android`. Leave it alone.
- **Validation:** Compare `playToFrame` (PlaybackMetrics) for resumed and
  fresh starts of the same source, per engine.

## PB-08: Each provider run builds an isolate and runtime and parses a 702 KB bundle

- **Severity:** Medium. **Category:** Provider performance / CPU.
- **Evidence:** Confirmed path, impact unmeasured.
- **Affected:** `ProviderRunner._run`; `ProviderPluginService.streams`
  (`needsCheerio` / `needsCryptoJs`); `assets/js/cheerio_bundle.js`
  (702,114 bytes).
- **Explanation:** Every provider run spawns an isolate, creates a QuickJS
  runtime and, for any script containing the substring `crypto` or
  `cheerio` (deliberately broad), evaluates the whole bundle. The bundle
  string is also copied into each isolate. On a low-end Android TV this
  fixed cost is paid once per provider per lookup, inside the 2-slot
  bottleneck from PB-02, so it lengthens slot occupancy for everyone.
- **Recommendation:** Measure the per-run fixed cost: the time from
  `ProviderRunner.run` entry to the start of `getStreams`, on a TV-class
  device. Only if it is significant, consider precompiling the bundle to
  QuickJS bytecode once (a `third_party/flutter_js` patch, which needs
  security review) or loading Cheerio and CryptoJS separately. Do not
  narrow the `crypto` heuristic: the code comment explains why it is broad.
- **Validation:** Per-run setup time before and after; `provider_runner_test`
  and `test/provider_compat` pass.

## PB-09: Windows: a provider stuck in synchronous code keeps its isolate and heap after the timeout

- **Severity:** Medium (Windows only). **Category:** Resource leak / isolation.
- **Evidence:** Confirmed: the `ProviderRunner.hardTimeout` comment says the
  interrupt deadline works only "where the native library supports one
  (Android)".
- **Explanation:** On Windows, a provider in an endless loop or a runaway
  regular expression is abandoned after 45 s. The caller frees the slot,
  but the isolate keeps spinning with its 64 MiB QuickJS heap. Each search
  that hits the same provider adds another, so CPU and memory grow until
  the app restarts.
- **Recommendation:** Enable the interrupt handler in the Windows QuickJS
  bridge build (`tool/build_quickjs_bridge_windows.ps1`,
  `third_party/flutter_js/REELISH_PATCH.md`), so `setInterruptDeadline`
  works there as on Android. This is a native-code change and needs the
  `provider-debugging` and `security-audit` reviews.
- **Validation:** A provider-compat test with `while(true){}`: on Windows the
  run ends at about 40 s and the process CPU returns to idle (the
  `windows_soak_test` style memory record).

## PB-10: Production telemetry cannot separate source resolution from player start

- **Severity:** Medium. **Category:** Observability.
- **Evidence:** Confirmed.
- **Affected:** [playback_metrics.dart](../../lib/src/services/playback_metrics.dart),
  `StreamDiscovery` (TTR/TTF `print` in debug only),
  `PerfTimeline` (debug only), `provider_plugin_service.dart`
  (`[Provider Perf]` debug only).
- **Explanation:** `PlaybackMetrics` starts its clock when the player
  screen opens, so `firstFrameMs` excludes discovery. Source-resolution
  time, providers run, providers that timed out, DNS/preparation time and
  open time per attempt exist only as debug prints. The opt-in
  `playbackSession` event therefore cannot answer the brief's central
  question: is a slow start the providers, Reelish, the network or the
  engine? What already exists is good: first frame, open, play-to-frame,
  rebuffer count and ratio, stalls, failure kinds, recoveries, slowest
  close, engine and source type.
- **Recommendation:** Add a few privacy-safe fields to the same event,
  measured in Home and handed to the player:
  `resolveMs` (Play → source chosen), `fromCache`, `providersStarted`,
  `providersTimedOut`, `prepareMs` (the `SourcePreparer` duration of the
  first attempt) and `attempts`. No provider names, hosts or titles: the
  class contract says "Never holds URLs, headers, provider names or titles".
  See the performance report for targets.
- **Validation:** Extend `playback_metrics_test` for the new fields.
  `analytics_test` checks the event shape.

## PB-11: Three different source-identity keys

- **Severity:** Low. **Category:** Duplicate logic.
- **Evidence:** Confirmed.
- **Affected:** `StreamDiscovery._key` (header names case-sensitive, list
  `toString`); `ProviderPluginService.streams` (`jsonEncode`, case-sensitive);
  `PlaybackCoordinator.sourceKey` (header names lower-cased).
- **Explanation:** The same link with `Referer` versus `referer` counts as
  two sources in discovery and once in the coordinator. In practice that
  means harmless duplicate rows in the source sheet, but the three rules
  can drift further apart.
- **Recommendation:** One static `StreamSource.identityKey` used by all
  three places.
- **Validation:** Unit test with mixed-case headers.

## PB-12: Media3 playing video with no audio is not detected

- **Severity:** Low. **Category:** Failure scenario 11 (unsupported audio codec).
- **Evidence:** Potential.
- **Explanation:** `_watchForPicture` catches Media3 playing audio with no
  picture. Nothing catches the reverse: a picture with no audio, which
  Media3 can do when it drops an audio track it cannot decode (for example
  some DTS/TrueHD tracks on devices without passthrough). The libmpv bridge
  distinguishes audio decoder messages (`_isAudioDecoderMessage`).
- **Recommendation:** Investigate on a device with a known DTS source first.
  If confirmed, an empty `getAudioTracks()` result for a source whose
  provider labels audio could offer "Try the other engine" in the audio
  menu. Keep it as an offer, not an automatic switch.
- **Validation:** A device run with a DTS-only test file on Media3.

## PB-13: Engine buffer and network settings are package defaults and were never measured

- **Severity:** Low. **Category:** Buffering configuration.
- **Evidence:** Observation.
- **Explanation:** libmpv runs with media_kit's default `PlayerConfiguration`
  (no explicit `demuxer-max-bytes`, `cache-secs`, readahead or
  `network-timeout`). Media3 uses `video_player_android`'s `LoadControl`
  defaults, which the app cannot change without forking that plugin. The
  audit found no evidence that these defaults cause problems, and no
  measurements either.
- **Recommendation:** Do not tune blindly (the brief says so, and so do the
  playback rules). First collect `rebufferPercent` and `stalls` per engine
  and source type (PB-10). Only if libmpv is clearly worse on HLS or
  progressive sources, trial explicit cache and readahead settings in the
  vendored bridge behind a debug flag, and compare.

## PB-14: Architecture notes say Windows has no torrents

- **Severity:** Low. **Category:** Documentation.
- **Evidence:** Confirmed: `TorrentSupport.available` returns true on
  Windows when `FlutterTorrentStreamer.isSupported`, and `_prepareTorrent`
  allows Windows. `.claude/skills/reelish-architecture/architecture.md`
  says "not supported".
- **Recommendation:** Correct the skill's platform matrix.

## PB-15: The failure policy has no test that drives it

- **Severity:** Medium. **Category:** Architecture / regression risk.
- **Evidence:** Confirmed: `test/` covers `PlaybackFailure.classify`,
  `PlaybackCoordinator`, `EnginePreference`, `LinkRefreshBudget`,
  `StallWatchdog` and `StreamDiscovery` in isolation, but no test runs
  `_initialize` → `_handleFailure` → reconnect / engine fallback / next
  source / error panel through a fake engine. PB-03 and PB-04 live exactly
  there.
- **Recommendation:** Not a rewrite. Add a widget-test harness with a fake
  `VideoPlayerPlatform` (scriptable: initialize ok, fail with text, hang,
  error after N s) and drive `CustomVideoPlayer` through the scenarios in
  [PLAYBACK_TEST_STRATEGY.md](PLAYBACK_TEST_STRATEGY.md). A later,
  optional refactor could move `_handleFailure`'s decision logic into a pure
  function next to `PlaybackCoordinator`, once the harness protects it.
- **Status (2026-11-13): harness added.** The fake engine is in
  `test/support/fake_video_player_platform.dart` and the session tests in
  `test/player_session_test.dart`. They cover a 403 moving to the next
  source, the two PB-03 cases, an open timeout, and closing while opening.
  The tests run on the Linux target platform, whose engine is whatever is
  registered (the fake), so the Media3 → libmpv engine switch is not
  covered yet.

---

## Failure scenarios (brief § 3)

| # | Scenario | Handled? | Responsible | Current behaviour | Feedback | Gap |
|---|---|---|---|---|---|---|
| 1 | Plugin too slow | Yes | `ProviderRunner`, `streams` | 30 s per provider, 60 s per search; results are progressive, so a slow one does not delay a fast one, except through slots | "Finding best stream", then a timeout message | PB-01, PB-02 |
| 2 | Empty response | Yes | `streams` | Normal; message lists the reason (no streams, errors, paused for review) | Snackbar or dialog | none |
| 3 | Malformed data | Yes | `ProviderRunner._run`, `StreamValidator` | Non-maps dropped; JSON error → provider error; invalid sources skipped | Provider error in message | none |
| 4 | Expired URL | Yes | `isExpired`, `LinkRefreshBudget`, cached-link refresh | Expired filtered before play. A 401/403/404/410 skips reconnect; a played source gets ≤2 refreshes; a cached link gets a 7 s timeout and one rediscovery | "Finding best stream…" / HTTP message | PB-05 |
| 5 | Many redirects | Partly | Engines | Engines follow redirects themselves. Provider fetches re-validate each hop. Engine redirects to private addresses are the accepted SEC-01 risk | Engine error | Runtime check only |
| 6 | Required headers | Yes | `SourcePreparer`, `PlayableSource.headers` | Hop-by-hop removed, others validated and passed as `httpHeaders` to both engines | n/a | none |
| 7 | HTTP 403 | Yes | `classify`, `_handleFailure` | `http` → no engine retry → next source (refresh if it had played) | "refused access (HTTP 403)" | none |
| 8 | HTTP 404 | Yes | same | same | "no longer available" | none |
| 9 | HTTP 5xx | Yes | same | Next source; reconnect if it was playing | "host returned an error" | No same-source retry for a transient 503 before the first frame (acceptable) |
| 10 | Unsupported format | Yes | `canTryAnotherEngine` | Other engine (12 s), then next source | "not a recognizable video stream" | none |
| 11 | Unsupported audio codec | Partly | Engines | libmpv handles more codecs; Media3 silent audio drop undetected | none | PB-12 |
| 12 | Unstable network | Yes | `StallWatchdog`, `endedEarly`, reconnect budget | 25 s stall (60 s torrent) → reconnect ×2 in 2 min → refresh → next source | "Reconnecting…" | Measure stall limit vs rebuffers (PB-13) |
| 13 | Switch source during init | Yes | Generation, open cancellation | Old open disposed; the source sheet is not offered while loading | n/a | PB-04 (episode key only) |
| 14 | Exit during init | Yes | `dispose`, Home `finally` | Generation++, open cancelled, controller disposed (≤5 s), discovery cancelled | n/a | PB-01 (providers keep running) |
| 15 | Rapid episode switching | Yes | `_switchingEpisode`, `_playbackStart`, `EpisodeHandOff` | Extra taps ignored during a switch; engine released before the next route | "Opening S01E02…" | PB-01 |
| 16 | Player fails to initialise | Yes | `prepareAndOpen` timeout | 20 s / 7 s / 12 s → classify → fallback | Error panel after budget | Total wait can be long (performance report) |
| 17 | Runtime exception | Yes | `_tick` `hasError` | Same policy | Same | PB-03 |
| 18 | Resume after minimise | Yes (package) | `video_player` lifecycle observer | Pauses on background, resumes if it was playing; progress saved on pause | n/a | Long background → expired link → handled by refresh; runtime check |
| 19 | Simultaneous init requests | Yes | `_playbackStart`, generation | Second Play ignored; newer open supersedes older | n/a | none |
| 20 | OOM / decoder limits | Partly | `decoder` kind, engine fallback | Decoder errors → other engine. A process killed for memory is not recoverable; progress is saved every 15 s and on pause | Error panel | Out of scope beyond the existing long-session tests |

## Answers to the ten questions (brief § 10)

1. **Why can start take too long?** In order of likely contribution:
   provider time, which Reelish does not control; slot contention from
   abandoned or slow providers (PB-01, PB-02); per-run setup (PB-08);
   serial pre-play steps (PB-06); and double buffering on resume (PB-07).
   Without PB-10's telemetry, the split between them is not known.
2. **Why can a source fail after the plugin returned it?** Signed links
   that expired or are tied to the provider's IP or headers, hosts
   refusing the app's request (403), codecs the engine cannot decode, and
   playlists that need cookies the engine never sees. The classifier and
   fallbacks handle these. Only PB-03 can turn one into a dead end.
3. **Architectural problems?** The capacity model for providers (PB-01,
   PB-02). The session widget is large, but its invariants hold; the risk
   is that it is untested (PB-15), not that it is wrong.
4. **Memory leaks or lifecycle bugs?** No leaked controllers or listeners
   were found: removal on dispose and generation checks are thorough. There
   is a Windows-only isolate leak on runaway providers (PB-09), and the
   PB-03 dead state.
5. **Can one bad plugin affect everything?** One cannot: there are two
   slots and errors are isolated per provider. Two slow ones delay
   everything (PB-02). A stuck one on Windows costs CPU and memory (PB-09).
6. **Unnecessary operations delaying playback?** The video track query
   before play with Auto quality (PB-06). The DNS preflight is required by
   the security policy and its cost is probably small (OS cache); measure
   `prepareMs` before touching it.
7. **Are the engines used efficiently?** The engine routing is good: Media3
   is skipped for cleartext and non-HTTP, retries are not doubled for
   network failures, and the preferred engine is learnt per session.
   Buffer settings are untested defaults (PB-13).
8. **What causes buffering or interruptions?** Mostly host throughput,
   which the app does not control. In the app: double buffering on resume
   (PB-07). The stall recovery limit is 25 s; whether that is right
   depends on measured rebuffer lengths.
9. **Fix immediately:** PB-03 (small, confirmed; since fixed), then PB-01.
   PB-04 turned out to be narrow and low priority.
10. **For growth:** provider outcome learning (PB-02), production stage
    timing (PB-10), the failure-policy test harness (PB-15) and the Windows
    interrupt (PB-09).
