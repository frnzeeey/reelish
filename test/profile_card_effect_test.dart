import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/theme/profile_styles.dart';
import 'package:onfeed/src/widgets/profile_card_backdrop.dart';

/// A page with the card's effect at the top and room to scroll it away.
class _Page extends StatefulWidget {
  const _Page({required this.effect, required this.controller});

  final ProfileEffect effect;
  final ScrollController controller;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  int rebuilds = 0;

  void rebuild() => setState(() => rebuilds++);

  @override
  Widget build(BuildContext context) => ListView(
    controller: widget.controller,
    children: [
      SizedBox(
        height: 200,
        child: ProfileCardEffect(effect: widget.effect, color: Colors.orange),
      ),
      const SizedBox(height: 3000),
    ],
  );
}

Finder _painting() => find.descendant(
  of: find.byType(ProfileCardEffect),
  matching: find.byType(CustomPaint),
);

void main() {
  for (final effect in [ProfileEffect.sheen, ProfileEffect.drift]) {
    testWidgets('${effect.name} moves again after the card scrolls back', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _Page(effect: effect, controller: scroll),
          ),
        ),
      );
      expect(_painting(), findsOneWidget);

      // Away: the effect stops. Something on the page rebuilds meanwhile
      // (a count loading, the theme).
      scroll.jumpTo(400);
      await tester.pump();
      await tester.pump();
      tester.state<_PageState>(find.byType(_Page)).rebuild();
      await tester.pump();

      // Back: it must be painting with a running animation again.
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(_painting(), findsOneWidget);
      final painter =
          tester.widget<CustomPaint>(_painting()).painter! as dynamic;
      final Animation<double> time = painter.time as Animation<double>;
      final before = time.value;
      await tester.pump(const Duration(milliseconds: 700));
      expect(time.value, isNot(before), reason: 'the effect is frozen');
    });
  }
}
