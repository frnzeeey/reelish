import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/screens/splash_screen.dart';

Finder get _logo => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.image is ResizeImage &&
      ((widget.image as ResizeImage).imageProvider as AssetImage).assetName ==
          SplashSpec.logoAsset,
);

double _logoOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.ancestor(of: _logo, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: child,
  ),
);

void main() {
  testWidgets('continues the native splash: logo visible on the first frame', (
    tester,
  ) async {
    final init = Completer<int>();
    await tester.pumpWidget(
      _app(
        SplashGate<int>(
          initialize: () => init.future,
          revealLogo: false,
          builder: (_, _) => const Text('home'),
        ),
      ),
    );
    expect(_logo, findsOneWidget);
    expect(_logoOpacity(tester), 1);
    init.complete(1);
    await tester.pumpAndSettle();
  });

  testWidgets('reveals the logo where there is no native splash', (
    tester,
  ) async {
    final init = Completer<int>();
    await tester.pumpWidget(
      _app(
        SplashGate<int>(
          initialize: () => init.future,
          revealLogo: true,
          builder: (_, _) => const Text('home'),
        ),
      ),
    );
    expect(_logoOpacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 700));
    expect(_logoOpacity(tester), 1);
    init.complete(1);
    await tester.pumpAndSettle();
  });

  testWidgets('moves on as soon as startup finishes, with no minimum wait', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(
        SplashGate<String>(
          initialize: () async {
            calls++;
            return 'ready';
          },
          builder: (_, result) => Text('home $result'),
        ),
      ),
    );
    // One frame for the future, then the 260 ms cross-fade.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('home ready'), findsOneWidget);
    expect(_logo, findsNothing);
    expect(calls, 1);
  });

  testWidgets('parent rebuilds never restart startup', (tester) async {
    var calls = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SplashGate<int>(
              initialize: () async => ++calls,
              builder: (_, _) => const Text('home'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    rebuild(() {});
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('shows progress only once startup is slow', (tester) async {
    final init = Completer<int>();
    await tester.pumpWidget(
      _app(
        SplashGate<int>(
          initialize: () => init.future,
          builder: (_, _) => const Text('home'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    init.complete(1);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a stalled startup offers a retry instead of hanging', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        SplashGate<int>(
          timeout: const Duration(seconds: 2),
          initialize: () {
            attempts++;
            // The first attempt never finishes; the retry does.
            return attempts == 1 ? Completer<int>().future : Future.value(7);
          },
          builder: (_, result) => Text('home $result'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Reelish could not finish starting.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('home 7'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('reduced motion switches without animating', (tester) async {
    await tester.pumpWidget(
      _app(
        SplashGate<int>(
          initialize: () async => 1,
          revealLogo: true,
          builder: (_, _) => const Text('home'),
        ),
        reduceMotion: true,
      ),
    );
    expect(_logoOpacity(tester), 1);
    await tester.pump();
    await tester.pump();
    expect(find.text('home'), findsOneWidget);
    expect(_logo, findsNothing);
  });
}
