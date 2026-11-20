import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/widgets/reelish_slider.dart';

/// A slider at [value] in a stateful host, recording what it reports.
class _Host extends StatefulWidget {
  const _Host({
    required this.log,
    this.value = .5,
    this.divisions = 20,
    this.enabled = true,
    this.directional = false,
  });

  final List<String> log;
  final double value;
  final int? divisions;
  final bool enabled;
  final bool directional;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late double value = widget.value;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      navigationMode: widget.directional
          ? NavigationMode.directional
          : NavigationMode.traditional,
    ),
    child: Center(
      child: SizedBox(
        width: 240,
        child: ReelishSlider(
          value: value,
          divisions: widget.divisions,
          semanticFormatterCallback: (v) => '${(v * 100).round()}%',
          onChangeStart: (v) => widget.log.add('start $v'),
          onChanged: widget.enabled
              ? (v) {
                  widget.log.add('change $v');
                  setState(() => value = v);
                }
              : null,
          onChangeEnd: (v) => widget.log.add('end $v'),
        ),
      ),
    ),
  );
}

Future<List<String>> _pump(
  WidgetTester tester, {
  double value = .5,
  int? divisions = 20,
  bool enabled = true,
  bool directional = false,
}) async {
  final log = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: _Host(
          log: log,
          value: value,
          divisions: divisions,
          enabled: enabled,
          directional: directional,
        ),
      ),
    ),
  );
  return log;
}

double _last(List<String> log) =>
    double.parse(log.where((l) => l.startsWith('end')).last.split(' ').last);

void main() {
  testWidgets('never builds an OverlayPortal (the semantics leak)', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(OverlayPortal), findsNothing);
  });

  testWidgets('a tap jumps to the point and reports one whole change', (
    tester,
  ) async {
    final log = await _pump(tester);
    final box = tester.getRect(find.byType(ReelishSlider));
    // The track starts and ends 20 px in (the ring's radius).
    await tester.tapAt(Offset(box.left + 20, box.center.dy));
    await tester.pump();
    expect(log.first, 'start 0.5');
    expect(_last(log), 0);
  });

  testWidgets('a drag reports start, changes and the released value', (
    tester,
  ) async {
    final log = await _pump(tester);
    await tester.drag(find.byType(ReelishSlider), const Offset(400, 0));
    await tester.pump();
    expect(log.first, 'start 0.5');
    expect(log.where((l) => l.startsWith('change')), isNotEmpty);
    expect(log.last, 'end 1.0');
  });

  testWidgets('divisions snap the value', (tester) async {
    final log = await _pump(tester, divisions: 4);
    final box = tester.getRect(find.byType(ReelishSlider));
    // 30 % along the track snaps to the nearest quarter.
    await tester.tapAt(Offset(box.left + 20 + .3 * 200, box.center.dy));
    await tester.pump();
    expect(_last(log), .25);
  });

  testWidgets('arrow keys step; all four with a keyboard', (tester) async {
    final log = await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_last(log), closeTo(.55, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_last(log), closeTo(.45, 1e-9));
  });

  testWidgets('with a D-pad, Up and Down are left for moving focus', (
    tester,
  ) async {
    final log = await _pump(tester, directional: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_last(log), closeTo(.45, 1e-9));
    log.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(log, isEmpty);
  });

  testWidgets('screen readers get a slider they can raise and lower', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final log = await _pump(tester);
    final node = tester.getSemantics(find.byType(ReelishSlider));
    expect(node.value, '50%');
    expect(node.increasedValue, '55%');
    expect(node.decreasedValue, '45%');
    expect(node.flagsCollection.isSlider, isTrue);
    // No tap action: activating it must not jump to the left edge.
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    tester.semantics.increase(find.semantics.byValue('50%'));
    await tester.pump();
    expect(_last(log), closeTo(.55, 1e-9));
    semantics.dispose();
  });

  testWidgets('disabled: no changes, not focusable', (tester) async {
    final log = await _pump(tester, enabled: false);
    await tester.tap(find.byType(ReelishSlider));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(log, isEmpty);
  });

  testWidgets('a gradient track draws', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReelishSlider(
            value: .3,
            trackColors: const [Colors.red, Colors.blue],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(OverlayPortal), findsNothing);
  });

  test("the app uses ReelishSlider, never Material's Slider", () {
    // Material's Slider keeps its page alive with accessibility on
    // (docs/playback/memory.md).
    final material = RegExp(r'(?<![A-Za-z_])Slider\(');
    final offenders = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            material.hasMatch(file.readAsStringSync()))
          file.path,
    ];
    expect(offenders, isEmpty);
  });

  testWidgets('screen readers hear its name', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReelishSlider(
            label: 'Subtitle size',
            value: .5,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(ReelishSlider));
    expect(node.label, 'Subtitle size');
    expect(node.value, '50%');
    semantics.dispose();
  });
}
