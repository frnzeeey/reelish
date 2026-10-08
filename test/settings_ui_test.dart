import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/screens/app_information_screens.dart';
import 'package:onfeed/src/screens/credits_screen.dart';
import 'package:onfeed/src/screens/legal_information_screen.dart';
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:onfeed/src/screens/subtitle_addons_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/widgets/settings/settings_components.dart';
import 'package:onfeed/src/widgets/settings/tmdb_attribution.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _disclaimer =
    'This product uses the TMDB API but is not endorsed or certified by TMDB.';

Finder get _logo => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is AssetImage &&
      (widget.image as AssetImage).assetName == TmdbAttribution.logoAsset,
);

Future<void> _pump(WidgetTester tester, Widget child, {Size? size}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

/// Scrolls the page's only scroll view until [finder] is built.
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
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

  test('TMDB disclaimer uses the exact required wording', () {
    expect(TmdbAttribution.disclaimer, _disclaimer);
    expect(TmdbAttribution.website.host, 'www.themoviedb.org');
  });

  testWidgets('footer shows the official logo and disclaimer', (tester) async {
    await _pump(tester, const Scaffold(body: TmdbAttributionFooter()));
    expect(find.text(_disclaimer), findsOneWidget);
    expect(_logo, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('footer rests at the bottom of a short page', (tester) async {
    await _pump(
      tester,
      Scaffold(
        body: SettingsPage(
          title: 'Short',
          onBack: () {},
          children: const [
            SettingsSection(children: [SettingsTile(title: 'Only row')]),
          ],
        ),
      ),
      size: const Size(400, 800),
    );
    final footerBottom = tester.getBottomLeft(find.text(_disclaimer)).dy;
    expect(footerBottom, greaterThan(740));
  });

  testWidgets('switch tile toggles from a tap anywhere on the row', (
    tester,
  ) async {
    var value = false;
    await _pump(
      tester,
      Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SettingsSwitchTile(
            title: 'Example',
            description: 'Row tap target',
            value: value,
            onChanged: (next) => setState(() => value = next),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Row tap target'));
    await tester.pump();
    expect(value, isTrue);
  });

  testWidgets('disabled tile ignores taps', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      Scaffold(
        body: SettingsTile(title: 'Off', enabled: false, onTap: () => taps++),
      ),
    );
    await tester.tap(find.text('Off'));
    expect(taps, 0);
  });

  testWidgets('main settings on a compact phone lists entries and ends with '
      'the TMDB footer', (tester) async {
    final accent = AccentSettingsController();
    addTearDown(accent.dispose);
    await _pump(
      tester,
      Scaffold(
        body: SettingsScreen(
          accentSettings: accent,
          onPlaybackSettings: () {},
          onAppearanceSettings: () {},
        ),
      ),
      size: const Size(320, 568),
    );
    for (final label in [
      'Appearance',
      'Playback',
      'Subtitle addons',
      'About Reelish',
      'Credits & attribution',
      'Open-source licenses',
      'Privacy policy',
      'Terms of use',
      'Support development',
    ]) {
      await _scrollTo(tester, find.text(label));
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await _scrollTo(tester, find.text(_disclaimer));
    expect(find.text(_disclaimer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('credits shows the TMDB attribution once with a site link', (
    tester,
  ) async {
    await _pump(tester, const CreditsScreen(), size: const Size(360, 740));
    // The content disclaimer comes first; TMDB follows it.
    await _scrollTo(tester, find.text('The Movie Database (TMDB)'));
    expect(find.text('DATA & METADATA'), findsOneWidget);
    expect(_logo, findsOneWidget);
    expect(find.text('The Movie Database (TMDB)'), findsOneWidget);
    expect(find.text(_disclaimer), findsOneWidget);
    await _scrollTo(tester, find.text('REELISH INFORMATION'));
    await _scrollTo(tester, find.text('1.7.0 (build 1007000)'));
    await _scrollTo(tester, find.text('Reporting and support'));
    // At the end, the footer repeats only the notice, without a second logo.
    await _scrollTo(tester, find.text(_disclaimer));
    expect(find.text(_disclaimer), findsOneWidget);
    expect(_logo, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every settings sub-screen ends with exactly one footer', (
    tester,
  ) async {
    final playback = PlaybackSettingsController();
    await playback.load();
    addTearDown(playback.dispose);
    final accent = AccentSettingsController();
    addTearDown(accent.dispose);
    final screens = <String, Widget>{
      'About': const AboutScreen(),
      'Support': const SupportDevelopmentScreen(),
      'Privacy': const LegalInformationScreen(document: LegalDocument.privacy),
      'Terms': const LegalInformationScreen(document: LegalDocument.terms),
      'Subtitles': const SubtitleAddonsScreen(),
      'Appearance': Scaffold(
        body: AppearanceSettingsScreen(controller: accent, onBack: () {}),
      ),
      'Playback': Scaffold(
        body: PlaybackSettingsScreen(
          controller: playback,
          plugins: const [],
          onBack: () {},
        ),
      ),
    };
    for (final entry in screens.entries) {
      await _pump(tester, entry.value, size: const Size(360, 740));
      await _scrollTo(tester, find.text(_disclaimer));
      expect(find.text(_disclaimer), findsOneWidget, reason: entry.key);
      expect(tester.takeException(), isNull, reason: entry.key);
    }
  });

  testWidgets('hold speed marks the saved value and follows hold to speed', (
    tester,
  ) async {
    final controller = PlaybackSettingsController();
    await controller.load();
    addTearDown(controller.dispose);
    await _pump(
      tester,
      Scaffold(
        body: PlaybackSettingsScreen(
          controller: controller,
          plugins: const [],
          onBack: () {},
        ),
      ),
    );
    await tester.ensureVisible(find.text('Hold speed'));
    await tester.pumpAndSettle();
    expect(find.text('2×'), findsOneWidget);

    await tester.tap(find.text('Hold speed'));
    await tester.pumpAndSettle();
    final selected = tester.widget<ListTile>(
      find.ancestor(of: find.text('2×').last, matching: find.byType(ListTile)),
    );
    expect(selected.selected, isTrue);
    await tester.tap(find.text('2.5×'));
    await tester.pumpAndSettle();
    expect(controller.value.holdSpeed, 2.5);

    await controller.update(controller.value.copyWith(holdToSpeed: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hold speed'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  // Last: the credits test above must be the first to read package info.
  contentDisclaimerTests();
}

void contentDisclaimerTests() {
  testWidgets(
    'content disclaimer follows TMDB on Credits and opens the Terms',
    (tester) async {
      const opening =
          'Reelish is a media discovery and playback application. Reelish does '
          'not host, store, upload, or distribute films, television programs, '
          'or any other copyrighted content';
      expect(LegalInformationScreen.contentDisclaimer.$2, startsWith(opening));

      await _pump(tester, const CreditsScreen(), size: const Size(360, 740));
      // TMDB leads the page; the disclaimer is below it.
      final tmdbTop = tester.getTopLeft(find.text('DATA & METADATA')).dy;
      await _scrollTo(tester, find.text('CONTENT DISCLAIMER'));
      expect(find.textContaining(opening), findsOneWidget);
      final scrolled = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      expect(
        tester.getTopLeft(find.text('CONTENT DISCLAIMER')).dy + scrolled,
        greaterThan(tmdbTop),
      );

      await _pump(
        tester,
        const LegalInformationScreen(document: LegalDocument.terms),
        size: const Size(360, 740),
      );
      expect(find.text('Content disclaimer'), findsOneWidget);
      expect(find.textContaining(opening), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
