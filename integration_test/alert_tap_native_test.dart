// Posts a real new-episode alert through SystemEpisodeNotifier on an Android
// phone or tablet and waits for it to be tapped, then checks that the tap
// reached AlertRoutes with the alert's title:
//
//   flutter test integration_test/alert_tap_native_test.dart -d <android>
//
// While it waits (two minutes), tap the "New episode of Reelish Tap Test"
// notification, or let a script do it (adb: grant POST_NOTIFICATIONS,
// `cmd statusbar expand-notifications`, then tap the notification). This
// covers a tap while the app runs; a tap that launches the app goes through
// getNotificationAppLaunchDetails, which needs the real app signed in.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/notifications/episode_alerts.dart';
import 'package:onfeed/src/notifications/episode_check.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a tapped alert opens its series', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      markTestSkipped('Android only.');
      return;
    }
    AlertRoutes.debugReset();
    final tapped = Completer<AlertTarget>();
    // A second tap on the same alert opens it again; only the first counts.
    AlertRoutes.open = (target) {
      if (!tapped.isCompleted) tapped.complete(target);
    };
    final notifier = SystemEpisodeNotifier();
    await tester.runAsync(() async {
      await notifier.listenForTaps();
      // ignore: avoid_print
      print('ALERT_PERMISSION ${await notifier.requestPermission()}');
      await notifier.showNew(const [
        NewEpisode(
          tmdbId: 424242,
          seriesName: 'Reelish Tap Test',
          season: 1,
          episode: 2,
          episodeName: 'Tap me',
        ),
      ]);
      // ignore: avoid_print
      print('ALERT_POSTED');
      final target = await tapped.future.timeout(const Duration(minutes: 2));
      // ignore: avoid_print
      print('ALERT_TAPPED ${target.kind}:${target.id}:${target.name}');
      expect(target.kind, 'series');
      expect(target.id, 424242);
      expect(target.name, 'Reelish Tap Test');
    });
    AlertRoutes.debugReset();
  });
}
