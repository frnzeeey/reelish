// A scriptable stand-in for the native video engines, for widget tests that
// drive the player session (opening, failures, fallbacks) without Media3 or
// libmpv.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// One player the session created. Tests decide what it does.
class FakePlayer {
  FakePlayer(this.id, this.uri, this.headers, void Function(FakePlayer)? script)
    : _script = script;

  final int id;
  final String uri;
  final Map<String, String> headers;
  final void Function(FakePlayer)? _script;

  // The player is scripted once the controller listens, so its first events
  // reach it. onCancel returns a future of the test's zone: without one,
  // cancelling returns a future of the root zone, which a widget test's fake
  // async never completes, and VideoPlayerController.dispose would hang.
  late final StreamController<VideoEvent> _events = StreamController(
    onListen: () => scheduleMicrotask(() => _script?.call(this)),
    onCancel: () => Future<void>.value(),
  );

  Duration position = Duration.zero;
  bool playing = false;
  bool disposed = false;
  int playCalls = 0;

  /// The engine opened the media: `initialize()` completes.
  void initialize({
    Duration duration = const Duration(minutes: 90),
    Size size = const Size(1920, 1080),
  }) {
    if (disposed) return;
    _events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: duration,
        size: size,
      ),
    );
  }

  /// The engine reports an error, the way the platform plugins do.
  void fail(String message) {
    if (disposed) return;
    _events.addError(PlatformException(code: 'VideoError', message: message));
  }

  /// The engine says it started playing.
  void reportPlaying() {
    if (disposed) return;
    playing = true;
    _events.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: true,
      ),
    );
  }

  Future<void> _close() async {
    disposed = true;
    playing = false;
    unawaited(_events.close());
  }
}

/// Records every player and lets [onCreate] script it. By default a player
/// stays silent: `initialize()` waits until the test calls
/// [FakePlayer.initialize] or [FakePlayer.fail].
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  FakeVideoPlayerPlatform({this.onCreate});

  /// Scripts each new player, once its controller listens for events.
  void Function(FakePlayer player)? onCreate;

  final List<FakePlayer> players = [];

  /// Players created and not yet disposed.
  Iterable<FakePlayer> get live => players.where((player) => !player.disposed);

  FakePlayer _player(int id) => players.firstWhere((player) => player.id == id);

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async {
    final player = FakePlayer(
      players.length + 1,
      dataSource.uri ?? '',
      dataSource.httpHeaders,
      onCreate,
    );
    players.add(player);
    return player.id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _player(playerId)._events.stream;

  @override
  Future<void> dispose(int playerId) => _player(playerId)._close();

  @override
  Future<void> play(int playerId) async {
    final player = _player(playerId);
    player.playCalls++;
    player.reportPlaying();
  }

  @override
  Future<void> pause(int playerId) async {
    _player(playerId).playing = false;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      _player(playerId).position;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    _player(playerId).position = position;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleep,
  ) async {}

  @override
  bool isAudioTrackSupportAvailable() => false;

  @override
  bool isVideoTrackSupportAvailable() => false;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}
