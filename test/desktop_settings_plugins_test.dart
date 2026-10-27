import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:onfeed/src/desktop/desktop_plugins_page.dart';
import 'package:onfeed/src/desktop/desktop_settings_page.dart';
import 'package:onfeed/src/models/provider_plugin.dart';
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:onfeed/src/screens/plugin_library_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/plugin_library_repository.dart';
import 'package:onfeed/src/services/provider_plugin_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Windows Settings and Plugins pages: the same settings and plugin
/// actions as phone and TV, laid out for a desktop window.

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(1600, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: GlassTheme.dark,
      home: Scaffold(body: page),
    ),
  );
  await tester.pumpAndSettle();
}

/// Plugin changes recorded instead of saved.
class _Plugins extends ProviderPluginService {
  _Plugins() {
    repositories.addAll(const [
      ProviderRepository(
        url: 'https://example.com/a.json',
        name: 'Repo A',
        plugins: [
          ProviderPlugin(
            id: 'one',
            name: 'Provider One',
            filename: 'one.js',
            description: 'Fast movies.',
          ),
          ProviderPlugin(
            id: 'two',
            name: 'Provider Two',
            filename: 'two.js',
            enabled: false,
          ),
        ],
      ),
    ]);
  }

  final calls = <String>[];

  @override
  Future<void> load() async => calls.add('load');

  @override
  Future<void> setPluginEnabled(
    ProviderRepository repository,
    ProviderPlugin plugin,
    bool enabled,
  ) async => calls.add('${plugin.id}=$enabled');

  @override
  Future<void> remove(ProviderRepository repo) async =>
      calls.add('remove ${repo.name}');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Reelish',
      packageName: 'app.reelish',
      version: '1.7.0',
      buildNumber: '1007000',
      buildSignature: '',
    );
  });

  group('Windows Settings', () {
    late AccentSettingsController accent;
    late PlaybackSettingsController playback;

    setUp(() {
      accent = AccentSettingsController();
      playback = PlaybackSettingsController();
    });
    tearDown(() {
      GlassTheme.setAccent(GlassTheme.coral);
      accent.dispose();
      playback.dispose();
    });

    Widget page() => DesktopSettingsPage(
      accentSettings: accent,
      playbackSettings: playback,
      plugins: const [],
    );

    testWidgets('lists every category and shows Appearance beside them', (
      tester,
    ) async {
      await _pump(tester, page());
      for (final section in DesktopSettingsSection.values) {
        expect(find.text(section.title), findsWidgets, reason: section.title);
      }
      expect(find.text('Open-source licenses'), findsOneWidget);
      expect(find.byType(AppearanceSettingsScreen), findsOneWidget);
      // The pane is the way back, so the page has no Back of its own.
      expect(find.byTooltip('Back'), findsNothing);
    });

    testWidgets('a category opens in the pane; a choice saves at once', (
      tester,
    ) async {
      await _pump(tester, page());
      await tester.tap(find.bySemanticsLabel(RegExp('^Violet accent')));
      await tester.pumpAndSettle();
      expect(accent.value.id, 'violet');
      // The rail shows the new value.
      expect(find.text('Violet'), findsWidgets);

      await tester.tap(find.text('Playback').first);
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackSettingsScreen), findsOneWidget);
      expect(find.byType(AppearanceSettingsScreen), findsNothing);
      expect(find.byTooltip('Back'), findsNothing);
    });

    testWidgets('the keyboard moves through the categories', (tester) async {
      await _pump(tester, page());
      Focus.of(tester.element(find.text('Terms of use'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.textContaining('Content disclaimer'), findsWidgets);
    });

    testWidgets('a title cut to fit stays clear of its external-link icon', (
      tester,
    ) async {
      // The page's width in a 1024 px window, beside the compact rail.
      await _pump(tester, page(), size: const Size(944, 700));
      final title = tester.getRect(find.text('Open-source licenses'));
      final icon = tester.getRect(find.byIcon(Symbols.open_in_new_rounded));
      expect(icon.left - title.right, greaterThanOrEqualTo(8));
    });

    for (final size in const [Size(1044, 720), Size(2324, 1440)]) {
      testWidgets('every category lays out at ${size.width.toInt()} wide', (
        tester,
      ) async {
        await _pump(tester, page(), size: size);
        for (final section in DesktopSettingsSection.values) {
          await tester.ensureVisible(find.text(section.title).first);
          await tester.tap(find.text(section.title).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: section.title);
        }
      });
    }
  });

  group('Windows Plugins', () {
    late _Plugins plugins;
    setUp(() => plugins = _Plugins());

    Widget page() => DesktopPluginsPage(
      pluginService: plugins,
      pluginLibrary: PluginLibraryRepository(),
    );

    testWidgets('shows the counts and a lone repository with its providers', (
      tester,
    ) async {
      await _pump(tester, page());
      expect(find.text('providers active'), findsNothing);
      expect(find.text('provider active'), findsOneWidget);
      expect(find.text('1 of 2 providers active'), findsOneWidget);
      expect(find.text('Provider One'), findsOneWidget);
      expect(find.text('Provider Two'), findsOneWidget);
    });

    testWidgets('a provider switches, Refresh reloads, Remove confirms', (
      tester,
    ) async {
      await _pump(tester, page());
      await tester.tap(find.text('Provider Two'));
      await tester.tap(find.byType(Switch).first);
      await tester.tap(find.byTooltip('Refresh repositories'));
      await tester.pump();
      expect(plugins.calls, ['two=true', 'one=false', 'load']);

      await tester.tap(find.byTooltip('Remove repository'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(plugins.calls.last, 'remove Repo A');
    });

    testWidgets('changed provider code waits for Allow update', (tester) async {
      plugins.pendingScriptUpdates['https://example.com/a.json'] = {
        'one': 'hash',
      };
      await _pump(tester, page());
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('Allow update'), findsOneWidget);
    });

    testWidgets('Browse opens the Community Library in the page, beside the '
        'sidebar, and Installed comes back', (tester) async {
      await _pump(tester, page());
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await tester.tap(find.text('Browse Reelish Plugins'));
      // The catalog may still be loading (an endless progress bar).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Shown in place: nothing was pushed over the shell.
      expect(find.byType(PluginLibraryView), findsOneWidget);
      expect(find.byType(PluginLibraryScreen), findsNothing);
      expect(navigator.canPop(), isFalse);
      expect(find.text('Community Library'), findsOneWidget);
      expect(find.text('Your repositories'), findsNothing);

      await tester.tap(find.byTooltip('Your repositories and providers'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PluginLibraryView), findsNothing);
      expect(find.text('Your repositories'), findsOneWidget);
    });

    testWidgets('with nothing installed, offers the library and a URL', (
      tester,
    ) async {
      plugins.repositories.clear();
      await _pump(tester, page(), size: const Size(1044, 720));
      expect(find.text('Start with a provider'), findsOneWidget);
      expect(find.text('Browse the library'), findsOneWidget);
      expect(find.text('Paste a manifest'), findsOneWidget);
    });
  });
}
