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
   clears the session choice.
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
| Neither (or `und`) | `Audio track 3` |

The detail adds channels (Stereo, 5.1) and codec; rows that would still
read the same get `Track N`. Nothing is invented: no "Original", no guessed
language.

## Engine support

| | Media3 (Android first choice) | libmpv (Windows; Android fallback) |
|---|---|---|
| Enumeration | `Tracks` groups, id `group_track` | libmpv `track-list` |
| Selected track | `Tracks.Group.isTrackSelected` | libmpv's `aid`, observed (media_kit's own state is `auto` until a pick) |
| Switch | `TrackSelectionOverride`; the call waits up to 5 s for ExoPlayer's track event | `aid`, answered at once |
| Labels | `Format.label`, `Format.language` | stream title, language |

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

`audio_tracks_test` (naming, `AudioSwitchCheck`, TV D-pad in the sheet),
`player_settings_sheet_test` (the Audio & language page),
`integration_test/audio_track_switch_test.dart` (libmpv: Windows or an
Android device) and `integration_test/media3_audio_track_test.dart`
(Media3: Android), both needing internet.
