import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/widgets/liquid_glass.dart';

void main() {
  glassMaterialTests();

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

void glassMaterialTests() {
  testWidgets('glass paints directional edges with no coral by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LiquidGlass(
          quality: LiquidGlassQuality.low,
          child: SizedBox(width: 120, height: 60),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is LiquidGlassBodyPainter,
      ),
    );
    expect(paint.foregroundPainter, isA<LiquidGlassEdgePainter>());
    expect((paint.painter! as LiquidGlassBodyPainter).accentStrength, 0);
    expect(
      (paint.foregroundPainter! as LiquidGlassEdgePainter).accentStrength,
      0,
    );
  });

  testWidgets('quality ceiling drops every backdrop blur', (tester) async {
    LiquidGlass.qualityCeiling = LiquidGlassQuality.low;
    addTearDown(() => LiquidGlass.qualityCeiling = LiquidGlassQuality.high);
    await tester.pumpWidget(
      const MaterialApp(
        home: LiquidGlass(
          quality: LiquidGlassQuality.high,
          child: Text('glass content'),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('glass content'), findsOneWidget);
  });

  testWidgets('glass card presses in and fully restores on release', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ReelishGlassCard(
            onTap: () => taps++,
            child: const SizedBox(width: 160, height: 60),
          ),
        ),
      ),
    );
    double press() =>
        tester.widget<LiquidGlass>(find.byType(LiquidGlass)).pressDepth;
    double scale() => tester
        .widget<Transform>(
          find.ancestor(
            of: find.byType(LiquidGlass),
            matching: find.byType(Transform),
          ),
        )
        .transform
        .storage[0];

    // Pressing near the padded edge still counts as the card.
    final gesture = await tester.startGesture(
      tester.getTopLeft(find.byType(ReelishGlassCard)) + const Offset(4, 4),
    );
    await tester.pumpAndSettle();
    expect(press(), 1);
    expect(scale(), lessThan(1));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(press(), 0);
    expect(scale(), 1);
  });

  testWidgets('selected glass card adds coral light', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ReelishGlassCard(selected: true, child: SizedBox(height: 40)),
      ),
    );
    expect(
      tester.widget<LiquidGlass>(find.byType(LiquidGlass)).accentStrength,
      greaterThan(0),
    );
  });
}
