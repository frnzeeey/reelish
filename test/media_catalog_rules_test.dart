import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/media_discovery_ranking.dart';

void main() {
  final now = DateTime.utc(2026, 10, 5);

  MediaItem item({
    String id = '1',
    String type = 'movie',
    String? name,
    String date = '2026-08-01',
    String rating = '8.0',
    int votes = 500,
    double popularity = 10,
    List<int> genres = const [18],
  }) => MediaItem(
    id: id,
    type: type,
    name: name ?? 'Title $id',
    releaseDate: date,
    rating: rating,
    voteCount: votes,
    popularity: popularity,
    genreIds: genres,
  );

  List<String> ids(List<MediaItem> items) => [for (final i in items) i.id];

  group('Weighted rating', () {
    test('a few perfect votes do not beat an established title', () {
      final fluke = item(id: 'fluke', rating: '10.0', votes: 1);
      final twoVotes = item(id: 'two', rating: '10.0', votes: 2);
      final proven = item(id: 'proven', rating: '8.5', votes: 10000);
      final big = item(id: 'big', rating: '8.2', votes: 50000);

      expect(
        MediaDiscoveryRanking.weightedRating(proven),
        greaterThan(MediaDiscoveryRanking.weightedRating(fluke)),
      );
      expect(
        MediaDiscoveryRanking.weightedRating(big),
        greaterThan(MediaDiscoveryRanking.weightedRating(twoVotes)),
      );
      expect(ids(MediaDiscoveryRanking.rankByScore([fluke, proven])), [
        'proven',
        'fluke',
      ]);
    });

    test('unrated and malformed ratings rank last without throwing', () {
      expect(MediaDiscoveryRanking.weightedRating(item(rating: '')), 0);
      expect(MediaDiscoveryRanking.weightedRating(item(rating: 'n/a')), 0);
      expect(MediaDiscoveryRanking.weightedRating(item(rating: '11')), 0);
      expect(
        MediaDiscoveryRanking.weightedRating(item(rating: '7', votes: -4)),
        closeTo(6.5, 0.001),
      );
    });
  });

  group('New movies', () {
    test('keeps only movies released inside the window', () {
      final result = MediaDiscoveryRanking.newMovies([
        item(id: 'recent', date: '2026-09-01'),
        item(id: 'classic', date: '1994-09-23', rating: '9.3', votes: 30000),
        item(id: 'last-year', date: '2025-09-01'),
        item(id: 'future', date: '2026-12-01'),
        item(id: 'no-date', date: ''),
        item(id: 'bad-date', date: 'soon'),
        item(id: 'show', type: 'series', date: '2026-09-01'),
      ], now: now);

      expect(ids(result), ['recent']);
    });

    test('ranks by vote-aware quality, not raw rating', () {
      final result = MediaDiscoveryRanking.newMovies([
        item(id: 'fluke', rating: '10.0', votes: 6, date: '2026-09-20'),
        item(id: 'hit', rating: '8.2', votes: 5000, date: '2026-07-01'),
      ], now: now);

      expect(ids(result), ['hit', 'fluke']);
    });

    test('fills a short row from relaxed rules, never with old titles', () {
      final result = MediaDiscoveryRanking.newMovies([
        item(id: 'strong', date: '2026-08-01'),
        item(id: 'few-votes', votes: 8, date: '2026-08-01'),
        item(id: 'no-votes', votes: 1, date: '2026-08-01'),
        item(id: 'old', date: '2010-01-01'),
      ], now: now);

      expect(ids(result), ['strong', 'few-votes']);
    });

    test('a full strict row is not padded with weaker titles', () {
      final strong = [
        for (var i = 0; i < MediaDiscoveryRanking.minimumRowSize; i++)
          item(id: 's$i'),
      ];
      final result = MediaDiscoveryRanking.newMovies([
        ...strong,
        item(id: 'weak', votes: 8),
      ], now: now);

      expect(result, hasLength(MediaDiscoveryRanking.minimumRowSize));
      expect(ids(result), isNot(contains('weak')));
    });
  });

  group('Series worth the queue', () {
    MediaItem show(String id, List<int> genres, {String? name}) => item(
      id: id,
      type: 'series',
      name: name,
      genres: genres,
      rating: '8.0',
      votes: 900,
    );

    test('ranks scripted series first and never admits talk, news, '
        'reality-only or event programming', () {
      final result = MediaDiscoveryRanking.worthQueueSeries([
        show('drama', [18]),
        show('late-night', [35, TmdbGenre.talk]),
        show('news', [TmdbGenre.news]),
        show('reality', [TmdbGenre.reality]),
        show('soap', [TmdbGenre.soap, 18]),
        show('awards', [35], name: 'The 98th Academy Awards'),
        show('docuseries', [TmdbGenre.documentary]),
        show('true-crime', [TmdbGenre.documentary, 80]),
        show('sitcom', [35]),
      ]);

      // Strict tier first; soap with a drama tag and the docuseries only
      // fill the short row afterwards.
      expect(
        ids(result).take(3),
        unorderedEquals(['drama', 'true-crime', 'sitcom']),
      );
      expect(ids(result).skip(3), unorderedEquals(['soap', 'docuseries']));
      for (final excluded in ['late-night', 'news', 'reality', 'awards']) {
        expect(ids(result), isNot(contains(excluded)));
      }
    });

    test('strict picks come first; a short row is filled, never with talk '
        'shows or movies', () {
      final result = MediaDiscoveryRanking.worthQueueSeries([
        show('drama', [18]),
        show('soap', [TmdbGenre.soap]),
        show('no-genres', const []),
        show('talk', [TmdbGenre.talk]),
        item(id: 'movie', genres: const [18]),
      ]);

      expect(ids(result).first, 'drama');
      expect(ids(result), containsAll(['soap', 'no-genres']));
      expect(ids(result), isNot(contains('talk')));
      expect(result.every((entry) => entry.type == 'series'), isTrue);
    });

    test('deduplicates repeated ids', () {
      final result = MediaDiscoveryRanking.worthQueueSeries([
        show('same', [18]),
        show('same', [18]),
      ]);
      expect(result, hasLength(1));
    });
  });

  group('Recommendations', () {
    test('10.0 from one vote does not outrank 8.5 from 10,000 votes', () {
      final result = MediaDiscoveryRanking.recommendations([
        item(id: 'fluke', rating: '10.0', votes: 1),
        item(id: 'proven', rating: '8.5', votes: 10000),
      ], now: now);

      expect(ids(result).first, 'proven');
    });

    test('excludes seeds and unsuitable series, and stays unique', () {
      final result = MediaDiscoveryRanking.recommendations(
        [
          item(id: 'seed'),
          item(id: 'a'),
          item(id: 'a'),
          item(id: 'talk', type: 'series', genres: [TmdbGenre.talk]),
          item(id: 'b', type: 'series'),
        ],
        excludedKeys: {'movie:seed'},
        now: now,
      );

      expect(ids(result), unorderedEquals(['a', 'b']));
    });

    test('prefers current titles, using older ones only to fill', () {
      final result = MediaDiscoveryRanking.recommendations([
        item(id: 'old-classic', date: '1972-03-24', rating: '9.2'),
        item(id: 'current', date: '2024-05-01', rating: '7.8'),
      ], now: now);

      expect(ids(result), ['current', 'old-classic']);
    });

    test('seed is the best vote-weighted title of the type', () {
      final catalog = [
        item(id: 'fluke', rating: '9.9', votes: 3),
        item(id: 'solid', rating: '8.1', votes: 4000),
        item(id: 'talk', type: 'series', genres: [TmdbGenre.talk]),
        item(id: 'show', type: 'series', rating: '7.4', votes: 300),
      ];

      expect(
        MediaDiscoveryRanking.recommendationSeed(catalog, 'movie')?.id,
        'solid',
      );
      expect(
        MediaDiscoveryRanking.recommendationSeed(catalog, 'series')?.id,
        'show',
      );
      expect(MediaDiscoveryRanking.recommendationSeed(const [], 'movie'), null);
    });
  });

  group('Freshness rules', () {
    test('handle missing, malformed and future dates', () {
      const window = Duration(days: 365);
      bool recent(String date) => MediaFreshnessRules.isRecentlyReleased(
        item(date: date),
        window: window,
        now: now,
      );

      expect(recent('2026-10-05'), isTrue);
      expect(recent('2025-10-05'), isTrue);
      expect(recent('2025-10-04'), isFalse);
      expect(recent('2026-10-06'), isFalse);
      expect(recent(''), isFalse);
      expect(recent('2026-13-45x'), isFalse);
      expect(
        MediaFreshnessRules.freshness(item(date: ''), window: window, now: now),
        0,
      );
    });
  });

  test('MediaItem.fromTmdb reads genres from lists and details', () {
    expect(
      MediaItem.fromTmdb({
        'id': 1,
        'genre_ids': [18, '80', null, 'x'],
      }).genreIds,
      [18, 80],
    );
    expect(
      MediaItem.fromTmdb({
        'id': 1,
        'genres': [
          {'id': 10767, 'name': 'Talk'},
          'bad',
        ],
      }, mediaType: 'tv').genreIds,
      [10767],
    );
    final saved = MediaItem.fromStorage(
      MediaItem.fromTmdb({
        'id': 1,
        'genre_ids': [18],
      }).toJson(),
    );
    expect(saved.genreIds, [18]);
  });
}
