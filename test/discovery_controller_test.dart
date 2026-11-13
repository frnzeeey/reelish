import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/discovery/discovery_controller.dart';
import 'package:onfeed/src/discovery/discovery_data.dart';
import 'package:onfeed/src/discovery/discovery_engine.dart';
import 'package:onfeed/src/discovery/discovery_store.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sciFi = 878, _comedy = 35;

MediaItem _title(
  int id, {
  String type = 'movie',
  List<int> genres = const [_sciFi],
  int resumeMs = 0,
  int durationMs = 0,
}) => MediaItem(
  id: '$id',
  type: type,
  name: 'Title $id',
  genreIds: genres,
  rating: '7.8',
  voteCount: 3000,
  popularity: 30,
  releaseDate: '2021-03-01',
  resumeMs: resumeMs,
  durationMs: durationMs,
);

const _minute = 60000;

class _FakeStorage extends StorageService {
  _FakeStorage(Directory dir) : super(filesDirectory: () async => dir);

  List<MediaItem> historyItems = [];
  List<MediaItem> myList = [];

  @override
  Future<List<MediaItem>> history() async => historyItems;

  @override
  Future<List<MediaItem>> favorites() async => myList;

  @override
  Future<SeriesProgress> seriesProgress(MediaItem series) async =>
      SeriesProgress.empty;
}

class _FakeTmdb {
  final asked = <String>[];
  bool down = false;
  List<MediaItem> Function(MediaItem seed) answer = (seed) => [
    for (var i = 0; i < 20; i++)
      _title(int.parse(seed.id) * 100 + i, genres: [_sciFi]),
  ];

  Future<List<MediaItem>> call(MediaItem seed) async {
    asked.add(seed.id);
    if (down) throw const SocketException('offline');
    return answer(seed);
  }
}

void main() {
  late Directory dir;
  late _FakeStorage storage;
  late DiscoveryStore store;
  late _FakeTmdb tmdb;
  var now = DateTime.utc(2026, 6, 1, 12);

  DiscoveryController controller() => DiscoveryController(
    recommendationsFor: tmdb.call,
    storage: storage,
    store: store,
    clock: () => now,
  );

  /// Titles Home already has loaded, as the catalog pool.
  final pool = [
    for (var i = 0; i < 12; i++) _title(5000 + i, genres: [_comedy]),
  ];

  List<String> shownKeys(DiscoveryController c) => [
    for (final s in c.sections)
      for (final item in s.items) '${item.type}:${item.id}',
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
    DiscoveryStore.debugResetWrites();
    StorageService.onProgressSaved = null;
    dir = await Directory.systemTemp.createTemp('discovery_test');
    storage = _FakeStorage(dir);
    store = DiscoveryStore(filesDirectory: () async => dir);
    tmdb = _FakeTmdb();
    now = DateTime.utc(2026, 6, 1, 12);
  });

  tearDown(() async {
    StorageService.onProgressSaved = null;
    await dir.delete(recursive: true);
  });

  test(
    'a brand-new viewer gets no personalised rows and no requests',
    () async {
      final c = controller();
      await c.bindUser('alice');
      await c.refresh(pool: pool);
      expect(c.loaded, isTrue);
      expect(c.sections, isEmpty);
      expect(tmdb.asked, isEmpty);
    },
  );

  test('watch history kept before discovery seeds the first account', () async {
    storage.historyItems = [
      _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
      _title(2, resumeMs: 80 * _minute, durationMs: 100 * _minute),
      // A failed start: never counts.
      _title(3, resumeMs: 10 * 1000, durationMs: 100 * _minute),
    ];
    final c = controller();
    await c.bindUser('alice');
    expect(c.data.activity.keys, unorderedEquals(['movie:1', 'movie:2']));
    expect(c.data.activity['movie:1']!.completions, 1);
    await c.refresh(pool: pool);
    expect(c.sections.first.kind, DiscoverySectionKind.forYou);
    expect(tmdb.asked, unorderedEquals(['1', '2']));
    // Watched titles are never recommended back.
    expect(shownKeys(c), isNot(contains('movie:1')));
    expect(shownKeys(c), isNot(contains('movie:2')));
    final keys = shownKeys(c);
    expect(keys.toSet().length, keys.length);
  });

  test('a second account on the device does not inherit the first one\'s '
      'history or rows', () async {
    storage.historyItems = [
      _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
    ];
    final c = controller();
    await c.bindUser('alice');
    await c.refresh(pool: pool);
    expect(c.sections, isNotEmpty);

    await c.bindUser('bob');
    expect(c.sections, isEmpty, reason: 'nothing of Alice shown to Bob');
    expect(c.data.activity, isEmpty);
    await c.refresh(pool: pool);
    expect(c.sections, isEmpty);

    // Alice's rows come back from her own cache, without a request.
    final asked = tmdb.asked.length;
    await c.bindUser('alice');
    expect(c.sections, isNotEmpty);
    expect(tmdb.asked.length, asked);
  });

  test(
    'rows are cached: no requests again until tastes change or they age',
    () async {
      storage.historyItems = [
        _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
      ];
      final c = controller();
      await c.bindUser('alice');
      await Future.wait([c.refresh(pool: pool), c.refresh(pool: pool)]);
      expect(tmdb.asked, ['1'], reason: 'simultaneous refreshes share one');
      await c.refresh(pool: pool);
      expect(tmdb.asked, ['1'], reason: 'fresh rows are not rebuilt');

      // Restarted offline: the last rows show at once, with no request.
      tmdb.down = true;
      final restarted = controller();
      await restarted.bindUser('alice');
      expect(restarted.sections, isNotEmpty);
      expect(tmdb.asked, ['1']);

      // Hours later, still offline and with nothing loaded: rows are kept.
      now = now.add(const Duration(hours: 7));
      await restarted.refresh();
      expect(restarted.sections, isNotEmpty);
    },
  );

  test('TMDB unavailable: rows come from what Home already has', () async {
    tmdb.down = true;
    storage.historyItems = [
      _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
    ];
    final c = controller();
    await c.bindUser('alice');
    await c.refresh(pool: [for (var i = 0; i < 12; i++) _title(7000 + i)]);
    expect(c.sections.single.kind, DiscoverySectionKind.forYou);
  });

  test(
    'empty TMDB recommendations and an empty catalog show nothing broken',
    () async {
      tmdb.answer = (_) => const [];
      storage.historyItems = [
        _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
      ];
      final c = controller();
      await c.bindUser('alice');
      await c.refresh();
      expect(c.sections, isEmpty);
    },
  );

  test(
    'records what the player saves, only for the signed-in account',
    () async {
      final c = controller()..startRecording();
      await c.bindUser('alice');
      final item = _title(42, genres: [_comedy]);
      // A sample: too short to count.
      StorageService.onProgressSaved!((
        item: item,
        positionMs: 30 * 1000,
        durationMs: 100 * _minute,
        episode: null,
      ));
      expect(c.data.activity, isEmpty);
      StorageService.onProgressSaved!((
        item: item,
        positionMs: 95 * _minute,
        durationMs: 100 * _minute,
        episode: null,
      ));
      expect(c.data.activity['movie:42']!.completions, 1);
      // Saved for Alice, and only Alice.
      await Future<void>.delayed(Duration.zero);
      expect((await store.load('alice')).activity.keys, ['movie:42']);
      expect((await store.load('bob')).activity, isEmpty);

      await c.bindUser(null);
      StorageService.onProgressSaved!((
        item: _title(43),
        positionMs: 95 * _minute,
        durationMs: 100 * _minute,
        episode: null,
      ));
      expect((await store.load('alice')).activity.keys, ['movie:42']);

      c.dispose();
      expect(StorageService.onProgressSaved, isNull);
    },
  );

  test('a title started since the rows were built leaves them', () async {
    storage.historyItems = [
      _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
    ];
    final c = controller()..startRecording();
    await c.bindUser('alice');
    await c.refresh(pool: pool);
    final shown = c.sections.first.items.first;
    StorageService.onProgressSaved!((
      item: shown,
      positionMs: 20 * _minute,
      durationMs: 100 * _minute,
      episode: null,
    ));
    await c.refresh(pool: pool);
    expect(shownKeys(c), isNot(contains('movie:${shown.id}')));
    c.dispose();
  });

  test('feedback hides at once, can be undone and persists', () async {
    storage.historyItems = [
      _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
    ];
    final c = controller();
    await c.bindUser('alice');
    await c.refresh(pool: pool);
    final item = c.sections.first.items.first;
    final key = 'movie:${item.id}';

    await c.giveFeedback(FeedbackKind.notInterested, item);
    expect(shownKeys(c), isNot(contains(key)));
    final again = controller();
    await again.bindUser('alice');
    expect(again.data.feedback[key]!.kind, FeedbackKind.notInterested);
    expect(shownKeys(again), isNot(contains(key)));

    await c.undoFeedback(item);
    expect(c.data.feedback, isEmpty);
  });

  test(
    'repeated Not interested adapts the rows and never breaks them',
    () async {
      storage.historyItems = [
        _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
      ];
      final c = controller();
      await c.bindUser('alice');
      await c.refresh(pool: pool);
      final first = {
        for (final item in c.sections.first.items) 'movie:${item.id}',
      };
      for (final item in [...c.sections.first.items]) {
        await c.giveFeedback(FeedbackKind.notInterested, item);
      }
      await c.refresh(pool: pool, force: true);
      // New titles take their place: the hidden genre is lowered, not banned.
      expect(c.sections, isNotEmpty);
      expect(shownKeys(c).toSet().intersection(first), isEmpty);
      // Hiding everything there is leaves no row at all, never a short or
      // broken one.
      for (var round = 0; round < 5 && c.sections.isNotEmpty; round++) {
        for (final item in [...c.sections.expand((s) => s.items)]) {
          await c.giveFeedback(FeedbackKind.notInterested, item);
        }
        await c.refresh(pool: pool, force: true);
        for (final s in c.sections) {
          expect(
            s.items.length,
            greaterThanOrEqualTo(DiscoveryEngine.minRowSize),
          );
        }
      }
      await c.showHiddenAgain();
      expect(
        c.data.feedback.values.where(
          (f) => f.kind == FeedbackKind.notInterested,
        ),
        isEmpty,
      );
    },
  );

  test('picked genres give a new viewer rows from the catalog', () async {
    final c = controller();
    await c.bindUser('alice');
    await c.setFavoriteGenres([_comedy]);
    await c.refresh(pool: pool);
    expect(c.sections.single.title, 'Picked for your genres');
    expect(tmdb.asked, isEmpty);
  });

  test(
    'reset forgets viewing and rows, and history is not read again',
    () async {
      storage.historyItems = [
        _title(1, resumeMs: 95 * _minute, durationMs: 100 * _minute),
      ];
      final c = controller();
      await c.bindUser('alice');
      await c.setFavoriteGenres([_sciFi]);
      await c.refresh(pool: pool);
      expect(c.sections, isNotEmpty);

      await c.reset();
      expect(c.sections, isEmpty);
      expect(c.data.activity, isEmpty);
      expect(c.data.favoriteGenres, [_sciFi]);
      expect(await store.cachedSections('alice'), isNull);

      final restarted = controller();
      await restarted.bindUser('alice');
      expect(restarted.data.activity, isEmpty, reason: 'history not re-read');
    },
  );

  test('signed out: nothing is loaded, recorded or requested', () async {
    final c = controller();
    await c.bindUser(null);
    await c.refresh(pool: pool);
    await c.giveFeedback(FeedbackKind.moreLikeThis, _title(1));
    expect(c.sections, isEmpty);
    expect(tmdb.asked, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getKeys(),
      isNot(contains(startsWith('onfeed.discovery.v1.'))),
    );
  });
}
