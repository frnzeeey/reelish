import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/widgets/player/stall_watchdog.dart';

// Widget tests run on a fake clock: tester.pump(duration) moves time.
void main() {
  const limit = Duration(seconds: 25);
  const at = Duration(minutes: 12);

  testWidgets('playback stuck buffering at one position is reported once', (
    tester,
  ) async {
    var stalls = 0;
    final watchdog = StallWatchdog(limit: limit, onStall: () => stalls++);
    watchdog.update(stalled: true, position: at);
    await tester.pump(const Duration(seconds: 24));
    expect(stalls, 0);
    // Repeated updates while stuck do not restart the wait.
    watchdog.update(stalled: true, position: at);
    await tester.pump(const Duration(seconds: 1));
    expect(stalls, 1);
    watchdog.update(stalled: true, position: at);
    await tester.pump(limit * 3);
    expect(stalls, 1);
    watchdog.dispose();
  });

  testWidgets('buffering that ends, or keeps moving, is not a stall', (
    tester,
  ) async {
    var stalls = 0;
    final watchdog = StallWatchdog(limit: limit, onStall: () => stalls++);
    watchdog.update(stalled: true, position: at);
    await tester.pump(const Duration(seconds: 20));
    watchdog.update(stalled: false, position: at);
    await tester.pump(limit * 2);
    expect(stalls, 0);

    // Slow but moving: each move restarts the wait.
    for (var i = 1; i <= 10; i++) {
      watchdog.update(stalled: true, position: at + Duration(seconds: i));
      await tester.pump(const Duration(seconds: 20));
    }
    expect(stalls, 0);
    watchdog.dispose();
  });

  testWidgets('after a report, the next stall needs playback to recover '
      'first', (tester) async {
    var stalls = 0;
    final watchdog = StallWatchdog(limit: limit, onStall: () => stalls++);
    watchdog.update(stalled: true, position: at);
    await tester.pump(limit);
    expect(stalls, 1);
    watchdog.update(stalled: false, position: at);
    watchdog.update(stalled: true, position: at);
    await tester.pump(limit);
    expect(stalls, 2);
    watchdog.dispose();
  });

  testWidgets('dispose cancels a pending report', (tester) async {
    var stalls = 0;
    final watchdog = StallWatchdog(limit: limit, onStall: () => stalls++);
    watchdog.update(stalled: true, position: at);
    watchdog.dispose();
    await tester.pump(limit * 2);
    expect(stalls, 0);
  });
}
