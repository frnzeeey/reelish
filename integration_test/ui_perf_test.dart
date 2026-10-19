// Measures frame times of the phone UI on a device or emulator:
//
//   flutter drive --profile -d <device-id> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/ui_perf_test.dart
//
// Prints one line per scenario. Build is UI-thread time, raster is GPU-thread
// time; on an emulator raster mostly reflects the host's GPU.
//
// Running `flutter drive` reinstalls the app, which clears its data (history,
// My list, installed plugins). Use a device or emulator whose data can go.
//
// Frame counts are not the app's own: the test binding draws frames of its
// own while live. Idle cost is measured from the VM service timeline instead.
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/main.dart' as app;
import 'package:onfeed/src/widgets/liquid_glass.dart';
import 'package:onfeed/src/widgets/media_card.dart';
import 'package:onfeed/src/widgets/soft_glass_dock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_smoke_test.dart' show pumpUntil;

/// Waits [seconds] of real time while the app runs.
Future<void> idle(WidgetTester tester, double seconds) =>
    Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));

/// `--dart-define=PERF_GLASS=low` measures with every backdrop blur off.
const _glass = String.fromEnvironment('PERF_GLASS');

class _Recorder {
  final _frames = <FrameTiming>[];

  void _onTimings(List<FrameTiming> timings) => _frames.addAll(timings);

  Future<String> measure(
    WidgetTester tester,
    String name,
    Future<void> Function() action,
  ) async {
    // Let earlier frames report before starting.
    await idle(tester, 1.5);
    _frames.clear();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    final watch = Stopwatch()..start();
    await action();
    // Timings arrive in batches; give the last one time to land.
    await idle(tester, 1.2);
    watch.stop();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    return _summary(name, watch.elapsedMilliseconds / 1000);
  }

  String _summary(String name, double seconds) {
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = [for (final f in _frames) ms(f.buildDuration)]..sort();
    final raster = [for (final f in _frames) ms(f.rasterDuration)]..sort();
    final total = [for (final f in _frames) ms(f.totalSpan)]..sort();
    double pct(List<double> v, double p) =>
        v.isEmpty ? 0 : v[((v.length - 1) * p).round()];
    String f1(double v) => v.toStringAsFixed(1);
    final slow = build.where((b) => b > 16.7).length;
    final slowRaster = raster.where((r) => r > 16.7).length;
    return '$name | frames ${_frames.length} in ${f1(seconds)}s'
        ' | build p50 ${f1(pct(build, .5))} p90 ${f1(pct(build, .9))}'
        ' p99 ${f1(pct(build, .99))} max ${f1(build.isEmpty ? 0 : build.last)}'
        ' | raster p50 ${f1(pct(raster, .5))} p90 ${f1(pct(raster, .9))}'
        ' max ${f1(raster.isEmpty ? 0 : raster.last)}'
        ' | total p90 ${f1(pct(total, .9))}'
        ' | build>16.7ms $slow, raster>16.7ms $slowRaster';
  }
}

Finder _scrollable(AxisDirection direction) => find.byWidgetPredicate(
  (w) => w is Scrollable && w.axisDirection == direction,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone UI frame times', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('reelish.legal.documentsAccepted.v1', true);

    app.main();
    final dock = find.byType(SoftGlassDock);
    await pumpUntil(tester, dock);
    if (_glass == 'low') LiquidGlass.qualityCeiling = LiquidGlassQuality.low;
    // Let the catalog and posters load.
    await pumpUntil(tester, find.text('Top 10 recommendations'));
    await idle(tester, 4);

    final recorder = _Recorder();
    final results = <String>[];
    final home = _scrollable(AxisDirection.down).first;

    results.add(
      await recorder.measure(tester, 'home fling down/up', () async {
        for (var i = 0; i < 3; i++) {
          await tester.fling(home, const Offset(0, -900), 3000);
          await idle(tester, .9);
        }
        for (var i = 0; i < 3; i++) {
          await tester.fling(home, const Offset(0, 900), 3000);
          await idle(tester, .9);
        }
      }),
    );

    // A poster row on Home.
    await tester.drag(home, const Offset(0, -500));
    await idle(tester, 1);
    final row = _scrollable(AxisDirection.right).hitTestable().at(1);
    results.add(
      await recorder.measure(tester, 'poster row fling', () async {
        for (var i = 0; i < 3; i++) {
          await tester.fling(row, const Offset(-700, 0), 2500);
          await idle(tester, .9);
        }
        for (var i = 0; i < 3; i++) {
          await tester.fling(row, const Offset(700, 0), 2500);
          await idle(tester, .9);
        }
      }),
    );

    results.add(
      await recorder.measure(tester, 'open details and back', () async {
        // The middle of a card is its poster; its heart, in the corner,
        // would change My list instead of opening the title.
        await tester.tap(
          find.descendant(of: row, matching: find.byType(MediaCard)).first,
        );
        await idle(tester, 2.5);
        final details = _scrollable(AxisDirection.down).hitTestable().first;
        await tester.fling(details, const Offset(0, -700), 2500);
        await idle(tester, 1);
        // System back: the page's own Back button has scrolled away.
        await tester.binding.handlePopRoute();
        await idle(tester, 1.5);
      }),
    );

    results.add(
      await recorder.measure(tester, 'library tab and scroll', () async {
        await tester.tap(
          find.descendant(of: dock, matching: find.text('Library')),
        );
        await idle(tester, 1.5);
        final library = _scrollable(AxisDirection.down).hitTestable().first;
        await tester.fling(library, const Offset(0, -900), 3000);
        await idle(tester, 1);
        await tester.fling(library, const Offset(0, 900), 3000);
        await idle(tester, 1);
      }),
    );

    for (final r in results) {
      // ignore: avoid_print
      print('PERF $r');
    }
  });
}
