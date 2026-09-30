import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:video_player_android/video_player_android.dart';

import '../models/playable_source.dart';
import '../models/stream_type.dart';

enum PlayerEngineId { media3, mediaKit, flutterPlatform }

/// Common controller boundary. Reelish's UI consumes video_player events and
/// controls, while platform engines own demuxing, decoding, and rendering.
abstract interface class PlayerEngine {
  PlayerEngineId get id;
  void activate();
  VideoPlayerController createController(PlayableSource source);
}

class Media3PlayerEngine implements PlayerEngine {
  const Media3PlayerEngine();

  @override
  PlayerEngineId get id => PlayerEngineId.media3;

  @override
  void activate() => AndroidVideoPlayer.registerWith();

  @override
  VideoPlayerController createController(PlayableSource source) =>
      VideoPlayerController.networkUrl(
        source.uri,
        formatHint: _formatHint(source.streamType),
        httpHeaders: source.headers,
      );
}

class MpvPlayerEngine implements PlayerEngine {
  const MpvPlayerEngine();

  @override
  PlayerEngineId get id => PlayerEngineId.mediaKit;

  @override
  void activate() => VideoPlayerMediaKit.registerWith();

  @override
  VideoPlayerController createController(PlayableSource source) =>
      VideoPlayerController.networkUrl(
        source.uri,
        formatHint: _formatHint(source.streamType),
        httpHeaders: source.headers,
      );
}

class FlutterPlatformPlayerEngine implements PlayerEngine {
  const FlutterPlatformPlayerEngine();

  @override
  PlayerEngineId get id => PlayerEngineId.flutterPlatform;

  @override
  void activate() {}

  @override
  VideoPlayerController createController(PlayableSource source) =>
      VideoPlayerController.networkUrl(
        source.uri,
        formatHint: _formatHint(source.streamType),
        httpHeaders: source.headers,
      );
}

VideoFormat? _formatHint(StreamType type) => switch (type) {
  StreamType.hls => VideoFormat.hls,
  StreamType.dash => VideoFormat.dash,
  _ => null,
};

class PlayerEngineFactory {
  static PlayerEngine forCurrentPlatform() =>
      defaultTargetPlatform == TargetPlatform.android
      ? const Media3PlayerEngine()
      : const FlutterPlatformPlayerEngine();

  static PlayerEngine? alternateFor(PlayerEngine engine) => switch (engine.id) {
    PlayerEngineId.media3 => const MpvPlayerEngine(),
    PlayerEngineId.mediaKit => const Media3PlayerEngine(),
    PlayerEngineId.flutterPlatform => null,
  };
}

class PlayerEngineBootstrap {
  static void initialize() {
    VideoPlayerMediaKit.ensureInitialized(android: true);
    if (defaultTargetPlatform == TargetPlatform.android) {
      AndroidVideoPlayer.registerWith();
    }
  }
}
