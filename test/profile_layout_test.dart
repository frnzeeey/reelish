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
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/screens/supporters_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/account_badges.dart';
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
  bool library = false,
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
    if (library) {
      // One title watched and one on My list, so the counts show.
      StorageService.debugResetWrites();
      final storage = StorageService(filesDirectory: () async => files);
      const title = MediaItem(id: '1', type: 'movie', name: 'A');
      await storage.saveProgress(title, 1000, durationMs: 7200000);
      await storage.toggleFavorite(title);
    }
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
  if (library) {
    // The page reads the library from disk, which needs real time.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }
  return profile;
}

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    loader.addFont(
      Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
    );
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    // The real fonts: the test font is far wider, so it would put the
    // capsule under every name.
    await _font('ReelishIcons', ['assets/fonts/ReelishIcons.otf']);
    await _font('Montserrat', [
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
        'assets/fonts/Montserrat-$weight.ttf',
    ]);
  });
  tearDown(() => GlassTheme.setAccent(GlassTheme.coral));

  group('Identity, Personalize and Account', () {
    testWidgets('every part once, and nothing repeated', (tester) async {
      await _show(tester);
      expect(find.text('PERSONALIZE'), findsOneWidget);
      expect(find.text('ACCOUNT'), findsOneWidget);
      // The identity card says who you are; no section repeats it.
      expect(find.text('MEMBERSHIP'), findsNothing);
      // One way into the avatar picker: the button on the avatar.
      expect(find.byTooltip('Change avatar'), findsOneWidget);
      expect(find.text('Avatar'), findsNothing);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Manage account'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
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

  group('Identity capsules', () {
    testWidgets('a free account carries none', (tester) async {
      await _show(tester);
      expect(find.byType(FounderBadge), findsNothing);
      expect(find.byType(SupporterBadge), findsNothing);
    });

    testWidgets('a supporter carries the Supporter capsule', (tester) async {
      await _show(tester, entitlement: 'supporter', badges: ['supporter']);
      expect(find.byType(SupporterBadge), findsOneWidget);
      expect(find.text(SupporterBadge.shortLabel), findsOneWidget);
      expect(find.byType(FounderBadge), findsNothing);
    });

    testWidgets('the Founder carries Sovereign, once, under the '
        'name', (tester) async {
      await _show(tester, entitlement: 'founder', badges: ['founder']);
      expect(find.byType(FounderBadge), findsOneWidget);
      expect(find.text(FounderBadge.title), findsOneWidget);
      // Founder without a donation: no Supporter capsule they did not earn.
      expect(find.byType(SupporterBadge), findsNothing);
      final name = tester.getRect(find.text('Sam'));
      final capsule = tester.getRect(find.byType(FounderBadge));
      // Under the name, centred with it.
      expect(capsule.top, greaterThan(name.bottom));
      expect((capsule.center.dx - name.center.dx).abs(), lessThan(2));
    });

    testWidgets('Founder and Supporter capsules share one geometry', (
      tester,
    ) async {
      await _show(
        tester,
        entitlement: 'founder',
        badges: ['founder', 'supporter'],
      );
      expect(
        tester.getSize(find.byType(FounderBadge)).height,
        tester.getSize(find.byType(SupporterBadge)).height,
      );
    });

    testWidgets('a capsule opens the Supporters page', (tester) async {
      await _show(tester, entitlement: 'founder', badges: ['founder']);
      await tester.tap(find.byType(FounderBadge));
      await tester.pumpAndSettle();
      expect(find.byType(SupportersScreen), findsOneWidget);
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
      'Windows: the identity across the top, the sections side by side',
      (tester) async {
        await _show(tester, size: const Size(1280, 900));
        final avatar = tester.getCenter(find.byTooltip('Change avatar'));
        final name = tester.getCenter(find.text('Sam'));
        // An empty library: its one line sits with the name, beside the avatar.
        final hint = tester.getTopLeft(
          find.text('Titles you watch and add to My list show up here.'),
        );
        expect(name.dx, greaterThan(avatar.dx));
        expect(hint.dx, greaterThan(avatar.dx));
        expect(hint.dy, greaterThan(name.dy));
        // Each section's first tile, on one line.
        final theme = tester.getTopLeft(find.text('Avatar frame'));
        final account = tester.getTopLeft(find.text('Manage account'));
        expect(theme.dy, account.dy);
        expect(account.dx, greaterThan(theme.dx));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('a phone stacks the parts', (tester) async {
      await _show(tester);
      expect(
        tester.getTopLeft(find.text('Theme')).dy,
        greaterThan(tester.getBottomLeft(find.text('Sam')).dy),
      );
    });

    testWidgets('a small phone fits, with both badges and the counts', (
      tester,
    ) async {
      await _show(
        tester,
        entitlement: 'founder',
        badges: ['founder', 'supporter'],
        size: const Size(320, 1400),
        library: true,
      );
      // Each count on one line, in a column of its own, whole.
      final watched = tester.getRect(find.bySemanticsLabel('1 Watched'));
      final progress = tester.getRect(find.bySemanticsLabel('1 In progress'));
      final myList = tester.getRect(find.bySemanticsLabel('1 On My list'));
      // On one line (a label shrunk to fit may sit a fraction lower).
      expect(watched.center.dy, closeTo(progress.center.dy, 1));
      expect(progress.center.dy, closeTo(myList.center.dy, 1));
      expect(watched.right, lessThanOrEqualTo(progress.left));
      expect(progress.right, lessThanOrEqualTo(myList.left));
      expect(tester.takeException(), isNull);
    });
  });

  group('The counts, apart from the identity', () {
    testWidgets('phone: along the card foot, under the name and badges', (
      tester,
    ) async {
      await _show(
        tester,
        entitlement: 'supporter',
        badges: ['supporter'],
        library: true,
      );
      final name = tester.getRect(find.text('Sam'));
      final trakt = tester.getRect(find.text('Signed in with Trakt'));
      final badge = tester.getRect(find.byType(SupporterBadge));
      final watched = tester.getRect(find.bySemanticsLabel('1 Watched'));
      // Name, then the account it signs in with, then the badge.
      expect(trakt.top, greaterThanOrEqualTo(name.bottom));
      expect(badge.top, greaterThan(trakt.bottom));
      expect(watched.top, greaterThan(badge.bottom));
      // Each count is a node of its own for a screen reader (a button where
      // the library can open; here nothing opens it), and each badge is a
      // button: not folded into the name and the rest of the page.
      expect(
        tester.getSemantics(find.bySemanticsLabel('1 Watched')).label,
        '1 Watched',
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel(SupporterBadge.label)),
        isSemantics(
          label: SupporterBadge.label,
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('Sam')).label,
        isNot(contains('Watched')),
      );
    });

    testWidgets(
      'Windows: beside the identity, where the card has room',
      (tester) async {
        await _show(tester, size: const Size(1280, 900), library: true);
        final avatar = tester.getCenter(find.byTooltip('Change avatar'));
        final name = tester.getRect(find.text('Sam'));
        final watched = tester.getRect(find.bySemanticsLabel('1 Watched'));
        expect(watched.left, greaterThan(name.right));
        // On the identity's row, not below it.
        expect(watched.center.dy, lessThan(avatar.dy));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('TV: along the card foot, below the avatar', (tester) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      await _show(tester, size: const Size(820, 1400), library: true);
      final avatar = tester.getRect(find.byTooltip('Change avatar'));
      final watched = tester.getRect(find.bySemanticsLabel('1 Watched'));
      expect(watched.top, greaterThan(avatar.bottom));
      expect(tester.takeException(), isNull);
    });
  });
}
