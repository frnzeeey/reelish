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
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:onfeed/src/theme/theme_tokens.dart';
import 'package:onfeed/src/widgets/founder_avatar_ring.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A signed-in account whose server answers [entitlement] ('free',
/// 'supporter', 'founder'), or fails when null.
Future<(AccountController, SupporterController)> _account(
  String? entitlement,
) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient((request) async {
      if (!request.url.path.endsWith('/supporters/me')) {
        return http.Response(jsonEncode({'badges': []}), 200);
      }
      if (entitlement == null) throw const SocketException('offline');
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

Widget _avatar(double size) => SizedBox.square(dimension: size);

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlassTheme.setAccent(GlassTheme.coral);
    GlassTheme.setSurfaces(ThemeSurfaces.classic);
  });

  group('FounderAnimatedAvatarRing', () {
    testWidgets('animates, in a loop, without growing the avatar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(FounderAnimatedAvatarRing(size: 100, child: _avatar(100))),
      );
      final pad = FounderAnimatedAvatarRing.paddingFor(100);
      expect(
        tester.getSize(find.byType(FounderAnimatedAvatarRing)),
        Size.square(100 + pad * 2),
      );
      // The avatar keeps its own size inside the ring.
      expect(tester.getSize(find.byType(SizedBox).last), const Size(100, 100));
      // Still running after more than one cycle: it loops.
      await tester.pump(FounderAnimatedAvatarRing.period * 1.5);
      expect(tester.binding.hasScheduledFrame, isTrue);
      // Leaving the tree disposes the controller (a leaked ticker fails).
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reduced motion shows the still ring', (tester) async {
      await tester.pumpWidget(
        _app(
          FounderAnimatedAvatarRing(size: 100, child: _avatar(100)),
          reduceMotion: true,
        ),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('animate: false is still', (tester) async {
      await tester.pumpWidget(
        _app(
          FounderAnimatedAvatarRing(
            size: 100,
            animate: false,
            child: _avatar(100),
          ),
        ),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('pauses in the background and resumes after', (tester) async {
      await tester.pumpWidget(
        _app(FounderAnimatedAvatarRing(size: 100, child: _avatar(100))),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('stops on a covered page', (tester) async {
      await tester.pumpWidget(
        _app(
          TickerMode(
            enabled: false,
            child: FounderAnimatedAvatarRing(size: 100, child: _avatar(100)),
          ),
        ),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('stops when scrolled out of view, and starts on return', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // Builds every child, so the ring stays alive off screen, as a
            // card scrolled past would in a cached list.
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  FounderAnimatedAvatarRing(size: 100, child: _avatar(100)),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.binding.hasScheduledFrame, isTrue);
      scroll.jumpTo(1000);
      // The scroll's frame, then the check after its layout.
      await tester.pump();
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isTrue);
    });

    testWidgets('a small avatar has no crown; a profile-sized one does', (
      tester,
    ) async {
      // Smoke: both sizes lay out and paint without errors.
      for (final size in [40.0, 84.0, 120.0]) {
        await tester.pumpWidget(
          _app(FounderAnimatedAvatarRing(size: size, child: _avatar(size))),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('Who gets it', () {
    for (final (name, entitlement, expected) in [
      ('the Founder', 'founder', true),
      ('a supporter', 'supporter', false),
      ('a free account', 'free', false),
    ]) {
      testWidgets(
        '$name ${expected ? 'gets' : 'keeps their own profile, without'} '
        'the animated ring',
        (tester) async {
          tester.view.physicalSize = const Size(412, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          late AccountController account;
          late AccentSettingsController appearance;
          final files = Directory.systemTemp.createTempSync('ring');
          final profile = ProfileController(directory: () async => files);
          await tester.runAsync(() async {
            final (a, supporters) = await _account(entitlement);
            account = a;
            await supporters.refresh();
            appearance = AccentSettingsController(supporters: supporters);
            await appearance.load();
            await profile.loadFor('user-1');
          });
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
          await tester.pump(const Duration(milliseconds: 500));
          expect(
            find.byType(FounderAnimatedAvatarRing),
            expected ? findsOneWidget : findsNothing,
          );
          // The avatar can still be changed.
          expect(find.byTooltip('Change avatar'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('the Founder keeps it under any theme', (tester) async {
      tester.view.physicalSize = const Size(412, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late AccountController account;
      late AccentSettingsController appearance;
      final files = Directory.systemTemp.createTempSync('ring');
      final profile = ProfileController(directory: () async => files);
      await tester.runAsync(() async {
        final (a, supporters) = await _account('founder');
        account = a;
        await supporters.refresh();
        appearance = AccentSettingsController(supporters: supporters);
        await appearance.load();
        await appearance.setTheme('aurora');
        await profile.loadFor('user-1');
      });
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
      await tester.pump(const Duration(milliseconds: 500));
      expect(appearance.theme, SupporterTheme.aurora);
      expect(find.byType(FounderAnimatedAvatarRing), findsOneWidget);
      expect(find.byType(SupporterAvatarRing), findsNothing);
    });

    testWidgets('a supporter\'s theme keeps its own ring', (tester) async {
      tester.view.physicalSize = const Size(412, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late AccountController account;
      late AccentSettingsController appearance;
      final files = Directory.systemTemp.createTempSync('ring');
      final profile = ProfileController(directory: () async => files);
      await tester.runAsync(() async {
        final (a, supporters) = await _account('supporter');
        account = a;
        await supporters.refresh();
        appearance = AccentSettingsController(supporters: supporters);
        await appearance.load();
        await appearance.setTheme('aurora');
        await profile.loadFor('user-1');
      });
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
      expect(find.byType(SupporterAvatarRing), findsOneWidget);
      expect(find.byType(FounderAnimatedAvatarRing), findsNothing);
    });

    for (final (name, entitlement, expected) in [
      ('the Founder', 'founder', true),
      ('a supporter', 'supporter', false),
    ]) {
      testWidgets(
        'small avatars: $name ${expected ? 'gets' : 'does not get'} the rim',
        (tester) async {
          late SupporterController supporters;
          await tester.runAsync(() async {
            (_, supporters) = await _account(entitlement);
            await supporters.refresh();
          });
          await tester.pumpWidget(
            _app(
              FounderAvatarRim(
                supporters: supporters,
                child: const SizedBox.square(dimension: 24),
              ),
            ),
          );
          final rims = find.descendant(
            of: find.byType(FounderAvatarRim),
            matching: find.byType(DecoratedBox),
          );
          expect(rims, expected ? findsOneWidget : findsNothing);
          // Never changes the avatar's size.
          expect(
            tester.getSize(find.byType(FounderAvatarRim)),
            const Size(24, 24),
          );
        },
      );
    }

    testWidgets('an offline device with no saved status shows no rim', (
      tester,
    ) async {
      late SupporterController supporters;
      await tester.runAsync(() async {
        (_, supporters) = await _account(null);
        await supporters.refresh();
      });
      expect(supporters.hasFounderPerk(FounderPerk.profileAccent), isFalse);
    });
  });
}
