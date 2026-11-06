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
/// stalls=0 failures=http:1 open=620ms playToFrame=240ms rebufferRatio=0.5%
/// recovered=1/1 (2400ms) close=80ms`.
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
  Duration? _open;
  DateTime? _playRequestedAt;
  Duration? _playToFrame;
  Duration _played = Duration.zero;
  DateTime? _playingSince;
  DateTime? _recoveringSince;
  int _recoveries = 0;
  int _recovered = 0;
  Duration _recovering = Duration.zero;
  Duration _slowestClose = Duration.zero;
  bool _gaveUp = false;
  final Map<PlaybackFailureKind, int> _failures = {};
  PlaybackFailureKind? _firstFailure;
  bool _reported = false;

  /// The first picture of the session (later sources keep the first time).
  void firstFrame(String engine) {
    _engine = engine;
    final now = _clock();
    _firstFrame ??= now.difference(_openedAt);
    final requested = _playRequestedAt;
    if (_playToFrame == null && requested != null) {
      _playToFrame = now.difference(requested);
    }
    _gaveUp = false;
    final since = _recoveringSince;
    if (since != null) {
      _recovering += now.difference(since);
      _recoveringSince = null;
      _recovered++;
    }
  }

  /// How long the first engine that opened took, from its attempt starting.
  void opened(Duration elapsed) => _open ??= elapsed;

  /// The session's first play request, which starts the time to first frame
  /// without the time spent opening.
  void playRequested() => _playRequestedAt ??= _clock();

  /// Called on every player update: [playing] is true while the picture is
  /// moving, the time [rebufferRatio] compares buffering with.
  void playing(bool playing) {
    final since = _playingSince;
    if (playing && since == null) {
      _playingSince = _clock();
    } else if (!playing && since != null) {
      _played += _clock().difference(since);
      _playingSince = null;
    }
  }

  /// The player went away, so neither playing nor buffering is still going.
  void interrupted() {
    playing(false);
    buffering(false);
  }

  /// Playback that had started failed and recovery began. One incident stays
  /// one recovery, however many attempts it takes.
  void recovering() {
    if (_recoveringSince != null) return;
    _recoveringSince = _clock();
    _recoveries++;
  }

  /// Every way of continuing has failed, and the error screen is up.
  void gaveUp() {
    _gaveUp = true;
    _recoveringSince = null;
  }

  /// One player took [elapsed] to close; the slowest is kept.
  void closed(Duration elapsed) {
    if (elapsed > _slowestClose) _slowestClose = elapsed;
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

  Duration get _totalPlayed {
    final since = _playingSince;
    return since == null ? _played : _played + _clock().difference(since);
  }

  /// The share of viewing time spent waiting for data (0–1), or null before
  /// anything played.
  double? get rebufferRatio {
    final waited = _totalRebuffering.inMilliseconds;
    final total = _totalPlayed.inMilliseconds + waited;
    return total == 0 ? null : waited / total;
  }

  /// The session so far, as one line.
  String summary() {
    final failures = _failures.isEmpty
        ? 'none'
        : _failures.entries.map((e) => '${e.key.name}:${e.value}').join(',');
    final ratio = rebufferRatio;
    return 'engine=${_engine.isEmpty ? '-' : _engine} '
        'firstFrame=${_firstFrame == null ? 'never' : '${_firstFrame!.inMilliseconds}ms'} '
        'rebuffers=$_rebuffers (${_totalRebuffering.inMilliseconds}ms) '
        'stalls=$_stalls failures=$failures '
        'open=${_open == null ? '-' : '${_open!.inMilliseconds}ms'} '
        'playToFrame=${_playToFrame == null ? '-' : '${_playToFrame!.inMilliseconds}ms'} '
        'rebufferRatio=${ratio == null ? '-' : '${(ratio * 100).toStringAsFixed(1)}%'} '
        'recovered=$_recovered/$_recoveries (${_recovering.inMilliseconds}ms) '
        'close=${_slowestClose.inMilliseconds}ms';
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
        ? _gaveUp
              ? PlaybackOutcome.interrupted
              : PlaybackOutcome.played
        : _failures.isNotEmpty
        ? PlaybackOutcome.failed
        : PlaybackOutcome.abandoned,
    engine: _engine,
    firstFrameMs: _firstFrame?.inMilliseconds,
    rebuffers: _rebuffers,
    rebufferMs: _totalRebuffering.inMilliseconds,
    stalls: _stalls,
    playToFrameMs: _playToFrame?.inMilliseconds,
    rebufferPercent: rebufferRatio == null
        ? null
        : (rebufferRatio! * 100).round(),
    recoveries: _recoveries,
    recovered: _recovered,
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
