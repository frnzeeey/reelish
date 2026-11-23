import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/social/together_screen.dart';
import 'package:onfeed/src/screens/social/together_sections.dart';
import 'package:onfeed/src/screens/watch_party/join_party_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => TogetherActions.findTitle = null);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.dark,
        home: const Scaffold(body: TogetherScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('greets by the hour, and Movie night leads with both ways in', (
    tester,
  ) async {
    var searched = 0;
    TogetherActions.findTitle = () => searched++;
    await pump(tester);
    expect(find.textContaining(greetingFor(DateTime.now())), findsOneWidget);
    expect(find.text('Movie night'), findsOneWidget);
    await tester.tap(find.text('Pick a title to host'));
    expect(searched, 1);
    await tester.tap(find.text('Join with a code'));
    await tester.pumpAndSettle();
    expect(find.byType(JoinPartyScreen), findsOneWidget);
  });

  testWidgets('hosting is for everyone: no Supporter note', (tester) async {
    await pump(tester);
    expect(find.textContaining('Supporters'), findsNothing);
    expect(find.text('Join with a code'), findsOneWidget);
    // Without Home's search (no hook), no button that does nothing.
    expect(find.text('Pick a title to host'), findsNothing);
  });

  test('the greeting follows the hour', () {
    expect(greetingFor(DateTime(2026, 1, 1, 8)), 'Good morning');
    expect(greetingFor(DateTime(2026, 1, 1, 14)), 'Good afternoon');
    expect(greetingFor(DateTime(2026, 1, 1, 21)), 'Good evening');
    expect(greetingFor(DateTime(2026, 1, 1, 2)), 'Good evening');
  });

  group('Before Friends is on', () {
    tearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );

    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: const Scaffold(body: TogetherScreen()),
        ),
      );
      await tester.pump();
    }

    // With no account here, Friends is still loading: its side of the page
    // is the spinner, laid out as Turn on Friends would be.
    testWidgets(
      'a wide Windows page puts Movie night and Friends side by side',
      (tester) async {
        DeviceCapabilities.debugOverride = const DeviceCapabilities(
          hasTouchscreen: false,
          supportsPictureInPicture: false,
        );
        TogetherActions.findTitle = () {};
        await pumpAt(tester, const Size(1100, 900));
        final movieNight = tester.getRect(find.text('Movie night'));
        final friends = tester.getRect(find.byType(CircularProgressIndicator));
        expect(friends.left, greaterThan(movieNight.right));
        // Top-aligned halves: Friends starts beside Movie night, not below.
        expect(friends.top, lessThan(movieNight.bottom + 120));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('a phone keeps one column, with a gap under Movie night', (
      tester,
    ) async {
      TogetherActions.findTitle = () {};
      await pumpAt(tester, const Size(412, 915));
      final join = tester.getRect(find.text('Join with a code'));
      final friends = tester.getRect(find.byType(CircularProgressIndicator));
      expect(friends.top, greaterThan(join.bottom));
    });
  });

  group('Together sections', () {
    tearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );

    Future<void> pumpSections(
      WidgetTester tester,
      Size size, {
      VoidCallback? onCopy,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                WelcomeCard(
                  friendCode: '23RZ-7KGT',
                  onAdd: () {},
                  onCopyCode: onCopy ?? () {},
                ),
                const SizedBox(height: 24),
                MovieNightCard(onJoin: () {}, onPickTitle: () {}),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('the friend code copies with a tap and says so in place', (
      tester,
    ) async {
      var copies = 0;
      await pumpSections(tester, const Size(412, 915), onCopy: () => copies++);
      expect(find.text('23RZ-7KGT'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('23RZ-7KGT'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(copies, 1);
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      // The cross-fade back to Copy.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Copied'), findsNothing);
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('Movie night: Join and Host side by side on a phone', (
      tester,
    ) async {
      await pumpSections(tester, const Size(412, 915));
      final join = tester.getRect(find.text('Join with a code'));
      final host = tester.getRect(find.text('Pick a title to host'));
      expect(host.left, greaterThan(join.right));
      expect((host.top - join.top).abs(), lessThan(1));
    });

    testWidgets('Movie night: two equal tiles fill the row', (tester) async {
      // Wide enough that the labels (in the wide test font) leave room, so
      // a tile shrunk to its text would show.
      await pumpSections(tester, const Size(900, 1400));
      Rect tile(String label) => tester.getRect(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      final joinTile = tile('Join with a code');
      final hostTile = tile('Pick a title to host');
      expect((joinTile.width - hostTile.width).abs(), lessThan(1));
      // The page's 16 px margins and the 12 px gap between the tiles.
      expect(joinTile.width + hostTile.width, closeTo(900 - 32 - 12, 1));
    });

    testWidgets('on TV they stack, so Down goes from Join to Host', (
      tester,
    ) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      await pumpSections(tester, const Size(1280, 1400));
      final join = tester.getRect(find.text('Join with a code'));
      final host = tester.getRect(find.text('Pick a title to host'));
      expect(host.top, greaterThan(join.bottom));
    });

    for (final size in const [Size(320, 568), Size(430, 932)]) {
      testWidgets('fits a ${size.width.toInt()} px phone without '
          'overflowing', (tester) async {
        await pumpSections(tester, size);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
