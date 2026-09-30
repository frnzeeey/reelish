import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/navigation/app_transitions.dart';
import 'package:onfeed/src/widgets/media_card.dart';

void main() {
  testWidgets('details route pushes and reverses through shared transition', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                AppPageRoute<void>(
                  context: context,
                  details: true,
                  builder: (detailsContext) => Scaffold(
                    body: Column(
                      children: [
                        const Text('Details page'),
                        TextButton(
                          onPressed: () => Navigator.pop(detailsContext),
                          child: const Text('Back'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('Open details'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Details page'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open details'), findsOneWidget);
    expect(find.text('Details page'), findsNothing);
  });

  testWidgets('rapid taps on one media card start navigation once', (
    tester,
  ) async {
    var navigationCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaCard(
            item: const MediaItem(id: '1', type: 'movie', name: 'Film'),
            onTap: () {
              navigationCount++;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(MediaCard));
    await tester.tap(find.byType(MediaCard));
    await tester.pump(const Duration(milliseconds: 240));
    await tester.pump();

    expect(navigationCount, 1);
  });
}
