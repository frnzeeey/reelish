---
name: playback-audit
description: Audit or fix Reelish playback — player engines (Media3, libmpv), source preparation and selection, stream headers, subtitles, audio tracks, resume, and the player controls/overlays. Use when playback fails, stalls or misbehaves, or before changing anything under lib/src/widgets/player or the playback services.
---

# Playback audit

## Purpose
Find and fix playback problems at the stage where they occur, without
disturbing the stages that work. Outcome: a verified root cause, a minimal
fix, and proof on every engine the change can reach.

## Activation
- "Video won't play", black screen, buffering, wrong quality, no subtitles,
  audio track issues, resume at the wrong place.
- Any change to `lib/src/widgets/player/`, `player_engine.dart`,
  `playback_coordinator.dart`, `source_preparer.dart`, `stream_*.dart`,
  `subtitle_*.dart`, `torrent_source_preparer.dart`, `video_quality_selector.dart`.
- If sources never appear at all, start with `provider-debugging` instead.

## Codebase context
Pipeline (see `reelish-architecture/architecture.md` § Play):
1. Sources come from `StreamDiscovery` (progressive, per request).
2. `PlaybackCoordinator` (`lib/src/services/playback_coordinator.dart`)
   ranks candidates, tries at most `maxAutomaticAttempts` (5) distinct
   sources, and classifies failures as `PlaybackFailureKind`
   (preparation, http, network, timeout, manifest, format, decoder,
   rendering, engine, source, cancelled, unknown).
3. `SourcePreparer` / `StreamValidator` / `StreamNormalizer` check and
   shape the source cheaply (never download media); torrents go through
   `TorrentSourcePreparer`.
4. `PlayerEngineFactory` (`lib/src/services/player_engine.dart`):
   Android → `Media3PlayerEngine` first, `MpvPlayerEngine` fallback; non-https
   schemes go straight to libmpv (Media3 obeys cleartext policy and lacks
   RTMP/RTSP/UDP/SRT/MMS). Windows → libmpv only. Headers travel in
   `PlayableSource.headers` → `httpHeaders`.
5. UI: `CustomVideoPlayer` (`lib/src/widgets/player/custom_video_player.dart`)
   owns the session; `PlayerControlsOverlay`, `PlayerProgressBar`,
   `ReelishPausedOverlay`,
   `PlayerLockOverlay`, sheets for sources/subtitles/audio/settings.

## Workflow
1. Reproduce and capture the `PlaybackFailureKind` (debug logs; release
   builds log little). Note platform, engine, stream type and scheme.
2. Locate the stage: discovery (no sources) → preparation (rejected URL,
   DNS) → engine open (http/manifest/format) → decode/render → UI.
3. Read the code for that stage and its tests before changing anything.
4. Fix in the narrowest place. Engine-specific problems stay
   engine-specific; never switch Android's engine order to fix one stream.
5. Add or extend a test at that stage (pure Dart where possible).
6. Validate per the section below.

## Safety constraints
- Do not change engine selection order, the attempt budget, header
  propagation, redirect handling or the cleartext/scheme routing without a
  verified cause.
- `Media3PlayerEngine.activate()` must not replace an active
  `AndroidVideoPlayer` (that disposes every native player).
- The player chrome is shared by all platforms; keep phone touch gestures,
  TV focus (`isTv`) and Windows keys/mouse (`isDesktop`) paths separate.
- Never log full stream URLs or headers (they can carry tokens).

## Platform considerations
- Android phone/TV: Media3 + libmpv fallback; torrents only on 64-bit
  processes (`TorrentSupport`). Chromecast-class TVs are 32-bit.
- Windows: libmpv only, bundled by `media_kit_libs_windows_video`;
  PiP/rotation/touch lock/brightness don't exist; screen lock takes keys
  and gamepad (`player_lock_overlay.dart`).
- TV: Back reveals controls; overscan-safe margins only on `isTv`.

## Validation
- Unit/widget: `playback_pipeline_test`, `playback_reliability_test`,
  `stream_discovery_test`, `stream_source_test`, `subtitles_test`,
  `player_ui_test`, `paused_overlay_test`, `player_settings_sheet_test`,
  `torrent_source_preparer_test`, `episode_selection_test`,
  `external_cue_clock_test`.
- Windows integration (`-d windows`): `windows_playback_test`,
  `windows_player_ui_test`, `libmpv_playback_test`; long runs:
  `player_long_session_test`, `windows_soak_test`.
- Android: emulator/device run of a real source (`flutter run`), plus
  `torrent_streamer_test` when torrents are touched. `flutter drive` and
  some integration runs wipe app data.
- Then `regression-check`.

## Completion criteria
Root cause named with the failing stage; fix covered by a test that fails
without it; every reachable engine verified or explicitly listed as
unverified.

## Reporting
Per CLAUDE.md § Reporting, plus: failure kind before/after, engines and
stream types tested, and anything only verified on one platform.
