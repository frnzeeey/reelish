import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('without the hosting perk it says who hosts; joining is open', (
    tester,
  ) async {
    await pump(tester);
    expect(
      find.text(
        'Hosting is for Reelish Supporters. Anyone can join with a code.',
      ),
      findsOneWidget,
    );
    // Without Home's search (no hook), no button that does nothing.
    expect(find.text('Pick a title to host'), findsNothing);
  });

  test('the greeting follows the hour', () {
    expect(greetingFor(DateTime(2026, 1, 1, 8)), 'Good morning');
    expect(greetingFor(DateTime(2026, 1, 1, 14)), 'Good afternoon');
    expect(greetingFor(DateTime(2026, 1, 1, 21)), 'Good evening');
    expect(greetingFor(DateTime(2026, 1, 1, 2)), 'Good evening');
  });
}
