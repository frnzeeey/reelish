// Measures whether provider work still running while playback starts slows
// the start (PB-23 in docs/playback-audit/DEEP_AUDIT_2026-11-21.md). A
// measurement, not a pass/fail gate: it prints one line per open and a
// table of medians.
//
//   flutter test integration_test/discovery_competition_test.dart -d windows
//
// The video comes from a local server through an emulated slow link: one
// bandwidth cap shared by every connection, as on a home line. Competing
// load stands in for provider traffic (scraping pages, API answers) on the
// same link, or for provider CPU (QuickJS runtimes busy, at most two as in
// the app). Stand-ins, not real providers: the result is how sensitive
// start-up is to a given load, not how much load real providers make.
//
// --dart-define=COMPETITION_RATES=187500,1000000 sets the link speeds in
// bytes per second (default: 1.5 and 8 Mbit/s).

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/services/provider_runner.dart';

/// Big Buck Bunny (CC BY 3.0), 10 s, about 0.8 Mbit/s: a fraction of the
/// slow link, as a modest stream is.
const _clipUrl =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/'
    'Big_Buck_Bunny_360_10s_1MB.mp4';

const _ratesDefine = String.fromEnvironment('COMPETITION_RATES');
List<int> get _rates => _ratesDefine.isEmpty
    ? const [187500, 1000000]
    : _ratesDefine.split(',').map(int.parse).toList();

const _repeats = 3;

/// The competing load while the player starts.
enum _Load {
  /// Discovery cancelled or finished: the player has the link to itself.
  none,

  /// Two providers scraping: 150 KB pages with 300 ms between them.
  light,

  /// Four workers downloading without pause: the worst a lookup can do.
  heavy,

  /// Two QuickJS runtimes busy (no network): provider CPU.
  cpu,
}

/// One link shared by every connection: each chunk waits for its turn at
/// [bytesPerSecond], so connections share the speed as on a real line.
class _Link {
  _Link(this.bytesPerSecond);

  final int bytesPerSecond;
  DateTime _free = DateTime.now();

  Future<void> send(HttpResponse response, List<int> chunk) async {
    final now = DateTime.now();
    final start = _free.isAfter(now) ? _free : now;
    _free = start.add(
      Duration(microseconds: chunk.length * 1000000 ~/ bytesPerSecond),
    );
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    response.add(chunk);
    await response.flush();
  }
}

/// Serves the clip (with byte ranges, as libmpv asks) and filler pages, all
/// through one [_Link].
class _Server {
  _Server._(this._server, this._clip);

  final HttpServer _server;
  final List<int> _clip;
  _Link? link;
  int mediaBytes = 0;
  int loadBytes = 0;

  static Future<_Server> start(List<int> clip) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _Server._(server, clip);
    server.listen(instance._handle);
    return instance;
  }

  String get mediaUrl => 'http://127.0.0.1:${_server.port}/media.mp4';
  Uri page(int kb) => Uri.parse('http://127.0.0.1:${_server.port}/page?kb=$kb');

  static const _chunk = 16 * 1024;

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path == '/media.mp4') {
        var start = 0, end = _clip.length - 1;
        final range = RegExp(
          r'bytes=(\d*)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        response.headers
          ..contentType = ContentType('video', 'mp4')
          ..set('accept-ranges', 'bytes');
        if (range != null) {
          if (range[1]!.isNotEmpty) start = int.parse(range[1]!);
          if (range[2]!.isNotEmpty) end = int.parse(range[2]!);
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            'content-range',
            'bytes $start-$end/${_clip.length}',
          );
        }
        response.contentLength = end - start + 1;
        for (var at = start; at <= end; at += _chunk) {
          final piece = _clip.sublist(at, min(at + _chunk, end + 1));
          await link!.send(response, piece);
          mediaBytes += piece.length;
        }
      } else {
        final kb = int.parse(request.uri.queryParameters['kb'] ?? '150');
        response.contentLength = kb * 1024;
        final piece = List<int>.filled(_chunk, 120);
        for (var left = kb * 1024; left > 0; left -= _chunk) {
          final part = left >= _chunk ? piece : piece.sublist(0, left);
          await link!.send(response, part);
          loadBytes += part.length;
        }
      }
    } catch (_) {
      // The player closed its connection early; nothing to do.
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// Runs [load] until [stop] completes.
Future<void> _runLoad(_Load load, _Server server, Future<void> stop) async {
  var stopped = false;
  unawaited(stop.then((_) => stopped = true));
  final client = HttpClient();
  Future<void> fetcher(int kb, Duration think) async {
    while (!stopped) {
      try {
        final request = await client.getUrl(server.page(kb));
        final response = await request.close();
        await response.drain<void>();
      } catch (_) {}
      if (think > Duration.zero) await Future<void>.delayed(think);
    }
  }

  Future<void> busyRuntime() async {
    while (!stopped) {
      try {
        await ProviderRunner.run(
          const ProviderRunRequest(
            pluginId: 'busy',
            code:
                'module.exports.getStreams = async () => {'
                ' const end = Date.now() + 1500; let x = 0;'
                ' while (Date.now() < end) { x = (x * 31 + 7) % 1000003; }'
                ' return []; };',
            codeUrl: 'https://repo.example/busy.js',
            tmdbId: '1',
            mediaType: 'movie',
          ),
        );
      } catch (_) {}
    }
  }

  try {
    await Future.wait(switch (load) {
      _Load.none => <Future<void>>[],
      _Load.light => [
        for (var i = 0; i < 2; i++)
          fetcher(150, const Duration(milliseconds: 300)),
      ],
      _Load.heavy => [for (var i = 0; i < 4; i++) fetcher(1024, Duration.zero)],
      _Load.cpu => [for (var i = 0; i < 2; i++) busyRuntime()],
    });
  } finally {
    client.close(force: true);
  }
}

class _Run {
  _Run(this.rate, this.load);

  final int rate;
  final _Load load;
  int? init, frame, total;
  int stalls = 0;
  int stalledMs = 0;
  int mediaKb = 0, loadKb = 0;
  String? error;

  String get line =>
      '[Competition] link=${rate * 8 ~/ 1000}kbit load=${load.name} '
      '${error != null ? 'error=$error' : 'init=${init}ms '
                'playToFrame=${frame}ms total=${total}ms '
                'stalls=$stalls (${stalledMs}ms) '
                'mediaKB=$mediaKb loadKB=$loadKb'}';
}

Future<_Run> _measure(_Server server, int rate, _Load load) async {
  final run = _Run(rate, load);
  server
    ..link = _Link(rate)
    ..mediaBytes = 0
    ..loadBytes = 0;
  final stop = Completer<void>();
  final loading = _runLoad(load, server, stop.future);
  // The lookup is already running when the player opens.
  await Future<void>.delayed(const Duration(seconds: 1));

  const engine = MpvPlayerEngine();
  await PlayerEngineGate.activate(engine);
  final source = PlayableSource(
    source: StreamSource(name: 'clip', url: server.mediaUrl),
    uri: Uri.parse(server.mediaUrl),
    headers: const {},
    streamType: StreamType.progressive,
  );
  final controller = engine.createController(source);
  final clock = Stopwatch()..start();
  try {
    await controller.initialize().timeout(const Duration(seconds: 60));
    run.init = clock.elapsedMilliseconds;
    await controller.setVolume(0);
    final start = controller.value.position;
    await controller.play();
    final played = Stopwatch()..start();
    while (!(controller.value.isPlaying && controller.value.position > start)) {
      if (controller.value.errorDescription != null) throw StateError('error');
      if (played.elapsed > const Duration(seconds: 60)) {
        throw TimeoutException('first frame');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    run.frame = played.elapsedMilliseconds;
    run.total = clock.elapsedMilliseconds;

    // Stalls over the next 6 s of a 10 s clip.
    var since = DateTime.now();
    DateTime? stalledAt;
    final until = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(until) && !controller.value.isCompleted) {
      final waiting = controller.value.isBuffering;
      if (waiting && stalledAt == null) {
        stalledAt = DateTime.now();
        run.stalls++;
      } else if (!waiting && stalledAt != null) {
        run.stalledMs += DateTime.now().difference(stalledAt).inMilliseconds;
        stalledAt = null;
      }
      since = DateTime.now();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (stalledAt != null) {
      run.stalledMs += since.difference(stalledAt).inMilliseconds;
    }
  } catch (error) {
    run.error = error.runtimeType.toString();
  } finally {
    run
      ..mediaKb = server.mediaBytes ~/ 1024
      ..loadKb = server.loadBytes ~/ 1024;
    stop.complete();
    await controller.dispose();
    await loading;
  }
  return run;
}

int? _median(Iterable<int?> values) {
  final known = values.whereType<int>().toList()..sort();
  if (known.isEmpty) return null;
  final mid = known.length ~/ 2;
  return known.length.isOdd
      ? known[mid]
      : ((known[mid - 1] + known[mid]) / 2).round();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'start-up with and without provider work competing',
    (tester) async {
      await tester.pumpWidget(const SizedBox.expand());
      await tester.runAsync(() async {
        final client = HttpClient();
        final List<int> clip;
        try {
          final response = await (await client.getUrl(
            Uri.parse(_clipUrl),
          )).close();
          clip = await response.fold<List<int>>(
            <int>[],
            (all, part) => all..addAll(part),
          );
        } finally {
          client.close();
        }
        expect(clip.length, greaterThan(100000));
        final server = await _Server.start(clip);
        addTearDown(server.close);

        final runs = <_Run>[];
        for (final rate in _rates) {
          for (var i = 0; i < _repeats; i++) {
            // Rotate the order so warm-up spreads over every load.
            final loads = [..._Load.values];
            for (var r = 0; r < i; r++) {
              loads.add(loads.removeAt(0));
            }
            for (final load in loads) {
              final run = await _measure(server, rate, load);
              runs.add(run);
              debugPrint(run.line);
            }
          }
        }

        debugPrint(
          '[Competition] median | link kbit | load | init | playToFrame '
          '| total | stalls | stalled ms | ok',
        );
        for (final rate in _rates) {
          for (final load in _Load.values) {
            final group = runs.where((r) => r.rate == rate && r.load == load);
            final ok = group.where((r) => r.error == null);
            debugPrint(
              '[Competition] | ${rate * 8 ~/ 1000} | ${load.name} | '
              '${_median(ok.map((r) => r.init))} | '
              '${_median(ok.map((r) => r.frame))} | '
              '${_median(ok.map((r) => r.total))} | '
              '${_median(ok.map((r) => r.stalls))} | '
              '${_median(ok.map((r) => r.stalledMs))} | '
              '${ok.length}/${group.length}',
            );
          }
        }
        expect(runs.where((r) => r.error == null), isNotEmpty);
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
