import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/discovery/discovery_controller.dart';
import 'package:onfeed/src/discovery/discovery_data.dart';
import 'package:onfeed/src/discovery/discovery_engine.dart';
import 'package:onfeed/src/discovery/discovery_preferences.dart';
import 'package:onfeed/src/discovery/discovery_store.dart';
import 'package:onfeed/src/discovery/taste_profile.dart';
import 'package:onfeed/src/discovery/tmdb_genres.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/viewmodels/home_view_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sciFi = 878, _comedy = 35, _horror = 27, _western = 37;

MediaItem _title(
  int id, {
  String type = 'movie',
  List<int> genres = const [_comedy],
  int resumeMs = 0,
  int durationMs = 0,
}) => MediaItem(
  id: '$id',
  type: type,
  name: 'Title $id',
  genreIds: genres,
  rating: '7.6',
  voteCount: 2500,
  popularity: 40,
  releaseDate: '2020-05-01',
  resumeMs: resumeMs,
  durationMs: durationMs,
);

class _FakeStorage extends StorageService {
  _FakeStorage(Directory dir) : super(filesDirectory: () async => dir);

  @override
  Future<List<MediaItem>> history() async => const [];

  @override
  Future<List<MediaItem>> favorites() async => const [];

  @override
  Future<SeriesProgress> seriesProgress(MediaItem series) async =>
      SeriesProgress.empty;
}

/// TMDB's genre lists: 20 movies and 20 series per genre, ids unique per
/// (type, genre).
class _FakeGenreTmdb {
  final asked = <String>[];
  bool down = false;

  Future<List<MediaItem>> call(String type, int genre) async {
    asked.add('$type:$genre');
    if (down) throw const SocketException('offline');
    final base = (type == 'movie' ? 1 : 2) * 1000000 + genre * 100;
    return [
      for (var i = 0; i < 20; i++)
        _title(
          base + i,
          type: type,
          // TV lists carry the TV genre; the engine folds it back.
          genres: [genre],
        ),
    ];
  }
}

/// The Reelish API's copy: the newer change wins, like the Worker.
class _FakeRemote implements DiscoveryPreferencesRemote {
  DiscoveryPreferences? stored;
  DateTime? storedAt;
  bool down = false;
  final fetched = <String>[];
  final pushed = <(String, DiscoveryPreferences)>[];

  /// While set, answers wait for it: a request still out.
  Completer<void>? hold;

  @override
  Future<DiscoveryPreferences?> fetch(String userId) async {
    if (down) throw const SocketException('offline');
    fetched.add(userId);
    // The answer is what was stored when the request arrived.
    final answer = stored;
    await hold?.future;
    return answer;
  }

  @override
  Future<DiscoveryPreferences?> push(
    String userId,
    DiscoveryPreferences preferences,
    DateTime changedAt,
  ) async {
    if (down) throw const SocketException('offline');
    pushed.add((userId, preferences));
    if (storedAt == null || changedAt.isAfter(storedAt!)) {
      stored = preferences;
      storedAt = changedAt;
    }
    return stored;
  }
}

void main() {
  group('Persisted data', () {
    test('data saved before preferences existed reads as before', () {
      final old = DiscoveryData.fromJson({
        'v': 1,
        'activity': <Object>[],
        'feedback': <Object>[],
        'genres': [_sciFi],
        'seeded': true,
      });
      expect(old.favoriteGenres, [_sciFi]);
      expect(old.onboarding, isNull);
      expect(old.personalization, isTrue);
      expect(old.preferencesUnsent, isFalse);
      // Nothing new is written for an account that changed nothing.
      expect(
        old.toJson().keys,
        unorderedEquals(['v', 'activity', 'feedback', 'genres', 'seeded']),
      );
    });

    test('preferences survive a round trip and a reset', () {
      final at = DateTime.utc(2026, 11, 13, 9);
      final data = DiscoveryData.empty.withPreferences(
        const DiscoveryPreferences(
          onboarding: OnboardingState.completed,
          genres: [_sciFi, _comedy],
          personalization: false,
        ),
        at,
      );
      final read = DiscoveryData.fromJson(data.toJson());
      expect(read.preferences, data.preferences);
      expect(read.preferencesChangedAt, at);
      expect(read.preferencesUnsent, isTrue);
      expect(read.reset().preferences, data.preferences);
    });

    test('unknown or malformed preference values are dropped', () {
      final prefs = DiscoveryPreferences.fromJson({
        'onboarding': 'maybe',
        'genres': [878, '35', -1, 878, 100000],
        'personalization': 'no',
      })!;
      expect(prefs.onboarding, isNull);
      expect(prefs.genres, [878]);
      expect(prefs.personalization, isTrue);
      expect(DiscoveryPreferences.fromJson('x'), isNull);
    });
  });

  group('Onboarding policy', () {
    final now = DateTime.utc(2026, 11, 13, 12);
    OnboardingNeed decide({
      DiscoveryPreferences preferences = const DiscoveryPreferences(),
      bool activity = false,
      bool remote = true,
      Duration? age = const Duration(minutes: 5),
    }) => OnboardingPolicy.decide(
      preferences: preferences,
      hasActivity: activity,
      remoteChecked: remote,
      accountCreatedAt: age == null ? null : now.subtract(age),
      now: now,
    );

    test('a brand-new account gets the full screen', () {
      expect(decide(), OnboardingNeed.fullScreen);
    });

    test('an existing account without preferences gets the card', () {
      expect(decide(age: const Duration(days: 90)), OnboardingNeed.prompt);
      expect(decide(age: null), OnboardingNeed.prompt);
      // New but already watching on this device: not a first run.
      expect(decide(activity: true), OnboardingNeed.prompt);
    });

    test('without the server answering, never the full screen', () {
      expect(decide(remote: false), OnboardingNeed.prompt);
    });

    test('an answered step, picked genres or personalisation off: nothing', () {
      for (final preferences in const [
        DiscoveryPreferences(onboarding: OnboardingState.skipped),
        DiscoveryPreferences(onboarding: OnboardingState.completed),
        DiscoveryPreferences(genres: [_sciFi]),
        DiscoveryPreferences(personalization: false),
      ]) {
        expect(decide(preferences: preferences), OnboardingNeed.none);
      }
    });
  });

  group('Genre catalog', () {
    const catalog = GenreCatalog.fallback;

    test('a picked genre is asked for on each side TMDB has it', () {
      expect(catalog.movieQueryId(_sciFi), _sciFi);
      expect(catalog.tvQueryId(_sciFi), 10765, reason: 'Sci-Fi & Fantasy');
      expect(catalog.tvQueryId(28), 10759, reason: 'Action & Adventure');
      expect(catalog.tvQueryId(_horror), isNull, reason: 'no TV horror genre');
      expect(catalog.movieQueryId(10762), isNull, reason: 'Kids is TV only');
      expect(catalog.tvQueryId(10762), 10762);
      expect(catalog.tvQueryId(99), isNull, reason: 'series rows are scripted');
    });

    test('TMDB lists decide what is offered and kept', () {
      final parsed = GenreCatalog(
        movie: GenreCatalog.parseList({
          'genres': [
            {'id': 878, 'name': 'Science Fiction'},
            {'id': 35, 'name': 'Comedy'},
            {'id': 'x', 'name': 'Broken'},
          ],
        })!,
        tv: GenreCatalog.parseList({'genres': <Object>[]}) ?? const {},
      );
      expect(parsed.pickable, [_comedy, _sciFi]);
      expect(parsed.valid([_sciFi, _horror, _sciFi]), [_sciFi]);
      expect(GenreCatalog.parseList({'nope': 1}), isNull);
    });
  });

  test(
    'Trending drops what the rows above show, unless too little is left',
    () {
      final trending = [for (var i = 0; i < 14; i++) _title(i)];
      final shown = trending.take(4);
      expect(HomeViewModel.distinctTrending(shown, trending), hasLength(10));
      expect(
        HomeViewModel.distinctTrending(trending.take(5), trending),
        trending,
        reason: 'nine left: the row stays whole',
      );
      expect(HomeViewModel.distinctTrending(const [], trending), trending);
    },
  );

  group('Controller', () {
    late Directory dir;
    late _FakeStorage storage;
    late DiscoveryStore store;
    late _FakeGenreTmdb genreTmdb;
    late _FakeRemote remote;
    var now = DateTime.utc(2026, 11, 13, 12);
    final seedAsked = <String>[];

    DiscoveryController controller({bool withRemote = true}) =>
        DiscoveryController(
          recommendationsFor: (seed) async {
            seedAsked.add(seed.id);
            return const [];
          },
          genreTitles: genreTmdb.call,
          remote: withRemote ? remote : null,
          storage: storage,
          store: store,
          clock: () => now,
          pushDelay: const Duration(hours: 1),
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      StorageService.debugResetWrites();
      DiscoveryStore.debugResetWrites();
      StorageService.onProgressSaved = null;
      dir = await Directory.systemTemp.createTemp('discovery_prefs_test');
      storage = _FakeStorage(dir);
      store = DiscoveryStore(filesDirectory: () async => dir);
      genreTmdb = _FakeGenreTmdb();
      remote = _FakeRemote();
      seedAsked.clear();
      now = DateTime.utc(2026, 11, 13, 12);
    });

    tearDown(() async {
      StorageService.onProgressSaved = null;
      await dir.delete(recursive: true);
    });

    test(
      'genres picked at onboarding alone fill Home with genre rows',
      () async {
        final c = controller();
        await c.bindUser('alice');
        await c.preferencesSettled;
        await c.completeOnboarding([_sciFi, _western]);
        await c.refresh();

        final titles = c.sections.map((s) => s.title).toList();
        expect(titles.first, 'Picked for your genres');
        expect(titles, contains('Because you like science fiction'));
        expect(titles, contains('Because you like western'));
        // Two genres, movies and series each, and no seed request.
        expect(
          genreTmdb.asked,
          unorderedEquals([
            'movie:$_sciFi',
            'series:10765',
            'movie:$_western',
            'series:$_western',
          ]),
        );
        expect(seedAsked, isEmpty);

        // No title appears in two rows, and a genre row mixes both types.
        final keys = [
          for (final s in c.sections)
            for (final item in s.items) '${item.type}:${item.id}',
        ];
        expect(keys.toSet(), hasLength(keys.length));
        final sciFi = c.sections.firstWhere(
          (s) => s.title == 'Because you like science fiction',
        );
        expect(sciFi.items.map((i) => i.type).toSet(), {'movie', 'series'});
        expect(
          sciFi.reasonFor(sciFi.items.first),
          'Based on your preferred genres',
        );

        // A second refresh within 6 hours asks nothing again.
        genreTmdb.asked.clear();
        await c.refresh();
        expect(genreTmdb.asked, isEmpty);
        c.dispose();
      },
    );

    test('the strongest picked genre always, the others day by day', () {
      final profile = TasteProfile.build(
        DiscoveryData.empty.withFavoriteGenres([_comedy, _horror, _sciFi]),
        now: now,
      );
      final picked = [_comedy, _horror, _sciFi];
      final today = DiscoveryController.genresToQuery(profile, picked, now);
      final tomorrow = DiscoveryController.genresToQuery(
        profile,
        picked,
        now.add(const Duration(days: 1)),
      );
      expect(today, hasLength(2));
      expect(today.first, tomorrow.first);
      expect(today.last, isNot(tomorrow.last));
      expect(
        DiscoveryController.genresToQuery(profile, const [], now),
        isEmpty,
      );
    });

    test('failed genre requests leave rows from what Home has', () async {
      genreTmdb.down = true;
      final c = controller(withRemote: false);
      await c.bindUser('alice');
      await c.setFavoriteGenres([_comedy]);
      await c.refresh(pool: [for (var i = 0; i < 10; i++) _title(500 + i)]);
      expect(c.sections.single.title, 'Picked for your genres');
      c.dispose();
    });

    test(
      'personalisation off: no rows, no requests, nothing learned',
      () async {
        final c = controller(withRemote: false)..startRecording();
        await c.bindUser('alice');
        await c.setFavoriteGenres([_sciFi]);
        await c.refresh();
        expect(c.sections, isNotEmpty);

        await c.setPersonalization(false);
        expect(c.sections, isEmpty);
        genreTmdb.asked.clear();
        await c.refresh(force: true);
        expect(c.sections, isEmpty);
        expect(genreTmdb.asked, isEmpty);
        StorageService.onProgressSaved?.call((
          item: _title(9),
          positionMs: 90 * 60000,
          durationMs: 100 * 60000,
          episode: null,
        ));
        expect(c.data.activity, isEmpty);

        // Back on: rows are built again, not the ones from before.
        await c.setPersonalization(true);
        await c.refresh();
        expect(c.sections, isNotEmpty);
        expect(genreTmdb.asked, isNotEmpty);
        c.dispose();
      },
    );

    test(
      'preferences reach the account and come back on another device',
      () async {
        final phone = controller();
        await phone.bindUser('alice');
        await phone.preferencesSettled;
        expect(phone.remoteChecked, isTrue);
        await phone.completeOnboarding([_sciFi]);
        expect(phone.data.preferencesUnsent, isTrue);
        await phone.syncPreferences();
        expect(phone.data.preferencesUnsent, isFalse);
        expect(remote.stored?.genres, [_sciFi]);
        phone.dispose();

        // A fresh device for the same account: nothing local, the server's
        // copy is taken, and the step is not asked again.
        SharedPreferences.setMockInitialValues({});
        DiscoveryStore.debugResetWrites();
        final tv = controller();
        await tv.bindUser('alice');
        await tv.preferencesSettled;
        expect(tv.favoriteGenres, [_sciFi]);
        expect(tv.data.onboarding, OnboardingState.completed);
        expect(tv.onboardingNeed(accountCreatedAt: now), OnboardingNeed.none);
        tv.dispose();
      },
    );

    test('a newer change from another device replaces this one', () async {
      final c = controller();
      await c.bindUser('alice');
      await c.preferencesSettled;
      await c.setFavoriteGenres([_comedy]);
      await c.syncPreferences();
      // Another device changes them later.
      remote
        ..stored = const DiscoveryPreferences(
          onboarding: OnboardingState.completed,
          genres: [_horror],
        )
        ..storedAt = now.add(const Duration(minutes: 1));
      await c.syncPreferences();
      expect(c.favoriteGenres, [_horror]);

      // An offline change made before theirs loses when it is finally sent.
      now = now.subtract(const Duration(minutes: 30));
      remote.down = true;
      await c.setFavoriteGenres([_western]);
      await c.syncPreferences();
      expect(c.data.preferencesUnsent, isTrue, reason: 'kept to send');
      remote.down = false;
      await c.syncPreferences();
      expect(c.favoriteGenres, [_horror], reason: 'the newer change wins');
      expect(c.data.preferencesUnsent, isFalse);
      c.dispose();
    });

    test('genres picked before sync existed become the account\'s', () async {
      await store.update('alice', (data) => data.withFavoriteGenres([_comedy]));
      final c = controller();
      await c.bindUser('alice');
      await c.preferencesSettled;
      expect(remote.stored?.genres, [_comedy]);
      expect(c.onboardingNeed(), OnboardingNeed.none);
      c.dispose();
    });

    test('offline at launch: the card, never the full screen', () async {
      remote.down = true;
      final c = controller();
      await c.bindUser('alice');
      await c.preferencesSettled;
      expect(c.remoteChecked, isFalse);
      expect(c.onboardingNeed(accountCreatedAt: now), OnboardingNeed.prompt);
      c.dispose();
    });

    test('skipping is remembered and not offered again', () async {
      final c = controller();
      await c.bindUser('alice');
      await c.preferencesSettled;
      expect(
        c.onboardingNeed(accountCreatedAt: now),
        OnboardingNeed.fullScreen,
      );
      await c.skipOnboarding();
      await c.syncPreferences();
      expect(c.onboardingNeed(accountCreatedAt: now), OnboardingNeed.none);
      expect(remote.stored?.onboarding, OnboardingState.skipped);
      c.dispose();
    });

    test('one account never sees or sends another\'s preferences', () async {
      final c = controller();
      await c.bindUser('alice');
      await c.preferencesSettled;
      await c.completeOnboarding([_sciFi]);
      await c.syncPreferences();
      await c.refresh();
      expect(c.sections, isNotEmpty);

      remote.stored = null;
      remote.storedAt = null;
      await c.bindUser('bob');
      expect(c.sections, isEmpty);
      expect(c.favoriteGenres, isEmpty);
      await c.preferencesSettled;
      expect(c.favoriteGenres, isEmpty);
      expect(remote.fetched.last, 'bob');
      expect(
        remote.pushed.where((push) => push.$1 == 'bob'),
        isEmpty,
        reason: 'bob changed nothing',
      );
      c.dispose();
    });

    test('an account bound during a sync still gets its own', () async {
      final c = controller();
      await c.bindUser('alice');
      await c.preferencesSettled;
      remote.stored = const DiscoveryPreferences(genres: [_horror]);
      remote.storedAt = now;
      // Alice's sync is still out when Bob signs in.
      final hold = remote.hold = Completer<void>();
      final alice = c.syncPreferences();
      await Future<void>.delayed(Duration.zero);
      expect(remote.fetched.last, 'alice', reason: 'her request is out');
      await c.bindUser('bob');
      // The fake keeps one record: from here on it is Bob's, and he has none.
      final aliceStored = remote.stored;
      remote
        ..hold = null
        ..stored = null
        ..storedAt = null;
      // Alice's answer arrives late, while Bob is bound.
      final late = hold.future;
      hold.complete();
      await late;
      expect(aliceStored?.genres, [_horror]);
      await Future.wait([alice, c.preferencesSettled]);
      expect(remote.fetched.last, 'bob');
      expect(c.favoriteGenres, isEmpty, reason: 'nothing of alice\'s');
      expect(c.remoteChecked, isTrue);
      c.dispose();
    });

    test('a reset forgets viewing but keeps the preferences', () async {
      final c = controller(withRemote: false);
      await c.bindUser('alice');
      await c.completeOnboarding([_sciFi]);
      await c.setPersonalization(false);
      await c.reset();
      expect(c.favoriteGenres, [_sciFi]);
      expect(c.personalization, isFalse);
      expect(c.data.onboarding, OnboardingState.completed);
      c.dispose();
    });
  });

  test('a genre row needs six titles', () {
    final profile = TasteProfile.build(
      DiscoveryData.empty.withFavoriteGenres([_western]),
      now: DateTime.utc(2026, 11, 13),
    );
    final sections = DiscoveryEngine.build(
      profile,
      genreLists: [
        GenreCandidates(_western, [
          for (var i = 0; i < 5; i++) _title(i, genres: [_western]),
        ]),
      ],
    );
    expect(
      sections.where((s) => s.kind == DiscoverySectionKind.likedGenre),
      isEmpty,
    );
  });
}
