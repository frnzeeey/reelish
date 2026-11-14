import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/library_screen.dart';
import 'package:onfeed/src/screens/tv/tv_pages.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/media_card.dart';

/// Library pages as users see them, written against public
/// constructors only, so they describe the pages before and after their
/// state moved into shared ViewModels.

MediaItem _movie(String id) =>
    MediaItem(id: id, type: 'movie', name: 'Movie $id', year: '2020');

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

      testWidgets('what is left shows under the poster, clear of Remove', (
        tester,
      ) async {
        // The wide test font gives the label more than its room.
        await pumpPhone(tester);
        final button = tester.getRect(
          find.byTooltip('Remove from watch history').first,
        );
        // The card's own details line, not the section's subtitle.
        final label = tester.getRect(
          find
              .descendant(
                of: find.byType(MediaCard),
                matching: find.textContaining(
                  RegExp('left|Resume'),
                  findRichText: true,
                ),
              )
              .first,
        );
        // In the details line below the artwork, not over it.
        expect(label.top, greaterThan(button.bottom));
        expect(label.overlaps(button), isFalse);
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
