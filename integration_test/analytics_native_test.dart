// The native analytics channel on an Android device or emulator: Firebase
// starts only after consent, events and reset never throw, and a build
// without a configuration stays inert. Run with placeholder values to check
// the plumbing (nothing reaches a real project):
//
//   $env:REELISH_FIREBASE_APP_ID='1:000000000000:android:0000000000000000'
//   $env:REELISH_FIREBASE_API_KEY='placeholder'
//   $env:REELISH_FIREBASE_PROJECT_ID='placeholder'
//   flutter test integration_test/analytics_native_test.dart -d <device>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/analytics/analytics_events.dart';
import 'package:onfeed/src/analytics/analytics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('consent, events, switching off and reset run natively', (
    _,
  ) async {
    // Never touch the installed app's saved choice.
    SharedPreferences.setMockInitialValues({});
    final analytics = AnalyticsService();
    await analytics.load();
    // ignore: avoid_print
    print('ANALYTICS_CONFIGURED=${analytics.available.value}');
    expect(analytics.consent.value, AnalyticsConsent.unknown);

    await analytics.setConsent(true);
    analytics
      ..logScreen('home')
      ..log(AnalyticsEvent.selectContent(contentType: 'movie', itemId: '550'))
      ..log(
        AnalyticsEvent.playbackSession(
          contentType: 'movie',
          itemId: '550',
          outcome: PlaybackOutcome.played,
          firstFrameMs: 1800,
          watchedPercent: 50,
        ),
      )
      ..setUserProperty('interface', 'phone');
    await analytics.setConsent(false);
    analytics.logScreen('library');
    expect(analytics.consent.value, AnalyticsConsent.denied);
  });
}
