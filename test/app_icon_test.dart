import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/platform/app_icon.dart';
import 'package:onfeed/src/screens/app_icon_settings_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';

const _channel = MethodChannel('onfeed/app_icon');

/// A fake Android side: [enabled] is the launcher's state.
class _FakeLauncher {
  String enabled = 'default';
  bool refuse = false;
  bool fail = false;
  final calls = <String>[];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    if (fail) throw PlatformException(code: 'icon_failed');
    switch (call.method) {
      case 'current':
        return enabled;
      case 'select':
        // A refusal leaves the old icon in place, as the system would.
        if (!refuse) enabled = (call.arguments as Map)['id'] as String;
        return enabled;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeLauncher launcher;

  setUp(() {
    launcher = _FakeLauncher();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, launcher.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('every preset has a bundled preview and a unique id', () async {
    final ids = AppIconPreset.all.map((p) => p.id).toSet();
    expect(ids, hasLength(AppIconPreset.all.length));
    expect(AppIconPreset.all.first.id, AppIconPreset.defaultId);
    for (final preset in AppIconPreset.all) {
      final data = await rootBundle.load(preset.preview);
      expect(data.lengthInBytes, greaterThan(0), reason: preset.id);
    }
  });

  group('AppIconController', () {
    test('shows what the launcher shows', () async {
      launcher.enabled = 'teal';
      final controller = AppIconController()..addListener(() {});
      await controller.load();
      expect(controller.current, 'teal');
    });

    test('an unknown launcher state reads as the default', () async {
      launcher.enabled = 'something-removed';
      final controller = AppIconController();
      await controller.load();
      expect(controller.current, AppIconPreset.defaultId);
    });

    test('a confirmed change succeeds and switching back works', () async {
      final controller = AppIconController();
      await controller.load();
      expect(await controller.select('violet'), true);
      expect(controller.current, 'violet');
      expect(await controller.select('default'), true);
      expect(launcher.enabled, 'default');
    });

    test('a change the system refuses is not reported as done', () async {
      launcher.refuse = true;
      final controller = AppIconController();
      await controller.load();
      expect(await controller.select('blue'), false);
      expect(controller.current, 'default');
    });

    test('a failed change keeps the current icon', () async {
      final controller = AppIconController();
      await controller.load();
      launcher.fail = true;
      expect(await controller.select('blue'), false);
      expect(controller.current, 'default');
      expect(controller.applying, isNull);
    });
  });

  testWidgets('the screen marks the active icon and confirms a change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    launcher.enabled = 'rose';
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.dark,
        home: Scaffold(body: AppIconSettingsScreen(onBack: () {})),
      ),
    );
    await tester.pumpAndSettle();

    for (final preset in AppIconPreset.all) {
      expect(find.text(preset.label), findsOneWidget);
    }
    expect(
      tester.getSemantics(find.bySemanticsLabel('Rose icon')),
      matchesSemantics(
        label: 'Rose icon',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );

    await tester.tap(find.text('Lime'));
    await tester.pumpAndSettle();
    expect(launcher.enabled, 'lime');
    expect(find.textContaining('App icon changed to Lime'), findsOneWidget);
    expect(find.textContaining('does not affect your account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refused change shows an error, not a success', (tester) async {
    tester.view.physicalSize = const Size(412, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    launcher.refuse = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.dark,
        home: Scaffold(body: AppIconSettingsScreen(onBack: () {})),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be changed'), findsOneWidget);
    expect(find.textContaining('App icon changed'), findsNothing);
  });
}
