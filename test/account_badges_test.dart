import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_badges.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/profile_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/watch_party/party_models.dart';
import 'package:onfeed/src/widgets/account_badges.dart' as ui;
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session(String userId, {String username = 'viewer'}) =>
    StoredSession(
      sessionId: 'session',
      accessToken: 'access',
      accessExpiresAt: _now() + 3600,
      refreshToken: 'refresh',
      refreshExpiresAt: _now() + 86400,
      userId: userId,
      username: username,
    );

Future<(AccountBadges, AccountController)> _badges(
  Object? body, {
  String userId = 'user-1',
  String username = 'viewer',
  bool offline = false,
}) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient((_) async {
      if (offline) throw const SocketException('offline');
      return http.Response(jsonEncode(body), 200);
    }),
  );
  final account = AccountController(
    api: api,
    store: MemorySessionStore(_session(userId, username: username)),
  );
  await account.restore();
  return (AccountBadges(account: account), account);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Reading badges', () {
    test('comes from the server', () async {
      final (badges, _) = await _badges({
        'badges': ['founder', 'supporter'],
      });
      await badges.refresh();
      expect(badges.has(AccountBadge.founder), isTrue);
      expect(badges.has(AccountBadge.supporter), isTrue);
    });

    test('a badge the app does not know is left out', () {
      expect(
        AccountBadges.parse({
          'badges': ['founder', 'admin'],
        }),
        {AccountBadge.founder},
      );
      expect(AccountBadges.parse({'badges': 'founder'}), isEmpty);
      expect(AccountBadges.parse(null), isEmpty);
    });

    test('a name never makes anyone Founder', () async {
      final (badges, _) = await _badges({
        'badges': [],
      }, username: 'franze_kenneth_lobos_ea1040');
      await badges.refresh();
      expect(badges.has(AccountBadge.founder), isFalse);
    });

    test('a saved value cannot survive the server saying otherwise', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.badges.v1.user-1': jsonEncode({
          'badges': ['founder'],
        }),
      });
      final (badges, _) = await _badges({'badges': []});
      await badges.refresh();
      expect(badges.has(AccountBadge.founder), isFalse);
    });

    test('offline, the saved badges still show', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.badges.v1.user-1': jsonEncode({
          'badges': ['founder'],
        }),
      });
      final (badges, _) = await _badges(null, offline: true);
      await badges.refresh();
      expect(badges.has(AccountBadge.founder), isTrue);
    });

    test('clearing saved data loses nothing', () async {
      final (first, _) = await _badges({
        'badges': ['founder'],
      });
      await first.refresh();
      SharedPreferences.setMockInitialValues({});
      final (second, _) = await _badges({
        'badges': ['founder'],
      });
      await second.refresh();
      expect(second.has(AccountBadge.founder), isTrue);
    });

    test('another account\'s saved badges are not shown', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.badges.v1.someone-else': jsonEncode({
          'badges': ['founder'],
        }),
      });
      final (badges, _) = await _badges(null, offline: true);
      await badges.refresh();
      expect(badges.has(AccountBadge.founder), isFalse);
    });
  });

  group('Watch Party', () {
    test('a participant is Founder only when the room says so', () {
      expect(
        PartyParticipant.fromJson({
          'pid': 'p',
          'name': 'Sam',
          'founder': true,
        })?.founder,
        isTrue,
      );
      expect(
        PartyParticipant.fromJson({'pid': 'p', 'name': 'Founder'})?.founder,
        isFalse,
      );
    });
  });

  group('The profile', () {
    Future<void> show(
      WidgetTester tester,
      Object? body, {
      Size size = const Size(412, 900),
      String name = 'franze_kenneth_lobos_ea1040',
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final (badges, account) = await _badges(body, username: name);
      final files = Directory.systemTemp.createTempSync('badges');
      addTearDown(() {
        try {
          files.deleteSync(recursive: true);
        } on FileSystemException {
          // A temporary folder.
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: ProfileScreen(
              storage: StorageService(filesDirectory: () async => files),
              account: account,
              profile: ProfileController(directory: () async => files),
              badges: badges,
            ),
          ),
        ),
      );
      await tester.runAsync(() => badges.refresh());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('shows the Founder identity', (tester) async {
      await show(tester, {
        'badges': ['founder'],
      });
      expect(find.byType(ui.FounderBadge), findsOneWidget);
      expect(find.text(ui.FounderBadge.title), findsOneWidget);
      expect(find.text(ui.FounderBadge.label), findsOneWidget);
      expect(find.byType(ui.SupporterBadge), findsNothing);
    });

    testWidgets('shows both badges when an account has both', (tester) async {
      await show(tester, {
        'badges': ['founder', 'supporter'],
      });
      expect(find.byType(ui.FounderBadge), findsOneWidget);
      expect(find.byType(ui.SupporterBadge), findsOneWidget);
    });

    testWidgets('an ordinary profile is unchanged', (tester) async {
      await show(tester, {'badges': []});
      expect(find.byType(ui.FounderBadge), findsNothing);
      expect(find.byType(ui.FounderEmblem), findsNothing);
      expect(find.text(ui.FounderBadge.title), findsNothing);
    });

    testWidgets('a supporter sees theirs alone', (tester) async {
      await show(tester, {
        'badges': ['supporter'],
      });
      expect(find.byType(ui.SupporterBadge), findsOneWidget);
      expect(find.byType(ui.FounderBadge), findsNothing);
    });

    testWidgets('fits a small phone with a long name and both badges', (
      tester,
    ) async {
      await show(tester, {
        'badges': ['founder', 'supporter'],
      }, size: const Size(320, 800));
      expect(tester.takeException(), isNull);
    });
  });

  test('the words are the ones agreed', () {
    expect(ui.FounderBadge.title, 'Founder & Developer');
    expect(ui.FounderBadge.label, 'REELISH FOUNDER');
    expect(
      ui.FounderBadge.description,
      'The original creator and developer of Reelish.',
    );
  });

  test('no name of a person or account is compiled into the app', () {
    final text = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join();
    expect(text, isNot(contains('franze_kenneth')));
  });
}
