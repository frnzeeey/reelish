import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/notifications/episode_alerts.dart';
import 'package:onfeed/src/notifications/episode_check.dart';
import 'package:onfeed/src/notifications/smart_alerts.dart';
import 'package:onfeed/src/screens/notification_settings_screen.dart';
import 'package:onfeed/src/screens/sign_in_screen.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Notifier implements EpisodeNotifier {
  final shown = <List<NewEpisode>>[];
  final popular = <List<NewEpisode>>[];

  @override
  Future<void> showNew(List<NewEpisode> episodes) async => shown.add(episodes);

  @override
  Future<void> showPopular(List<NewEpisode> episodes) async =>
      popular.add(episodes);

  final messages = <(int, List<String>)>[];

  @override
  Future<void> showMessages(int count, List<String> from) async =>
      messages.add((count, from));

  final updates = <(AlertCategory, List<AlertEvent>)>[];
  final digests = <List<AlertEvent>>[];

  @override
  Future<void> showUpdates(
    AlertCategory category,
    List<AlertEvent> events,
  ) async => updates.add((category, events));

  @override
  Future<void> showDigest(List<AlertEvent> events) async => digests.add(events);
}

/// The API's answer: each series' latest episode, set per test.
class _FakeApi {
  final latest = <int, (int, int, String)>{};
  final popularIds = <int>[];
  final requested = <List<int>>[];
  bool? askedPopular;
  bool? askedMessages;
  int waitingMessages = 0;
  List<String> waitingFrom = const [];
  String token = 'rnt_${'a' * 43}';

  Map<String, Object> _series(int id) {
    final (season, episode, airDate) = latest[id]!;
    return {
      'tmdbId': id,
      'name': 'Show $id',
      'poster': '',
      'lastEpisode': {
        'season': season,
        'episode': episode,
        'name': 'Ep $episode',
        'airDate': airDate,
      },
    };
  }

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/notifications/token')) {
      return http.Response(
        jsonEncode({'token': token}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    expect(request.url.path, '/api/v1/notifications/episodes');
    expect(request.headers['Authorization'], 'Bearer $token');
    final body = jsonDecode(request.body) as Map;
    final ids = (body['series'] as List).cast<int>();
    requested.add(ids);
    askedPopular = body['popular'] as bool;
    askedMessages = body['messages'] as bool?;
    return http.Response(
      jsonEncode({
        if (askedMessages == true && waitingMessages > 0)
          'messages': {'count': waitingMessages, 'from': waitingFrom},
        'series': [
          for (final id in ids)
            if (latest.containsKey(id)) _series(id),
        ],
        'popular': [
          if (askedPopular!)
            for (final id in popularIds) _series(id),
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

String _day(DateTime d, [int minusDays = 0]) {
  final t = d.subtract(Duration(days: minusDays));
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

void main() {
  late _FakeApi fake;
  late StorageService storage;
  late _Notifier notifier;
  final now = DateTime(2026, 10, 30, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
    fake = _FakeApi();
    storage = StorageService();
    notifier = _Notifier();
  });

  AccountApi api() => AccountApi(
    baseUrl: Uri.parse('https://api.reelish.app'),
    client: MockClient(fake.handle),
  );

  Future<void> settings(EpisodeAlertSettings s) => EpisodeAlertStore.update(
    'user-a',
    (e) => e['settings'] = EpisodeAlertStore.settingsJson(s),
  );

  Future<EpisodeCheckResult> check([DateTime? at]) => EpisodeCheck.run(
    userId: 'user-a',
    alertToken: fake.token,
    api: api(),
    storage: storage,
    notifier: notifier,
    now: at ?? now,
  );

  group('EpisodeCheck', () {
    test('does nothing while alerts are off', () async {
      await storage.toggleFavorite(
        const MediaItem(id: '1', type: 'series', name: 'A'),
      );
      await check();
      expect(fake.requested, isEmpty);
    });

    test(
      'the first check only notes what is out; a later episode alerts',
      () async {
        await settings(const EpisodeAlertSettings(enabled: true));
        await storage.toggleFavorite(
          const MediaItem(id: '1', type: 'series', name: 'A'),
        );
        fake.latest[1] = (2, 4, _day(now, 1));
        expect((await check()).found, isEmpty);
        expect(notifier.shown, isEmpty);

        fake.latest[1] = (2, 5, _day(now));
        final result = await check();
        expect(result.found.single.episode, 5);
        expect(notifier.shown.single.single.seriesName, 'Show 1');

        // The same episode never alerts twice.
        await check();
        expect(notifier.shown, hasLength(1));
      },
    );

    test('alerts once per new message arrival, never with the text', () async {
      await settings(const EpisodeAlertSettings(enabled: true));
      // No series followed: messages alone are still checked.
      fake.waitingMessages = 1;
      fake.waitingFrom = ['ana'];
      await check();
      expect(fake.askedMessages, isTrue);
      expect(notifier.messages, hasLength(1));
      expect(notifier.messages.single.$1, 1);
      expect(notifier.messages.single.$2, ['ana']);

      // Still the same one waiting: no second alert.
      await check();
      expect(notifier.messages, hasLength(1));

      // Another arrives.
      fake.waitingMessages = 2;
      fake.waitingFrom = ['ben', 'ana'];
      await check();
      expect(notifier.messages.last.$1, 2);
      expect(notifier.messages.last.$2, ['ben', 'ana']);

      // Read in the app (none waiting), then a new one alerts again.
      fake.waitingMessages = 0;
      await check();
      fake.waitingMessages = 1;
      await check();
      expect(notifier.messages, hasLength(3));

      // Switched off: not even asked.
      await settings(
        const EpisodeAlertSettings(enabled: true, messages: false),
      );
      fake.waitingMessages = 5;
      await check();
      expect(notifier.messages, hasLength(3));
    });

    test('an episode that aired long ago is noted but not alerted', () async {
      await settings(const EpisodeAlertSettings(enabled: true));
      await storage.toggleFavorite(
        const MediaItem(id: '1', type: 'series', name: 'A'),
      );
      fake.latest[1] = (1, 1, _day(now, 30));
      await check();
      fake.latest[1] = (1, 2, _day(now, 10));
      await check();
      expect(notifier.shown, isEmpty);
    });

    test('follows My list and Continue watching per the switches', () async {
      await storage.toggleFavorite(
        const MediaItem(id: '1', type: 'series', name: 'On my list'),
      );
      await storage.toggleFavorite(
        const MediaItem(id: '9', type: 'movie', name: 'A movie'),
      );
      await storage.saveProgress(
        const MediaItem(id: '2', type: 'series', name: 'Watching'),
        60000,
      );
      fake.latest[1] = (1, 1, _day(now));
      fake.latest[2] = (1, 1, _day(now));

      await settings(const EpisodeAlertSettings(enabled: true));
      await check();
      expect(fake.requested.last.toSet(), {1, 2});

      await settings(
        const EpisodeAlertSettings(enabled: true, watching: false),
      );
      await check();
      expect(fake.requested.last, [1]);

      await settings(
        const EpisodeAlertSettings(
          enabled: true,
          myList: false,
          watching: true,
          watchlist: false,
        ),
      );
      await check();
      expect(fake.requested.last, [2]);

      // My list updates still ask about series on My list (for seasons),
      // but their episodes alert only with Series on My list on.
      await settings(
        const EpisodeAlertSettings(
          enabled: true,
          myList: false,
          watching: true,
        ),
      );
      fake.latest[1] = (1, 2, _day(now));
      fake.latest[2] = (1, 2, _day(now));
      notifier.shown.clear();
      await check();
      expect(fake.requested.last.toSet(), {1, 2});
      expect(notifier.shown.expand((l) => l).map((e) => e.tmdbId), [2]);
    });

    test(
      'popular series: one summary a day, never ones already followed',
      () async {
        await settings(
          const EpisodeAlertSettings(enabled: true, popular: true),
        );
        await storage.toggleFavorite(
          const MediaItem(id: '1', type: 'series', name: 'Followed'),
        );
        fake.latest[1] = (1, 1, _day(now));
        fake.latest[50] = (3, 2, _day(now));
        fake.latest[51] = (1, 8, _day(now, 1));
        fake.latest[52] = (4, 1, _day(now, 9));
        fake.popularIds.addAll([1, 50, 51, 52]);

        final first = await check();
        expect(fake.askedPopular, true);
        expect(first.popular.map((e) => e.tmdbId), [50, 51]);
        expect(notifier.popular, hasLength(1));

        // Later the same day: no second summary.
        await check(now.add(const Duration(hours: 6)));
        expect(notifier.popular, hasLength(1));

        // The next day: a new summary is allowed.
        fake.latest[50] = (3, 3, _day(now.add(const Duration(days: 1))));
        await check(now.add(const Duration(days: 1)));
        expect(notifier.popular, hasLength(2));
      },
    );

    test('forgets series no longer followed', () async {
      await settings(const EpisodeAlertSettings(enabled: true));
      const item = MediaItem(id: '1', type: 'series', name: 'A');
      await storage.toggleFavorite(item);
      fake.latest[1] = (1, 1, _day(now));
      await check();
      await storage.toggleFavorite(item);
      await check();
      final entry = await EpisodeAlertStore.entry('user-a');
      expect(entry['seen'], isEmpty);
    });
  });

  group('EpisodeAlerts', () {
    Future<AccountController> signedIn() async {
      final account = AccountController(
        store: MemorySessionStore(
          StoredSession(
            sessionId: 's1',
            accessToken: 'access-1',
            accessExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
            refreshToken: 'refresh-1',
            refreshExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
            userId: 'user-a',
            username: 'viewer',
          ),
        ),
      );
      await account.restore();
      return account;
    }

    test(
      'refused notification permission keeps alerts off and says why',
      () async {
        final account = await signedIn();
        final alerts = EpisodeAlerts(
          api: api(),
          storage: storage,
          notifier: notifier,
          tokens: _MemoryTokens(),
          requestPermission: () async => false,
          background: false,
        )..attach(account);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(await alerts.setEnabled(true), false);
        expect(alerts.settings.enabled, false);
        expect(alerts.error, contains('blocked'));
      },
    );

    test(
      'turning alerts on issues a token, checks, and signing out stops them',
      () async {
        final account = await signedIn();
        final tokens = _MemoryTokens();
        final alerts = EpisodeAlerts(
          api: api(),
          storage: storage,
          notifier: notifier,
          tokens: tokens,
          requestPermission: () async => true,
          background: false,
        )..attach(account);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await storage.toggleFavorite(
          const MediaItem(id: '1', type: 'series', name: 'A'),
        );
        fake.latest[1] = (1, 1, _day(DateTime.now()));

        expect(await alerts.setEnabled(true), true);
        expect(tokens.value, fake.token);
        expect(fake.requested, isNotEmpty);
        expect(alerts.lastChecked, isNotNull);
        expect(await EpisodeAlertStore.activeUser(), 'user-a');

        await account.signOut();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(tokens.value, isNull);
        expect(await EpisodeAlertStore.activeUser(), isNull);
      },
    );
  });

  testWidgets('the settings page switches sources only while alerts are on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final alerts = EpisodeAlerts(
      api: api(),
      storage: storage,
      notifier: notifier,
      tokens: _MemoryTokens(),
      background: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.dark,
        home: Scaffold(
          body: NotificationSettingsScreen(alerts: alerts, onBack: () {}),
        ),
      ),
    );
    expect(find.text('Allow notifications'), findsOneWidget);
    expect(find.text('Series on My list'), findsOneWidget);
    expect(find.text('Popular series'), findsOneWidget);
    // Off: the source switches are disabled.
    final popular = tester.widget<Switch>(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Popular series'),
              matching: find.byType(InkWell),
            )
            .first,
        matching: find.byType(Switch),
      ),
    );
    expect(popular.onChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signing out returns to the sign-in screen from a pushed page', (
    tester,
  ) async {
    final account = AccountController(
      api: AccountApi(baseUrl: null),
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's1',
          accessToken: 'a',
          accessExpiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
          refreshToken: 'r',
          refreshExpiresAt:
              DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
          userId: 'u',
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.dark,
        home: AccountGate(
          account: account,
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Account page')),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Account page'), findsOneWidget);

    await account.signOut();
    await tester.pumpAndSettle();
    expect(find.text('Account page'), findsNothing);
    expect(find.text('Sign in to Reelish'), findsOneWidget);
  });
}

class _MemoryTokens implements AlertTokenStore {
  String? value;
  String? user;

  @override
  Future<String?> read(String userId) async => user == userId ? value : null;

  @override
  Future<void> write(String userId, String token) async {
    user = userId;
    value = token;
  }

  @override
  Future<void> clear() async {
    value = null;
    user = null;
  }
}
