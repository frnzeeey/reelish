// Universal Search: the orchestration (requests, ranking, filters, paging,
// stale answers, recent searches), the parsing of people and collections,
// and playback discovery through the provider lookup.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/discovery/tmdb_genres.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/search/playback_availability.dart';
import 'package:onfeed/src/search/search_models.dart';
import 'package:onfeed/src/search/search_ranking.dart';
import 'package:onfeed/src/search/universal_search_controller.dart';

Map<String, Object?> movie(
  int id,
  String title, {
  String date = '2021-10-22',
  List<int> genres = const [878],
  double vote = 7.8,
  int votes = 9000,
  String? original,
}) => {
  'id': id,
  'media_type': 'movie',
  'title': title,
  'original_title': ?original,
  'release_date': date,
  'genre_ids': genres,
  'vote_average': vote,
  'vote_count': votes,
  'poster_path': '/p$id.jpg',
};

Map<String, Object?> show(
  int id,
  String name, {
  String date = '2019-04-01',
  List<int> genres = const [18],
  double vote = 8.2,
  int votes = 500,
}) => {
  'id': id,
  'media_type': 'tv',
  'name': name,
  'first_air_date': date,
  'genre_ids': genres,
  'vote_average': vote,
  'vote_count': votes,
};

Map<String, Object?> person(int id, String name, {String dept = 'Acting'}) => {
  'id': id,
  'media_type': 'person',
  'name': name,
  'known_for_department': dept,
  'profile_path': '/f$id.jpg',
  'known_for': [movie(1, 'Dune')],
};

class FakeCatalog implements SearchCatalog {
  final calls = <String>[];
  final Map<String, Map<String, dynamic>> answers = {};
  final Map<String, Completer<Map<String, dynamic>>> held = {};
  final Set<String> failing = {};

  Future<Map<String, dynamic>> _answer(String key) {
    calls.add(key);
    if (failing.contains(key)) return Future.error(Exception('down'));
    final hold = held[key];
    if (hold != null) return hold.future;
    return Future.value(
      answers[key] ?? {'results': <Object>[], 'total_pages': 1},
    );
  }

  @override
  Future<Map<String, dynamic>> multi(String query, {int page = 1}) =>
      _answer('multi:$query:$page');

  @override
  Future<Map<String, dynamic>> category(
    String kind,
    String query, {
    int page = 1,
    int? year,
  }) => _answer('$kind:$query:$page${year == null ? '' : ':$year'}');

  @override
  Future<Map<String, dynamic>> discover(
    String type,
    Map<String, String> params, {
    int page = 1,
  }) => _answer(
    'discover:$type:${(params.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}:$page',
  );

  @override
  Future<Map<String, dynamic>> person(int id) => _answer('person:$id');

  @override
  Future<Map<String, dynamic>> collection(int id) => _answer('collection:$id');

  @override
  Future<GenreCatalog> genres() async => GenreCatalog.fallback;
}

Map<String, dynamic> page(List<Object?> results, {int pages = 1}) => {
  'results': results,
  'total_pages': pages,
};

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late FakeCatalog catalog;
  late UniversalSearchController search;
  late Map<String, String> settings;

  setUp(() {
    catalog = FakeCatalog();
    settings = {};
    search = UniversalSearchController(
      catalog: catalog,
      debounce: const Duration(milliseconds: 30),
      readSetting: (key) async => settings[key],
      saveSetting: (key, value) async => settings[key] = value,
      currentYear: () => 2026,
    );
  });
  tearDown(() => search.dispose());

  group('ranking', () {
    test('normalizes case, accents, punctuation and a leading "the"', () {
      expect(
        normalizeForMatch('The Lord of the Rings: Return'),
        'lord of the rings return',
      );
      expect(normalizeForMatch('Amélie'), 'amelie');
      expect(normalizeForMatch('Fast & Furious'), 'fast and furious');
    });

    test('scores exact, leading and all-words matches', () {
      expect(matchScore('dune', 'Dune'), 3);
      expect(matchScore('dune', 'Dune: Part Two'), 2);
      expect(matchScore('part two dune', 'Dune: Part Two'), 1);
      expect(matchScore('dune', 'Spice'), 0);
      expect(matchScore('amelie', 'Le Fabuleux Destin', original: 'Amélie'), 3);
    });

    test('a trailing year is a year only when it could be one', () {
      expect(trailingYear('dune 2021', now: 2026), (words: 'dune', year: 2021));
      expect(trailingYear('blade runner 2049', now: 2026), isNull);
      expect(
        trailingYear('1917', now: 2026),
        isNull,
        reason: 'no words before',
      );
    });
  });

  group('overview', () {
    test(
      'one mixed search and one for collections, organised by kind',
      () async {
        catalog.answers['multi:dune:1'] = page([
          movie(1, 'Dune'),
          movie(2, 'Dune: Part Two', date: '2024-03-01'),
          show(3, 'Dune: Prophecy'),
          person(4, 'Denis Villeneuve', dept: 'Directing'),
          {'id': 5, 'media_type': 'company', 'name': 'Legendary'},
        ]);
        catalog.answers['collection:dune:1'] = page([
          {'id': 6, 'name': 'Dune Collection', 'poster_path': '/c.jpg'},
        ]);
        await search.search('dune');
        expect(catalog.calls, ['multi:dune:1', 'collection:dune:1']);
        final o = search.overview;
        expect(search.status, SearchStatus.ready);
        expect(o.movies.map((m) => m.name), ['Dune', 'Dune: Part Two']);
        expect(o.series.single.name, 'Dune: Prophecy');
        expect(o.people.single.role, 'Directing');
        expect(o.collections.single.name, 'Dune Collection');
        expect((o.top as MediaItem).id, '1', reason: 'exact match');
      },
    );

    test(
      'a person is the top result when their name is what was typed',
      () async {
        catalog.answers['multi:greta gerwig:1'] = page([
          movie(10, 'Little Women'),
          person(11, 'Greta Gerwig', dept: 'Directing'),
        ]);
        await search.search('greta gerwig');
        expect((search.overview.top as PersonHit).name, 'Greta Gerwig');
      },
    );

    test('no top result when nothing clearly matches', () async {
      catalog.answers['multi:space:1'] = page([movie(20, 'Interstellar')]);
      await search.search('space');
      expect(search.overview.top, isNull);
      expect(search.overview.movies.single.name, 'Interstellar');
    });

    test('a failed collections search leaves the rest', () async {
      catalog.answers['multi:dune:1'] = page([movie(1, 'Dune')]);
      catalog.failing.add('collection:dune:1');
      await search.search('dune');
      expect(search.status, SearchStatus.ready);
      expect(search.overview.movies, hasLength(1));
    });

    test(
      '"dune 2021" finds Dune from 2021 when nothing is called that',
      () async {
        catalog.answers['movie:dune:1:2021'] = page([
          movie(1, 'Dune'),
        ], pages: 1);
        await search.search('dune 2021');
        expect(search.overview.yearFromQuery, 2021);
        expect(search.overview.movies.single.name, 'Dune');
        expect(catalog.calls, contains('tv:dune:1:2021'));
      },
    );

    test(
      'a failed search says so, and empty input goes back to landing',
      () async {
        catalog.failing.add('multi:x:1');
        await search.search('x');
        expect(search.status, SearchStatus.failed);
        await search.search('   ');
        expect(search.status, SearchStatus.landing);
        expect(catalog.calls, ['multi:x:1', 'collection:x:1']);
      },
    );

    test('control characters are removed and long input is cut', () async {
      await search.search('a\u0000b');
      expect(search.query, 'a b');
      await search.search('q' * 300);
      expect(search.query.length, 100);
    });
  });

  group('typing', () {
    test('debounces: one search for a burst of keystrokes', () async {
      for (final text in ['d', 'du', 'dun', 'dune']) {
        search.queryChanged(text);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(catalog.calls.where((c) => c.startsWith('multi')), [
        'multi:dune:1',
      ]);
    });

    test(
      'a slow answer to an older query never replaces a newer one',
      () async {
        final slow = Completer<Map<String, dynamic>>();
        catalog.held['multi:dun:1'] = slow;
        catalog.answers['multi:dune:1'] = page([movie(1, 'Dune')]);
        unawaited(search.search('dun'));
        await settle();
        await search.search('dune');
        slow.complete(page([movie(99, 'Dunkirk')]));
        await settle();
        expect(search.query, 'dune');
        expect(search.overview.movies.single.name, 'Dune');
      },
    );
  });

  group('categories and paging', () {
    test(
      'a category pages on demand, each result once, within the cap',
      () async {
        catalog.answers['movie:star:1'] = page([
          movie(1, 'Star Wars'),
          movie(2, 'Stardust'),
        ], pages: 3);
        catalog.answers['movie:star:2'] = page([
          movie(2, 'Stardust'),
          movie(3, 'Star Trek'),
        ], pages: 3);
        await search.search('star');
        search.setCategory(SearchCategory.movies);
        await settle();
        expect(search.items, hasLength(2));
        expect(search.hasMore, isTrue);
        await search.loadMore();
        expect(search.items.map((i) => (i as MediaItem).name), [
          'Star Wars',
          'Stardust',
          'Star Trek',
        ]);
      },
    );

    test('people and collections have their own searches', () async {
      catalog.answers['person:nolan:1'] = page([
        {
          'id': 5,
          'name': 'Christopher Nolan',
          'known_for_department': 'Directing',
        },
      ]);
      await search.search('nolan');
      search.setCategory(SearchCategory.people);
      await settle();
      expect((search.items.single as PersonHit).name, 'Christopher Nolan');
      search.setCategory(SearchCategory.collections);
      await settle();
      expect(catalog.calls, contains('collection:nolan:1'));
    });
  });

  group('filters', () {
    test('genre, years and rating apply to titles, together', () async {
      catalog.answers['movie:dune:1'] = page([
        movie(1, 'Dune', date: '2021-10-22', genres: [878], vote: 7.8),
        movie(2, 'Dune', date: '1984-12-14', genres: [878], vote: 6.3),
        movie(3, 'Dune Drifter', date: '2020-01-01', genres: [53], vote: 4.0),
        movie(4, 'Dune World', date: '', genres: [878], vote: 8.0),
        movie(5, 'Dune Fan Cut', genres: [878], vote: 9.5, votes: 3),
      ]);
      await search.search('dune');
      search.setFilters(
        const SearchFilters(
          genres: {878},
          yearFrom: 2000,
          yearTo: 2030,
          minRating: 7,
        ),
      );
      await settle();
      expect(search.filtering, isTrue);
      expect(search.overview.movies.map((m) => m.id), ['1']);
      expect(search.overview.people, isEmpty, reason: 'filters are for titles');
      expect(catalog.calls, contains('tv:dune:1'));
    });

    test('a single year is narrowed by TMDB itself', () async {
      await search.search('dune');
      search.setFilters(const SearchFilters(yearFrom: 2021, yearTo: 2021));
      await settle();
      expect(
        catalog.calls,
        containsAll(['movie:dune:1:2021', 'tv:dune:1:2021']),
      );
    });

    test('Science fiction also finds series tagged Sci-Fi & Fantasy', () {
      const filters = SearchFilters(genres: {878});
      final series = MediaItem(
        id: '1',
        type: 'series',
        name: 'x',
        genreIds: const [10765],
      );
      expect(filters.matches(series), isTrue);
      expect(
        filters.discoverParams('tv', GenreCatalog.fallback)['with_genres'],
        '10765',
      );
    });

    test('filters without words browse what fits them', () async {
      search.setFilters(const SearchFilters(genres: {28}, minRating: 7));
      await settle();
      expect(
        catalog.calls,
        containsAll([
          'discover:movie:vote_average.gte=7.0&vote_count.gte=20&with_genres=28:1',
          'discover:tv:vote_average.gte=7.0&vote_count.gte=20&with_genres=10759:1',
        ]),
      );
      expect(search.status, SearchStatus.ready);
      search.clearFilters();
      await settle();
      expect(search.status, SearchStatus.landing);
    });

    test('changing filters keeps the words', () async {
      await search.search('dune');
      search.setFilters(const SearchFilters(minRating: 8));
      await settle();
      expect(search.query, 'dune');
    });
  });

  group('recent searches', () {
    test(
      'remembers searches newest first, once each, and forgets them',
      () async {
        settings[UniversalSearchController.recentSearchesKey] = jsonEncode([
          'Arrival',
          42,
        ]);
        await search.start();
        expect(search.recent, ['Arrival']);
        await search.search('dune');
        await search.search('ARRIVAL');
        await settle();
        expect(search.recent, ['ARRIVAL', 'dune']);
        await search.clearRecent();
        expect(
          jsonDecode(settings[UniversalSearchController.recentSearchesKey]!),
          isEmpty,
        );
      },
    );
  });

  group('pages behind a result', () {
    test(
      'a person keeps acting and directing apart, best known first',
      () async {
        catalog.answers['person:7'] = {
          'id': 7,
          'name': 'Greta Gerwig',
          'known_for_department': 'Directing',
          'profile_path': '/g.jpg',
          'biography': 'Writer and director.',
          'combined_credits': {
            'cast': [
              movie(1, 'Frances Ha', votes: 900),
              {'id': 'bad'},
            ],
            'crew': [
              {...movie(2, 'Lady Bird', votes: 5000), 'job': 'Director'},
              {...movie(3, 'Barbie', votes: 9000), 'job': 'Director'},
              {...movie(3, 'Barbie', votes: 9000), 'job': 'Screenplay'},
            ],
          },
        };
        final p = await search.person(7);
        expect(p.acting.single.item.name, 'Frances Ha');
        expect(p.directing.map((c) => c.item.name), ['Barbie', 'Lady Bird']);
        expect(p.otherCrew.single.role, 'Screenplay');
        expect(p.profileUrl, endsWith('/g.jpg'));
      },
    );

    test('a collection lists its films in release order', () async {
      catalog.answers['collection:9'] = {
        'id': 9,
        'name': 'Dune Collection',
        'parts': [
          {'id': 2, 'title': 'Dune: Part Two', 'release_date': '2024-03-01'},
          {'id': 3, 'title': 'Dune: Part Three', 'release_date': ''},
          {'id': 1, 'title': 'Dune', 'release_date': '2021-10-22'},
        ],
      };
      final c = await search.collection(9);
      expect(c.parts.map((p) => p.name), [
        'Dune',
        'Dune: Part Two',
        'Dune: Part Three',
      ]);
    });

    test('untrusted shapes are dropped, image paths checked', () {
      expect(PersonHit.fromJson({'id': '7', 'name': 'x'}), isNull);
      expect(PersonHit.fromJson({'id': 7, 'name': ''}), isNull);
      expect(
        PersonHit.fromJson({
          'id': 7,
          'name': 'x',
          'profile_path': 'https://evil.example/a.jpg',
        })!.profileUrl,
        isEmpty,
      );
      expect(CollectionHit.fromJson('nope'), isNull);
      expect(tmdbImage('/ok.jpg'), 'https://image.tmdb.org/t/p/w342/ok.jpg');
      expect(tmdbImage('/../x'), isEmpty);
    });
  });

  group('playback discovery', () {
    StreamSource source(String provider, String url, {String quality = ''}) =>
        StreamSource(
          name: provider,
          url: url,
          description: '',
          providerName: provider,
          providerId: 'repo|$provider',
          quality: quality,
        );

    const dune = MediaItem(id: '438631', type: 'movie', name: 'Dune');

    test(
      'reports sources by provider as they arrive, without duplicates',
      () async {
        final asked = <String>[];
        final availability = PlaybackAvailability(
          lookup: (item, {required isCancelled, required onSource}) async {
            asked.add(item.id);
            onSource(source('Alpha', 'https://a/1', quality: '1080p'));
            onSource(source('Alpha', 'https://a/1', quality: '1080p'));
            onSource(source('Alpha', 'https://a/2', quality: '720p'));
            onSource(source('Beta', 'https://b/1'));
            return const [];
          },
        );
        availability.check(dune);
        await settle();
        final result = availability.of(dune)!;
        expect(result.state, AvailabilityState.found);
        expect(result.finished, isTrue);
        expect(result.sourceCount, 3);
        expect(result.providers.first.provider, 'Alpha');
        expect(result.providers.first.qualities, {'1080p', '720p'});
        expect(
          result.providers.last.qualities,
          isEmpty,
          reason: 'none supplied',
        );
        // A recent answer is reused.
        availability.check(dune);
        await settle();
        expect(asked, ['438631']);
        availability.check(dune, again: true);
        await settle();
        expect(asked, hasLength(2));
        availability.dispose();
      },
    );

    test(
      'says when nothing was found, or when providers took too long',
      () async {
        final none = PlaybackAvailability(
          lookup: (_, {required isCancelled, required onSource}) async =>
              const [],
        );
        none.check(dune);
        await settle();
        expect(none.of(dune)!.state, AvailabilityState.none);

        final slow = PlaybackAvailability(
          limit: const Duration(milliseconds: 20),
          lookup: (_, {required isCancelled, required onSource}) =>
              Completer<List<StreamSource>>().future,
        );
        slow.check(dune);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(slow.of(dune)!.state, AvailabilityState.timedOut);
        none.dispose();
        slow.dispose();
      },
    );

    test('a failing lookup fails only this check', () async {
      final broken = PlaybackAvailability(
        lookup: (_, {required isCancelled, required onSource}) =>
            Future.error(StateError('provider crashed')),
      );
      broken.check(dune);
      await settle();
      expect(broken.of(dune)!.state, AvailabilityState.failed);
      broken.dispose();
    });

    test(
      'a newer check cancels the older one, which stops reporting',
      () async {
        final cancelled = <String, bool Function()>{};
        final reports = <String, void Function(StreamSource)>{};
        final availability = PlaybackAvailability(
          lookup: (item, {required isCancelled, required onSource}) {
            cancelled[item.id] = isCancelled;
            reports[item.id] = onSource;
            return Completer<List<StreamSource>>().future;
          },
        );
        availability.check(dune);
        await settle();
        const arrival = MediaItem(id: '329865', type: 'movie', name: 'Arrival');
        availability.check(arrival);
        await settle();
        expect(cancelled['438631']!(), isTrue);
        expect(cancelled['329865']!(), isFalse);
        reports['438631']!(source('Alpha', 'https://late'));
        expect(availability.of(dune), isNull, reason: 'stale, never shown');
        availability.dispose();
      },
    );

    test('series are not checked: providers look up one episode at a time', () {
      var asked = false;
      final availability = PlaybackAvailability(
        lookup: (_, {required isCancelled, required onSource}) async {
          asked = true;
          return const [];
        },
      );
      availability.check(
        const MediaItem(id: '1399', type: 'series', name: 'Game of Thrones'),
      );
      expect(asked, isFalse);
      expect(PlaybackAvailability.canCheck(dune), isTrue);
      availability.dispose();
    });
  });
}
