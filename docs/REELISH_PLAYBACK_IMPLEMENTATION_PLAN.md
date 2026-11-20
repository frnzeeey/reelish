# Reelish playback implementation plan (2026-11-20)

Follows [REELISH_PLAYBACK_AUDIT.md](REELISH_PLAYBACK_AUDIT.md). Each step is
small, reviewable and validated with the `regression-check` skill. A git
checkpoint is made before step 1.

## Defects in scope

| ID | Defect | Root cause | Priority |
|---|---|---|---|
| PB-16 | Untagged tracks read "Audio track N" | Label falls back to the position before codec and layout | P0 (reported) |
| PB-17 | Flags and channel layout lost | media_kit and the bridge keep a fixed subset of `track-list` | P0 |
| PB-21 | Codec names as FFmpeg ids | No display table | P1 (with P0) |
| PB-18 | One row per HLS variant | FFmpeg exposes each variant's audio | P1 |
| PB-19 | Opening switches away from a matching track | First-match choice | P1 |

Out of scope, with reasons: PB-01 and PB-02 (provider execution; separate
reviewed change), PB-06, PB-07 and PB-13 (no measurements yet: the brief
forbids speculative tuning), PB-20 (backend limitation; a manifest
mapping would be a guess).

## Step 1: Full libmpv audio metadata (PB-17)

- **Files:** `packages/video_player_media_kit/lib/src/media_kit_video_player.dart`,
  new `packages/video_player_media_kit/lib/src/mpv_audio_track_info.dart`,
  the package's export file.
- **Approach:** On `create`, observe `track-list` next to `aid` (observed,
  never read: a read can deadlock with the video output). Parse the JSON
  into `MpvAudioTrackInfo` per audio track: id, layout, default, forced,
  visual-impaired, hearing-impaired, program id, HLS bitrate. Keep one map
  per player, replaced on every change and removed in `dispose`. Expose
  `audioTrackInfo(playerId)`.
- **Native dependency:** none. libmpv already provides the property.
- **Risk:** low. Parsing failures leave the map empty (old labels).

## Step 2: Names from real metadata (PB-16, PB-21)

- **Files:** `lib/src/widgets/player/audio_track_sheet.dart`
  (`AudioTrackLabel`), `player_settings_sheet.dart` (passes the extras),
  `custom_video_player.dart` (reads them with the tracks).
- **Rules:**
  - Title: language (or a title naming it) as today; otherwise the
    stream's title; otherwise codec and layout ("DTS · 5.1"); "Audio track
    N" only when the stream says nothing.
  - Detail: title when not used as the row's name, "Audio description",
    "Hearing impaired", "Forced", layout, codec, and "Default" only when
    some tracks are marked default and others not. Duplicates still get
    "Track N".
  - Layout: libmpv's layout when it names one (`5.1(side)` → 5.1, `quad` →
    4.0); otherwise the count as today (1 Mono, 2 Stereo, 6 5.1, 8 7.1,
    else "N channels").
  - Codec: display names (AC-3, E-AC-3, DTS, TrueHD, Opus …); unknown ones
    unchanged.
- **Risk:** row text changes on Media3 too (codec names, the no-language
  title). Media3's own data is unchanged.

## Step 3: Hide per-variant copies (PB-18)

- **Files:** `AudioTrackLabel` (a pure `choices` function),
  `custom_video_player.dart` (`_audioChoices`).
- **Rule:** hide a row only if it has `hls-bitrate`, its `program-id`
  differs from the playing track's, and a row with identical metadata
  exists in the playing track's program. Nothing is hidden without libmpv
  data, without a playing track, or on non-HLS media.

## Step 4: Keep a matching track at open (PB-19)

- **Files:** `custom_video_player.dart` (`_applyPreferredAudio`).
- **Rule:** for the first preferred language that any track matches, keep
  the playing track if it matches; otherwise switch to the first match.

## Testing strategy

- Unit: label rules for every case in the audit table (untagged DTS
  Blu-ray, MKV without language, commentary, audio description, forced,
  default, duplicate languages, identical codecs, non-sequential ids),
  `track-list` parsing (including bad JSON), variant hiding (bipbop shape,
  separate rendition kept, single-program files untouched).
- Widget: `audio_tracks_test`, `player_settings_sheet_test`, the full
  `flutter test`.
- Windows integration, real media: a new `audio_track_metadata_test`
  that opens the Blu-ray `.m2ts` (seven untagged DTS/AC-3 tracks,
  non-sequential container ids), the MKV with commentary, the HLS with an
  audio description rendition and bipbop, checks the rows, then **selects
  every track and confirms through libmpv's observed `aid` and decoder
  codec that the stream changed**. `audio_track_switch_test` must still
  pass.
- Builds: `flutter build windows --release`, `flutter build apk --profile`.

## Acceptance criteria

- Windows rows show language, codec and layout from libmpv whenever it has
  them; "Audio track N" only when it has none of them.
- Selecting each row plays that libmpv track (observed `aid` and codec).
- Missing or malformed metadata never throws; tracks keep working.
- No metadata survives into the next source, episode or player.
- Media3 enumeration and switching unchanged; subtitles unchanged.

## Order

Checkpoint → 1 → 2 → 3 → 4 → integration test on Windows → full
validation → final report
([REELISH_PLAYBACK_FINAL_REPORT.md](REELISH_PLAYBACK_FINAL_REPORT.md)).
