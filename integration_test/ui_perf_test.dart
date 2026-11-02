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
// No account or network is needed: Home gets a canned catalog (a fake TMDB
// client), and its artwork, real poster- and backdrop-sized PNGs drawn
// here, is put in the app's own artwork disk cache under the TMDB URLs the
// catalog names, so images decode from disk as they do after a first run.
// `--dart-define=PERF_ARTWORK=none` measures with no artwork at all.
//
// Frame counts are not the app's own: the test binding draws frames of its
// own while live. Idle cost is measured from the VM service timeline instead.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/artwork_image.dart';
import 'package:onfeed/src/widgets/liquid_glass.dart';
import 'package:onfeed/src/widgets/media_card.dart';
import 'package:onfeed/src/widgets/soft_glass_dock.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_smoke_test.dart' show pumpUntil;

const _artwork = String.fromEnvironment('PERF_ARTWORK');
const _posters = 24;
const _backdrops = 8;

/// A [width]×[height] PNG with a gradient and shapes, so it encodes and
/// decodes like real artwork rather than a flat colour.
Future<Uint8List> _picture(int width, int height, int seed) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final hue = (seed * 37 % 360).toDouble();
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          HSVColor.fromAHSV(1, hue, .7, .8).toColor(),
          HSVColor.fromAHSV(1, (hue + 120) % 360, .6, .3).toColor(),
        ],
      ).createShader(rect),
  );
  for (var i = 0; i < 12; i++) {
    canvas.drawCircle(
      Offset(
        (i * 53 + seed * 17) % width.toDouble(),
        (i * 97) % height.toDouble(),
      ),
      20.0 + (i * 7 % 60),
      Paint()..color = Colors.white.withValues(alpha: .08 + i % 3 * .05),
    );
  }
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Puts drawn artwork in the artwork disk cache under the URLs the canned
/// catalog uses.
Future<void> _seedArtwork() async {
  final cache = ArtworkCache.manager;
  for (var i = 0; i < _posters; i++) {
    await cache.putFile(
      'https://image.tmdb.org/t/p/w500/perf_poster_$i.png',
      await _picture(500, 750, i),
      fileExtension: 'png',
    );
  }
  for (var i = 0; i < _backdrops; i++) {
    await cache.putFile(
      'https://image.tmdb.org/t/p/w1280/perf_backdrop_$i.png',
      await _picture(1280, 720, i + 100),
      fileExtension: 'png',
    );
  }
}

/// TMDB-shaped pages for every catalog request: 20 titles each, with
/// artwork paths cycling through the seeded files.
http.Response _catalogPage(Uri url) {
  final page = int.tryParse(url.queryParameters['page'] ?? '1') ?? 1;
  final series = url.path.contains('/tv');
  final base = (url.path.hashCode.abs() % 1000) * 1000 + page * 40;
  String date(int days) => MediaFreshnessRules.tmdbDate(
    DateTime.now().toUtc().subtract(Duration(days: days)),
  );
  Map<String, Object?> title(int i) => {
    'id': base + i,
    if (series) 'name': 'Series ${base + i}' else 'title': 'Movie ${base + i}',
    if (series)
      'first_air_date': date(20 + i)
    else
      'release_date': date(20 + i),
    if (url.path.contains('/search/')) 'media_type': 'movie',
    'vote_average': 7.8,
    'vote_count': 500,
    'popularity': 40,
    'genre_ids': [series ? 18 : 28],
    'overview': 'A canned overview for frame-time measurement. ' * 3,
    if (_artwork != 'none') ...{
      'poster_path': '/perf_poster_${(base + i) % _posters}.png',
      'backdrop_path': '/perf_backdrop_${(base + i) % _backdrops}.png',
    },
  };
  return http.Response(
    jsonEncode({
      'page': page,
      'total_pages': 50,
      'results': [for (var i = 0; i < 20; i++) title(i)],
    }),
    200,
  );
}

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
    if (_artwork != 'none') await _seedArtwork();

    // Home with a canned catalog: no account or network needed.
    final cacheRoot = await Directory.systemTemp.createTemp('perf-tmdb-');
    final tmdb = TmdbService(
      // DNS and HTTP are both faked: nothing leaves the device. (A reserved
      // name such as .test is refused by the destination policy.)
      baseUrl: 'https://api.themoviedb.org/3',
      accessToken: ({bool forceRefresh = false}) async => 'perf-token',
      testClient: MockClient((request) async => _catalogPage(request.url)),
      network: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
      cache: TmdbResponseCache(directory: cacheRoot),
    );
    final accent = AccentSettingsController();
    await accent.load();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: GlassTheme.dark,
        home: HomeScreen(
          accentSettings: accent,
          tmdbService: tmdb,
          updateChecker: () async =>
              const UpdateCheckResult(UpdateCheckStatus.upToDate),
        ),
      ),
    );
    final dock = find.byType(SoftGlassDock);
    await pumpUntil(tester, dock);
    if (_glass == 'low') LiquidGlass.qualityCeiling = LiquidGlassQuality.low;
    // Let the catalog and posters load.
    await pumpUntil(tester, find.byType(MediaCard));
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
