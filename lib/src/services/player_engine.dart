import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
      PlayerEngineGate._track(
        _EngineVideoController(
          source.uri,
          formatHint: _formatHint(source.streamType),
          httpHeaders: source.headers,
        ),
        id,
      );
}

class MpvPlayerEngine implements PlayerEngine {
  const MpvPlayerEngine();

  @override
  PlayerEngineId get id => PlayerEngineId.mediaKit;

  @override
  void activate() {
    // Loads libmpv on first use rather than at app launch; it is the
    // fallback engine, so most sessions never need it. Idempotent.
    VideoPlayerMediaKit.ensureInitialized(android: true);
    VideoPlayerMediaKit.registerWith();
  }

  @override
  VideoPlayerController createController(PlayableSource source) =>
      PlayerEngineGate._track(
        _EngineVideoController(
          source.uri,
          formatHint: _formatHint(source.streamType),
          httpHeaders: source.headers,
        ),
        id,
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
      PlayerEngineGate._track(
        _EngineVideoController(
          source.uri,
          formatHint: _formatHint(source.streamType),
          httpHeaders: source.headers,
        ),
        id,
      );
}

/// A controller that tells [PlayerEngineGate] when it is gone.
class _EngineVideoController extends VideoPlayerController {
  _EngineVideoController(super.uri, {super.formatHint, super.httpHeaders})
    : super.networkUrl();

  /// Longest a caller waits for an engine to dispose a player.
  static const disposeTimeout = Duration(seconds: 5);

  /// Bounded: libmpv (media_kit) runs play and dispose under one per-player
  /// lock, and its play first waits for the Android video surface. When that
  /// surface never initializes, play never returns and dispose would wait
  /// behind it forever, leaving the screen that disposes it (and the next
  /// source or episode) stuck. The native dispose still finishes if the
  /// engine ever recovers; callers just stop waiting for it.
  @override
  Future<void> dispose() async {
    try {
      await super.dispose().timeout(
        disposeTimeout,
        onTimeout: () {
          if (kDebugMode) {
            debugPrint(
              '[Playback][Engine] player did not dispose within '
              '${disposeTimeout.inSeconds}s; moving on',
            );
          }
        },
      );
    } finally {
      PlayerEngineGate._release(this);
    }
  }
}

/// Keeps engines from switching under a live player.
///
/// package:video_player sends every controller call, dispose included,
/// through one app-wide platform instance. Selecting another engine while a
/// player of the current one is still open (or still being disposed) would
/// send that player's calls, and its dispose, to the wrong engine: its
/// native player would be orphaned and could keep playing, and switching
/// back makes the plugin dispose all of its players at once. So a switch
/// first waits for the other engine's players to be disposed.
abstract final class PlayerEngineGate {
  static final Map<VideoPlayerController, PlayerEngineId> _live = {};
  static Completer<void>? _released;

  /// Longest a switch waits for the other engine's players.
  static const maxWait = Duration(seconds: 5);

  /// Live controllers by engine, for diagnostics and tests.
  @visibleForTesting
  static int liveCount(PlayerEngineId engine) =>
      _live.values.where((id) => id == engine).length;

  static VideoPlayerController _track(
    VideoPlayerController controller,
    PlayerEngineId engine,
  ) {
    _live[controller] = engine;
    return controller;
  }

  static void _release(VideoPlayerController controller) {
    if (_live.remove(controller) == null) return;
    final released = _released;
    _released = null;
    released?.complete();
  }

  /// Selects [engine] once no player of another engine is alive, or after
  /// [maxWait], whichever comes first.
  static Future<void> activate(
    PlayerEngine engine, {
    Duration timeout = maxWait,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_live.values.any((id) => id != engine.id)) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        if (kDebugMode) {
          debugPrint(
            '[Playback][Engine] switching to ${engine.id.name} while another '
            'engine still has a player open',
          );
        }
        break;
      }
      await (_released ??= Completer<void>()).future.timeout(
        remaining,
        onTimeout: () {},
      );
    }
    engine.activate();
  }
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

/// Selects the default engine at launch. libmpv is loaded lazily by
/// [MpvPlayerEngine.activate], keeping its native libraries off the cold-start
/// path.
class PlayerEngineBootstrap {
  static void initialize() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      const Media3PlayerEngine().activate();
      unawaited(_configureForEmulator());
    }
  }

  /// On an Android emulator libmpv's OpenGL video output cannot start, so
  /// libmpv would play audio over a black picture; render through MediaCodec
  /// instead. Physical devices are unaffected. Resolves long before libmpv is
  /// first used (it is the fallback engine).
  static Future<void> _configureForEmulator() async {
    try {
      final emulator = await const MethodChannel(
        'onfeed/player',
      ).invokeMethod<bool>('isEmulator');
      MediaKitVideoPlayer.useMediaCodecOutput = emulator ?? false;
    } catch (_) {
      // Unknown: keep media_kit's defaults.
    }
  }
}
