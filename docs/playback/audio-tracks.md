# Audio tracks

How the player finds, names and switches audio tracks (dual audio, dubs,
commentary), what each engine supports, and what has been verified.

## Flow

1. **Discovery.** After `initialize()`, `CustomVideoPlayer._initialize`
   asks the engine for its audio tracks (`VideoPlayerController.getAudioTracks`,
   at most 2 s alongside the video tracks). The list is read again on the
   first frame (`_awaitFirstFrame`), whenever the Audio sheet or Playback
   settings open, and after every switch (`_refreshAudioTracks`), so late
   tracks appear and the selected row is the engine's, not an assumption.
2. **Opening choice.** `_applyPreferredAudio` plays, in order: the language
   the viewer picked earlier in this session (`_chosenAudioLanguage`, kept
   across another source, a reconnect or the other engine), the preferred
   audio language, the secondary one. Changing the preferences in Settings
   clears the session choice. The first preferred language any track
   speaks decides, and when the playing track already speaks it, it stays:
   another track in that language gains nothing, and on HLS it can move
   the audio to another variant (PB-19 in the
   [2026-11-20 audit](../REELISH_PLAYBACK_AUDIT.md)).
3. **Switching.** The Audio button (more than one track) opens
   `AudioTrackSheet`; Playback settings has the same list under
   **Audio & language**. `_selectAudioTrack` switches in place: the
   position, the paused state and the subtitles stay as they are; only
   forced subtitles follow the audio language, by design
   (`useForcedSubtitles`).
4. **libmpv check.** On libmpv, `_confirmMpvAudio` runs `AudioSwitchCheck`
   ([`audio_switch_check.dart`](../../lib/src/widgets/player/audio_switch_check.dart))
   on the controller's position. A switch counts once playback has moved
   on 2 s; if it stands still for 3 s of play, the previous track is put
   back. If libmpv instead ends the source at once (a false lost
   connection), the reopen of that source restores the language from
   before the switch (`_unconfirmedAudioSwitch`,
   `_audioSwitchFailedSource`). Either way the viewer is told and the
   source offers no audio choice for the rest of the session.

   The check never reads libmpv on request: `mpv_get_property` blocks the
   UI thread on libmpv's core, which can wait on the video output, which
   waits on the UI thread (seen as 4-minute hangs in the integration test).
   The bridge observes `aid` instead. So a track whose codec libmpv cannot
   decode, which plays the picture silently, is not caught.

## Naming

`AudioTrackLabel` ([`audio_track_sheet.dart`](../../lib/src/widgets/player/audio_track_sheet.dart))
names a row from the stream's metadata only, through `SubtitleLanguage`
(`jpn`, `ja` → Japanese; `fil` → Filipino):

| Metadata | Row |
|---|---|
| Language only | `Japanese` |
| Title naming the language with more ("English Commentary") | the title |
| Title about something else ("Commentary", "stream_5") | `English`, title in the detail |
| No language, no title, codec or channels known | `DTS · 5.1`, `AC-3 · Stereo` |
| Nothing at all | `Audio track 3` |

The detail adds, in order: the title when the row is named otherwise,
**Audio description** and **Hearing impaired** (the file's flags),
**Forced**, channels and codec, and **Default** when the file marks some
tracks default and others not (HLS and DASH mark every track, so it is
left out there). Rows that would still read the same get `Track N`.
Nothing is invented: no "Original", no guessed language.

- **Channels** use libmpv's layout when it names one (`5.1(side)` → 5.1,
  `quad` → 4.0, `2.1`); otherwise the count: 1 Mono, 2 Stereo, 6 → 5.1 and
  8 → 7.1 (FFmpeg's default layouts for those counts), else "N channels".
- **Codecs** get their usual names from both engines' identifiers
  (`eac3`/`ec-3` → E-AC-3, `ac3` → AC-3, `mp4a.40.2` → AAC, `dtsl` →
  DTS-HD MA, `opus` → Opus); unknown codecs keep the engine's name.

### libmpv metadata beyond `VideoAudioTrack`

media_kit keeps only part of libmpv's `track-list`, and `VideoAudioTrack`
has no fields for flags or layout. The bridge therefore observes
`track-list` itself (observed like `aid`, never read on request) and keeps
`MpvAudioTrackInfo` per player
([`mpv_audio_track_info.dart`](../../packages/video_player_media_kit/lib/src/mpv_audio_track_info.dart)):
layout, default, forced, visual-impaired, hearing-impaired, HLS program
and variant bitrate. The player reads it with every track list
(`_readAudioInfo`), drops it with the source, and passes it to both sheets.
On Media3 it is empty and the rules above use what Media3 gives.

### HLS variant copies

FFmpeg's HLS demuxer lists the audio inside each variant (quality) as its
own track: Apple's bipbop shows seven English rows. Variants are encodings
of the same content, so `AudioTrackLabel.choices` hides a row when libmpv
puts it in another variant (`program-id`, with an `hls-bitrate`) and a row
that reads the same exists in the playing track's variant. Separate
renditions (no variant bitrate), other languages, one-variant streams and
Media3 keep every row. Choosing a hidden copy would only have made libmpv
download a second variant.

### What libmpv does not report

HLS rendition names (`NAME="Japanese Dub"`) and codec profiles (DTS-HD MA
shows as DTS) do not reach libmpv's track list in the bundled build. The
app does not parse the playlist to guess them: FFmpeg's stream order is
not guaranteed to match it. Media3 reports rendition names
(`Format.label`).

## Engine support

| | Media3 (Android first choice) | libmpv (Windows; Android fallback) |
|---|---|---|
| Enumeration | `Tracks` groups, id `group_track` | libmpv `track-list` |
| Selected track | `Tracks.Group.isTrackSelected` | libmpv's `aid`, observed (media_kit's own state is `auto` until a pick) |
| Switch | `TrackSelectionOverride`; the call waits up to 5 s for ExoPlayer's track event | `aid`, answered at once |
| Labels | `Format.label`, `Format.language`, `Format.codecs`, channel count | stream title, language, codec, layout and flags (`MpvAudioTrackInfo`) |

### Verified

`integration_test/audio_track_switch_test.dart` (libmpv) and
`integration_test/media3_audio_track_test.dart` (Media3) play public
streams and switch while playing, paused and rapidly. libmpv results are
read from libmpv's observed `current-tracks/audio/id` and its audio output
restarting; Media3 results from ExoPlayer's own track selection.

| Media | Media3 (Android phone and Google TV emulators) | libmpv (Windows; Android emulator) |
|---|---|---|
| Two audio tracks in one MKV | Switches in place | Switches in place, position kept |
| DASH, one adaptation set per language | Switches language in place | Switches language in place |
| HLS alternative audio in TS segments | Switches in place | Switches in place (about 2 s without audio), seeks after |
| HLS alternative audio in fMP4 segments | Switches in place | **Cannot switch** (below) |

libmpv selects an fMP4 rendition it did not start at open, but FFmpeg's
HLS demuxer never feeds it. Inside the first segments (which FFmpeg read
for every rendition at open) the switch can still work; later, playback
freezes for several seconds or libmpv reports end of file within a
second, which the bridge turns into a lost connection. Reopening, refresh
seeks and dropping buffers do not help; the rendition plays only when
chosen before play and never seeked. libmpv's track list does not say
whether renditions are fMP4 or TS, so the player handles the failure after
the switch (step 4) rather than hiding tracks beforehand. On Android this
reaches only streams Media3 cannot open, since Media3 is tried first.

On Android emulators the bridge used to fail a source at libmpv's first
"Error decoding audio." after a switch, because MediaCodec output makes
decoder messages fatal there; audio messages now get the same grace check
as on phones and Windows.

### Verified: names from real media (Windows, 2026-11-20)

`integration_test/audio_track_metadata_test.dart` opens real files through
libmpv, checks the rows and chooses every row, confirming each through
libmpv's observed `aid`, active decoder (`audio-codec-name`) and decoded
channel count:

| Media | Rows | Every row plays its own stream |
|---|---|---|
| Blu-ray `.m2ts`, 7 untagged tracks, container ids 4352–4358 | DTS · 5.1 (×4, with Track N), AC-3 · 5.1 (×2), AC-3 · Stereo | Yes: dts/6, ac3/6, ac3/2 |
| Matroska test 5 | AAC · Stereo / Default; English / Commentary · Mono · AAC | Yes: aac/2, aac/1 |
| HLS with an audio description rendition | English / Audio description · Stereo · AAC | Yes |
| bipbop HLS (audio in 6 variants) | 2 rows offered of 7 | n/a |

### Not verified

- A physical phone, Android TV or Google TV device; Media3's audible
  output (its test reads ExoPlayer's track selection).
- Whether Media3 plays a track the device cannot decode silently.
- Real provider streams.

## Related known issue

On libmpv, an HLS stream with fMP4 segments also freezes when it is
seeked **before** `play()`, with the default rendition and no audio
change. The player resumes that way (`_initialize`, step 6 of the
[lifecycle](playback-lifecycle.md)), so resuming such a stream on Windows
can stall. Not changed here.

## Tests

`audio_tracks_test` (naming, libmpv metadata, variant copies,
`AudioSwitchCheck`, TV D-pad in the sheet),
`player_settings_sheet_test` (the Audio & language page),
`integration_test/audio_track_switch_test.dart` and
`integration_test/audio_track_metadata_test.dart` (libmpv: Windows or an
Android device) and `integration_test/media3_audio_track_test.dart`
(Media3: Android), all needing internet. `player_session_test` covers the
opening choice (a playing track in the preferred language stays).
