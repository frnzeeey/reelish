import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/desktop/desktop_shell.dart';
import 'package:onfeed/src/desktop/desktop_widgets.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/tv/tv_home_shell.dart' show TvDestination;
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<MediaItem> _items(int count) => [
  for (var i = 0; i < count; i++)
    MediaItem(id: '$i', type: 'movie', name: 'Title $i', year: '2026'),
];

Future<void> _pump(WidgetTester tester, Widget child, {Size? size}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: GlassTheme.tv,
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

class _ShellHost extends StatefulWidget {
  const _ShellHost();

  @override
  State<_ShellHost> createState() => _ShellHostState();
}

class _ShellHostState extends State<_ShellHost> {
  TvDestination destination = TvDestination.home;

  @override
  Widget build(BuildContext context) => DesktopShell(
    destination: destination,
    onDestinationChanged: (value) => setState(() => destination = value),
    pageBuilder: (context, destination) =>
        Center(child: Text('page:${destination.name}')),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('DesktopMetrics', () {
    test('posters stay between 150 and 230 px at every window size', () {
      for (final width in [640.0, 900.0, 1240.0, 1700.0, 2400.0, 3700.0]) {
        final poster = DesktopMetrics.posterWidth(width);
        expect(poster, inInclusiveRange(150, 230), reason: '$width');
        final columns = DesktopMetrics.columns(width);
        final used = columns * poster + (columns - 1) * DesktopMetrics.gap;
        expect(used, lessThanOrEqualTo(width + .5), reason: '$width');
      }
    });

    test('poster decode sizes are bucketed, so resizes reuse images', () {
      expect(posterDecodeWidth(201), 256);
      expect(posterDecodeWidth(250), 256);
      expect(posterDecodeWidth(257), 320);
    });
  });

  group('DesktopShell', () {
    testWidgets('the sidebar switches pages and keeps visited ones', (
      tester,
    ) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      expect(find.text('page:home'), findsOneWidget);
      for (final destination in TvDestination.values) {
        expect(find.text(destination.label), findsOneWidget);
      }

      await tester.tap(find.text('Movies'));
      await tester.pumpAndSettle();
      expect(find.text('page:movies'), findsOneWidget);
      // Home stays built (offstage), so it keeps its scroll position.
      expect(find.text('page:home', skipOffstage: false), findsOneWidget);
    });

    testWidgets('collapses to icons with tooltips, and remembers it', (
      tester,
    ) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Collapse sidebar'), findsOneWidget);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Expand sidebar'), findsOneWidget);
      expect(find.byTooltip('Search'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('reelish.desktop.sidebarExpanded'), isFalse);
    });

    testWidgets('Ctrl+F opens Search; Enter on a focused item selects it', (
      tester,
    ) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('page:search'), findsOneWidget);

      // Tab reaches the sidebar items; Enter activates the focused one.
      for (var i = 0; i < 2; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('page:movies'), findsOneWidget);
    });
  });

  group('Poster rows and cards', () {
    testWidgets('a click on a card opens it', (tester) async {
      MediaItem? opened;
      await _pump(
        tester,
        DesktopPosterCard(
          item: _items(1).single,
          width: 180,
          onOpen: (item) => opened = item,
        ),
      );
      await tester.tap(find.text('Title 0'));
      expect(opened?.id, '0');
    });

    testWidgets('scroll arrows appear only when the row can scroll', (
      tester,
    ) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 880));
      addTearDown(mouse.removePointer);
      Future<void> hoverRow() async {
        await mouse.moveTo(const Offset(5, 880));
        await tester.pump();
        await mouse.moveTo(const Offset(700, 300));
        await tester.pumpAndSettle();
      }

      await _pump(
        tester,
        DesktopMediaRow(title: 'Short', items: _items(2), onOpen: (_) {}),
        size: const Size(1400, 900),
      );
      await hoverRow();
      expect(find.byTooltip('Scroll Short forward'), findsNothing);
      expect(find.byTooltip('Scroll Short back'), findsNothing);

      await _pump(
        tester,
        DesktopMediaRow(title: 'Long', items: _items(30), onOpen: (_) {}),
      );
      await tester.pumpAndSettle();
      await hoverRow();
      expect(find.byTooltip('Scroll Long forward'), findsOneWidget);
      expect(find.byTooltip('Scroll Long back'), findsNothing);
      await tester.tap(find.byTooltip('Scroll Long forward'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Scroll Long back'), findsOneWidget);
    });

    testWidgets('a row asks for more near its end', (tester) async {
      var asked = 0;
      await _pump(
        tester,
        DesktopMediaRow(
          title: 'Paged',
          items: _items(30),
          onOpen: (_) {},
          onNearEnd: () => asked++,
        ),
        size: const Size(1400, 900),
      );
      expect(asked, 0);
      await tester.dragUntilVisible(
        find.text('Title 29'),
        find.byType(ListView),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      expect(asked, greaterThan(0));
    });
  });
}
