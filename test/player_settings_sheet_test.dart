import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/widgets/player/player_settings_sheet.dart';

void main() {
  /// Opens the sheet and returns what it is closed with.
  Future<Future<PlayerSettings?>> openSheet(
    WidgetTester tester, {
    String? alternateEngine,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    Future<PlayerSettings?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => result = PlayerSettingsSheet.show(
                context,
                const PlayerSettings(),
                const [],
                const [],
                const [],
                alternateEngine,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result!;
  }

  testWidgets('offers the other engine and reports the choice', (
    tester,
  ) async {
    final closed = await openSheet(
      tester,
      alternateEngine: 'the Android player',
    );
    await tester.tap(find.text('Switch to the Android player'));
    await tester.pumpAndSettle();
    expect((await closed)?.switchEngine, isTrue);
  });

  testWidgets('hides the switch when no other engine can play', (
    tester,
  ) async {
    await openSheet(tester);
    expect(find.textContaining('Switch to'), findsNothing);
  });
}
