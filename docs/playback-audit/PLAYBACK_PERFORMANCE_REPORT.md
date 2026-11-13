# Playback performance report (2026-11-13)

**No benchmarks were run for this audit.** Every duration below is either
a timeout or limit read from the code (marked *limit*), or a proposed
target (marked *target*). Nothing here is a measured value. Finding IDs
refer to [PLAYBACK_AUDIT_REPORT.md](PLAYBACK_AUDIT_REPORT.md).

## Measure the stages separately

A fast player cannot make up for a slow source resolver, and a resolved
source does not guarantee playback. The pipeline has five stages that
fail and slow down for different reasons:

| Stage | From → to | Owner | Instrumented today |
|---|---|---|---|
| S1 Resolution | Play pressed → source chosen | Providers (external) + Reelish scheduling | Debug only: `PerfTimeline` `PLAY_PRESSED -> FIRST_SOURCE`, `[Stream] First valid source (TTR)`, `[Provider Perf]` per provider |
| S2 Preparation | Source → engine created | Reelish (`SourcePreparer`, gate, torrent metadata) | Not measured separately |
| S3 Open | `initialize()` → ready | Engine + host | `PlaybackMetrics.opened` (`open=` in summary; first attempt only) |
| S4 Pre-play | ready → `play()` accepted | Reelish (tracks, audio, speed, volume, seek) | Debug log gap between "initialized in" and "play accepted after" |
| S5 First frame | `play()` → position advances | Engine + host | `playToFrame` (summary and analytics) |

`firstFrameMs` in analytics covers S2–S5 for the session, measured from the
player screen opening. S1 is not in production data (PB-10).

## Startup latency budget (worst case per stage, from code limits)

| Step | Limit | Where |
|---|---|---|
| Episode list (series, no episode chosen) | TMDB request + viewer choice | `_resolveAndOpenPlayer` |
| `resolveTmdbId` (legacy IMDb ids only) | 3 s *limit* | `_resolveAndOpenPlayer` |
| Script download (uncached) | 20 s *limit* per provider | `streams` |
| Wait for a runtime slot | unbounded queue; each holder ≤30 s (45 s hard) *limit* | `ProviderExecutionScheduler` |
| Provider `getStreams` | 30 s *limit* | `ProviderRunner` |
| Whole search | 60 s *limit* | `streams` |
| Torrent first: wait for a direct stream | 2 s *limit* | `startingSource` |
| Manual selection mode | `streamSelectionTimeoutSeconds` setting | `_resolveAndOpenPlayer` |
| DNS preflight | 5 s *limit* | `NetworkDestinationValidator.dnsTimeout` |
| Engine switch wait | 5 s *limit* | `PlayerEngineGate.maxWait` |
| Previous controller dispose | 5 s *limit* | `_EngineVideoController.disposeTimeout` |
| Torrent metadata | 30 s *limit* | `TorrentSourcePreparer._metadata` |
| `initialize()` | 20 s; 7 s for a cached link; 12 s on engine fallback *limit* | `_initialize`, `_handleFailure` |
| Track queries | 2 s *limit* | `_initialize` |
| Preferred audio | 2 s *limit* | `_applyPreferredAudio(beforePlay: true)` |
| Speed / volume (non-default only) | 2 s + 2 s *limit* | `_initialize` |
| Resume seek | 2 s *limit* | `_initialize` |
| `play()` | 10 s *limit* | `_initialize` |

**Worst case to the error panel**, ignoring S1 and torrents: per source,
roughly DNS 5 + open 20 + pre-play 10 + play 10 ≈ 45 s, plus ≈ 45 s more
when the other engine is tried (12 s open). With 5 distinct sources the
theoretical ceiling is several minutes. Real failures are usually fast
(DNS, HTTP 4xx), so this ceiling matters only for hosts that accept the
connection and then go silent. The *target* below bounds it.

## Bottlenecks identified

| # | Bottleneck | Stage | Finding | Confidence |
|---|---|---|---|---|
| 1 | Two app-wide QuickJS slots, held by abandoned providers after cancel | S1 | PB-01 | Confirmed path |
| 2 | Static provider order with no memory of slow or dead providers | S1 | PB-02 | Confirmed path |
| 3 | Isolate + runtime + 702 KB bundle evaluation per provider run | S1 | PB-08 | Confirmed path; cost unmeasured |
| 4 | Serial track/audio/speed/volume/seek round trips | S4 | PB-06 | Confirmed path; cost unmeasured |
| 5 | Resume buffers the start, then seeks | S3–S5 | PB-07 | Confirmed path; cost unmeasured |
| 6 | DNS preflight before the engine's own lookup | S2 | (security requirement) | Likely small because of the OS resolver cache; measure `prepareMs` |

Things that look like bottlenecks but are not:

- Metadata, subtitles and artwork **do not block playback**. IMDb ids
  resolve in parallel (100 ms cap at hand-over), details and episodes are
  futures, subtitle search starts after `play()`, and artwork waits 4 s
  after play.
- The engine is not opened twice for network failures:
  `canTryAnotherEngine` excludes network, HTTP, DNS and timeout failures.
- A cached link fails fast (7 s), then rediscovery runs.
- libmpv is loaded lazily on Android (fallback only).

## Buffering risks

- Rebuffering is mostly host throughput, which Reelish cannot fix.
- Engine buffer configuration is untuned package defaults (PB-13). The
  audit found no evidence either way.
- The stall watchdog gives up on a source after 25 s with no progress
  (60 s for torrents). Too short would abandon slow but working hosts;
  too long leaves a spinner. Tune it only with the rebuffer-length
  distribution from telemetry.
- `endedEarly` correctly turns libmpv's silent end of file after lost
  reconnects into a recoverable network failure.

## Network efficiency

- Provider fetches reuse one DNS-pinned client per origin per run
  (connection pooling, 4 per host). Clients do not survive across runs,
  since each run is a new isolate.
- A lookup is shared per (title, episode, filter) while in flight, so a
  repeated Play does not double the provider requests.
- Cancelling does not cancel in-flight provider HTTP requests (PB-01).
- The engines own their own connections. Reelish neither adds nor removes
  connection reuse there.

## Memory and resources

- Controllers: disposed on every path checked (new open, failure, episode
  release, dispose). Dispose is bounded at 5 s; a stuck native dispose
  finishes in the background.
- Listeners: `_tick` is removed before disposal. The first-frame and
  no-picture listeners remove themselves on a stale generation.
- QuickJS: 64 MiB per runtime, 2 at once (plus any orphaned on Windows,
  PB-09).
- Long sessions: `player_long_session_test` (Android) and
  `windows_soak_test` (Windows) exist to record memory over repeated opens.
  No results are stored in the repository, so none are reported here.

## Platform concerns

- **Android phone:** Media3 first. A Media3 failure on an engine-specific
  kind costs one extra open on libmpv (12 s cap).
- **Android TV / Google TV:** The same engines on weaker CPUs, so PB-08
  matters most here. Many TVs are 32-bit (no torrents).
- **Windows:** libmpv only, no engine fallback. PB-09 applies. libmpv
  default hardware decoding has not been verified on a range of GPUs.

## Metrics and targets

The targets are proposals to set after a baseline exists. Reaching a
target is not evidence until it has been measured on a device.

| Metric | Definition | Source | Target |
|---|---|---|---|
| Source resolution time | Play → source chosen (S1), p50 / p90 | new `resolveMs` (PB-10) | p50 ≤ 5 s, p90 ≤ 15 s with healthy providers |
| Player initialization time | S2 + S3 of the attempt that played | `open` + new `prepareMs` | p50 ≤ 2 s, p90 ≤ 6 s |
| Pre-play time | S4 | new field or debug log | p90 ≤ 300 ms |
| Time to first frame (TTFF) | `play()` → first frame (S5), and Play → first frame overall | `playToFrame`, `resolveMs + firstFrameMs` | S5 p50 ≤ 1.5 s; end-to-end p50 ≤ 8 s |
| Rebuffering ratio | buffering / (buffering + playing) after the first frame | `rebufferPercent` | median session 0 %, p90 ≤ 2 % |
| Playback failure rate | sessions with `outcome=failed` / sessions with a source | `playbackSession.outcome` | ≤ 5 %, split by `failure` kind and app/provider/network side |
| Recovery success | `recovered / recoveries` | existing | ≥ 70 % |
| Cancel to slot free | cancel → both runtime slots free | test / debug log | ≤ 2 s (after PB-01) |
| Worst case to error panel | Play → error panel when every candidate hangs | integration test with hanging fake host | ≤ 90 s |

For every metric, report the split by engine (`media3` / `mediaKit`),
platform (phone / TV / Windows) and `sourceType` (hls / dash / progressive
/ torrent). The existing event already carries engine and source type.
