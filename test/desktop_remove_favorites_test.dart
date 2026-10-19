import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/desktop/desktop_widgets.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows Remove (from watch history) and My list on poster cards.
///
/// Run as Windows: a card's hover highlight follows Flutter's desktop
/// highlight mode, as in the app.
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

const _film = MediaItem(id: '1', type: 'movie', name: 'Film', year: '2024');
const _show = MediaItem(id: '2', type: 'series', name: 'Show', year: '2023');
const _saved = MediaItem(id: '3', type: 'movie', name: 'Saved', year: '2022');

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: GlassTheme.tv,
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

/// One mouse, as on a real PC: it hovers a card, then clicks its buttons.
class _Mouse {
  _Mouse(this.tester);

  final WidgetTester tester;
  TestGesture? _gesture;

  Future<void> hover(Finder finder) async {
    var gesture = _gesture;
    if (gesture == null) {
      gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      _gesture = gesture;
    }
    // As a viewer would, scroll the card into view first.
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await gesture.moveTo(tester.getCenter(finder));
    await tester.pumpAndSettle();
  }

  Future<void> click(Finder finder) async {
    final at = tester.getCenter(finder);
    final gesture = _gesture!;
    await gesture.moveTo(at);
    await gesture.down(at);
    await gesture.up();
    await tester.pump();
  }
}

Finder _card(String name) => find
    .ancestor(
      of: find.text(name, skipOffstage: false),
      matching: find.byType(DesktopPosterCard, skipOffstage: false),
    )
    .first;

/// StorageService's history and My list rules, in memory: a title is its
/// type and id, saving progress moves it to the front, toggling adds or
/// removes it.
class _MemoryStorage extends StorageService {
  final _historyItems = <MediaItem>[];
  final _favoriteItems = <MediaItem>[];

  static bool _same(MediaItem a, MediaItem b) =>
      a.id == b.id && a.type == b.type;

  @override
  Future<List<MediaItem>> history() async => [..._historyItems];

  @override
  Future<List<MediaItem>> favorites() async => [..._favoriteItems];

  @override
  Future<SeriesProgress> seriesProgress(MediaItem series) async =>
      SeriesProgress.empty;

  @override
  Future<void> saveProgress(
    MediaItem item,
    int positionMs, {
    int durationMs = 0,
  }) async {
    _historyItems
      ..removeWhere((e) => _same(e, item))
      ..insert(0, item.copyWith(resumeMs: positionMs, durationMs: durationMs));
  }

  @override
  Future<void> removeHistory(MediaItem item) async =>
      _historyItems.removeWhere((e) => _same(e, item));

  @override
  Future<void> toggleFavorite(MediaItem item) async {
    if (_favoriteItems.any((e) => _same(e, item))) {
      _favoriteItems.removeWhere((e) => _same(e, item));
    } else {
      _favoriteItems.insert(0, item);
    }
  }
}

List<String> _names(List<MediaItem> items) => [for (final i in items) i.name];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('poster card actions', () {
    testWidgets('no buttons where a page offers no action', (tester) async {
      await _pump(
        tester,
        DesktopPosterCard(item: _film, width: 200, onOpen: (_) {}),
      );
      await _Mouse(tester).hover(find.byType(DesktopPosterCard));
      expect(find.byTooltip('Add to My list (F)'), findsNothing);
      expect(
        find.byTooltip('Remove from watch history (Delete)'),
        findsNothing,
      );
    }, variant: _windows);

    testWidgets('buttons appear on hover; each press acts once', (
      tester,
    ) async {
      final pending = Completer<void>();
      var toggles = 0;
      var removes = 0;
      var opened = 0;
      await _pump(
        tester,
        DesktopPosterCard(
          item: _film,
          width: 200,
          onOpen: (_) => opened++,
          onToggleFavorite: () {
            toggles++;
            return pending.future;
          },
          onRemove: () async => removes++,
        ),
      );
      final heart = find.byTooltip('Add to My list (F)');
      final remove = find.byTooltip('Remove from watch history (Delete)');
      IgnorePointer gate() => tester.widget<IgnorePointer>(
        find.ancestor(of: heart, matching: find.byType(IgnorePointer)).first,
      );
      // Hidden, and not clickable, until the card is hovered or focused.
      expect(gate().ignoring, isTrue);

      final mouse = _Mouse(tester);
      await mouse.hover(find.byType(DesktopPosterCard));
      expect(gate().ignoring, isFalse);
      await mouse.click(heart);
      // While it saves, more presses (mouse or keyboard) are ignored.
      await mouse.click(heart);
      await mouse.click(remove);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      expect((toggles, removes), (1, 0));

      pending.complete();
      await tester.pumpAndSettle();
      await mouse.click(remove);
      await tester.pumpAndSettle();
      expect((toggles, removes), (1, 1));
      // The buttons never opened the title; the poster still does.
      expect(opened, 0);
      await mouse.click(find.text('Film'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    }, variant: _windows);

    testWidgets('F and Delete work on the focused card', (tester) async {
      var toggles = 0;
      var removes = 0;
      await _pump(
        tester,
        DesktopPosterCard(
          item: _film,
          width: 200,
          onOpen: (_) {},
          isFavorite: true,
          onToggleFavorite: () async => toggles++,
          onRemove: () async => removes++,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      // Focused: the buttons show, and the heart says what F will do.
      expect(find.byTooltip('Remove from My list (F)'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect((toggles, removes), (1, 1));
    }, variant: _windows);

    testWidgets('a failure says so, and the card stays usable', (tester) async {
      var attempts = 0;
      await _pump(
        tester,
        DesktopPosterCard(
          item: _film,
          width: 200,
          onOpen: (_) {},
          onToggleFavorite: () async {
            attempts++;
            throw Exception('disk full');
          },
        ),
      );
      final mouse = _Mouse(tester);
      await mouse.hover(find.byType(DesktopPosterCard));
      await mouse.click(find.byTooltip('Add to My list (F)'));
      await tester.pump();
      expect(find.text('Could not update My list. Try again.'), findsOneWidget);
      await mouse.click(find.byTooltip('Add to My list (F)'));
      await tester.pump();
      expect(attempts, 2);
    }, variant: _windows);
  });

  group('Windows library', () {
    late _MemoryStorage storage;
    late int historyChanged;

    Future<void> pumpLibrary(WidgetTester tester) async {
      storage = _MemoryStorage();
      historyChanged = 0;
      await storage.saveProgress(_show, 0);
      await storage.saveProgress(_film, 60000, durationMs: 120000);
      await storage.toggleFavorite(_saved);
      await _pump(
        tester,
        DesktopLibraryPage(
          storage: storage,
          onOpen: (_) {},
          refreshToken: 0,
          // Home's toggle: saves through the same storage.
          onToggleFavorite: (item) async {
            await storage.toggleFavorite(item);
            return (await storage.favorites()).any((i) => i.id == item.id);
          },
          onHistoryChanged: () => historyChanged++,
        ),
      );
    }

    /// The titles the library row [row] shows, or null when it is not shown.
    List<String>? rowTitles(WidgetTester tester, String row) {
      for (final widget in tester.widgetList<DesktopMediaRow>(
        find.byType(DesktopMediaRow, skipOffstage: false),
      )) {
        if (widget.title == row) return _names(widget.items);
      }
      return null;
    }

    testWidgets('Remove takes a title out of the watch history only', (
      tester,
    ) async {
      await pumpLibrary(tester);
      expect(rowTitles(tester, 'Continue watching'), ['Film']);
      expect(rowTitles(tester, 'Watch history'), ['Film', 'Show']);

      final mouse = _Mouse(tester);
      await mouse.hover(_card('Film'));
      await mouse.click(_action('Film', 'Remove from watch history (Delete)'));
      await tester.pumpAndSettle();

      // Gone from both rows at once; Home is told so its row follows.
      expect(find.text('Film', skipOffstage: false), findsNothing);
      expect(find.text('Continue watching'), findsNothing);
      expect(rowTitles(tester, 'Watch history'), ['Show']);
      expect(rowTitles(tester, 'Continue watching'), isNull);
      expect(historyChanged, 1);
      expect(_names(await storage.history()), ['Show']);
      // My list is untouched.
      expect(_names(await storage.favorites()), ['Saved']);
    }, variant: _windows);

    testWidgets('My list changes show at once', (tester) async {
      await pumpLibrary(tester);
      final mouse = _Mouse(tester);

      // Add Show from the watch history.
      await mouse.hover(_card('Show'));
      await mouse.click(_action('Show', 'Add to My list (F)'));
      await tester.pumpAndSettle();
      expect(rowTitles(tester, 'My list'), ['Show', 'Saved']);

      // Take Saved off My list from its card there.
      await mouse.hover(_card('Saved'));
      await mouse.click(_action('Saved', 'Remove from My list (F)'));
      await tester.pumpAndSettle();
      expect(find.text('Saved', skipOffstage: false), findsNothing);
      expect(_names(await storage.favorites()), ['Show']);
      // History is untouched.
      expect(_names(await storage.history()), ['Film', 'Show']);
      expect(historyChanged, 0);
    }, variant: _windows);
  });

  test(
    'the real storage keeps the changes across a restart, once each',
    () async {
      final storage = StorageService();
      await storage.saveProgress(_show, 0);
      await storage.saveProgress(_film, 60000, durationMs: 120000);
      await storage.toggleFavorite(_saved);
      await storage.toggleFavorite(_show);
      await storage.removeHistory(_film);
      await storage.toggleFavorite(_saved);

      final restarted = StorageService();
      expect(_names(await restarted.favorites()), ['Show']);
      expect(_names(await restarted.history()), ['Show']);
      // An odd number of toggles leaves the title on the list once.
      await restarted.toggleFavorite(_film);
      await restarted.toggleFavorite(_film);
      await restarted.toggleFavorite(_film);
      expect(_names(await StorageService().favorites()), ['Film', 'Show']);
    },
  );
}

/// The [tooltip] button on the card titled [name] (the first such card).
Finder _action(String name, String tooltip) =>
    find.descendant(of: _card(name), matching: find.byTooltip(tooltip));
