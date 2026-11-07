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
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:onfeed/src/widgets/supporter_theme_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _userId = 'user-1';

String _saved(Map<String, Object?> entry) => jsonEncode({_userId: entry});

Directory _folder() {
  final folder = Directory.systemTemp.createTempSync('themes');
  addTearDown(() {
    try {
      folder.deleteSync(recursive: true);
    } on FileSystemException {
      // A temporary folder.
    }
  });
  return folder;
}

/// The profile screen for an account whose supporter status the fake API
/// answers with [status], one answer after another.
Future<(ProfileController, SupporterController)> _show(
  WidgetTester tester, {
  required List<String> status,
  Size size = const Size(412, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final files = _folder();
  late AccountController account;
  late SupporterController supporters;
  late AccountBadges badges;
  late ProfileController profile;
  await tester.runAsync(() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient((request) async {
        if (!request.url.path.endsWith('/supporters/me')) {
          return http.Response(jsonEncode({'badges': []}), 200);
        }
        final answer = status.length > 1 ? status.removeAt(0) : status.first;
        return http.Response(
          jsonEncode({
            'code': 'RS-ABCD-2345',
            'status': answer,
            'since': answer == 'verified' ? 1719825600 : null,
            'recognition': {'listed': false, 'name': ''},
          }),
          200,
        );
      }),
    );
    account = AccountController(
      api: api,
      store: MemorySessionStore(
        StoredSession(
          sessionId: 'session',
          accessToken: 'access',
          accessExpiresAt: now + 3600,
          refreshToken: 'refresh',
          refreshExpiresAt: now + 86400,
          userId: _userId,
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
    supporters = SupporterController(account: account, api: api);
    badges = AccountBadges(account: account, api: api);
    profile = ProfileController(directory: () async => files);
    await profile.loadFor(_userId);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: DeviceCapabilities.isTv ? GlassTheme.tv : GlassTheme.dark,
      home: Scaffold(
        body: ProfileScreen(
          storage: StorageService(filesDirectory: () async => files),
          account: account,
          profile: profile,
          badges: badges,
          supporters: supporters,
        ),
      ),
    ),
  );
  await settle(tester);
  return (profile, supporters);
}

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

/// The theme on the profile card itself, not on the picker's swatches.
SupporterTheme? _drawn(WidgetTester tester) {
  final swatches = find
      .descendant(
        of: find.byType(SupporterThemePicker),
        matching: find.byType(SupporterThemeBackdrop),
      )
      .evaluate()
      .toSet();
  final card = find
      .byType(SupporterThemeBackdrop)
      .evaluate()
      .where((element) => !swatches.contains(element))
      .toList();
  return card.isEmpty
      ? null
      : (card.last.widget as SupporterThemeBackdrop).theme;
}

bool _pickerShown() => find.byType(SupporterThemePicker).evaluate().isNotEmpty;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Choosing what to draw', () {
    test('a supporter who has not chosen sees the standard theme', () {
      expect(SupporterTheme.resolve(null), SupporterTheme.standard);
      expect(SupporterTheme.resolve('no-such-theme'), SupporterTheme.standard);
      expect(SupporterTheme.resolve('aurora'), SupporterTheme.aurora);
      expect(SupporterTheme.resolve(SupporterTheme.classicId), isNull);
    });

    test('every theme has its own id and name', () {
      final ids = SupporterTheme.all.map((theme) => theme.id).toSet();
      final names = SupporterTheme.all.map((theme) => theme.name).toSet();
      expect(ids, hasLength(SupporterTheme.all.length));
      expect(names, hasLength(SupporterTheme.all.length));
      expect(ids, isNot(contains(SupporterTheme.classicId)));
    });
  });

  group('Saving the choice', () {
    test('survives a restart, next to the rest of the profile', () async {
      SharedPreferences.setMockInitialValues({
        ProfileController.storageKey: _saved({
          'displayName': 'Sam',
          'avatar': 'preset',
          'preset': 'avatar3',
        }),
      });
      final files = _folder();
      final first = ProfileController(directory: () async => files);
      await first.loadFor(_userId);
      expect(first.themeId, isNull);
      await first.setTheme('celestial');

      final again = ProfileController(directory: () async => files);
      await again.loadFor(_userId);
      expect(again.themeId, 'celestial');
      expect(again.displayName, 'Sam');
      expect(again.avatar, const ProfileAvatar.preset('avatar3'));
    });

    test('an unknown theme is neither saved nor loaded', () async {
      SharedPreferences.setMockInitialValues({
        ProfileController.storageKey: _saved({
          'avatar': 'initials',
          'theme': 'diamond',
        }),
      });
      final profile = ProfileController(directory: () async => _folder());
      await profile.loadFor(_userId);
      expect(profile.themeId, isNull);
      await profile.setTheme('diamond');
      expect(profile.themeId, isNull);
      await profile.setTheme(SupporterTheme.classicId);
      expect(profile.themeId, SupporterTheme.classicId);
    });
  });

  group('Only supporters see a theme', () {
    testWidgets('a theme saved on the device does nothing for others', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        ProfileController.storageKey: _saved({
          'avatar': 'initials',
          'theme': 'aurora',
        }),
      });
      await _show(tester, status: ['none']);
      expect(_drawn(tester), isNull);
      expect(_pickerShown(), isFalse);
      expect(find.text('PROFILE THEME'), findsNothing);
    });

    testWidgets('a donation waiting for review does not count', (tester) async {
      await _show(tester, status: ['pending']);
      expect(_drawn(tester), isNull);
      expect(_pickerShown(), isFalse);
    });

    testWidgets('a supporter gets the standard theme and the picker', (
      tester,
    ) async {
      await _show(tester, status: ['verified']);
      expect(_drawn(tester), SupporterTheme.standard);
      expect(_pickerShown(), isTrue);
    });

    testWidgets('choosing a theme draws it and keeps it', (tester) async {
      final (profile, _) = await _show(tester, status: ['verified']);
      await tester.tap(find.text('Celestial'));
      await settle(tester);
      expect(_drawn(tester), SupporterTheme.celestial);
      expect(profile.themeId, 'celestial');

      await tester.tap(find.text('Classic'));
      await settle(tester);
      expect(_drawn(tester), isNull);
      expect(_pickerShown(), isTrue);
      expect(profile.themeId, SupporterTheme.classicId);
    });

    testWidgets('when support ends, the usual profile returns and the choice '
        'waits', (tester) async {
      SharedPreferences.setMockInitialValues({
        ProfileController.storageKey: _saved({
          'displayName': 'Sam',
          'avatar': 'initials',
          'theme': 'rose_luxe',
        }),
      });
      final (profile, supporters) = await _show(
        tester,
        status: ['verified', 'none'],
      );
      expect(_drawn(tester), SupporterTheme.roseLuxe);
      await tester.runAsync(supporters.refresh);
      await settle(tester);
      expect(_drawn(tester), isNull);
      expect(_pickerShown(), isFalse);
      // Nothing of theirs was lost.
      expect(profile.themeId, 'rose_luxe');
      expect(profile.displayName, 'Sam');
    });
  });

  group('Every interface', () {
    testWidgets('TV: the swatches take the remote and fit the screen', (
      tester,
    ) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final (profile, _) = await _show(
        tester,
        status: ['verified'],
        size: const Size(1920, 1600),
      );
      Focus.of(tester.element(find.text('Aurora'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(profile.themeId, 'aurora');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Windows: all six in one row',
      (tester) async {
        await _show(tester, status: ['verified'], size: const Size(1280, 1000));
        final first = tester.getTopLeft(find.text('Royal Violet'));
        final last = tester.getTopLeft(find.text('Classic'));
        expect(last.dy, first.dy);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}
