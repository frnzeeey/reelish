import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/theme/avatar_frames.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/avatar_frame.dart';
import 'package:onfeed/src/widgets/home_profile_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_account.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The ring's colours.
  List<Color> ringColors(WidgetTester tester) {
    final ring = tester.widget<Container>(
      find.byKey(const ValueKey('home-profile-ring')),
    );
    final gradient = (ring.decoration! as BoxDecoration).gradient!;
    return (gradient as LinearGradient).colors;
  }

  Future<void> pump(WidgetTester tester, String? frame) async {
    final fake = (await tester.runAsync(
      () => fakeAccount(entitlement: 'supporter', frame: frame),
    ))!;
    expect(fake.frames.equipped, frame);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HomeProfileButton(onOpen: () {}, frames: fake.frames),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('without a frame: one ring in the accent', (tester) async {
    await pump(tester, null);
    expect(ringColors(tester), [GlassTheme.coralBright, GlassTheme.primary]);
    expect(find.byType(AvatarFrameRim), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('home-profile-ring'))),
      const Size.square(44),
    );
  });

  testWidgets(
    "with a supporter's frame: one ring in the frame's colour, no second rim",
    (tester) async {
      await pump(tester, 'aurora');
      final aurora = AvatarFrameStyle.byId('aurora')!;
      expect(ringColors(tester), [aurora.rim, aurora.rim]);
      // The frame colours the one ring; nothing draws a rim inside it.
      expect(find.byType(AvatarFrameRim), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('home-profile-ring')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).border != null,
          ),
        ),
        findsNothing,
      );
      expect(find.byTooltip('Profile'), findsOneWidget);
    },
  );
}
