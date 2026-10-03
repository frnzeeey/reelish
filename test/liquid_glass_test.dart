import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/widgets/liquid_glass.dart';

void main() {
  testWidgets('low quality glass does not add a backdrop filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LiquidGlass(
          quality: LiquidGlassQuality.low,
          child: Text('glass content'),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('glass content'), findsOneWidget);
  });

  testWidgets('balanced glass adds a clipped backdrop filter', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LiquidGlass(
          quality: LiquidGlassQuality.balanced,
          blurSigma: 9,
          child: Text('glass content'),
        ),
      ),
    );

    expect(find.byType(ClipRRect), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('glass content'), findsOneWidget);
  });
}
