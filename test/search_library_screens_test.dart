import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/library_screen.dart';
import 'package:onfeed/src/screens/tv/tv_pages.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/media_card.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';

/// Search and library pages as users see them, written against public
/// constructors only, so they describe the pages before and after their
/// state moved into shared ViewModels.

MediaItem _movie(String id) =>
    MediaItem(id: id, type: 'movie', name: 'Movie $id', year: '2020');

class _FakeTmdb extends TmdbService {
  final requests = <String>[];

  /// Gates an answer until the test completes it.
  final gates = <String, Completer<void>>{};
  final failing = <String>{};

  @override
  Future<List<MediaItem>> search(
    String query, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    int page = 1,
  }) async {
    requests.add('$query#$page');
    await gates['$query#$page']?.future;
    if (failing.contains(query)) throw Exception('offline');
    return [for (var i = 0; i < 20; i++) _movie('$query-$page-$i')];
  }
}

class _FakeStorage extends StorageService {
  int reads = 0;

  @override
  Future<List<MediaItem>> history() async {
    reads++;
    return [_movie('watched')];
  }

  @override
  Future<List<MediaItem>> favorites() async => [_movie('saved')];

  @override
  Future<SeriesProgress> seriesProgress(MediaItem series) async =>
      throw UnimplementedError();
}

/// History and My list that removals and toggles really change, or that
/// fail to save when [failing].
class _ChangingStorage extends StorageService {
  _ChangingStorage({this.failing = false});

  final bool failing;
  final history_ = [
    const MediaItem(
      id: 'watched',
      type: 'movie',
      name: 'Movie watched',
      year: '2020',
      resumeMs: 60000,
      durationMs: 600000,
    ),
  ];
  final favorites_ = [_movie('saved')];

  @override
  Future<List<MediaItem>> history() async => [...history_];

  @override
  Future<List<MediaItem>> favorites() async => [...favorites_];

  @override
  Future<SeriesProgress> seriesProgress(MediaItem series) async =>
      SeriesProgress.empty;

  @override
  Future<void> removeHistory(MediaItem item) async {
    if (failing) throw const FileSystemException('disk full');
    history_.removeWhere((i) => i.id == item.id && i.type == item.type);
  }

  @override
  Future<void> toggleFavorite(MediaItem item) async {
    if (failing) throw const FileSystemException('disk full');
    if (!favorites_.any((i) => i.id == item.id)) {
      favorites_.add(item);
    } else {
      favorites_.removeWhere((i) => i.id == item.id);
    }
  }
}

Future<void> _pump(WidgetTester tester, Widget page, {bool tv = false}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: tv ? GlassTheme.tv : GlassTheme.dark,
      home: Scaffold(body: page),
    ),
  );
  await tester.pump();
}

void main() {
  late _FakeTmdb tmdb;
  setUp(() => tmdb = _FakeTmdb());

  // Each layout types through its own field.
  final layouts = <String, (Widget Function(TmdbService), Duration, bool)>{
    'TV': (
      (tmdb) =>
          TvSearchPage(tmdb: tmdb, onOpen: (_) {}, isFavorite: (_) => false),
      const Duration(milliseconds: 450),
      true,
    ),
    'Windows': (
      (tmdb) => DesktopSearchPage(
        tmdb: tmdb,
        onOpen: (_) {},
        isFavorite: (_) => false,
      ),
      const Duration(milliseconds: 400),
      false,
    ),
  };

  for (final MapEntry(key: name, value: (build, debounce, tv))
      in layouts.entries) {
    Future<void> type(WidgetTester tester, String text) async {
      if (tv) {
        tester.widget<TvTextField>(find.byType(TvTextField)).onChanged(text);
      } else {
        await tester.enterText(find.byType(TextField), text);
      }
      await tester.pump();
    }

    group('$name search', () {
      testWidgets('waits ${debounce.inMilliseconds} ms after typing stops', (
        tester,
      ) async {
        await _pump(tester, build(tmdb), tv: tv);
        await type(tester, 'du');
        await tester.pump(debounce - const Duration(milliseconds: 50));
        await type(tester, 'dune ');
        await tester.pump(debounce - const Duration(milliseconds: 1));
        expect(tmdb.requests, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pumpAndSettle();
        // Only the last text, trimmed.
        expect(tmdb.requests, ['dune#1']);
        expect(find.text('Movie dune-1-0'), findsWidgets);
      });

      testWidgets('an older answer never replaces a newer one', (tester) async {
        tmdb.gates['slow#1'] = Completer();
        await _pump(tester, build(tmdb), tv: tv);
        await type(tester, 'slow');
        await tester.pump(debounce);
        await type(tester, 'fast');
        await tester.pump(debounce);
        await tester.pumpAndSettle();
        tmdb.gates['slow#1']!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Movie fast-1-0'), findsWidgets);
        expect(find.text('Movie slow-1-0'), findsNothing);
      });

      testWidgets('a failure says so and offers Retry', (tester) async {
        tmdb.failing.add('down');
        await _pump(tester, build(tmdb), tv: tv);
        await type(tester, 'down');
        await tester.pump(debounce);
        await tester.pumpAndSettle();
        expect(
          find.text('Search failed. Check your connection and try again.'),
          findsOneWidget,
        );
        tmdb.failing.clear();
        await tester.tap(find.text(tv ? 'Retry' : 'Try again'));
        await tester.pumpAndSettle();
        expect(find.text('Movie down-1-0'), findsWidgets);
      });
    });
  }

  testWidgets('Windows search loads each next page near the end, once', (
    tester,
  ) async {
    await _pump(tester, layouts['Windows']!.$1(tmdb));
    await tester.enterText(find.byType(TextField), 'many');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    // Pages in order, each requested once.
    expect(tmdb.requests.take(2), ['many#1', 'many#2']);
    expect(tmdb.requests.toSet(), hasLength(tmdb.requests.length));
    expect(tmdb.requests, [
      for (var i = 1; i <= tmdb.requests.length; i++) 'many#$i',
    ]);
  });

  group('library pages', () {
    final pages = <String, (Widget Function(StorageService, int), bool)>{
      'phone': (
        (storage, token) => LibraryScreen(
          storage: storage,
          onPlay: (_) {},
          refreshToken: token,
        ),
        false,
      ),
      'TV': (
        (storage, token) => TvLibraryPage(
          storage: storage,
          onOpen: (_) {},
          refreshToken: token,
        ),
        true,
      ),
      'Windows': (
        (storage, token) => DesktopLibraryPage(
          storage: storage,
          onOpen: (_) {},
          refreshToken: token,
        ),
        false,
      ),
    };
    group('the phone library tells Home only about saved changes', () {
      Future<(_ChangingStorage, List<String>)> pumpPhone(
        WidgetTester tester, {
        bool failing = false,
      }) async {
        final storage = _ChangingStorage(failing: failing);
        final told = <String>[];
        await _pump(
          tester,
          LibraryScreen(
            storage: storage,
            onPlay: (_) {},
            onHistoryChanged: () => told.add('history'),
            onFavoritesChanged: () => told.add('favorites'),
          ),
        );
        await tester.pumpAndSettle();
        return (storage, told);
      }

      Future<void> press(WidgetTester tester, String tooltip) =>
          tester.tap(find.byTooltip(tooltip).first);

      testWidgets('the resume badge stays clear of the Remove button', (
        tester,
      ) async {
        // The wide test font gives the badge's label more than its room.
        await pumpPhone(tester);
        final button = tester.getRect(
          find.byTooltip('Remove from watch history').first,
        );
        final badge = tester.getRect(
          find
              .ancestor(
                of: find.byWidgetPredicate(
                  (w) => w is Icon && w.icon == Symbols.play_arrow_rounded,
                ),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(badge.right, lessThanOrEqualTo(button.left));
        expect(badge.overlaps(button), isFalse);
      });

      testWidgets('a removal is passed on once saved', (tester) async {
        final (storage, told) = await pumpPhone(tester);
        await press(tester, 'Remove from watch history');
        await tester.pumpAndSettle();
        expect(storage.history_, isEmpty);
        expect(told, ['history']);
      });

      testWidgets('a My list change is passed on once saved', (tester) async {
        final (storage, told) = await pumpPhone(tester);
        // The heart on the saved title's card (the header's "saved" count
        // has the same icon).
        tester
            .widget<MediaCard>(
              find.byWidgetPredicate(
                (w) =>
                    w is MediaCard &&
                    w.item.name == 'Movie saved' &&
                    w.onFavorite != null,
              ),
            )
            .onFavorite!();
        await tester.pumpAndSettle();
        expect(storage.favorites_, isEmpty);
        expect(told, ['favorites']);
      });

      testWidgets('a failed removal says so and changes nothing', (
        tester,
      ) async {
        final (storage, told) = await pumpPhone(tester, failing: true);
        await press(tester, 'Remove from watch history');
        await tester.pumpAndSettle();
        expect(told, isEmpty);
        expect(find.text('Could not remove it. Try again.'), findsOneWidget);
        expect(find.text('Movie watched', skipOffstage: false), findsWidgets);
        expect(storage.history_, isNotEmpty);
      });
    });

    for (final MapEntry(key: name, value: (build, tv)) in pages.entries) {
      testWidgets('$name shows history and My list, and reloads on refresh', (
        tester,
      ) async {
        final storage = _FakeStorage();
        await _pump(tester, build(storage, 0), tv: tv);
        await tester.pumpAndSettle();
        expect(find.text('Movie watched', skipOffstage: false), findsWidgets);
        expect(find.text('Movie saved', skipOffstage: false), findsWidgets);
        expect(storage.reads, 1);
        await _pump(tester, build(storage, 1), tv: tv);
        await tester.pumpAndSettle();
        expect(storage.reads, 2);
      });
    }
  });
}
