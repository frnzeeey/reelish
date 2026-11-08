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
import 'package:onfeed/src/theme/theme_tokens.dart';
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

/// WCAG contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlassTheme.setAccent(GlassTheme.coral);
    GlassTheme.setSurfaces(ThemeSurfaces.classic);
  });

  group('The collection', () {
    test('seven themes are offered, flagship first', () {
      expect(SupporterTheme.all.map((theme) => theme.name), [
        'Velvet Cinema',
        'Aurora',
        'Ember',
        'Arctic',
        'Ivory Studio',
        'Obsidian Gold',
        'Rosé Noir',
      ]);
      expect(SupporterTheme.byId('ivory_studio'), SupporterTheme.ivoryStudio);
    });

    test('Ivory Studio is a light theme in the palette given', () {
      final ivory = SupporterTheme.ivoryStudio;
      final s = ivory.surfaces;
      expect(s.brightness, Brightness.light);
      expect(s.background, const Color(0xFFFAF8F3));
      expect(s.surface, const Color(0xFFFFFFFF));
      expect(s.raised, const Color(0xFFF4F0E8));
      expect(s.textPrimary, const Color(0xFF28251F));
      // The palette's bronze stays as the light partner; the accent is a
      // deeper bronze so small accent text reads on ivory.
      expect(ivory.light, const Color(0xFFB49B78));
      // Light Material components and dark status bar icons follow.
      final data = GlassTheme.build(ivory.accent, s);
      expect(data.brightness, Brightness.light);
      expect(data.colorScheme.onSurface, s.textPrimary);
    });

    test('artwork stays dark behind white titles, whatever the theme', () {
      for (final theme in SupporterTheme.all) {
        final s = theme.surfaces;
        // White titles over the scrim read in every theme.
        expect(
          _contrast(Colors.white, s.artworkScrim),
          greaterThan(7),
          reason: theme.name,
        );
        if (s.brightness == Brightness.dark) {
          expect(s.artworkScrim, s.background, reason: theme.name);
        }
      }
    });

    test('every theme casts its own light; Classic stays flat', () {
      expect(ThemeSurfaces.classic.ambient, isNull);
      for (final theme in SupporterTheme.all) {
        expect(theme.surfaces.ambient, isNotNull, reason: theme.name);
      }
    });

    test('each theme is the palette it was designed with', () {
      const spec = {
        'velvet_cinema': (0xFFA78BFA, 0xFF0D0B14, 0xFF191522, 0xFF211B30),
        'aurora': (0xFF54D6C0, 0xFF071311, 0xFF10201E, 0xFF17302B),
        'obsidian_gold': (0xFFD6B36A, 0xFF0D0D0C, 0xFF191816, 0xFF24211B),
        'ember': (0xFFFF795F, 0xFF140B0A, 0xFF211312, 0xFF301A18),
        'arctic': (0xFF8CCBFF, 0xFF08111C, 0xFF111E2D, 0xFF192A3C),
        'rose_noir': (0xFFF18EB5, 0xFF140D14, 0xFF211622, 0xFF302033),
        'ivory_studio': (0xFF856D4C, 0xFFFAF8F3, 0xFFFFFFFF, 0xFFF4F0E8),
      };
      for (final theme in SupporterTheme.all) {
        final (primary, page, surface, raised) = spec[theme.id]!;
        expect(theme.primary, Color(primary), reason: theme.name);
        expect(theme.surfaces.background, Color(page), reason: theme.name);
        expect(theme.surfaces.surface, Color(surface), reason: theme.name);
        expect(theme.surfaces.raised, Color(raised), reason: theme.name);
      }
    });

    test('every theme reads: text, captions and its accent', () {
      final ids = <String>{};
      for (final theme in SupporterTheme.all) {
        final s = theme.surfaces;
        expect(theme.accent.id, 'theme:${theme.id}');
        expect(theme.accent.label, theme.name);
        ids.add(theme.accent.id);
        // Body text: AAA. Captions, on the page and on dialogs: AA.
        expect(_contrast(s.textPrimary, s.background), greaterThan(7));
        expect(_contrast(s.textSecondary, s.background), greaterThan(4.5));
        expect(_contrast(s.textSecondary, s.raised), greaterThan(4.5));
        // The accent as text on the page, and the page colour as text on
        // an accent button.
        expect(_contrast(theme.primary, s.background), greaterThan(4.5));
        expect(
          _contrast(s.background, theme.primary),
          greaterThan(4.5),
          reason: theme.name,
        );
      }
      expect(ids, hasLength(SupporterTheme.all.length));
    });

    test('retired themes open as the ones that replaced them', () {
      expect(SupporterTheme.byId('royal_violet'), SupporterTheme.velvetCinema);
      expect(SupporterTheme.byId('celestial'), SupporterTheme.arctic);
      expect(SupporterTheme.byId('aurora'), SupporterTheme.aurora);
      expect(SupporterTheme.byId('rose_luxe'), SupporterTheme.roseNoir);
      expect(SupporterTheme.byId('golden_hour'), SupporterTheme.obsidianGold);
      expect(SupporterTheme.byId(''), isNull);
      expect(SupporterTheme.byId('nope'), isNull);
    });

    test('Material components take the theme\'s colours', () {
      final theme = SupporterTheme.arctic;
      final data = GlassTheme.build(theme.accent, theme.surfaces);
      expect(data.scaffoldBackgroundColor, theme.surfaces.background);
      expect(data.colorScheme.primary, theme.primary);
      expect(data.colorScheme.surface, theme.surfaces.surface);
      expect(data.dialogTheme.backgroundColor, theme.surfaces.raised);
      expect(data.bottomSheetTheme.backgroundColor, theme.surfaces.raised);
      expect(data.colorScheme.onSurfaceVariant, theme.surfaces.textSecondary);
      // TV keeps its focus styling over the same colours.
      final tv = GlassTheme.buildTv(theme.accent, theme.surfaces);
      expect(tv.scaffoldBackgroundColor, theme.surfaces.background);
      expect(tv.focusColor, theme.primary.withValues(alpha: .26));
    });

    test('Classic keeps the colours Reelish had', () {
      expect(GlassTheme.background, const Color(0xFF0B0B0F));
      expect(GlassTheme.surface, const Color(0xFF15151C));
      expect(GlassTheme.elevatedSurface, const Color(0xFF202029));
      expect(GlassTheme.muted, const Color(0xFFA5A5B2));
      expect(GlassTheme.border, const Color(0x1AFFFFFF));
      expect(GlassTheme.glassTint, const Color(0xFF111722));
      expect(ThemeSurfaces.classic.sidebar, const Color(0xFF0D0D12));
    });
  });

  group('The app theme', () {
    test('a supporter\'s theme sets the page colours and the accent', () async {
      final (appearance, _) = await _appearance(['supporter']);
      await appearance.setTheme('aurora');
      expect(appearance.theme, SupporterTheme.aurora);
      expect(appearance.value.id, 'theme:aurora');
      expect(GlassTheme.primary, SupporterTheme.aurora.primary);
      expect(GlassTheme.background, SupporterTheme.aurora.surfaces.background);
      expect(GlassTheme.surface, SupporterTheme.aurora.surfaces.surface);
      expect(GlassTheme.muted, SupporterTheme.aurora.surfaces.textSecondary);
    });

    test('the Founder can use every theme without donating', () async {
      final (appearance, _) = await _appearance(['founder']);
      for (final theme in SupporterTheme.all) {
        await appearance.setTheme(theme.id);
        expect(appearance.theme, theme);
        expect(GlassTheme.background, theme.surfaces.background);
      }
    });

    test('someone without the perk cannot set one', () async {
      final (appearance, _) = await _appearance(['free']);
      await appearance.setTheme('arctic');
      expect(appearance.themeId, isNull);
      expect(GlassTheme.primary, GlassTheme.coral.primary);
      expect(GlassTheme.surfaces, ThemeSurfaces.classic);
    });

    test('a theme saved on the device does nothing without the perk', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.appearance.theme': 'rose_noir',
      });
      final (appearance, _) = await _appearance(['free']);
      expect(appearance.theme, isNull);
      expect(appearance.value, GlassTheme.coral);
      expect(GlassTheme.surfaces, ThemeSurfaces.classic);
    });

    test('a retired theme saved before opens as its new one', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.appearance.theme': 'golden_hour',
      });
      final (appearance, _) = await _appearance(['supporter']);
      expect(appearance.theme, SupporterTheme.obsidianGold);
      expect(
        GlassTheme.background,
        SupporterTheme.obsidianGold.surfaces.background,
      );
    });

    test('is saved, and comes back after a restart', () async {
      final (first, _) = await _appearance(['supporter']);
      await first.setTheme('ember');
      final (again, _) = await _appearance(['supporter']);
      expect(again.theme, SupporterTheme.ember);
      expect(GlassTheme.background, SupporterTheme.ember.surfaces.background);
    });

    test('Classic turns the theme off', () async {
      final (appearance, _) = await _appearance(['supporter']);
      await appearance.setTheme('arctic');
      await appearance.setTheme(null);
      expect(appearance.theme, isNull);
      expect(GlassTheme.surfaces, ThemeSurfaces.classic);
      final (again, _) = await _appearance(['supporter']);
      expect(again.theme, isNull);
    });

    test('an accent picked under a theme replaces only its accent', () async {
      final (appearance, _) = await _appearance(['supporter']);
      await appearance.setTheme('arctic');
      await appearance.update(GlassTheme.teal);
      expect(appearance.theme, SupporterTheme.arctic);
      expect(appearance.usesThemeAccent, isFalse);
      expect(GlassTheme.primary, GlassTheme.teal.primary);
      expect(GlassTheme.background, SupporterTheme.arctic.surfaces.background);
      // Kept after a restart.
      final (again, _) = await _appearance(['supporter']);
      expect(again.theme, SupporterTheme.arctic);
      expect(again.value, GlassTheme.teal);
      // And back to the theme's own.
      await again.useThemeAccent();
      expect(GlassTheme.primary, SupporterTheme.arctic.primary);
      final (third, _) = await _appearance(['supporter']);
      expect(third.usesThemeAccent, isTrue);
    });

    test('choosing a theme brings its own accent back', () async {
      final (appearance, _) = await _appearance(['supporter']);
      await appearance.setTheme('arctic');
      await appearance.update(GlassTheme.teal);
      await appearance.setTheme('ember');
      expect(appearance.usesThemeAccent, isTrue);
      expect(GlassTheme.primary, SupporterTheme.ember.primary);
    });

    test('when support ends, Classic and the picked accent return; the theme '
        'waits', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.appearance.accent': GlassTheme.blue.id,
      });
      final (appearance, supporters) = await _appearance(['supporter', 'free']);
      await appearance.setTheme('velvet_cinema');
      expect(GlassTheme.primary, SupporterTheme.velvetCinema.primary);
      await supporters.refresh();
      expect(appearance.theme, isNull);
      expect(GlassTheme.primary, GlassTheme.blue.primary);
      expect(GlassTheme.surfaces, ThemeSurfaces.classic);
      expect(appearance.themeId, 'velvet_cinema');
    });
  });

  group('Settings > Appearance', () {
    Future<AccentSettingsController> show(
      WidgetTester tester,
      String entitlement, {
      Size size = const Size(412, 2000),
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

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('a supporter previews a theme, then applies it', (
      tester,
    ) async {
      final appearance = await show(tester, 'supporter');
      expect(find.text('THEMES'), findsOneWidget);
      await tester.tap(find.text('Arctic'));
      await tester.pumpAndSettle();
      // Nothing changes until the preview is confirmed.
      expect(find.byType(ThemePreview), findsOneWidget);
      expect(appearance.theme, isNull);
      // The preview is drawn in the theme's own Material theme.
      final preview = Theme.of(tester.element(find.byType(ThemePreview)));
      expect(
        preview.scaffoldBackgroundColor,
        SupporterTheme.arctic.surfaces.background,
      );
      expect(preview.colorScheme.primary, SupporterTheme.arctic.primary);
      await tester.tap(find.text('Apply theme'));
      await settle(tester);
      expect(appearance.theme, SupporterTheme.arctic);
      await tester.pumpAndSettle();
      expect(find.byType(ThemePreview), findsNothing);
      expect(find.textContaining('brings its own accent'), findsOneWidget);
    });

    testWidgets('closing the preview changes nothing', (tester) async {
      final appearance = await show(tester, 'supporter');
      await tester.tap(find.text('Ember'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(appearance.theme, isNull);
    });

    testWidgets('under a theme, the accent can go back to the theme\'s', (
      tester,
    ) async {
      final appearance = await show(tester, 'supporter');
      await tester.runAsync(() async {
        await appearance.setTheme('aurora');
        await appearance.update(GlassTheme.teal);
      });
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Theme'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Theme'));
      await settle(tester);
      expect(appearance.usesThemeAccent, isTrue);
      expect(GlassTheme.primary, SupporterTheme.aurora.primary);
    });

    testWidgets('someone else previews the themes, and learns why', (
      tester,
    ) async {
      final appearance = await show(tester, 'free');
      expect(
        find.bySemanticsLabel(RegExp('Aurora theme.*for Reelish Supporters')),
        findsOneWidget,
      );
      // Classic is theirs, and in use.
      expect(
        find.bySemanticsLabel(RegExp('Classic theme.*selected')),
        findsOneWidget,
      );
      await tester.tap(find.text('Aurora'));
      await tester.pumpAndSettle();
      expect(find.byType(ThemePreview), findsOneWidget);
      expect(find.text('Apply theme'), findsNothing);
      await tester.tap(find.text('Learn more'));
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

    testWidgets('TV: the remote opens a preview and applies it', (
      tester,
    ) async {
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
        size: const Size(1920, 2600),
      );
      Focus.of(tester.element(find.text('Rosé Noir'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(ThemePreview), findsOneWidget);
      // Apply has the focus, so one more press applies.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(appearance.theme, SupporterTheme.roseNoir);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Windows: the collection lays out in even columns',
      (tester) async {
        await show(tester, 'supporter', size: const Size(1280, 1800));
        expect(
          tester.getTopLeft(find.text('Velvet Cinema')).dy,
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
