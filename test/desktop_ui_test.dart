import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/desktop/desktop_provider_search.dart';
import 'package:onfeed/src/desktop/desktop_shell.dart';
import 'package:onfeed/src/desktop/desktop_widgets.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/resume_summary.dart';
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
  const _ShellHost({this.probe = false});

  /// Home is a [_PageProbe], which counts its builds.
  final bool probe;

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
        widget.probe && destination == TvDestination.home
        ? const _PageProbe()
        : Center(child: Text('page:${destination.name}')),
  );
}

/// A page that fills its area and counts how often it is built, standing
/// in for a streaming page whose rebuild would be costly.
class _PageProbe extends StatelessWidget {
  const _PageProbe();

  static int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return const SizedBox.expand(child: Center(child: Text('page:home')));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('DesktopMetrics', () {
    test('posters stay between 140 and 220 px at every window size', () {
      for (final width in [640.0, 900.0, 1240.0, 1700.0, 2400.0, 3700.0]) {
        final poster = DesktopMetrics.posterWidth(width);
        expect(poster, inInclusiveRange(140, 220), reason: '$width');
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
    Future<TestGesture> mouseAt(WidgetTester tester, Offset position) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: position);
      await tester.pump();
      return mouse;
    }

    testWidgets('the sidebar switches pages and keeps visited ones', (
      tester,
    ) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      expect(find.text('page:home'), findsOneWidget);
      // Compact: every destination is an icon with its name as a tooltip.
      for (final destination in TvDestination.values) {
        expect(find.byTooltip(destination.label), findsOneWidget);
      }

      await tester.tap(find.byTooltip('Movies'));
      await tester.pumpAndSettle();
      expect(find.text('page:movies'), findsOneWidget);
      // Home stays built (offstage), so it keeps its scroll position.
      expect(find.text('page:home', skipOffstage: false), findsOneWidget);
    });

    testWidgets('starts compact and opens over the page on hover, without '
        'rebuilding or moving the page', (tester) async {
      _PageProbe.builds = 0;
      await _pump(
        tester,
        const _ShellHost(probe: true),
        size: const Size(1400, 900),
      );
      await tester.pumpAndSettle();
      final page = tester.getRect(find.byType(_PageProbe));
      final builds = _PageProbe.builds;
      expect(page.left, DesktopShell.collapsedExtent);
      expect(find.text('Movies'), findsNothing);

      // A pointer that only crosses the rail does not open it.
      final mouse = await mouseAt(tester, const Offset(40, 300));
      await tester.pump(const Duration(milliseconds: 60));
      await mouse.moveTo(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);

      // Resting on it does: labels show, the panel widens over the page.
      await mouse.moveTo(const Offset(40, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Movies')).dx,
        lessThan(DesktopShell.expandedExtent),
      );
      // The page neither rebuilt nor moved.
      expect(_PageProbe.builds, builds);
      expect(tester.getRect(find.byType(_PageProbe)), page);

      // A click while open works, once.
      await tester.tap(find.text('Movies'));
      await tester.pumpAndSettle();
      expect(find.text('page:movies'), findsOneWidget);

      // Leaving closes it again.
      await mouse.moveTo(const Offset(900, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
    });

    testWidgets('keyboard focus opens the rail, so labels show without a '
        'mouse', (tester) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      // Focus stays on the item as the rail opens around it.
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FocusableActionDetector>(),
        isNotNull,
      );
    });

    testWidgets('can be kept open beside the page, and remembers it', (
      tester,
    ) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Keep sidebar open'));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsOneWidget);
      // Pinned, the page sits beside the rail instead of under it.
      expect(
        tester.getTopLeft(find.text('page:home')).dx,
        greaterThan(DesktopShell.expandedExtent),
      );
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('reelish.desktop.sidebarPinned'), isTrue);

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
      expect(preferences.getBool('reelish.desktop.sidebarPinned'), isFalse);
    });

    testWidgets('Collapse sidebar closes the rail at once, though the '
        'pointer is still on the button', (tester) async {
      SharedPreferences.setMockInitialValues({
        'reelish.desktop.sidebarPinned': true,
      });
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.pumpAndSettle();
      final button = tester.getCenter(find.byTooltip('Collapse sidebar'));
      // One mouse throughout, as on a real desktop: it stays on the button.
      final mouse = await mouseAt(tester, const Offset(900, 300));
      await mouse.moveTo(button);
      await tester.pump(const Duration(milliseconds: 400));
      await mouse.down(button);
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
      expect(find.byTooltip('Keep sidebar open'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('reelish.desktop.sidebarPinned'), isFalse);

      // Resting there does not reopen it...
      await mouse.moveTo(button + const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
      // ...but leaving and coming back does.
      await mouse.moveTo(const Offset(900, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await mouse.moveTo(const Offset(40, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsOneWidget);
    });

    testWidgets('Collapse sidebar from the keyboard closes it too', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'reelish.desktop.sidebarPinned': true,
      });
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.pumpAndSettle();
      for (var i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused != null &&
            find
                .ancestor(
                  of: find.byElementPredicate((e) => e == focused),
                  matching: find.byTooltip('Collapse sidebar'),
                )
                .evaluate()
                .isNotEmpty) {
          break;
        }
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Keep sidebar open'), findsOneWidget);
      expect(find.text('Movies'), findsNothing);
    });

    testWidgets('the earlier sidebar\'s saved "expanded" does not pin it', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'reelish.desktop.sidebarExpanded': true,
      });
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
      expect(find.byTooltip('Keep sidebar open'), findsOneWidget);
    });

    testWidgets('focus left in the rail does not hold it open once the '
        'pointer leaves', (tester) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      final mouse = await mouseAt(tester, const Offset(900, 300));
      await mouse.moveTo(const Offset(40, 300));
      await tester.pump(const Duration(milliseconds: 400));
      // A keyboard step while the pointer is over the rail.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsOneWidget);

      await mouse.moveTo(const Offset(900, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
      // Shortcuts still work from the shell.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('page:search'), findsOneWidget);
    });

    testWidgets('focus in the rail is released by a click on the page', (
      tester,
    ) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsOneWidget);
      await tester.tapAt(const Offset(900, 300));
      await tester.pumpAndSettle();
      expect(find.text('Movies'), findsNothing);
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

    testWidgets('floats off the window edges and holds navigation only', (
      tester,
    ) async {
      await _pump(tester, const _ShellHost(), size: const Size(1400, 900));
      await tester.pumpAndSettle();
      final home = tester.getRect(find.byTooltip('Home'));
      expect(home.left, greaterThanOrEqualTo(DesktopShell.inset));
      expect(home.right, lessThanOrEqualTo(DesktopShell.collapsedExtent));
      // Grouped: browsing first, then yours, then the app's at the foot.
      double top(String label) => tester.getTopLeft(find.byTooltip(label)).dy;
      expect(top('Movies'), lessThan(top('My library')));
      expect(top('Together'), lessThan(top('Plugins')));
      expect(top('Settings'), lessThan(top('Profile')));
      expect(find.textContaining('CONTINUE WATCHING'), findsNothing);
    });

    for (final height in [600.0, 720.0, 768.0, 1080.0]) {
      testWidgets('a ${height.toInt()} px window lays the rail out cleanly; '
          'Settings stays reachable', (tester) async {
        await _pump(tester, const _ShellHost(), size: Size(1280, height));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (height >= 720) {
          // Everything fits without scrolling the rail itself.
          final pin = tester.getRect(find.byTooltip('Keep sidebar open'));
          expect(pin.bottom, lessThanOrEqualTo(height - DesktopShell.inset));
        }
        await tester.tap(find.byTooltip('Settings'), warnIfMissed: false);
        await tester.pumpAndSettle();
        if (height >= 720) {
          expect(find.text('page:settings'), findsOneWidget);
        }
      });
    }
  });

  group('Continue watching on Home', () {
    late List<String> resumed, detailed;
    late int seeAll;
    setUp(() {
      resumed = [];
      detailed = [];
      seeAll = 0;
    });

    DesktopResumeShelf shelf(int count) => DesktopResumeShelf(
      items: [
        for (var i = 0; i < count; i++)
          MediaItem(
            id: '$i',
            type: i.isEven ? 'movie' : 'series',
            name: 'Started title $i',
            resumeMs: 60000 * 20,
          ),
      ],
      summaryOf: (item) => item.id == '0'
          ? const ResumeSummary(fraction: .4, label: '34 min left')
          : const ResumeSummary(label: 'S2 E1'),
      onResume: (item) => resumed.add(item.id),
      onDetails: (item) => detailed.add(item.id),
      onSeeAll: () => seeAll++,
    );

    Finder card(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(DesktopPosterCard),
    );

    testWidgets('wide cards say where each was left; a click resumes, a '
        'right click opens details, See all opens the library', (tester) async {
      await _pump(
        tester,
        SingleChildScrollView(
          child: DesktopContinueWatchingRow(shelf: shelf(3)),
        ),
        size: const Size(1400, 900),
      );
      await tester.pumpAndSettle();
      expect(find.text('Continue watching'), findsOneWidget);
      expect(find.text('34 min left'), findsOneWidget);
      expect(find.text('S2 E1'), findsNWidgets(2));
      expect(
        tester.widget<DesktopPosterCard>(card('Started title 0')).progress,
        .4,
      );

      await tester.tap(card('Started title 2'));
      await tester.pump();
      expect(resumed, ['2']);
      await tester.tap(card('Started title 1'), buttons: kSecondaryMouseButton);
      await tester.pump();
      expect(detailed, ['1']);
      expect(resumed, ['2']);

      await tester.tap(find.text('See all'));
      expect(seeAll, 1);
    });

    testWidgets('Enter on a focused card resumes it', (tester) async {
      await _pump(
        tester,
        SingleChildScrollView(
          child: DesktopContinueWatchingRow(shelf: shelf(2)),
        ),
        size: const Size(1400, 900),
      );
      Focus.of(
        tester.element(
          find
              .descendant(
                of: card('Started title 1'),
                matching: find.byType(GestureDetector),
              )
              .first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(resumed, ['1']);
    });

    testWidgets('a narrower window resizes the cards at once, without '
        'overflowing while they ease', (tester) async {
      await _pump(
        tester,
        SingleChildScrollView(
          child: DesktopContinueWatchingRow(shelf: shelf(4)),
        ),
        size: const Size(1600, 900),
      );
      tester.view.physicalSize = const Size(1500, 900);
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a dozen at most; the library holds the rest', (
      tester,
    ) async {
      await _pump(
        tester,
        SingleChildScrollView(
          child: DesktopContinueWatchingRow(shelf: shelf(30)),
        ),
        size: const Size(1400, 900),
      );
      final row = tester.widget<DesktopMediaRow>(find.byType(DesktopMediaRow));
      expect(row.items, hasLength(DesktopResumeShelf.maxShown));
    });
  });

  group('Provider search panel', () {
    testWidgets('names the title and episode; Cancel and Esc stop it, and '
        'Esc is left alone once it is gone', (tester) async {
      var cancelled = 0;
      await _pump(
        tester,
        DesktopProviderSearch(
          title: 'Carrie',
          season: 1,
          episode: 3,
          onCancel: () => cancelled++,
        ),
        size: const Size(1400, 900),
      );
      // The spinner never settles.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Searching providers…'), findsOneWidget);
      expect(find.textContaining('Carrie'), findsOneWidget);
      expect(find.textContaining('S1 E3'), findsOneWidget);
      // Inside a Material: no missing-Material underline.
      final style = tester
          .widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Searching providers…'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style;
      expect(style.decoration, isNot(TextDecoration.underline));

      await tester.tap(find.text('Cancel'));
      expect(cancelled, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancelled, 2);

      await tester.pumpWidget(const SizedBox());
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancelled, 2);
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
