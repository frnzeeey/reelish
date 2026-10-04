import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:video_player_android/video_player_android.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

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

  static AndroidVideoPlayer? _platform;

  @override
  PlayerEngineId get id => PlayerEngineId.media3;

  /// Selects Media3 without replacing an already active instance.
  /// package:video_player sends every controller call through the current
  /// platform instance and calls `init()` whenever that instance changes,
  /// which on Android disposes every native player.
  @override
  void activate() {
    final current = VideoPlayerPlatform.instance;
    if (current is AndroidVideoPlayer) {
      _platform = current;
      return;
    }
    VideoPlayerPlatform.instance = _platform ??= AndroidVideoPlayer();
  }

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

  /// The engine to try first for [url], given the session's [preferred]
  /// engine.
  ///
  /// On Android, Media3 obeys the platform network security policy, which
  /// blocks cleartext HTTP (including the torrent streamer's loopback URL)
  /// for this app's target SDK, and Media3 has no RTMP/RTSP/UDP/SRT/MMS
  /// support here. libmpv uses its own network stack and handles those, so
  /// such URLs go to it directly instead of failing on Media3 first.
  static PlayerEngine forSource(String url, PlayerEngine preferred) {
    if (preferred.id != PlayerEngineId.media3) return preferred;
    final scheme = Uri.tryParse(url.trim())?.scheme.toLowerCase() ?? '';
    return scheme == 'https' ? preferred : const MpvPlayerEngine();
  }

  /// Whether [engine] can open [url] at all, so a fallback to it is useful.
  static bool canOpen(PlayerEngine engine, String url) {
    if (engine.id != PlayerEngineId.media3) return true;
    return Uri.tryParse(url.trim())?.scheme.toLowerCase() == 'https';
  }

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
      const Media3PlayerEngine().activate();
    }
  }
}
