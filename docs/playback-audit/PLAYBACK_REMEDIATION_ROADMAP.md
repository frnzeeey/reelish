# Playback remediation roadmap (2026-11-13)

**Status: proposal awaiting review. Nothing below has been implemented.**
Finding IDs refer to [PLAYBACK_AUDIT_REPORT.md](PLAYBACK_AUDIT_REPORT.md).
Tests are described in [PLAYBACK_TEST_STRATEGY.md](PLAYBACK_TEST_STRATEGY.md).

The order puts measurement before optimisation. Phase 6's telemetry
(PB-10) is small and should land early, alongside Phase 1, so that Phases
2 and 5 are decided on data.

Each phase is one or more separate pull requests, validated with the
`regression-check` skill.

---

## Phase 1: Critical bugs and playback failures

### 1.1 Fake engine harness for the session (PB-15). Priority: P0 (prerequisite)
- **Problem:** The failure policy cannot be tested, so the fixes below would
  be unprotected.
- **Files:** two new test files (proposed: a fake video player platform
  under the test support folder, and a player session test). No `lib/`
  changes, or at most a `@visibleForTesting` hook.
- **Dependencies:** none.
- **Approach:** A scriptable `VideoPlayerPlatform`, registered like the real
  one; drive `CustomVideoPlayer` with fake clock and storage.
- **Regression risk:** none (tests only).
- **Tests:** the widget scenarios in the test strategy.
- **Done when:** the harness runs the "403 → next source" and "hang on
  initialize" scenarios green on CI.

### 1.2 A live failure is never mistaken for cancellation (PB-03). Priority: P0
- **Problem:** Permanent spinner.
- **Files:** `playback_coordinator.dart` (`prepareAndOpen`, `classify`),
  `custom_video_player.dart` (`_handleFailure`).
- **Dependencies:** 1.1.
- **Approach:** Throw a dedicated `PlaybackCancelled` from `prepareAndOpen`
  and classify `cancelled` by type. Treat text-only "was cancelled" as
  `unknown`.
- **Regression risk:** Low. A real cancellation already returns on the
  stale generation first.
- **Tests:** classify unit tests; harness scenario "error text with 'was
  cancelled' while playing".
- **Done when:** the scenario shows the next source or the error panel.

### 1.3 Rediscovery during an episode switch (PB-04). Priority: P3 (was P0)
- **Dropped from Phase 1.** On closer reading the viewer cannot pick a
  source while rediscovery runs, so the reported race does not exist. A
  plain generation guard would make the remaining episode-key case worse.
  See the corrected PB-04 for the narrow fix, if one is wanted.

**Phase 1 status (2026-11-13):** 1.1 and 1.2 are done and uncommitted.
1.1 is in `test/support/fake_video_player_platform.dart` and
`test/player_session_test.dart`. 1.2 is in `_handleFailure`, which maps a
live `cancelled` to `unknown`; this is simpler than the dedicated type
proposed above, and `classify` is unchanged. Device runs are still
outstanding.

## Phase 2: Startup latency and buffering

Decide each item on the Phase 6.1 numbers.

### 2.1 Provider abort on cancel (PB-01). Priority: P1
- **Files:** `provider_runner.dart`, `provider_fetch_bridge.dart`,
  `provider_plugin_service.dart`, `stream_discovery.dart`.
- **Dependencies:** none, but it is provider-execution code: use the
  `provider-debugging` and `security-audit` skills.
- **Approach:** `Isolate.spawn` with a control port; on abort, set the
  interrupt deadline to now and fail pending fetches; the slot is released
  on acknowledgement or after a 2 s grace. Never `Isolate.kill`.
- **Regression risk:** Medium. Providers that are still useful to another
  lookup sharing the same discovery must not be aborted: abort only when no
  caller still holds the discovery. The sandbox limits must stay unchanged.
- **Tests:** scheduler test with a fake runner; device "cancel, then Play
  another title".
- **Done when:** the cancel-to-slot-free time is ≤ 2 s in the test and on
  an Android device.

### 2.2 Provider outcome learning (PB-02). Priority: P1
- **Files:** `provider_plugin_service.dart`, `storage_service.dart` (a new
  key only).
- **Dependencies:** 6.1, to confirm the problem exists in the field.
- **Approach:** Record time to first result, empty, error or timeout per
  provider (the last N). Sort by priority, then demote providers that
  recently timed out or returned nothing. Optionally use a shorter
  first-wave deadline for providers with no recent success.
- **Regression risk:** Medium. A provider that is slow but the only one
  with a title must still run. Demote it; never skip it.
- **Tests:** replay test with fake runners.
- **Done when:** p50 resolution time improves in telemetry with no rise in
  "no source found" sessions.

### 2.3 Trim the pre-play chain (PB-06). Priority: P2
- **Files:** `custom_video_player.dart` (`_initialize`).
- **Dependencies:** 6.1 shows a pre-play p90 above 300 ms.
- **Approach:** With Auto quality, load the video tracks after the first
  frame; set speed and volume concurrently. Keep the audio selection and
  the seek before `play()`.
- **Regression risk:** Medium (playback rule 3). The quality menu and audio
  must still be correct on both engines.
- **Tests:** `audio_tracks_test`, `media3_audio_track_test`,
  `audio_track_switch_test`; harness timing.
- **Done when:** the pre-play gap is lower on each engine, with identical
  track behaviour.

### 2.4 Start libmpv at the resume position (PB-07). Priority: P2
- **Files:** `packages/video_player_media_kit/` and the call site in
  `_initialize`.
- **Dependencies:** a measured gap between resumed and fresh `playToFrame`.
- **Approach:** Pass a start position through the vendored bridge (mpv
  `start`). Media3 is unchanged.
- **Regression risk:** Medium. Watch Party opening positions, `endedEarly`
  and duration estimates must still work.
- **Tests:** `libmpv_playback_test`, `windows_playback_test`,
  `watch_party_test`.
- **Done when:** resumed `playToFrame` on libmpv is close to a fresh start.

## Phase 3: Lifecycle, memory and resource management

### 3.1 Fresh lookups for link refresh (PB-05). Priority: P3
- **Files:** `provider_plugin_service.dart`, `home_screen.dart`
  (`onRediscover`).
- **Approach:** A `fresh` flag that bypasses the in-flight map; or skip
  sources whose key already failed.
- **Done when:** a unit test shows a new discovery; a refresh never reopens
  the same failed key.

### 3.2 One source identity key (PB-11). Priority: P3
- **Files:** `stream_source.dart`, `stream_discovery.dart`,
  `provider_plugin_service.dart`, `playback_coordinator.dart`.
- **Regression risk:** Low. Keys are in-memory only, not persisted (verify
  that `saveLastStream` does not depend on them).
- **Done when:** the mixed-case header unit test passes.

### 3.3 Memory baselines. Priority: P2
- Run `player_long_session_test` and `windows_soak_test` and record the
  numbers in `docs/playback/` so later changes have a reference.

## Phase 4: Plugin reliability and network resilience

### 4.1 Windows QuickJS interrupt (PB-09). Priority: P2
- **Files:** `third_party/flutter_js` (native), `tool/build_quickjs_bridge_windows.ps1`.
- **Approach:** Build the interrupt handler into the Windows bridge so
  `setInterruptDeadline` stops synchronous runaways. The QuickJS limits are
  unchanged.
- **Regression risk:** Medium (native build, Authenticode-signed artifacts).
  Use the `windows-desktop` and `security-audit` skills.
- **Done when:** a `while(true){}` provider ends at about 40 s on Windows
  and the CPU returns to idle.

### 4.2 Detect silent audio drops on Media3 (PB-12). Priority: P3
- Investigate first on a device with a DTS source. If confirmed, offer the
  other engine from the audio menu; no automatic switch.

## Phase 5: Platform-specific optimisations

### 5.1 Engine buffer settings, data-driven only (PB-13). Priority: P3
- **Dependencies:** 6.1 shows libmpv's rebuffer ratio clearly worse than
  Media3's for the same source types.
- **Approach:** Trial explicit cache and readahead settings in the vendored
  bridge behind a debug flag; compare the rebuffer ratio and memory on a TV
  and on Windows.
- **Done when:** a measured improvement with no memory regression in the
  soak tests.

### 5.2 Per-provider setup cost (PB-08). Priority: P3
- **Dependencies:** a measured per-run setup cost on a TV-class device.
- **Approach:** QuickJS bytecode for the bundle, or split modules. Security
  review required.

## Phase 6: Monitoring and regression prevention

### 6.1 Stage timings in the session event (PB-10). Priority: P1 (do early)
- **Files:** `playback_metrics.dart`, `analytics_events.dart`,
  `home_screen.dart` (hand the resolve time to the player),
  `playback_coordinator.dart` (prepare time), `docs/features/analytics.md`.
- **Approach:** Add `resolveMs`, `fromCache`, `providersStarted`,
  `providersTimedOut`, `prepareMs` and `attempts`. No names, hosts or URLs.
  Follow the analytics consent rules.
- **Regression risk:** Low. Analytics is opt-in and the event is additive.
- **Tests:** `playback_metrics_test`, `analytics_test`.
- **Done when:** the event carries the fields, and the analytics doc lists
  them.

### 6.2 Correct the architecture notes (PB-14). Priority: P3
- Update the Windows torrent row in `.claude/skills/reelish-architecture/architecture.md`.

### 6.3 Keep the harness in CI. Priority: P1
- The Phase 1 harness tests run in `flutter test`, which CI already runs
  before every release.
