/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2023 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

// https://github.com/dart-lang/linter/issues/1381
// ignore_for_file: close_sinks

/// package:media_kit implementation of [VideoPlayerPlatform].
///
/// References:
/// * https://pub.dev/packages/media_kit
/// * https://github.com/media-kit/media-kit
///
class MediaKitVideoPlayer extends VideoPlayerPlatform {
  // The implementation uses [Player.hashCode] as texture ID.
  final _players = HashMap<int, Player>();
  final _completers = HashMap<int, Completer<void>>();
  final _videoControllers = HashMap<int, VideoController>();
  final _streamControllers = HashMap<int, StreamController<VideoEvent>>();
  final _streamSubscriptions = HashMap<int, List<StreamSubscription>>();

  static MediaKitVideoPlayer? _shared;

  /// Renders video through Android's MediaCodec straight into the video
  /// surface (`vo=mediacodec_embed`, `hwdec=mediacodec`) instead of libmpv's
  /// OpenGL ES output (`vo=gpu`).
  ///
  /// For Android emulators: there media_kit switches to software decoding,
  /// and libmpv cannot create its EGL context on the emulator's OpenGL ES
  /// translator ("Could not create EGL context for GLES 2.x"). libmpv then
  /// drops the video track and plays audio over a black picture. Physical
  /// devices keep media_kit's defaults. Applies to players created after
  /// it is set.
  static bool useMediaCodecOutput = false;

  /// Registers this class as the default instance of [VideoPlayerPlatform].
  ///
  /// One instance is shared and re-registering it is a no-op. package:
  /// video_player routes every controller call (including dispose) through
  /// the current instance, so replacing it while a player is open or still
  /// opening would leave that native player unreachable and never disposed.
  static void registerWith() {
    final shared = _shared ??= MediaKitVideoPlayer();
    if (identical(VideoPlayerPlatform.instance, shared)) return;
    VideoPlayerPlatform.instance = shared;
  }

  /// Initializes the platform interface and disposes all existing players.
  ///
  /// This method is called when the plugin is first initialized and on every full restart.
  @override
  Future<void> init() async {
    // Copy the keys: dispose() removes entries while this loop runs.
    for (final textureId in _players.keys.toList()) {
      await dispose(textureId);
    }

    _players.clear();
    _completers.clear();
    _videoControllers.clear();
    _streamControllers.clear();
    _streamSubscriptions.clear();
  }

  /// Clears one video.
  @override
  Future<void> dispose(int textureId) async {
    await _players[textureId]?.dispose();

    await _streamControllers[textureId]?.close();
    await Future.wait(
      _streamSubscriptions[textureId]?.map((e) => e.cancel()) ?? [],
    );

    _players.remove(textureId);
    _completers.remove(textureId);
    _videoControllers.remove(textureId);
    _streamControllers.remove(textureId);
    _streamSubscriptions.remove(textureId);
  }

  /// Creates an instance of a video player and returns its textureId.
  @override
  Future<int?> create(DataSource dataSource) async {
    final player = Player();
    final completer = Completer();
    final videoController = VideoController(
      player,
      configuration: useMediaCodecOutput
          ? const VideoControllerConfiguration(
              vo: 'mediacodec_embed',
              hwdec: 'mediacodec',
            )
          : const VideoControllerConfiguration(),
    );
    // NOTE: [StreamController] without broadcast buffers events.
    final streamController = StreamController<VideoEvent>();
    final streamSubscriptions = <StreamSubscription>[];

    final textureId = player.hashCode;
    _latestPlayerId = textureId;

    _players[textureId] = player;
    _completers[textureId] = completer;
    _videoControllers[textureId] = videoController;
    _streamControllers[textureId] = streamController;
    _streamSubscriptions[textureId] = streamSubscriptions;

    // --------------------------------------------------
    final markMediaOpened = _initialize(textureId);
    // --------------------------------------------------

    final String resource;
    final Map<String, String> httpHeaders = dataSource.httpHeaders;

    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        final String? asset;
        if (dataSource.package == null) {
          asset = dataSource.asset;
        } else {
          asset = 'packages/${dataSource.package}/${dataSource.asset}';
        }
        resource = 'asset:///$asset';
        break;

      case DataSourceType.network:
      case DataSourceType.file:
      case DataSourceType.contentUri:
        if (dataSource.uri == null) {
          throw ArgumentError('uri must not be null');
        }
        resource = dataSource.uri!;
        break;

      default:
        throw UnsupportedError('${dataSource.sourceType} is not supported');
    }

    await player.open(
      Media(
        resource,
        httpHeaders: httpHeaders,
      ),
      play: false,
    );
    markMediaOpened();

    return textureId;
  }

  /// Returns a Stream of [VideoEventType]s.
  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    if (_streamControllers[textureId] == null) {
      throw StateError(
          'VideoPlayer for textureId $textureId is not found, Check if its disposed.');
    }
    return _streamControllers[textureId]!.stream;
  }

  /// Sets the looping attribute of the video.
  @override
  Future<void> setLooping(int textureId, bool looping) async {
    final playlistMode = looping ? PlaylistMode.single : PlaylistMode.none;
    return _players[textureId]?.setPlaylistMode(playlistMode);
  }

  /// Starts the video playback.
  @override
  Future<void> play(int textureId) async {
    return _players[textureId]?.play();
  }

  /// Stops the video playback.
  @override
  Future<void> pause(int textureId) async {
    return _players[textureId]?.pause();
  }

  /// Sets the volume to a range between 0.0 and 1.0.
  @override
  Future<void> setVolume(int textureId, double volume) async {
    // NOTE: [volume] is in the range of 0.0 to 1.0 while [setVolume] expects 0.0 to 100.
    return _players[textureId]?.setVolume(volume * 100);
  }

  /// Sets the video position to a [Duration] from the start.
  @override
  Future<void> seekTo(int textureId, Duration position) async {
    return _players[textureId]?.seek(position);
  }

  /// Sets the playback speed to a [speed] value indicating the playback rate.
  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {
    return _players[textureId]?.setRate(speed);
  }

  /// Gets the video position as [Duration] from the start.
  @override
  Future<Duration> getPosition(int textureId) async {
    return _players[textureId]?.platform?.state.position ?? Duration.zero;
  }

  /// Returns a widget displaying the video with a given textureId.
  @override
  Widget buildView(int textureId) {
    if (_videoControllers[textureId] == null) {
      throw StateError(
          'VideoPlayer for textureId $textureId is not found, Check if its disposed.');
    }
    return Video(
      key: ValueKey(_videoControllers[textureId]!),
      controller: _videoControllers[textureId]!,
      wakelock: false,
      controls: NoVideoControls,
      fill: const Color(0x00000000),
      pauseUponEnteringBackgroundMode: false,
      // The app renders subtitle text itself (see subtitleLines) so every
      // subtitle source uses the same style and can be turned off.
      subtitleViewConfiguration:
          const SubtitleViewConfiguration(visible: false),
      resumeUponEnteringForegroundMode: false,
    );
  }

  /// Sets the audio mode to mix with other sources.
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => Future.value();

  /// Sets additional options on web.
  @override
  Future<void> setWebOptions(int textureId, VideoPlayerWebOptions options) =>
      Future.value();

  @override
  Future<List<VideoAudioTrack>> getAudioTracks(int playerId) async {
    final player = _players[playerId];
    if (player == null) return [];
    final selectedId = player.state.track.audio.id;
    return player.state.tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map((track) => VideoAudioTrack(
              id: track.id,
              label:
                  track.title ?? track.language ?? track.codec ?? 'Audio track',
              language: track.language,
              isSelected: track.id == selectedId,
              bitrate: track.bitrate,
              sampleRate: track.samplerate,
              channelCount: track.channelscount,
              codec: track.codec,
            ))
        .toList();
  }

  @override
  Future<void> selectAudioTrack(int playerId, String trackId) async {
    final player = _players[playerId];
    if (player == null) return;
    for (final track in player.state.tracks.audio) {
      if (track.id == trackId) {
        await player.setAudioTrack(track);
        return;
      }
    }
  }

  @override
  bool isAudioTrackSupportAvailable() => true;

  /// The shared instance, for the embedded-subtitle API below, which
  /// package:video_player's platform interface does not cover.
  static MediaKitVideoPlayer? get shared => _shared;

  int? _latestPlayerId;

  /// The most recently created player, while it is alive. Apps that keep one
  /// player at a time use it to reach that player (package:video_player keeps
  /// its player id private).
  int? get activePlayerId {
    final id = _latestPlayerId;
    return id != null && _players.containsKey(id) ? id : null;
  }

  /// Subtitle tracks inside the media (not external files), once mpv has
  /// read them. Empty for an unknown player.
  List<EmbeddedSubtitleTrack> embeddedSubtitles(int playerId) {
    final player = _players[playerId];
    if (player == null) return const [];
    return [
      for (final track in player.state.tracks.subtitle)
        if (track.id != 'auto' && track.id != 'no' && !track.uri && !track.data)
          EmbeddedSubtitleTrack(
            id: track.id,
            title: track.title ?? '',
            language: track.language ?? '',
          ),
    ];
  }

  /// The embedded track mpv is showing, or null for none.
  String? selectedEmbeddedSubtitle(int playerId) {
    final track = _players[playerId]?.state.track.subtitle;
    if (track == null ||
        track.id == 'auto' ||
        track.id == 'no' ||
        track.uri ||
        track.data) {
      return null;
    }
    return track.id;
  }

  /// Shows embedded track [trackId], or turns embedded subtitles off when
  /// null. Playback continues; only mpv's subtitle selection changes.
  Future<void> selectEmbeddedSubtitle(int playerId, String? trackId) async {
    final player = _players[playerId];
    if (player == null) return;
    if (trackId == null) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    for (final track in player.state.tracks.subtitle) {
      if (track.id == trackId) {
        await player.setSubtitleTrack(track);
        return;
      }
    }
  }

  /// Notifies when the track list or the selected track changes.
  Stream<void> subtitleTracksChanged(int playerId) {
    final player = _players[playerId];
    if (player == null) return const Stream.empty();
    StreamSubscription<void>? tracks, selection;
    late final StreamController<void> changes;
    changes = StreamController<void>(
      onListen: () {
        tracks = player.stream.tracks.listen((_) => changes.add(null));
        selection = player.stream.track.listen((_) => changes.add(null));
      },
      onCancel: () async {
        await tracks?.cancel();
        await selection?.cancel();
      },
    );
    return changes.stream;
  }

  /// Text of the current embedded subtitle, drawn by the app so it can use
  /// its own subtitle style (media_kit's own subtitle view is disabled).
  Stream<List<String>> subtitleLines(int playerId) =>
      _players[playerId]?.stream.subtitle ?? const Stream.empty();

  /// Shifts embedded subtitles by [seconds] (mpv `sub-delay`).
  Future<void> setSubtitleDelay(int playerId, double seconds) async {
    final platform = _players[playerId]?.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('sub-delay', seconds.toStringAsFixed(3));
    }
  }

  /// Initialize the [Stream]s for a given textureId.
  VoidCallback _initialize(int textureId) {
    if (_streamSubscriptions[textureId]?.isNotEmpty ?? false) {
      return () {};
    }

    final player = _players[textureId];
    final completer = _completers[textureId];
    final streamController = _streamControllers[textureId];
    final streamSubscriptions = _streamSubscriptions[textureId];

    if (player != null &&
        completer != null &&
        streamController != null &&
        streamSubscriptions != null) {
      // VideoEventType.initialized

      int? width;
      int? height;
      Duration? duration;
      var mediaOpened = false;
      var videoDiagnosticsLogged = false;
      var audioDiagnosticsLogged = false;
      final diagnosticsClock = Stopwatch()..start();

      void notify() {
        if (!completer.isCompleted) {
          if (width != null &&
              height != null &&
              (duration != null || mediaOpened)) {
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.initialized,
                size: Size(
                  (width ?? 0) * 1.0,
                  (height ?? 0) * 1.0,
                ),
                duration: duration ?? player.state.duration,
              ),
            );
            completer.complete();
          }
        }
      }

      streamSubscriptions.add(
        player.stream.duration.listen(
          (event) {
            if (event > Duration.zero) {
              duration = event;
              notify();
            }
          },
        ),
      );
      streamSubscriptions.add(
        player.stream.videoParams.listen(
          (event) {
            width = event.dw;
            height = event.dh;
            if (!videoDiagnosticsLogged &&
                (width ?? 0) > 0 &&
                (height ?? 0) > 0) {
              videoDiagnosticsLogged = true;
              if (kDebugMode) {
                debugPrint(
                  '[MPV] video decoder output at ${diagnosticsClock.elapsedMilliseconds}ms: '
                  '${event.w}x${event.h} display=${event.dw}x${event.dh} '
                  'pixel=${event.pixelformat ?? 'unknown'} '
                  'hardwarePixel=${event.hwPixelformat ?? 'unknown'}',
                );
              }
            }
            if ((width ?? 0) > 0 && (height ?? 0) > 0) {
              notify();
            }
          },
        ),
      );
      streamSubscriptions.add(
        player.stream.audioParams.listen((event) {
          if (audioDiagnosticsLogged || event.format == null) return;
          audioDiagnosticsLogged = true;
          if (kDebugMode) {
            debugPrint(
              '[MPV] audio decoder output at ${diagnosticsClock.elapsedMilliseconds}ms: '
              'format=${event.format} rate=${event.sampleRate} '
              'channels=${event.channels}',
            );
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.tracks.listen(
          (event) {
            if (kDebugMode && !videoDiagnosticsLogged) {
              final videoTracks = event.video
                  .where((track) => track.id != 'auto' && track.id != 'no')
                  .toList();
              final audioTracks = event.audio
                  .where((track) => track.id != 'auto' && track.id != 'no')
                  .toList();
              final video = videoTracks.isEmpty ? null : videoTracks.first;
              final audio = audioTracks.isEmpty ? null : audioTracks.first;
              debugPrint(
                '[MPV] tracks discovered: '
                'video=${video?.codec ?? 'none'} decoder=${video?.decoder ?? 'unknown'} '
                '${video?.w ?? 0}x${video?.h ?? 0}; '
                'audio=${audio?.codec ?? 'none'} decoder=${audio?.decoder ?? 'unknown'}',
              );
            }
            // No video track is available i.e. an audio file.
            if (event.video.length == 2 && event.audio.length > 2) {
              width = 0;
              height = 0;
              notify();
            }
          },
        ),
      );
      // VideoEventType.isPlayingStateUpdate
      streamSubscriptions.add(
        player.stream.playing.listen(
          (event) async {
            await completer.future;
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.isPlayingStateUpdate,
                isPlaying: event,
              ),
            );
          },
        ),
      );
      // VideoEventType.completed
      streamSubscriptions.add(
        player.stream.completed.listen(
          (event) async {
            await completer.future;
            if (event) {
              streamController.add(
                VideoEvent(
                  eventType: VideoEventType.completed,
                ),
              );
            }
          },
        ),
      );
      // VideoEventType.bufferingStart
      streamSubscriptions.add(
        player.stream.buffering.listen(
          (event) async {
            await completer.future;
            streamController.add(
              VideoEvent(
                eventType: event
                    ? VideoEventType.bufferingStart
                    : VideoEventType.bufferingEnd,
              ),
            );
          },
        ),
      );
      // VideoEventType.bufferingUpdate
      streamSubscriptions.add(
        player.stream.buffer.listen(
          (event) async {
            await completer.future;
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.bufferingUpdate,
                buffered: [
                  DurationRange(
                    Duration.zero,
                    event,
                  ),
                ],
              ),
            );
          },
        ),
      );

      streamSubscriptions.add(
        player.stream.error.listen(
          (event) {
            final error = PlatformException(code: '', message: event);
            // Initialization can fail before video dimensions or duration
            // arrive. Forward the error immediately so video_player's
            // initialize future can fail instead of timing out.
            streamController.addError(error);
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
        ),
      );

      return () {
        mediaOpened = true;
        duration ??= player.state.duration;
        notify();
      };
    }

    return () {};
  }
}

/// A subtitle track inside the media itself.
class EmbeddedSubtitleTrack {
  const EmbeddedSubtitleTrack({
    required this.id,
    required this.title,
    required this.language,
  });

  final String id;
  final String title;
  final String language;
}
