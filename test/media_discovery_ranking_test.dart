import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/media_discovery_ranking.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30);

  MediaItem item({
    String id = '1',
    String type = 'movie',
    String date = '2026-08-01',
    String lastAirDate = '',
    String rating = '8.0',
    int votes = 100,
    double popularity = 10,
    bool recentEpisode = false,
  }) => MediaItem(
    id: id,
    type: type,
    name: 'Title $id',
    releaseDate: date,
    lastAirDate: lastAirDate,
    rating: rating,
    voteCount: votes,
    popularity: popularity,
    hasRecentEpisode: recentEpisode,
  );

  group('New Releases', () {
    test('includes recent highly rated titles and orders by release date', () {
      final result = MediaDiscoveryRanking.newReleases([
        item(id: 'older'),
        item(id: 'newer', date: '2026-09-20', rating: '7.1'),
      ], now: now);

      expect(result.map((entry) => entry.id), ['newer', 'older']);
    });

    test('excludes low rated, old, and unrated titles', () {
      final result = MediaDiscoveryRanking.newReleases([
        item(id: 'low', rating: '6.9'),
        item(id: 'old', date: '2026-01-01'),
        item(id: 'missing', rating: ''),
        item(id: 'no-votes', votes: 0),
      ], now: now);

      expect(result, isEmpty);
    });

    test('safely excludes missing, malformed, and future dates', () {
      final result = MediaDiscoveryRanking.newReleases([
        item(id: 'missing-date', date: ''),
        item(id: 'malformed-date', date: 'not-a-date'),
        item(id: 'future', date: '2027-01-01'),
      ], now: now);

      expect(result, isEmpty);
    });

    test('includes an old series with a recently aired episode', () {
      final result = MediaDiscoveryRanking.newReleases([
        item(
          id: 'ongoing',
          type: 'series',
          date: '2018-01-01',
          lastAirDate: '2026-09-01',
        ),
        item(
          id: 'air-filter-match',
          type: 'series',
          date: '2010-01-01',
          recentEpisode: true,
        ),
      ], now: now);

      expect(
        result.map((entry) => entry.id),
        containsAll(['ongoing', 'air-filter-match']),
      );
    });

    test('deduplicates repeated IDs', () {
      final result = MediaDiscoveryRanking.newReleases([
        item(id: 'same'),
        item(id: 'same', date: '2026-09-01', rating: '9.0'),
      ], now: now);

      expect(result, hasLength(1));
    });
  });

  group('Spotlight', () {
    test('ranks recent high-rated titles before an older fallback', () {
      final result = MediaDiscoveryRanking.spotlightCandidates([
        item(id: 'older', date: '2023-01-01', rating: '9.5'),
        item(id: 'recent', date: '2026-08-01', rating: '8.0'),
      ], now: now);

      expect(result.map((entry) => entry.id), ['recent', 'older']);
    });

    test('never admits low-rated or future titles through fallback', () {
      final result = MediaDiscoveryRanking.spotlightCandidates([
        item(id: 'low', date: '2026-09-01', rating: '5.5'),
        item(id: 'future', date: '2027-01-01'),
        item(id: 'old', date: '2018-01-01'),
      ], now: now);

      expect(result, isEmpty);
    });

    test('uses older high-rated titles when the recent pool is short', () {
      final result = MediaDiscoveryRanking.spotlightCandidates([
        item(id: 'recent', date: '2026-08-01'),
        item(id: 'older', date: '2023-01-01'),
      ], now: now);

      expect(result.map((entry) => entry.id), ['recent', 'older']);
    });

    test(
      'keeps older series that matched the recent air-date filter current',
      () {
        final result = MediaDiscoveryRanking.spotlightCandidates([
          item(
            id: 'airing',
            type: 'series',
            date: '2010-01-01',
            recentEpisode: true,
          ),
          item(id: 'newer-movie', date: '2026-08-01'),
        ], now: now);

        expect(
          result.map((entry) => entry.id),
          containsAll(['airing', 'newer-movie']),
        );
      },
    );

    test('handles missing metadata without throwing', () {
      expect(
        MediaDiscoveryRanking.spotlightCandidates([
          item(id: 'no-rating', rating: ''),
          item(id: 'no-date', date: ''),
        ], now: now),
        isEmpty,
      );
    });
  });

  test(
    'TMDB normalization retains release, air-date, rating, and relevance metadata',
    () {
      final series = MediaItem.fromTmdb({
        'id': 10,
        'media_type': 'tv',
        'name': 'Series',
        'first_air_date': '2010-01-01',
        'last_episode_to_air': {'air_date': '2026-09-01'},
        'vote_average': 8.25,
        'vote_count': 900,
        'popularity': 42.5,
        'in_production': true,
      });

      expect(series.releaseDate, '2010-01-01');
      expect(series.lastAirDate, '2026-09-01');
      expect(series.rating, '8.3');
      expect(series.voteCount, 900);
      expect(series.popularity, 42.5);
      expect(series.isOngoing, isTrue);
    },
  );
}
