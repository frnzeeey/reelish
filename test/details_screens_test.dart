import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/desktop/desktop_details_screen.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/media_details_screen.dart';
import 'package:onfeed/src/screens/tv/tv_details_screen.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';

/// Behaviour of the three details screens (phone, TV, Windows) as users see
/// it. Written against the screens' public constructors only, so the same
/// tests describe them before and after their state moved into a shared
/// ViewModel.

const _series = MediaItem(id: '7', type: 'series', name: 'Show', year: '2020');
const _movie = MediaItem(id: '8', type: 'movie', name: 'Film', year: '2021');

class _FakeTmdb extends TmdbService {
  bool failDetails = false;
  final failSeasons = <int>{};
  final calls = <String>[];

  @override
  Future<MediaDetails> details(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(MediaDetails)? onRevalidated,
  }) async {
    calls.add('details');
    if (failDetails) throw Exception('down');
    return const MediaDetails(overview: 'A plot.', genres: ['Drama']);
  }

  @override
  Future<List<Map<String, dynamic>>> seasons(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    calls.add('seasons');
    return [
      {'season_number': 1, 'name': 'Season One'},
      {'season_number': 2, 'name': 'Season Two'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> episodes(
    MediaItem item,
    int season, {
    bool forceRefresh = false,
  }) async {
    calls.add('episodes $season');
    if (failSeasons.contains(season)) throw Exception('down');
    return season == 1
        ? [
            {'episode_number': 2, 'name': 'Second', 'air_date': '2020-01-08'},
            {'episode_number': 1, 'name': 'First', 'air_date': '2020-01-01'},
          ]
        : [
            {'episode_number': 1, 'name': 'Later', 'air_date': '2021-01-01'},
          ];
  }

  @override
  Future<List<MediaItem>> recommendations(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
  }) async {
    calls.add('related');
    return const [MediaItem(id: '9', type: 'movie', name: 'Related film')];
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  bool tv = false,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: tv ? GlassTheme.tv : GlassTheme.dark, home: screen),
  );
  await tester.pumpAndSettle();
}

double _y(WidgetTester tester, String text) =>
    tester.getTopLeft(find.textContaining(text, skipOffstage: false).first).dy;

double _x(WidgetTester tester, String text) =>
    tester.getTopLeft(find.textContaining(text, skipOffstage: false).first).dx;

void main() {
  late _FakeTmdb tmdb;
  late List<(int, int)> played;
  setUp(() {
    tmdb = _FakeTmdb();
    played = [];
  });

  group('phone and tablet', () {
    Widget screen(MediaItem item) => MediaDetailsScreen(
      item: item,
      tmdb: tmdb,
      onPlay: (_) {},
      onPlayEpisode: (_, season, episode) => played.add((season, episode)),
    );

    testWidgets('lists season 1 in order and plays the tapped episode', (
      tester,
    ) async {
      await _pump(tester, screen(_series));
      expect(find.text('A plot.'), findsOneWidget);
      expect(_y(tester, 'First'), lessThan(_y(tester, 'Second')));
      await tester.ensureVisible(find.textContaining('Second'));
      await tester.tap(find.textContaining('Second'));
      expect(played, [(1, 2)]);
      expect(tmdb.calls, ['details', 'seasons', 'episodes 1']);
    });

    testWidgets('switches season from the menu', (tester) async {
      await _pump(tester, screen(_series));
      await tester.ensureVisible(find.text('Season 1'));
      await tester.tap(find.text('Season 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Season 2').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Later'), findsOneWidget);
      expect(find.textContaining('First'), findsNothing);
      expect(tmdb.calls.last, 'episodes 2');
    });

    testWidgets('reports failures in its own words, and retries', (
      tester,
    ) async {
      tmdb
        ..failDetails = true
        ..failSeasons.add(1);
      await _pump(tester, screen(_series));
      expect(
        find.text('Could not load extra details. Try again.'),
        findsOneWidget,
      );
      expect(
        find.text('Could not load this season. Try again.'),
        findsOneWidget,
      );
      tmdb
        ..failDetails = false
        ..failSeasons.clear();
      for (final retry in find.text('Retry').evaluate().toList().reversed) {
        await tester.ensureVisible(find.byWidget(retry.widget));
        await tester.tap(find.byWidget(retry.widget));
        await tester.pumpAndSettle();
      }
      expect(find.text('A plot.'), findsOneWidget);
      expect(find.textContaining('First'), findsOneWidget);
    });

    testWidgets('a movie asks for no seasons', (tester) async {
      await _pump(tester, screen(_movie));
      expect(tmdb.calls, ['details']);
    });

    testWidgets('no My list button where the page offers none', (
      tester,
    ) async {
      await _pump(tester, screen(_movie));
      expect(find.text('My list'), findsNothing);
      expect(find.text('In My list'), findsNothing);
    });

    testWidgets('My list saves once per tap and says it is saved', (
      tester,
    ) async {
      var saved = false;
      var toggles = 0;
      var pending = Completer<void>();
      await _pump(
        tester,
        MediaDetailsScreen(
          item: _movie,
          tmdb: tmdb,
          onPlay: (_) {},
          onPlayEpisode: (_, _, _) {},
          onToggleFavorite: () async {
            toggles++;
            await pending.future;
            return saved = !saved;
          },
        ),
      );
      await tester.tap(find.text('My list'));
      await tester.pump();
      // A second tap while it saves is ignored.
      await tester.tap(find.text('My list'));
      pending.complete();
      await tester.pumpAndSettle();
      expect(toggles, 1);
      expect(find.text('In My list'), findsOneWidget);

      pending = Completer<void>()..complete();
      await tester.tap(find.text('In My list'));
      await tester.pumpAndSettle();
      expect((toggles, saved), (2, false));
      expect(find.text('My list'), findsOneWidget);
    });

    testWidgets('a title already saved opens as In My list', (tester) async {
      await _pump(
        tester,
        MediaDetailsScreen(
          item: _movie,
          tmdb: tmdb,
          onPlay: (_) {},
          onPlayEpisode: (_, _, _) {},
          isFavorite: true,
          onToggleFavorite: () async => false,
        ),
      );
      expect(find.text('In My list'), findsOneWidget);
    });

    testWidgets('a failed save says so and changes nothing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: MediaDetailsScreen(
            item: _movie,
            tmdb: tmdb,
            onPlay: (_) {},
            onPlayEpisode: (_, _, _) {},
            onToggleFavorite: () async => throw Exception('disk full'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('My list'));
      await tester.pump();
      expect(find.text('Could not update My list. Try again.'), findsOneWidget);
      expect(find.text('My list'), findsOneWidget);
    });

    testWidgets('Back stays on screen while the page scrolls', (tester) async {
      tester.view.physicalSize = const Size(400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => screen(_series))),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      // Scroll to the end, well past the header.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pumpAndSettle();
      final scrolled = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      // The 440-pixel header, where Back used to sit, is off screen.
      expect(scrolled, greaterThan(440));

      await tester.tap(find.byTooltip('Back').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(find.byType(MediaDetailsScreen), findsNothing);
    });
  });

  group('Android TV', () {
    Widget screen(MediaItem item) => TvMediaDetailsScreen(
      item: item,
      tmdb: tmdb,
      onPlay: (_) {},
      onPlayEpisode: (_, season, episode) => played.add((season, episode)),
    );

    testWidgets('lists season 1 in order and plays the selected episode', (
      tester,
    ) async {
      await _pump(tester, screen(_series), tv: true);
      expect(find.text('A plot.'), findsOneWidget);
      expect(_x(tester, 'First'), lessThan(_x(tester, 'Second')));
      // What the remote's select does on that episode card.
      tester
          .widget<TvFocusable>(
            find.descendant(
              of: find.ancestor(
                of: find.textContaining('Second', skipOffstage: false),
                matching: find.byWidgetPredicate(
                  (widget) => widget.runtimeType.toString() == '_EpisodeCard',
                  skipOffstage: false,
                ),
              ),
              matching: find.byType(TvFocusable, skipOffstage: false),
            ),
          )
          .onSelect!();
      expect(played, [(1, 2)]);
      expect(tmdb.calls, ['details', 'seasons', 'episodes 1']);
    });

    testWidgets('switches season', (tester) async {
      await _pump(tester, screen(_series), tv: true);
      await tester.ensureVisible(find.text('Season 2'));
      await tester.tap(find.text('Season 2'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Later'), findsOneWidget);
      expect(tmdb.calls.last, 'episodes 2');
    });

    testWidgets('reports failures in its own words', (tester) async {
      tmdb
        ..failDetails = true
        ..failSeasons.add(1);
      await _pump(tester, screen(_series), tv: true);
      expect(find.text('Could not load extra details. Retry'), findsOneWidget);
      expect(find.text('Could not load this season.'), findsOneWidget);
    });
  });

  group('Windows', () {
    Widget screen(MediaItem item) => DesktopDetailsScreen(
      item: item,
      tmdb: tmdb,
      onPlay: (_, _) {},
      onPlayEpisode: (_, _, season, episode) => played.add((season, episode)),
      isFavorite: (_) => false,
      onToggleFavorite: (_) async => true,
    );

    testWidgets('shows related titles and plays the first aired episode', (
      tester,
    ) async {
      await _pump(tester, screen(_series));
      expect(find.text('A plot.'), findsOneWidget);
      expect(find.text('Related film', skipOffstage: false), findsOneWidget);
      expect(tmdb.calls, ['details', 'related', 'seasons', 'episodes 1']);
      // Play starts the first aired episode of the selected season.
      await tester.tap(find.textContaining('Play').first);
      expect(played, [(1, 1)]);
    });

    testWidgets('labels seasons by name and switches between them', (
      tester,
    ) async {
      await _pump(tester, screen(_series));
      await tester.ensureVisible(find.text('Season Two'));
      await tester.tap(find.text('Season Two'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Later', skipOffstage: false), findsOneWidget);
      expect(tmdb.calls.last, 'episodes 2');
    });

    testWidgets('a season that fails keeps the episodes already shown', (
      tester,
    ) async {
      tmdb.failSeasons.add(2);
      await _pump(tester, screen(_series));
      await tester.ensureVisible(find.text('Season Two'));
      await tester.tap(find.text('Season Two'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load this season.', skipOffstage: false),
        findsOneWidget,
      );
      expect(tmdb.calls.last, 'episodes 2');
    });
  });
}
