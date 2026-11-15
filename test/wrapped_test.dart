import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/notifications/episode_alerts.dart';
import 'package:onfeed/src/notifications/smart_alerts.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/brand_logo.dart';
import 'package:onfeed/src/wrapped/wrapped_cards.dart';
import 'package:onfeed/src/wrapped/wrapped_export.dart';
import 'package:onfeed/src/wrapped/wrapped_screen.dart';
import 'package:onfeed/src/wrapped/wrapped_service.dart';
import 'package:onfeed/src/wrapped/wrapped_stats.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hour = 3600000;

int _at(int y, int m, int d, [int h = 20]) =>
    DateTime(y, m, d, h).millisecondsSinceEpoch;

WrappedRow _movie(int id, int at, {int pos = 95, int len = 100}) => WrappedRow(
  kind: 'movie',
  tmdbId: id,
  positionMs: pos * _hour ~/ 100,
  durationMs: len * _hour ~/ 100,
  at: at,
);

WrappedRow _ep(int id, int s, int e, int at, {int pos = 95}) => WrappedRow(
  kind: 'episode',
  tmdbId: id,
  season: s,
  episode: e,
  positionMs: pos * 2400000 ~/ 100,
  durationMs: 2400000,
  at: at,
);

TitleInfo _info(
  String name, {
  List<String> genres = const [],
  List<int> cast = const [],
  Map<int, int> seasons = const {},
}) => TitleInfo(
  name: name,
  genres: genres,
  cast: [for (final id in cast) (id: id, name: 'Actor $id', profile: '')],
  seasons: seasons,
);

WrappedSummary _compute(
  List<WrappedRow> rows,
  Map<String, TitleInfo> info, {
  int year = 2026,
  DateTime? now,
}) => WrappedStats.compute(
  year: year,
  rows: rows,
  info: info,
  now: now ?? DateTime(2027, 1, 10),
);

void main() {
  group('Counting', () {
    test('only finished, valid titles of the year count, each once', () {
      final s = _compute(
        [
          _movie(1, _at(2026, 3, 1)),
          _movie(1, _at(2026, 3, 1)), // A repeat in the answer.
          _movie(2, _at(2026, 3, 2), pos: 60), // Not finished.
          _movie(3, _at(2025, 12, 31)), // Last year.
          _movie(4, _at(2026, 5, 1), len: 0), // No length.
          _movie(5, _at(2026, 5, 1), len: 3000), // Thirty hours: not real.
          _ep(10, 1, 1, _at(2026, 4, 1)),
          _ep(10, 1, 2, _at(2026, 4, 1), pos: 50),
        ],
        {
          'movie:1': _info('One'),
          'movie:2': _info('Two'),
          'series:10': _info('Show'),
        },
      );
      expect(s.movies.map((m) => m.name), ['One']);
      expect(s.episodes, 1);
      expect(s.series.single.count, 1);
    });

    test('the year is read in local time, at its edges', () {
      final s = _compute(
        [
          _movie(1, DateTime(2025, 12, 31, 23, 30).millisecondsSinceEpoch),
          _movie(2, DateTime(2026, 1, 1, 0, 30).millisecondsSinceEpoch),
          _movie(3, DateTime(2026, 12, 31, 23, 59).millisecondsSinceEpoch),
          _movie(4, DateTime(2027, 1, 1, 0, 1).millisecondsSinceEpoch),
        ],
        {
          for (final id in [1, 2, 3, 4]) 'movie:$id': _info('M$id'),
        },
      );
      expect(s.movies.map((m) => m.id), [2, 3]);
      expect(s.months[0], 1);
      expect(s.months[11], 1);
    });

    test('watch time is the furthest point, from 90 seconds, never past the '
        'length', () {
      final s = _compute([
        _movie(1, _at(2026, 2, 1), pos: 150, len: 100), // Past its length.
        _movie(2, _at(2026, 2, 1), pos: 1, len: 100), // 36 s: a sample.
        _ep(9, 1, 1, _at(2026, 2, 1), pos: 50), // 20 min.
      ], {});
      expect(s.movieMinutes, 60);
      expect(s.seriesMinutes, 20);
      // Not finished, still counted as time.
      expect(s.movies, hasLength(1));
    });

    test('genres and actors count once per title, a series once', () {
      final s = _compute(
        [
          _movie(1, _at(2026, 1, 5)),
          _movie(2, _at(2026, 1, 6)),
          for (var e = 1; e <= 6; e++) _ep(10, 1, e, _at(2026, 2, e)),
        ],
        {
          'movie:1': _info('A', genres: ['Drama', 'Drama'], cast: [7, 8]),
          'movie:2': _info('B', genres: ['Comedy'], cast: [7]),
          'series:10': _info('S', genres: ['Drama'], cast: [8, 8, 9]),
        },
      );
      expect(s.genres.first, (name: 'Drama', count: 2));
      expect(s.genreTitles, 3);
      // Actor 7 in two movies, actor 8 in a movie and the series; 9 in one
      // title only, so not listed.
      expect({for (final a in s.actors) a.id: a.count}, {7: 2, 8: 2});
    });

    test(
      'a season is finished when all of it is, the last of it this year',
      () {
        final s = _compute(
          [
            _ep(10, 1, 1, _at(2025, 12, 20)),
            _ep(10, 1, 2, _at(2026, 1, 3)),
            _ep(10, 1, 3, _at(2026, 1, 4)),
            _ep(10, 2, 1, _at(2026, 6, 1)),
          ],
          {
            'series:10': _info('Show', seasons: {1: 3, 2: 2}),
          },
        );
        expect(s.seasonsFinished, 1);
        expect(
          s.milestones.map((m) => m.label),
          contains('First season you finished'),
        );
        // The episode from 2025 is not this year's.
        expect(s.episodes, 3);
      },
    );

    test('milestones follow the order things were finished', () {
      final s = _compute(
        [
          _movie(1, _at(2026, 3, 1)),
          _movie(2, _at(2026, 2, 1)),
          for (var e = 1; e <= 100; e++)
            _ep(10, 1, e, _at(2026, 1, 1) + e * 60000),
        ],
        {
          'movie:1': _info('March'),
          'movie:2': _info('February'),
          'series:10': _info('Show'),
        },
      );
      final byLabel = {for (final m in s.milestones) m.label: m.detail};
      expect(byLabel['Your first movie of 2026'], 'February');
      expect(byLabel['Your 100th episode'], 'Show');
    });

    test('a recap computed after the server dropped the year\'s start says '
        'what it covers', () {
      expect(_compute([], {}, now: DateTime(2027, 1, 20)).partial, isFalse);
      final late = _compute([], {}, now: DateTime(2027, 3, 1));
      expect(late.partial, isTrue);
      expect(DateTime.fromMillisecondsSinceEpoch(late.coveredFrom).year, 2026);
    });

    test('a summary survives the trip through storage', () {
      final s = _compute(
        [_movie(1, _at(2026, 3, 1)), _ep(10, 1, 1, _at(2026, 4, 1))],
        {
          'movie:1': _info('One', genres: ['Drama'], cast: [1]),
          'series:10': _info('Show', genres: ['Drama'], cast: [1]),
        },
      );
      final back = WrappedSummary.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect(jsonEncode(back!.toJson()), jsonEncode(s.toJson()));
      expect(WrappedSummary.fromJson({'v': 2}), isNull);
      expect(WrappedSummary.fromJson('x'), isNull);
    });

    test('rows from the API are read strictly', () {
      expect(
        WrappedRow.fromJson({
          'key': 'episode:5:1:2',
          'positionMs': 1,
          'durationMs': 2,
          'at': 3,
          'poster': 'https://evil.example/x.png',
        })!.poster,
        '',
      );
      for (final key in ['movie:0', 'episode:5:1', 'tv:5', 'movie:5;']) {
        expect(
          WrappedRow.fromJson({
            'key': key,
            'positionMs': 1,
            'durationMs': 2,
            'at': 3,
          }),
          isNull,
          reason: key,
        );
      }
    });
  });

  group('Personality', () {
    List<String> ids(WrappedSummary s) => [for (final p in s.personas) p.id];

    test('nothing finished: no personality', () {
      expect(_compute([], {}).personas, isEmpty);
    });

    test('a few titles: the Curious Viewer', () {
      expect(ids(_compute([_movie(1, _at(2026, 1, 1))], {})), ['curious']);
    });

    test('series over movies, binges and a favourite genre, each with its '
        'reason', () {
      final rows = [
        for (var d = 1; d <= 3; d++)
          for (var e = 1; e <= 4; e++) _ep(d, 1, e, _at(2026, 2, d, 14)),
        for (var e = 1; e <= 10; e++) _ep(9, 1, e, _at(2026, 3, e, 14)),
      ];
      final s = _compute(rows, {
        for (final id in [1, 2, 3, 9])
          'series:$id': _info('S$id', genres: ['Horror']),
        'series:20': _info('Other', genres: ['Comedy']),
      });
      // 4 of 4 titles were horror, but devotee needs 5 titles.
      expect(ids(s), ['binge', 'story']);
      expect(s.personas.first.reason, contains('3 days'));
    });
  });

  group('WrappedService', () {
    late List<Map<String, Object?>> rows;
    late int detailCalls;

    Future<WrappedService> service(
      DateTime now, {
      bool failDetails = false,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final account = AccountController(
        store: MemorySessionStore(
          StoredSession(
            sessionId: 's',
            accessToken: 'a',
            accessExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
            refreshToken: 'r',
            refreshExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
            userId: 'u',
            username: 'viewer',
          ),
        ),
      );
      await account.restore();
      detailCalls = 0;
      return WrappedService(
        account: account,
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.app'),
          client: MockClient((request) async {
            final since = int.parse(request.url.queryParameters['since']!);
            final page = rows.skip(since).take(2).toList();
            final more = since + 2 < rows.length;
            return http.Response(
              jsonEncode({
                'items': page,
                'cursor': since + page.length,
                'more': more,
                'serverTime': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
        details: (type, id) async {
          detailCalls++;
          if (failDetails && id == 2) throw StateError('offline');
          return {
            'title': 'Film $id',
            'genres': [
              {'name': 'Drama'},
            ],
          };
        },
        clock: () => now,
      );
    }

    Map<String, Object?> row(String key, int at) => {
      'key': key,
      'positionMs': 95,
      'durationMs': 100,
      'at': at,
    };

    test(
      'reads every page, looks titles up once, and keeps the recap',
      () async {
        rows = [
          row('movie:1', _at(2026, 1, 1)),
          row('movie:2', _at(2026, 2, 1)),
          row('movie:3', _at(2026, 3, 1)),
          row('movie:4', _at(2025, 3, 1)), // Not this year: not looked up.
          row('episode:9:1:1', _at(2026, 4, 1)),
        ];
        final wrapped = await service(DateTime(2027, 1, 5), failDetails: true);
        final s = await wrapped.load(2026);
        // Movie 2's details failed: it still counts, under a plain name.
        expect(s.movies.map((m) => m.id), [1, 2, 3]);
        expect(s.movies[1].name, 'A movie');
        expect(s.episodes, 1);
        expect(detailCalls, 4);
        expect((await wrapped.saved(2026))!.finished, s.finished);
        expect(await wrapped.years(), [2026]);
        // Kept: no second computation.
        await wrapped.load(2026);
        expect(detailCalls, 4);
      },
    );

    test('a later count that finds less keeps the kept recap', () async {
      rows = [row('movie:1', _at(2026, 1, 1)), row('movie:3', _at(2026, 3, 1))];
      final wrapped = await service(DateTime(2027, 1, 5));
      await wrapped.load(2026);
      rows = [row('movie:3', _at(2026, 3, 1))];
      final again = await wrapped.load(2026, refresh: true);
      expect(again.movies, hasLength(2));
    });

    test('a year opens only once it is over', () async {
      rows = [];
      final wrapped = await service(DateTime(2026, 11, 15));
      expect(wrapped.latestYear, 2025);
      expect(wrapped.isOpen(2026), isFalse);
      await expectLater(wrapped.load(2026), throwsStateError);
    });
  });

  group('Wrapped is out', () {
    test('in January, once a year, for someone who watched', () {
      final events = WrappedAnnouncement.detect(
        now: DateTime(2027, 1, 2),
        watchedLastYear: true,
      );
      expect(events.single.key, 'wrapped:2026');
      expect(events.single.target, 'wrapped:2026');
      expect(
        WrappedAnnouncement.detect(
          now: DateTime(2027, 2, 2),
          watchedLastYear: true,
        ),
        isEmpty,
      );
      expect(
        WrappedAnnouncement.detect(
          now: DateTime(2027, 1, 2),
          watchedLastYear: false,
        ),
        isEmpty,
      );
      final target = AlertTarget.parse(
        AlertTarget.payloadOf(events.single.target, events.single.name),
      );
      expect((target!.kind, target.id), ('wrapped', 2026));
    });
  });

  group('On screen', () {
    late WrappedSummary summary;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final loader = FontLoader('Montserrat');
      for (final w in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/Montserrat-$w.ttf'));
      }
      await loader.load();
      summary = _compute(
        [
          for (var i = 1; i <= 30; i++) _movie(i, _at(2026, 1 + i % 12, 3)),
          for (var d = 1; d <= 3; d++)
            for (var e = 1; e <= 5; e++) _ep(100, d, e, _at(2026, 5, d)),
        ],
        {
          for (var i = 1; i <= 30; i++)
            'movie:$i': _info(
              'A Rather Long Movie Title $i',
              genres: [i.isEven ? 'Science Fiction' : 'Drama', 'Thriller'],
              cast: [1, 2, i + 10],
            ),
          'series:100': _info(
            'The Longest Running Show',
            genres: ['Drama'],
            cast: [1],
            seasons: {1: 5, 2: 5, 3: 5},
          ),
        },
      );
    });

    testWidgets('every card, in every format, draws and exports cleanly', (
      tester,
    ) async {
      final out = Platform.environment['WRAPPED_OUT'];
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final kind in wrappedCardsFor(summary)) {
        for (final format in WrappedCardFormat.values) {
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: GlassTheme.dark,
              home: Center(
                child: RepaintBoundary(
                  key: key,
                  child: WrappedCard(
                    kind: kind,
                    summary: summary,
                    format: format,
                    options: const WrappedCardOptions(name: 'Sam'),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: '$kind $format');
          // As the share sheet does: the wordmark loaded before export.
          await tester.runAsync(
            () => precacheImage(
              const AssetImage(BrandAssets.wordLogo),
              tester.element(find.byType(WrappedCard)),
            ),
          );
          await tester.pump();
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final png = await WrappedExport.capture(boundary);
            expect(png.length, greaterThan(1000));
            final image = await decodeImageFromList(png);
            expect(image.width, 1080, reason: '$kind $format');
            expect(
              image.height,
              (1080 / format.aspect).round(),
              reason: '$kind $format',
            );
            if (out != null) {
              File(
                '$out/card_${kind.name}_${format.name}.png',
              ).writeAsBytesSync(png);
            }
          });
        }
      }
    });

    /// The story for a recap already kept, on a [size] screen.
    Future<void> showStory(
      WidgetTester tester,
      Size size,
      GlobalKey key,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        WrappedService.storageKey: jsonEncode({
          'u': {'2026': summary.toJson()},
        }),
      });
      final account = AccountController(
        store: MemorySessionStore(
          StoredSession(
            sessionId: 's',
            accessToken: 'a',
            accessExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
            refreshToken: 'r',
            refreshExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
            userId: 'u',
            username: 'viewer',
          ),
        ),
      );
      await tester.runAsync(account.restore);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: GlassTheme.dark,
            home: WrappedScreen(
              service: WrappedService(
                account: account,
                api: AccountApi(
                  baseUrl: Uri.parse('https://api.reelish.app'),
                  client: MockClient((_) async => http.Response('{}', 500)),
                ),
                details: (_, _) async => {},
                clock: () => DateTime(2027, 1, 5),
              ),
              year: 2026,
            ),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
    }

    for (final (name, size) in [
      ('phone', const Size(412, 915)),
      ('wide', const Size(1280, 720)),
    ]) {
      testWidgets(
        'every slide fits a $name screen',
        (tester) async {
          final key = GlobalKey();
          await showStory(tester, size, key);
          final out = Platform.environment['WRAPPED_OUT'];
          for (var i = 0; i < 9; i++) {
            expect(tester.takeException(), isNull, reason: 'slide $i');
            if (out != null) {
              await tester.runAsync(() async {
                final boundary =
                    key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final png = await WrappedExport.capture(
                  boundary,
                  pixelRatio: 1,
                );
                File('$out/slide_${name}_$i.png').writeAsBytesSync(png);
              });
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pump();
            await tester.pump(const Duration(seconds: 2));
          }
        },
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );
    }

    /// The 2026 story on a [size] screen, opened on a recap already kept.
    Future<void> pumpKeptStory(
      WidgetTester tester, {
      Size size = const Size(1280, 720),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final account = AccountController(
        store: MemorySessionStore(
          StoredSession(
            sessionId: 's',
            accessToken: 'a',
            accessExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900,
            refreshToken: 'r',
            refreshExpiresAt:
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400,
            userId: 'u',
            username: 'viewer',
          ),
        ),
      );
      await tester.runAsync(account.restore);
      final service = WrappedService(
        account: account,
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.app'),
          client: MockClient((_) async => http.Response('{}', 500)),
        ),
        details: (_, _) async => {},
        clock: () => DateTime(2027, 1, 5),
      );
      // A recap already kept: the screen opens on it.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        WrappedService.storageKey,
        jsonEncode({
          'u': {'2026': summary.toJson()},
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: WrappedScreen(service: service, year: 2026),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets(
      'on TV the remote walks the story, and nothing offers to share',
      (tester) async {
        DeviceCapabilities.debugOverride = const DeviceCapabilities(
          isTelevision: true,
          hasTouchscreen: false,
        );
        addTearDown(
          () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
        );
        expect(WrappedExport.canShare, isFalse);
        expect(await WrappedExport.canSave(), isFalse);
        await pumpKeptStory(tester, size: const Size(1920, 1080));
        expect(find.text('One year. Countless stories.'), findsOneWidget);
        for (var i = 0; i < 12; i++) {
          expect(
            find.textContaining('Share'),
            findsNothing,
            reason: 'slide $i',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
        }
        expect(find.text('Your 2026 in stories'), findsOneWidget);
        expect(find.text('Replay'), findsOneWidget);
        expect(find.textContaining('Share'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the story moves with the keyboard and ends on the finale',
      (tester) async {
        await pumpKeptStory(tester);
        expect(find.text('One year. Countless stories.'), findsOneWidget);
        for (var i = 0; i < 12; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
        }
        expect(find.text('Your 2026 in stories'), findsOneWidget);
        expect(find.text('Replay'), findsOneWidget);
        expect(find.textContaining('How this was counted'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        // One frame starts the page animation, the next moves it.
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('Your 2026 in stories'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}
