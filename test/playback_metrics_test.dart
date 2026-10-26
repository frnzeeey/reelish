import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/services/playback_metrics.dart';

void main() {
  test('a session reports its first frame, rebuffers, stalls and failures, '
      'and nothing that identifies the stream', () {
    var now = DateTime(2026, 1, 1, 20);
    void wait(int ms) => now = now.add(Duration(milliseconds: ms));
    final metrics = PlaybackMetrics(clock: () => now);

    // Buffering before the first frame is start-up, not a rebuffer.
    metrics.buffering(true);
    wait(1200);
    metrics.failure(PlaybackFailureKind.http);
    wait(600);
    metrics.firstFrame('media3');
    metrics.buffering(false);

    wait(60000);
    metrics.buffering(true);
    wait(2000);
    metrics.buffering(false);
    wait(30000);
    metrics.buffering(true);
    wait(1100);
    metrics.stall();
    metrics.buffering(false);
    metrics.failure(PlaybackFailureKind.timeout);

    // A later source keeps the first time.
    wait(500);
    metrics.firstFrame('mediaKit');

    expect(
      metrics.summary(),
      'engine=mediaKit firstFrame=1800ms rebuffers=2 (3100ms) stalls=1 '
      'failures=http:1,timeout:1',
    );
  });

  test('a session that never plays says so', () {
    final metrics = PlaybackMetrics();
    metrics.failure(PlaybackFailureKind.network);
    expect(
      metrics.summary(),
      'engine=- firstFrame=never rebuffers=0 (0ms) stalls=0 '
      'failures=network:1',
    );
  });
}
