// Drives the real app on a device or emulator:
//
//   flutter test integration_test -d <device-id>
//
// Covers launch, the Plugins tab and the Plugin Library. Playback is not
// covered: it depends on third-party providers and live streams, which would
// make this test flaky.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/main.dart' as app;
import 'package:onfeed/src/widgets/soft_glass_dock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pumps frames until [finder] matches or [timeout] passes. pumpAndSettle
/// never settles here: Home has looping spinners and a spotlight timer.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launch, Plugins tab and Plugin Library', (tester) async {
    // Skip the first-run legal screen; it is covered by widget tests.
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('reelish.legal.documentsAccepted.v1', true);

    app.main();
    final dock = find.byType(SoftGlassDock);
    await pumpUntil(tester, dock);

    await tester.tap(
      find.descendant(of: dock, matching: find.text('Plugins')),
    );
    await pumpUntil(tester, find.text('Browse Reelish Plugins'));
    expect(find.byTooltip('Paste a manifest URL'), findsOneWidget);
    expect(find.text('Add provider'), findsNothing);

    await tester.tap(find.text('Browse Reelish Plugins'));
    await pumpUntil(tester, find.text('Reelish Plugins'));
    // The catalog loads from the network, the cache or the bundled copy.
    await pumpUntil(tester, find.text('Providers'));
    expect(find.text('Unable to load plugins'), findsNothing);

    await tester.tap(find.byTooltip('Back to plugins'));
    await pumpUntil(tester, find.text('Browse Reelish Plugins'));
  });
}
