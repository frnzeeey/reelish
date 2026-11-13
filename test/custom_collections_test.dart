import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/collections/collection_models.dart';
import 'package:onfeed/src/collections/collection_store.dart';
import 'package:onfeed/src/collections/smart_collections.dart';
import 'package:onfeed/src/desktop/desktop_collections.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/collections/collection_pages.dart';
import 'package:onfeed/src/screens/tv/tv_collections.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/viewmodels/library_view_model.dart';
import 'package:onfeed/src/widgets/collections/collection_actions.dart';
import 'package:onfeed/src/widgets/tv/tv_poster_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _day = 24 * 60 * 60 * 1000;

const _dune = MediaItem(
  id: '438631',
  type: 'movie',
  name: 'Dune',
  poster: 'https://image.tmdb.org/t/p/w500/dune.jpg',
  year: '2021',
);
const _arrival = MediaItem(
  id: '329865',
  type: 'movie',
  name: 'Arrival',
  poster: 'https://image.tmdb.org/t/p/w500/arrival.jpg',
  year: '2016',
);
const _dark = MediaItem(
  id: '70523',
  type: 'series',
  name: 'Dark',
  poster: 'https://image.tmdb.org/t/p/w500/dark.jpg',
  year: '2017',
);

/// A movie and a series that share a TMDB id.
const _sameIdSeries = MediaItem(id: '438631', type: 'series', name: 'Other');

class _Clock {
  int now = 1000 * _day;
  int call() => now;
}

Future<CollectionStore> _store(String account, {_Clock? clock}) async {
  final store = CollectionStore(clock: (clock ?? _Clock()).call)
    ..useAccount(account);
  await store.ready;
  return store;
}

Future<Map<String, dynamic>> _saved(String account) async {
  final raw = (await SharedPreferences.getInstance()).getString(
    CollectionStore.storageKey(account),
  );
  return jsonDecode(raw!) as Map<String, dynamic>;
}

List<String> _names(Iterable<CollectionEntry> entries) => [
  for (final entry in entries) entry.name,
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
    StorageService.debugResetAccount();
  });

  group('collections', () {
    test('are created, edited and deleted', () async {
      final store = await _store('a');
      final weekend = await store.createCollection(
        name: '  Weekend movies ',
        description: 'Easy watching',
      );
      expect(weekend.name, 'Weekend movies');
      expect(store.library.collectionsIn(null).single.name, 'Weekend movies');

      await store.editCollection(weekend.id, name: 'Weekend', description: '');
      expect(store.library.collection(weekend.id)!.name, 'Weekend');
      expect(store.library.collection(weekend.id)!.description, isEmpty);

      await store.add(_dune, weekend.id);
      await store.deleteCollection(weekend.id);
      expect(store.library.collections, isEmpty);
      // Kept as a deletion mark; its titles are dropped with it.
      final saved = await _saved('a');
      expect((saved['collections'] as List).single['deleted'], isTrue);
      expect(saved['entries'], isEmpty);
    });

    test('names are required and bounded', () async {
      final store = await _store('a');
      expect(
        () => store.createCollection(name: '   '),
        throwsA(isA<CollectionInputError>()),
      );
      expect(
        () => store.createCollection(name: 'x' * 81),
        throwsA(isA<CollectionInputError>()),
      );
      expect(
        () => store.createCollection(name: 'ok', description: 'x' * 301),
        throwsA(isA<CollectionInputError>()),
      );
      expect(store.library.collections, isEmpty);
    });

    test('a title is listed once however often it is added, and by kind '
        'and id', () async {
      final store = await _store('a');
      final scifi = await store.createCollection(name: 'Sci-fi');
      await store.add(_dune, scifi.id);
      await store.add(_dune, scifi.id);
      await store.add(_sameIdSeries, scifi.id);
      expect(store.library.countOf(scifi.id), 2);
      expect(
        store.library.collectionsWith(_dune),
        store.library.collectionsWith(_sameIdSeries),
      );
      await store.remove(_sameIdSeries, scifi.id);
      expect(_names(store.library.entriesOf(scifi.id)), ['Dune']);
    });

    test('one title can be in several collections', () async {
      final store = await _store('a');
      final scifi = await store.createCollection(name: 'Sci-fi');
      final family = await store.createCollection(name: 'Family');
      await store.setMembership(_arrival, add: {scifi.id, family.id});
      expect(store.library.collectionsWith(_arrival), {scifi.id, family.id});
      await store.setMembership(_arrival, remove: {family.id});
      expect(store.library.collectionsWith(_arrival), {scifi.id});
    });

    test('a missing collection changes nothing', () async {
      final store = await _store('a');
      final scifi = await store.createCollection(name: 'Sci-fi');
      await expectLater(
        store.setMembership(_dune, add: {scifi.id, 'gone'}),
        throwsA(isA<CollectionInputError>()),
      );
      expect(store.library.countOf(scifi.id), 0);
    });

    test('removed then added again comes back', () async {
      final clock = _Clock();
      final store = await _store('a', clock: clock);
      final scifi = await store.createCollection(name: 'Sci-fi');
      await store.add(_dune, scifi.id);
      clock.now += 1000;
      await store.remove(_dune, scifi.id);
      expect(store.library.countOf(scifi.id), 0);
      clock.now += 1000;
      await store.add(_dune, scifi.id);
      final entry = store.library.entriesOf(scifi.id).single;
      expect(entry.addedAt, clock.now);
    });

    test('sorts by when added, title and year', () async {
      final clock = _Clock();
      final store = await _store('a', clock: clock);
      final list = await store.createCollection(name: 'List');
      for (final item in [_arrival, _dark, _dune]) {
        clock.now += 1000;
        await store.add(item, list.id);
      }
      String names(CollectionSort sort) =>
          _names(store.library.entriesOf(list.id, sort: sort)).join(',');
      expect(names(CollectionSort.newest), 'Dune,Dark,Arrival');
      expect(names(CollectionSort.oldest), 'Arrival,Dark,Dune');
      expect(names(CollectionSort.title), 'Arrival,Dark,Dune');
      expect(names(CollectionSort.year), 'Dune,Dark,Arrival');
    });

    test('reorder moves one place and stops at the ends', () async {
      final store = await _store('a');
      final a = await store.createCollection(name: 'A');
      await store.createCollection(name: 'B');
      final c = await store.createCollection(name: 'C');
      List<String> order() => [
        for (final c in store.library.collectionsIn(null)) c.name,
      ];
      await store.reorderCollection(c.id, -1);
      expect(order(), ['A', 'C', 'B']);
      await store.reorderCollection(a.id, -1);
      expect(order(), ['A', 'C', 'B']);
      await store.reorderCollection(a.id, 1);
      expect(order(), ['C', 'A', 'B']);
    });

    test('the cover is the chosen title, then the newest', () async {
      final clock = _Clock();
      final store = await _store('a', clock: clock);
      final list = await store.createCollection(name: 'List');
      for (final item in [_arrival, _dark, _dune]) {
        clock.now += 1000;
        await store.add(item, list.id);
      }
      MediaCollection current() => store.library.collection(list.id)!;
      expect(store.library.coverArtOf(current(), count: 1), [_dune.poster]);
      await store.setCover(list.id, _arrival);
      expect(store.library.coverArtOf(current()).first, _arrival.poster);
      expect(store.library.coverArtOf(current()), hasLength(3));
      await store.setCover(list.id, null);
      expect(store.library.coverArtOf(current(), count: 1), [_dune.poster]);
    });
  });

  group('folders', () {
    test('hold collections, and moving keeps the titles', () async {
      final store = await _store('a');
      final movies = await store.createFolder('Movies');
      final scifi = await store.createCollection(name: 'Sci-fi');
      await store.add(_dune, scifi.id);
      await store.moveCollection(scifi.id, movies.id);
      expect(store.library.collectionsIn(null), isEmpty);
      expect(store.library.collectionsIn(movies.id).single.name, 'Sci-fi');
      expect(store.library.countOf(scifi.id), 1);
      await store.moveCollection(scifi.id, null);
      expect(store.library.collectionsIn(null).single.name, 'Sci-fi');
    });

    test('a collection cannot move into a deleted folder', () async {
      final store = await _store('a');
      final folder = await store.createFolder('Old');
      final list = await store.createCollection(name: 'List');
      await store.deleteFolder(folder.id);
      await expectLater(
        store.moveCollection(list.id, folder.id),
        throwsA(isA<CollectionInputError>()),
      );
    });

    test('deleting a folder keeps its collections unless asked', () async {
      final store = await _store('a');
      final movies = await store.createFolder('Movies');
      final scifi = await store.createCollection(
        name: 'Sci-fi',
        folderId: movies.id,
      );
      await store.add(_dune, scifi.id);
      await store.deleteFolder(movies.id);
      expect(store.library.folders, isEmpty);
      expect(store.library.collectionsIn(null).single.id, scifi.id);
      expect(store.library.countOf(scifi.id), 1);

      final shows = await store.createFolder('Shows');
      final dark = await store.createCollection(
        name: 'Dark things',
        folderId: shows.id,
      );
      await store.deleteFolder(shows.id, withCollections: true);
      expect(store.library.collection(dark.id), isNull);
      expect(store.library.collection(scifi.id), isNotNull);
    });

    test('a collection whose folder is gone shows at the top level', () {
      final library = CollectionLibrary(
        collections: [
          const MediaCollection(
            id: 'c',
            name: 'Orphan',
            folderId: 'missing',
            order: 1,
            createdAt: 1,
            updatedAt: 1,
          ),
        ],
      );
      expect(library.collectionsIn(null).single.name, 'Orphan');
    });
  });

  group('storage', () {
    test('survives a restart', () async {
      final store = await _store('a');
      final folder = await store.createFolder('Movies');
      final list = await store.createCollection(
        name: 'Sci-fi',
        folderId: folder.id,
      );
      await store.add(_dune, list.id);
      final again = await _store('a');
      expect(again.library.folders.single.name, 'Movies');
      expect(again.library.collectionsIn(folder.id).single.name, 'Sci-fi');
      final entry = again.library.entriesOf(list.id).single;
      expect(
        (entry.type, entry.id, entry.name, entry.poster, entry.year),
        ('movie', _dune.id, 'Dune', _dune.poster, '2021'),
      );
    });

    test('each account has its own library', () async {
      final store = await _store('a');
      await store.createCollection(name: 'Mine');
      store.useAccount('b');
      await store.ready;
      expect(store.library.collections, isEmpty);
      await store.createCollection(name: 'Theirs');
      store.useAccount(null);
      expect(store.library.collections, isEmpty);
      await expectLater(
        store.createCollection(name: 'Nobody'),
        throwsA(isA<CollectionInputError>()),
      );
      store.useAccount('a');
      await store.ready;
      expect([for (final c in store.library.collections) c.name], ['Mine']);
    });

    test('a change made for one account is never saved to another', () async {
      final store = await _store('a');
      final list = await store.createCollection(name: 'Mine');
      final pending = store.add(_dune, list.id);
      store.useAccount('b');
      await expectLater(pending, throwsA(isA<CollectionInputError>()));
      await store.ready;
      expect(
        (await SharedPreferences.getInstance()).getString(
          CollectionStore.storageKey('b'),
        ),
        isNull,
      );
    });

    test('unreadable records are skipped and the rest load', () async {
      SharedPreferences.setMockInitialValues({
        CollectionStore.storageKey('a'): jsonEncode({
          'collections': [
            {'id': 'ok', 'name': 'Fine', 'order': 1},
            {'name': 'No id'},
            7,
          ],
          'entries': [
            {'collectionId': 'ok', 'type': 'movie', 'id': '1', 'name': 'One'},
            {'collectionId': 'ok', 'type': 'person', 'id': '2'},
          ],
        }),
      });
      final store = await _store('a');
      expect([for (final c in store.library.collections) c.name], ['Fine']);
      expect(store.library.countOf('ok'), 1);
    });

    test('a corrupt library loads empty', () async {
      SharedPreferences.setMockInitialValues({
        CollectionStore.storageKey('a'): '{not json',
      });
      final store = await _store('a');
      expect(store.loaded, isTrue);
      expect(store.library.isEmpty, isTrue);
    });

    test('old deletion marks are dropped on the next save', () async {
      final clock = _Clock();
      final store = await _store('a', clock: clock);
      final old = await store.createCollection(name: 'Old');
      await store.deleteCollection(old.id);
      clock.now += 401 * _day;
      await store.createCollection(name: 'New');
      final saved = await _saved('a');
      expect([for (final c in saved['collections']) c['name']], ['New']);
    });
  });

  group('My list dates', () {
    test(
      'a title added to My list is dated; older entries still load',
      () async {
        StorageService.clock = () => 5 * _day;
        addTearDown(
          () =>
              StorageService.clock = () =>
                  DateTime.now().millisecondsSinceEpoch,
        );
        SharedPreferences.setMockInitialValues({
          'onfeed.favorites': [jsonEncode(_arrival.toJson())],
        });
        final storage = StorageService();
        await storage.toggleFavorite(_dune);
        final list = await storage.favorites();
        expect(
          [for (final i in list) (i.name, i.savedAt)],
          [('Dune', 5 * _day), ('Arrival', 0)],
        );
        // Trakt's watchlist sync does not date what it brings in.
        await storage.updateFavorites(add: [_dark]);
        expect((await storage.favorites()).last.savedAt, 0);
      },
    );
  });

  group('smart collections', () {
    const now = 100 * _day;
    CollectionLibrary library({required int addedAt}) {
      return CollectionLibrary(
        collections: const [
          MediaCollection(
            id: 'c',
            name: 'C',
            order: 1,
            createdAt: 1,
            updatedAt: 1,
          ),
        ],
        entries: [CollectionEntry.of('c', _dark, addedAt)],
      );
    }

    List<String> names(List<MediaItem> items) => [
      for (final i in items) i.name,
    ];

    test('Recently added: dated saves of the last 30 days, newest first', () {
      final sources = SmartCollectionSources(
        favorites: [
          _dune.copyWith(savedAt: now - 2 * _day),
          // Saved before dates were recorded: never "recent".
          _arrival,
        ],
        collections: library(addedAt: now - _day),
      );
      expect(
        names(
          SmartCollections.of(SmartCollection.recentlyAdded, sources, now: now),
        ),
        ['Dark', 'Dune'],
      );
      final later = SmartCollections.of(
        SmartCollection.recentlyAdded,
        sources,
        now: now + 30 * _day,
      );
      expect(names(later), isEmpty);
    });

    test('My list is My list, unchanged', () {
      final sources = SmartCollectionSources(favorites: [_arrival, _dune]);
      expect(
        names(SmartCollections.of(SmartCollection.myList, sources, now: now)),
        ['Arrival', 'Dune'],
      );
    });

    test('Not started: saved titles without real viewing', () {
      final sources = SmartCollectionSources(
        favorites: [_dune, _arrival],
        collections: library(addedAt: now),
        history: [
          // A failed start of 30 seconds does not count.
          _dune.copyWith(resumeMs: 30000, durationMs: 9000000),
          // A series whose episode was watched past 90 seconds does, even
          // with the history's own position at the next episode's start.
          _dark.copyWith(resumeMs: 1000),
        ],
        seriesProgress: const {
          'series:70523': SeriesProgress(
            last: (season: 1, episode: 1),
            episodes: {
              '1:1': EpisodeProgress(positionMs: 600000, durationMs: 3000000),
            },
          ),
        },
      );
      expect(
        names(
          SmartCollections.of(SmartCollection.unwatched, sources, now: now),
        ),
        ['Dune', 'Arrival'],
      );
    });

    test('Finished: watched to the end, not in progress', () {
      final sources = SmartCollectionSources(
        history: [
          _dune.copyWith(resumeMs: 8900000, durationMs: 9000000),
          _arrival.copyWith(resumeMs: 600000, durationMs: 7000000),
        ],
      );
      expect(
        names(SmartCollections.of(SmartCollection.finished, sources, now: now)),
        ['Dune'],
      );
    });
  });

  group('library view model', () {
    test('follows collection changes without reloading', () async {
      final store = await _store('a');
      final model = LibraryViewModel(
        storage: StorageService(),
        collections: store,
      );
      addTearDown(model.dispose);
      await model.load();
      var notified = 0;
      model.addListener(() => notified++);
      final list = await store.createCollection(name: 'List');
      await store.add(_dune, list.id);
      expect(notified, greaterThanOrEqualTo(2));
      expect(names(model.smart(SmartCollection.unwatched)), ['Dune']);
    });
  });

  group('screens', () {
    Future<CollectionStore> instance(String account) async {
      final store = CollectionStore()..useAccount(account);
      await store.ready;
      CollectionStore.instance = store;
      addTearDown(() => CollectionStore.instance = CollectionStore());
      return store;
    }

    testWidgets('Collections on a details page creates a collection with the '
        'title in it, and unticking takes it out', (tester) async {
      final store = await tester.runAsync(() => instance('a'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    CollectionActions.addToCollections(context, store!, _dune),
                child: const Text('Collections'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Collections'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New collection'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Weekend');
      await tester.tap(find.text('Create'));
      await tester.runAsync(() => store!.ready);
      await tester.pumpAndSettle();
      final weekend = store!.library.collections.single;
      expect(store.library.collectionsWith(_dune), {weekend.id});
      expect(find.text('Weekend'), findsOneWidget);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(store.library.collectionsWith(_dune), isEmpty);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('an empty name is not saved', (tester) async {
      final store = await tester.runAsync(() => instance('a'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => CollectionActions.create(context, store!),
                child: const Text('New'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('New'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(store!.library.collections, isEmpty);
    });

    testWidgets('deleting asks first, with Cancel focused', (tester) async {
      final store = await tester.runAsync(() => instance('a'));
      final list = (await tester.runAsync(
        () => store!.createCollection(name: 'Keep me'),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    CollectionActions.delete(context, store!, list),
                child: const Text('Delete'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Keep me?'), findsOneWidget);
      final cancel = find.widgetWithText(TextButton, 'Cancel');
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        focused.findAncestorWidgetOfExactType<TextButton>(),
        tester.widget<TextButton>(cancel),
      );
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(store!.library.collection(list.id), isNotNull);
    });

    testWidgets('the phone collection page lists its titles and opens one', (
      tester,
    ) async {
      final store = await tester.runAsync(() => instance('a'));
      final list = (await tester.runAsync(() async {
        final list = await store!.createCollection(
          name: 'Sci-fi',
          description: 'Big ideas',
        );
        await store.setMembership(_dune, add: {list.id});
        await store.setMembership(_arrival, add: {list.id});
        return list;
      }))!;
      MediaItem? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: CollectionPage(
            target: CustomTarget(list.id),
            storage: StorageService(),
            onOpen: (item) => opened = item,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sci-fi'), findsOneWidget);
      expect(find.text('Big ideas'), findsOneWidget);
      expect(find.textContaining('2 titles'), findsOneWidget);
      await tester.tap(find.text('Arrival'));
      expect(opened?.id, _arrival.id);
    });

    testWidgets('the TV collection page focuses the first title', (
      tester,
    ) async {
      final store = await tester.runAsync(() => instance('a'));
      final list = (await tester.runAsync(() async {
        final list = await store!.createCollection(name: 'Series');
        await store.setMembership(_dark, add: {list.id});
        return list;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: TvCollectionPage(
            target: CustomTarget(list.id),
            storage: StorageService(),
            onOpen: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Series'), findsOneWidget);
      expect(find.text('Options'), findsOneWidget);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
        focused?.findAncestorWidgetOfExactType<TvPosterCard>()?.item.id,
        _dark.id,
      );
    });

    testWidgets(
      'the Windows library section lists smart collections and folders',
      (tester) async {
        final store = await tester.runAsync(() => instance('a'));
        await tester.runAsync(() async {
          final folder = await store!.createFolder('Movies');
          await store.createCollection(name: 'Sci-fi', folderId: folder.id);
          await store.createCollection(name: 'Loose');
        });
        final model = LibraryViewModel(
          storage: StorageService(),
          collections: store,
        );
        addTearDown(model.dispose);
        await tester.runAsync(model.load);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DesktopCollectionsSection(
                  model: model,
                  storage: StorageService(),
                  onOpen: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final kind in SmartCollection.values) {
          expect(find.text(kind.label), findsOneWidget);
        }
        expect(find.text('Movies', skipOffstage: false), findsOneWidget);
        expect(find.text('1 collection', skipOffstage: false), findsOneWidget);
        expect(find.text('Loose', skipOffstage: false), findsOneWidget);
        // In its folder, not at the top level.
        expect(find.text('Sci-fi', skipOffstage: false), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}

List<String> names(List<MediaItem> items) => [for (final i in items) i.name];
