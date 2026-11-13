// Intro and outro skipping through the real player session (PlayerScreen →
// CustomVideoPlayer) against the scripted engine: what the viewer sees and
// where playback lands. The skip rules themselves are in intro_skip_test.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/intro_skip/intro_outro_service.dart';
import 'package:onfeed/src/intro_skip/skip_planner.dart';
import 'package:onfeed/src/intro_skip/skip_segments.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/playback_settings.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/player_screen.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video_player_platform.dart';

const _source = StreamSource(
  name: 'Only',
  url: 'https://8.8.8.8/episode.m3u8',
  providerName: 'A',
);
const _series = MediaItem(id: '1396', type: 'series', name: 'Show');
const _key = EpisodeKey('tt0903747', 1, 2);
const _length = Duration(minutes: 47);

void main() {
  late FakeVideoPlayerPlatform engine;
  late Directory files;
  late StorageService storage;
  late int introDbRequests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    engine = FakeVideoPlayerPlatform()
      ..onCreate = (player) => player.initialize(duration: _length);
    VideoPlayerPlatform.instance = engine;
    files = Directory.systemTemp.createTempSync('intro_skip_player_test');
    storage = StorageService(filesDirectory: () async => files);
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      supportsPictureInPicture: false,
    );
    introDbRequests = 0;
  });

  tearDown(() {
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
    IntroOutroService.instance = IntroOutroService();
    try {
      files.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// IntroDB answers with an intro at 0:30–1:30 and an outro at
  /// 44:00–46:30, as the scripted episode is 47 minutes long. The answer is
  /// fetched before the player opens (real I/O does not run under the
  /// widget test clock), so the player finds it cached.
  Future<void> introDbKnowsEpisode(WidgetTester tester) async {
    final service = IntroOutroService(
      client: MockClient((request) async {
        introDbRequests++;
        return http.Response(
          jsonEncode({
            'imdb_id': 'tt0903747',
            'media_type': 'tv',
            'is_movie': false,
            'season': 1,
            'episode': 2,
            'intro': {
              'start_ms': 30000,
              'end_ms': 90000,
              'start_sec': 30,
              'end_sec': 90,
              'confidence': .95,
              'submission_count': 12,
              'updated_at': '2026-10-01T00:00:00Z',
            },
            'recap': null,
            'outro': {
              'start_ms': 2640000,
              'end_ms': 2790000,
              'start_sec': 2640,
              'end_sec': 2790,
              'confidence': .9,
              'submission_count': 6,
              'updated_at': '2026-10-01T00:00:00Z',
            },
            'post_credits': null,
            'no_intro': false,
            'no_recap': true,
            'no_outro': false,
          }),
          200,
        );
      }),
      filesDirectory: () async => files,
    );
    await tester.runAsync(() => service.segmentsFor(_key));
    IntroOutroService.instance = service;
  }

  Future<void> openEpisode(
    WidgetTester tester, {
    PlaybackSettings settings = const PlaybackSettings(),
    String imdbId = 'tt0903747',
    int season = 1,
  }) async {
    final controller = PlaybackSettingsController(storage: storage);
    await controller.update(settings);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          item: _series,
          source: _source,
          sources: const [_source],
          storage: storage,
          playbackSettings: controller,
          season: season,
          episode: 2,
          imdbId: Future.value(imdbId),
          // A fresh start: no saved position to resume.
          startFromBeginning: true,
        ),
      ),
    );
  }

  Future<void> advance(
    WidgetTester tester, [
    Duration by = Duration.zero,
  ]) async {
    await tester.pump(by);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The engine moves to [position]; the controller polls it while playing.
  Future<void> playAt(WidgetTester tester, Duration position) async {
    engine.players.last.position = position;
    await advance(tester, const Duration(milliseconds: 600));
  }

  Future<void> closePlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await advance(tester, const Duration(seconds: 25));
  }

  _testSession('an intro is skipped as it starts, once', (tester) async {
    await introDbKnowsEpisode(tester);
    await openEpisode(tester);
    await advance(tester);
    expect(engine.players.single.playCalls, 1);

    await playAt(tester, const Duration(seconds: 10));
    expect(engine.players.single.position, const Duration(seconds: 10));

    await playAt(tester, const Duration(seconds: 31));
    expect(
      engine.players.single.position,
      const Duration(seconds: 90),
      reason: 'sought to the end of the intro',
    );
    // The outro is offered, not skipped (the default).
    await playAt(tester, const Duration(minutes: 44, seconds: 5));
    expect(
      engine.players.single.position,
      const Duration(minutes: 44, seconds: 5),
    );
    expect(find.text('Skip outro'), findsOneWidget);
    expect(introDbRequests, 1, reason: 'the cached answer was used');
    await closePlayer(tester);
  });

  _testSession('phone: the Skip intro button skips on a tap', (tester) async {
    await introDbKnowsEpisode(tester);
    await openEpisode(
      tester,
      settings: const PlaybackSettings(introSkip: SkipMode.button),
    );
    await advance(tester);
    await playAt(tester, const Duration(seconds: 40));
    expect(engine.players.single.position, const Duration(seconds: 40));
    expect(find.text('Skip intro'), findsOneWidget);
    await tester.tap(find.text('Skip intro'));
    await advance(tester);
    expect(engine.players.single.position, const Duration(seconds: 90));
    await advance(tester, const Duration(milliseconds: 600));
    expect(find.text('Skip intro'), findsNothing);
    await closePlayer(tester);
  });

  _testSession('TV: Select on the remote skips while the button shows', (
    tester,
  ) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
      supportsPictureInPicture: false,
    );
    await introDbKnowsEpisode(tester);
    await openEpisode(
      tester,
      settings: const PlaybackSettings(introSkip: SkipMode.button),
    );
    await advance(tester);
    // The controls hide after a while; the button stays.
    await advance(tester, const Duration(seconds: 6));
    await playAt(tester, const Duration(seconds: 45));
    expect(find.text('Skip intro'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
    await advance(tester);
    expect(engine.players.single.position, const Duration(seconds: 90));
    await closePlayer(tester);
  });

  _testSession('without a certain episode nothing is asked or skipped', (
    tester,
  ) async {
    await introDbKnowsEpisode(tester);
    await openEpisode(tester, imdbId: '');
    await advance(tester);
    await playAt(tester, const Duration(seconds: 40));
    expect(engine.players.single.position, const Duration(seconds: 40));
    expect(find.text('Skip intro'), findsNothing);
    expect(introDbRequests, 1, reason: 'only the warm-up request');
    await closePlayer(tester);
  });

  _testSession('both off: IntroDB is not asked', (tester) async {
    var asked = false;
    IntroOutroService.instance = IntroOutroService(
      client: MockClient((_) async {
        asked = true;
        return http.Response('{}', 200);
      }),
      filesDirectory: () async => files,
    );
    await openEpisode(
      tester,
      settings: const PlaybackSettings(
        introSkip: SkipMode.off,
        outroSkip: SkipMode.off,
      ),
    );
    await advance(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await playAt(tester, const Duration(seconds: 40));
    expect(asked, isFalse);
    expect(engine.players.single.position, const Duration(seconds: 40));
    await closePlayer(tester);
  });
}

void _testSession(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.linux),
);
