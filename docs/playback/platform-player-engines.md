# Player engines

Reelish's player UI talks to one API, package:video_player's
`VideoPlayerController`. Underneath, a platform engine demuxes, decodes and
renders. All of it is in
[`player_engine.dart`](../../lib/src/services/player_engine.dart).

| Engine | `PlayerEngineId` | Platforms | Package | Notes |
|---|---|---|---|---|
| `Media3PlayerEngine` | `media3` | Android (first choice) | `video_player_android` (ExoPlayer/Media3) | HTTPS only here: obeys Android's cleartext policy; no RTMP/RTSP/UDP/SRT/MMS; no text tracks through video_player |
| `MpvPlayerEngine` | `mediaKit` | Android (fallback), Windows (only engine) | vendored [`packages/video_player_media_kit`](../../packages/video_player_media_kit) over libmpv (`media_kit_libs_android_video`, `media_kit_libs_windows_video`) | Own network stack; handles cleartext and other schemes; exposes embedded subtitles; loaded lazily on first use |
| `FlutterPlatformPlayerEngine` | `flutterPlatform` | Any other platform (not shipped) | video_player's default | Kept so the code runs in tests and on unsupported targets |

## Selection

- **At launch.** `PlayerEngineBootstrap.initialize` (called from `main`)
  selects Media3 on Android and asks `onfeed/player` whether this is an
  emulator; on an emulator libmpv renders through MediaCodec output because
  its OpenGL output cannot start there.
- **Per platform.** `PlayerEngineFactory.forCurrentPlatform`: Android →
  Media3, Windows → libmpv.
- **Per source.** `PlayerEngineFactory.forSource`: on Android, any URL that
  is not `https` (cleartext HTTP, the torrent streamer's loopback URL,
  RTMP, …) goes straight to libmpv instead of failing on Media3 first.
- **Fallback.** `PlayerEngineFactory.alternateFor`: Media3 ↔ libmpv on
  Android; none on Windows. The player uses it when a failure can depend on
  the engine (see [the recovery policy](playback-architecture.md#recovery-policy)).
  An engine that played what the preferred one could not becomes the
  preferred engine for the rest of the session. The viewer can also switch
  engines from the player settings (`_switchEngine`).

## The engine gate

package:video_player routes every controller call, `dispose` included,
through one app-wide platform instance. Switching engines while a player of
the other engine is still open would send that player's calls to the wrong
engine. So:

- `PlayerEngineGate.activate` waits (up to 5 s) until no player of another
  engine is alive, then activates the requested one.
- `Media3PlayerEngine.activate` never replaces an `AndroidVideoPlayer` that
  is already the platform instance: replacing it would make the plugin
  dispose every native player.
- `_EngineVideoController.dispose` waits at most 5 s for the native dispose
  and always releases its gate entry, so a libmpv dispose stuck behind a
  never-initialised Android surface cannot freeze the next screen.

Do not change engine order, the scheme routing or the gate without a
verified cause; see the `playback-audit` skill.

## Torrents

On Android, compatible providers may return torrent (magnet / info hash)
sources:

- `TorrentSupport.available`
  ([`torrent_source_preparer.dart`](../../lib/src/services/torrent_source_preparer.dart))
  is true only in 64-bit Android processes; the streamer's native library
  is built for `arm64-v8a` and `x86_64`. Many TV devices run 32-bit
  Android, so they neither request nor offer torrents. On Windows it is
  false, so torrents are never requested and the P2P setting is hidden.
  (Widget tests that simulate Android on a desktop host get `true`.)
- `TorrentSourcePreparer` validates the info hash and trackers, starts a
  session in the vendored Go streamer
  ([`packages/flutter_go_torrent_streamer`](../../packages/flutter_go_torrent_streamer)),
  waits for metadata, picks the video file and returns a loopback URL,
  which libmpv plays (it is not `https`).
- Torrent data lives in the app's cache, capped at 5 GiB and cleaned at
  startup when a clear is pending (`StorageService.cleanTorrentDataAtStartup`).

## Platform differences in the player

| | Android phone | Android TV | Windows |
|---|---|---|---|
| Engine | Media3 → libmpv | Media3 → libmpv | libmpv |
| Embedded subtitles | libmpv only | libmpv only | yes |
| Input | Touch gestures, double-tap seek, lock | Remote keys, Back shows controls | Mouse (click plays or pauses, double click toggles fullscreen, wheel sets volume, a speaker button with a slider), keyboard (Space, arrows, M, F, F11), controller |
| Picture in picture | Automatic on leaving the app while playing, or the button (`player_pip.dart`) | The button, where the TV supports it | No |
| Brightness, rotation | Yes | No | No |
| Keeps the display on while playing | Yes | Yes | Yes (`DesktopWindow.keepDisplayOn`) |
| Screen lock | Touch lock | — | Keys and controller (`player_lock_overlay.dart`) |
