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
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:onfeed/src/widgets/supporter_theme_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The fake API answers GET /supporters/me with [entitlements] in turn
/// ('free', 'supporter', 'founder'); null fails as if offline.
Future<(AccountController, SupporterController)> _account(
  List<String?> entitlements,
) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient((request) async {
      if (!request.url.path.endsWith('/supporters/me')) {
        return http.Response(jsonEncode({'badges': []}), 200);
      }
      final answer = entitlements.length > 1
          ? entitlements.removeAt(0)
          : entitlements.first;
      if (answer == null) throw const SocketException('offline');
      return http.Response(
        jsonEncode({
          'code': 'RS-ABCD-2345',
          'status': answer == 'supporter' ? 'verified' : 'none',
          'since': null,
          'recognition': {'listed': false, 'name': ''},
          'entitlement': answer,
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

/// The app's look, loaded from saved settings, for an account whose
/// entitlement the server answers.
Future<(AccentSettingsController, SupporterController)> _appearance(
  List<String?> entitlements,
) async {
  final (_, supporters) = await _account(entitlements);
  await supporters.refresh();
  final appearance = AccentSettingsController(supporters: supporters);
  await appearance.load();
  return (appearance, supporters);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlassTheme.setAccent(GlassTheme.coral);
  });

  group('A theme\'s accent', () {
    test('every theme has its own accent, readable on the page', () {
      final ids = <String>{};
      for (final theme in SupporterTheme.all) {
        final accent = theme.accent;
        expect(accent.id, 'theme:${theme.id}');
        expect(accent.label, theme.name);
        expect(accent.primary.computeLuminance(), greaterThanOrEqualTo(.2));
        ids.add(accent.id);
      }
      expect(ids, hasLength(SupporterTheme.all.length));
    });
  });

  group('The app theme', () {
    test('a supporter\'s theme sets the accent across the app', () async {
      final (appearance, _) = await _appearance(['supporter']);
      await appearance.setTheme('aurora');
      expect(appearance.theme, SupporterTheme.aurora);
      expect(appearance.value.id, 'theme:aurora');
      expect(GlassTheme.primary, SupporterTheme.aurora.accent.primary);
    });

    test('the Founder can use every theme without donating', () async {
      final (appearance, _) = await _appearance(['founder']);
      for (final theme in SupporterTheme.all) {
        await appearance.setTheme(theme.id);
        expect(appearance.theme, theme);
      }
    });

    test('someone without the perk cannot set one', () async {
      final (appearance, _) = await _appearance(['free']);
      await appearance.setTheme('celestial');
      expect(appearance.themeId, isNull);
      expect(GlassTheme.primary, GlassTheme.coral.primary);
    });

    test('a theme saved on the device does nothing without the perk', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.appearance.theme': 'rose_luxe',
      });
      final (appearance, _) = await _appearance(['free']);
      expect(appearance.theme, isNull);
      expect(appearance.value, GlassTheme.coral);
      expect(GlassTheme.primary, GlassTheme.coral.primary);
    });

    test('is saved, and comes back after a restart', () async {
      final (first, _) = await _appearance(['supporter']);
      await first.setTheme('golden_hour');
      final (again, _) = await _appearance(['supporter']);
      expect(again.theme, SupporterTheme.goldenHour);
    });

    test('Classic, or picking an accent, turns the theme off', () async {
      final (appearance, _) = await _appearance(['supporter']);
      await appearance.setTheme('celestial');
      await appearance.setTheme(null);
      expect(appearance.theme, isNull);
      await appearance.setTheme('celestial');
      await appearance.update(GlassTheme.teal);
      expect(appearance.theme, isNull);
      expect(GlassTheme.primary, GlassTheme.teal.primary);
      final (again, _) = await _appearance(['supporter']);
      expect(again.theme, isNull);
      expect(again.accent, GlassTheme.teal);
    });

    test(
      'when support ends, the picked accent returns and the theme waits',
      () async {
        SharedPreferences.setMockInitialValues({
          'onfeed.appearance.accent': GlassTheme.blue.id,
        });
        final (appearance, supporters) = await _appearance([
          'supporter',
          'free',
        ]);
        await appearance.setTheme('royal_violet');
        expect(GlassTheme.primary, SupporterTheme.royalViolet.accent.primary);
        await supporters.refresh();
        expect(appearance.theme, isNull);
        expect(GlassTheme.primary, GlassTheme.blue.primary);
        expect(appearance.themeId, 'royal_violet');
      },
    );
  });

  group('Settings > Appearance', () {
    Future<AccentSettingsController> show(
      WidgetTester tester,
      String entitlement, {
      Size size = const Size(412, 1600),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late AccentSettingsController appearance;
      await tester.runAsync(() async {
        (appearance, _) = await _appearance([entitlement]);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: DeviceCapabilities.isTv ? GlassTheme.tv : GlassTheme.dark,
          home: Scaffold(
            body: AppearanceSettingsScreen(
              controller: appearance,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      return appearance;
    }

    testWidgets('a supporter picks a theme', (tester) async {
      final appearance = await show(tester, 'supporter');
      expect(find.text('THEMES'), findsOneWidget);
      await tester.tap(find.text('Celestial'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(appearance.theme, SupporterTheme.celestial);
      expect(find.textContaining('Your theme sets the accent'), findsOneWidget);
    });

    testWidgets('someone else sees the themes locked, and why', (tester) async {
      final appearance = await show(tester, 'free');
      expect(
        find.bySemanticsLabel('Aurora theme, for Reelish Supporters'),
        findsOneWidget,
      );
      expect(find.text('Classic'), findsNothing);
      await tester.tap(find.text('Aurora'));
      await tester.pumpAndSettle();
      expect(find.text('Become a Supporter'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(appearance.themeId, isNull);
      // The accents stay free.
      await tester.scrollUntilVisible(
        find.text(GlassTheme.teal.label),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text(GlassTheme.teal.label));
      await tester.pump();
      expect(appearance.accent, GlassTheme.teal);
    });

    testWidgets('TV: the themes take the remote', (tester) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final appearance = await show(
        tester,
        'founder',
        size: const Size(1920, 2400),
      );
      Focus.of(tester.element(find.text('Rose Luxe'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(appearance.theme, SupporterTheme.roseLuxe);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Windows: the themes fit in one row',
      (tester) async {
        await show(tester, 'supporter', size: const Size(1280, 1400));
        expect(
          tester.getTopLeft(find.text('Royal Violet')).dy,
          tester.getTopLeft(find.text('Classic')).dy,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('The profile card', () {
    Future<void> showProfile(
      WidgetTester tester,
      AccentSettingsController appearance,
      AccountController account,
    ) async {
      tester.view.physicalSize = const Size(412, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final files = Directory.systemTemp.createTempSync('themes');
      final profile = ProfileController(directory: () async => files);
      await tester.runAsync(() => profile.loadFor('user-1'));
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: ProfileScreen(
              storage: StorageService(filesDirectory: () async => files),
              account: account,
              profile: profile,
              badges: AccountBadges(account: account),
              appearance: appearance,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
    }

    testWidgets('wears the app theme, and has no picker of its own', (
      tester,
    ) async {
      late AccountController account;
      late AccentSettingsController appearance;
      await tester.runAsync(() async {
        final (a, supporters) = await _account(['supporter']);
        account = a;
        await supporters.refresh();
        appearance = AccentSettingsController(supporters: supporters);
        await appearance.load();
        await appearance.setTheme('aurora');
      });
      await showProfile(tester, appearance, account);
      final backdrops = tester.widgetList<SupporterThemeBackdrop>(
        find.byType(SupporterThemeBackdrop),
      );
      expect(backdrops.single.theme, SupporterTheme.aurora);
      expect(find.byType(SupporterThemePicker), findsNothing);
    });

    testWidgets('without a theme, the usual card', (tester) async {
      late AccountController account;
      late AccentSettingsController appearance;
      await tester.runAsync(() async {
        final (a, supporters) = await _account(['free']);
        account = a;
        await supporters.refresh();
        appearance = AccentSettingsController(supporters: supporters);
        await appearance.load();
      });
      await showProfile(tester, appearance, account);
      expect(find.byType(SupporterThemeBackdrop), findsNothing);
    });
  });
}
