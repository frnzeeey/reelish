# Reelish playback audit (2026-11-20)

Scope: playback on Android phone, Android TV / Google TV and Windows, with
a runtime investigation of Windows audio track names. Branch
`redesign/living-room` (v1.38.2 plus the redesign). This audit builds on
the static audit of 2026-11-13
([report](playback-audit/PLAYBACK_AUDIT_REPORT.md), findings PB-01 to
PB-15) and does not repeat it. New findings start at PB-16.

**Method.** Code reading, plus runs of the real engine on Windows:
libmpv through `MpvPlayerEngine`, the same path the player uses. A
temporary probe printed what the app receives from
`VideoPlayerController.getAudioTracks()` next to libmpv's own `track-list`
property, for 11 public media files (below). The memory soak
(`windows_soak_test`) was run for a baseline. No Android device was
used for this audit.

**Evidence levels**, as in the earlier audit: **Confirmed** (seen at
runtime or certain from the code), **Confirmed path, impact unmeasured**,
**Suspected** (needs a device or a stream we do not have).

## 1. Architecture (verified)

| | Android phone | Android TV / Google TV | Windows |
|---|---|---|---|
| Engine | Media3 (`video_player_android`) first, libmpv fallback | same | libmpv only |
| libmpv packaging | `media_kit_libs_android_video` 1.3.8 | same | `media_kit_libs_windows_video` 1.0.11 |
| Bridge | `packages/video_player_media_kit` (vendored, patched) | same | same |
| Audio tracks | ExoPlayer `Tracks` groups | same | libmpv `track-list`, observed `aid` |
| Session owner | `CustomVideoPlayer` (shared) | same, D-pad paths on `isTv` | same, keys and mouse on `isDesktop` |

The pipeline (discovery → `PlaybackCoordinator` → `SourcePreparer` →
`PlayerEngineFactory` → `CustomVideoPlayer`) is described in
[playback-architecture.md](playback/playback-architecture.md) and
[PLAYBACK_ARCHITECTURE_OVERVIEW.md](playback-audit/PLAYBACK_ARCHITECTURE_OVERVIEW.md);
both were checked against the code and still match.

### Where Windows audio metadata comes from

```
libmpv track-list (node)            every key libmpv knows
  └─ media_kit 1.2.6 NativePlayer     keeps: id, title, lang, codec, default,
     (real.dart, track-list)          demux-channel-count, demux-channels,
                                      demux-samplerate, demux-bitrate …
                                      drops: forced, visual-impaired,
                                      hearing-impaired, hls-bitrate, program-id
  └─ bridge getAudioTracks            keeps: id, title→label, lang, codec,
     (media_kit_video_player.dart)    channel count, sample rate, bitrate
                                      drops: default, channel layout
  └─ video_player VideoAudioTrack     id, label, language, codec,
                                      channelCount, bitrate, sampleRate, isSelected
  └─ AudioTrackLabel                  title + detail rows in the Audio sheet
     (audio_track_sheet.dart)         and Playback settings
```

## 2. Windows audio track names: runtime evidence

Probe output, abbreviated. "Row" is what the Audio sheet shows (title /
detail).

| Media | What libmpv reports | Row today |
|---|---|---|
| Matroska test 5 (MKV) | #1 aac, 2 ch, no lang, default; #2 aac, mono, `eng`, title "Commentary" | **"Audio track 1"** / Stereo · AAC; "English" / Commentary · Mono · AAC |
| FFmpeg `multiple_tracks.mkv` | #1 mp3, no lang; #2 aac `jpn` "Japanese Audio (2ch LC-AAC)" | **"Audio track 1"** / Stereo · MP3; the title |
| FFmpeg `H264+EAC3.mkv` | eac3, 6 ch, `eng`, long encoder title | the title / 5.1 · EAC3 |
| FFmpeg DTS 4.0 MKV | dts, 4 ch, no lang | **"Audio track 1"** / 4 channels · DTS |
| FFmpeg `hitman_cut.m2ts` (Blu-ray) | 4 × dts 5.1, 2 × ac3 5.1, 1 × ac3 stereo; container ids 4352–4358; **no languages** | **"Audio track 1" … "Audio track 7"** |
| FFmpeg AC-3 VOB | ac3, 5.1(side), no lang | **"Audio track 1"** / 5.1 · AC3 |
| Shaka Angel One (DASH) | 10 tracks, `es`/`de`/`en`/`fr`/`it`, AAC and Opus | "Spanish" / Stereo · AAC … correct |
| Shaka Angel One (HLS fMP4) | 6 renditions with languages, one 5.1 | "English" / 5.1 · AAC … correct |
| Apple bipbop (HLS TS) | 7 × `eng` aac stereo; 6 of them in `program-id` 0–5, one per variant | **7 rows "English" / Stereo · AAC · Track 1…7** |
| Local HLS master (bipbop segments): `NAME="Japanese Dub"` without `LANGUAGE`; `NAME="English AD"` with `describes-video` | #1 no lang, no title; #2 `en`, title "visual impaired", `visual-impaired: true`; #3 muxed | **"Audio track 1"**; "English" / visual impaired · …; **"Audio track 3"** |

`bond_sample_dtshdma.m2ts` returned no tracks to the app because the
4-second clip had already ended (libmpv clears its track list at end of
file). That is a property of the sample, not a defect.

### Root cause, by the three candidate causes

1. **Metadata available but not used (Reelish).** Confirmed, and the main
   cause of the reported "Audio Track 1, 2, 3". When libmpv has no language
   for a track, `AudioTrackLabel.title` falls back to "Audio track N" even
   when the codec and channel layout are known. Untagged tracks are common
   in Blu-ray rips (`.m2ts`: languages live in the disc playlist, not the
   stream), DVD `.vob`, many MKV releases and HLS renditions without a
   `LANGUAGE` attribute. **PB-16.**
2. **Metadata partly passed and then discarded (plugin layers).**
   Confirmed. media_kit 1.2.6 parses a fixed list of `track-list` keys and
   drops `forced`, `visual-impaired`, `hearing-impaired`, `hls-bitrate`
   and `program-id`. The bridge then drops `default` and the channel
   layout (`5.1(side)`, `stereo`), and `VideoAudioTrack` has no fields for
   any of them. libmpv's automatic title for a described-video track
   ("visual impaired") reaches the row as raw text. **PB-17.**
3. **Metadata the backend does not expose.** Confirmed for HLS rendition
   names: bipbop's master playlist names its audio "BipBop Audio 1" and
   "BipBop Audio 2", and the local playlist "Japanese Dub", yet no
   `title` reaches libmpv's `track-list`. This libmpv build also reports no
   codec profile, so DTS-HD MA shows as "dts". **PB-20.**

The probe also showed:

- **Duplicate rows on HLS with audio inside each variant.** FFmpeg's HLS
  demuxer exposes the audio of every variant as its own track. The HLS
  specification makes variants alternative encodings of the same content,
  so bipbop's rows 2–7 are the same audio. Provider HLS streams are often
  built this way; with untagged audio they read "Audio track 1 … 5", one
  per quality. **PB-18.**
- **Codec names are FFmpeg identifiers in capitals**: `EAC3`, `AC3`,
  `OPUS`, `MP3`. **PB-21.**

### Track identity and selection: verified correct

- The row id is libmpv's track id (`aid`), never the list position. In the
  Blu-ray file the container ids are 4352–4358 (`src-id`); libmpv numbers
  them 1–7, and the bridge selects by that id (`setAudioTrack`, then the
  observed `aid`).
- The selected row comes from the observed `aid`, not from media_kit's
  requested state, so it reflects what libmpv actually plays.
- `audio_track_switch_test` already verifies switching on MKV, DASH and
  TS HLS through libmpv's own `current-tracks/audio/id` and audio output
  restarts. It does not cover different codecs in one file or untagged
  tracks.
- Track lists are dropped with the source (`_audioTracks = []` in
  `_initialize`) and are read per controller, with a generation check, so
  one session's tracks cannot leak into the next. The bridge's per-player
  maps are cleared in `dispose`.

## 3. New findings

| ID | Title | Severity | Platform | Evidence |
|---|---|---|---|---|
| PB-16 | Untagged audio tracks are named "Audio track N" although codec and channels are known | High (the reported issue) | Windows; Android on libmpv | Confirmed at runtime |
| PB-17 | Default, forced, audio description and hearing-impaired flags and the channel layout are discarded | Medium | Windows; Android on libmpv | Confirmed at runtime |
| PB-18 | HLS with audio in every variant lists one identical row per variant | Medium | Windows; Android on libmpv | Confirmed at runtime |
| PB-19 | Opening a player switches away from a playing track that already has the preferred language | Medium | All engines; costly on libmpv HLS | Confirmed path; impact checked during implementation |
| PB-20 | libmpv does not expose HLS rendition names or codec profiles | Low (limitation) | Windows; Android on libmpv | Confirmed at runtime |
| PB-21 | Codec names shown as FFmpeg identifiers (`EAC3`, `AC3`, `OPUS`) | Low | All | Confirmed |

### PB-16: Untagged audio tracks are named "Audio track N"

- **Affected:** `AudioTrackLabel.title` in
  [audio_track_sheet.dart](../lib/src/widgets/player/audio_track_sheet.dart).
- **Cause:** The title is the language or the stream's title; otherwise the
  position. Codec and channels only appear in the second line.
- **Impact:** On a Blu-ray rip, seven rows called "Audio track 1–7" with
  DTS or AC-3 details underneath; the viewer must read the small print.
- **Fix:** When there is no language and no title, name the row from
  what the stream does say ("DTS · 5.1", "AC-3 · Stereo"). Keep "Track N"
  as the distinguishing detail when two rows would still read the same,
  and "Audio track N" only when the stream says nothing at all.

### PB-17: Flags and channel layout discarded

- **Affected:** media_kit's `track-list` parser (not vendored), the bridge's
  `getAudioTracks`, `VideoAudioTrack`.
- **Fix:** The bridge observes libmpv's full `track-list` (JSON, observed
  rather than read, like `aid`, because a property read can deadlock with
  the video output) and keeps a per-player map of the extra fields. The
  player reads it alongside `getAudioTracks` when libmpv is the engine.
  Rows then show "Audio description", "Hearing impaired", "Forced", the
  real layout (5.1, 7.1, 4.0) and "Default" when the file marks some tracks
  and not others. Media3 is unchanged.
- **No new dependency, no native code:** `observeProperty` is already
  used for `aid`.

### PB-18: One identical row per HLS variant

- **Affected:** the bridge's `getAudioTracks`; `_audioChoices` in
  `CustomVideoPlayer`.
- **Cause:** FFmpeg's HLS demuxer; libmpv reports each copy with its
  variant's `program-id` and `hls-bitrate`.
- **Risk of a naive fix:** selecting a copy from another variant makes
  libmpv download that variant's segments as well as the playing one.
  Rows must not be merged by language alone: bipbop's row 1 is a separate
  rendition ("BipBop Audio 2"), with the same language and codec.
- **Fix:** Hide a row only when it belongs to another variant (`program-id`
  differs from the playing track's, and it carries `hls-bitrate`) and a
  row with identical metadata exists in the playing variant. Separate
  renditions and non-HLS files are never hidden.

### PB-19: The opening audio choice ignores the playing track

- **Affected:** `_applyPreferredAudio` in
  [custom_video_player.dart](../lib/src/widgets/player/custom_video_player.dart).
- **Cause:** It takes the *first* track in the preferred language, even
  when the playing track is in that language too.
- **Impact:** On bipbop with English preferred, the player switches from
  the playing variant's audio (row 6) to row 1 before play. On HLS with
  tagged audio in each variant it moves the audio to another variant,
  which doubles the download. A switch before play also restarts libmpv's
  audio output, and on fMP4 renditions switching is known to freeze
  ([audio-tracks.md](playback/audio-tracks.md)).
- **Fix:** If the playing track already matches the language, keep it.

### PB-20: HLS rendition names and codec profiles are not exposed

- **Cause:** FFmpeg's HLS demuxer does not pass `NAME` to libmpv as a
  title, and this libmpv build has no `codec-profile` in `track-list`.
- **Recommendation:** Do not parse the master playlist to guess which
  rendition is which: FFmpeg's stream order is not guaranteed to match, so
  any mapping would be an inference. Media3 does expose rendition names
  (`Format.label`). Revisit when media_kit ships a newer libmpv.

### PB-21: Codec names

- **Fix:** A display table for well-known codecs (AAC, AC-3, E-AC-3, DTS,
  TrueHD, FLAC, Opus, Vorbis, MP3, PCM); unknown codecs keep the engine's
  name in capitals. Nothing is inferred: the table only renames.

## 4. Status of the 2026-11-13 findings

Checked against the code today.

| ID | Status |
|---|---|
| PB-03, PB-15 | Fixed (fake-engine harness, `player_session_test`) |
| PB-01, PB-02 (provider slots) | Open. High. Provider execution, needs the provider and security skills |
| PB-04 | Open, low (narrow) |
| PB-05 (refresh reuses the running lookup) | Open, low |
| PB-06 (serial pre-play steps) | Measured on Windows: 3–32 ms, no change justified (section 7). Android unmeasured |
| PB-07 (resume buffers twice) | Open, unmeasured on device |
| PB-08, PB-09 | Open |
| PB-10 (stage telemetry) | Open |
| PB-11, PB-12, PB-13, PB-14 | Open |

The earlier audit found no leaked controllers, listeners or duplicate
players, and this audit's code reading agrees: the generation token, the
engine gate (`PlayerEngineGate`), bounded dispose and the bridge's
per-player maps cover the lifecycle the brief asks about.

## 5. Resource baseline (Windows)

`windows_soak_test` opens and closes the full player screen 20 times on
a public HLS stream after two warm-up cycles, then runs providers
repeatedly:

| Run | Player cycles (RSS MB) | Provider runs (RSS MB) |
|---|---|---|
| Before the changes | 462 → 594 (+132); a step at cycles 9–10 (514 → 574), then about +2 MB per cycle | 598 → 604, flat |

The test's own notes record an earlier run at +85 MB over the first 13
cycles, then about +0.7 MB per cycle; its limit is +150 MB. The shape
(one step, then a slow rise) matches HLS variant buffers and allocator
growth rather than a leaked decoder or texture, which would add tens of
MB per cycle. **Suspected, not confirmed:** two runs cannot separate
network variance from slow growth; a longer run (`SOAK_CYCLES=60`) would.

## 6. Recommended order

1. PB-16, PB-17, PB-21: names from real metadata (Windows audio issue).
2. PB-18: hide per-variant copies, safely.
3. PB-19: keep a playing track that already matches.
4. PB-01 and PB-02 remain the largest startup risk, but they are provider
   execution changes (rule 3 and 4 areas) and need their own reviewed
   change; they are not part of this pass.
5. PB-10 before any buffer or startup tuning (PB-06, PB-07, PB-13): the
   brief forbids unmeasured optimisation, and production timings do not
   exist yet.

## 7. Measurements

**Startup on Windows (libmpv, public HLS, 20 opens in the soak test),**
from the player's own debug timings:

| Stage | Typical | Range |
|---|---|---|
| Screen open → `initialize()` done | 1.95 s | 1.85–2.03 s (first open 4.7 s, cold) |
| `initialize()` → `play()` accepted (PB-06's chain) | 4 ms | 3–32 ms |
| `play()` → first frame | 0.8 s | 0.3–1.4 s |

So on Windows PB-06's serial pre-play steps cost milliseconds: **no change
is justified there**, and none was made. Opening (network and demuxer) and
the first decoded frame are where the time goes. Android and TV were not
measured in this audit.

## Regression risks of the recommended fixes

| Change | Risk | Guard |
|---|---|---|
| Labels from codec and layout | Row text changes on all engines | `audio_tracks_test`, sheet tests |
| Observing `track-list` | One more libmpv observer per player | Observed like `aid`; cleared on dispose; probe and soak runs |
| Hiding variant copies | Hiding a real alternative | Hidden only with `program-id` + `hls-bitrate` + an identical twin in the playing variant; integration test on bipbop |
| Keeping a matching track | A viewer who wanted another same-language track | Only the automatic choice changes; the sheet still lists every track |

Media3 and its track selection are not touched by any of these.
