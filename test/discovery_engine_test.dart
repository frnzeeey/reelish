import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/discovery/discovery_data.dart';
import 'package:onfeed/src/discovery/discovery_engine.dart';
import 'package:onfeed/src/discovery/taste_profile.dart';
import 'package:onfeed/src/discovery/viewing_activity.dart';
import 'package:onfeed/src/models/media_item.dart';

final _now = DateTime.utc(2026, 6, 1);

const _sciFi = 878, _drama = 18, _comedy = 35, _horror = 27, _mystery = 9648;
const _thriller = 53, _romance = 10749;

final _ids = <String, String>{};

/// A title named [label]. The engine only takes real (numeric) TMDB ids, so
/// a label that is not a number gets a stable one.
MediaItem _title(
  String label, {
  String type = 'movie',
  List<int> genres = const [_drama],
  double rating = 7.6,
  int votes = 2000,
  double popularity = 40,
  String date = '2022-05-01',
}) => MediaItem(
  id: int.tryParse(label) != null
      ? label
      : _ids.putIfAbsent(label, () => '${9000 + _ids.length}'),
  type: type,
  name: label,
  genreIds: genres,
  rating: rating.toStringAsFixed(1),
  voteCount: votes,
  popularity: popularity,
  releaseDate: date,
);

TitleActivity _finished(MediaItem item, {DateTime? at, int times = 1}) {
  var entry = TitleActivity.record(
    null,
    item,
    positionMs: 95 * 60000,
    durationMs: 100 * 60000,
    at: at ?? _now,
  );
  for (var i = 1; i < times; i++) {
    entry = TitleActivity.record(
      entry,
      item,
      positionMs: 2 * 60000,
      durationMs: 100 * 60000,
      at: at ?? _now,
    );
    entry = TitleActivity.record(
      entry,
      item,
      positionMs: 95 * 60000,
      durationMs: 100 * 60000,
      at: at ?? _now,
    );
  }
  return entry!;
}

TitleActivity _abandoned(MediaItem item) => TitleActivity.record(
  null,
  item,
  positionMs: 5 * 60000,
  durationMs: 100 * 60000,
  at: _now.subtract(const Duration(days: 40)),
)!;

DiscoveryData _data(Iterable<TitleActivity> activity) {
  var data = DiscoveryData.empty;
  for (final entry in activity) {
    data = data.withActivity(entry);
  }
  return data;
}

void main() {
  group('TasteProfile', () {
    test('a new viewer has no profile, so no personalised rows', () {
      final profile = TasteProfile.build(DiscoveryData.empty, now: _now);
      expect(profile.isEmpty, isTrue);
      expect(
        DiscoveryEngine.build(
          profile,
          pool: [for (var i = 0; i < 30; i++) _title('$i')],
          now: _now,
        ),
        isEmpty,
      );
    });

    test('genre affinity follows what was watched, strongest first', () {
      final profile = TasteProfile.build(
        _data([
          _finished(_title('1', genres: [_sciFi, _thriller])),
          _finished(_title('2', genres: [_sciFi])),
          _finished(_title('3', genres: [_comedy])),
        ]),
        now: _now,
      );
      expect(profile.topGenres.first, _sciFi);
      expect(profile.genreAffinity[_sciFi], 1.0);
      expect(
        profile.genreAffinity[_comedy]!,
        lessThan(profile.genreAffinity[_sciFi]!),
      );
    });

    test('a rewatch counts more than a single viewing', () {
      final profile = TasteProfile.build(
        _data([
          _finished(_title('1', genres: [_horror]), times: 2),
          _finished(_title('2', genres: [_comedy])),
        ]),
        now: _now,
      );
      expect(profile.topGenres.first, _horror);
      expect(profile.seeds.first.item.name, '1');
    });

    test('abandoned titles count against their genres, never seed', () {
      final profile = TasteProfile.build(
        _data([
          _abandoned(_title('1', genres: [_romance])),
          _finished(_title('2', genres: [_sciFi])),
        ]),
        now: _now,
      );
      expect(profile.genreAffinity[_romance]!, lessThan(0));
      expect(profile.seeds.map((s) => s.item.name), ['2']);
      expect(profile.excludedKeys, containsAll(['movie:1', 'movie:2']));
    });

    test('one recent title does not outweigh long-standing tastes', () {
      final old = _now.subtract(const Duration(days: 200));
      final profile = TasteProfile.build(
        _data([
          for (var i = 0; i < 6; i++)
            _finished(_title('old$i', genres: [_mystery]), at: old),
          _finished(_title('new', genres: [_comedy])),
        ]),
        now: _now,
      );
      expect(profile.topGenres.first, _mystery);
    });

    test('picked genres count from the start', () {
      final profile = TasteProfile.build(
        DiscoveryData.empty.withFavoriteGenres([_horror]),
        now: _now,
      );
      expect(profile.isEmpty, isFalse);
      expect(profile.genreAffinity[_horror], 0.5);
      expect(profile.seeds, isEmpty);
    });

    test('Not interested lowers a genre but never excludes it', () {
      var data = _data([
        _finished(_title('1', genres: [_horror])),
      ]);
      for (var i = 0; i < 50; i++) {
        data = data.withFeedback(
          TitleFeedback.of(
            FeedbackKind.notInterested,
            _title('n$i', genres: [_comedy]),
            _now,
          ),
        );
      }
      final profile = TasteProfile.build(data, now: _now);
      expect(profile.genreAffinity[_comedy], DiscoveryWeights.minGenreAffinity);
      // A comedy can still be recommended (it only ranks lower).
      final scored = DiscoveryEngine.score(
        profile,
        pool: [
          _title('c', genres: [_comedy]),
        ],
        now: _now,
      );
      expect(scored.map((c) => c.item.name), ['c']);
    });

    test('seeds mix movies and series when both are watched', () {
      final profile = TasteProfile.build(
        _data([
          for (var i = 0; i < 5; i++) _finished(_title('m$i'), times: 2),
          TitleActivity.record(
            null,
            _title('s1', type: 'series'),
            positionMs: 50 * 60000,
            durationMs: 50 * 60000,
            episode: (season: 1, episode: 1),
            at: _now,
          )!,
        ]),
        now: _now,
      );
      expect(profile.seeds, hasLength(4));
      expect(profile.seeds.map((s) => s.item.type), contains('series'));
    });

    test('My list counts and is excluded', () {
      final saved = _title('fav', genres: [_thriller]);
      final profile = TasteProfile.build(
        DiscoveryData.empty,
        myList: [saved],
        now: _now,
      );
      expect(profile.topGenres, contains(_thriller));
      expect(profile.excludedKeys, contains('movie:${saved.id}'));
      expect(profile.seeds.single.origin, SeedOrigin.saved);
    });
  });

  group('DiscoveryEngine', () {
    final watched = _title('seed', genres: [_sciFi]);
    TasteProfile sciFiFan() => TasteProfile.build(
      _data([
        _finished(watched),
        _finished(_title('seed2', genres: [_sciFi, _thriller])),
      ]),
      now: _now,
    );

    test('never recommends a watched, saved, hidden or unreleased title', () {
      final profile = TasteProfile.build(
        _data([_finished(watched)]).withFeedback(
          TitleFeedback.of(FeedbackKind.alreadyWatched, _title('seen'), _now),
        ),
        myList: [_title('saved')],
        now: _now,
      );
      final scored = DiscoveryEngine.score(
        profile,
        pool: [
          watched,
          _title('saved'),
          _title('seen'),
          _title('future', date: '2027-01-01'),
          _title('weak', rating: 3.0),
          _title('novotes', votes: 1),
          _title('ok'),
        ],
        now: _now,
      );
      expect(scored.map((c) => c.item.name), ['ok']);
    });

    test('a close genre match outranks a merely popular title', () {
      final scored = DiscoveryEngine.score(
        sciFiFan(),
        pool: [
          _title('blockbuster', genres: [_comedy], popularity: 5000),
          _title('niche', genres: [_sciFi], popularity: 3, votes: 300),
        ],
        now: _now,
      );
      expect(scored.first.item.name, 'niche');
    });

    test('builds explained rows without duplicates across them', () {
      final profile = sciFiFan();
      final seedList = [
        for (var i = 0; i < 20; i++)
          _title('r$i', genres: i.isEven ? [_sciFi] : [_drama, _sciFi]),
      ];
      final pool = [
        for (var i = 0; i < 25; i++)
          _title('p$i', genres: [if (i % 3 == 0) _sciFi else _comedy]),
        for (var i = 0; i < 10; i++)
          _title('x$i', genres: [_romance], rating: 8.4),
      ];
      final sections = DiscoveryEngine.build(
        profile,
        seedLists: [SeedCandidates(profile.seeds.first, seedList)],
        pool: pool,
        now: _now,
      );
      expect(sections.first.kind, DiscoverySectionKind.forYou);
      expect(sections.first.title, 'Recommended for you');
      final because = sections.where(
        (s) => s.kind == DiscoverySectionKind.becauseYouWatched,
      );
      expect(because.single.title, startsWith('Because you watched seed'));
      final keys = [
        for (final s in sections)
          for (final item in s.items) '${item.type}:${item.id}',
      ];
      expect(keys.toSet().length, keys.length, reason: 'no title twice');
      for (final s in sections) {
        expect(
          s.items.length,
          greaterThanOrEqualTo(DiscoveryEngine.minRowSize),
        );
        for (final item in s.items) {
          expect(s.reasonFor(item), isNotEmpty);
        }
      }
      expect(sections.length, lessThanOrEqualTo(DiscoveryEngine.maxSections));
    });

    test('one genre cannot take the whole row; some titles explore', () {
      final profile = sciFiFan();
      final pool = [
        for (var i = 0; i < 40; i++) _title('s$i', genres: [_sciFi]),
        for (var i = 0; i < 10; i++)
          _title('o$i', genres: [_romance], rating: 8.2),
      ];
      final forYou = DiscoveryEngine.build(
        profile,
        pool: pool,
        now: _now,
      ).first;
      final other = forYou.items.where((i) => i.genreIds.first != _sciFi);
      // Explore slots (about a quarter) go to titles outside sci-fi.
      expect(other.length, greaterThanOrEqualTo(3));
      expect(forYou.reasons.values, contains('Something a little different'));
    });

    test('rows with too few titles are left out rather than shown short', () {
      final profile = sciFiFan();
      final sections = DiscoveryEngine.build(
        profile,
        seedLists: [
          SeedCandidates(profile.seeds.first, [_title('only')]),
        ],
        pool: [_title('a'), _title('b')],
        now: _now,
      );
      expect(sections, isEmpty);
    });

    test('empty TMDB answers still give rows from what Home has', () {
      final profile = sciFiFan();
      final sections = DiscoveryEngine.build(
        profile,
        seedLists: [SeedCandidates(profile.seeds.first, const [])],
        pool: [
          for (var i = 0; i < 20; i++) _title('p$i', genres: [_sciFi]),
        ],
        now: _now,
      );
      expect(sections.first.kind, DiscoverySectionKind.forYou);
      expect(
        sections.any((s) => s.kind == DiscoverySectionKind.becauseYouWatched),
        isFalse,
      );
    });

    test('series fans get series first', () {
      final series = TitleActivity.record(
        null,
        _title('s', type: 'series', genres: [_drama]),
        positionMs: 50 * 60000,
        durationMs: 50 * 60000,
        episode: (season: 1, episode: 1),
        at: _now,
      )!;
      var entry = series;
      for (var e = 2; e < 8; e++) {
        entry = TitleActivity.record(
          entry,
          _title('s', type: 'series', genres: [_drama]),
          positionMs: 50 * 60000,
          durationMs: 50 * 60000,
          episode: (season: 1, episode: e),
          at: _now,
        )!;
      }
      final profile = TasteProfile.build(_data([entry]), now: _now);
      expect(profile.seriesShare, 1.0);
      final scored = DiscoveryEngine.score(
        profile,
        pool: [
          _title('movie', genres: [_drama]),
          _title('show', type: 'series', genres: [_drama]),
        ],
        now: _now,
      );
      expect(scored.first.item.name, 'show');
    });

    test('the same inputs always give the same rows', () {
      final profile = sciFiFan();
      final pool = [
        for (var i = 0; i < 30; i++)
          _title('p$i', genres: [i.isEven ? _sciFi : _drama], rating: 7.0),
      ];
      List<String> ids() => [
        for (final s in DiscoveryEngine.build(profile, pool: pool, now: _now))
          for (final item in s.items) item.name,
      ];
      expect(ids(), ids());
    });

    test('rows survive the cache round trip', () {
      final section = DiscoverySection(
        kind: DiscoverySectionKind.becauseYouWatched,
        title: 'Because you watched X',
        seedKey: 'movie:1',
        items: [_title('a')],
        reasons: {'movie:${_title('a').id}': 'Similar to X'},
      );
      final back = DiscoverySection.fromJson(section.toJson())!;
      expect(back.id, 'becauseYouWatched:movie:1');
      expect(back.items.single.genreIds, [_drama]);
      expect(back.reasonFor(back.items.single), 'Similar to X');
    });
  });
}
