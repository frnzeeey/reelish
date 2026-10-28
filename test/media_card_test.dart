import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/widgets/media_card.dart';
import 'package:onfeed/src/widgets/poster_image.dart';

Future<void> _pump(WidgetTester tester, Widget card) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: card)),
  ),
);

void main() {
  const movie = MediaItem(id: '1', type: 'movie', name: 'Film');
  const series = MediaItem(id: '2', type: 'series', name: 'Show');

  testWidgets('the details line names the kind by default', (tester) async {
    await _pump(tester, MediaCard(item: series, onTap: () {}));
    expect(find.textContaining('Series', findRichText: true), findsOneWidget);
  });

  testWidgets('the artwork keeps the poster shape, with the caption below', (
    tester,
  ) async {
    for (final width in const [MediaCard.defaultWidth, 182.0]) {
      await _pump(tester, MediaCard(item: movie, onTap: () {}, width: width));
      final art = tester.getSize(find.byType(PosterPlaceholder));
      // 2:3, never cropped by the caption or stretched by the card.
      expect(art.width, width);
      expect(art.height, closeTo(width * 1.5, .5));
      final card = tester.getRect(find.byType(MediaCard));
      final title = tester.getRect(find.text('Film'));
      expect(title.top, greaterThan(card.top + art.height));
      expect(title.bottom, lessThanOrEqualTo(card.bottom));
    }
  });

  testWidgets('a screen reader hears the title and details once', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      MediaCard(
        item: const MediaItem(
          id: '3',
          type: 'series',
          name: 'Oxygen',
          year: '2021',
          rating: '7.6',
        ),
        onTap: () {},
      ),
    );
    expect(
      find.bySemanticsLabel('Oxygen, 2021, Series, rated 7.6'),
      findsOneWidget,
    );
    // The caption is not read again after the card's label.
    expect(find.bySemanticsLabel('Oxygen'), findsNothing);
    semantics.dispose();
  });

  testWidgets('missing details leave no stray separators', (tester) async {
    await _pump(
      tester,
      MediaCard(
        item: const MediaItem(id: '4', type: 'movie', name: 'Quiet'),
        onTap: () {},
      ),
    );
    final details = tester
        .widget<RichText>(find.textContaining('Movie', findRichText: true))
        .text
        .toPlainText();
    expect(details.trim(), 'Movie');
  });

  testWidgets('the loading skeleton is exactly a card\'s size', (tester) async {
    await _pump(tester, const MediaCardSkeleton());
    final skeleton = tester.getSize(find.byType(MediaCardSkeleton));
    await _pump(tester, MediaCard(item: movie, onTap: () {}));
    expect(tester.getSize(find.byType(MediaCard)), skeleton);
  });

  testWidgets('the My list heart is named, toggled and at least 47 dp', (
    tester,
  ) async {
    var toggles = 0;
    await _pump(
      tester,
      MediaCard(item: movie, onTap: () {}, onFavorite: () => toggles++),
    );
    final add = find.byTooltip('Add to My list');
    expect(add, findsOneWidget);
    final size = tester.getSize(
      find.ancestor(of: add, matching: find.byType(IconButton)),
    );
    expect(size.width, greaterThanOrEqualTo(47));
    expect(size.height, greaterThanOrEqualTo(47));

    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 500));
    expect(toggles, 1);
    expect(find.byTooltip('Remove from My list'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).isSelected,
      isTrue,
    );
  });

  testWidgets('leaves the kind out when a caller says it elsewhere', (
    tester,
  ) async {
    await _pump(
      tester,
      MediaCard(item: movie, onTap: () {}, showTypeBadge: false),
    );
    expect(find.textContaining('Movie', findRichText: true), findsNothing);
    expect(find.text('Film'), findsOneWidget);
  });

  testWidgets('a card without a poster shows the placeholder', (tester) async {
    await _pump(tester, MediaCard(item: movie, onTap: () {}));
    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(find.byIcon(Symbols.movie_rounded), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('the placeholder stays behind a poster while it loads', (
    tester,
  ) async {
    await _pump(
      tester,
      MediaCard(
        item: const MediaItem(
          id: '1',
          type: 'movie',
          name: 'Film',
          poster: 'https://image.tmdb.org/t/p/w342/a.jpg',
        ),
        onTap: () {},
      ),
    );
    // Test HTTP never delivers a frame, so the image stays transparent and
    // the placeholder is what is visible.
    expect(find.byType(PosterPlaceholder), findsOneWidget);
    final fade = tester.widget<AnimatedOpacity>(
      find.descendant(
        of: find.byType(Image),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(fade.opacity, 0);
  });
}
