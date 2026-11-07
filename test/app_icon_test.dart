import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/platform/app_icon.dart';
import 'package:onfeed/src/screens/app_icon_settings_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// The account the icon screen checks: the fake server answers [status]
/// ('none', 'pending', 'verified') one after another, or fails when null.
/// [signedIn] false is a device with nobody signed in.
class _Account {
  _Account(this.status, {this.signedIn = true});

  final List<String?> status;
  final bool signedIn;
  int requests = 0;
  late AccountController account;
  late SupporterController supporters;

  Future<SupporterController> start() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient((_) async {
        requests++;
        final answer = status.length > 1 ? status.removeAt(0) : status.first;
        if (answer == null) return http.Response('', 503);
        return http.Response(
          jsonEncode({
            'code': 'RS-ABCD-2345',
            'status': answer,
            'since': answer == 'verified' ? 1719825600 : null,
            'recognition': {'listed': false, 'name': ''},
          }),
          200,
        );
      }),
    );
    account = AccountController(
      api: api,
      store: MemorySessionStore(
        signedIn
            ? StoredSession(
                sessionId: 'session',
                accessToken: 'access',
                accessExpiresAt: now + 3600,
                refreshToken: 'refresh',
                refreshExpiresAt: now + 86400,
                userId: 'user-1',
                username: 'viewer',
              )
            : null,
      ),
    );
    await account.restore();
    return supporters = SupporterController(account: account, api: api);
  }
}

Future<AppIconController> _controller(List<String?> status) async {
  final supporters = await _Account(status).start();
  final controller = AppIconController(supporters: supporters);
  await controller.load();
  // The status check load() started; waiting asks the server no more.
  await supporters.refresh();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeLauncher launcher;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    launcher = _FakeLauncher();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, launcher.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('The collection', () {
    test('every preset has a bundled preview and a unique id', () async {
      final ids = AppIconPreset.all.map((p) => p.id).toSet();
      expect(ids, hasLength(AppIconPreset.all.length));
      expect(AppIconPreset.all.first.id, AppIconPreset.defaultId);
      for (final preset in AppIconPreset.all) {
        final data = await rootBundle.load(preset.preview);
        expect(data.lengthInBytes, greaterThan(0), reason: preset.id);
      }
    });

    test('exactly two icons are free: Default and Slate', () {
      expect(AppIconPreset.all.where((p) => p.free).map((p) => p.id), [
        'default',
        'slate',
      ]);
      expect(
        AppIconPreset.all.where((p) => p.group == AppIconGroup.signature),
        hasLength(5),
      );
    });

    test('the app, the switcher and the manifest list the same icons', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/example/onfeed/AppIconSwitcher.kt',
      ).readAsStringSync();
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final aliases = {
        for (final match in RegExp(
          r'"([a-z_]+)" to "\.(\w+)"',
        ).allMatches(kotlin))
          match[1]!: match[2]!,
      };
      final dart = AppIconPreset.all.map((p) => p.id).toSet()
        ..remove('default');
      expect(aliases.keys.toSet(), dart);
      for (final MapEntry(key: id, value: alias) in aliases.entries) {
        expect(manifest, contains('android:name=".$alias"'), reason: id);
        expect(manifest, contains('@mipmap/ic_launcher_$id"'), reason: id);
        expect(
          File(
            'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_$id.xml',
          ).existsSync(),
          isTrue,
          reason: id,
        );
      }
    });
  });

  group('AppIconController', () {
    test('shows what the launcher shows', () async {
      launcher.enabled = 'teal';
      final controller = await _controller(['none']);
      expect(controller.current, 'teal');
    });

    test('an unknown launcher state reads as the default', () async {
      launcher.enabled = 'something-removed';
      final controller = await _controller(['none']);
      expect(controller.current, AppIconPreset.defaultId);
    });

    test('anyone can switch between the free icons', () async {
      final controller = await _controller(['none']);
      expect(await controller.select('slate'), AppIconChange.applied);
      expect(launcher.enabled, 'slate');
      expect(await controller.select('default'), AppIconChange.applied);
      expect(launcher.enabled, 'default');
    });

    test(
      'someone who is not a supporter cannot apply a supporter icon',
      () async {
        final controller = await _controller(['none']);
        expect(controller.unlocked(AppIconPreset.byId('aurora')), isFalse);
        expect(await controller.select('aurora'), AppIconChange.supportersOnly);
        expect(launcher.enabled, 'default');
        expect(launcher.calls, isNot(contains('select')));
      },
    );

    test('a donation waiting for review does not count', () async {
      final controller = await _controller(['pending']);
      expect(await controller.select('violet'), AppIconChange.supportersOnly);
      expect(launcher.enabled, 'default');
    });

    test('a supporter can apply every icon, and switch back', () async {
      final controller = await _controller(['verified']);
      expect(await controller.select('aurora'), AppIconChange.applied);
      expect(launcher.enabled, 'aurora');
      expect(await controller.select('violet'), AppIconChange.applied);
      expect(await controller.select('default'), AppIconChange.applied);
      expect(launcher.enabled, 'default');
    });

    test('a supporter icon asks the server, not the saved status', () async {
      // Saved as a supporter on this device (or edited to say so)...
      SharedPreferences.setMockInitialValues({
        'reelish.supporter.v1.user-1': jsonEncode({
          'code': 'RS-ABCD-2345',
          'status': 'verified',
          'since': 1719825600,
          'recognition': {'listed': false, 'name': ''},
        }),
      });
      // ...but the server cannot be reached.
      final account = _Account([null]);
      final controller = AppIconController(supporters: await account.start());
      await controller.load();
      expect(await controller.select('celestial'), AppIconChange.unverified);
      expect(launcher.enabled, 'default');
    });

    test('support that has ended is caught when applying', () async {
      final controller = await _controller(['verified', 'none']);
      expect(controller.supporter, isTrue);
      expect(
        await controller.select('rose_luxe'),
        AppIconChange.supportersOnly,
      );
      expect(launcher.enabled, 'default');
    });

    test('with nobody signed in, no supporter icon applies', () async {
      final supporters = await _Account(['verified'], signedIn: false).start();
      final controller = AppIconController(supporters: supporters);
      await controller.load();
      expect(await controller.select('aurora'), isNot(AppIconChange.applied));
      expect(launcher.enabled, 'default');
    });

    test(
      'after signing out, the next account gets only its own access',
      () async {
        final account = _Account(['verified']);
        final controller = AppIconController(supporters: await account.start());
        await controller.load();
        expect(await controller.select('aurora'), AppIconChange.applied);
        await account.account.signOut();
        await account.supporters.refresh();
        expect(controller.supporter, isFalse);
        expect(
          await controller.select('celestial'),
          isNot(AppIconChange.applied),
        );
        // The icon on the launcher is left alone.
        expect(launcher.enabled, 'aurora');
      },
    );

    test(
      'an icon chosen while supporting is never changed behind the user',
      () async {
        launcher.enabled = 'golden_hour';
        final controller = await _controller(['none']);
        expect(controller.current, 'golden_hour');
        expect(launcher.calls, isNot(contains('select')));
      },
    );

    test('a change the system refuses is not reported as done', () async {
      launcher.refuse = true;
      final controller = await _controller(['verified']);
      expect(await controller.select('blue'), AppIconChange.failed);
      expect(controller.current, 'default');
    });

    test('a failed change keeps the current icon', () async {
      final controller = await _controller(['verified']);
      launcher.fail = true;
      expect(await controller.select('slate'), AppIconChange.failed);
      expect(controller.current, 'default');
      expect(controller.applying, isNull);
    });
  });

  group('The screen', () {
    Future<SupporterController> show(
      WidgetTester tester,
      List<String?> status,
    ) async {
      tester.view.physicalSize = const Size(412, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late SupporterController supporters;
      await tester.runAsync(() async {
        supporters = await _Account(status).start();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: AppIconSettingsScreen(onBack: () {}, supporters: supporters),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      return supporters;
    }

    testWidgets('someone who is not a supporter sees every icon, two free', (
      tester,
    ) async {
      await show(tester, ['none']);
      for (final preset in AppIconPreset.all) {
        expect(find.text(preset.label), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            preset.free
                ? '${preset.label} icon'
                : '${preset.label} icon, for Reelish Supporters',
          ),
          findsOneWidget,
          reason: preset.id,
        );
      }
      expect(find.text('FREE'), findsOneWidget);
      expect(find.text('SUPPORTER COLLECTION'), findsOneWidget);

      await tester.tap(find.text('Slate'));
      await tester.pumpAndSettle();
      expect(launcher.enabled, 'slate');
      expect(find.textContaining('App icon changed to Slate'), findsOneWidget);
    });

    testWidgets('a locked icon explains itself and changes nothing', (
      tester,
    ) async {
      await show(tester, ['none']);
      await tester.tap(find.text('Celestial'));
      await tester.pumpAndSettle();
      expect(find.text('Become a Supporter'), findsOneWidget);
      expect(find.textContaining('stay free for everyone'), findsOneWidget);
      expect(launcher.enabled, 'default');
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Become a Supporter'), findsNothing);
      expect(launcher.calls, isNot(contains('select')));
    });

    testWidgets('a supporter picks from the whole collection', (tester) async {
      await show(tester, ['verified']);
      expect(
        find.bySemanticsLabel(RegExp('for Reelish Supporters')),
        findsNothing,
      );
      expect(find.textContaining('Every icon is yours'), findsOneWidget);
      await tester.tap(find.text('Aurora'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(launcher.enabled, 'aurora');
      expect(find.textContaining('App icon changed to Aurora'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a supporter icon kept from before is shown, not locked', (
      tester,
    ) async {
      launcher.enabled = 'violet';
      await show(tester, ['none']);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Violet icon')),
        matchesSemantics(
          label: 'Violet icon',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
        ),
      );
      expect(
        find.textContaining('stays until you choose another'),
        findsOneWidget,
      );
    });

    testWidgets('a refused change shows an error, not a success', (
      tester,
    ) async {
      launcher.refuse = true;
      await show(tester, ['none']);
      await tester.tap(find.text('Slate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be changed'), findsOneWidget);
      expect(find.textContaining('App icon changed'), findsNothing);
    });
  });
}
