import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/subtitle_loader.dart';
import 'package:onfeed/src/widgets/player/external_cue_clock.dart';

/// Wall time the tests control, kept in step with fake timers by [_advance].
class _FakeStopwatch implements Stopwatch {
  Duration now = Duration.zero;
  Duration _startedAt = Duration.zero;
  bool _running = false;

  @override
  void start() {
    if (_running) return;
    _running = true;
    _startedAt = now;
  }

  @override
  void reset() => _startedAt = now;

  @override
  void stop() => _running = false;

  @override
  bool get isRunning => _running;

  @override
  int get elapsedMicroseconds =>
      _running ? (now - _startedAt).inMicroseconds : 0;

  @override
  Duration get elapsed => Duration(microseconds: elapsedMicroseconds);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _advance(
  WidgetTester tester,
  _FakeStopwatch watch,
  int milliseconds,
) async {
  watch.now += Duration(milliseconds: milliseconds);
  await tester.pump(Duration(milliseconds: milliseconds));
}

Duration _s(double seconds) => Duration(microseconds: (seconds * 1e6).round());

const _cues = [
  SubtitleCue(1.0, 2.0, 'first'),
  SubtitleCue(2.5, 4.0, 'second'),
  SubtitleCue(3.0, 3.5, 'overlap'),
  SubtitleCue(10.0, 12.0, 'later'),
];

void main() {
  group('cue lookup', () {
    test('finds the cue on screen, including both edges', () {
      expect(cueIndexAt(_cues, .5), -1);
      expect(cueIndexAt(_cues, 1.0), 0);
      expect(cueIndexAt(_cues, 2.0), 0);
      expect(cueIndexAt(_cues, 2.2), -1);
      // Overlap keeps the earliest-starting cue, as before.
      expect(cueIndexAt(_cues, 3.2), 1);
      expect(cueIndexAt(_cues, 11), 3);
      expect(cueIndexAt(_cues, 20), -1);
      expect(cueIndexAt(const [], 1), -1);
    });

    test('next boundary is the nearest start or end', () {
      expect(nextBoundaryAfter(_cues, .5), 1.0);
      expect(nextBoundaryAfter(_cues, 1.5), 2.0);
      expect(nextBoundaryAfter(_cues, 2.2), 2.5);
      expect(nextBoundaryAfter(_cues, 3.2), 3.5);
      expect(nextBoundaryAfter(_cues, 13), isNull);
    });
  });

  group('ExternalCueClock', () {
    late _FakeStopwatch watch;
    late ExternalCueClock clock;

    setUp(() {
      watch = _FakeStopwatch();
      clock = ExternalCueClock(stopwatch: watch);
    });
    tearDown(() => clock.dispose());

    testWidgets('shows a cue at its start time, not at the next poll', (
      tester,
    ) async {
      clock.setCues(_cues, delay: 0);
      clock.sync(position: _s(.95), playing: true, speed: 1);
      expect(clock.value, '');
      // The next 100 ms poll would only arrive at 1.05 s.
      await _advance(tester, watch, 49);
      expect(clock.value, '');
      await _advance(tester, watch, 2);
      expect(clock.value, 'first');
    });

    testWidgets('clears a cue at its end time', (tester) async {
      clock.setCues(_cues, delay: 0);
      clock.sync(position: _s(1.95), playing: true, speed: 1);
      expect(clock.value, 'first');
      await _advance(tester, watch, 51);
      expect(clock.value, '');
    });

    testWidgets('positive delay shows the cue later by exactly that much', (
      tester,
    ) async {
      clock.setCues(_cues, delay: .5);
      clock.sync(position: _s(1.2), playing: true, speed: 1);
      expect(clock.value, '');
      clock.sync(position: _s(1.45), playing: true, speed: 1);
      await _advance(tester, watch, 49);
      expect(clock.value, '');
      await _advance(tester, watch, 2);
      expect(clock.value, 'first');
    });

    testWidgets('negative delay shows it earlier, and reset restores zero', (
      tester,
    ) async {
      clock.setCues(_cues, delay: -.5);
      clock.sync(position: _s(.6), playing: false, speed: 1);
      expect(clock.value, 'first');
      clock.setCues(_cues, delay: 0);
      expect(clock.value, '');
    });

    testWidgets('follows playback speed', (tester) async {
      clock.setCues(_cues, delay: 0);
      clock.sync(position: _s(.9), playing: true, speed: 2);
      // 100 ms of media at 2x is 50 ms of wall time.
      await _advance(tester, watch, 49);
      expect(clock.value, '');
      await _advance(tester, watch, 2);
      expect(clock.value, 'first');
    });

    testWidgets('does not move while paused or buffering', (tester) async {
      clock.setCues(_cues, delay: 0);
      clock.sync(position: _s(.95), playing: false, speed: 1);
      await _advance(tester, watch, 500);
      expect(clock.value, '');
    });

    testWidgets('never runs far ahead of the player', (tester) async {
      clock.setCues(_cues, delay: 0);
      // The next start is 500 ms away: left to the next real position.
      clock.sync(position: _s(.5), playing: true, speed: 1);
      await _advance(tester, watch, 600);
      expect(clock.value, '');
    });

    testWidgets('position jitter just after a flip does not flicker', (
      tester,
    ) async {
      clock.setCues(_cues, delay: 0);
      clock.sync(position: _s(.95), playing: true, speed: 1);
      await _advance(tester, watch, 60);
      expect(clock.value, 'first');
      // The player reports a hair behind the cue start.
      clock.sync(position: _s(.98), playing: true, speed: 1);
      expect(clock.value, 'first');
    });

    testWidgets('seeking backward or forward re-syncs immediately', (
      tester,
    ) async {
      clock.setCues(_cues, delay: 0);
      clock.sync(position: _s(1.5), playing: true, speed: 1);
      expect(clock.value, 'first');
      clock.sync(position: _s(-8.5 + 10), playing: true, speed: 1);
      expect(clock.value, 'first');
      clock.sync(position: _s(11), playing: true, speed: 1);
      expect(clock.value, 'later');
      clock.sync(position: _s(.2), playing: true, speed: 1);
      expect(clock.value, '');
    });

    testWidgets('notifies only when the visible text changes', (tester) async {
      var changes = 0;
      clock.addListener(() => changes++);
      clock.setCues(_cues, delay: 0);
      for (var position = 1.0; position < 1.9; position += .1) {
        clock.sync(position: _s(position), playing: true, speed: 1);
      }
      expect(clock.value, 'first');
      expect(changes, 1);
      // Pausing cancels the pending end-of-cue flip.
      clock.sync(position: _s(1.9), playing: false, speed: 1);
      expect(changes, 1);
    });

    testWidgets('switching tracks clears and does not carry old text', (
      tester,
    ) async {
      clock.setCues(_cues, delay: 0);
      clock.sync(position: _s(1.5), playing: true, speed: 1);
      expect(clock.value, 'first');
      clock.setCues(const [SubtitleCue(5, 6, 'other')], delay: 0);
      expect(clock.value, '');
      clock.setCues(const [], delay: 0);
      expect(clock.value, '');
      await _advance(tester, watch, 300);
    });
  });
}
