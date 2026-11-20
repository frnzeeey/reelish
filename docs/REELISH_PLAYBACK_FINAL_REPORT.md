# Reelish playback final report (2026-11-20)

Covers the work planned in
[REELISH_PLAYBACK_IMPLEMENTATION_PLAN.md](REELISH_PLAYBACK_IMPLEMENTATION_PLAN.md)
after the [audit](REELISH_PLAYBACK_AUDIT.md). Checkpoint before the
changes: commit `c50c470` on `redesign/living-room`.

## Problems discovered

| ID | Problem | Root cause | Status |
|---|---|---|---|
| PB-16 | Windows audio rows read "Audio track 1, 2, 3" | No language in the stream → the label used the position, though codec and channels were known | Fixed |
| PB-17 | Default, forced, audio description, hearing-impaired and channel layout never shown | media_kit 1.2.6 and the bridge keep a fixed subset of libmpv's `track-list`; `VideoAudioTrack` has no fields for the rest | Fixed |
| PB-18 | HLS with audio in every variant listed one identical row per variant (bipbop: 7) | FFmpeg's HLS demuxer exposes each variant's audio | Fixed |
| PB-19 | Opening a player switched away from a playing track already in the preferred language | First-match choice | Fixed |
| PB-21 | Codec shown as engine ids (`EAC3`, `MP4A.40.2`) | No display table | Fixed |
| PB-20 | HLS rendition names and DTS profiles not available on libmpv | Not exposed by the bundled libmpv/FFmpeg | Documented limitation |

The reported issue was mainly the first of your three candidate causes
(metadata available, Reelish not using it), with the second (plugin layers
discarding fields) behind the missing flags and layout, and the third
(backend) only for HLS rendition names.

## Changes

| File | Change |
|---|---|
| `packages/video_player_media_kit/lib/src/mpv_audio_track_info.dart` (new) | `MpvAudioTrackInfo`: layout, default, forced, visual/hearing impaired, HLS program and variant bitrate, parsed from libmpv's `track-list` JSON; malformed input gives nothing |
| `packages/video_player_media_kit/lib/src/media_kit_video_player.dart` | Observes `track-list` next to `aid` (observed, never read: reads can deadlock with the video output); one map per player, replaced on every change, removed on dispose and on restart; `audioTrackInfo(playerId)` |
| `packages/video_player_media_kit/lib/video_player_media_kit.dart` | Exports `MpvAudioTrackInfo` |
| `lib/src/widgets/player/audio_track_sheet.dart` | `AudioTrackLabel`: codec-and-layout names for untagged tracks, flags in the detail, real layouts, codec display names, `choices` (hides only per-variant copies) |
| `lib/src/widgets/player/player_settings_sheet.dart` | Passes the metadata to the Audio & language page |
| `lib/src/widgets/player/custom_video_player.dart` | Reads the metadata with every track list and drops it with the source; offers `choices`; keeps a matching playing track at open (PB-19); debug log of track discovery and switches (ids, languages, codecs, layouts, flags; no titles or URLs) |
| `test/audio_tracks_test.dart` | 13 tests from real `track-list` output |
| `test/player_session_test.dart`, `test/support/fake_video_player_platform.dart` | Fake engine can report audio tracks; 2 tests for the opening choice |
| `integration_test/audio_track_metadata_test.dart` (new) | Real media on libmpv: rows and every switch verified |
| `docs/playback/audio-tracks.md`, `docs/README.md`, three new `docs/REELISH_PLAYBACK_*.md` | Documentation |

Not changed: engine selection, source discovery and preparation, stream
headers, subtitles, Media3's track handling, Watch Party, resume and
history. No new dependency, no native code.

## Windows audio rows, before and after (real media)

| Media | Before | After |
|---|---|---|
| Blu-ray `.m2ts`, 7 untagged tracks | Audio track 1 … Audio track 7 | DTS · 5.1 (Track 1–4), AC-3 · 5.1 (Track 5–6), AC-3 · Stereo |
| Matroska test 5 | Audio track 1 / Stereo · AAC | AAC · Stereo / Default |
| | English / Commentary · Mono · AAC | unchanged |
| HLS audio description rendition | English / visual impaired · Stereo · AAC | English / Audio description · Stereo · AAC |
| DASH (Shaka Angel One) | French / Stereo · OPUS | French / Stereo · Opus |
| bipbop HLS | 7 × English · Stereo · AAC · Track N | 2 rows: the playing track and the separate rendition |
| Media3 (Android) codec `mp4a.40.2` | MP4A.40.2 | AAC |

**Selection proof.** For every row of the Blu-ray file (in the order 5, 7,
2, 6, 1, 3, 4) and both rows of the MKV, choosing the row changed libmpv's
observed `aid` to that id, its active decoder to the track's codec and its
decoded channel count to the track's (ac3/6, ac3/2, dts/6, aac/1, aac/2),
and playback kept advancing. The container's ids (4352–4358) differ from
the row ids; selection goes by libmpv's id.

## Playback reliability

- **PB-19:** a player no longer swaps a playing track for another in the
  same language before play. On bipbop this was a switch from the playing
  variant's audio to another stream; on HLS with tagged audio per variant
  it moved the audio to a second variant. Test fails without the fix
  (`Actual: ['1']`), passes with it.
- **PB-06 measured, not changed:** on Windows the steps between
  `initialize()` and `play()` take 3–32 ms, so reordering them would gain
  nothing. Time goes to opening (about 1.9 s) and the first frame after
  play (0.3–1.4 s).
- PB-01 and PB-02 (provider slots), the largest startup risk found last
  week, were not changed: they are provider-execution changes that need
  their own reviewed pass.

## Performance and resources (Windows, measured)

| | Before | After |
|---|---|---|
| Soak, 20 player opens (RSS MB) | 462 → 594 (+132) | 467 → 598 (+131) |
| Soak, provider runs (RSS MB) | 598 → 604 | 602 → 596 |
| Open → `initialize()` (HLS, warm) | 1.85–2.03 s | not re-measured separately |

The extra `track-list` observer made no measurable difference. Both runs
show a step around cycles 9–10 and a slow rise after it, within the test's
+150 MB limit; whether that rise is growth or network variance is not
settled (a 60-cycle run would tell). No performance optimisation was made:
nothing measured justified one.

## Tests executed

| Check | Result |
|---|---|
| `flutter analyze lib test integration_test test_driver --no-fatal-infos` | 15 infos (baseline), no warnings or errors |
| `dart analyze` (bridge package) | 4 pre-existing infos |
| `flutter test` | 1,829 passed, 4 skipped, 0 failed |
| `integration_test/audio_track_metadata_test.dart` on Windows | 4/4 passed (real media) |
| `integration_test/audio_track_switch_test.dart` on Windows | 4/4 passed |
| `integration_test/windows_soak_test.dart` on Windows, before and after | Passed both |
| `integration_test/media3_audio_track_test.dart` on the Android emulator | 4/4 passed |
| `flutter build windows --release` | Built |
| `flutter build apk --profile` | Built (208.1 MB) |
| Docs `generate` and `check` | Passed |

## Known limitations and not verified

- Not verified: a physical Android phone, Android TV or Google TV; the
  Windows player opened by hand with a provider stream (the integration
  tests use the real engine and the same label code, not the full player
  screen); audible output (switches were confirmed through libmpv's
  decoder state, not by ear).
- No public sample was found for a track flagged commentary by the file
  itself (libmpv has no commentary flag; "Commentary" comes from the
  title), a forced audio track, or 7.1 audio; those rules are covered by
  unit tests only.
- HLS rendition names (`NAME`) and DTS profiles cannot be shown on libmpv
  (PB-20).
- fMP4 HLS renditions still cannot be switched on libmpv (a known FFmpeg
  limitation, handled by the existing switch check).

## Remaining issues

PB-01, PB-02 (provider slots), PB-04, PB-05, PB-07 (resume buffering),
PB-08 to PB-14, as listed in the audit, and the open question on the soak
test's slow rise.
