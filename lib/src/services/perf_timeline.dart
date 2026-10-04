import 'package:flutter/foundation.dart';

/// Development-only milestones measured from process start, for spotting
/// regressions in startup, browsing and playback. Release builds log nothing.
///
/// Lines look like `[Perf] HOME_CONTENT_VISIBLE +812ms` (since app start) or
/// `[Perf] PLAY_PRESSED -> PLAYER_OPEN 2410ms` for spans.
abstract final class PerfTimeline {
  static final Stopwatch _sinceStart = Stopwatch();
  static final Map<String, int> _spans = {};
  static final Set<String> _once = {};

  static void appStarted() {
    if (kDebugMode) _sinceStart.start();
  }

  /// Logs [milestone] the first time it is reached in this process.
  static void markOnce(String milestone) {
    if (!kDebugMode || !_once.add(milestone)) return;
    debugPrint('[Perf] $milestone +${_sinceStart.elapsedMilliseconds}ms');
  }

  /// Starts (or restarts) a named span.
  static void begin(String span) {
    if (kDebugMode) _spans[span] = _sinceStart.elapsedMilliseconds;
  }

  /// Logs the time since [span] began; [finish] ends the span.
  static void end(String span, String milestone, {bool finish = false}) {
    if (!kDebugMode) return;
    final start = finish ? _spans.remove(span) : _spans[span];
    if (start == null) return;
    debugPrint(
      '[Perf] $span -> $milestone ${_sinceStart.elapsedMilliseconds - start}ms',
    );
  }
}
