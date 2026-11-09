// Sets and resets the Founder's system splash on an Android device through
// the real `onfeed/splash` channel (ReelishActivity):
//
//   flutter test integration_test/splash_art_native_test.dart -d <android>
//
// On Android 13 and later (the default; pass --dart-define=SPLASH_THEME=false
// for an older device) both calls must report success, which means
// SovereignSplashTheme resolved and the system accepted it; earlier versions
// must report false (their system splash cannot change). The test leaves the
// default splash in place. To look at the crest itself, run only
// "applies the crest", launch Reelish from the launcher, then run "resets".
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _channel = MethodChannel('onfeed/splash');

/// Whether this device can change its system splash: Android 13 and later.
/// Pass --dart-define=SPLASH_THEME=false for an older device.
const _supported = bool.fromEnvironment('SPLASH_THEME', defaultValue: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<bool?> set(bool crest) =>
      _channel.invokeMethod<bool>('set', {'crest': crest});

  testWidgets('applies the crest', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      markTestSkipped('Android only.');
      return;
    }
    final applied = await set(true);
    // ignore: avoid_print
    print('SPLASH_SET crest=true applied=$applied');
    expect(applied, _supported);
  });

  testWidgets('resets to the Reelish logo', (tester) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      markTestSkipped('Android only.');
      return;
    }
    final applied = await set(false);
    // ignore: avoid_print
    print('SPLASH_SET crest=false applied=$applied');
    expect(applied, _supported);
  });
}
