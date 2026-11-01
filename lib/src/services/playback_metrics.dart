import 'package:flutter/foundation.dart';

import '../analytics/analytics_events.dart';
import '../analytics/analytics_service.dart';
import 'playback_coordinator.dart';

/// One player session's timings and failures. Debug and profile builds
/// print a summary when the player closes; every build hands the same
/// counts to opt-in usage statistics as one event per session. Never holds
/// URLs, headers, provider names or titles.
///
/// The summary looks like
/// `[Playback][Summary] engine=media3 firstFrame=1840ms rebuffers=2 (3100ms)
/// stalls=0 failures=http:1`.
class PlaybackMetrics {
  PlaybackMetrics({DateTime Function()? clock, this.analytics})
    : _clock = clock ?? DateTime.now {
    _openedAt = _clock();
  }

  /// Whether the summary is printed (never in release builds).
  static const printsSummary = !kReleaseMode;

  final DateTime Function() _clock;

  /// Where [report] sends its event; [AnalyticsService.instance] when null.
  final AnalyticsService? analytics;
  late final DateTime _openedAt;
  Duration? _firstFrame;
  String _engine = '';
  int _rebuffers = 0;
  Duration _rebuffering = Duration.zero;
  DateTime? _bufferingSince;
  int _stalls = 0;
  final Map<PlaybackFailureKind, int> _failures = {};
  PlaybackFailureKind? _firstFailure;
  bool _reported = false;

  /// The first picture of the session (later sources keep the first time).
  void firstFrame(String engine) {
    _engine = engine;
    _firstFrame ??= _clock().difference(_openedAt);
  }

  /// Called on every player update: [buffering] is true while playback,
  /// after its first frame, waits for data.
  void buffering(bool buffering) {
    if (_firstFrame == null) return;
    final since = _bufferingSince;
    if (buffering && since == null) {
      _bufferingSince = _clock();
      _rebuffers++;
    } else if (!buffering && since != null) {
      _rebuffering += _clock().difference(since);
      _bufferingSince = null;
    }
  }

  void stall() => _stalls++;

  void failure(PlaybackFailureKind kind) {
    _firstFailure ??= kind;
    _failures[kind] = (_failures[kind] ?? 0) + 1;
  }

  Duration get _totalRebuffering {
    final since = _bufferingSince;
    return since == null
        ? _rebuffering
        : _rebuffering + _clock().difference(since);
  }

  /// The session so far, as one line.
  String summary() {
    final failures = _failures.isEmpty
        ? 'none'
        : _failures.entries.map((e) => '${e.key.name}:${e.value}').join(',');
    return 'engine=${_engine.isEmpty ? '-' : _engine} '
        'firstFrame=${_firstFrame == null ? 'never' : '${_firstFrame!.inMilliseconds}ms'} '
        'rebuffers=$_rebuffers (${_totalRebuffering.inMilliseconds}ms) '
        'stalls=$_stalls failures=$failures';
  }

  /// The session as one analytics event. [watched] is the share of the
  /// title reached (0–1), when known.
  AnalyticsEvent event({
    required String contentType,
    required String itemId,
    double? watched,
    bool watchParty = false,
  }) => AnalyticsEvent.playbackSession(
    contentType: contentType,
    itemId: itemId,
    outcome: _firstFrame != null
        ? PlaybackOutcome.played
        : _failures.isNotEmpty
        ? PlaybackOutcome.failed
        : PlaybackOutcome.abandoned,
    engine: _engine,
    firstFrameMs: _firstFrame?.inMilliseconds,
    rebuffers: _rebuffers,
    rebufferMs: _totalRebuffering.inMilliseconds,
    stalls: _stalls,
    failure: _firstFailure?.name ?? '',
    // Tens of percent: enough for completion rates, less to send.
    watchedPercent: watched == null
        ? null
        : ((watched.clamp(0.0, 1.0) * 10).round() * 10),
    watchParty: watchParty,
  );

  /// Ends the session: prints [summary] (debug and profile) and sends
  /// [event] once (only when the viewer shares usage statistics).
  void report({
    required String contentType,
    required String itemId,
    double? watched,
    bool watchParty = false,
  }) {
    if (_reported) return;
    _reported = true;
    if (printsSummary) debugPrint('[Playback][Summary] ${summary()}');
    (analytics ?? AnalyticsService.instance).log(
      event(
        contentType: contentType,
        itemId: itemId,
        watched: watched,
        watchParty: watchParty,
      ),
    );
  }
}
