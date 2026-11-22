// Drives the real app on a device or emulator:
//
//   flutter test integration_test -d <device-id>
//
// Covers launch, Plugins (the Windows sidebar; Settings on the phone) and
// the Plugin Library. Playback is not
// covered: it depends on third-party providers and live streams, which would
// make this test flaky.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/main.dart' as app;
import 'package:onfeed/src/desktop/desktop_shell.dart';
import 'package:onfeed/src/widgets/plugin_library/plugin_card.dart';
import 'package:onfeed/src/widgets/settings/settings_components.dart';
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

  testWidgets('launch, Plugins and Plugin Library', (tester) async {
    // Skip the first-run legal screen; it is covered by widget tests.
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('reelish.legal.documentsAccepted.v1', true);

    // main() adds its crash reporting to the test's error handler.
    final errors = FlutterError.onError;
    app.main();
    FlutterError.onError = errors;
    // Phones and TVs navigate with the dock; Windows with its sidebar,
    // which labels each page in text or, when compact, in a tooltip.
    final desktop = Platform.isWindows;
    final navigation = find.byType(desktop ? DesktopShell : SoftGlassDock);
    await pumpUntil(tester, navigation);

    if (desktop) {
      final pluginsLabel = find.descendant(
        of: navigation,
        matching: find.text('Plugins'),
      );
      await tester.tap(
        pluginsLabel.evaluate().isEmpty
            ? find.byTooltip('Plugins').first
            : pluginsLabel.first,
      );
    } else {
      // The phone keeps Plugins in Settings, under Playback.
      await tester.tap(
        find.descendant(of: navigation, matching: find.text('Settings')),
      );
      await tester.pumpAndSettle();
      final plugins = find.widgetWithText(SettingsTile, 'Plugins');
      await tester.scrollUntilVisible(
        plugins,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(plugins);
    }
    await pumpUntil(tester, find.text('Browse Reelish Plugins'));
    // An icon button on phones and TVs; a labelled button on the Windows
    // Plugins page.
    // The empty page repeats the Windows button, so at least one there.
    expect(
      desktop ? find.text('Add by link') : find.byTooltip('Add by link'),
      desktop ? findsWidgets : findsOneWidget,
    );
    expect(find.text('Add provider'), findsNothing);

    await tester.tap(find.text('Browse Reelish Plugins').first);
    // The catalog loads from the network, the cache or the bundled copy.
    await pumpUntil(tester, find.byType(PluginCard));
    expect(find.text('Unable to load plugins'), findsNothing);

    // Windows shows the library in place, behind the Installed / Discover
    // switch; phones and TVs open it as a page with a back button.
    await tester.tap(
      desktop
          ? find.byTooltip('Your collections and providers')
          : find.byTooltip('Back to plugins'),
    );
    await pumpUntil(tester, find.text('Browse Reelish Plugins'));
  });
}
