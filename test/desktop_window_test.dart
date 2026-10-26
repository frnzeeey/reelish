import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/platform/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('reelish/window');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Windows asks the runner to keep the display on, and to stop', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await DesktopWindow.keepDisplayOn(true);
    await DesktopWindow.keepDisplayOn(false);
    expect(calls.map((call) => (call.method, call.arguments)), [
      ('keepDisplayOn', true),
      ('keepDisplayOn', false),
    ]);
  });

  test('other platforms send nothing', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await DesktopWindow.keepDisplayOn(true);
    expect(calls, isEmpty);
  });

  test('a runner without the method is not an error', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException();
        });
    await expectLater(DesktopWindow.keepDisplayOn(true), completes);
  });
}
