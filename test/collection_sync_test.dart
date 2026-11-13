import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/collection_sync.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/collections/collection_models.dart';
import 'package:onfeed/src/collections/collection_store.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _dune = MediaItem(
  id: '438631',
  type: 'movie',
  name: 'Dune',
  year: '2021',
  poster: 'https://image.tmdb.org/t/p/w500/dune.jpg',
);
const _dark = MediaItem(id: '70523', type: 'series', name: 'Dark');

/// The Reelish API's collection routes, with the Worker's ordering rule.
class _FakeServer {
  final rows = <String, Map<String, Object?>>{};
  int time = 1000000;
  bool down = false;
  int pushes = 0;

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  bool _newer(Map<String, Object?> change, Map<String, Object?>? stored) {
    if (stored == null) return true;
    if (change['device'] == stored['device']) {
      return (change['seq'] as int) > (stored['seq'] as int);
    }
    final a = change['at'] as int, b = stored['at'] as int;
    return a > b ||
        (a == b &&
            (change['device'] as String).compareTo(stored['device'] as String) >
                0);
  }

  Future<http.Response> handle(http.Request request) async {
    expect(request.url.path, '/api/v1/collections');
    if (down) throw http.ClientException('offline');
    time += 10;
    if (request.method == 'POST') {
      pushes++;
      final body = jsonDecode(request.body) as Map;
      final changes = body['changes'] as List;
      expect(changes.length, lessThanOrEqualTo(50));
      for (final raw in changes) {
        final change = Map<String, Object?>.from(raw as Map)
          ..['device'] = body['device'];
        change['at'] = (change['at'] as int).clamp(0, time);
        final key = '${change['kind']}:${change['key']}';
        if (_newer(change, rows[key])) {
          rows[key] = {
            if (change['deleted'] == true)
              for (final field in ['kind', 'key', 'device', 'seq', 'at'])
                field: change[field]
            else
              ...change,
            'deleted': change['deleted'] == true,
            'changedAt': time,
          };
        }
      }
      return _json({'accepted': 0, 'serverTime': time});
    }
    final since = int.parse(request.url.queryParameters['since']!);
    final items =
        rows.values.where((r) => (r['changedAt'] as int) >= since).toList()
          ..sort(
            (a, b) => (a['changedAt'] as int).compareTo(b['changedAt'] as int),
          );
    return _json({
      'items': items,
      'cursor': items.isEmpty ? since : items.last['changedAt'],
      'more': false,
      'serverTime': time,
    });
  }
}

void main() {
  late _FakeServer server;
  late AccountController account;
  var skew = 0;

  final devices = <String, Map<String, Object>>{};

  setUp(() async {
    devices.clear();
    server = _FakeServer();
    skew = 0;
    StorageService.clock = () => server.time + skew;
    SharedPreferences.setMockInitialValues({});
    account = AccountController(
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's1',
          accessToken: 'access-1',
          accessExpiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
          refreshToken: 'refresh-1',
          refreshExpiresAt:
              DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
          userId: 'user-a',
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
  });

  tearDown(() {
    CollectionStore.onRecordsChanged = null;
    StorageService.clock = () => DateTime.now().millisecondsSinceEpoch;
  });

  /// One device: its own preferences, store and sync, synced before and
  /// after [body] unless [online] is false.
  Future<CollectionStore> onDevice(
    String name,
    Future<void> Function(CollectionStore store, CollectionSync sync) body, {
    bool syncAfter = true,
  }) async {
    SharedPreferences.setMockInitialValues(devices[name] ?? {});
    final preferences = await SharedPreferences.getInstance();
    // ignore: invalid_use_of_visible_for_testing_member
    await preferences.reload();
    final store = CollectionStore()..useAccount('user-a');
    await store.ready;
    final sync = CollectionSync(
      api: AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient(server.handle),
      ),
      store: store,
      idleDelay: const Duration(hours: 1),
      retryBase: const Duration(hours: 1),
      followLifecycle: false,
    )..attach(account);
    await sync.sync();
    await body(store, sync);
    // Let the store's change notice reach the outbox.
    await Future<void>.delayed(Duration.zero);
    if (syncAfter) await sync.sync();
    sync.dispose();
    devices[name] = {
      for (final key in preferences.getKeys()) key: preferences.get(key)!,
    };
    return store;
  }

  List<String> names(CollectionStore store, String collectionId) => [
    for (final entry in store.library.entriesOf(collectionId)) entry.name,
  ];

  test(
    'a collection made on Android, in a folder, appears on Windows',
    () async {
      late String folderId, collectionId;
      await onDevice('android', (store, _) async {
        final folder = await store.createFolder('Movies');
        final collection = await store.createCollection(
          name: 'Sci-fi',
          description: 'Big ideas',
          folderId: folder.id,
        );
        await store.add(_dune, collection.id);
        await store.add(_dark, collection.id);
        await store.setCover(collection.id, _dune);
        folderId = folder.id;
        collectionId = collection.id;
      });
      await onDevice('windows', (store, _) async {
        final library = store.library;
        expect(library.folder(folderId)?.name, 'Movies');
        final collection = library.collection(collectionId)!;
        expect(
          (collection.name, collection.description, collection.folderId),
          ('Sci-fi', 'Big ideas', folderId),
        );
        expect(collection.cover, 'movie:438631');
        expect(names(store, collectionId), unorderedEquals(['Dune', 'Dark']));
        final dune = library
            .entriesOf(collectionId)
            .firstWhere((e) => e.id == _dune.id);
        expect((dune.poster, dune.year), (_dune.poster, '2021'));
      });
    },
  );

  test('edits made offline on two devices are both kept', () async {
    late String shared;
    await onDevice('android', (store, _) async {
      shared = (await store.createCollection(name: 'Shared')).id;
    });
    await onDevice('windows', (_, _) async {});
    // Both offline: Android makes a collection, Windows adds a title.
    late String fresh;
    server.down = true;
    await onDevice('android', (store, _) async {
      fresh = (await store.createCollection(name: 'Fresh')).id;
    });
    await onDevice('windows', (store, _) async {
      await store.add(_dune, shared);
    });
    server.down = false;
    await onDevice('android', (_, _) async {});
    await onDevice('windows', (_, _) async {});
    final android = await onDevice('android', (_, _) async {});
    expect(android.library.collection(fresh)?.name, 'Fresh');
    expect(names(android, shared), ['Dune']);
    final windows = await onDevice('windows', (_, _) async {});
    expect(windows.library.collection(fresh)?.name, 'Fresh');
  });

  test('the same title added on two devices is listed once', () async {
    late String id;
    await onDevice('android', (store, _) async {
      id = (await store.createCollection(name: 'List')).id;
    });
    await onDevice('windows', (store, _) async => store.add(_dune, id));
    await onDevice('android', (store, _) async => store.add(_dune, id));
    final windows = await onDevice('windows', (_, _) async {});
    expect(names(windows, id), ['Dune']);
    expect(
      server.rows.keys.where((key) => key.startsWith('entry:')),
      hasLength(1),
    );
  });

  test('a deletion is not undone by an older offline edit', () async {
    late String id;
    await onDevice('android', (store, _) async {
      id = (await store.createCollection(name: 'Doomed')).id;
    });
    await onDevice('windows', (_, _) async {});
    // Windows renames it offline; later, Android deletes it and syncs.
    server.down = true;
    await onDevice('windows', (store, _) async {
      await store.editCollection(id, name: 'Renamed offline');
    });
    server.down = false;
    server.time += 1000;
    await onDevice('android', (store, _) async => store.deleteCollection(id));
    final windows = await onDevice('windows', (_, _) async {});
    expect(windows.library.collection(id), isNull);
    final android = await onDevice('android', (_, _) async {});
    expect(android.library.collection(id), isNull);
    expect(server.rows['collection:$id']?['deleted'], isTrue);
  });

  test('a title removed on one device leaves the others', () async {
    late String id;
    await onDevice('android', (store, _) async {
      id = (await store.createCollection(name: 'List')).id;
      await store.add(_dune, id);
      await store.add(_dark, id);
    });
    await onDevice(
      'tv',
      (store, _) async => expect(names(store, id), hasLength(2)),
    );
    await onDevice('windows', (store, _) async => store.remove(_dune, id));
    final tv = await onDevice('tv', (_, _) async {});
    expect(names(tv, id), ['Dark']);
  });

  test('a library made before sync is uploaded on the first sync', () async {
    // Phase 1: collections made with no sync running.
    late String id;
    SharedPreferences.setMockInitialValues({});
    final before = CollectionStore()..useAccount('user-a');
    await before.ready;
    id = (await before.createCollection(name: 'Before sync')).id;
    await before.add(_dune, id);
    final preferences = await SharedPreferences.getInstance();
    devices['android'] = {
      for (final key in preferences.getKeys()) key: preferences.get(key)!,
    };
    await onDevice('android', (_, _) async {});
    final windows = await onDevice('windows', (_, _) async {});
    expect(windows.library.collection(id)?.name, 'Before sync');
    expect(names(windows, id), ['Dune']);
  });

  test('a device clock an hour fast cannot win over newer changes', () async {
    late String id;
    await onDevice('android', (store, _) async {
      id = (await store.createCollection(name: 'Original')).id;
    });
    skew = 60 * 60 * 1000;
    await onDevice('fast', (store, _) async {
      await store.editCollection(id, name: 'From the fast clock');
    });
    skew = 0;
    server.time += 1000;
    await onDevice('android', (store, _) async {
      await store.editCollection(id, name: 'Newest');
    });
    // The fast device's clock is still fast; its offset corrects it.
    skew = 60 * 60 * 1000;
    final fast = await onDevice('fast', (_, _) async {});
    expect(fast.library.collection(id)?.name, 'Newest');
  });

  test('a title that arrives before its collection is kept', () async {
    SharedPreferences.setMockInitialValues({});
    final store = CollectionStore()..useAccount('user-a');
    await store.ready;
    const collectionId = 'abcdefabcdefabcdefabcdef';
    await store.applySynced('user-a', [
      const SyncedRecord(
        kind: SyncedKind.entry,
        key: '$collectionId|movie:438631',
        at: 10,
        addedAt: 10,
        fields: {'name': 'Dune'},
      ),
    ]);
    expect(store.library.collections, isEmpty);
    await store.applySynced('user-a', [
      const SyncedRecord(
        kind: SyncedKind.collection,
        key: collectionId,
        at: 5,
        createdAt: 5,
        fields: {'name': 'Late'},
      ),
    ]);
    expect(names(store, collectionId), ['Dune']);
    // Applied again: nothing changes.
    expect(
      await store.applySynced('user-a', [
        const SyncedRecord(
          kind: SyncedKind.collection,
          key: collectionId,
          at: 5,
          fields: {'name': 'Late'},
        ),
      ]),
      isFalse,
    );
  });

  test('records for another account are never applied', () async {
    SharedPreferences.setMockInitialValues({});
    final store = CollectionStore()..useAccount('user-a');
    await store.ready;
    expect(
      await store.applySynced('user-b', [
        const SyncedRecord(
          kind: SyncedKind.folder,
          key: 'abcdefabcdefabcdefabcdef',
          at: 1,
          fields: {'name': 'Not mine'},
        ),
      ]),
      isFalse,
    );
    expect(store.library.folders, isEmpty);
  });
}
