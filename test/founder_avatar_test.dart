import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/profile_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/screens/watch_party/party_widgets.dart';
import 'package:onfeed/src/widgets/profile_avatar.dart';
import 'package:onfeed/src/widgets/profile_avatar_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A signed-in account whose server answers [entitlement].
Future<(AccountController, SupporterController)> _account(
  String entitlement,
) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient((request) async {
      if (!request.url.path.endsWith('/supporters/me')) {
        return http.Response(jsonEncode({'badges': []}), 200);
      }
      return http.Response(
        jsonEncode({
          'code': 'RS-ABCD-2345',
          'status': entitlement == 'supporter' ? 'verified' : 'none',
          'recognition': {'listed': false, 'name': ''},
          'entitlement': entitlement,
        }),
        200,
      );
    }),
  );
  final account = AccountController(
    api: api,
    store: MemorySessionStore(
      StoredSession(
        sessionId: 'session',
        accessToken: 'access',
        accessExpiresAt: _now() + 3600,
        refreshToken: 'refresh',
        refreshExpiresAt: _now() + 86400,
        userId: 'user-1',
        username: 'viewer',
      ),
    ),
  );
  await account.restore();
  return (account, SupporterController(account: account, api: api));
}

/// The asset an avatar under [finder] draws, or null when it draws none.
String? _assetIn(WidgetTester tester, Finder finder) {
  final images = find.descendant(of: finder, matching: find.byType(Image));
  if (images.evaluate().isEmpty) return null;
  final provider = tester.widget<Image>(images.first).image;
  final key = provider is ResizeImage ? provider.imageProvider : provider;
  return key is AssetImage ? key.assetName : null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('The Founder\'s laurel avatar', () {
    test('is its own preset, kept out of the everyday list', () async {
      const laurel = AvatarPreset.founderLaurel;
      expect(laurel.id, 'founder_laurel');
      expect(laurel.founderOnly, isTrue);
      expect(AvatarPreset.all, isNot(contains(laurel)));
      expect(AvatarPreset.all.where((p) => p.founderOnly), isEmpty);
      expect(AvatarPreset.byId('founder_laurel'), laurel);
      final data = await rootBundle.load(laurel.asset);
      expect(data.lengthInBytes, greaterThan(0));
    });

    test('shows for someone else only when the room says Founder', () {
      expect(
        AvatarPreset.shownFor('founder_laurel', founder: true),
        AvatarPreset.founderLaurel,
      );
      expect(AvatarPreset.shownFor('founder_laurel', founder: false), isNull);
      // Everyday presets show for everyone.
      expect(AvatarPreset.shownFor('avatar3', founder: false)?.id, 'avatar3');
      expect(AvatarPreset.shownFor('nope', founder: true), isNull);
    });

    testWidgets('a party guest claiming it shows their initial', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Column(
            children: [
              PartyAvatar(
                key: ValueKey('founder'),
                name: 'Franze',
                avatar: 'founder_laurel',
                founder: true,
              ),
              PartyAvatar(
                key: ValueKey('guest'),
                name: 'Guest',
                avatar: 'founder_laurel',
              ),
            ],
          ),
        ),
      );
      expect(
        _assetIn(tester, find.byKey(const ValueKey('founder'))),
        AvatarPreset.founderLaurel.asset,
      );
      expect(_assetIn(tester, find.byKey(const ValueKey('guest'))), isNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('guest')),
          matching: find.text('G'),
        ),
        findsOneWidget,
      );
    });

    for (final (name, entitlement, expected) in [
      ('the Founder', 'founder', true),
      ('a supporter', 'supporter', false),
      ('a free account', 'free', false),
    ]) {
      testWidgets('saved on the device, it shows for $name: $expected', (
        tester,
      ) async {
        late AccountController account;
        late SupporterController supporters;
        late ProfileController profile;
        final files = Directory.systemTemp.createTempSync('laurel');
        await tester.runAsync(() async {
          (account, supporters) = await _account(entitlement);
          await supporters.refresh();
          profile = ProfileController(directory: () async => files);
          await profile.loadFor('user-1');
          await profile.setAvatar(const ProfileAvatar.preset('founder_laurel'));
        });
        await tester.pumpWidget(
          MaterialApp(
            home: MyProfileAvatar(
              size: 80,
              account: account,
              profile: profile,
              supporters: supporters,
            ),
          ),
        );
        expect(
          _assetIn(tester, find.byType(MyProfileAvatar)),
          expected ? AvatarPreset.founderLaurel.asset : isNull,
        );
      });
    }

    for (final founder in [true, false]) {
      testWidgets(
        'the picker ${founder ? 'offers it first to the Founder' : 'never offers it to anyone else'}',
        (tester) async {
          final files = Directory.systemTemp.createTempSync('laurel');
          late ProfileController profile;
          await tester.runAsync(() async {
            profile = ProfileController(directory: () async => files);
            await profile.loadFor('user-1');
          });
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ProfileAvatarPicker(
                  profile: profile,
                  name: 'Franze',
                  enabled: true,
                  traktUrl: null,
                  founder: founder,
                ),
              ),
            ),
          );
          expect(
            find.bySemanticsLabel('Founder'),
            founder ? findsOneWidget : findsNothing,
          );
          if (!founder) return;
          await tester.runAsync(() async {
            await tester.tap(find.bySemanticsLabel('Founder'));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          expect(profile.avatar, const ProfileAvatar.preset('founder_laurel'));
        },
      );
    }
  });
}
