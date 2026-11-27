// Measures where playback start-up time goes on the real engines (PB-06,
// PB-07 in docs/playback-audit/PLAYBACK_AUDIT_REPORT.md): opening, the
// steps before play, the resume seek, and play to first frame, for a fresh
// start and a resumed one. A measurement, not a pass/fail gate: it prints
// one line per open and a table of medians.
//
//   flutter test integration_test/startup_latency_test.dart -d windows
//   flutter test integration_test/startup_latency_test.dart -d <android>
//
// Windows measures libmpv; Android measures Media3 and libmpv. The steps run
// in the order CustomVideoPlayer._initialize runs them. Public test media
// (Mux HLS, Akamai DASH, test-videos.co.uk Big Buck Bunny, CC BY 3.0), so
// the numbers include the host's network: compare fresh with resumed runs
// of the same clip, not absolute values. Positions arrive about every
// 100 ms, so play-to-frame times are that coarse.
//
// --dart-define=STARTUP_CLIPS=hls,mp4 measures only those clips (labels:
// hls, dash, mp4, mp4+headers, mkv). On Windows libmpv opens one DASH
// stream per process (PB-24, WindowsDashGuard): later DASH opens are
// refused and show as errors, so measure dash one process per open.
// --dart-define=STARTUP_RESUME_FIRST=true starts each clip with a resumed
// open.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:video_player/video_player.dart';

/// One clip, and where a resumed start begins.
typedef _Clip = ({
  String label,
  String url,
  StreamType type,
  Duration resumeAt,
  Map<String, String> headers,
});

const List<_Clip> _clips = [
  (
    label: 'hls',
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    type: StreamType.hls,
    resumeAt: Duration(minutes: 5),
    headers: {},
  ),
  (
    label: 'dash',
    url: 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd',
    type: StreamType.dash,
    resumeAt: Duration(minutes: 5),
    headers: {},
  ),
  (
    label: 'mp4',
    url:
        'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/'
        'Big_Buck_Bunny_360_10s_1MB.mp4',
    type: StreamType.progressive,
    resumeAt: Duration(seconds: 6),
    headers: {},
  ),
  (
    label: 'mp4+headers',
    url:
        'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/'
        'Big_Buck_Bunny_360_10s_1MB.mp4',
    type: StreamType.progressive,
    resumeAt: Duration(seconds: 6),
    headers: {'Referer': 'https://provider.example/'},
  ),
  (
    label: 'mkv',
    url:
        'https://test-videos.co.uk/vids/bigbuckbunny/mkv/360/'
        'Big_Buck_Bunny_360_10s_1MB.mkv',
    type: StreamType.progressive,
    resumeAt: Duration(seconds: 6),
    headers: {},
  ),
];

/// Clips to measure, by label (comma-separated): one clip per run keeps a
/// crash in one from losing the others. All clips when empty.
const _only = String.fromEnvironment('STARTUP_CLIPS');

List<_Clip> get _selected {
  final wanted = _only.split(',').where((label) => label.isNotEmpty).toSet();
  return wanted.isEmpty
      ? _clips
      : _clips.where((clip) => wanted.contains(clip.label)).toList();
}

/// Starts each clip with a resumed open instead of a fresh one.
const _resumeFirst = bool.fromEnvironment('STARTUP_RESUME_FIRST');

/// Opens per clip, engine and mode. Alternating fresh and resumed opens
/// spreads any host or cache warm-up over both.
const _repeats = 3;

/// One open, in milliseconds per step; null for a step that did not run.
class _Run {
  _Run(this.engine, this.clip, this.resumed);

  final String engine;
  final String clip;
  final bool resumed;
  int? init, tracks, volume, seek, play, frame, total;
  int startupRebuffers = 0;
  String? error;

  /// Engine ready to first frame: what the pre-play steps, the seek and
  /// the start buffering add after `initialize()`.
  int? get afterInit => total == null || init == null ? null : total! - init!;

  String get line =>
      '[Startup] engine=$engine clip=$clip '
      'mode=${resumed ? 'resume' : 'fresh'} '
      '${error != null ? 'error="$error"' : 'init=${init}ms tracks=${tracks}ms '
                'volume=${volume}ms seek=${seek ?? '-'}ms play=${play}ms '
                'playToFrame=${frame}ms total=${total}ms '
                'afterInit=${afterInit}ms rebuffers=$startupRebuffers'}';
}

int _ms(Stopwatch watch) {
  final value = watch.elapsedMilliseconds;
  watch.reset();
  return value;
}

Future<void> _waitFor(
  VideoPlayerController controller,
  bool Function(VideoPlayerValue value) condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition(controller.value)) {
    final error = controller.value.errorDescription;
    if (error != null) throw StateError('player error');
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<_Run> _measure(PlayerEngine engine, _Clip clip, bool resumed) async {
  final run = _Run(engine.id.name, clip.label, resumed);
  final source = PlayableSource(
    source: StreamSource(name: 'test', url: clip.url, headers: clip.headers),
    uri: Uri.parse(clip.url),
    headers: clip.headers,
    streamType: clip.type,
  );
  await PlayerEngineGate.activate(engine);
  final controller = engine.createController(source);
  final total = Stopwatch()..start();
  final step = Stopwatch()..start();
  try {
    await controller.initialize().timeout(const Duration(seconds: 45));
    run.init = _ms(step);

    // As _initialize: both track lists at once, at most 2 s.
    await Future.wait<void>([
      if (controller.isVideoTrackSupportAvailable())
        controller.getVideoTracks(),
      if (controller.isAudioTrackSupportAvailable())
        controller.getAudioTracks(),
    ]).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
    run.tracks = _ms(step);

    // The session's volume, sent before play when it is not 1 (silent
    // here, so the measurement makes no sound).
    await controller.setVolume(0).timeout(const Duration(seconds: 2));
    run.volume = _ms(step);

    if (resumed) {
      try {
        await controller
            .seekTo(clip.resumeAt)
            .timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The player continues after 2 s too.
      }
      run.seek = _ms(step);
    }

    final start = controller.value.position;
    await controller.play().timeout(const Duration(seconds: 10));
    run.play = _ms(step);

    // First frame as the player counts it: the position moves after play.
    await _waitFor(
      controller,
      (value) => value.isPlaying && value.position > start,
    );
    run.frame = _ms(step);
    run.total = total.elapsedMilliseconds;

    // Rebuffering in the first 5 s of playback.
    var buffering = false;
    final until = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(until)) {
      final now = controller.value.isBuffering;
      if (now && !buffering) run.startupRebuffers++;
      buffering = now;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  } catch (error) {
    run.error = error.runtimeType.toString();
  } finally {
    await controller.dispose();
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
    'start-up time: fresh against resumed, per engine and clip',
    (tester) async {
      await tester.pumpWidget(const SizedBox.expand());
      await tester.runAsync(() async {
        final engines = <PlayerEngine>[
          if (defaultTargetPlatform == TargetPlatform.android)
            const Media3PlayerEngine(),
          const MpvPlayerEngine(),
        ];
        final runs = <_Run>[];
        for (final engine in engines) {
          for (final clip in _selected) {
            for (var i = 0; i < _repeats; i++) {
              // Alternate which mode goes first.
              for (final resumed
                  in i.isEven != _resumeFirst ? [false, true] : [true, false]) {
                final run = await _measure(engine, clip, resumed);
                runs.add(run);
                debugPrint(run.line);
              }
            }
          }
        }

        debugPrint(
          '[Startup] median ms | engine | clip | mode | init | tracks | volume '
          '| seek | play | playToFrame | afterInit | total | ok',
        );
        for (final engine in engines) {
          for (final clip in _selected) {
            for (final resumed in [false, true]) {
              final group = runs.where(
                (run) =>
                    run.engine == engine.id.name &&
                    run.clip == clip.label &&
                    run.resumed == resumed,
              );
              final ok = group.where((run) => run.error == null);
              debugPrint(
                '[Startup] | ${engine.id.name} | ${clip.label} | '
                '${resumed ? 'resume' : 'fresh'} | '
                '${_median(ok.map((r) => r.init))} | '
                '${_median(ok.map((r) => r.tracks))} | '
                '${_median(ok.map((r) => r.volume))} | '
                '${_median(ok.map((r) => r.seek)) ?? '-'} | '
                '${_median(ok.map((r) => r.play))} | '
                '${_median(ok.map((r) => r.frame))} | '
                '${_median(ok.map((r) => r.afterInit))} | '
                '${_median(ok.map((r) => r.total))} | '
                '${ok.length}/${group.length}',
              );
            }
          }
        }
        debugPrint('[Startup] host=${Platform.operatingSystem}');
        // Something must have played for the numbers to mean anything.
        expect(runs.where((run) => run.error == null), isNotEmpty);
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
