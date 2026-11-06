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
      'failures=http:1,timeout:1 open=- playToFrame=- rebufferRatio=100.0% '
      'recovered=0/0 (0ms) close=0ms',
    );
  });

  test('the rebuffer ratio compares waiting with moving pictures', () {
    var now = DateTime(2026, 1, 1, 20);
    void wait(int ms) => now = now.add(Duration(milliseconds: ms));
    final metrics = PlaybackMetrics(clock: () => now);

    expect(metrics.rebufferRatio, isNull);
    metrics
      ..firstFrame('mediaKit')
      ..playing(true);
    wait(9000);
    metrics
      ..playing(false)
      ..buffering(true);
    wait(1000);
    metrics
      ..buffering(false)
      ..playing(true);
    expect(metrics.rebufferRatio, closeTo(.1, .001));

    // Time without a player counts as neither.
    metrics.interrupted();
    wait(60000);
    expect(metrics.rebufferRatio, closeTo(.1, .001));
  });

  test('time to first frame starts at the first play request, and open and '
      'close times are kept', () {
    var now = DateTime(2026, 1, 1, 20);
    void wait(int ms) => now = now.add(Duration(milliseconds: ms));
    final metrics = PlaybackMetrics(clock: () => now);

    wait(700);
    metrics
      ..opened(const Duration(milliseconds: 700))
      ..playRequested();
    wait(240);
    metrics
      ..firstFrame('media3')
      // Later sources keep the first times; close keeps the slowest.
      ..opened(const Duration(seconds: 9))
      ..closed(const Duration(milliseconds: 80))
      ..closed(const Duration(milliseconds: 30));

    expect(metrics.summary(), contains('firstFrame=940ms'));
    expect(metrics.summary(), contains('open=700ms playToFrame=240ms'));
    expect(metrics.summary(), contains('close=80ms'));
  });

  test('a recovery counts once per incident and succeeds on the next first '
      'frame', () {
    var now = DateTime(2026, 1, 1, 20);
    void wait(int ms) => now = now.add(Duration(milliseconds: ms));
    final metrics = PlaybackMetrics(clock: () => now)..firstFrame('mediaKit');

    metrics.recovering();
    wait(1000);
    metrics.recovering();
    wait(1400);
    metrics.firstFrame('mediaKit');
    expect(metrics.summary(), contains('recovered=1/1 (2400ms)'));

    metrics
      ..recovering()
      ..gaveUp();
    expect(metrics.summary(), contains('recovered=1/2'));
  });

  test('a session that never plays says so', () {
    final metrics = PlaybackMetrics();
    metrics.failure(PlaybackFailureKind.network);
    expect(
      metrics.summary(),
      'engine=- firstFrame=never rebuffers=0 (0ms) stalls=0 '
      'failures=network:1 open=- playToFrame=- rebufferRatio=- '
      'recovered=0/0 (0ms) close=0ms',
    );
  });
}
