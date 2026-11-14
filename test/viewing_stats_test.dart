import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/viewing_stats.dart';
import 'package:onfeed/src/screens/profile_stats_screen.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _min = 60000;
final _now = DateTime(2026, 11, 15, 12);
int _at(int year, int month) =>
    DateTime(year, month, 10).millisecondsSinceEpoch;

MediaItem _movie(
  String id, {
  required int position,
  int duration = 100 * _min,
  int at = 0,
  List<int> genres = const [],
}) => MediaItem(
  id: id,
  type: 'movie',
  name: id,
  resumeMs: position,
  durationMs: duration,
  progressAt: at,
  genreIds: genres,
);

SeriesProgress _series(Map<String, EpisodeProgress> episodes) =>
    SeriesProgress(episodes: episodes);

EpisodeProgress _episode(
  int position, {
  int duration = 40 * _min,
  int at = 0,
}) => EpisodeProgress(positionMs: position, durationMs: duration, at: at);

class _Storage extends StorageService {
  _Storage(this.items, this.series);

  final List<MediaItem> items;
  final Map<String, SeriesProgress> series;

  @override
  Future<List<MediaItem>> history() async => items;

  @override
  Future<Map<String, SeriesProgress>> allSeriesProgress() async => series;
}

void main() {
  group('Movies', () {
    test('finished from 90% of a known length; started from 90 seconds', () {
      final stats = ViewingStats.from(
        history: [
          _movie('done', position: 92 * _min),
          _movie('half', position: 50 * _min),
          _movie('sample', position: 60000),
          // No length: started, never finished.
          _movie('live', position: 120 * _min, duration: 0),
        ],
        series: const {},
        now: _now,
      );
      expect(stats.moviesFinished, 1);
      expect(stats.moviesInProgress, 2);
      expect(stats.estimatedWatchMs, (92 + 50 + 120) * _min);
    });

    test('the same title twice counts once', () {
      final stats = ViewingStats.from(
        history: [
          _movie('a', position: 95 * _min),
          _movie('a', position: 95 * _min),
        ],
        series: const {},
        now: _now,
      );
      expect(stats.moviesFinished, 1);
      expect(stats.estimatedWatchMs, 95 * _min);
    });

    test('a position past the end counts to the end', () {
      final stats = ViewingStats.from(
        history: [_movie('long', position: 130 * _min)],
        series: const {},
        now: _now,
      );
      expect(stats.estimatedWatchMs, 100 * _min);
    });
  });

  group('Series', () {
    test('episodes count; the series\' own entry lends only its genres', () {
      final stats = ViewingStats.from(
        history: [
          MediaItem(
            id: '7',
            type: 'series',
            name: 'Show',
            resumeMs: 39 * _min,
            durationMs: 40 * _min,
            genreIds: const [18],
          ),
        ],
        series: {
          'series:7': _series({
            '1:1': _episode(39 * _min),
            '1:2': _episode(38 * _min),
            '1:3': _episode(10 * _min),
            '1:4': _episode(30000),
          }),
          'series:8': _series({'1:1': _episode(5 * _min)}),
        },
        now: _now,
      );
      expect(stats.moviesFinished + stats.moviesInProgress, 0);
      expect(stats.episodesFinished, 2);
      expect(stats.episodesInProgress, 2);
      expect(stats.seriesWatched, 1);
      // The series entry's own 39 minutes are not added again.
      expect(stats.estimatedWatchMs, (39 + 38 + 10 + 5) * _min);
      expect(stats.genres, [(genreId: 18, titles: 1)]);
      expect(stats.titlesWithGenres, 1);
    });
  });

  test('months: the last six, oldest first; undated finishes in none', () {
    final stats = ViewingStats.from(
      history: [
        _movie('nov', position: 95 * _min, at: _at(2026, 11)),
        _movie('jun', position: 95 * _min, at: _at(2026, 6)),
        _movie('old', position: 95 * _min, at: _at(2025, 1)),
        _movie('undated', position: 95 * _min),
      ],
      series: {
        'series:1': _series({
          '1:1': _episode(39 * _min, at: _at(2026, 11)),
          '1:2': _episode(39 * _min, at: _at(2026, 9)),
        }),
      },
      now: _now,
    );
    expect([for (final m in stats.months) m.month.month], [6, 7, 8, 9, 10, 11]);
    expect([for (final m in stats.months) m.finished], [1, 0, 0, 1, 0, 2]);
    expect(stats.moviesFinished, 4);
  });

  test('genres: most first, ties by id, at most five', () {
    final stats = ViewingStats.from(
      history: [
        for (var i = 0; i < 3; i++)
          _movie('d$i', position: 95 * _min, genres: const [18, 35]),
        _movie('h', position: 95 * _min, genres: const [27, 28, 12, 16, 80]),
        _movie('x', position: 95 * _min),
      ],
      series: const {},
      now: _now,
    );
    expect(stats.genres.first, (genreId: 18, titles: 3));
    expect(stats.genres[1], (genreId: 35, titles: 3));
    expect(stats.genres, hasLength(ViewingStats.topGenres));
    expect(stats.genres[2], (genreId: 12, titles: 1));
    expect(stats.titlesWithGenres, 4);
  });

  test('progress from another device replaces, never adds', () async {
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
    StorageService.useAccount('user-a');
    addTearDown(() => StorageService.useAccount(null));
    final storage = StorageService();
    const show = MediaItem(id: '5', type: 'series', name: 'Show');
    await storage.saveEpisodeProgress(
      show,
      season: 1,
      episode: 1,
      positionMs: 20 * _min,
      durationMs: 40 * _min,
    );
    await storage.saveProgress(
      const MediaItem(id: '9', type: 'movie', name: 'Film'),
      50 * _min,
      durationMs: 100 * _min,
    );
    final later = DateTime.now().millisecondsSinceEpoch + 60000;
    // The other device finished both.
    await storage.applySynced([
      SyncedProgress(
        key: 'episode:5:1:1',
        positionMs: 39 * _min,
        durationMs: 40 * _min,
        at: later,
      ),
      SyncedProgress(
        key: 'movie:9',
        positionMs: 95 * _min,
        durationMs: 100 * _min,
        at: later,
      ),
    ]);
    final stats = ViewingStats.from(
      history: await storage.history(),
      series: await storage.allSeriesProgress(),
    );
    expect(stats.episodesFinished, 1);
    expect(stats.episodesInProgress, 0);
    expect(stats.moviesFinished, 1);
    expect(stats.moviesInProgress, 0);
    expect(stats.estimatedWatchMs, (39 + 95) * _min);
  });

  test('nothing watched: empty', () {
    final stats = ViewingStats.from(
      history: const [],
      series: const {},
      now: _now,
    );
    expect(stats.isEmpty, isTrue);
    expect(ViewingStats.formatHours(0), 'Under a minute');
    expect(ViewingStats.formatHours(45 * _min), 'About 45 min');
    expect(ViewingStats.formatHours(150 * _min), 'About 3 h');
  });

  group('The page', () {
    Future<void> show(WidgetTester tester, StorageService storage) async {
      tester.view.physicalSize = const Size(412, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(body: ProfileStatsScreen(storage: storage)),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows the counts and says they are private', (tester) async {
      await show(
        tester,
        _Storage(
          [
            _movie('a', position: 95 * _min, genres: const [878]),
          ],
          {
            'series:1': _series({'1:1': _episode(39 * _min)}),
          },
        ),
      );
      expect(find.text('Movie finished'), findsOneWidget);
      expect(find.text('Episode finished'), findsOneWidget);
      expect(find.text('Science fiction'), findsOneWidget);
      expect(find.textContaining('never sent anywhere'), findsOneWidget);
    });

    testWidgets('without history, an empty state, not zeros', (tester) async {
      await show(tester, _Storage(const [], const {}));
      expect(find.textContaining('Nothing to count yet'), findsOneWidget);
      expect(find.text('Movies finished'), findsNothing);
    });
  });
}
