import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:onfeed/src/desktop/desktop_details_screen.dart';
import 'package:onfeed/src/desktop/desktop_hero.dart';
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/desktop/desktop_shell.dart';
import 'package:onfeed/src/desktop/desktop_widgets.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/paged_feed_controller.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';

/// The Windows layout as users see it: the Spotlight and its rail,
/// the details page's episode panel, and both at the window sizes Windows
/// users run.

const _sizes = [
  Size(1280, 720),
  Size(1366, 768),
  Size(1920, 1080),
  Size(2560, 1440),
  // A window dragged narrow.
  Size(900, 600),
];

List<MediaItem> _spotlight(int count) => [
  for (var i = 0; i < count; i++)
    MediaItem(
      id: '$i',
      type: i.isEven ? 'movie' : 'series',
      name: 'Title $i with a fairly long name',
      year: '2024',
      rating: '7.$i',
      genreIds: const [28, 878],
      description: 'A synopsis long enough to wrap over several lines. ' * 4,
    ),
];

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The hero where the shell puts it: right of the expanded sidebar.
Future<void> _pumpHero(
  WidgetTester tester,
  List<MediaItem> items, {
  Size size = const Size(1920, 1080),
  bool shown = true,
  Future<String> Function(MediaItem item)? logoOf,
}) async {
  await _setSize(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      theme: GlassTheme.dark,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(left: DesktopShell.expandedWidth),
          child: TickerMode(
            enabled: shown,
            child: ListView(
              children: [
                DesktopHero(
                  items: items,
                  onPlay: (_) {},
                  onDetails: (_) {},
                  isFavorite: (_) => false,
                  onToggleFavorite: (_) async => true,
                  logoOf: logoOf,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The hero's title, not a preview card's caption.
Finder _heroTitle(String name) => find.byWidgetPredicate(
  (w) => w is Text && w.data == name && w.style?.fontSize == 50,
);

Finder _previewCards() => find.byWidgetPredicate(
  (w) => w is Tooltip && w.message!.startsWith('Show'),
);

class _FakeTmdb extends TmdbService {
  @override
  Future<MediaDetails> details(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(MediaDetails)? onRevalidated,
  }) async => const MediaDetails(
    overview: 'A plot that runs on for a while. A plot that runs on.',
    genres: ['Drama', 'Mystery'],
    runtimeMinutes: 52,
    cast: [CastMember(name: 'Someone', character: 'A part', profile: '')],
  );

  @override
  Future<List<Map<String, dynamic>>> seasons(
    MediaItem item, {
    bool forceRefresh = false,
  }) async => [
    {'season_number': 1, 'name': 'Season One'},
    {'season_number': 2, 'name': 'Season Two'},
  ];

  @override
  Future<List<Map<String, dynamic>>> episodes(
    MediaItem item,
    int season, {
    bool forceRefresh = false,
  }) async => [
    for (var i = 1; i <= (season == 1 ? 8 : 2); i++)
      {
        'episode_number': i,
        'name': season == 1 ? 'Episode name $i' : 'Later $i',
        'air_date': '2020-01-0$i',
        'runtime': 50,
        'overview': 'What happens in this one.',
      },
  ];

  @override
  Future<List<MediaItem>> recommendations(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
  }) async => const [MediaItem(id: '9', type: 'movie', name: 'Related film')];
}

const _series = MediaItem(
  id: '7',
  type: 'series',
  name: 'A series',
  year: '2020',
);
const _movie = MediaItem(id: '8', type: 'movie', name: 'A film', year: '2021');

void main() {
  group('Spotlight rail', () {
    Finder card(String tooltip) => find.byTooltip(tooltip);
    Size sizeOf(WidgetTester tester, String tooltip) => tester.getSize(
      find
          .descendant(
            of: card(tooltip),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );

    testWidgets('lists every title: the shown one as a wide backdrop card '
        'with its details, the others as posters of the same height', (
      tester,
    ) async {
      await _pumpHero(tester, _spotlight(5));
      // The shown title opens its details; every other one shows itself.
      expect(card('More about Title 0 with a fairly long name'), findsOne);
      expect(_previewCards(), findsNWidgets(4));
      // Its name and details on the card, beside a play button.
      final shown = card('More about Title 0 with a fairly long name');
      expect(
        find.descendant(
          of: shown,
          matching: find.text('Title 0 with a fairly long name'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: shown,
          matching: find.textContaining(
            '7.0  |  2024  |  Movie  |  Action, Sci-Fi',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: shown, matching: find.byTooltip('Play')),
        findsOneWidget,
      );
      expect(find.text('01  /  05'), findsOneWidget);
      final wide = sizeOf(tester, 'More about Title 0 with a fairly long name');
      final poster = sizeOf(tester, 'Show Title 1 with a fairly long name');
      expect(wide.height, poster.height);
      expect(wide.aspectRatio, moreOrLessEquals(16 / 9, epsilon: .01));
      expect(poster.aspectRatio, moreOrLessEquals(2 / 3, epsilon: .01));
      // Genres from TMDB ids, beside the year and type.
      expect(find.textContaining('Action  ·  Sci-Fi'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a click shows that title, which widens and leads the rail', (
      tester,
    ) async {
      await _pumpHero(tester, _spotlight(20));
      await tester.tap(card('Show Title 2 with a fairly long name'));
      await tester.pumpAndSettle();
      expect(_heroTitle('Title 2 with a fairly long name'), findsOneWidget);
      expect(find.text('03  /  20'), findsOneWidget);
      expect(card('More about Title 2 with a fairly long name'), findsOne);
      // Scrolled so the shown card starts at the page margin.
      expect(
        tester
            .getTopLeft(card('More about Title 2 with a fairly long name'))
            .dx,
        moreOrLessEquals(
          DesktopShell.expandedWidth + DesktopMetrics.pagePadding,
          epsilon: 1,
        ),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a click on the shown card opens its details; its button '
        'plays', (tester) async {
      final opened = <String>[], played = <String>[];
      await _setSize(tester, const Size(1920, 1080));
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: ListView(
              children: [
                DesktopHero(
                  items: _spotlight(3),
                  onPlay: (item) => played.add(item.id),
                  onDetails: (item) => opened.add(item.id),
                  isFavorite: (_) => false,
                  onToggleFavorite: (_) async => true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(card('More about Title 0 with a fairly long name'));
      await tester.pump();
      expect(opened, ['0']);
      expect(played, isEmpty);

      await tester.tap(
        find.descendant(
          of: card('More about Title 0 with a fairly long name'),
          matching: find.byTooltip('Play'),
        ),
      );
      await tester.pump();
      expect(played, ['0']);
      expect(opened, ['0']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the rail loops: it starts at the shown title, and the first '
        'title follows the last', (tester) async {
      await _pumpHero(tester, _spotlight(5));
      double left(String tooltip) => tester.getTopLeft(card(tooltip)).dx;
      await tester.tap(card('Show Title 4 with a fairly long name'));
      await tester.pumpAndSettle();
      expect(_heroTitle('Title 4 with a fairly long name'), findsOneWidget);
      final shown = left('More about Title 4 with a fairly long name');
      expect(
        shown,
        moreOrLessEquals(
          DesktopShell.expandedWidth + DesktopMetrics.pagePadding,
          epsilon: 1,
        ),
      );
      // Title 0, then 1, follow the last title.
      expect(left('Show Title 0 with a fairly long name'), greaterThan(shown));
      expect(
        left('Show Title 1 with a fairly long name'),
        greaterThan(left('Show Title 0 with a fairly long name')),
      );

      // The rotation wraps the same way.
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(_heroTitle('Title 0 with a fairly long name'), findsOneWidget);
      expect(card('More about Title 0 with a fairly long name'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    for (final size in const [Size(1920, 1080), Size(1366, 768)]) {
      testWidgets('all 12 titles fit at ${size.width.toInt()} px, no '
          'scrolling', (tester) async {
        await _pumpHero(tester, _spotlight(12), size: size);
        final hero = tester.getRect(find.byType(DesktopHero));
        expect(card('More about Title 0 with a fairly long name'), findsOne);
        for (var i = 1; i < 12; i++) {
          final rect = tester.getRect(
            card('Show Title $i with a fairly long name'),
          );
          expect(rect.right, lessThanOrEqualTo(hero.right), reason: '$i');
        }
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('the next title glides to the front and widens; it is not '
        'redrawn there', (tester) async {
      await _pumpHero(tester, _spotlight(5));
      await tester.pumpAndSettle();
      const start = DesktopShell.expandedWidth + DesktopMetrics.pagePadding;
      final before = tester.getRect(
        card('Show Title 1 with a fairly long name'),
      );
      final wide = sizeOf(tester, 'More about Title 0 with a fairly long name');
      await tester.tap(card('Show Title 1 with a fairly long name'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // Midway: between its old place and the front, and widening.
      final moving = tester.getRect(
        card('More about Title 1 with a fairly long name'),
      );
      expect(moving.left, lessThan(before.left));
      expect(moving.left, greaterThan(start + 1));
      expect(moving.width, greaterThan(before.width));
      expect(moving.width, lessThan(wide.width));

      await tester.pumpAndSettle();
      final settled = tester.getRect(
        card('More about Title 1 with a fairly long name'),
      );
      expect(settled.left, moreOrLessEquals(start, epsilon: 1));
      expect(settled.width, moreOrLessEquals(wide.width, epsilon: 1));
      // Title 0 left: only one card shows it, at the end of the loop.
      expect(card('Show Title 0 with a fairly long name'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a short card keeps the name and button, not a clipped '
        'details line', (tester) async {
      // Beside the pinned sidebar at 1280 the cards are at their shortest.
      await _pumpHero(tester, _spotlight(12), size: const Size(1280, 720));
      final shown = card('More about Title 0 with a fairly long name');
      expect(
        find.descendant(of: shown, matching: find.byTooltip('Play')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: shown, matching: find.textContaining('2024  |')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Enter on a focused card shows its title', (tester) async {
      await _pumpHero(tester, _spotlight(4));
      final shown = card('Show Title 1 with a fairly long name');
      Focus.of(
        tester.element(
          find
              .descendant(of: shown, matching: find.byType(GestureDetector))
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_heroTitle('Title 1 with a fairly long name'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('logos are asked once per title; a failed one shows the name', (
      tester,
    ) async {
      final asked = <String>[];
      Future<String> logoOf(MediaItem item) async {
        asked.add(item.id);
        return 'https://image.tmdb.org/t/p/w500/logo${item.id}.png';
      }

      await _pumpHero(tester, _spotlight(3), logoOf: logoOf);
      await tester.pumpAndSettle();
      await tester.tap(card('Show Title 1 with a fairly long name'));
      await tester.pumpAndSettle();
      expect(asked, ['0', '1', '2']);
      // Images do not load in tests: the logo falls back to the name, which
      // is still the hero's heading.
      expect(_heroTitle('Title 1 with a fairly long name'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Title 1 with a fairly long name'),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('one title: no rail', (tester) async {
      await _pumpHero(tester, _spotlight(2));
      expect(_previewCards(), findsOneWidget);
      await _pumpHero(tester, _spotlight(1));
      expect(_previewCards(), findsNothing);
      expect(find.byTooltip('Play'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('rotates while shown, and not while another page is', (
      tester,
    ) async {
      await _pumpHero(tester, _spotlight(3), shown: false);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump(const Duration(seconds: 1));
      expect(_heroTitle('Title 0 with a fairly long name'), findsOneWidget);

      await _pumpHero(tester, _spotlight(3));
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(seconds: 1));
      expect(_heroTitle('Title 1 with a fairly long name'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    for (final size in _sizes) {
      testWidgets(
        'at ${size.width.toInt()}×${size.height.toInt()} the text and actions '
        'stay above the rail, inside the hero',
        (tester) async {
          await _pumpHero(tester, _spotlight(12), size: size);
          expect(tester.takeException(), isNull);
          final hero = tester.getRect(find.byType(DesktopHero));
          final shown = tester.getRect(
            card('More about Title 0 with a fairly long name'),
          );
          final guarded = [
            tester.getRect(_heroTitle('Title 0 with a fairly long name')),
            tester.getRect(find.text('More info')),
            tester.getRect(find.byTooltip('Add to My list')),
          ];
          for (final rect in guarded) {
            expect(rect.top, greaterThanOrEqualTo(hero.top), reason: '$rect');
            expect(rect.bottom, lessThan(shown.top), reason: '$rect');
          }
          expect(shown.bottom, lessThanOrEqualTo(hero.bottom));
          // The rail scrolls; at least the shown card and the next fit.
          final next = tester.getRect(
            card('Show Title 1 with a fairly long name'),
          );
          expect(next.right, lessThanOrEqualTo(size.width));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });

  group('Details', () {
    late List<int> reads;
    setUp(() => reads = []);

    Widget details(MediaItem item, {SeriesProgress? progress}) =>
        DesktopDetailsScreen(
          item: item,
          tmdb: _FakeTmdb(),
          onPlay: (_, _) {},
          onPlayEpisode: (_, _, _, _) {},
          isFavorite: (_) => false,
          onToggleFavorite: (_) async => true,
          seriesProgress: progress == null
              ? null
              : (_) async {
                  reads.add(reads.length);
                  return progress;
                },
        );

    Future<void> pump(WidgetTester tester, Widget screen, Size size) async {
      await _setSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(theme: GlassTheme.dark, home: screen),
      );
      await tester.pumpAndSettle();
    }

    const progress = SeriesProgress(
      episodes: {
        '1:1': EpisodeProgress(positionMs: 2950000, durationMs: 3000000),
        '1:2': EpisodeProgress(positionMs: 1200000, durationMs: 3000000),
      },
      last: (season: 1, episode: 2),
    );

    testWidgets('a wide window lists episodes in the panel, with progress', (
      tester,
    ) async {
      await pump(
        tester,
        details(_series, progress: progress),
        const Size(1600, 1000),
      );
      final panel = tester.getRect(find.byType(BackdropFilter));
      // The panel sits in the header, right of the text and actions.
      expect(panel.right, lessThanOrEqualTo(1600));
      final play = tester.getRect(find.textContaining('Play season'));
      expect(play.right, lessThan(panel.left));
      expect(
        panel.contains(tester.getCenter(find.text('1. Episode name 1'))),
        isTrue,
      );
      // Watched, in progress (with what is left) and last watched.
      expect(
        find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Symbols.check_circle_rounded,
        ),
        findsOneWidget,
      );
      expect(find.textContaining('30 min left'), findsOneWidget);
      expect(find.text('LAST WATCHED'), findsOneWidget);
      expect(find.text('8 episodes'), findsOneWidget);
    });

    testWidgets('the panel switches seasons', (tester) async {
      await pump(tester, details(_series), const Size(1600, 1000));
      await tester.tap(find.text('Season Two'));
      await tester.pumpAndSettle();
      expect(find.text('1. Later 1'), findsOneWidget);
      expect(find.text('2 episodes'), findsOneWidget);
    });

    testWidgets('a narrow window lists episodes under the header instead', (
      tester,
    ) async {
      await pump(tester, details(_series), const Size(1000, 760));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('1. Episode name 1', skipOffstage: false), findsOne);
    });

    testWidgets('a movie has no episode panel', (tester) async {
      await pump(tester, details(_movie), const Size(1600, 1000));
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('Episodes'), findsNothing);
    });

    testWidgets('progress is read again after the player closes', (
      tester,
    ) async {
      await pump(
        tester,
        details(_series, progress: progress),
        const Size(1600, 1000),
      );
      expect(reads, hasLength(1));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(reads, hasLength(2));
    });

    for (final size in _sizes) {
      for (final item in [_series, _movie]) {
        testWidgets('${item.type} lays out at ${size.width.toInt()}×'
            '${size.height.toInt()}', (tester) async {
          await pump(tester, details(item, progress: progress), size);
          // Layout overflows fail the test on their own; also the Back
          // and Play buttons are on screen.
          expect(find.byTooltip('Back (Esc)').hitTestable(), findsOne);
          expect(
            tester.getRect(find.textContaining('Play').first).bottom,
            lessThanOrEqualTo(size.height),
          );
        });
      }
    }
  });

  group('Grids and rows', () {
    List<MediaItem> page(int number) => [
      for (var i = 0; i < 20; i++)
        MediaItem(id: '$number-$i', type: 'movie', name: 'Film $number-$i'),
    ];

    PagedFeedController feed(List<int> asked) => PagedFeedController(
      label: 'Test',
      fetch: (number, {previous, required forceRefresh, onRevalidated}) async {
        asked.add(number);
        return CatalogPage(items: page(number), page: number, totalPages: 5);
      },
    );

    Future<void> pumpCatalog(
      WidgetTester tester,
      PagedFeedController feed,
      Size size,
    ) async {
      await _setSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: DesktopCatalogPage(
              title: 'Movies',
              subtitle: 'New and noteworthy films.',
              feed: feed,
              onOpen: (_) {},
              isFavorite: (_) => false,
            ),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('a first page that does not fill the window loads the next', (
      tester,
    ) async {
      final asked = <int>[];
      final movies = feed(asked);
      addTearDown(movies.dispose);
      // Wide and tall: twenty posters, two rows, nothing to scroll.
      await pumpCatalog(tester, movies, const Size(2600, 1600));
      expect(asked, [1, 2]);
      expect(find.text('Film 2-0', skipOffstage: false), findsOneWidget);
    });

    testWidgets('a page that fills the window waits for the scroll', (
      tester,
    ) async {
      final asked = <int>[];
      final movies = feed(asked);
      addTearDown(movies.dispose);
      await pumpCatalog(tester, movies, const Size(1280, 720));
      expect(asked, [1]);
    });

    test('a laptop window shows five posters a row, a 1080p one eight', () {
      // Content width beside the expanded sidebar, less the page margins.
      double content(double window) =>
          window - DesktopShell.expandedWidth - DesktopMetrics.pagePadding * 2;
      expect(DesktopMetrics.columns(content(1280)), 5);
      expect(DesktopMetrics.columns(content(1920)), 8);
    });

    testWidgets('Continue watching cards say what is left', (tester) async {
      await _setSize(tester, const Size(1600, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: DesktopMediaRow(
              title: 'Continue watching',
              items: const [
                MediaItem(id: '1', type: 'movie', name: 'Film', year: '2024'),
              ],
              onOpen: (_) {},
              progressOf: (_) => .4,
              captionOf: (_) => '34 min left',
            ),
          ),
        ),
      );
      expect(find.text('34 min left'), findsOneWidget);
      expect(find.text('2024 · Movie'), findsNothing);
    });
  });
}
