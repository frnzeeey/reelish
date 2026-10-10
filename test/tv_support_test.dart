import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/first_run_consent_screen.dart';
import 'package:onfeed/src/screens/legal_information_screen.dart';
import 'package:onfeed/src/screens/tv/tv_browse.dart';
import 'package:onfeed/src/screens/tv/tv_home_shell.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/liquid_glass.dart';
import 'package:onfeed/src/widgets/player/player_controls.dart';
import 'package:onfeed/src/widgets/player/player_progress_bar.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';
import 'package:video_player/video_player.dart';

const _deviceChannel = MethodChannel('onfeed/device');

/// A controller whose state the test sets directly; never initialized.
VideoPlayerController _controller() {
  final controller = VideoPlayerController.networkUrl(
    Uri.parse('https://cdn.example/video.m3u8'),
  );
  controller.value = controller.value.copyWith(
    duration: const Duration(minutes: 100),
    position: const Duration(minutes: 10),
    isPlaying: true,
    isInitialized: true,
    size: const Size(1920, 1080),
  );
  return controller;
}

List<MediaItem> _items(String prefix, int count) => [
  for (var i = 0; i < count; i++)
    MediaItem(id: '$prefix$i', type: 'movie', name: '$prefix title $i'),
];

/// A TV-sized window (960 × 540 dp, as a 1080p TV reports) with the TV theme,
/// as the app sets them up on a TV.
Future<void> _pumpTv(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: GlassTheme.tv, home: child));
  await tester.pump();
}

String? get _focused => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_deviceChannel, null);
  });

  group('DeviceCapabilities', () {
    test('a device reporting television gets the TV interface', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _deviceChannel,
            (call) async => {
              'isTelevision': true,
              'hasLeanback': true,
              'hasTouchscreen': false,
              'supportsPictureInPicture': false,
            },
          );

      final device = await DeviceCapabilities.load();

      expect(device.isTelevision, isTrue);
      expect(device.hasTouchscreen, isFalse);
      expect(device.supportsPictureInPicture, isFalse);
      expect(DeviceCapabilities.isTv, isTrue);
      // TV drops backdrop blur and always draws focus.
      expect(LiquidGlass.qualityCeiling, LiquidGlassQuality.low);
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTraditional,
      );
    });

    test(
      'a phone, or an unanswered query, keeps the mobile interface',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              _deviceChannel,
              (call) async => {
                'isTelevision': false,
                'hasTouchscreen': true,
                'supportsPictureInPicture': true,
              },
            );
        expect((await DeviceCapabilities.load()).isTelevision, isFalse);

        // No handler at all: MissingPluginException is caught.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_deviceChannel, null);
        expect((await DeviceCapabilities.load()).isTelevision, isFalse);
        expect(DeviceCapabilities.isTv, isFalse);
        expect(LiquidGlass.qualityCeiling, LiquidGlassQuality.high);
        expect(
          FocusManager.instance.highlightStrategy,
          FocusHighlightStrategy.automatic,
        );
      },
    );
  });

  testWidgets('TvFocusable activates with the D-pad center and Enter', (
    tester,
  ) async {
    var selected = 0;
    await _pumpTv(
      tester,
      Scaffold(
        body: Center(
          child: TvFocusable(
            autofocus: true,
            onSelect: () => selected++,
            child: const SizedBox(width: 120, height: 80),
          ),
        ),
      ),
    );

    await _press(tester, LogicalKeyboardKey.select);
    await _press(tester, LogicalKeyboardKey.enter);

    expect(selected, 2);
  });

  testWidgets('rows move with the D-pad and remember focus per row', (
    tester,
  ) async {
    final opened = <String>[];
    final cards = TvCardOptions(onOpen: (item) => opened.add(item.id));
    await _pumpTv(
      tester,
      Scaffold(
        body: Column(
          children: [
            TvMediaRow(
              title: 'A',
              items: _items('a', 12),
              cards: cards,
              autofocus: true,
            ),
            TvMediaRow(title: 'B', items: _items('b', 12), cards: cards),
          ],
        ),
      ),
    );
    expect(_focused, 'A 0');

    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused, 'A 2');

    // Entering row B for the first time starts at its first title.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused, 'B 0');
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused, 'B 1');

    // Back up: row A resumes where it was left.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused, 'A 2');

    await _press(tester, LogicalKeyboardKey.select);
    expect(opened, ['a2']);
  });

  testWidgets('the rail and pages hand focus back and forth, and Back steps '
      'out to the rail, then Home, then leaves', (tester) async {
    var destination = TvDestination.home;
    final popped = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          popped.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final nodes = <String, FocusNode>{};
    FocusNode node(String label) =>
        nodes[label] ??= FocusNode(debugLabel: label);
    addTearDown(() {
      for (final node in nodes.values) {
        node.dispose();
      }
    });

    await _pumpTv(
      tester,
      StatefulBuilder(
        builder: (context, setState) => TvHomeShell(
          destination: destination,
          onDestinationChanged: (value) => setState(() => destination = value),
          pageBuilder: (context, page) => Row(
            children: [
              for (var i = 0; i < 2; i++)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: TvFocusable(
                    focusNode: node('${page.name} $i'),
                    autofocus: page == TvDestination.home && i == 0,
                    onSelect: () {},
                    child: const SizedBox(width: 100, height: 100),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(_focused, 'home 0');

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused, 'home 1');
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused, 'home 0');
    // Left from the leftmost control opens the rail on the current page.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused, 'Rail Home');

    // Moving through the rail switches pages as it goes.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused, 'Rail Movies');
    expect(destination, TvDestination.movies);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused, 'movies 0');

    // Back to Home through the rail restores the control focused there.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(destination, TvDestination.home);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused, 'home 0');

    // Back: page -> rail -> Home -> leave the app.
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused, 'home 1');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_focused, 'Rail Home');
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(destination, TvDestination.movies);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(destination, TvDestination.home);
    expect(_focused, 'Rail Home');
    expect(popped, isNot(contains('SystemNavigator.pop')));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, contains('SystemNavigator.pop'));
  });

  testWidgets('the progress bar scrubs with the D-pad and seeks once', (
    tester,
  ) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
    );
    final controller = _controller();
    addTearDown(controller.dispose);
    final seeks = <Duration>[];
    final scrubbing = <bool>[];
    await _pumpTv(
      tester,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: PlayerProgressBar(
              controller: controller,
              onSeek: seeks.add,
              onScrubChanged: scrubbing.add,
            ),
          ),
        ),
      ),
    );
    Focus.of(
      tester.element(
        find
            .descendant(
              of: find.byType(PlayerProgressBar),
              matching: find.byType(GestureDetector),
            )
            .first,
      ),
    ).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    // Previewing only: nothing seeks while keys keep coming.
    expect(seeks, isEmpty);
    expect(scrubbing, [true]);
    expect(find.text('10:10'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 800));
    expect(seeks, [const Duration(minutes: 10, seconds: 10)]);
    expect(scrubbing, [true, false]);
  });

  testWidgets('controls hidden by the pause screen cannot take focus', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    final playFocus = FocusNode(debugLabel: 'Play');
    addTearDown(playFocus.dispose);
    final pauseScreen = ValueNotifier(false);
    addTearDown(pauseScreen.dispose);
    await _pumpTv(
      tester,
      Scaffold(
        backgroundColor: Colors.black,
        body: PlayerControlsOverlay(
          controller: controller,
          title: 'The Show',
          subtitle: '',
          sourceLabel: '',
          subtitleEnabled: false,
          showAudio: false,
          showSources: false,
          landscapeLocked: true,
          onBack: () {},
          onTogglePlay: () {},
          onSeekBy: (_) {},
          onSeekTo: (_) {},
          onScrubChanged: (_) {},
          onSubtitles: () {},
          onAudio: () {},
          onSources: () {},
          onSettings: () {},
          onPip: null,
          onRotate: null,
          pauseScreen: pauseScreen,
          playFocusNode: playFocus,
        ),
      ),
    );
    expect(playFocus.canRequestFocus, isTrue);
    // TV passes no rotation or picture-in-picture callbacks.
    expect(find.bySemanticsLabel('Lock to landscape'), findsNothing);
    expect(find.bySemanticsLabel('Picture in picture'), findsNothing);

    playFocus.requestFocus();
    await tester.pump();
    pauseScreen.value = true;
    await tester.pumpAndSettle();

    expect(playFocus.canRequestFocus, isFalse);
    expect(playFocus.hasFocus, isFalse);
  });

  testWidgets('TV text entry opens on Select, and Down leaves the field', (
    tester,
  ) async {
    final changes = <String>[];
    final submitted = <String>[];
    var value = '';
    await _pumpTv(
      tester,
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 500,
            child: StatefulBuilder(
              builder: (context, setState) => TvTextField(
                autofocus: true,
                value: value,
                hint: 'Search movies and series',
                textInputAction: TextInputAction.search,
                onChanged: (text) {
                  changes.add(text);
                  setState(() => value = text);
                },
                onSubmitted: submitted.add,
              ),
            ),
          ),
        ),
      ),
    );
    // Focusing the field does not open the keyboard.
    expect(find.byType(TextField), findsNothing);

    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'matrix');
    expect(changes.last, 'matrix');

    // With the keyboard dismissed, Down reaches the dialog's buttons.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNull,
    );
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
    );

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(submitted, ['matrix']);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('matrix'), findsOneWidget);
  });

  testWidgets('a dialog opens with its first, safe action focused', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.tv,
        navigatorObservers: [TvPopupFocusObserver()],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                autofocus: true,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Remove repository?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Remove'),
                      ),
                    ],
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _press(tester, LogicalKeyboardKey.select);

    final focused = FocusManager.instance.primaryFocus?.context;
    final button = focused?.findAncestorWidgetOfExactType<TextButton>();
    expect((button?.child as Text?)?.data, 'Cancel');
  });

  testWidgets('a sheet that focuses its own control keeps that focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final field = FocusNode(debugLabel: 'URL field');
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.tv,
        navigatorObservers: [TvPopupFocusObserver()],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                autofocus: true,
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (context) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // First in reading order, as the installer's Close is.
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                      TvFocusable(
                        focusNode: field,
                        autofocus: true,
                        onSelect: () {},
                        child: const SizedBox(width: 200, height: 50),
                      ),
                    ],
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _press(tester, LogicalKeyboardKey.select);

    expect(_focused, 'URL field');
  });

  testWidgets('first-run consent starts on a visible action, not a disabled '
      'checkbox', (tester) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
    );
    await _pumpTv(tester, FirstRunConsentScreen(onAccepted: () {}));

    await _press(tester, LogicalKeyboardKey.arrowDown);

    // The agreement checkboxes stay disabled until a document is read, and
    // Material draws no focus on disabled controls; focus must not land
    // there.
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused?.findAncestorWidgetOfExactType<TextButton>(), isNotNull);
    expect(focused?.findAncestorWidgetOfExactType<CheckboxListTile>(), isNull);
  });

  testWidgets('a document that must be read to the end can be read with the '
      'D-pad', (tester) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
    );
    bool? readToEnd;
    await _pumpTv(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              autofocus: true,
              onPressed: () async {
                readToEnd = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => const LegalInformationScreen(
                      document: LegalDocument.terms,
                      requireReadToEnd: true,
                    ),
                  ),
                );
              },
              child: const Text('Read'),
            ),
          ),
        ),
      ),
    );
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.text('Done reading'), findsOneWidget);

    // Plain text has nothing to focus: Down scrolls it until the end, where
    // Done reading turns on and takes focus.
    for (var i = 0; i < 60 && readToEnd == null; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused?.findAncestorWidgetOfExactType<FilledButton>() != null) {
        await _press(tester, LogicalKeyboardKey.select);
      }
    }
    expect(readToEnd, isTrue);
  });
}
