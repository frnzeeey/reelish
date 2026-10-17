import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/desktop/desktop_top_ten.dart';
import 'package:onfeed/src/desktop/desktop_widgets.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/paged_feed_controller.dart';
import 'package:onfeed/src/theme/glass_theme.dart';

MediaItem _item(int i, {String type = 'movie'}) =>
    MediaItem(id: '$i', type: type, name: 'Title $i', year: '2026');

/// The shared Top 10 feed as Home builds it (`targetCount: 10`), over a fake
/// fetcher that counts requests.
class _Feed {
  _Feed(this.pages);

  /// What each call returns, in order; the last one repeats.
  final List<FutureOr<List<MediaItem>> Function()> pages;
  int requests = 0;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.dispose();
  }

  late final controller = PagedFeedController(
    label: 'Top10',
    targetCount: 10,
    fetch: (page, {previous, required forceRefresh, onRevalidated}) async {
      final next = pages[requests.clamp(0, pages.length - 1)];
      requests++;
      final items = await next();
      return CatalogPage(items: items, page: page, totalPages: 1);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Feed feed, {
  ValueChanged<MediaItem>? onOpen,
  Size size = const Size(1600, 900),
  double pixelRatio = 1,
  bool loadWhenShown = true,
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  tester.view.physicalSize = size * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  addTearDown(feed.dispose);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: GlassTheme.tv,
      home: Scaffold(
        body: ListView(
          children: [
            DesktopTopTenRow(
              feed: feed.controller,
              onOpen: onOpen ?? (_) {},
              loadWhenShown: loadWhenShown,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The rank numerals on screen, left to right.
List<String> _numerals(WidgetTester tester) {
  final texts = find.byWidgetPredicate(
    (widget) => widget is Text && RegExp(r'^\d+$').hasMatch(widget.data ?? ''),
  );
  final found = texts.evaluate().toList()
    ..sort(
      (a, b) => tester
          .getTopLeft(find.byWidget(a.widget))
          .dx
          .compareTo(tester.getTopLeft(find.byWidget(b.widget)).dx),
    );
  return [for (final element in found) (element.widget as Text).data!];
}

Finder _card(int i) => find.ancestor(
  of: find.text('Title $i'),
  matching: find.byType(DesktopPosterCard),
);

FocusNode? _focusedCard() => FocusManager.instance.primaryFocus;

String? _focusedTitle(WidgetTester tester) {
  final context = _focusedCard()?.context;
  if (context == null) return null;
  final card = context.findAncestorWidgetOfExactType<DesktopPosterCard>();
  return card?.item.name;
}

void main() {
  group('visibleItems', () {
    test('keeps the ranked order, each title once, at most ten', () {
      final items = [
        for (var i = 1; i <= 7; i++) _item(i),
        _item(3), // a repeat
        _item(3, type: 'series'), // the same id, another type: not a repeat
        for (var i = 8; i <= 14; i++) _item(i),
      ];
      final visible = DesktopTopTenRow.visibleItems(items);
      expect(visible.map((i) => '${i.type}:${i.id}'), [
        for (var i = 1; i <= 7; i++) 'movie:$i',
        'series:3',
        'movie:8',
        'movie:9',
      ]);
    });
  });

  group('DesktopTopTenRow', () {
    testWidgets('shows ranks 1 to 10 in the feed order', (tester) async {
      final feed = _Feed([
        () => [for (var i = 1; i <= 14; i++) _item(i)],
      ]);
      await _pump(tester, feed, size: const Size(3840, 1000));
      expect(find.text('Top 10 recommendations'), findsOneWidget);
      expect(_numerals(tester), [for (var i = 1; i <= 10; i++) '$i']);
      for (var i = 1; i <= 10; i++) {
        expect(find.text('Title $i'), findsOneWidget);
        // Rank and poster belong together.
        expect(
          tester.getCenter(_card(i)).dx,
          greaterThan(tester.getCenter(find.text('$i')).dx),
        );
      }
      expect(find.text('Title 11'), findsNothing);
      expect(feed.requests, 1);
      expect(
        find.bySemanticsLabel(RegExp(r'^Number 1, Title 1, ')),
        findsOneWidget,
      );
    });

    testWidgets('fewer than ten results are shown as they are', (tester) async {
      final feed = _Feed([
        () => [_item(1), _item(2), _item(3)],
      ]);
      await _pump(tester, feed);
      expect(_numerals(tester), ['1', '2', '3']);
    });

    testWidgets('loads only once shown, and only once', (tester) async {
      final feed = _Feed([
        () => [_item(1)],
      ]);
      await _pump(tester, feed, loadWhenShown: false);
      expect(feed.requests, 0);
      // Home holds Top 10 back until the catalog has loaded; the row then
      // rebuilds with loadWhenShown and asks once.
      await _pump(tester, feed);
      await tester.pump();
      await _pump(tester, feed);
      expect(feed.requests, 1);
      expect(find.text('Title 1'), findsOneWidget);
    });

    testWidgets('loading, failure with retry, and nothing to show', (
      tester,
    ) async {
      final first = Completer<List<MediaItem>>();
      final feed = _Feed([
        () => first.future,
        () => [_item(1), _item(2)],
      ]);
      await _pump(tester, feed);
      // Placeholders keep the row's height while page 1 loads.
      expect(
        find.bySemanticsLabel(RegExp(r'^Loading Top 10 recommendations')),
        findsOneWidget,
      );

      first.completeError(Exception('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Could not load recommendations.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(_numerals(tester), ['1', '2']);

      final empty = _Feed([() => const <MediaItem>[]]);
      await _pump(tester, empty);
      expect(find.text('Top 10 recommendations'), findsNothing);
    });

    testWidgets('a click opens the title it shows', (tester) async {
      MediaItem? opened;
      final feed = _Feed([
        () => [_item(1), _item(2, type: 'series')],
      ]);
      await _pump(tester, feed, onOpen: (item) => opened = item);
      await tester.tap(find.text('Title 2'));
      expect((opened?.type, opened?.id), ('series', '2'));
    });

    testWidgets('arrow keys reach all ten, scrolling each fully into view; '
        'Enter and Space open the focused one', (tester) async {
      final opened = <String>[];
      final feed = _Feed([
        () => [for (var i = 1; i <= 10; i++) _item(i)],
      ]);
      await _pump(
        tester,
        feed,
        size: const Size(1100, 800),
        onOpen: (item) => opened.add(item.id),
      );
      final row = tester.getRect(find.byType(SingleChildScrollView));
      // Tab enters the row at rank 1.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_focusedTitle(tester), 'Title 1');

      for (var i = 2; i <= 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(_focusedTitle(tester), 'Title $i');
        // The whole ranked card, numeral included, is on screen.
        final numeral = tester.getRect(find.text('$i'));
        final poster = tester.getRect(_card(i));
        expect(numeral.left, greaterThanOrEqualTo(row.left - .5), reason: '$i');
        expect(poster.right, lessThanOrEqualTo(row.right + .5), reason: '$i');
      }
      // At the end, Right keeps focus on rank 10.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focusedTitle(tester), 'Title 10');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(_focusedTitle(tester), 'Title 9');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(opened, ['10', '9']);
    });

    testWidgets('focus returns to the same card after its details page', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final feed = _Feed([
        () => [for (var i = 1; i <= 10; i++) _item(i)],
      ]);
      await _pump(
        tester,
        feed,
        navigatorKey: navigator,
        onOpen: (item) => navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: Text('details ${item.id}')),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('details 4'), findsOneWidget);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_focusedTitle(tester), 'Title 4');
    });

    testWidgets('a refresh keeps focus on the same rank', (tester) async {
      var round = 0;
      final feed = _Feed([
        () => [for (var i = 1; i <= 10; i++) _item(i + 100 * round)],
      ]);
      await _pump(tester, feed);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_focusedTitle(tester), 'Title 2');

      round = 1;
      await feed.controller.refresh();
      await tester.pumpAndSettle();
      expect(_focusedTitle(tester), 'Title 102');
    });

    testWidgets('mouse: hover arrows page the row, and a drag scrolls it', (
      tester,
    ) async {
      final feed = _Feed([
        () => [for (var i = 1; i <= 10; i++) _item(i)],
      ]);
      await _pump(tester, feed, size: const Size(1100, 800));
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(_card(2)));
      addTearDown(mouse.removePointer);
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Scroll Top 10 recommendations forward'),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Scroll Top 10 recommendations back'),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Scroll Top 10 recommendations forward'));
      await tester.pumpAndSettle();
      final paged = scroll.offset;
      expect(paged, greaterThan(0));
      expect(
        find.byTooltip('Scroll Top 10 recommendations back'),
        findsOneWidget,
      );

      await tester.dragFrom(
        tester.getCenter(find.byType(SingleChildScrollView)),
        const Offset(300, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(paged));
    });

    for (final (size, ratio) in [
      (const Size(960, 600), 1.0),
      (const Size(1366, 768), 1.25),
      (const Size(1920, 1080), 1.0),
      (const Size(1280, 720), 1.5),
      (const Size(2560, 1440), 1.0),
      (const Size(1920, 1080), 2.0),
      (const Size(3840, 2160), 1.0),
    ]) {
      testWidgets('lays out without overflow at ${size.width.toInt()}x'
          '${size.height.toInt()} @${ratio}x', (tester) async {
        final feed = _Feed([
          () => [for (var i = 1; i <= 10; i++) _item(i)],
        ]);
        await _pump(tester, feed, size: size, pixelRatio: ratio);
        expect(tester.takeException(), isNull);
        final row = tester.getRect(find.byType(SingleChildScrollView));
        final poster = tester.getSize(_card(1));
        // Posters stay the size the other rows use: 150–230 px wide.
        expect(poster.width, inInclusiveRange(150, 230));
        // Numeral "1" sits fully inside the row, left of its poster.
        final numeral = tester.getRect(find.text('1'));
        expect(numeral.left, greaterThanOrEqualTo(row.left));
        expect(numeral.top, greaterThanOrEqualTo(row.top));
        expect(numeral.bottom, lessThanOrEqualTo(row.bottom));
        expect(
          tester.getRect(find.text('10', skipOffstage: false)).width,
          lessThanOrEqualTo(poster.width * .8),
        );
      });
    }
  });
}
