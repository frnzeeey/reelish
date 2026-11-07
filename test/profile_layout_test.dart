import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_badges.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/profile_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/profile_avatar_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The profile for an account with [entitlement] and [badges], as the fake
/// API reports them. Returns the profile controller, to read what was saved.
Future<ProfileController> _show(
  WidgetTester tester, {
  String entitlement = 'free',
  List<String> badges = const [],
  Size size = const Size(412, 1400),
  String? theme,
}) async {
  SharedPreferences.setMockInitialValues({
    ProfileController.storageKey: jsonEncode({
      'u': {'displayName': 'Sam', 'avatar': 'preset', 'preset': 'avatar3'},
    }),
    'onfeed.appearance.theme': ?theme,
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final files = Directory.systemTemp.createTempSync('profile');
  late AccountController account;
  late AccountBadges accountBadges;
  late ProfileController profile;
  late AccentSettingsController appearance;
  await tester.runAsync(() async {
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path.endsWith('/supporters/me')
                ? {
                    'code': 'RS-ABCD-2345',
                    'status': badges.contains('supporter')
                        ? 'verified'
                        : 'none',
                    'since': null,
                    'recognition': {'listed': false, 'name': ''},
                    'entitlement': entitlement,
                  }
                : {
                    'user': {'id': 'u', 'username': 'sam_r'},
                    'badges': badges,
                  },
          ),
          200,
        ),
      ),
    );
    account = AccountController(
      api: api,
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's',
          accessToken: 'a',
          accessExpiresAt: _now() + 3600,
          refreshToken: 'r',
          refreshExpiresAt: _now() + 86400,
          userId: 'u',
          username: 'sam_r',
        ),
      ),
    );
    await account.restore();
    final supporters = SupporterController(account: account, api: api);
    await supporters.refresh();
    accountBadges = AccountBadges(account: account);
    await accountBadges.refresh();
    profile = ProfileController(directory: () async => files);
    await profile.loadFor('u');
    appearance = AccentSettingsController(supporters: supporters);
    await appearance.load();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: DeviceCapabilities.isTv ? GlassTheme.tv : GlassTheme.dark,
      home: Scaffold(
        body: ProfileScreen(
          storage: StorageService(filesDirectory: () async => files),
          account: account,
          profile: profile,
          badges: accountBadges,
          appearance: appearance,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  return profile;
}

void main() {
  tearDown(() => GlassTheme.setAccent(GlassTheme.coral));

  group('Three parts', () {
    testWidgets('identity, then Personalize, Membership and Account', (
      tester,
    ) async {
      await _show(tester);
      for (final label in ['PERSONALIZE', 'MEMBERSHIP', 'ACCOUNT']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Avatar'), findsOneWidget);
      expect(find.text('Avatar 3'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Manage account'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      // The identity card comes first.
      expect(
        tester.getTopLeft(find.text('Sam')).dy,
        lessThan(tester.getTopLeft(find.text('PERSONALIZE')).dy),
      );
    });

    testWidgets('the theme tile names the theme in use', (tester) async {
      await _show(tester, entitlement: 'supporter', theme: 'aurora');
      expect(find.text('Aurora'), findsOneWidget);
    });
  });

  group('Membership', () {
    for (final (entitlement, badges, title) in [
      ('free', <String>[], 'Reelish Supporters'),
      ('supporter', ['supporter'], 'Supporter perks'),
      ('founder', ['founder'], 'Founder'),
    ]) {
      testWidgets('$entitlement: "$title"', (tester) async {
        await _show(tester, entitlement: entitlement, badges: badges);
        expect(find.text(title), findsOneWidget);
      });
    }

    testWidgets('a Founder who never donated shows no Supporter badge', (
      tester,
    ) async {
      await _show(tester, entitlement: 'founder', badges: ['founder']);
      expect(find.text('REELISH FOUNDER'), findsOneWidget);
      expect(find.text('Reelish Supporter'), findsNothing);
      expect(
        find.textContaining('Every Supporter perk is yours'),
        findsOneWidget,
      );
    });
  });

  group('Changing the avatar in place', () {
    testWidgets('phone: a sheet, and a choice saves at once', (tester) async {
      final profile = await _show(tester);
      await tester.tap(find.byTooltip('Change avatar'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileAvatarPicker), findsOneWidget);
      await tester.tap(find.byTooltip('Avatar 5'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(profile.avatar, const ProfileAvatar.preset('avatar5'));
    });

    testWidgets('TV: the remote reaches the button, and a dialog opens', (
      tester,
    ) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      await _show(tester, size: const Size(1920, 1400));
      // The button's own focus, inside its tooltip.
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byTooltip('Change avatar'),
            matching: find.byType(Icon),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(ProfileAvatarPicker), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Every interface', () {
    testWidgets(
      'Windows: the identity beside the rest',
      (tester) async {
        await _show(tester, size: const Size(1280, 900));
        final name = tester.getCenter(find.text('Sam'));
        final avatarTile = tester.getCenter(find.text('Avatar'));
        expect(avatarTile.dx, greaterThan(name.dx));
        expect(avatarTile.dy, lessThan(name.dy + 200));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('a phone stacks the parts', (tester) async {
      await _show(tester);
      expect(
        tester.getTopLeft(find.text('Avatar')).dy,
        greaterThan(tester.getBottomLeft(find.text('Sam')).dy),
      );
    });

    testWidgets('a small phone fits, with both badges', (tester) async {
      await _show(
        tester,
        entitlement: 'founder',
        badges: ['founder', 'supporter'],
        size: const Size(320, 1400),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
