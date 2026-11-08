import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/glass_button.dart';

GlassButtonPainter? _finishOf(WidgetTester tester, Finder button) {
  final paints = tester.widgetList<CustomPaint>(
    find.descendant(of: button, matching: find.byType(CustomPaint)),
  );
  for (final paint in paints) {
    if (paint.painter case final GlassButtonPainter painter) return painter;
  }
  return null;
}

Future<void> _pump(WidgetTester tester, ThemeData theme, Widget child) =>
    tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  test('light follows the button state', () {
    expect(GlassButtonStyle.lightFor({}), 1);
    expect(GlassButtonStyle.lightFor({WidgetState.hovered}), greaterThan(1));
    expect(GlassButtonStyle.lightFor({WidgetState.pressed}), lessThan(1));
    expect(
      GlassButtonStyle.lightFor({WidgetState.disabled, WidgetState.hovered}),
      lessThan(GlassButtonStyle.lightFor({WidgetState.pressed})),
    );
  });

  testWidgets('filled and outlined buttons carry the glass finish', (
    tester,
  ) async {
    await _pump(
      tester,
      GlassTheme.dark,
      Column(
        children: [
          FilledButton(onPressed: () {}, child: const Text('Play')),
          OutlinedButton(onPressed: () {}, child: const Text('Trailer')),
          TextButton(onPressed: () {}, child: const Text('Cancel')),
        ],
      ),
    );
    expect(
      _finishOf(tester, find.byType(FilledButton))?.tone,
      GlassButtonTone.accent,
    );
    expect(
      _finishOf(tester, find.byType(OutlinedButton))?.tone,
      GlassButtonTone.neutral,
    );
    // Text buttons stay flat.
    expect(_finishOf(tester, find.byType(TextButton)), isNull);
  });

  testWidgets('a call site colour is kept under the finish', (tester) async {
    await _pump(
      tester,
      GlassTheme.dark,
      FilledButton(
        onPressed: () {},
        style: FilledButton.styleFrom(backgroundColor: GlassTheme.danger),
        child: const Text('Remove'),
      ),
    );
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(FilledButton),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, GlassTheme.danger);
    expect(_finishOf(tester, find.byType(FilledButton)), isNotNull);
  });

  testWidgets('TV keeps its focus ring and gains the finish', (tester) async {
    final theme = GlassTheme.tv;
    final side = theme.outlinedButtonTheme.style!.side!;
    expect(side.resolve({WidgetState.focused})?.width, 2.5);
    expect(side.resolve({})?.color.a, closeTo(.3, .01));
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await _pump(
      tester,
      theme,
      FilledButton(
        focusNode: focusNode,
        onPressed: () {},
        child: const Text('Play'),
      ),
    );
    expect(_finishOf(tester, find.byType(FilledButton)), isNotNull);
  });

  testWidgets('a busy button keeps its size and shows its progress', (
    tester,
  ) async {
    Widget button({required bool busy}) => FilledButton.icon(
      key: const ValueKey('button'),
      onPressed: busy ? null : () {},
      icon: busy ? const GlassButtonProgress() : const Icon(Icons.download),
      label: const Text('Install'),
    );
    await _pump(tester, GlassTheme.dark, button(busy: false));
    final idle = tester.getSize(find.byKey(const ValueKey('button')));
    await _pump(tester, GlassTheme.dark, button(busy: true));
    expect(tester.getSize(find.byKey(const ValueKey('button'))), idle);
    // Disabled while busy, yet the indicator is drawn at full strength.
    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.color?.a, 1);
    expect(
      tester.getSize(find.byType(GlassButtonProgress)),
      const Size.square(18),
    );
  });

  testWidgets('menus are smoked glass with a hairline edge', (tester) async {
    final menu = GlassTheme.dark.popupMenuTheme;
    expect(menu.surfaceTintColor, Colors.transparent);
    final shape = menu.shape! as RoundedRectangleBorder;
    expect(shape.side.color, GlassTheme.border);
    // Near-opaque, so menu text reads over artwork.
    expect(menu.color!.a, greaterThan(.95));
    // TV inherits it.
    expect(GlassTheme.tv.popupMenuTheme.shape, shape);
  });

  testWidgets('keyboard focus draws a ring on phone and Windows', (
    tester,
  ) async {
    final side = GlassTheme.dark.filledButtonTheme.style!.side!;
    expect(side.resolve({WidgetState.focused})?.width, 2);
    expect(side.resolve({}), BorderSide.none);
  });
}
