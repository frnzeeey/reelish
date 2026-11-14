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
import 'package:onfeed/src/screens/profile_stats_screen.dart';
import 'package:onfeed/src/screens/profile_style_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/profile_styles.dart';
import 'package:onfeed/src/theme/supporter_themes.dart';
import 'package:onfeed/src/widgets/profile_card_backdrop.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// WCAG contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

const _cinematic = ProfileStyle(
  backdrop: 'spotlight',
  color: 'custom:4fc3f7',
  effect: ProfileEffect.drift,
);

/// The profile page for an account with [entitlement], with [style] already
/// saved for it. Returns the profile controller, to read what was saved.
Future<ProfileController> _show(
  WidgetTester tester, {
  String entitlement = 'free',
  Map<String, Object?>? style,
  String? theme,
}) async {
  SharedPreferences.setMockInitialValues({
    ProfileController.storageKey: jsonEncode({
      'u': {'displayName': 'Sam', 'avatar': 'initial', 'style': ?style},
    }),
    'onfeed.appearance.theme': ?theme,
  });
  tester.view.physicalSize = const Size(412, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final files = Directory.systemTemp.createTempSync('profile-style');
  late AccountController account;
  late AccountBadges badges;
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
                    'status': entitlement == 'supporter' ? 'verified' : 'none',
                    'since': null,
                    'recognition': {'listed': false, 'name': ''},
                    'entitlement': entitlement,
                  }
                : {
                    'user': {'id': 'u', 'username': 'sam_r'},
                    'badges': [],
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
    badges = AccountBadges(account: account);
    profile = ProfileController(directory: () async => files);
    await profile.loadFor('u');
    appearance = AccentSettingsController(supporters: supporters);
    await appearance.load();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: GlassTheme.dark,
      home: Scaffold(
        body: ProfileScreen(
          storage: StorageService(filesDirectory: () async => files),
          account: account,
          profile: profile,
          badges: badges,
          appearance: appearance,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  return profile;
}

Future<void> _openStylePage(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Profile card'));
  await tester.tap(find.text('Profile card'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  expect(find.byType(ProfileStyleScreen), findsOneWidget);
}

/// Taps a choice on the Profile card page, scrolling to it first.
Future<void> _choose(WidgetTester tester, String label) async {
  final page = find.byType(ProfileStyleScreen);
  final text = find.descendant(of: page, matching: find.text(label));
  // Colours are named by their tooltips.
  final target = text.evaluate().isNotEmpty
      ? text
      : find.descendant(of: page, matching: find.byTooltip(label));
  await tester.ensureVisible(target.first);
  await tester.pump();
  await tester.tap(target.first);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _apply(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Apply'));
  await tester.tap(find.text('Apply'));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  tearDown(() => GlassTheme.setAccent(GlassTheme.coral));

  group('The catalog', () {
    test('ids are unique and only Cinematic is for supporters', () {
      final ids = ProfileBackdropStyle.all.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final style in ProfileBackdropStyle.all) {
        expect(
          style.forSupporters,
          style.collection == ProfileBackdropCollection.cinematic,
        );
      }
      expect(
        ProfileBackdropStyle.all.where((s) => !s.forSupporters),
        hasLength(8),
      );
    });

    test('every background keeps the card dark and readable', () {
      for (final style in ProfileBackdropStyle.all) {
        // The card's text, and every preset colour for the counts.
        expect(
          _contrast(Colors.white, style.base),
          greaterThan(12),
          reason: style.id,
        );
        for (final accent in GlassTheme.accents) {
          expect(
            _contrast(accent.primary, style.base),
            greaterThan(4.5),
            reason: '${accent.id} on ${style.id}',
          );
        }
        // Solids and gradients paint their colours in full; the rest only
        // as faint lights.
        if (style.pattern == ProfilePattern.solid ||
            style.pattern == ProfilePattern.gradient) {
          for (final colour in style.colors) {
            expect(
              _contrast(Colors.white, colour),
              greaterThan(7),
              reason: style.id,
            );
          }
        }
      }
    });
  });

  group('A saved style', () {
    test('round-trips, and the standard card saves nothing', () {
      expect(ProfileStyle.standard.toJson(), isNull);
      final json = jsonDecode(jsonEncode(_cinematic.toJson()));
      expect(ProfileStyle.fromJson(json), _cinematic);
    });

    test('drops unknown or tampered parts, one by one', () {
      expect(
        ProfileStyle.fromJson({
          'backdrop': 'not-a-backdrop',
          'color': 'custom:zzzzzz',
          'effect': 'explode',
        }),
        ProfileStyle.standard,
      );
      expect(
        ProfileStyle.fromJson({'backdrop': 'dusk', 'color': 42}),
        const ProfileStyle(backdrop: 'dusk'),
      );
      expect(ProfileStyle.fromJson('dusk'), ProfileStyle.standard);
      expect(ProfileStyle.fromJson(null), ProfileStyle.standard);
    });

    test('needs the perk for Cinematic, effects and any colour of '
        'one\'s own, never for a preset', () {
      expect(const ProfileStyle(backdrop: 'dusk').needsPerk, isFalse);
      expect(const ProfileStyle(color: 'teal').needsPerk, isFalse);
      expect(const ProfileStyle(backdrop: 'spotlight').needsPerk, isTrue);
      expect(const ProfileStyle(effect: ProfileEffect.sheen).needsPerk, isTrue);
      // Typing a preset's own value as a colour still needs the perk.
      final teal = GlassTheme.teal.primary.toARGB32() & 0xFFFFFF;
      expect(
        ProfileStyle(color: 'custom:${teal.toRadixString(16)}').needsPerk,
        isTrue,
      );
    });

    test('without the perk shows its free parts and keeps the rest saved', () {
      const mixed = ProfileStyle(
        backdrop: 'spotlight',
        color: 'teal',
        effect: ProfileEffect.drift,
      );
      expect(mixed.allowed(perk: true), mixed);
      expect(mixed.allowed(perk: false), const ProfileStyle(color: 'teal'));
      expect(_cinematic.allowed(perk: false), ProfileStyle.standard);
      expect(
        const ProfileStyle(backdrop: 'moss').allowed(perk: false),
        const ProfileStyle(backdrop: 'moss'),
      );
    });
  });

  group('ProfileController', () {
    late ProfileController profile;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        ProfileController.storageKey: jsonEncode({
          // Saved before styles existed.
          'a': {'displayName': 'Ana', 'avatar': 'preset', 'preset': 'avatar2'},
        }),
      });
      profile = ProfileController(directory: () async => Directory.systemTemp);
    });

    test('a profile saved before styles has the standard card, and keeps '
        'its name and avatar when a style is saved', () async {
      await profile.loadFor('a');
      expect(profile.style, ProfileStyle.standard);
      expect(
        await profile.setStyle(
          const ProfileStyle(backdrop: 'tide'),
          perk: false,
        ),
        isTrue,
      );
      final reloaded = ProfileController(
        directory: () async => Directory.systemTemp,
      );
      await reloaded.loadFor('a');
      expect(reloaded.style, const ProfileStyle(backdrop: 'tide'));
      expect(reloaded.displayName, 'Ana');
      expect(reloaded.avatar, const ProfileAvatar.preset('avatar2'));
    });

    test(
      'refuses a supporter style without the perk, where it saves',
      () async {
        await profile.loadFor('a');
        expect(await profile.setStyle(_cinematic, perk: false), isFalse);
        expect(profile.style, ProfileStyle.standard);
        expect(await profile.setStyle(_cinematic, perk: true), isTrue);
        expect(profile.style, _cinematic);
      },
    );

    test('keeps each account\'s style apart', () async {
      await profile.loadFor('a');
      await profile.setStyle(const ProfileStyle(backdrop: 'pine'), perk: false);
      await profile.loadFor('b');
      expect(profile.style, ProfileStyle.standard);
      await profile.loadFor('a');
      expect(profile.style, const ProfileStyle(backdrop: 'pine'));
    });

    test('signed out, nothing is saved', () async {
      await profile.loadFor(null);
      expect(
        await profile.setStyle(
          const ProfileStyle(backdrop: 'pine'),
          perk: true,
        ),
        isFalse,
      );
    });
  });

  group('Every account level', () {
    testWidgets('free: a free background applies; a cinematic one previews '
        'but leads to the Supporters page', (tester) async {
      final profile = await _show(tester);
      await _openStylePage(tester);
      await _choose(tester, 'Spotlight');
      expect(find.text('Become a Supporter'), findsOneWidget);
      expect(find.text('Apply'), findsNothing);
      expect(profile.style, ProfileStyle.standard);
      await _choose(tester, 'Dusk');
      await _apply(tester);
      expect(profile.style, const ProfileStyle(backdrop: 'dusk'));
      // A preset colour applies too.
      await _choose(tester, 'Teal');
      await _apply(tester);
      expect(
        profile.style,
        const ProfileStyle(backdrop: 'dusk', color: 'teal'),
      );
      // The effects stay locked.
      await _choose(tester, 'Drift');
      expect(find.text('Become a Supporter'), findsOneWidget);
    });

    for (final entitlement in ['supporter', 'founder']) {
      testWidgets('$entitlement: Cinematic, effects and a colour of their own '
          'apply', (tester) async {
        final profile = await _show(tester, entitlement: entitlement);
        await _openStylePage(tester);
        await _choose(tester, 'Neon Noir');
        await _choose(tester, 'Sheen');
        await _choose(tester, 'Your own');
        expect(find.text('Hue'), findsOneWidget);
        await _apply(tester);
        expect(profile.style.backdrop, 'neon_noir');
        expect(profile.style.effect, ProfileEffect.sheen);
        expect(profile.style.hasCustomColor, isTrue);
      });
    }

    testWidgets('a lapsed supporter sees the standard card; the choice waits '
        'for support to return', (tester) async {
      final profile = await _show(tester, style: _cinematic.toJson());
      final card = find.byType(ProfileScreen);
      expect(
        find.descendant(of: card, matching: find.byType(ProfileCardBackdrop)),
        findsNothing,
      );
      expect(find.byType(ProfileCardEffect), findsNothing);
      expect(profile.style, _cinematic);
    });

    testWidgets('a supporter\'s saved style dresses the card', (tester) async {
      await _show(tester, entitlement: 'supporter', style: _cinematic.toJson());
      final backdrop = tester.widget<ProfileCardBackdrop>(
        find.byType(ProfileCardBackdrop),
      );
      expect(backdrop.style.id, 'spotlight');
      expect(find.byType(ProfileCardEffect), findsOneWidget);
    });
  });

  group('The Profile card page', () {
    testWidgets('a draft is not saved until Apply, and Discard restores the '
        'card', (tester) async {
      final profile = await _show(
        tester,
        style: const ProfileStyle(backdrop: 'moss').toJson(),
      );
      await _openStylePage(tester);
      await _choose(tester, 'Graphite');
      expect(find.text('Not applied yet.'), findsOneWidget);
      expect(profile.style, const ProfileStyle(backdrop: 'moss'));
      await tester.ensureVisible(find.text('Discard changes'));
      await tester.tap(find.text('Discard changes'));
      await tester.pump();
      expect(find.text('This is your card.'), findsOneWidget);
      // Leaving with a draft keeps the card too.
      await _choose(tester, 'Pine');
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 600));
      expect(profile.style, const ProfileStyle(backdrop: 'moss'));
    });

    testWidgets('the profile colour stays on the card: the app accent and '
        'theme are untouched', (tester) async {
      final profile = await _show(tester, entitlement: 'supporter');
      final before = GlassTheme.primary;
      await _openStylePage(tester);
      await _choose(tester, 'Violet');
      await _apply(tester);
      expect(profile.style.color, 'violet');
      expect(GlassTheme.primary, before);
    });

    testWidgets('under an app theme with no card background, the theme '
        'still dresses the card', (tester) async {
      await _show(
        tester,
        entitlement: 'supporter',
        theme: 'aurora',
        style: const ProfileStyle(color: 'teal').toJson(),
      );
      expect(find.byType(SupporterThemeBackdrop), findsOneWidget);
      expect(find.byType(ProfileCardBackdrop), findsNothing);
    });
  });

  testWidgets('TV: the remote picks a background and applies it; the card '
      'stays still', (tester) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    addTearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );
    final profile = await _show(tester, entitlement: 'supporter');
    await _openStylePage(tester);
    final tile = find.descendant(
      of: find.byType(ProfileStyleScreen),
      matching: find.bySemanticsLabel('Midnight background'),
    );
    await tester.ensureVisible(tile);
    Focus.of(
      tester.element(
        find.descendant(of: tile, matching: find.text('Midnight')),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 400));
    await _apply(tester);
    expect(profile.style.backdrop, 'midnight');
    expect(find.textContaining('On TV the card stays still'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('TV focus', () {
    setUp(() {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
    });
    tearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );

    /// Whether the focused node sits inside the tile labelled [label].
    bool focusedOn(WidgetTester tester, String label) {
      final focused = FocusManager.instance.primaryFocus?.context;
      final tile = focused?.findAncestorWidgetOfExactType<TvFocusable>();
      return tile?.semanticLabel?.startsWith('$label background') ?? false;
    }

    /// Presses the button labelled [label] with the remote.
    Future<void> press(WidgetTester tester, String label) async {
      final button = find.text(label);
      await tester.ensureVisible(button);
      Focus.of(tester.element(button)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('the page opens on the current background', (tester) async {
      await _show(
        tester,
        entitlement: 'supporter',
        style: const ProfileStyle(backdrop: 'tide').toJson(),
      );
      await _openStylePage(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(focusedOn(tester, 'Tide'), isTrue);
    });

    testWidgets('Apply, Discard and Standard card leave focus on the '
        'background now chosen', (tester) async {
      final profile = await _show(tester, entitlement: 'supporter');
      await _openStylePage(tester);
      await _choose(tester, 'Pine');
      await press(tester, 'Apply');
      expect(profile.style.backdrop, 'pine');
      expect(find.text('Apply'), findsNothing);
      expect(focusedOn(tester, 'Pine'), isTrue);

      // With the remote: the snack bar from Apply covers the foot of the
      // screen, where a tap would land.
      final moss = find.descendant(
        of: find.byType(ProfileStyleScreen),
        matching: find.text('Moss'),
      );
      await tester.ensureVisible(moss);
      Focus.of(tester.element(moss)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 400));
      await press(tester, 'Discard changes');
      expect(focusedOn(tester, 'Pine'), isTrue);

      await press(tester, 'Standard card');
      expect(find.text('Standard card'), findsNothing);
      expect(focusedOn(tester, 'Standard'), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Viewing statistics opens from the profile', (tester) async {
    await _show(tester);
    await tester.ensureVisible(find.text('Viewing statistics'));
    await tester.tap(find.text('Viewing statistics'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ProfileStatsScreen), findsOneWidget);
  });
}
