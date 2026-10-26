import 'dart:async';

/// Notices playback that is stuck: playing, buffering, and not moving for
/// [limit]. Engines report most network failures themselves; this catches
/// the rest (a segment that never arrives, a host that stops answering
/// mid-file), which would otherwise leave the viewer on a spinner.
///
/// Feed it every player update with [update]; [onStall] runs once per stall,
/// after which a new stall needs playback to move (or stop stalling) first.
class StallWatchdog {
  StallWatchdog({required this.limit, required this.onStall});

  final Duration limit;
  final void Function() onStall;

  Timer? _timer;
  Duration? _stalledAt;
  bool _reported = false;

  /// [stalled]: playing (not paused or scrubbing) but buffering.
  void update({required bool stalled, required Duration position}) {
    if (!stalled) {
      _reset();
      return;
    }
    if (_stalledAt != null && _stalledAt != position) {
      // It moved: a new wait starts from here.
      _reset();
    }
    if (_reported || _timer != null) return;
    _stalledAt = position;
    _timer = Timer(limit, () {
      _timer = null;
      _reported = true;
      onStall();
    });
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _stalledAt = null;
    _reported = false;
  }

  void dispose() => _reset();
}
