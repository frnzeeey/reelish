import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/liquid_glass.dart';
import 'package:onfeed/src/widgets/soft_glass_dock.dart';

/// Lays the dock out the way the home screen does: full width, pinned to the
/// bottom of a Stack, with a 24 dp gesture-navigation inset.
Future<List<int>> _pumpDock(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final selected = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: const EdgeInsets.only(bottom: 24),
        ),
        child: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: StatefulBuilder(
                  builder: (context, setState) => SoftGlassDock(
                    selectedIndex: selected.isEmpty ? 0 : selected.last,
                    onSelected: (index) => setState(() => selected.add(index)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return selected;
}

Rect _glass(WidgetTester tester) => tester.getRect(find.byType(LiquidGlass));

void main() {
  const labels = ['Home', 'Plugins', 'Library', 'Settings'];

  group('phones keep the original dock', () {
    for (final size in const [
      Size(360, 800),
      Size(412, 915),
      Size(915, 412), // large phone, landscape
    ]) {
      testWidgets('${size.width.toInt()} x ${size.height.toInt()}', (
        tester,
      ) async {
        await _pumpDock(tester, size);
        final glass = _glass(tester);
        // 22 dp side margins, full width, 72 dp row + 6 dp padding each way.
        expect(glass.left, 22);
        expect(glass.right, size.width - 22);
        expect(glass.height, 84);
        // The 24 dp system inset wins over the 10 dp minimum margin.
        expect(glass.bottom, size.height - 24);
      });
    }
  });

  group('tablets get a compact centered dock', () {
    for (final (size, width) in const [
      (Size(600, 960), 380.0),
      (Size(800, 1280), 400.0),
      (Size(1280, 800), 440.0),
      (Size(1024, 1366), 440.0),
      (Size(1366, 1024), 440.0),
    ]) {
      testWidgets(
        '${size.width.toInt()} x ${size.height.toInt()} -> ${width.toInt()} dp',
        (tester) async {
          await _pumpDock(tester, size);
          final glass = _glass(tester);
          expect(glass.width, width);
          expect(glass.center.dx, size.width / 2);
          expect(glass.height, 76);
          expect(glass.bottom, size.height - 24);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  testWidgets('every tablet tab is a 48 dp target and still navigates', (
    tester,
  ) async {
    final selected = await _pumpDock(tester, const Size(600, 960));
    for (final (index, label) in labels.indexed) {
      final target = tester.getSize(
        find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
      );
      expect(target.width, greaterThanOrEqualTo(48), reason: label);
      expect(target.height, greaterThanOrEqualTo(48), reason: label);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(selected.last, index);
    }
  });

  test('breakpoint follows the shortest side, not orientation', () {
    expect(DockMetrics.forSize(const Size(915, 412)), DockMetrics.phone);
    expect(DockMetrics.forSize(const Size(412, 915)), DockMetrics.phone);
    expect(DockMetrics.forSize(const Size(960, 600)).width, 440);
    expect(DockMetrics.forSize(const Size(600, 960)).width, 380);
  });

  testWidgets('tab labels use the app font, not the platform default', (
    tester,
  ) async {
    await _pumpDock(tester, const Size(412, 915));
    for (final label in ['Home', 'Plugins', 'Library', 'Settings']) {
      final text = tester.widget<RichText>(
        find.descendant(of: find.text(label), matching: find.byType(RichText)),
      );
      expect(text.text.style?.fontFamily, GlassTheme.fontFamily, reason: label);
    }
  });
}
