import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/platform/app_icon.dart';
import 'package:onfeed/src/screens/watch_party/create_party_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/watch_party/party_models.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _iconChannel = MethodChannel('onfeed/app_icon');

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> _status({String status = 'none', String? entitlement}) => {
  'code': 'RS-ABCD-2345',
  'status': status,
  'since': status == 'verified' ? 1719825600 : null,
  'recognition': {'listed': false, 'name': ''},
  'entitlement': ?entitlement,
};

/// An account [userId] whose GET /supporters/me answers [answers] in turn;
/// null fails as if offline.
Future<(AccountController, SupporterController)> _account(
  List<Map<String, Object?>?> answers, {
  String userId = 'user-1',
}) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient((request) async {
      if (!request.url.path.endsWith('/supporters/me')) {
        return http.Response(jsonEncode({'badges': []}), 200);
      }
      final answer = answers.length > 1 ? answers.removeAt(0) : answers.first;
      if (answer == null) throw const SocketException('offline');
      return http.Response(jsonEncode(answer), 200);
    }),
  );
  final account = AccountController(
    api: api,
    store: MemorySessionStore(
      StoredSession(
        sessionId: 'session-$userId',
        accessToken: 'access',
        accessExpiresAt: _now() + 3600,
        refreshToken: 'refresh',
        refreshExpiresAt: _now() + 86400,
        userId: userId,
        username: 'viewer',
      ),
    ),
  );
  await account.restore();
  return (account, SupporterController(account: account, api: api));
}

Map<String, Object?> get _founder => _status(entitlement: 'founder');
Map<String, Object?> get _supporter =>
    _status(status: 'verified', entitlement: 'supporter');
Map<String, Object?> get _free => _status(entitlement: 'free');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Reading the entitlement', () {
    test('comes from the server, and keeps the donation honest', () {
      final founder = SupporterStatus.fromJson(_founder)!;
      expect(founder.entitlement, Entitlement.founder);
      expect(founder.state, SupporterState.none);
      expect(
        SupporterStatus.fromJson(_supporter)!.entitlement,
        Entitlement.supporter,
      );
      expect(SupporterStatus.fromJson(_free)!.entitlement, Entitlement.free);
    });

    test('an older API or saved copy falls back to the donation', () {
      expect(
        SupporterStatus.fromJson(_status(status: 'verified'))!.entitlement,
        Entitlement.supporter,
      );
      expect(
        SupporterStatus.fromJson(_status(status: 'pending'))!.entitlement,
        Entitlement.free,
      );
    });

    test('survives being saved', () {
      final saved = SupporterStatus.fromJson(
        jsonDecode(jsonEncode(SupporterStatus.fromJson(_founder)!.toJson())),
      )!;
      expect(saved.entitlement, Entitlement.founder);
    });
  });

  group('Every perk, for every account', () {
    for (final (name, answer, expected) in [
      ('the Founder', _founder, true),
      ('a supporter', _supporter, true),
      ('a free account', _free, false),
    ]) {
      test('$name ${expected ? 'has' : 'has none of'} them', () async {
        final (_, supporters) = await _account([answer]);
        await supporters.refresh();
        // Every value, so a perk added later is covered here too.
        for (final perk in SupporterPerk.values) {
          expect(supporters.has(perk), expected, reason: perk.name);
        }
      });
    }

    test('nothing has them before the server answers', () async {
      final (_, supporters) = await _account([null]);
      await supporters.refresh();
      for (final perk in SupporterPerk.values) {
        expect(supporters.has(perk), isFalse);
      }
    });

    test(
      'a saved status edited to say Founder is replaced by the server',
      () async {
        SharedPreferences.setMockInitialValues({
          'reelish.supporter.v1.user-1': jsonEncode(_founder),
        });
        final (_, supporters) = await _account([_free]);
        await supporters.refresh();
        expect(supporters.has(SupporterPerk.appThemes), isFalse);
        expect(supporters.entitlement, Entitlement.free);
      },
    );

    test('another account\'s saved Founder status never shows', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.supporter.v1.founder-account': jsonEncode(_founder),
      });
      final (_, supporters) = await _account([null], userId: 'someone-else');
      await supporters.refresh();
      expect(supporters.entitlement, Entitlement.free);
    });

    test('signing out of the Founder account leaves nothing behind', () async {
      final (account, supporters) = await _account([_founder]);
      await supporters.refresh();
      expect(supporters.has(SupporterPerk.hostWatchParty), isTrue);
      await account.signOut();
      await supporters.refresh();
      expect(supporters.entitlement, Entitlement.free);
    });
  });

  group('The Founder, feature by feature', () {
    late String launcher;
    setUp(() {
      launcher = 'default';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iconChannel, (call) async {
            if (call.method == 'select') {
              launcher = (call.arguments as Map)['id'] as String;
            }
            return launcher;
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_iconChannel, null),
    );

    test('applies every supporter app icon', () async {
      final (_, supporters) = await _account([_founder]);
      final icons = AppIconController(supporters: supporters);
      await icons.load();
      await supporters.refresh();
      expect(icons.founder, isTrue);
      for (final preset in AppIconPreset.all) {
        expect(icons.unlocked(preset), isTrue, reason: preset.id);
      }
      expect(await icons.select('celestial'), AppIconChange.applied);
      expect(launcher, 'celestial');
    });

    test('an unreachable server still unlocks nothing', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.supporter.v1.user-1': jsonEncode(_founder),
      });
      final (_, supporters) = await _account([null]);
      final icons = AppIconController(supporters: supporters);
      await icons.load();
      await supporters.refresh();
      expect(await icons.select('aurora'), AppIconChange.unverified);
      expect(launcher, 'default');
    });

    testWidgets('hosts a Watch Party', (tester) async {
      late SupporterController supporters;
      await tester.runAsync(() async {
        (_, supporters) = await _account([_founder]);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: CreatePartyScreen(
            content: const PartyContent(tmdbId: 1, type: 'movie', title: 'F'),
            create:
                ({required content, settings = const PartySettings()}) async =>
                    '11112222',
            supporters: supporters,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.text('Create party'), findsOneWidget);
      expect(find.text(PartyHostingForSupporters.title), findsNothing);
    });

    test('uses every app theme', () async {
      final (_, supporters) = await _account([_founder]);
      await supporters.refresh();
      final appearance = AccentSettingsController(supporters: supporters);
      await appearance.load();
      for (final theme in SupporterTheme.all) {
        await appearance.setTheme(theme.id);
        expect(appearance.theme, theme);
      }
      appearance.dispose();
    });
  });
}
