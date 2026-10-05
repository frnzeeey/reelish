import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/resume_summary.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/widgets/media_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _minute = 60000;

MediaItem _movie({int resume = 0, int duration = 0}) => MediaItem(
  id: '27205',
  type: 'movie',
  name: 'Inception',
  year: '2010',
  rating: '8.4',
  resumeMs: resume,
  durationMs: duration,
);

const _series = MediaItem(
  id: '1396',
  type: 'series',
  name: 'Breaking Bad',
  resumeMs: 12 * _minute,
);

SeriesProgress _lastWatched(int position, int duration) => SeriesProgress(
  last: (season: 2, episode: 1),
  episodes: {
    '1:7': const EpisodeProgress(
      positionMs: 47 * _minute,
      durationMs: 48 * _minute,
    ),
    '2:1': EpisodeProgress(positionMs: position, durationMs: duration),
  },
);

void main() {
  group('movie progress', () {
    test('real share and time left, not a fixed 36%', () {
      final summary = ResumeSummary.of(
        _movie(resume: 30 * _minute, duration: 148 * _minute),
      );
      expect(summary.fraction, closeTo(30 / 148, 1e-9));
      expect(summary.label, '1h 58m left');
    });

    test('nearly finished reads as watched', () {
      final summary = ResumeSummary.of(
        _movie(resume: 140 * _minute, duration: 148 * _minute),
      );
      expect(summary.fraction, 1);
      expect(summary.label, 'Watched');
    });

    test('saved before lengths were recorded: position only, no bar', () {
      final summary = ResumeSummary.of(_movie(resume: 34 * _minute));
      expect(summary.fraction, 0);
      expect(summary.label, 'Paused at 34 min');
    });

    test('a few seconds in shows nothing', () {
      final summary = ResumeSummary.of(
        _movie(resume: 20000, duration: 148 * _minute),
      );
      expect(summary.fraction, 0);
      expect(summary.label, isEmpty);
    });
  });

  group('series progress follows the last episode', () {
    test('its own share and time left', () {
      final summary = ResumeSummary.of(
        _series,
        series: _lastWatched(21 * _minute, 48 * _minute),
      );
      expect(summary.fraction, closeTo(21 / 48, 1e-9));
      expect(summary.label, 'S2 E1 · 27 min left');
    });

    test('a finished episode reads as watched', () {
      final summary = ResumeSummary.of(
        _series,
        series: _lastWatched(47 * _minute, 48 * _minute),
      );
      expect(summary.label, 'S2 E1 · Watched');
      expect(summary.fraction, 1);
    });

    test('just started: the episode, no bar', () {
      final summary = ResumeSummary.of(
        _series,
        series: _lastWatched(10000, 48 * _minute),
      );
      expect(summary.fraction, 0);
      expect(summary.label, 'S2 E1');
    });

    test('saved before episodes were tracked: nothing is guessed', () {
      expect(
        ResumeSummary.of(_series, series: SeriesProgress.empty).label,
        isEmpty,
      );
      expect(ResumeSummary.of(_series).fraction, 0);
    });
  });

  group('history keeps the length', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('saved and read back', () async {
      final storage = StorageService();
      await storage.saveProgress(
        _movie(),
        30 * _minute,
        durationMs: 148 * _minute,
      );
      final saved = (await storage.history()).single;
      expect(saved.resumeMs, 30 * _minute);
      expect(saved.durationMs, 148 * _minute);
    });

    test('entries saved by older versions load with no length', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.history': [
          '{"id":"27205","type":"movie","name":"Inception","resumeMs":5}',
        ],
      });
      final saved = (await StorageService().history()).single;
      expect(saved.resumeMs, 5);
      expect(saved.durationMs, 0);
    });
  });

  testWidgets('a card shows the progress label instead of year and rating', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 264,
              child: MediaCard(
                item: _movie(),
                onTap: () {},
                progress: .4,
                progressLabel: '1h 58m left',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('1h 58m left'), findsOneWidget);
    expect(find.text('2010'), findsNothing);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, .4);
  });
}
