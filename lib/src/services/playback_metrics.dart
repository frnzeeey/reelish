import 'package:flutter/foundation.dart';

import 'playback_coordinator.dart';

/// One player session's timings and failures, for measuring playback on
/// real devices in debug and profile builds. Release builds record and
/// print nothing. Never holds URLs, headers or titles.
///
/// The summary, printed when the player closes, looks like
/// `[Playback][Summary] engine=media3 firstFrame=1840ms rebuffers=2 (3100ms)
/// stalls=0 failures=http:1`.
class PlaybackMetrics {
  PlaybackMetrics({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _openedAt = _clock();
  }

  /// Whether this build records anything.
  static const enabled = !kReleaseMode;

  final DateTime Function() _clock;
  late final DateTime _openedAt;
  Duration? _firstFrame;
  String _engine = '';
  int _rebuffers = 0;
  Duration _rebuffering = Duration.zero;
  DateTime? _bufferingSince;
  int _stalls = 0;
  final Map<PlaybackFailureKind, int> _failures = {};

  /// The first picture of the session (later sources keep the first time).
  void firstFrame(String engine) {
    if (!enabled) return;
    _engine = engine;
    _firstFrame ??= _clock().difference(_openedAt);
  }

  /// Called on every player update: [buffering] is true while playback,
  /// after its first frame, waits for data.
  void buffering(bool buffering) {
    if (!enabled || _firstFrame == null) return;
    final since = _bufferingSince;
    if (buffering && since == null) {
      _bufferingSince = _clock();
      _rebuffers++;
    } else if (!buffering && since != null) {
      _rebuffering += _clock().difference(since);
      _bufferingSince = null;
    }
  }

  void stall() {
    if (enabled) _stalls++;
  }

  void failure(PlaybackFailureKind kind) {
    if (enabled) _failures[kind] = (_failures[kind] ?? 0) + 1;
  }

  /// The session so far, as one line.
  String summary() {
    final since = _bufferingSince;
    final rebuffering = since == null
        ? _rebuffering
        : _rebuffering + _clock().difference(since);
    final failures = _failures.isEmpty
        ? 'none'
        : _failures.entries.map((e) => '${e.key.name}:${e.value}').join(',');
    return 'engine=${_engine.isEmpty ? '-' : _engine} '
        'firstFrame=${_firstFrame == null ? 'never' : '${_firstFrame!.inMilliseconds}ms'} '
        'rebuffers=$_rebuffers (${rebuffering.inMilliseconds}ms) '
        'stalls=$_stalls failures=$failures';
  }

  /// Prints [summary] once the session ends.
  void report() {
    if (enabled) debugPrint('[Playback][Summary] ${summary()}');
  }
}
