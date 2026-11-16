import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:onfeed/src/screens/spotlight_experience_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/spotlight/spotlight_deck.dart';
import 'package:onfeed/src/spotlight/spotlight_motion.dart';
import 'package:onfeed/src/spotlight/spotlight_motion_controller.dart';
import 'package:onfeed/src/theme/reelish_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

const _key = 'onfeed.appearance.spotlight_motion';

/// An account whose GET /supporters/me answers [entitlements] in turn
/// ('free', 'supporter', 'founder'; null fails as if offline), refreshed once.
Future<SupporterController> _supporters(List<String?> entitlements) async {
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
  final supporters = SupporterController(account: account, api: api);
  await supporters.refresh();
  return supporters;
}

Future<SpotlightMotionController> _motion(List<String?> entitlements) async {
  final controller = SpotlightMotionController(
    supporters: await _supporters(entitlements),
  );
  await controller.load();
  return controller;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Presets', () {
    test('ids are unique and stable; only two are free', () {
      final ids = SpotlightMotion.values.map((m) => m.id).toSet();
      expect(ids, hasLength(SpotlightMotion.values.length));
      for (final motion in SpotlightMotion.values) {
        expect(SpotlightMotion.byId(motion.id), motion);
      }
      expect(SpotlightMotion.byId('not_a_preset'), isNull);
      expect(SpotlightMotion.byId(null), isNull);
      expect(SpotlightMotion.values.where((m) => !m.exclusive), [
        SpotlightMotion.cinematicDepth,
        SpotlightMotion.minimal,
      ]);
      expect(SpotlightMotion.fallback.exclusive, isFalse);
    });

    test('the shown card is whole and in front in every preset', () {
      for (final motion in SpotlightMotion.values) {
        final frame = motion.style.frame(0, 300);
        expect(frame.opacity, 1, reason: motion.label);
        expect(frame.reveal, 1, reason: motion.label);
        expect(frame.imageScale, 1, reason: motion.label);
        // No turn and no shift: the shown card sits where it is laid out.
        final m = frame.transform;
        expect(
          m.getTranslation().x.abs(),
          lessThan(.001),
          reason: motion.label,
        );
        expect(m.entry(0, 0), closeTo(1, .001), reason: motion.label);
      }
    });

    test('the presets move a neighbour differently from one another', () {
      String signature(SpotlightMotion motion) {
        final frame = motion.style.frame(.5, 300, float: .2);
        return [
          ...frame.transform.storage.map((v) => v.toStringAsFixed(3)),
          frame.opacity.toStringAsFixed(3),
          frame.imageScale.toStringAsFixed(3),
          frame.reveal.toStringAsFixed(3),
          motion.style.viewportFraction,
        ].join(',');
      }

      final signatures = SpotlightMotion.values.map(signature).toSet();
      expect(signatures, hasLength(SpotlightMotion.values.length));
    });

    test('only Minimal Motion is flat; only Floating needs a ticker', () {
      bool turns(SpotlightMotion motion) {
        final m = motion.style.frame(.6, 300).transform;
        // A perspective entry, or a rotation in the plane.
        return m.entry(3, 2) != 0 || m.entry(0, 1).abs() > .001;
      }

      expect(turns(SpotlightMotion.minimal), isFalse);
      expect(turns(SpotlightMotion.cinematicDepth), isTrue);
      expect(turns(SpotlightMotion.coverFlow), isTrue);
      expect(turns(SpotlightMotion.stacked), isTrue);
      expect(SpotlightMotion.values.where((m) => m.style.floats), [
        SpotlightMotion.floating,
      ]);
    });

    test(
      'Spotlight Reveal staggers its lines; the others show them together',
      () {
        final reveal = SpotlightMotion.reveal.style;
        final first = reveal.lineReveal(.5, 0);
        final last = reveal.lineReveal(.5, 4);
        expect(first, greaterThan(last));
        expect(reveal.lineReveal(1, 4), 1);
        final depth = SpotlightMotion.cinematicDepth.style;
        expect(depth.lineReveal(.5, 0), depth.lineReveal(.5, 4));
      },
    );
  });

  group('Entitlement and saving', () {
    test(
      'a free account keeps the free presets and cannot take another',
      () async {
        final motion = await _motion(['free']);
        expect(motion.value, SpotlightMotion.cinematicDepth);
        expect(await motion.select(SpotlightMotion.coverFlow), isFalse);
        expect(motion.value, SpotlightMotion.cinematicDepth);
        expect(motion.saved, SpotlightMotion.cinematicDepth);
        expect(await motion.select(SpotlightMotion.minimal), isTrue);
        expect(motion.value, SpotlightMotion.minimal);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(_key), 'minimal');
      },
    );

    test(
      'an exclusive preset written into the settings by hand does not apply',
      () async {
        SharedPreferences.setMockInitialValues({_key: 'stacked_motion'});
        final motion = await _motion(['free']);
        expect(motion.saved, SpotlightMotion.stacked);
        expect(motion.value, SpotlightMotion.cinematicDepth);
      },
    );

    test('an unknown or old id opens as the default', () async {
      SharedPreferences.setMockInitialValues({_key: 'warp_speed'});
      final motion = await _motion(['supporter']);
      expect(motion.saved, SpotlightMotion.cinematicDepth);
      expect(motion.value, SpotlightMotion.cinematicDepth);
    });

    test('a supporter chooses any preset, kept across a restart', () async {
      final motion = await _motion(['supporter']);
      expect(await motion.select(SpotlightMotion.reveal), isTrue);
      expect(motion.value, SpotlightMotion.reveal);
      final again = await _motion(['supporter']);
      expect(again.value, SpotlightMotion.reveal);
    });

    test(
      'the Founder has them too, through the supporter entitlement',
      () async {
        final motion = await _motion(['founder']);
        expect(await motion.select(SpotlightMotion.floating), isTrue);
        expect(motion.value, SpotlightMotion.floating);
      },
    );

    test(
      'losing the perk falls back at once, and the choice returns with it',
      () async {
        final supporters = await _supporters([
          'supporter',
          'free',
          'supporter',
        ]);
        final motion = SpotlightMotionController(supporters: supporters);
        await motion.load();
        await motion.select(SpotlightMotion.coverFlow);
        var notified = 0;
        motion.addListener(() => notified++);

        await supporters.refresh();
        expect(motion.value, SpotlightMotion.cinematicDepth);
        expect(motion.saved, SpotlightMotion.coverFlow);
        expect(notified, greaterThan(0));

        await supporters.refresh();
        expect(motion.value, SpotlightMotion.coverFlow);
      },
    );
  });

  group('Carousel', () {
    Widget deck(
      SpotlightMotion motion, {
      required PageController controller,
      VoidCallback? onUserScroll,
      ValueChanged<int>? onPageChanged,
    }) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: Builder(
              builder: (context) => SpotlightDeck(
                controller: controller,
                style: SpotlightDeck.styleFor(context, motion),
                itemCount: null,
                onUserScroll: onUserScroll,
                onPageChanged: onPageChanged,
                itemBuilder: (context, index) => ColoredBox(
                  color: Colors.primaries[index % Colors.primaries.length],
                  child: Center(
                    child: SpotlightReveal(
                      order: 0,
                      child: Text('Card $index'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    for (final motion in SpotlightMotion.values) {
      testWidgets('${motion.label}: swipes, turns and stops cleanly', (
        tester,
      ) async {
        final controller = SpotlightDeck.controllerFor(motion.style);
        addTearDown(controller.dispose);
        var dragged = 0;
        var page = 0;
        await tester.pumpWidget(
          deck(
            motion,
            controller: controller,
            onUserScroll: () => dragged++,
            onPageChanged: (p) => page = p,
          ),
        );
        // Floating bobs for as long as it shows, so it never settles.
        Future<void> settle() async {
          if (!motion.style.floats) {
            await tester.pumpAndSettle();
            return;
          }
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        expect(find.text('Card 0'), findsOneWidget);
        await tester.fling(find.text('Card 0'), const Offset(-300, 0), 1500);
        await settle();
        expect(dragged, 1);
        // A fling may cross more than one of Cover Flow's narrow cards.
        expect(page, greaterThanOrEqualTo(1));
        // Rapid turns, as an automatic turn and a swipe could overlap.
        unawaited(
          controller.animateToPage(
            2,
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeInOutCubic,
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        unawaited(
          controller.animateToPage(
            3,
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeInOutCubic,
          ),
        );
        await settle();
        expect(page, 3);
        expect(tester.takeException(), isNull);
        // Gone without a ticker left running (Floating's included).
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets(
      'a peeking neighbour takes no taps on its controls, and a tap brings '
      'it forward',
      (tester) async {
        final controller = SpotlightDeck.controllerFor(
          SpotlightMotion.coverFlow.style,
        );
        addTearDown(controller.dispose);
        var page = 0;
        await tester.pumpWidget(
          deck(
            SpotlightMotion.coverFlow,
            controller: controller,
            onPageChanged: (p) => page = p,
          ),
        );
        await tester.pumpAndSettle();
        // Built and peeking at the side, but not a target.
        expect(find.text('Card 1'), findsOneWidget);
        expect(find.text('Card 1').hitTestable(), findsNothing);
        expect(find.text('Card 0').hitTestable(), findsOneWidget);
        final box = tester.getRect(find.byType(SpotlightDeck));
        await tester.tapAt(Offset(box.right - 12, box.center.dy));
        await tester.pumpAndSettle();
        expect(page, 1);
        expect(find.text('Card 1').hitTestable(), findsOneWidget);
      },
    );

    testWidgets("a swipe never rebuilds a card's content, in any preset", (
      tester,
    ) async {
      for (final motion in SpotlightMotion.values) {
        final controller = SpotlightDeck.controllerFor(motion.style);
        // Creations per card: a card's content is made when it first shows,
        // never again while it stays.
        final created = <int, int>{};
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: SpotlightDeck(
                    controller: controller,
                    style: motion.style,
                    itemCount: 3,
                    itemBuilder: (context, index) => _CountsCreation(
                      onCreate: () =>
                          created[index] = (created[index] ?? 0) + 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // Across the fade and shadow thresholds, and back.
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(SpotlightDeck)),
        );
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(const Offset(-30, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(const Offset(30, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          created.values.every((count) => count == 1),
          isTrue,
          reason: '${motion.label}: $created',
        );
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      }
    });

    testWidgets('reduced motion shows Minimal Motion', (tester) async {
      late SpotlightMotionStyle shown;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              shown = SpotlightDeck.styleFor(
                context,
                SpotlightMotion.coverFlow,
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(shown, same(SpotlightMotion.minimal.style));
    });
  });

  group('Spotlight Experience', () {
    Future<void> open(
      WidgetTester tester,
      SpotlightMotionController motion,
    ) async {
      tester.view.physicalSize = const Size(800, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SpotlightExperienceScreen(controller: motion)),
        ),
      );
      await tester.pump();
    }

    testWidgets(
      'free: every preset previews; the exclusive ones are locked and explain why',
      (tester) async {
        final motion = await tester.runAsync(() => _motion(['free']));
        await open(tester, motion!);
        // The four exclusive presets carry a lock.
        expect(find.byIcon(ReelishIcons.lock), findsNWidgets(4));
        await tester.tap(find.text('Classic Cover Flow'));
        await tester.pump();
        expect(find.text('Previewing'), findsOneWidget);
        await tester.tap(find.text('Supporters only'));
        await tester.pumpAndSettle();
        expect(find.text('Spotlight animations'), findsOneWidget);
        expect(find.text('Become a Supporter'), findsOneWidget);
        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();
        expect(motion.value, SpotlightMotion.cinematicDepth);

        await tester.tap(find.text('Minimal Motion'));
        await tester.pump();
        await tester.tap(find.text('Use this'));
        await tester.pump();
        expect(motion.value, SpotlightMotion.minimal);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('supporter: applies an exclusive preset', (tester) async {
      final motion = await tester.runAsync(() => _motion(['supporter']));
      await open(tester, motion!);
      expect(find.byIcon(ReelishIcons.lock), findsNothing);
      await tester.tap(find.text('Stacked Motion'));
      await tester.pump();
      await tester.tap(find.text('Use this'));
      await tester.pump();
      expect(motion.value, SpotlightMotion.stacked);
      expect(find.text('In use'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Appearance', () {
    Future<void> appearance(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = AccentSettingsController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppearanceSettingsScreen(
              controller: controller,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('offers Spotlight Experience on a phone', (tester) async {
      await appearance(tester);
      expect(find.text('Spotlight Experience'), findsOneWidget);
    });

    testWidgets('not on TV, whose Home has no Spotlight', (tester) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      await appearance(tester);
      expect(find.text('Spotlight Experience'), findsNothing);
    });
  });
}

/// Counts how often it is created: a card's content made again means it was
/// thrown away and rebuilt.
class _CountsCreation extends StatefulWidget {
  const _CountsCreation({required this.onCreate});

  final VoidCallback onCreate;

  @override
  State<_CountsCreation> createState() => _CountsCreationState();
}

class _CountsCreationState extends State<_CountsCreation> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.teal);
}
