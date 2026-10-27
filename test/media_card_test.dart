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

  testWidgets('shows the type badge by default', (tester) async {
    await _pump(tester, MediaCard(item: series, onTap: () {}));
    expect(find.text('SERIES'), findsOneWidget);
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

  testWidgets('hides the type badge when a caller owns that corner', (
    tester,
  ) async {
    await _pump(
      tester,
      MediaCard(item: movie, onTap: () {}, showTypeBadge: false),
    );
    expect(find.text('FILM'), findsNothing);
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
