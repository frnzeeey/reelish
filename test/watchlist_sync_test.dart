import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/watchlist_sync.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

MediaItem _item(String type, String id) =>
    MediaItem(id: id, type: type, name: '$type $id');

/// A fake Reelish API holding one Trakt watchlist.
class _FakeTrakt {
  final remote = <String>{};
  final notFound = <String>{};
  final pushedAdd = <String>[];
  final pushedRemove = <String>[];
  String? failWith;
  int reads = 0;

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> handle(http.Request request) async {
    expect(request.url.path, '/api/v1/trakt/watchlist');
    expect(request.headers['Authorization'], 'Bearer access-1');
    if (failWith != null) {
      return _json({
        'error': {'code': failWith, 'message': failWith},
      }, 409);
    }
    if (request.method == 'GET') {
      reads++;
      return _json({
        'items': [
          for (final key in remote)
            {
              'type': key.split(':')[0],
              'tmdbId': int.parse(key.split(':')[1]),
              'listedAt': '',
            },
        ],
      });
    }
    final body = jsonDecode(request.body) as Map;
    String key(Object? e) => '${(e as Map)['type']}:${e['tmdbId']}';
    final missing = <Map<String, Object>>[];
    for (final entry in body['add'] as List) {
      final k = key(entry);
      pushedAdd.add(k);
      if (notFound.contains(k)) {
        missing.add({
          'type': k.split(':')[0],
          'tmdbId': int.parse(k.split(':')[1]),
        });
      } else {
        remote.add(k);
      }
    }
    for (final entry in body['remove'] as List) {
      pushedRemove.add(key(entry));
      remote.remove(key(entry));
    }
    return _json({'added': 0, 'removed': 0, 'notFound': missing});
  }
}

void main() {
  late _FakeTrakt trakt;
  late StorageService storage;
  late AccountController account;
  final failingFetches = <String>{};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
    trakt = _FakeTrakt();
    storage = StorageService();
    failingFetches.clear();
    account = AccountController(
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's1',
          accessToken: 'access-1',
          accessExpiresAt: _now() + 900,
          refreshToken: 'refresh-1',
          refreshExpiresAt: _now() + 86400,
          userId: 'user-a',
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
  });

  WatchlistSync sync() => WatchlistSync(
    api: AccountApi(
      baseUrl: Uri.parse('https://api.reelish.app'),
      client: MockClient(trakt.handle),
    ),
    storage: storage,
    fetchItem: (type, id) async {
      if (failingFetches.contains('$type:$id')) throw Exception('offline');
      return _item(type, '$id');
    },
    debounce: const Duration(milliseconds: 10),
  );

  Future<WatchlistSync> attached() async {
    final s = sync()..attach(account);
    // Let the stored settings load.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return s;
  }

  Future<Set<String>> localKeys() async => {
    for (final item in await storage.favorites()) '${item.type}:${item.id}',
  };

  test('does nothing until the user turns it on', () async {
    await storage.toggleFavorite(_item('movie', '1'));
    final s = await attached();
    await s.sync();
    expect(trakt.reads, 0);
    expect(s.enabled, false);
  });

  test('the first sync combines both lists and deletes nothing', () async {
    await storage.updateFavorites(
      add: [_item('movie', '1'), _item('movie', '2')],
    );
    trakt.remote.addAll({'movie:2', 'series:3'});
    final s = await attached();
    await s.setEnabled(true);

    expect(trakt.pushedAdd, ['movie:1']);
    expect(trakt.pushedRemove, isEmpty);
    expect(await localKeys(), {'movie:1', 'movie:2', 'series:3'});
    expect(trakt.remote, {'movie:1', 'movie:2', 'series:3'});
    expect(s.error, isNull);
    expect(s.lastSynced, isNotNull);
  });

  test('removals on either side reach the other after a first sync', () async {
    await storage.updateFavorites(
      add: [_item('movie', '1'), _item('movie', '2')],
    );
    trakt.remote.addAll({'movie:1', 'movie:2'});
    final s = await attached();
    await s.setEnabled(true);

    // Removed on another device (on Trakt).
    trakt.remote.remove('movie:2');
    // Removed here.
    await storage.toggleFavorite(_item('movie', '1'));
    await s.sync();

    expect(await localKeys(), isEmpty);
    expect(trakt.pushedRemove, ['movie:1']);
    expect(trakt.remote, isEmpty);
  });

  test('a change to My list syncs on its own shortly after', () async {
    final s = await attached();
    await s.setEnabled(true);
    await storage.toggleFavorite(_item('series', '42'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await s.sync();
    expect(trakt.remote, {'series:42'});
  });

  test('titles without a TMDB id stay on My list, untouched', () async {
    await storage.updateFavorites(add: [_item('movie', 'tt0111161')]);
    final s = await attached();
    await s.setEnabled(true);
    await s.sync();
    expect(trakt.pushedAdd, isEmpty);
    expect(await localKeys(), {'movie:tt0111161'});
  });

  test(
    'a title Trakt cannot find stays on My list and is not retried',
    () async {
      await storage.updateFavorites(add: [_item('movie', '99')]);
      trakt.notFound.add('movie:99');
      final s = await attached();
      await s.setEnabled(true);
      await s.sync();
      await s.sync();
      expect(trakt.pushedAdd, ['movie:99'], reason: 'pushed once only');
      expect(await localKeys(), {'movie:99'});
    },
  );

  test(
    'a title that could not be fetched is retried, never removed from Trakt',
    () async {
      trakt.remote.add('movie:7');
      failingFetches.add('movie:7');
      final s = await attached();
      await s.setEnabled(true);
      expect(await localKeys(), isEmpty);

      await s.sync();
      expect(trakt.pushedRemove, isEmpty);
      expect(trakt.remote, {'movie:7'});

      failingFetches.clear();
      await s.sync();
      expect(await localKeys(), {'movie:7'});
    },
  );

  test('a failed sync changes nothing and says why', () async {
    await storage.updateFavorites(add: [_item('movie', '1')]);
    final s = await attached();
    trakt.failWith = 'trakt_limit';
    await s.setEnabled(true);
    expect(s.error, contains('watchlist is full'));
    expect(await localKeys(), {'movie:1'});

    // Once Trakt accepts again, the pending add goes through.
    trakt.failWith = null;
    await s.sync();
    expect(s.error, isNull);
    expect(trakt.remote, {'movie:1'});
  });

  test('turning it off and on again combines rather than deletes', () async {
    await storage.updateFavorites(add: [_item('movie', '1')]);
    trakt.remote.add('movie:1');
    final s = await attached();
    await s.setEnabled(true);
    await s.setEnabled(false);
    // While off, both sides change.
    trakt.remote.remove('movie:1');
    await storage.toggleFavorite(_item('movie', '5'));
    await s.setEnabled(true);
    expect(await localKeys(), {'movie:1', 'movie:5'});
    expect(trakt.remote, {'movie:1', 'movie:5'});
  });

  test('settings are kept per account and survive a restart', () async {
    final s = await attached();
    await s.setEnabled(true);
    final again = await attached();
    expect(again.enabled, true);
    expect(again.lastSynced, isNotNull);
  });
}
