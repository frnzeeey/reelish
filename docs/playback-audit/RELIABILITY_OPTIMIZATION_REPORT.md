# Playback reliability and optimization report

The playback reliability initiative works through the findings of the
24 November 2026 architecture audit
(`REELISH_PLAYBACK_ARCHITECTURE_AUDIT.docx`) one checkpoint at a time. This
report records, for each checkpoint, what the current code was found to do,
what changed, and how it was tested. Finding numbers (PB-xx) are those of
[PLAYBACK_AUDIT_REPORT.md](PLAYBACK_AUDIT_REPORT.md).

| Checkpoint | Status |
|---|---|
| 0. Baseline | Done (27 November 2026) |
| 1. Fresh candidates during link refresh (PB-05) | Done (27 November 2026) |
| 2. Production stage attribution (PB-10) | Done (27 November 2026) |
| 3. Resume and pre-play latency (PB-06, PB-07) | Measured on Windows (27 November 2026); no change. Android not measured |
| 4. Discovery network competition (PB-23) | Sensitivity measured on Windows (27 November 2026); no change. Real provider traffic not measured |
| 5. Episode switch and rediscovery (PB-04) | Reproduced and fixed (27 November 2026) |
| 6. Source identity (PB-11) | Inconsistency confirmed and fixed (27 November 2026) |
| 7. Cross-platform regression | Windows and Android emulators run (27 November 2026); no physical Android device. Continuous |

## 0. Baseline

- **Code:** `main` at `d68275e` (v1.43.1). No playback file changed between
  the audit and this baseline, so the audit described the current code;
  every finding was still checked against the source.
- **Toolchain:** Flutter 3.44.8, Dart 3.12.2. Player packages as the audit
  lists them: video_player 2.14.1, video_player_android 2.12.2, media_kit
  1.2.6, media_kit_libs_android_video 1.3.8, media_kit_libs_windows_video
  1.0.11, vendored video_player_media_kit 2.0.0.
- **Tests:** `flutter test`: 1913 passed, 4 skipped, 0 failed.
  `flutter analyze lib test integration_test test_driver`: infos only.
  Docs check passed.
- **Devices:** Windows only. No Android phone, Android TV, Google TV or
  emulator was connected; nothing Android-specific was run on hardware.

### Findings against the current code

| Finding | Status |
|---|---|
| PB-05 refresh reuses the running lookup | Confirmed. `discoverStreams` returned the in-flight lookup, `_rediscoverAndPlay` matched the failed source by name, provider and description, and reset the attempt history. A dead link could use both link refreshes (up to 20 s each) before another source was tried. |
| PB-10 production attribution | Confirmed. `open` is measured but not sent; no discovery, cache, provider-count, preparation or attempt fields; `first_frame_ms` starts at player open, not at Play. Analytics exists on Android only. |
| PB-06, PB-07 sequential pre-play steps, resume seek | Code paths confirmed; impact unmeasured. |
| PB-23 discovery during startup | Confirmed; unmeasured. |
| PB-04 episode switch race | Path confirmed, narrow; earlier advice (no plain generation guard) still holds. |
| PB-11 three identity keys | Confirmed. Only effect found: duplicate rows in the source sheet for the same link with differently cased header names. Attempt accounting uses one key (`PlaybackCoordinator.sourceKey`). |
| PB-09 Windows QuickJS deadline | Already resolved. |
| PB-15 no test drives the failure policy | Out of date: `player_session_test` drives fallbacks, reconnects and timeouts through a scripted engine. It did not cover link refresh. |

## 1. Fresh candidates during link refresh (PB-05)

**Root cause.** `ProviderPluginService.discoverStreams` shares one
`StreamDiscovery` per title, episode and filter key while it runs (up to
60 s after Play). The player's refresh (`onRediscover` from Home) used the
same key, so during that window it got the original lookup back. Its
sources include the link that just failed, and `_rediscoverAndPlay`
preferred that one.

**Change.**

- `discoverStreams` takes `fresh` (default false). A fresh lookup is a new
  `StreamDiscovery` running through the same `streams()` worker pool and the
  service's single `ProviderExecutionScheduler`, so the limits (4 workers per
  lookup, 2 QuickJS runtimes in all) are unchanged. It does not cancel the
  running lookup; it becomes the shared entry for later calls.
- Home's `onRediscover` passes `fresh: true`. Every caller of
  `onRediscover` is a refresh: Retry, a failed cached link, and a dead link
  (`_refreshDeadLink`).
- The player keeps its subscription to the first lookup and gives the
  refresh its own (`_rediscoverySubscription`). Before, the refresh replaced
  the only subscription; with a separate lookup that would have dropped the
  first lookup's late sources.
- If `onRediscover` hands back a lookup the player already follows (the
  first one or the previous refresh), the player declines the refresh and
  the failure policy continues (other engine, next source). It never
  cancels the first lookup, which Home owns.

**Unchanged.** `LinkRefreshBudget` (2 refreshes per session), the one
cached-link refresh, the attempt budget of 5 distinct sources per candidate
set, engine fallback, reconnects, ranking and cancellation. A refresh still
cancels the refresh before it.

**Deliberate limit.** A genuinely new lookup may return exactly the same
URL and headers (stable links). That link is tried again, since after a
network drop it can work; this is bounded by the refresh budget. Excluding
it would have changed recovery for stable links without evidence.

**Trade-off accepted.** While the first lookup is still running, a refresh
runs the same providers again and waits behind it for the two runtime
slots. The first lookup is kept for its late sources (decision of
27 November 2026).

**Files.** `lib/src/services/provider_plugin_service.dart`,
`lib/src/screens/home_screen.dart`,
`lib/src/widgets/player/custom_video_player.dart`,
`test/player_session_test.dart`, `test/provider_lookup_scheduling_test.dart`.

**Tests added.**

| Test | Covers | Fails without the change |
|---|---|---|
| `player_session_test`: a refresh that hands back the running lookup does not reopen the dead link | Failed link not retried through a shared lookup; first lookup not cancelled; late source used | Yes (dead link reopened) |
| `player_session_test`: a fresh lookup renews the link, and the first lookup's late sources still arrive | Renewed link plays; late result of the first lookup still becomes a candidate | Yes (late source lost) |
| `player_session_test`: a link that keeps dying is refreshed at most the budget | Refresh budget holds; each refresh cancels the one before; first lookup untouched | No (guards existing behaviour) |
| `provider_lookup_scheduling_test`: a refresh starts its own lookup and leaves the running one going | New object; sharing still applies without `fresh`; both lookups deliver; at most 2 runtimes at once | n/a (new API) |
| `provider_lookup_scheduling_test`: cancelling a refresh stops it and nothing else | Cancellation reaches running providers of the refresh only | n/a |
| `provider_lookup_scheduling_test`: a refresh that finds nothing does not stand in for later lookups | A finished empty refresh leaves the in-flight map | n/a |

The provider tests use real QuickJS runtimes with stand-in scripts; the
player tests use the scripted engine (`FakeVideoPlayerPlatform`) on a
platform without Media3 or libmpv.

**Not verified.** Real providers, Media3 and libmpv on devices, Android TV,
Google TV. The change is in shared Dart code with no platform branches, so
it reaches every interface the same way; the engine-specific steps of the
failure policy were not exercised.

## 2. Production stage attribution (PB-10)

**Problem.** `playback_session` could not say whether a slow or failed start
was the providers, Reelish, the address checks or the engine. Its clock
starts when the player opens, so discovery was invisible; `open` was
measured but not sent; and a Play that never reached the player sent
nothing at all.

**Constraints kept.**

- Opt-in only, through the existing `AnalyticsService` (Firebase on Android).
  No new vendor, backend or event pipeline.
- The analytics policy: no provider, plugin or repository names, no stream
  URLs, hosts or headers, no titles. The existing test that forbids
  `provider`, `url`, `title` and similar words in parameter names is kept as
  it was; the new names use `lookup_…` instead.
- Firebase drops parameters past 25 without a word. `playback_session` can
  now carry 24; a test pins the fully populated event at 25 or fewer.
- `PlaybackMetrics` still never holds URLs, headers, provider names or
  titles: it keeps only a `LookupStats` (counts and one duration), not the
  lookup and its sources.

**Change.**

| Stage asked for | Where it is now |
|---|---|
| Play request, cached-link lookup | `source_origin` (`cache`/`auto`/`manual`), `resolve_ms` (Play to player; left out for `manual`, which includes the viewer's time) |
| Discovery started, first candidate | `first_source_ms` (lookup start to first playable source) |
| Provider execution, discovery timed out | `lookup_stalled` (runs that timed out or took 10 s without a source: the rule that already demotes providers); `source_lookup` adds `lookup_runs` and `lookup_failed` |
| Source preparation | `prepare_ms` (of the attempt that first opened) |
| Engine initialization | `open_ms` (`open_ms − prepare_ms` is the engine) |
| Playback started, first frame | Existing `play_to_frame_ms`, `first_frame_ms` |
| Rebuffering, stalls | Existing `rebuffers`, `rebuffer_ms`, `rebuffer_pct`, `stalls` |
| Recovery, rediscovery, source switching | Existing `recoveries`, `recovered`; new `recovery_ms` and `opens` |
| Session ended | Existing: one event at close (`report` is idempotent) |
| A Play that never opened the player | New `source_lookup`: `outcome` `no_source`, `cancelled` or `declined`, `lookup_ms`, counts |

Unavailable, skipped and failed stages are told apart by leaving a
parameter out rather than sending zero: no `first_source_ms` without a
lookup or before a source, no `prepare_ms`/`open_ms` when nothing opened, no
`resolve_ms` for a picked source. Cancellation before the player is
`source_lookup` with `cancelled`; after it, the existing `abandoned`.

**What is not sent, on purpose.** Per-provider durations (they would need a
provider identity); the number of providers that ran in a session that
played (the 25-parameter limit; `source_lookup` has it for failed Plays).

**Windows.** `AnalyticsService` does nothing on Windows, as before. The same
stages are printed in the debug and profile summary line
(`[Playback][Summary] … prepare= opens= origin= resolve= firstSource=
lookup=…`), not in release.

**Files.** `lib/src/analytics/analytics_events.dart` (fields, `SourceOrigin`,
`LookupOutcome`, `source_lookup`), `lib/src/services/playback_metrics.dart`
(`SourceResolution`, stages, summary), `lib/src/services/stream_discovery.dart`
(`LookupStats`), `lib/src/services/provider_plugin_service.dart` (reports
each run to the lookup), `lib/src/services/playback_coordinator.dart`
(`prepareAndOpen` returns the preparation time),
`lib/src/screens/home_screen.dart` (Play clock, origin, `source_lookup`),
`lib/src/screens/player_screen.dart` and
`lib/src/widgets/player/custom_video_player.dart` (pass the resolution, count
opens). Docs: `docs/features/analytics.md`.

**Intentional behaviour changes.** The debug summary line gained `prepare=`,
`opens=` and, when Home measured them, the stages before the player; two
`playback_metrics_test` expectations were updated for it. `playback_session`
always carries `opens` and `recovery_ms`; one `analytics_test` expectation
was updated.

**Tests added.**

| Test | Covers |
|---|---|
| `analytics_test`: a session found by a lookup reports where its start-up time went | Every stage, values, at most 25 parameters |
| `analytics_test`: stages that did not run are left out | Cache (no lookup), manual (no resolve time), nothing opened, no Home measurements |
| `analytics_test`: a session that closes while recovering counts the time so far | `recovery_ms` with a recovery still running |
| `analytics_test`: stage parameters never carry the stream, host, headers, provider or title | Privacy: a source full of secrets, values only numbers or fixed words |
| `analytics_test`: a Play that never opens the player is one lookup event, only after yes | Consent, event shape |
| `analytics_test`: names and parameters meet Firebase limits; no event can carry source details | Extended to the full session and every `source_lookup` outcome |
| `provider_lookup_scheduling_test`: a lookup counts runs and failures, not the runs it stopped | Real QuickJS: failure counted, cancelled run not |
| `provider_lookup_scheduling_test`: providers that wasted their slot run after the others | Now also checks `stalled` matches the demotion |

**Not covered by a test.** Home's Play flow has no widget-test harness, so
the `source_lookup` call sites and the origin/resolve values are verified by
reading the code: each is on a path that returns at once, so one Play sends
at most one `source_lookup`, and only when the player does not open. Not run
on a device, so no real values have been seen in Firebase yet.

## 3. Resume and pre-play latency (PB-06, PB-07)

**Question.** Do the steps between `initialize()` and `play()` (PB-06), or
opening at the start and then seeking to the resume point (PB-07), add
meaningful start-up time?

**Method.** `integration_test/startup_latency_test.dart` opens public test
clips on the real engine and times each step in the order
`CustomVideoPlayer._initialize` runs them: `initialize`, both track lists at
once (2 s cap), volume, the resume seek (2 s cap), `play`, and first frame,
which is the player's own test (the position moves after play). Each clip is
opened fresh and resumed, alternating, three times; one clip per process.
Positions arrive about every 100 ms, so play-to-frame is that coarse.

**Conditions.** Windows 11 desktop (the development machine), libmpv
through media_kit, debug build under `flutter test`, the office network
(not throttled). Public CDNs, not provider hosts. Measured
27 November 2026.

**Results (Windows, libmpv; medians in ms; n = 3 unless noted).**

| Clip | Mode | init | tracks | volume | seek | play | play to frame | init to frame | total |
|---|---|---|---|---|---|---|---|---|---|
| HLS (Mux) | fresh | 2108 | 0 | 2 | - | 4 | 101 | 111 | 2215 |
| HLS (Mux) | resume 5:00 | 2130 | 0 | 3 | 0 | 0 | 410 | 416 | 2546 |
| DASH (Akamai, 4K) | fresh (n = 3, one open per process) | 4281 | 1 | 3 | - | 11 | 100 | 118 | 4400 |
| DASH (Akamai, 4K) | resume 5:00 (n = 4, one per process) | 3940 | 1 | 3 | 1 | 1 | 609 | 618 | 4740 |
| MP4 | fresh | 746 | 0 | 3 | - | 1 | 102 | 109 | 855 |
| MP4 | resume 0:06 | 710 | 0 | 4 | 0 | 10 | 205 | 222 | 926 |
| MP4 + Referer header | fresh | 685 | 0 | 2 | - | 1 | 102 | 109 | 795 |
| MP4 + Referer header | resume 0:06 | 691 | 0 | 6 | 0 | 11 | 207 | 231 | 923 |
| MKV | fresh | 672 | 0 | 2 | - | 1 | 105 | 112 | 781 |
| MKV | resume 0:06 | 698 | 0 | 4 | 0 | 11 | 205 | 225 | 922 |

One DASH resume took 2300 ms to the first frame with one rebuffer; the
median above includes it. The first open of a host in
a fresh process took 17–20 s once (HLS, DASH: connection and CDN warm-up on
this machine); it is not in the per-clip runs above.

**Findings.**

- **PB-06: not a problem on Windows.** Tracks, volume and `play` together
  take 3–25 ms. `seekTo` returns in about 1 ms (the bridge does not wait for
  the seek), so its 2 s cap never applies; the seek's real cost lands in
  play-to-frame. Nothing to change.
- **PB-07: real but small on Windows.** A resumed start reaches its first
  frame about 100 ms later for progressive files, 300 ms for HLS and 500 ms
  for DASH. Measured against the whole start (0.8–4.7 s, mostly `initialize`
  on the network), that is 10–15%. Opening at the resume position (libmpv's
  `start` option, through the vendored bridge) could save at most that, and
  would change how every resumed open starts. **Decision: no change.** The
  evidence does not justify the risk.
- `initialize` dominates start-up everywhere (0.7 s for small progressive
  files, 2–4 s for HLS and DASH), and that is the network and the stream,
  not Reelish's steps.

**Not measured.** Android Media3 and Android libmpv (no device was
connected; the same test measures both), Android TV and Google TV hardware,
throttled or slow networks, real provider hosts, the audio-track switch
before play (it runs only when the preferred language differs), and the
speed step (only when the speed is not 1). PB-07's concern is larger on
Media3, which buffers from the start before `initialize()` completes; run
this test on a TV before deciding there.

## New finding: PB-24, a second DASH open ends the Windows process

- **Evidence:** reproduced in 8 of 8 measurement processes on Windows. The
  first DASH open (fresh or resumed) plays; the next DASH open in the same
  process (after the first player was disposed) ends the process during
  `initialize`, after `NativeVideoController: Texture ID` and an empty
  `tracks discovered` line. HLS, MP4 and MKV reopen without trouble in the
  same harness (18 opens each). Windows logged no application error. The
  stream is Akamai's `bbb_30fps.mpd`, which libmpv decodes at 3840×2160.
- **Why it matters:** the app opens a source again on a reconnect, another
  source, the other episode, or a new title. A Windows viewer whose
  provider returns DASH may lose the app on the second open in a session.
- **Not yet known:** whether it is DASH, 4K output, hardware decoding, or
  the media_kit video output being reused after a large texture; whether the
  real player (not just the harness) does it; whether Android libmpv does.
  `windows_playback_test` opens DASH once per process, so it never caught it.
- **Status:** investigated (below); mitigated on 27 November 2026 by a Windows guard (below). Real fix pending.

### PB-24 investigation (27 November 2026)

A temporary probe (since removed; the regression test below replaces it) opened a chosen
sequence of clips through the real bridge (`MpvPlayerEngine`), one process
per experiment, on Windows 11.

| Experiment | Result | Reading |
|---|---|---|
| 4K DASH, then 4K DASH | Process ends in the second `initialize` | Reproduces |
| 1080p DASH (Envivio), twice | Ends | Not 4K-specific |
| DASH twice, `initialize` only, never played | Ends | Playing is not involved |
| DASH, then HLS | Both play | Only a later DASH open fails |
| HLS three times | All play | Control |
| DASH twice, 5 s and 10 s apart | Ends | Not media_kit's delayed core teardown (`mpv_terminate_destroy` 5 s after `dispose`) |
| DASH kept open while a second DASH opens | Ends | No disposal at all: the second manifest parse in the process is the trigger |

The process exit code captured during the failure is `0xC0000005`, a native
access violation. No application error is logged and no Dart exception is
raised, so nothing in Reelish can catch it.

**Root cause (high confidence, not proven by a native stack).** The bundled
libmpv (`media_kit_libs_windows_video` 1.0.11: mpv v0.36.0-403, FFmpeg
n6.0, libxml2 linked in) parses DASH manifests with FFmpeg's `dashdec`,
which calls libxml2's process-wide `xmlCleanupParser()` at the end of every
manifest parse (`libavformat/dashdec.c`, `parse_manifest`, lines 1359–1362
at n6.0; still present in FFmpeg master as downloaded on this date). That
tears down libxml2's global state; the next manifest parse in the same
process then crashes. Upstream: FFmpeg ticket #11236 (crash in
`xmlCleanupParser` from `parse_manifest`) and an unmerged October 2024
patch removing the call. No debugger was available to capture the crashing
frame.

**Scope.**

- Windows: every libmpv DASH open after the first in an app session,
  including a reconnect of the same DASH source, another source, the next
  episode or a new title.
- Android: DASH over HTTPS opens on Media3, which has its own parser, so the
  default path is not affected. Android's libmpv (the fallback after a
  Media3 failure) was not tested.
- A DASH source whose URL and provider metadata do not say DASH is still
  sniffed by libmpv as DASH, so Reelish cannot always know in advance.

### PB-24 mitigation (27 November 2026)

**Change.** `WindowsDashGuard` (`lib/src/services/player_engine.dart`):
on Windows, `MpvPlayerEngine.createController` lets one DASH source through
per app session and throws `DashReopenUnsupported` for any later one,
before libmpv sees it. `PlaybackFailure.classify` maps it to `format`, so
the existing policy moves to the next source with no reconnect and no link
refresh (`linkMayHaveDied` is false for `format`; Windows has no other
engine). If nothing else plays, the error screen says "Windows can play one
DASH stream per session. Try another source, or restart Reelish to play
this one."

**Why this shape.** The crash is native and process-wide, so nothing can
catch it once libmpv parses the manifest; the only safe point is before
the open. Checking at `createController` covers every path that opens a
source (first open, reconnect, another source, episode change, manual pick).
The first DASH open is counted when its controller is created, even if it
then fails before parsing: holding back one DASH source too many is better
than a crash.

**Limits.** Only sources Reelish recognizes as DASH are held back (provider
hint, `application/dash+xml`, `.mpd` path); a DASH stream without those
signs still reaches libmpv and can still crash. A second DASH source in a
session does not play on Windows until restart. Android unchanged.

**Files.** `lib/src/services/player_engine.dart` (guard and exception),
`lib/src/services/playback_coordinator.dart` (classification and message),
`test/playback_reliability_test.dart`,
`integration_test/windows_playback_test.dart`,
`integration_test/startup_latency_test.dart` (note), docs
`docs/playback/platform-player-engines.md`, `docs/playback/troubleshooting.md`.

**Tests.**

| Test | Result |
|---|---|
| `playback_reliability_test`, group "one DASH stream per session on Windows" (5 tests: a second and a repeated DASH open refused, other formats never held back, Android unchanged, classification and message, engine refuses before libmpv) | Pass |
| `windows_playback_test`: a second DASH stream is refused instead of ending the app, and other formats still play (real libmpv) | Pass; with the refusal disabled the app ends ("did not complete"), as before the change |
| `windows_playback_test`, all 10 | Pass |

**Next (real fix).** A Windows libmpv whose FFmpeg does not call
`xmlCleanupParser()` (the unmerged upstream patch), or one whose libxml2
survives it. Try a newer libmpv build locally against the regression test
first; replacing the bundled DLL needs a security review and a release
decision.

## 4. Discovery network competition (PB-23)

**Question.** The provider lookup keeps running after playback starts, so
later sources can serve as fallbacks. Does its work slow the start or cause
early buffering?

**Method.** `integration_test/discovery_competition_test.dart` plays a
10 s, 0.8 Mbit/s MP4 (Big Buck Bunny, downloaded once) from a local server
through an emulated link: one bandwidth cap shared by every connection, so
the video and the competing load divide it as on a home line. The load
starts 1 s before the player opens, as a lookup already running would, and
stops when the measurement ends:

| Load | Stands in for |
|---|---|
| none | The lookup finished or cancelled |
| light | Two providers scraping: 150 KB pages, 300 ms apart |
| heavy | Four workers downloading without pause (the worker limit; worst case) |
| cpu | Two QuickJS runtimes busy computing, no network (the runtime limit) |

Each case three times, rotating the order, on libmpv. Measured: Play to
first frame, and stalls in the next 6 s.

**Conditions.** Windows 11 desktop, debug build, loopback server; the links
are emulated (1.5 and 8 Mbit/s), the load is a stand-in. Real provider
traffic was not measured: running community provider scripts against their
sites from a development session was out of scope.

**Results (medians; all 24 opens played).**

| Link | Load | Open (`initialize`) | Play to first frame | Start total | Stalls in 6 s |
|---|---|---|---|---|---|
| 1.5 Mbit/s | none | 717 ms | 103 ms | 824 ms | 0 |
| 1.5 Mbit/s | light | 1285 ms | 102 ms | 1395 ms | 1 (773 ms) |
| 1.5 Mbit/s | heavy | 3411 ms | 101 ms | 3519 ms | 2 (3804 ms) |
| 1.5 Mbit/s | cpu | 713 ms | 103 ms | 819 ms | 0 |
| 8 Mbit/s | none | 361 ms | 103 ms | 471 ms | 0 |
| 8 Mbit/s | light | 368 ms | 101 ms | 479 ms | 0 |
| 8 Mbit/s | heavy | 760 ms | 106 ms | 866 ms | 0 |
| 8 Mbit/s | cpu | 362 ms | 101 ms | 471 ms | 0 |

Repeats agreed within a few percent.

**Findings.**

- On a slow link the effect is large: light scraping adds about 0.6 s to
  the start and a stall soon after; heavy traffic adds 2.7 s and nearly
  4 s of stalls. On an ordinary link only the heavy case shows, at +0.4 s
  and no stalls.
- Provider CPU (two busy runtimes) does not affect start-up on this
  desktop. TV hardware has far fewer and slower cores; not measured.
- Whether this happens to viewers depends on how much traffic real
  providers make after the first source is chosen, which this measurement
  cannot say. The lookup can keep up to four providers working for up to
  60 s after Play.

**Decision: no change yet.** The sensitivity is real, but changing the
lookup would cost fallback sources, and there is no evidence yet of how
much real provider traffic runs during start-up. Before changing anything:

1. Measure real provider traffic during start-up on a device, with the
   viewer's own providers: bytes fetched per provider run after the first
   source (a debug-only count in the fetch bridge would give it).
2. If it is substantial, the smallest change that keeps fallbacks would be
   to hold back providers that have not started yet (not stop running
   ones) from when the player opens until its first seconds have buffered,
   and to release them at once if that source fails. It must not change
   the 60 s cap, the worker or runtime limits, or cancellation.

**Fallback coverage.** Unchanged behaviour, already covered:
`player_session_test` (late sources of the first lookup still become
candidates; a new source arriving after a failure is tried) and
`provider_lookup_scheduling_test`.

**Not measured.** Real provider traffic; Android and TV hardware (CPU
variant especially); real network conditions (latency, loss) beyond a
bandwidth cap; HLS (many segment requests) instead of one progressive file.

## 5. Episode switch and rediscovery (PB-04)

**Question.** A link refresh waits for a provider's first source. If the
viewer moves to another episode meanwhile, does the refresh still open the
old episode?

**Paths that can start a switch during a refresh.** The remote's or
keyboard's next-track key (accepted while loading, TV and Windows layouts);
the auto-next countdown, whose timer keeps running if the stream drops
during the credits; a Watch Party host changing episode
(`_PartyHandle.remoteEpisode`). All go through `_playEpisode`.

**Reproduced** in `player_session_test` (scripted engine, TV layout,
next-track key) on the code before this change:

- The refresh finds a link while the next episode is being looked up: the
  old episode opens again and plays behind the switch (two players where
  one is expected).
- The new episode's player then fails to open after this player released
  its engine: the old episode is opened twice.

**Root cause.** `_rediscoverAndPlay` awaits the refresh's first source and
then calls `_initialize` without checking for a switch in progress.

**Change** (`custom_video_player.dart`). While `_switchingEpisode` is set,
a refresh that finds a source keeps it (`_sourceAfterSwitch`) instead of
opening it. When the switch completes, this player is replaced and the
source is dropped. When it falls through (no stream for the next episode,
or the new player did not open after the engine was released), the old
episode reopens with that refreshed source rather than the dead one. No
generation guard was added, so a refresh outside a switch, and every other
recovery path, is unchanged, as the audit advised.

**Tests** (`player_session_test`, group "episode switch during a link
refresh"):

| Test | Before the change | After |
|---|---|---|
| A link found while the next episode is looked up does not reopen the old episode | Fails (old episode reopened) | Pass |
| When the next episode finds no stream, the old one resumes with the refreshed link | Pass | Pass |
| When the new episode's player does not open after the engine was released, the old one resumes with the refreshed link | Fails (opened twice) | Pass |
| A refresh with no switch still plays the renewed link at once | Pass | Pass |
| A next episode that finds no stream leaves the playing episode playing; repeated presses ask once | Pass | Pass |
| The auto-next countdown moves on during a refresh without reopening the old episode (added after checkpoint 7) | Fails (old episode reopened) | Pass |
| A Watch Party guest following the host to the next episode during a refresh does not reopen the old episode (real `WatchPartyController` on a fake socket; added after checkpoint 7) | Fails (old episode reopened) | Pass |

Disabling the change again makes exactly the first and third fail, and the
two tests added later.

**Test harness note.** `StorageService` runs every save on one app-wide
queue; a save started under an earlier test's fake clock never finishes and
held later tests' saves. The session tests now call the existing
`StorageService.debugResetWrites()` in `setUp`, and the switch tests give
the position save real time (`tester.runAsync`). Flutter's Linux key
simulation has no media keys, so the next-track key is sent as an Android
key event, as a TV remote sends it.

**Not verified.** A real device or provider; Windows' keyboard path (the
same handler); the Watch Party host's own episode change (the key path plus
a message to the room). Auto-next and a guest following the host are now
driven by tests of their own (above).

## 6. Source identity (PB-11)

**Question.** Three places decided whether two results are the same source,
each with its own key: the provider search's final de-duplication
(`ProviderPluginService.streams`), the lookup (`StreamDiscovery._key`) and
the player's candidates and attempts (`PlaybackCoordinator.sourceKey`, also
used for reconnect limits, link refreshes and engine fallback). Do they
disagree in a way that matters? No key is ever saved, so changing it
cannot affect stored data.

**Confirmed on the code before the change** (`test/source_identity_test.dart`,
then `provider_lookup_scheduling_test` with real QuickJS):

| Case | Lookup | Player | Verdict |
|---|---|---|---|
| Same link, headers in another order | 1 | 1 | Consistent |
| Same link, header names in another case (`Referer` / `referer`) | 2 | 1 | **Inconsistent**: listed twice, one candidate |
| Different `Authorization` values | 2 | 2 | Consistent, correct |
| Different signed URLs or query parameters | separate | separate | Consistent, correct |
| Identical request from two providers | 1 | 1 | Consistent (first provider's kept) |
| Two different torrents given only by info hash | **1** | **1** | **Wrong**: all such torrents shared one key (their empty URL); only the first survived a lookup |
| One torrent's different files | **1** | **1** | **Wrong**, same cause |
| After trying one hash-only torrent | - | others counted as tried | **Wrong**: fallback could never reach them |

The torrent case is beyond the audit's description. Hash-only results are
the Stremio torrent shape, so torrent providers lost all but their first
result wherever torrents play (64-bit Android, and Windows with its
bundled torrent engine).

**Change.** One rule, `StreamSource.identityKey`
(`lib/src/models/stream_source.dart`), used by all three:

- A link: its exact URL (query and signature included) and its headers,
  names lower-cased and sorted, values exact. For every non-torrent source
  this is the coordinator's previous key, character for character (a
  header name present twice in different case is now ordered
  deterministically), so
  attempts, reconnects, link refreshes and engine fallback are unchanged
  for them; the lookup and the provider search now merge only what the
  player already treated as one.
- A torrent given by info hash alone: `torrent:<hash, lower-case>#<file>`.
  A magnet link: its URL and headers plus its file index.
- Not the provider: the identical request from two providers stays one
  source, as before in all three places.

**Files.** `lib/src/models/stream_source.dart`,
`lib/src/services/stream_discovery.dart`,
`lib/src/services/provider_plugin_service.dart`,
`lib/src/services/playback_coordinator.dart`; docs
`docs/playback/provider-integration.md`.

**Tests.**

| Test | Before | After |
|---|---|---|
| `source_identity_test`: headers in another order | Pass | Pass |
| `source_identity_test`: header names in another case | Fail (2 / 1) | Pass |
| `source_identity_test`: different authorization values | Pass | Pass |
| `source_identity_test`: different signed URLs or query parameters | Pass | Pass |
| `source_identity_test`: identical request from two providers | Pass | Pass |
| `source_identity_test`: torrents given only by info hash | Fail (1 / 1) | Pass |
| `source_identity_test`: one torrent's different files | Fail | Pass |
| `source_identity_test`: same torrent, hash in either case | Pass | Pass |
| `source_identity_test`: trying one hash-only torrent leaves the others untried | Fail | Pass |
| `source_identity_test`: a link with headers in another case counts as tried | Pass | Pass |
| `provider_lookup_scheduling_test`: torrents given only by info hash each survive the search (real QuickJS) | Fail (`['One']`) | Pass |

**Not verified.** Real torrent providers; torrent playback on an Android
device (the torrent engine itself is unchanged).

## 7. Cross-platform regression (27 November 2026)

**What was available.** One physical device: the Windows 11 development
desktop. Android emulators on the same PC: a phone (Pixel 10 Pro image,
Android 17, x86-64) and a Google TV (Android 16, x86-64, leanback). No
physical Android phone, Android TV or Google TV, and no second device for a
mixed Watch Party. Emulator results show that the Android code paths run;
they say nothing about real decoders, TV hardware, remotes or HDMI audio.

No code changed in this checkpoint. The unit and widget suite last ran
after checkpoint 6 on the same code: 1946 passed, 4 skipped, 0 failed.
Two tests added afterwards bring it to 1948.

### Integration runs

Each file ran on its own (`flutter test integration_test/<file> -d <device>`),
with the debug build, against public test media.

| File | Windows (physical) | Phone emulator | Google TV emulator |
|---|---|---|---|
| `windows_playback_test` (HLS, DASH, MP4, MKV, speed, headers and redirects, dead stream, lost connection, end of title, close and reopen, second DASH refused) | 10/10 | n/a | n/a |
| `windows_player_ui_test` (keyboard, mouse, fullscreen, volume, mute, advisory) | 4/4 | n/a | n/a |
| `audio_track_switch_test` (libmpv: MKV, DASH, HLS TS and fMP4) | 4/4 (see below) | not run | not run |
| `audio_track_metadata_test` (libmpv) | 4/4 | not run | not run |
| `windows_torrent_test` (a real torrent through the bundled engine and libmpv) | 1/1 | n/a | n/a |
| `provider_runtime_test` (real QuickJS limits) | 4/4 | 4/4 | 4/4 |
| `libmpv_playback_test` | 1/1 | skipped (by design: libmpv is unreliable on emulators) | not run |
| `media3_audio_track_test` (Media3: DASH, MKV, HLS TS and fMP4) | n/a | 4/4 | 4/4 |
| `player_long_session_test` (24 opens and closes, memory) | n/a | 1/1 | 1/1 |
| `torrent_streamer_test` (64-bit torrent engine) | n/a | 1/1 | 1/1 |
| `app_smoke_test` (launch, Plugins, Plugin Library) | 1/1 | **fail** (see below) | not run |

Not run: `windows_soak_test` (long memory run), `windows_update_channel_test`
and `together_layout_test` (no playback change), and the two measurement
harnesses, which ran in checkpoints 3 and 4.

**Failures and how each was resolved.**

- `audio_track_switch_test` on Windows failed twice before passing.
  1. The first run lost the MKV clip mid-read (`tcp: ffurl_read`), which
     the repository treats as the host. The other three tests then failed
     only because the test binding was left broken.
  2. The next two runs ended natively (`0xC0000005`) within 5 s, before any
     track switch. Both printed `NativeReferenceHolder: Located` where every
     clean run prints `Allocated`: media_kit picked up player references
     from an earlier process and freed them. The same tests passed alone,
     and the whole file then passed 4/4.

  This looks like a test-harness effect after an abnormal exit. It is not
  connected to the playback changes: the only change on this path is the
  DASH guard, which does nothing for MKV. It was not investigated further.
- `app_smoke_test` on the phone emulator waited 30 s for the dock and
  timed out. The test signs no one in, and `AccountGate` shows sign-in to
  anyone not signed in, so a freshly installed app cannot reach the dock.
  On Windows it passed because a session from earlier use is kept in this
  PC's secure storage. It plays nothing. This was inferred from the code,
  not confirmed with a screenshot.
- The Google TV emulator first ran with its clock 21 days behind (it
  resumed an old snapshot). Media3 then failed every HTTPS clip with a
  source error, and the system log showed TLS failures. Even so, every
  Media3 failure moved to libmpv for the same source, which shows Android's
  engine fallback working. After a cold boot set the clock, the tests
  were run again; the TV column shows those results. One rerun hung
  because the TV launcher took the foreground straight after boot and
  Android froze the test app; it was stopped and run again.

**Media3 timings on the phone emulator** (`player_long_session_test`; 24
sessions over MP4 and HLS; emulator on a desktop, not a device): the first
session took 5.4 s to its first frame, later ones 0.36Ã¢â‚¬â€œ1.09 s, with no
rebuffers and no failures. On the Google TV emulator (clock corrected) the
same 24 sessions all played on Media3 with no failure and no fallback, at
0.26–0.79 s to the first frame (1.6 s once). The new summary fields
(`prepare=`, `opens=`) appeared on Android as on Windows.

### Compatibility matrix

- **Device:** a runtime check on physical hardware.
- **Emulator:** a runtime check on an Android emulator.
- **Logic:** unit or widget tests only (scripted engine, no media).
- **No:** not verified.

| Behaviour | Android phone | Android TV / Google TV | Windows |
|---|---|---|---|
| Primary engine opens and plays | Emulator (Media3) | Emulator (Media3) | Device (libmpv) |
| Other engine after a failure | Logic | Emulator (Media3 Ã¢â€ â€™ libmpv, during the bad-clock run) | n/a: no other engine (Logic: `playback_pipeline_test`) |
| libmpv on Android | No (skipped on emulators) | No | n/a |
| HLS | Emulator | Emulator | Device |
| DASH | Emulator (Media3) | Emulator (Media3) | Device: first open; a second is refused (PB-24) |
| MP4 / MKV | Emulator | Emulator | Device |
| Request headers and redirects | Logic | Logic | Device |
| Audio tracks | Emulator (switching) | Emulator (switching) | Device (switching and naming) |
| Subtitles | Logic (`subtitles_test`) | Logic | Logic |
| Resume | Logic | Logic | Device (resume seek, checkpoint 3) |
| Recovery: reconnect, next source, link refresh | Logic (`player_session_test`, `playback_reliability_test`) | Logic | Device for the errors that start it (dead stream, lost connection); Logic for the policy |
| Source switching | Logic | Logic | Device (close and reopen); Logic for the switch |
| Episode transitions | Logic (`player_session_test`, `episode_selection_test`) | Logic (TV next-track key) | Logic |
| Lifecycle interruptions (background, PiP) | Logic (`player_pip_test`) | No | n/a |
| Remote / D-pad navigation | n/a | Logic (`tv_support_test`, `tv_layout_test`) | Logic plus Device (keyboard, controller) |
| Torrents | Emulator (engine streams) | Emulator (engine streams) | Device |
| Provider sandbox limits | Emulator | Emulator | Device |
| Memory over repeated opens | Emulator | Emulator | Not run (soak) |
| Watch Party: readiness, buffering, commands, drift, recovery, episode follow, host and guest | Logic (`watch_party_test`, `watch_party_reliability_test`) | Logic | Logic |
| Watch Party across devices | No | No | No |

### Regression checklist (brief, section 7)

| Item | Evidence | Level |
|---|---|---|
| Movie playback | Windows integration; emulator Media3 | Device (Windows), Emulator |
| Series playback, episode selection | `episode_selection_test`, `player_session_test` | Logic |
| Automatic episode selection, previous and next | `episode_selection_test` (season boundaries, first and last) | Logic |
| Auto-next | Next-episode card (`player_ui_test`); the countdown switching during a refresh (`player_session_test`) | Logic |
| Automatic and manual source selection | `playback_reliability_test` (ranking), `player_ui_test` (source sheet) | Logic |
| Late provider results | `player_session_test`, `provider_lookup_scheduling_test` (real QuickJS) | Logic |
| Provider filtering, enablement and priorities, torrent preferences | `playback_pipeline_test` (source policy), `provider_lookup_scheduling_test` | Logic |
| Cached-link reuse | `playback_settings_test` (last stream cache) | Logic |
| Failed-source recovery, source switching | `player_session_test`, `playback_reliability_test` | Logic; Device for the errors on Windows |
| Android engine fallback | `playback_reliability_test`; TV emulator run | Logic, Emulator |
| Windows libmpv playback | `windows_playback_test` | Device |
| Request headers | `windows_playback_test`; `playback_pipeline_test` | Device (Windows), Logic |
| HLS and DASH | Windows, emulators | Device (Windows), Emulator |
| Subtitles | `subtitles_test`, `player_settings_sheet_test` | Logic |
| Audio and video tracks | `audio_track_switch_test`, `audio_track_metadata_test`, `media3_audio_track_test` | Device (Windows), Emulator |
| Resume, local progress | `episode_selection_test` (episode progress), checkpoint 3 | Logic; Device (Windows resume seek) |
| Account progress sync | `progress_sync_test` | Logic |
| Watch Party host, guest, recovery, episode transitions | `watch_party_test`, `watch_party_reliability_test` | Logic |
| Cancellation and disposal | `player_session_test` (closing while a source opens), `windows_playback_test` (close and reopen), `player_long_session_test` | Logic, Device, Emulator |
| No stale session replacing a newer one | `player_session_test` (episode switch during a refresh by key, auto-next and a party guest; a declined refresh) | Logic |

## Final report

### A. Executive summary

Five changes, each to a confirmed problem, each covered by tests that fail
without it:

1. **Link refresh gets new links (PB-05).** A refresh used to receive the
   lookup still running, so it could hand back the link that had just
   failed. It now starts its own lookup, and the original one keeps
   delivering late sources.
2. **Start-up stages are measurable (PB-10).** Opt-in analytics now say
   where a start spent its time: cache, lookup, preparation, engine and
   recovery. A Play that never reached the player is reported too. Nothing
   sent names a stream, host, header, provider or title.
3. **Episode switch during a refresh (PB-04).** A refresh that finished
   mid-switch reopened the old episode, sometimes twice. It now waits for
   the switch, and its link is used only if the old episode resumes.
4. **One source identity (PB-11).** One rule now decides whether two
   results are the same source. This fixed torrents given only by info
   hash: before, all of them were merged into the first.
5. **Windows DASH crash (PB-24, found here).** Windows' libmpv crashes on
   the second DASH manifest in a process. The crash is now prevented: a
   second DASH source is refused, and the player moves on to the next one.

Left unchanged on purpose, after measurement:
- The order of the pre-play steps and the resume seek (PB-06, PB-07):
  together under 30 ms, and +0.1 to 0.5 s on resume, on Windows.
- Discovery's competition with start-up (PB-23): real on slow links with
  heavy stand-in traffic, but real provider traffic is unmeasured.

Engine order, buffer sizes, timeouts, worker and runtime limits, budgets,
the network policy and the sandbox are all unchanged.

### B. Audit verification

| Finding | Outcome |
|---|---|
| PB-05 refresh reuses the running lookup | Confirmed, fixed |
| PB-10 no production stage attribution | Confirmed, fixed |
| PB-06 sequential pre-play steps | Measured on Windows: negligible; no change |
| PB-07 resume opens then seeks | Measured on Windows: small; no change. Not measured on Media3 or a TV |
| PB-23 discovery competes with start-up | Sensitivity measured with stand-ins; no change until real traffic is measured |
| PB-04 episode switch race | Reproduced, fixed |
| PB-11 three identity keys | Confirmed, fixed; the torrent case was worse than described |
| PB-09 Windows QuickJS deadline | Already resolved |
| PB-15 failure policy untested | Out of date: already covered by `player_session_test`; link refresh is now covered too |
| PB-24 (new) second DASH open crashes Windows | Found, root cause identified (FFmpeg `xmlCleanupParser`), mitigated; real fix pending |

### C. Implemented improvements

Details, root causes and file lists are in sections 1, 2, 5, 6 and the PB-24
sections above. Why each is safe:

- **PB-05:** `fresh` defaults to false, so every other caller is
  unchanged. The new lookup uses the same scheduler and limits. The refresh
  budget, the attempt budget and engine fallback are untouched.
- **PB-10:** new parameters are numbers or fixed words. The existing
  privacy test was kept and extended. Events stay at 25 parameters or fewer.
  Nothing is sent without consent, and nothing is sent on Windows.
- **PB-04:** acts only while an episode switch is in progress. No
  generation guard was added, so other recovery paths are as before.
- **PB-11:** for every non-torrent source the key is the player's previous
  key, so attempts and recovery are unchanged. The keys are never saved.
- **PB-24:** Windows plus a recognized DASH source only; Android and other
  formats are unaffected. The refusal is a `format` failure, so no
  reconnect or link refresh is spent on it.

### D. Testing results

| Command | Result |
|---|---|
| `flutter test` (after the follow-up tests) | 1948 passed, 4 skipped, 0 failed (1913 at baseline) |
| `flutter analyze lib test integration_test test_driver` | 15 infos, no warnings or errors (unchanged from baseline) |
| `dart run tool/docs/docs_tool.dart check` | Passed |
| `flutter build windows --release` | Built |
| `flutter build apk --profile` | Built, 177.1 MB, the same as `main` (177.0 MB). The 208 MB seen from checkpoint 2 on was not the app: both files held the same 876 entries (176.6 MB); the rest was dead space incremental packaging leaves in a local APK it updates in place. Rebuilt after deleting the packaged APK: 177.1 MB |
| Windows integration | All files listed above passed (audio switching after two environmental failures, explained above) |
| Phone emulator integration | 5 files passed, 1 skipped by design, `app_smoke_test` failed (sign-in; no playback) |
| Google TV emulator integration | After the clock fix: Media3 4/4, long session 1/1, provider runtime 4/4, torrent 1/1 |

Tests added: 35 unit and widget tests in five files (including the new
`test/source_identity_test.dart`), plus one Windows integration test.
Expectation updates for intended changes: two in `playback_metrics_test`,
one in `analytics_test`.

### E. Cross-platform results

- **Windows (physical desktop):** all playback integration tests pass. This
  covers libmpv HLS, DASH (one per session), MP4, MKV, headers, redirects,
  audio tracks, torrents, keyboard and mouse.
- **Android phone:** emulator only. Media3 plays and switches audio for
  HLS, DASH and MKV; the provider sandbox limits hold; the torrent engine
  streams; memory settles over 24 opens. libmpv on Android was not run.
- **Android TV / Google TV:** emulator only. Media3 plays and switches
  audio for HLS, DASH and MKV; 24 sessions played with no failure. Remote
  navigation, HDMI audio and real TV decoders are not verified.
- **Watch Party:** logic only. No mixed-device session was run.

### F. Performance measurements

| Measurement | Kind | Result |
|---|---|---|
| Pre-play steps (PB-06) | Device, Windows, debug, public CDNs | 3Ã¢â‚¬â€œ25 ms together |
| Resume vs fresh start (PB-07) | Device, Windows | +0.1 s progressive, +0.3 s HLS, +0.5 s DASH to first frame |
| Discovery competition (PB-23) | Simulated link and stand-in load, Windows | 1.5 Mbit/s: +0.6 s (light), +2.7 s and stalls (heavy). 8 Mbit/s: +0.4 s, heavy only. CPU load: no effect |
| Media3 first frame | Emulator, phone | 0.36Ã¢â‚¬â€œ1.09 s after the first session (5.4 s) |
| Real community providers | Not measured | n/a |
| Physical Android devices | Not measured | n/a |

The checkpoints changed correctness, not speed, so there is no
before-and-after timing to give. The 21 November stand-in measurements
were not used as evidence.

### G. Privacy and security review

- **New telemetry.** On `playback_session`:
  - `source_origin`: `cache`, `auto` or `manual`.
  - Stage timings in milliseconds: `first_source_ms`, `resolve_ms`,
    `prepare_ms`, `open_ms`, `recovery_ms`.
  - Counts: `lookup_stalled`, `opens`.

  A new `source_lookup` event, for a Play that never opened the player:
  - `content_type` and `outcome` (`no_source`, `cancelled` or `declined`).
  - `lookup_ms` and the counts `lookup_runs`, `lookup_failed`,
    `lookup_stalled`.

  Everything is numbers or fixed words. It is sent only after the viewer
  agrees to analytics, only on Android, and through the existing service.
- **Excluded, and tested:** stream URLs, hosts, headers, cookies, tokens,
  provider, plugin and repository names, titles, Watch Party ids.
  `analytics_test` fills a source with secrets and checks that none of
  them appears in any event.
- **Logging:** no new log line carries a URL or header. The debug summary
  gained only numbers.
- **Untouched:** `NetworkDestinationValidator`, redirect and header
  validation, QuickJS memory and time limits, script approval, provider
  isolation, cancellation. A fresh lookup runs under the same scheduler and
  limits.
- **PB-24:** the mitigation adds no native code. Replacing the libmpv DLL
  (the real fix) would need a security review.

### H. Remaining limitations

1. **PB-24:** on Windows a second DASH source in a session does not play
   until restart. DASH not recognizable from its URL or metadata can still
   reach libmpv and crash. The fix is a libmpv build without FFmpeg's
   `xmlCleanupParser()` call.
2. **PB-23:** real provider traffic during start-up is unmeasured, so
   whether viewers on slow links are affected is unknown.
3. **PB-07** on Media3 and TV hardware is unmeasured.
4. **No physical Android verification.** Phone, Android TV, Google TV,
   32-bit TVs, real decoders, HDMI audio and remotes have not been tested
   on hardware. Neither has libmpv on Android, including whether PB-24
   affects its DASH fallback.
5. **Watch Party across devices:** not tested.
6. **Home's Play flow** (origin, resolve time, `source_lookup` calls) has no
   widget-test harness; it was verified by reading the code. Each call is on
   a path that returns at once, and the event's content is tested. A harness
   would need Home with injected providers and a replaceable analytics
   service. No real Firebase values have been seen yet.
7. **The Watch Party host's own episode change** is the tested key path
   plus a message to the room; it was not driven with a party. Auto-next and
   a guest following the host now have tests of their own.

### I. Final changed-file inventory

Code:

| File | Change |
|---|---|
| `lib/src/services/provider_plugin_service.dart` | `fresh` lookups (PB-05); reports each run to the lookup (PB-10); identity key (PB-11) |
| `lib/src/services/stream_discovery.dart` | `LookupStats` (PB-10); identity key (PB-11) |
| `lib/src/widgets/player/custom_video_player.dart` | Separate refresh subscription, declined refresh (PB-05); passes the resolution, counts opens (PB-10); held source during an episode switch (PB-04) |
| `lib/src/screens/home_screen.dart` | `fresh: true` for refreshes (PB-05); Play clock, origin, `source_lookup` (PB-10) |
| `lib/src/screens/player_screen.dart` | Passes `resolution` to the player (PB-10) |
| `lib/src/services/playback_metrics.dart` | `SourceResolution`, stage timings, summary fields (PB-10) |
| `lib/src/analytics/analytics_events.dart` | New `playback_session` parameters, `SourceOrigin`, `LookupOutcome`, `source_lookup` (PB-10) |
| `lib/src/services/playback_coordinator.dart` | `prepareAndOpen` returns the preparation time (PB-10); DASH refusal classification and message (PB-24); `sourceKey` uses the identity key (PB-11) |
| `lib/src/services/player_engine.dart` | `WindowsDashGuard`, `DashReopenUnsupported` (PB-24) |
| `lib/src/models/stream_source.dart` | `identityKey` (PB-11) |

Tests:

| File | Change |
|---|---|
| `test/player_session_test.dart` | Link refresh (3) and episode switch during a refresh (7, including auto-next and a Watch Party guest) groups; storage queue reset in `setUp` |
| `test/provider_lookup_scheduling_test.dart` | Fresh lookups (3), lookup counts, stalled checks, hash-only torrents |
| `test/analytics_test.dart` | Stage, omission, recovery, privacy and `source_lookup` tests; one expectation updated |
| `test/playback_metrics_test.dart` | Two expectations updated for the summary line |
| `test/playback_reliability_test.dart` | One DASH stream per session on Windows (5) |
| `test/source_identity_test.dart` (new) | 10 identity tests |
| `integration_test/windows_playback_test.dart` | A second DASH stream is refused instead of ending the app |
| `integration_test/startup_latency_test.dart` (new) | Pre-play and resume measurement harness (checkpoint 3) |
| `integration_test/discovery_competition_test.dart` (new) | Emulated-link competition harness (checkpoint 4) |

Documentation:

| File | Change |
|---|---|
| `docs/playback-audit/RELIABILITY_OPTIMIZATION_REPORT.md` (new) | This report |
| `docs/README.md` | Links the report |
| `docs/playback-audit/PLAYBACK_AUDIT_REPORT.md` | Finding statuses; PB-24 added |
| `docs/playback-audit/PLAYBACK_REMEDIATION_ROADMAP.md` | Items done |
| `docs/playback-audit/PLAYBACK_PERFORMANCE_REPORT.md` | Measurements |
| `docs/playback-audit/PLAYBACK_ARCHITECTURE_OVERVIEW.md` | Refresh flowchart |
| `docs/playback-audit/PLAYBACK_TEST_STRATEGY.md` | Coverage notes |
| `docs/playback-audit/DEEP_AUDIT_2026-11-21.md` | PB-23 status |
| `docs/features/analytics.md` | New parameters and event |
| `docs/playback/playback-architecture.md` | A refresh is always a new lookup |
| `docs/playback/platform-player-engines.md` | One DASH stream per session on Windows |
| `docs/playback/troubleshooting.md` | The Windows DASH message |
| `docs/playback/provider-integration.md` | The single identity rule |
| `docs/codebase/*.md` | Regenerated by the docs tool |

`docs/playback-audit/REELISH_PLAYBACK_ARCHITECTURE_AUDIT.docx` is the
audit itself: untracked, read only, not modified.

### J. Recommendation

Reelish is ready for physical-device playback testing. On Windows, the
playback integration suite passes on hardware. On Android, the changed code
runs on emulators and its logic is covered by tests. In order:

1. **Run the Android integration files on a real phone and a real TV.**
   - Files: `media3_audio_track_test`, `libmpv_playback_test`,
     `player_long_session_test` and `startup_latency_test`.
   - Include a 32-bit Chromecast-class TV.
   - This covers PB-07 on Media3 and libmpv's DASH fallback, which may
     share PB-24.
2. **Fix PB-24 properly.** Try a newer Windows libmpv build against the
   `windows_playback_test` regression test. If one has no
   `xmlCleanupParser` call, a security review and a release decision follow.
3. **Measure real provider traffic during start-up (PB-23)** before
   deciding on any scheduling change.
4. **Run one mixed-device Watch Party session:** Windows host, Android
   guest, and the reverse.

No further code change is justified until one of these produces evidence
for it.
