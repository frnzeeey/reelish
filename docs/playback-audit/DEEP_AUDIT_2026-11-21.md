# Playback deep audit, 2026-11-21

A read-only pass over the whole path from Play to the first frame, measured
before anything was changed, then two fixes where the measurements showed
Reelish itself making the viewer wait. It builds on the
[2026-11-13 audit](PLAYBACK_AUDIT_REPORT.md) (PB-01 to PB-15) and the
[2026-11-20 audit](../REELISH_PLAYBACK_AUDIT.md) (PB-16 to PB-21); IDs keep
that numbering.

## A. Summary

- **Does Reelish wait for provider answers it does not need?** With
  automatic selection, no: playback starts with the first usable source,
  plus at most 3 s when a source closer to the quality target may still
  arrive and 2 s when the first is a torrent
  (`StreamDiscovery.startingSource`). Manual selection waits for the
  configured time, by design.
- **Where it did wait needlessly**, measured with stand-in providers (real
  QuickJS runtimes, known timings), both in the provider scheduler, which
  has two runtime slots shared by every lookup:
  - **PB-01:** a lookup the viewer had left kept both slots until its
    providers returned. The next title waited **7.55 s**; now **30 ms**.
  - **PB-02:** two slow, empty providers at the top of the order held back
    a provider that answers at once: **11.1 s** to the first source, on
    every lookup. The first lookup of a session still waits; later ones now
    take **27 ms**.
- **Player start** is not the bottleneck. On Windows (2026-11-20, same
  code path): opening takes about 1.9 s (4.7 s for a cold first open), the
  steps between open and play 3 to 32 ms, play to the first frame 0.3 to
  1.4 s. Measured on public test clips.
- **No buffering, engine or decoder settings were changed.** None was
  measured as a cause.

## B. Findings

| ID | Finding | Severity | Platform | Status |
|---|---|---|---|---|
| PB-01 | A cancelled lookup's running providers keep both runtime slots | High | All | **Fixed**, measured |
| PB-02 | Two slow top-priority providers delay every other provider | High | All | **Improved** from the second lookup, measured; first lookup unchanged |
| PB-08 | Each run parses the Cheerio/CryptoJS bundle | Low (was Medium) | All | Measured: 45 ms per run; not worth a cache |
| PB-09 | Stuck synchronous providers outlive the timeout on Windows | n/a | Windows | **Already fixed** by the rebuilt bridge DLL; the code comment said otherwise (corrected) |
| PB-22 | The 60 s search cap left running providers going | Medium | All | **Fixed** with PB-01 |
| PB-23 | Discovery keeps running while the player buffers its first seconds | Low | All | Sensitivity measured on Windows with stand-in load (2026-11-27): matters on slow links; real provider traffic unmeasured; not changed ([reliability report](RELIABILITY_OPTIMIZATION_REPORT.md)) |

PB-04 to PB-07 and PB-10 to PB-13 are unchanged from the earlier audits.

### PB-01: leaving a lookup held the runtime slots

- **Root cause:** `StreamDiscovery.cancel` only stopped workers from
  starting providers. A provider already inside `ProviderRunner.run`
  (`Isolate.run`, which cannot be told anything) kept its slot until its
  `getStreams` returned or hit 30 s.
- **When:** cancelling the search, closing the player while providers
  still search (Home cancels the lookup then), switching episode, or
  picking another title.
- **Fix:** `ProviderRunner.run(abort:)` starts the isolate with
  `Isolate.spawn` and a control port. When the lookup is cancelled
  (`StreamDiscovery.whenCancelled`), the isolate stops waiting for
  `getStreams`, disposes its runtime and fetch bridge as before, and exits.
  The slot is freed only after that, so the limit of two live 64 MiB heaps
  holds. A script busy in synchronous code reads the message only when it
  yields; the interrupt deadline (40 s) still bounds that case. A stopped
  run is not recorded as a provider error. No limit, timeout, validator or
  approval check changed, and `Isolate.kill` is not used: it would skip the
  runtime's disposal.

### PB-02: slow providers at the top of the order

- **Root cause:** providers start in manifest priority order, and only two
  run at once (a memory bound). Two that wait out their upstream hold back
  every provider below them, on every lookup.
- **Fix:** in-session memory (`ProviderPluginService._stalledProviders`):
  a provider whose last run timed out, or failed or found nothing after
  10 s or more, starts after the others on the next lookup, still in
  priority order. A provider that finds sources, however slowly, keeps its
  place, and one that answers quickly again is restored. Nothing is
  persisted, so each launch starts from the manifests' order.
- **Not done:** raising the runtime limit, which would raise the memory
  ceiling on low-RAM TVs, and shortening the 30 s timeout, which measured
  scrapers need.

### PB-22: the search cap left providers running

After 60 s the lookup reported what it had and stopped starting providers,
but those still running kept their slots for up to 45 s more, with results
nobody would read. The cap now stops them as a cancel does.

### PB-23: discovery during player start

The lookup keeps running after playback starts, so later sources can serve
as fallbacks. Its script downloads and provider requests share the
connection with the player's first buffering. Unmeasured; changing it would
cost fallback sources, so it is left for a measured follow-up.

## C. Measurements

Unit runs on Windows (`flutter test`), stand-in providers on real QuickJS.

| Measure | Before | After |
|---|---|---|
| Next title's first source after leaving a lookup (two 8 s providers) | 7,551 ms | 30 ms |
| First source, two dead top providers + one instant, 1st lookup | 11,097 ms | 11,097 ms (unchanged by design) |
| Same, 2nd lookup in the session | about 11,000 ms | 27 ms |
| One provider run, no bundle | 24 to 26 ms | unchanged |
| One provider run with the 685 KB bundle | 67 to 76 ms | unchanged |

These scenarios are now tests: `test/provider_lookup_scheduling_test.dart`
fails without the fixes (7.58 s and 11.04 s against a 3 s limit).

## D. Platforms

- **Shared:** both fixes live in the provider services, used identically by
  phone, Android TV and Windows. No UI or player change.
- **Android:** `integration_test/provider_runtime_test.dart` on an API
  emulator: the abort stops a waiting provider, and the interrupt deadline
  still stops `while (true) {}` on the new path.
- **Windows:** the same test, same results. The interrupt deadline works
  on Windows (3 s), so PB-09 no longer applies.
- **Windows backend facts** (unchanged): libmpv through
  `packages/video_player_media_kit`, media_kit's native video output with
  `hwdec=auto`, media_kit's default 32 MiB demuxer buffer. Audio track
  names come from the stream's own metadata ([audio tracks](../playback/audio-tracks.md)).

## E. Files

- `lib/src/services/provider_runner.dart`: `abort`, `ProviderRunCancelled`,
  the spawned isolate with a control port; corrected PB-09 comment.
- `lib/src/services/provider_plugin_service.dart`: stops running providers
  on cancel and at the search cap; in-session demotion of stalled providers.
- `lib/src/services/stream_discovery.dart`: `whenCancelled`.
- Tests: `test/provider_runner_test.dart` (abort group),
  `test/provider_lookup_scheduling_test.dart` (new),
  `integration_test/provider_runtime_test.dart` (abort on device).

## F. Not verified

- Real community providers: the measurements use stand-ins, so the gain
  per viewer depends on how often their providers are slow or abandoned.
- Android TV hardware and a phone; only the emulator and Windows ran.
- A real Play, back out, Play again in the app UI with live providers.

## G. Remaining risks

- A provider's late fetch answer arriving as the runtime is disposed is
  dropped with it, as it was at the 30 s timeout.
- An abort that arrives while a script computes waits for the interrupt
  deadline, holding the slot as before.

## H. Recommendations

1. Measure PB-23 (first-buffer time with and without a running lookup) on
   a slow connection before deciding anything.
2. PB-07 (resume opens at the start, then seeks) and PB-10 (stage timings
   in production telemetry) remain the largest unmeasured start-up items.
3. Consider persisting the stalled-provider record (a new key) only if the
   first lookup of a session proves a common complaint.
