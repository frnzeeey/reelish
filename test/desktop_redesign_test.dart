import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:onfeed/src/desktop/desktop_details_screen.dart';
import 'package:onfeed/src/desktop/desktop_hero.dart';
import 'package:onfeed/src/desktop/desktop_shell.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';

/// The Windows layout as users see it: the Spotlight's next-up previews,
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
  group('Spotlight previews', () {
    testWidgets('show the next three titles, the first as Up next', (
      tester,
    ) async {
      await _pumpHero(tester, _spotlight(5));
      expect(_previewCards(), findsNWidgets(3));
      expect(find.text('UP NEXT'), findsOneWidget);
      for (final i in [1, 2, 3]) {
        expect(
          find.byTooltip('Show Title $i with a fairly long name'),
          findsOne,
        );
      }
      expect(find.text('01  /  05'), findsOneWidget);
      // Genres from TMDB ids, beside the year and type.
      expect(find.textContaining('Action  ·  Sci-Fi'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a click shows that title, and the previews move on', (
      tester,
    ) async {
      await _pumpHero(tester, _spotlight(5));
      await tester.tap(find.byTooltip('Show Title 2 with a fairly long name'));
      await tester.pumpAndSettle();
      expect(_heroTitle('Title 2 with a fairly long name'), findsOneWidget);
      expect(find.text('03  /  05'), findsOneWidget);
      // Wraps around the end.
      for (final i in [3, 4, 0]) {
        expect(
          find.byTooltip('Show Title $i with a fairly long name'),
          findsOne,
        );
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Enter on a focused preview shows its title', (tester) async {
      await _pumpHero(tester, _spotlight(4));
      final card = find.byTooltip('Show Title 1 with a fairly long name');
      Focus.of(
        tester.element(
          find
              .descendant(of: card, matching: find.byType(GestureDetector))
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
      await tester.tap(find.byTooltip('Show Title 1 with a fairly long name'));
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

    testWidgets('fewer titles, fewer previews', (tester) async {
      await _pumpHero(tester, _spotlight(2));
      expect(_previewCards(), findsOneWidget);
      await _pumpHero(tester, _spotlight(1));
      expect(_previewCards(), findsNothing);
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
        'at ${size.width.toInt()}×${size.height.toInt()} the previews stay '
        'clear of the title and actions',
        (tester) async {
          await _pumpHero(tester, _spotlight(5), size: size);
          final hero = tester.getRect(find.byType(DesktopHero));
          final guarded = [
            tester.getRect(_heroTitle('Title 0 with a fairly long name')),
            tester.getRect(find.text('More info')),
            tester.getRect(find.byTooltip('Add to My list')),
          ];
          final cards = _previewCards().evaluate().toList();
          if (size.width >= 1280) {
            expect(cards, isNotEmpty, reason: 'room for at least one preview');
          }
          for (final card in cards) {
            final rect = tester.getRect(find.byWidget(card.widget));
            expect(rect.right, lessThanOrEqualTo(hero.right));
            expect(rect.bottom, lessThanOrEqualTo(hero.bottom));
            for (final other in guarded) {
              expect(rect.overlaps(other), isFalse, reason: '$rect / $other');
            }
          }
          // Wide windows show all three.
          if (size.width >= 1920) expect(cards, hasLength(3));
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
}
