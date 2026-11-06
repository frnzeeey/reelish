import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/content_advisory.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/design_tokens.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/player/content_advisory_overlay.dart';
import 'package:onfeed/src/widgets/player/player_controls.dart';

Map<String, Object?> _country(
  String code,
  List<Map<String, Object?>> releases,
) => {'iso_3166_1': code, 'release_dates': releases};

Map<String, Object?> _release(
  String rating, {
  int type = 3,
  String note = '',
  List<String> descriptors = const [],
}) => {
  'certification': rating,
  'type': type,
  'note': note,
  'descriptors': descriptors,
};

Map<String, Object?> _movie(List<Map<String, Object?>> countries) => {
  'results': countries,
};

Map<String, Object?> _series(Map<String, Object?> ratings) => {
  'results': [
    for (final MapEntry(:key, :value) in ratings.entries)
      {
        'iso_3166_1': key,
        'rating': value is String ? value : (value! as List).first,
        'descriptors': value is String ? const [] : (value! as List).last,
      },
  ],
};

const _sample = ContentAdvisory(
  rating: 'R',
  ratingCountry: 'US',
  descriptors: [ContentDescriptor.violence, ContentDescriptor.language],
);

void main() {
  group('Reading TMDB ratings', () {
    test('uses the viewer\'s own rating, without naming the country', () {
      final advisory = ContentAdvisory.fromMovie(
        _movie([
          _country('US', [_release('R')]),
          _country('PH', [_release('R-13')]),
        ]),
        region: 'ph',
      )!;
      expect(advisory.rating, 'R-13');
      expect(advisory.ratingLabel, 'R-13');
      expect(advisory.heading, 'AGE RATING');
    });

    test('falls back to the US, then the UK, and says whose it is', () {
      final us = ContentAdvisory.fromMovie(
        _movie([
          _country('US', [_release('PG-13')]),
          _country('GB', [_release('12A')]),
        ]),
        region: 'PH',
      )!;
      expect(us.ratingLabel, 'PG-13 · US');
      final uk = ContentAdvisory.fromMovie(
        _movie([
          _country('GB', [_release('12A')]),
        ]),
        region: 'PH',
      )!;
      expect(uk.ratingLabel, '12A · GB');
    });

    test('a rating alone is never turned into content warnings', () {
      final advisory = ContentAdvisory.fromSeries(
        _series({'US': 'TV-MA'}),
        region: 'US',
      )!;
      expect(advisory.rating, 'TV-MA');
      expect(advisory.descriptors, isEmpty);
      expect(advisory.heading, 'AGE RATING');
      expect(advisory.descriptorSource, isEmpty);
    });

    test('names the board when descriptors come from another country', () {
      // The shape of real data: Oppenheimer-like, no US descriptors.
      final advisory = ContentAdvisory.fromMovie(
        _movie([
          _country('US', [_release('R')]),
          _country('DE', [
            _release('12', descriptors: ['Violence', 'Threat', 'Injury']),
          ]),
        ]),
        region: 'US',
      )!;
      expect(advisory.rating, 'R');
      expect(advisory.heading, 'CONTENT ADVISORY');
      expect(advisory.descriptorLine, 'Violence · Frightening Scenes');
      expect(advisory.descriptorSource, 'From the rating in Germany (12)');
    });

    test('its own board\'s descriptors need no source', () {
      final advisory = ContentAdvisory.fromMovie(
        _movie([
          _country('DE', [
            _release('16', descriptors: ['Violence']),
          ]),
        ]),
        region: 'DE',
      )!;
      expect(advisory.descriptorSource, isEmpty);
      expect(advisory.ratingLabel, '16');
    });

    test('boards are never mixed', () {
      final advisory = ContentAdvisory.fromMovie(
        _movie([
          _country('US', [_release('R')]),
          _country('NL', [
            _release('16', descriptors: ['Fear']),
          ]),
          _country('BR', [
            _release('18', descriptors: ['Drugs', 'Nudity']),
          ]),
        ]),
        region: 'US',
      )!;
      expect(advisory.descriptors, [ContentDescriptor.frighteningScenes]);
    });

    test('vague or unknown values are left out, and leave no advisory', () {
      final advisory = ContentAdvisory.fromMovie(
        _movie([
          _country('US', [_release('PG')]),
          _country('TR', [
            _release('10A', descriptors: ['Negative examples', 'Mystery']),
          ]),
          _country('BR', [
            _release('14', descriptors: ['Criminal Acts']),
          ]),
        ]),
        region: 'US',
      )!;
      expect(advisory.descriptors, isEmpty);
      expect(advisory.heading, 'AGE RATING');
    });

    test('a single letter counts only on its board\'s scheme', () {
      final known = ContentAdvisory.fromMovie(
        _movie([
          _country('US', [_release('R')]),
          _country('ZA', [
            _release('16', descriptors: ['V', 'L']),
          ]),
        ]),
        region: 'US',
      )!;
      expect(known.descriptors, [
        ContentDescriptor.violence,
        ContentDescriptor.language,
      ]);
      final unknown = ContentAdvisory.fromMovie(
        _movie([
          _country('US', [_release('R')]),
          _country('NL', [
            _release('16', descriptors: ['V']),
          ]),
        ]),
        region: 'US',
      )!;
      expect(unknown.descriptors, isEmpty);
    });

    test('a country\'s fullest release speaks for it', () {
      final advisory = ContentAdvisory.fromMovie(
        _movie([
          _country('BR', [
            _release('14', descriptors: ['Violence']),
            _release(
              '14',
              type: 4,
              descriptors: ['Nudity', 'Inappropriate Language', 'Violence'],
            ),
          ]),
        ]),
        region: 'BR',
      )!;
      expect(advisory.descriptors, hasLength(3));
    });

    test('the original release outranks a reissue', () {
      final advisory = ContentAdvisory.fromMovie(
        _movie([
          _country('GB', [
            _release('15', note: '25th Anniversary'),
            _release('18'),
          ]),
        ]),
        region: 'GB',
      )!;
      expect(advisory.rating, '18');
    });

    test('nothing reliable means no advisory at all', () {
      expect(ContentAdvisory.fromMovie(_movie([])), isNull);
      expect(ContentAdvisory.fromMovie(null), isNull);
      expect(ContentAdvisory.fromMovie({'results': 'x'}), isNull);
      expect(
        ContentAdvisory.fromMovie(
          _movie([
            _country('US', [_release(''), _release('NR')]),
            _country('GB', [_release('Not Rated')]),
          ]),
        ),
        isNull,
      );
      expect(ContentAdvisory.fromSeries(_series({'FR': '12'})), isNull);
    });

    test('malformed entries are skipped', () {
      final advisory = ContentAdvisory.fromMovie({
        'results': [
          7,
          {'iso_3166_1': 'US', 'release_dates': 'x'},
          _country('GB', [
            {'certification': 15},
            _release('<b>15</b>'),
            _release('15'),
          ]),
        ],
      });
      expect(advisory?.rating, '15');
    });

    test('a screen reader hears all of it', () {
      const advisory = ContentAdvisory(
        rating: 'R',
        ratingCountry: 'US',
        showCountry: true,
        descriptors: [ContentDescriptor.violence],
        descriptorSource: 'From the rating in Germany (12)',
      );
      expect(
        advisory.spokenLabel,
        'Age rating R, US. Content advisory: Violence. '
        'From the rating in Germany (12)',
      );
    });
  });

  group('Fetching', () {
    late Directory cacheRoot;
    setUp(() => cacheRoot = Directory.systemTemp.createTempSync('advisory'));
    tearDown(() async {
      // The cache may still be finishing a write on Windows.
      try {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        cacheRoot.deleteSync(recursive: true);
      } on FileSystemException {
        // A temporary folder; the system clears it.
      }
    });

    TmdbService service(http.Client client) => TmdbService(
      baseUrl: 'https://api.themoviedb.org/3',
      accessToken: ({bool forceRefresh = false}) async => 'test-token',
      testClient: client,
      network: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('8.8.8.8')],
      ),
      cache: TmdbResponseCache(directory: cacheRoot),
      wait: (_) async {},
      jitter: () => 0,
    );

    test('a movie and a series use their own route', () async {
      final paths = <String>[];
      final tmdb = service(
        MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            jsonEncode(
              request.url.path.contains('content_ratings')
                  ? _series({'US': 'TV-MA'})
                  : _movie([
                      _country('US', [_release('R')]),
                    ]),
            ),
            200,
          );
        }),
      );
      final movie = await tmdb.contentAdvisory(
        const MediaItem(id: '550', type: 'movie', name: 'A'),
      );
      final series = await tmdb.contentAdvisory(
        const MediaItem(id: '1399', type: 'series', name: 'B'),
      );
      expect(movie?.rating, 'R');
      expect(series?.rating, 'TV-MA');
      expect(paths.first, endsWith('/movie/550/release_dates'));
      expect(paths.last, endsWith('/tv/1399/content_ratings'));
    });

    test(
      'a gateway without the routes means no advisory, not an error',
      () async {
        final tmdb = service(
          MockClient(
            (_) async => http.Response('{"code":"unknown_route"}', 404),
          ),
        );
        expect(
          await tmdb.contentAdvisory(
            const MediaItem(id: '550', type: 'movie', name: 'A'),
          ),
          isNull,
        );
      },
    );

    test('a second request for the title is served from the cache', () async {
      var requests = 0;
      final tmdb = service(
        MockClient((_) async {
          requests++;
          return http.Response(jsonEncode(_series({'US': 'TV-14'})), 200);
        }),
      );
      const series = MediaItem(id: '66732', type: 'series', name: 'C');
      await tmdb.contentAdvisory(series);
      await tmdb.contentAdvisory(series);
      expect(requests, 1, reason: 'each episode reuses the series rating');
    });
  });

  group('When it shows', () {
    testWidgets('after both playback and the advisory, then goes', (
      tester,
    ) async {
      final controller = ContentAdvisoryController();
      addTearDown(controller.dispose);
      controller.provide(_sample);
      expect(controller.visible, isFalse, reason: 'not before a frame plays');
      controller.playbackStarted();
      expect(controller.visible, isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(controller.visible, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(controller.visible, isFalse);
    });

    testWidgets('an advisory arriving soon after playback still shows', (
      tester,
    ) async {
      final controller = ContentAdvisoryController();
      addTearDown(controller.dispose);
      controller.playbackStarted();
      await tester.pump(const Duration(seconds: 3));
      controller.provide(_sample);
      expect(controller.visible, isTrue);
      await tester.pump(const Duration(seconds: 7));
      expect(controller.visible, isFalse);
    });

    testWidgets('one arriving too late does not interrupt the scene', (
      tester,
    ) async {
      final controller = ContentAdvisoryController();
      addTearDown(controller.dispose);
      controller.playbackStarted();
      await tester.pump(const Duration(seconds: 13));
      controller.provide(_sample);
      expect(controller.visible, isFalse);
    });

    testWidgets('never comes back in the same session', (tester) async {
      final controller = ContentAdvisoryController();
      addTearDown(controller.dispose);
      var changes = 0;
      controller.addListener(() => changes++);
      controller
        ..provide(_sample)
        ..playbackStarted()
        // A source or engine switch reaches the first frame again.
        ..playbackStarted();
      await tester.pump(const Duration(seconds: 7));
      controller
        ..playbackStarted()
        ..provide(_sample);
      expect(controller.visible, isFalse);
      expect(changes, 2, reason: 'shown once, hidden once');
    });

    testWidgets('dismissing ends it, and nothing fires afterwards', (
      tester,
    ) async {
      final controller = ContentAdvisoryController();
      addTearDown(controller.dispose);
      controller
        ..provide(_sample)
        ..playbackStarted()
        ..dismiss();
      expect(controller.visible, isFalse);
      await tester.pump(const Duration(seconds: 7));
      expect(controller.visible, isFalse);
    });

    testWidgets('the display time can be changed', (tester) async {
      final controller = ContentAdvisoryController(
        displayFor: const Duration(seconds: 2),
      );
      addTearDown(controller.dispose);
      controller
        ..provide(_sample)
        ..playbackStarted();
      await tester.pump(const Duration(seconds: 3));
      expect(controller.visible, isFalse);
    });

    testWidgets('a title without an advisory shows nothing', (tester) async {
      final controller = ContentAdvisoryController();
      addTearDown(controller.dispose);
      controller
        ..provide(null)
        ..playbackStarted();
      expect(controller.visible, isFalse);
    });

    testWidgets('a disposed player ignores what arrives later', (tester) async {
      final controller = ContentAdvisoryController()..playbackStarted();
      controller.dispose();
      controller.provide(_sample);
      await tester.pump(const Duration(seconds: 20));
    });
  });

  group('On screen', () {
    Future<ContentAdvisoryController> show(
      WidgetTester tester, {
      ContentAdvisory advisory = _sample,
      bool tv = false,
      Size size = const Size(360, 720),
      double textScale = 1,
      bool controls = true,
      bool reducedMotion = false,
      ValueNotifier<bool>? controlsVisible,
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = ContentAdvisoryController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
            padding: const EdgeInsets.only(top: 24),
            disableAnimations: reducedMotion,
          ),
          child: MaterialApp(
            theme: GlassTheme.dark,
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  ContentAdvisoryOverlay(
                    controller: controller,
                    controlsVisible:
                        controlsVisible ?? ValueNotifier<bool>(controls),
                    tv: tv,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      controller
        ..provide(advisory)
        ..playbackStarted();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      return controller;
    }

    const long = ContentAdvisory(
      rating: 'TV-MA',
      ratingCountry: 'US',
      showCountry: true,
      descriptors: ContentDescriptor.values,
      descriptorSource: 'From the rating in the Netherlands (16)',
    );

    testWidgets('shows only what the advisory holds', (tester) async {
      await show(
        tester,
        advisory: const ContentAdvisory(rating: 'PG', ratingCountry: 'US'),
      );
      expect(find.text('AGE RATING'), findsOneWidget);
      expect(find.text('PG'), findsOneWidget);
      expect(find.text('CONTENT ADVISORY'), findsNothing);
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('wraps a long advisory instead of overflowing', (tester) async {
      await show(tester, advisory: long, textScale: 2);
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.byType(DecoratedBox).first);
      expect(card.width, lessThanOrEqualTo(360 * 0.6));
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('sits below the top bar, and moves up when it hides', (
      tester,
    ) async {
      final visible = ValueNotifier(true);
      await show(tester, controlsVisible: visible);
      final below = tester.getTopLeft(find.byType(DecoratedBox).first);
      expect(
        below.dy,
        greaterThanOrEqualTo(24 + PlayerControlsLayout.topBarExtent(tv: false)),
      );
      visible.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final up = tester.getTopLeft(find.byType(DecoratedBox).first);
      expect(up.dy, lessThan(below.dy));
      expect(up.dx, below.dx);
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('on TV, it stays inside the overscan-safe area', (
      tester,
    ) async {
      await show(tester, tv: true, size: const Size(960, 540), controls: false);
      final corner = tester.getTopLeft(find.byType(DecoratedBox).first);
      expect(corner.dx, greaterThanOrEqualTo(960 * 0.05));
      expect(corner.dy, greaterThanOrEqualTo(540 * 0.05));
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('takes no focus, so the remote never lands on it', (
      tester,
    ) async {
      await show(tester, tv: true, size: const Size(960, 540));
      expect(
        FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<ContentAdvisoryOverlay>()),
      );
      expect(
        find.descendant(
          of: find.byType(ContentAdvisoryOverlay),
          matching: find.byType(ExcludeFocus),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('a tap dismisses it', (tester) async {
      final controller = await show(tester);
      await tester.tap(find.text('CONTENT ADVISORY'));
      expect(controller.visible, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('is announced once as one label', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester);
      expect(find.bySemanticsLabel(_sample.spokenLabel), findsOneWidget);
      semantics.dispose();
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('reduced motion removes the fade', (tester) async {
      await show(tester, reducedMotion: true);
      final fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(fade.duration, Duration.zero);
      expect(AppMotion.exitOf(Duration.zero), Duration.zero);
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('text keeps its contrast over a white frame', (tester) async {
      await show(tester);
      final box =
          tester
                  .widget<DecoratedBox>(find.byType(DecoratedBox).first)
                  .decoration
              as BoxDecoration;
      final fill = Color.alphaBlend(box.color!, Colors.white);
      final ratio =
          (Colors.white.computeLuminance() + 0.05) /
          (fill.computeLuminance() + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5));
      await tester.pump(const Duration(seconds: 7));
    });
  });
}
