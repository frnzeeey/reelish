// Reelish Connect against a deployed Reelish API, in the real app, signed in:
//
//   flutter test integration_test/reelish_connect_test.dart -d windows \
//     --dart-define=REELISH_API_URL=https://<staging host>
//
// Opens Together > Reelish Connect, waits for this account's invite code from
// the API, opens its QR dialog, then hands the app a shared title link and
// waits for that title's page. Needs a signed-in account on the device; it
// is skipped otherwise. It creates this account's invite code if it has none.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/main.dart' as app;
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/connect/reelish_qr.dart';
import 'package:onfeed/src/desktop/desktop_shell.dart';
import 'package:onfeed/src/watch_party/party_links.dart';
import 'package:onfeed/src/widgets/soft_glass_dock.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('Connect: invite code from the API, its QR, and a shared title '
      'link opens the title', (tester) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('reelish.legal.documentsAccepted.v1', true);
    final errors = FlutterError.onError;
    app.main();
    FlutterError.onError = errors;
    final desktop = Platform.isWindows;
    final navigation = find.byType(desktop ? DesktopShell : SoftGlassDock);
    try {
      await pumpUntil(tester, navigation, timeout: const Duration(seconds: 90));
    } on TestFailure {
      markTestSkipped('No one is signed in on this device.');
      return;
    }
    expect(AccountController.instance.userId, isNotNull);

    // Together > Reelish Connect.
    await tester.tap(
      desktop ? find.byTooltip('Together').first : find.text('Together').first,
    );
    await pumpUntil(tester, find.text('Reelish Connect'));
    await tester.ensureVisible(find.text('Reelish Connect').first);
    await tester.tap(find.text('Reelish Connect').first);
    await pumpUntil(tester, find.text('INVITE FRIENDS'));

    // The code comes from the API: ABCD-2345.
    final code = find.textContaining(
      RegExp(r'^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$'),
    );
    try {
      await pumpUntil(tester, code);
    } on TestFailure {
      // What the page says instead, for the failure report.
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .join(' | ');
      fail('No invite code shown. The page says: $texts');
    }
    expect(find.text('Joined with your invitation'), findsOneWidget);
    final shown = tester.widget<Text>(code.first).data!;

    await tester.tap(find.text('Your invitation'));
    await pumpUntil(tester, find.byType(ReelishQrCode));
    final qr = tester.widget<ReelishQrCode>(find.byType(ReelishQrCode));
    expect(qr.link, endsWith('/invite/${shown.replaceAll('-', '')}'));
    await tester.tap(find.text('Close'));
    await tester.pump(const Duration(milliseconds: 500));

    // A shared title link, as the runner hands one over.
    PartyLinks.receive('reelish://movie/550');
    await pumpUntil(tester, find.text('Fight Club'));
  });
}
