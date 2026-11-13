import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/progress_sync.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/resume_summary.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _minute = 60000;

const _movie = MediaItem(
  id: '27205',
  type: 'movie',
  name: 'Inception',
  year: '2010',
  poster: 'https://image.tmdb.org/t/p/w500/abc.jpg',
);
const _series = MediaItem(id: '1396', type: 'series', name: 'Breaking Bad');

/// The Reelish API's progress routes, with the Worker's ordering rule.
class _FakeServer {
  final rows = <String, Map<String, Object?>>{};
  int time = 1000000;
  bool down = false;
  int pushes = 0, pulls = 0;

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
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
    expect(request.url.path, '/api/v1/progress');
    if (down) throw const SocketExceptionLike();
    time += 10;
    if (request.method == 'POST') {
      pushes++;
      final body = jsonDecode(request.body) as Map;
      for (final raw in body['changes'] as List) {
        final change = Map<String, Object?>.from(raw as Map)
          ..['device'] = body['device'];
        change['at'] = (change['at'] as int).clamp(0, time);
        final key = change['key'] as String;
        if (_newer(change, rows[key])) {
          rows[key] = {
            ...?rows[key],
            ...change,
            'removed': change['removed'] == true,
            'positionMs': change['positionMs'] ?? 0,
            'durationMs': change['durationMs'] ?? 0,
            'next': change['next'],
            'changedAt': time,
          };
        }
      }
      return _json({'accepted': 0, 'serverTime': time});
    }
    pulls++;
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

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

void main() {
  late _FakeServer server;
  late AccountController account;
  // How far this device's clock is from the server's.
  var skew = 0;

  // Each device keeps its own SharedPreferences; switching device swaps them.
  final devices = <String, Map<String, Object>>{};
  Future<void> useDevice(String name) async {
    final preferences = await SharedPreferences.getInstance();
    SharedPreferences.setMockInitialValues(devices[name] ?? {});
    StorageService.debugResetWrites();
    StorageService.debugResetAccount();
    StorageService.useAccount('user-a');
    // ignore: invalid_use_of_visible_for_testing_member
    await preferences.reload();
  }

  Future<void> leaveDevice(String name) async {
    final preferences = await SharedPreferences.getInstance();
    devices[name] = {
      for (final key in preferences.getKeys()) key: preferences.get(key)!,
    };
  }

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
    StorageService.onProgressChanged = null;
    StorageService.debugResetAccount();
    StorageService.clock = () => DateTime.now().millisecondsSinceEpoch;
  });

  /// One device's sync, run to completion; returns the storage it used.
  Future<StorageService> onDevice(
    String name,
    Future<void> Function(StorageService storage, ProgressSync sync) body,
  ) async {
    await useDevice(name);
    final storage = StorageService();
    final sync = ProgressSync(
      api: AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient((request) async {
          try {
            return await server.handle(request);
          } on SocketExceptionLike {
            throw http.ClientException('offline');
          }
        }),
      ),
      storage: storage,
      idleDelay: const Duration(hours: 1),
      maxDelay: const Duration(hours: 1),
      retryBase: const Duration(hours: 1),
      followLifecycle: false,
    )..attach(account);
    await sync.sync();
    await body(storage, sync);
    await sync.sync();
    sync.dispose();
    await leaveDevice(name);
    return storage;
  }

  test('a movie left on one device continues on another', () async {
    await onDevice('android', (storage, _) async {
      await storage.saveProgress(
        _movie,
        42 * _minute,
        durationMs: 148 * _minute,
      );
    });
    await onDevice('windows', (storage, _) async {
      final history = await storage.history();
      expect(history.single.id, '27205');
      expect(history.single.resumeMs, 42 * _minute);
      expect(history.single.name, 'Inception');
      expect(history.single.poster, _movie.poster);
      expect(ResumeSummary.continues(history.single), isTrue);
    });
  });

  test('an episode and the next one follow the account', () async {
    await onDevice('windows', (storage, _) async {
      await storage.saveProgress(
        _series,
        47 * _minute,
        durationMs: 48 * _minute,
      );
      await storage.saveEpisodeProgress(
        _series,
        season: 1,
        episode: 3,
        positionMs: 47 * _minute,
        durationMs: 48 * _minute,
        next: (season: 1, episode: 4),
      );
    });
    await onDevice('tv', (storage, _) async {
      expect((await storage.history()).single.type, 'series');
      final progress = await storage.seriesProgress(_series);
      expect(progress.last, (season: 1, episode: 3));
      expect(progress.continueAt, (season: 1, episode: 4));
      expect(progress.of(1, 3)?.isWatched, isTrue);
    });
  });

  test('progress saved offline is sent once the connection returns', () async {
    await onDevice('android', (storage, sync) async {
      server.down = true;
      await storage.saveProgress(
        _movie,
        10 * _minute,
        durationMs: 100 * _minute,
      );
      await sync.sync();
      expect(server.rows, isEmpty);
      server.down = false;
    });
    expect(server.rows['movie:27205']?['positionMs'], 10 * _minute);
  });

  test('an older position from another device does not overwrite a newer '
      'one', () async {
    // Android watched first, but only syncs after Windows.
    await onDevice('android', (storage, sync) async {
      server.down = true;
      await storage.saveProgress(
        _movie,
        25 * _minute,
        durationMs: 100 * _minute,
      );
    });
    server.down = false;
    await onDevice('windows', (storage, _) async {
      await storage.saveProgress(
        _movie,
        31 * _minute,
        durationMs: 100 * _minute,
      );
    });
    // Android comes back online: its older 25:00 loses, and it takes 31:00.
    await onDevice('android', (storage, _) async {});
    expect(server.rows['movie:27205']?['positionMs'], 31 * _minute);
    await onDevice('android', (storage, _) async {
      expect((await storage.history()).single.resumeMs, 31 * _minute);
    });
  });

  test('removing a title on one device removes it on the others', () async {
    await onDevice('android', (storage, _) async {
      await storage.saveProgress(
        _movie,
        10 * _minute,
        durationMs: 100 * _minute,
      );
    });
    await onDevice('windows', (storage, _) async {
      expect(await storage.history(), hasLength(1));
      await storage.removeHistory(_movie);
    });
    await onDevice('android', (storage, _) async {
      expect(await storage.history(), isEmpty);
    });
  });

  test('progress from before sync fills gaps but never replaces newer '
      'progress', () async {
    await onDevice('windows', (storage, _) async {
      await storage.saveProgress(
        _movie,
        50 * _minute,
        durationMs: 100 * _minute,
      );
    });
    // A device whose history predates sync (no save times).
    devices['old-phone'] = {
      'onfeed.history.u.user-a': [
        jsonEncode(_movie.copyWith(resumeMs: 5 * _minute).toJson()),
        jsonEncode(
          const MediaItem(
            id: '603',
            type: 'movie',
            name: 'The Matrix',
            resumeMs: 60000,
          ).toJson(),
        ),
      ],
    };
    await onDevice('old-phone', (storage, _) async {
      final history = await storage.history();
      expect(history.firstWhere((e) => e.id == '27205').resumeMs, 50 * _minute);
    });
    expect(server.rows['movie:27205']?['positionMs'], 50 * _minute);
    expect(server.rows['movie:603']?['positionMs'], 60000);
  });

  test('a device clock an hour fast is corrected, so the later play still '
      'wins', () async {
    // Windows' clock is an hour ahead; it has reached the server before.
    skew = 60 * _minute;
    await onDevice('windows', (storage, _) async {
      await storage.saveProgress(
        _movie,
        31 * _minute,
        durationMs: 100 * _minute,
      );
    });
    // Later, on Android (correct clock), the viewer went back to 20:00.
    skew = 0;
    server.time += 5 * _minute;
    await onDevice('android', (storage, _) async {
      await storage.saveProgress(
        _movie,
        20 * _minute,
        durationMs: 100 * _minute,
      );
    });
    expect(server.rows['movie:27205']?['positionMs'], 20 * _minute);
    skew = 60 * _minute;
    await onDevice('windows', (storage, _) async {
      expect((await storage.history()).single.resumeMs, 20 * _minute);
    });
  });
  test('a change saved for another account waits for that account', () async {
    await useDevice('phone');
    final sync = ProgressSync(
      api: AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient(server.handle),
      ),
      idleDelay: const Duration(hours: 1),
      followLifecycle: false,
    )..attach(account);
    await sync.sync();
    StorageService.useAccount('user-b');
    await StorageService().saveProgress(_movie, 1000);
    await sync.sync();
    sync.dispose();
    expect(server.rows, isEmpty);
    final stored =
        jsonDecode(
              (await SharedPreferences.getInstance()).getString(
                ProgressSync.storageKey,
              )!,
            )
            as Map;
    expect((stored['user-b'] as Map)['outbox'], contains('movie:27205'));
  });
}
