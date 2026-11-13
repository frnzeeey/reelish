// Drives the player session (CustomVideoPlayer through PlayerScreen) against
// a scripted engine: opening, failure handling, fallbacks and closing.
//
// The tests select a target platform with no engine of Reelish's own
// (Linux), so PlayerEngineFactory picks FlutterPlatformPlayerEngine, which
// uses whatever VideoPlayerPlatform is registered: the fake. That platform
// has no second engine, so these tests cover source fallback, reconnects and
// timeouts, not the Media3/libmpv engine switch. Stream URLs use public IP
// literals so source preparation needs no DNS lookup.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/player_screen.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video_player_platform.dart';

const _first = StreamSource(
  name: 'First',
  url: 'https://8.8.8.8/first.m3u8',
  providerName: 'A',
);
const _second = StreamSource(
  name: 'Second',
  url: 'https://8.8.4.4/second.m3u8',
  providerName: 'B',
);

void main() {
  late FakeVideoPlayerPlatform engine;
  late Directory files;
  late StorageService storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    engine = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = engine;
    files = Directory.systemTemp.createTempSync('player_session_test');
    storage = StorageService(filesDirectory: () async => files);
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      supportsPictureInPicture: false,
    );
  });

  tearDown(() {
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
    try {
      files.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> openPlayer(
    WidgetTester tester, {
    List<StreamSource> sources = const [_first, _second],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          item: const MediaItem(id: '1', type: 'movie', name: 'Clip'),
          source: sources.first,
          sources: sources,
          storage: storage,
          playbackSettings: PlaybackSettingsController(storage: storage),
        ),
      ),
    );
  }

  /// Lets the session's async steps run. The loading spinner animates
  /// forever, so pumpAndSettle would never return.
  Future<void> advance(
    WidgetTester tester, [
    Duration by = Duration.zero,
  ]) async {
    await tester.pump(by);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Closes the player and lets its bounded timers run out: an open that
  /// was cancelled still has its 20 s startup timeout pending.
  Future<void> closePlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await advance(tester, const Duration(seconds: 25));
  }

  bool showsVideo() => find.byType(VideoPlayer).evaluate().isNotEmpty;

  _testSession('a source the host refuses moves on to the next source', (
    tester,
  ) async {
    engine.onCreate = (player) => player.uri == _first.url
        ? player.fail('Source error: response code: 403')
        : player.initialize();
    await openPlayer(tester);
    await advance(tester);

    expect(engine.players.map((player) => player.uri), [
      _first.url,
      _second.url,
    ]);
    expect(engine.players.first.disposed, isTrue);
    expect(engine.players.last.playCalls, 1);
    expect(showsVideo(), isTrue);
    await closePlayer(tester);
  });

  _testSession('an engine error worded "was cancelled" while opening still '
      'moves on instead of leaving a spinner', (tester) async {
    engine.onCreate = (player) => player.uri == _first.url
        ? player.fail('The operation was cancelled.')
        : player.initialize();
    await openPlayer(tester);
    await advance(tester);

    expect(engine.players.map((player) => player.uri), [
      _first.url,
      _second.url,
    ]);
    expect(engine.players.last.playCalls, 1);
    expect(showsVideo(), isTrue);
    await closePlayer(tester);
  });

  _testSession('an engine error worded "was cancelled" during playback '
      'reconnects instead of leaving a spinner', (tester) async {
    engine.onCreate = (player) => player.initialize();
    await openPlayer(tester);
    await advance(tester);
    expect(engine.players, hasLength(1));
    expect(showsVideo(), isTrue);

    engine.players.single.fail('Request was cancelled');
    // A playing source that drops is reconnected after a short backoff.
    await advance(tester, const Duration(seconds: 2));

    expect(engine.players, hasLength(2));
    expect(engine.players.first.disposed, isTrue);
    expect(engine.players.last.uri, _first.url);
    expect(engine.players.last.playCalls, 1);
    expect(showsVideo(), isTrue);
    await closePlayer(tester);
  });

  _testSession('an engine that never opens times out and the next source '
      'plays', (tester) async {
    // The first player stays silent; later ones open.
    engine.onCreate = (player) {
      if (player.uri != _first.url) player.initialize();
    };
    await openPlayer(tester);
    await advance(tester);
    expect(engine.players, hasLength(1));

    await advance(tester, const Duration(seconds: 21));

    expect(engine.players.first.disposed, isTrue);
    expect(engine.players.last.uri, _second.url);
    expect(engine.players.last.playCalls, 1);
    await closePlayer(tester);
  });

  _testSession('closing the player while a source opens disposes it', (
    tester,
  ) async {
    await openPlayer(tester);
    await advance(tester);
    expect(engine.live, hasLength(1));

    await closePlayer(tester);

    expect(engine.live, isEmpty);
    expect(engine.players, hasLength(1));
  });
}

/// A session test on the platform whose engine is the registered fake.
void _testSession(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.linux),
);
