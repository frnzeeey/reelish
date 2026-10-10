import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/playback_coordinator.dart';
import '../../services/subtitle_loader.dart';

/// The text of the downloaded subtitle cue that should be on screen, kept
/// in step with the player's own clock.
///
/// package:video_player refreshes the playback position only every 100 ms,
/// so a cue picked straight from that value appears (and clears) up to
/// 100 ms late, and never early. Each position update re-anchors this clock
/// to the player; when a cue starts or ends before the next update would
/// arrive, a single one-shot timer flips the text at that moment, using the
/// time elapsed since the anchor scaled by the playback speed. Nothing runs
/// while paused or buffering, and the player's position is always the only
/// source of truth: the estimate never reaches past [maxProjection].
///
/// Listeners are notified only when the visible text changes, not on every
/// position update.
class ExternalCueClock extends ValueNotifier<String> {
  ExternalCueClock({Stopwatch? stopwatch})
    : _sinceAnchor = stopwatch ?? Stopwatch(),
      super('');

  /// How far past the last real position the clock may project. A little
  /// over one position update, so a stalled update can never let it run on.
  static const maxProjection = Duration(milliseconds: 250);

  /// Treats a position this far behind the clock's own projection, while
  /// playing, as reporting jitter rather than a seek, so a cue that just
  /// flipped on time does not flicker back for one update.
  static const _jitter = .15;

  /// The largest step between two checks that still counts as continuous
  /// playback, for diagnostics: a bigger jump is a seek.
  static const _continuity = .5;

  final Stopwatch _sinceAnchor;
  Timer? _boundary;
  List<SubtitleCue> _cues = const [];
  double _delay = 0;
  double _anchor = 0; // Media time of the last position, in seconds.
  double _speed = 1;
  bool _running = false;
  double? _lastShownAt;
  int _shownIndex = -1;

  /// Starts showing [cues], shifted by [delay] seconds (positive is later).
  /// Call with an empty list to clear.
  void setCues(List<SubtitleCue> cues, {required double delay}) {
    if (identical(cues, _cues) && delay == _delay) return;
    _cues = cues;
    _delay = delay;
    // New cues or a new delay are a new timeline; nothing carries over.
    _lastShownAt = null;
    _evaluate(_anchor + _projected, reason: 'cues');
  }

  /// Re-anchors to the player. Call on every position or state update.
  void sync({
    required Duration position,
    required bool playing,
    required double speed,
  }) {
    var media = position.inMicroseconds / 1e6;
    final last = _lastShownAt;
    if (playing &&
        _running &&
        last != null &&
        media - _delay < last &&
        last - (media - _delay) < _jitter) {
      // Reported slightly behind what is already shown: keep moving forward.
      media = last + _delay;
    }
    _anchor = media;
    _speed = speed > 0 ? speed : 1;
    _running = playing;
    _sinceAnchor
      ..reset()
      ..start();
    _evaluate(media, reason: 'position');
  }

  double get _projected {
    if (!_running) return 0;
    final elapsed = _sinceAnchor.elapsedMicroseconds.clamp(
      0,
      maxProjection.inMicroseconds,
    );
    return elapsed / 1e6 * _speed;
  }

  void _evaluate(double media, {required String reason}) {
    _boundary?.cancel();
    _boundary = null;
    final t = media - _delay;
    final index = cueIndexAt(_cues, t);
    final text = index < 0 ? '' : _cues[index].text;
    if (index != _shownIndex) {
      _logChange(index, t, _lastShownAt, reason);
      _shownIndex = index;
    }
    _lastShownAt = t;
    value = text;
    if (!_running || _cues.isEmpty) return;

    // The next moment the visible text changes: this cue's end, or the
    // next cue's start, whichever comes first.
    final next = nextBoundaryAfter(_cues, t);
    if (next == null) return;
    final wait = (next - t) / _speed;
    final waitMicros = (wait * 1e6).ceil() + 1;
    // Only close boundaries: further ones are reached by a later position
    // update, which re-anchors to the player first.
    if (waitMicros > maxProjection.inMicroseconds) return;
    final anchoredAt = _anchor;
    _boundary = Timer(Duration(microseconds: waitMicros), () {
      _boundary = null;
      if (_running) _evaluate(anchoredAt + _projected, reason: 'boundary');
    });
  }

  void _logChange(int index, double t, double? previous, String reason) {
    if (!kDebugMode || index < 0) return;
    // Media time only, never cue text. `late` is timing error, and is only
    // reported when playback ran across the cue's start since the last
    // check. Otherwise playback arrived inside a cue that had already
    // started (a seek, or a subtitle file that finished loading mid-cue);
    // `joined` is how far into the cue that was, and is not a delay.
    final start = _cues[index].start;
    final offset = ((t - start) * 1000).round();
    final crossed =
        previous != null && previous < start && t - previous < _continuity;
    PlaybackLog.log(
      'SubtitleSync',
      'cue=$index start=${start.toStringAsFixed(3)}s '
          'shownAt=${t.toStringAsFixed(3)}s '
          '${crossed ? 'late' : 'joined'}=${offset}ms '
          'by=$reason delay=${_delay.toStringAsFixed(2)}s '
          'speed=$_speed',
    );
  }

  @override
  void dispose() {
    _boundary?.cancel();
    super.dispose();
  }
}

/// Index of the cue on screen at media time [t] (seconds), or -1.
///
/// [cues] are sorted by start. Among overlapping cues the earliest-starting
/// one wins, as before. Binary search, so a long film stays cheap.
@visibleForTesting
int cueIndexAt(List<SubtitleCue> cues, double t) {
  // First cue that starts after t.
  var low = 0, high = cues.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (cues[mid].start <= t) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  // Cues starting at or before t, latest first; a few back covers overlaps.
  var found = -1;
  for (var i = low - 1; i >= 0 && i >= low - 8; i--) {
    if (t <= cues[i].end) found = i;
  }
  return found;
}

/// The next media time after [t] at which the visible cue changes.
@visibleForTesting
double? nextBoundaryAfter(List<SubtitleCue> cues, double t) {
  double? next;
  void consider(double time) {
    if (time > t && (next == null || time < next!)) next = time;
  }

  var low = 0, high = cues.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (cues[mid].start <= t) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  if (low < cues.length) consider(cues[low].start);
  for (var i = low - 1; i >= 0 && i >= low - 8; i--) {
    consider(cues[i].end);
  }
  return next;
}
