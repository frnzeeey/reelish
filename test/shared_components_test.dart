import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/theme/design_tokens.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/theme/reelish_icons.dart';
import 'package:onfeed/src/widgets/count_badge.dart';
import 'package:onfeed/src/widgets/empty_state.dart';
import 'package:onfeed/src/widgets/notice_card.dart';

Widget _app(Widget child) => MaterialApp(
  theme: GlassTheme.dark,
  home: Scaffold(body: child),
);

void main() {
  group('NoticeCard', () {
    testWidgets('says what is missing and offers its action', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _app(
          NoticeCard(
            icon: ReelishIcons.link,
            title: 'Add a source',
            message: 'Titles play through plugins you choose.',
            action: TextButton(
              onPressed: () => tapped = true,
              child: const Text('Add'),
            ),
          ),
        ),
      );
      expect(find.text('Add a source'), findsOneWidget);
      expect(find.text('Titles play through plugins you choose.'), findsOne);
      await tester.tap(find.text('Add'));
      expect(tapped, isTrue);
    });

    testWidgets('is a solid surface on the page, not glass', (tester) async {
      await tester.pumpWidget(
        _app(
          const NoticeCard(
            icon: ReelishIcons.link,
            title: 'Nothing yet',
            message: 'Help',
          ),
        ),
      );
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(NoticeCard),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, GlassTheme.surface);
      expect(decoration.borderRadius, BorderRadius.circular(AppRadius.xl));
    });
  });

  group('EmptyState', () {
    testWidgets('an icon, a title and a message, centred', (tester) async {
      await tester.pumpWidget(
        _app(
          const EmptyState(
            icon: ReelishIcons.chat,
            title: 'Choose a conversation',
            message: 'It opens here.',
          ),
        ),
      );
      expect(find.byIcon(ReelishIcons.chat), findsOneWidget);
      expect(find.text('Choose a conversation'), findsOneWidget);
      expect(find.text('It opens here.'), findsOneWidget);
    });

    testWidgets('a picture of its own replaces the icon', (tester) async {
      await tester.pumpWidget(
        _app(
          const EmptyState(
            leading: SizedBox(key: ValueKey('avatar'), width: 72, height: 72),
            message: 'Say hello',
          ),
        ),
      );
      expect(find.byKey(const ValueKey('avatar')), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('CountBadge', () {
    Future<void> pump(
      WidgetTester tester,
      int count, {
      bool inverted = false,
    }) => tester.pumpWidget(
      _app(
        CountBadge(
          count: count,
          inverted: inverted,
          child: const Icon(ReelishIcons.people),
        ),
      ),
    );

    testWidgets('shows nothing at 0, the count, then 99+', (tester) async {
      await pump(tester, 0);
      expect(find.byType(Badge), findsNothing);
      await pump(tester, 7);
      expect(find.text('7'), findsOneWidget);
      await pump(tester, 140);
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('inverted, it reads on an accent fill', (tester) async {
      await pump(tester, 3, inverted: true);
      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.backgroundColor, GlassTheme.background);
      expect(badge.textColor, GlassTheme.primary);
    });
  });

  test('shadows by role', () {
    expect(AppShadow.raised.single.blurRadius, 14);
    expect(AppShadow.floating.single.blurRadius, 32);
    final glow = AppShadow.glow(const Color(0xFFBA725A)).single;
    expect(glow.color, const Color(0xFFBA725A).withValues(alpha: .42));
  });
}
