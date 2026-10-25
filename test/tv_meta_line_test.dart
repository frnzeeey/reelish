import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:onfeed/src/screens/tv/tv_browse.dart';
import 'package:onfeed/src/theme/glass_theme.dart';

void main() {
  testWidgets('a rating shows the theme star icon, not a "★" character, and '
      'the parts keep their order', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.tv,
        home: const Scaffold(
          body: TvMetaLine(
            parts: ['2026', 'Movie', TvRating('8.0')],
            style: TextStyle(fontSize: 15),
          ),
        ),
      ),
    );
    final text = tester.widget<RichText>(find.byType(RichText).first).text;
    expect(text.toPlainText(), contains('2026   ·   Movie   ·   '));
    expect(text.toPlainText(), endsWith('8.0'));
    expect(text.toPlainText(), isNot(contains('★')));
    final star = tester.widget<Icon>(find.byIcon(Symbols.star_rounded));
    expect(star.color, GlassTheme.primary);
  });

  testWidgets('without a rating there is no star', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TvMetaLine(
            parts: ['2026', 'Series'],
            style: TextStyle(fontSize: 15),
          ),
        ),
      ),
    );
    expect(find.byIcon(Symbols.star_rounded), findsNothing);
    expect(find.textContaining('2026   ·   Series'), findsOneWidget);
  });
}
