import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/discovery/discovery_controller.dart';
import 'package:onfeed/src/discovery/discovery_preferences.dart';
import 'package:onfeed/src/discovery/discovery_store.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/genre_onboarding_screen.dart';
import 'package:onfeed/src/screens/recommendation_settings_screen.dart';
import 'package:onfeed/src/screens/tv/tv_pages.dart';
import 'package:onfeed/src/services/paged_feed_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/discovery_prompt_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoHistory extends StorageService {
  _NoHistory(Directory dir) : super(filesDirectory: () async => dir);

  @override
  Future<List<MediaItem>> history() async => const [];

  @override
  Future<List<MediaItem>> favorites() async => const [];
}

/// The genre step and its Home card on phone, TV and Windows.
void main() {
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
    DiscoveryStore.debugResetWrites();
    dir = await Directory.systemTemp.createTemp('genre_onboarding_test');
  });

  tearDown(() async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
    for (var attempt = 0; await dir.exists(); attempt++) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<DiscoveryController> boundDiscovery(WidgetTester tester) async {
    final discovery = DiscoveryController(
      recommendationsFor: (_) async => const [],
      storage: _NoHistory(dir),
      store: DiscoveryStore(filesDirectory: () async => dir),
    );
    await tester.runAsync(() => discovery.bindUser('viewer'));
    return discovery;
  }

  Future<void> loadMontserrat(WidgetTester tester) => tester.runAsync(() async {
    final loader = FontLoader('Montserrat');
    for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Montserrat-$weight.ttf'));
    }
    await loader.load();
  });

  /// A button that opens the step, as Home does, and what it completed with.
  Widget opener(DiscoveryController discovery, List<bool> results) =>
      MaterialApp(
        theme: GlassTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => results.add(
                  await GenreOnboardingScreen.show(
                    context,
                    discovery: discovery,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('Phone: picking genres and Continue saves them', (tester) async {
    // A small phone, in the app's font: nothing may overflow.
    tester.view.physicalSize = const Size(360 * 3, 740 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await loadMontserrat(tester);
    final discovery = await boundDiscovery(tester);
    final results = <bool>[];
    await tester.pumpWidget(opener(discovery, results));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('What do you love watching?'), findsOneWidget);
    expect(find.text('Pick a few to get started'), findsOneWidget);
    final cont = find.widgetWithText(FilledButton, 'Continue');
    expect(tester.widget<FilledButton>(cont).onPressed, isNull);

    await tester.tap(find.text('Science fiction'));
    await tester.tap(find.text('Comedy'));
    await tester.pump();
    expect(find.text('2 selected · a few more helps'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Comedy')),
      matchesSemantics(
        label: 'Comedy',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    await tester.tap(find.text('Comedy'));
    await tester.tap(find.text('Mystery'));
    await tester.tap(find.text('Thriller'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(cont);
    await settle(tester);
    expect(results, [true]);
    expect(find.text('What do you love watching?'), findsNothing);
    expect(discovery.data.onboarding, OnboardingState.completed);
    expect(discovery.favoriteGenres, unorderedEquals([878, 9648, 53]));
    expect(discovery.onboardingNeed(), OnboardingNeed.none);
    await tester.pumpWidget(const SizedBox.shrink());
    discovery.dispose();
  });

  testWidgets('Skip answers the step without genres; Back leaves it open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final discovery = await boundDiscovery(tester);
    final results = <bool>[];
    await tester.pumpWidget(opener(discovery, results));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // System Back: the phone's back gesture, the remote's Back key.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(results, [false]);
    expect(discovery.data.onboarding, isNull);
    expect(discovery.onboardingNeed(), OnboardingNeed.prompt);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip for now'));
    await settle(tester);
    expect(results, [false, true]);
    expect(discovery.data.onboarding, OnboardingState.skipped);
    expect(discovery.favoriteGenres, isEmpty);
    expect(discovery.onboardingNeed(), OnboardingNeed.none);
    await tester.pumpWidget(const SizedBox.shrink());
    discovery.dispose();
  });

  testWidgets('TV: focus starts on a genre and the remote picks it', (
    tester,
  ) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadMontserrat(tester);
    final discovery = await boundDiscovery(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.tv,
        home: GenreOnboardingScreen(discovery: discovery),
      ),
    );
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus;
    expect(focused?.context, isNotNull, reason: 'a genre has focus at once');
    expect(
      find.ancestor(
        of: find.text('Action'),
        matching: find.byWidget(focused!.context!.widget),
      ),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.text('1 selected · a few more helps'), findsOneWidget);
    // Right moves to the next genre.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.text('2 selected · a few more helps'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    discovery.dispose();
  });

  TvCatalog catalog(DiscoveryController discovery, {required bool prompt}) {
    PagedFeedController feed(String label) => PagedFeedController(
      label: label,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) async =>
          const CatalogPage(items: [], page: 1, totalPages: 1),
    );
    return TvCatalog(
      tmdb: TmdbService(baseUrl: 'https://api.themoviedb.org/3'),
      movies: feed('movies'),
      series: feed('series'),
      releases: feed('releases'),
      top10: feed('top10'),
      spotlight: const [],
      continueWatching: const [],
      catalogSettled: false,
      resumeFraction: (_) => 0,
      favoriteKeys: const {},
      hasSources: true,
      discovery: discovery,
      showGenrePrompt: prompt,
    );
  }

  testWidgets(
    'Windows: the Home card opens the step or goes away for good',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final discovery = await boundDiscovery(tester);
      var opened = 0;
      Widget page(bool prompt) => MaterialApp(
        home: Scaffold(
          body: DesktopHomePage(
            catalog: catalog(discovery, prompt: prompt),
            onOpen: (_) {},
            onPlay: (_) {},
            onToggleFavorite: (_) async => false,
            onRetry: () {},
            onAddSource: () {},
            onChooseGenres: () => opened++,
            onDismissGenres: () => discovery.skipOnboarding(),
          ),
        ),
      );
      await tester.pumpWidget(page(true));
      await tester.pump();
      expect(find.text(DiscoveryPromptCard.title), findsOneWidget);
      await tester.tap(find.text('Choose genres'));
      expect(opened, 1);
      await tester.tap(find.byTooltip('Not now'));
      // Home's placeholders animate, so this page never settles.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(discovery.data.onboarding, OnboardingState.skipped);

      await tester.pumpWidget(page(false));
      await tester.pump();
      expect(find.byType(DiscoveryPromptCard), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      discovery.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('TV: the Home card is one row the remote can open', (
    tester,
  ) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    tester.view.physicalSize = const Size(1920, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final discovery = await boundDiscovery(tester);
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvHomePage(
            catalog: catalog(discovery, prompt: true),
            onOpen: (_) {},
            onRetry: () {},
            onAddSource: () {},
            onChooseGenres: () => opened++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Tell us what you love watching'), findsOneWidget);
    await tester.tap(find.text('Tell us what you love watching'));
    await tester.pump();
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    discovery.dispose();
  });

  testWidgets('Settings: personalised rows can be turned off and on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final discovery = await boundDiscovery(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecommendationSettingsScreen(discovery: discovery),
        ),
      ),
    );
    await tester.pump();
    expect(discovery.personalization, isTrue);
    await tester.tap(find.text('Personalised rows on Home'));
    await settle(tester);
    expect(discovery.personalization, isFalse);
    expect(
      find.textContaining('Off: Home shows the same rows'),
      findsOneWidget,
    );
    await tester.tap(find.text('Personalised rows on Home'));
    await settle(tester);
    expect(discovery.personalization, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    discovery.dispose();
  });
}
