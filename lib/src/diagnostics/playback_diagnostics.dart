// Which playback failures are worth a crash report. Most are not: a dead
// link or a dropped connection says nothing about Reelish's own code.
import '../services/playback_coordinator.dart';
import 'crash_reporter.dart';
import 'error_scrubber.dart';

/// Whose fault a playback failure most likely is.
enum PlaybackFailureSide { app, provider, network, none }

/// Stands in for the real error in a report. Engine messages often quote
/// the stream address, so a report carries the failure kind and engine only.
class PlaybackEngineFailure implements Exception {
  const PlaybackEngineFailure();
}

class PlaybackDiagnostics {
  const PlaybackDiagnostics._();

  static PlaybackFailureSide sideOf(PlaybackFailureKind kind) => switch (kind) {
    PlaybackFailureKind.engine ||
    PlaybackFailureKind.rendering ||
    PlaybackFailureKind.decoder ||
    PlaybackFailureKind.unknown => PlaybackFailureSide.app,
    PlaybackFailureKind.preparation ||
    PlaybackFailureKind.http ||
    PlaybackFailureKind.manifest ||
    PlaybackFailureKind.format ||
    PlaybackFailureKind.source => PlaybackFailureSide.provider,
    PlaybackFailureKind.network ||
    PlaybackFailureKind.timeout => PlaybackFailureSide.network,
    PlaybackFailureKind.cancelled => PlaybackFailureSide.none,
  };

  /// Records a source that failed. App-side failures become one non-fatal
  /// report per kind and engine; the rest are notes on later reports.
  static void failed(
    PlaybackFailureKind kind, {
    required String engine,
    required bool wasPlaying,
    CrashReporter? reporter,
  }) {
    final side = sideOf(kind);
    if (side == PlaybackFailureSide.none) return;
    final target = reporter ?? CrashReporter.instance;
    final moment = wasPlaying ? 'while_playing' : 'while_opening';
    if (side != PlaybackFailureSide.app) {
      target.note('playback ${side.name} ${kind.name} $engine $moment');
      return;
    }
    target.recordError(
      const PlaybackEngineFailure(),
      StackTrace.current,
      category: ErrorCategory.playback,
      reason: 'playback ${kind.name} on $engine $moment',
    );
  }
}
