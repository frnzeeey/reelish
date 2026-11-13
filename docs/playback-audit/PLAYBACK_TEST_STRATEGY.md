# Playback test strategy (2026-11-13)

Finding IDs refer to [PLAYBACK_AUDIT_REPORT.md](PLAYBACK_AUDIT_REPORT.md).
Nothing in this audit was run. The lists below come from reading the test
files.

## Existing coverage

**Unit and widget tests (`test/`):**

| File | Covers |
|---|---|
| `playback_reliability_test.dart` | `endedEarly`; `LinkRefreshBudget`; `PlaybackFailure.classify` (no picture, network/HTTP skipping the engine retry, engine timeout, URLs ignored, HTTP codes, cancellation); `PlaybackCoordinator` budget and ranking; `EnginePreference`; scheme routing; `Media3PlayerEngine.activate` keeping its instance; NAT64; `ProviderScriptCache`; redirect headers |
| `playback_pipeline_test.dart` | Normalisation, hop-by-hop headers, candidate bounds, Windows libmpv-only, scheduler bounds, quality selection, source policy |
| `stream_discovery_test.dart` | First source before completion, replay and dedupe, cancelled discovery ignoring later results, expiry, `startingSource` torrent grace |
| `provider_runner_test.dart` | Background isolate, calling isolate stays responsive, CryptoJS loading, error propagation, timeout |
| `stall_watchdog_test.dart`, `playback_metrics_test.dart` | Watchdog and metrics in isolation |
| `torrent_source_preparer_test.dart`, `windows_torrent_support_test.dart` | Torrent preparation and Windows support detection |
| `player_ui_test.dart`, `paused_overlay_test.dart`, `player_settings_sheet_test.dart`, `audio_tracks_test.dart`, `subtitles_test.dart`, `episode_selection_test.dart` | Player chrome, sheets, tracks, subtitles, episodes |
| `network_destination_validator_test.dart`, `provider_fetch_bridge_test.dart`, `test/provider_compat/` | Network policy and provider sandbox |

**Integration tests (`integration_test/`, on a device, one file per run):**
`windows_playback_test`, `windows_player_ui_test`, `windows_soak_test`,
`windows_torrent_test`, `libmpv_playback_test` (Windows and Android device),
`player_long_session_test` (Android memory), `media3_audio_track_test`,
`audio_track_switch_test`, `provider_runtime_test`, `torrent_streamer_test`,
`ui_perf_test` (frame timings via `flutter drive`).

## Gaps

1. **The session failure policy** (`_initialize` / `_handleFailure` /
   `_rediscoverAndPlay` / `_tick` errors) is never driven end to end
   (PB-15). That is where PB-03 and PB-04 live.
2. **Cancellation of running providers** (PB-01) and **slot contention**
   (PB-02) have no test with timing assertions.
3. **No stage timings are asserted** anywhere (resolution, prepare, pre-play).
4. **No hanging-host test:** a server that accepts the connection and never
   sends data, which is what drives the worst-case timeline.
5. **Android TV has no device-run playback test.** Phone integration tests
   apply, but D-pad flows during failure (error panel focus, Retry) are not
   covered.

## Recommended unit tests (pure Dart)

| Test | Asserts | Finding |
|---|---|---|
| Classify: live "Request was cancelled" with a current generation | not `cancelled` (or handled as unknown) | PB-03 |
| `PlaybackCancelled` type from `prepareAndOpen` | classified as `cancelled` by type, not text | PB-03 |
| Scheduler with a fake runner: cancel lookup A | both slots free within the grace; B's first provider starts immediately | PB-01 |
| Two dead top-priority providers, one fast | first source ≈ fast provider time after one demotion | PB-02 |
| `discoverStreams(fresh: true)` | returns a new discovery while one is in flight | PB-05 |
| `StreamSource.identityKey` | mixed-case header names give one key | PB-11 |
| `PlaybackMetrics` new fields | `resolveMs`, `prepareMs`, `attempts` and `fromCache` in the event; no names or URLs | PB-10 |
| Retry and timeout | the reconnect delays (1 s, 3 s) and the 2-in-2-min limit, through an injectable clock | existing behaviour |

## Recommended widget tests (fake engine harness)

Build one reusable fake `VideoPlayerPlatform` for `test/`. It is
scriptable per created player: initialize succeeds, fails with text X,
hangs; play hangs; `VideoEvent` error after N ms; buffering forever.
Register it the way `Media3PlayerEngine` registers the Android one. Then
drive `CustomVideoPlayer`:

| Scenario | Expected |
|---|---|
| First source fails 403 before playing | next source opens; no engine retry |
| First source fails "unrecognized format" | same source on the alternate engine (Android variant), then the next source |
| Playing source errors "connection reset" | "Reconnecting…", same source and engine, at the last position |
| Three reconnects within 2 min | third goes to refresh or next source |
| Hang on initialize | timeout after 20 s (fake clock) → next source |
| Hang on play | `EngineStartTimeout` → engine fallback |
| Buffering without progress | stall at 25 s → reconnect |
| Error text containing "was cancelled" while playing | error panel or next source, never a permanent spinner (PB-03) |
| Pick a source while rediscovery is pending | picked source stays (PB-04) |
| Close the player during initialize | controller disposed, no listener calls after dispose |
| Episode switch with a lookup that finds nothing | old episode resumes at its position |
| Five sources all failing | error panel "Could not play 5 sources…" |

Run the Windows variant with
`variant: TargetPlatformVariant.only(TargetPlatform.windows)` (no engine
fallback), and TV with `DeviceCapabilities.debugOverride`. On TV, check
that focus lands on the error panel's action.

## Integration tests (devices)

| Test | Platforms | Measures |
|---|---|---|
| Plugin → player with a local test provider returning a public test clip | Android, Windows | S1–S5 stage times from logs |
| Hanging host (local server that accepts and stalls) | Android, Windows | time to error panel ≤ target |
| Rapid source switching (10 picks in 10 s) | Android, Windows | one live controller at the end (`PlayerEngineGate.liveCount`), no crash |
| Rapid episode switching (Next ×10) | Android, TV, Windows | final episode plays; no stuck "Opening…" |
| Open/close ×50 | Android (`player_long_session_test`), Windows (`windows_soak_test`) | memory slope; record the numbers in the PR |
| Network drop for 30 s mid-play | Android device, Windows | reconnect, then continue at the position |
| Cancel search, then Play another title | Android, Windows | second lookup's first provider start ≤ 2 s after Play (PB-01) |
| Runaway provider (`while(true){}`) | Windows | CPU idle after the run ends (PB-09) |

Windows streams use public test clips; a libmpv `tcp: ffurl_read` error
there is the host, not a regression (CLAUDE.md).

## Stress tests

- Repeated initialization: 100 opens of the same source, recording time
  to first frame per iteration. There should be no upward trend.
- Rapid source and episode switching, as above.
- Long duration: 2 h of continuous playback on Android TV and Windows,
  recording RSS every 5 min and rebuffer ratio.
- Network interruptions: 10 drops of 5–30 s during one session; recovered
  on each within the reconnect and refresh budgets.
- Consecutive failures: 20 sessions against dead sources. The app stays
  responsive and the provider slots are free afterwards.

## Reproduction procedure (for any playback bug)

1. Debug build. Note the platform, engine, `sourceType` and scheme.
2. Capture the `[Playback]`, `[Stream]`, `[Provider Perf]` and `[Perf]`
   lines. They contain no URLs or headers.
3. Find the stage from the logs (S1–S5 in the performance report).
4. Reproduce with the fake engine harness if it is a policy bug, or with a
   local test server if it is network behaviour.

## Acceptance criteria for remediation work

- The test that reproduces the finding fails before the fix and passes after.
- `flutter analyze lib test integration_test test_driver` shows no new issues.
- `flutter test` passes.
- The platforms the change can reach have been run (`regression-check`
  skill); a platform that could not be run is named in the PR.
- Stage timings before and after are recorded for performance changes,
  on the same device and source.
