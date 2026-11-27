// Drives the player session (CustomVideoPlayer through PlayerScreen) against
// a scripted engine: opening, failure handling, fallbacks and closing.
//
// The tests select a target platform with no engine of Reelish's own
// (Linux), so PlayerEngineFactory picks FlutterPlatformPlayerEngine, which
// uses whatever VideoPlayerPlatform is registered: the fake. That platform
// has no second engine, so these tests cover source fallback, reconnects and
// timeouts, not the Media3/libmpv engine switch. Stream URLs use public IP
// literals so source preparation needs no DNS lookup.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/profile_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/models/episode_context.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/player_screen.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/stream_discovery.dart';
import 'package:onfeed/src/watch_party/watch_party_controller.dart';
import 'package:onfeed/src/widgets/player/custom_video_player.dart'
    show EpisodeHandOff, EpisodeSwitch;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart' hide VideoAudioTrack;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video_player_platform.dart';

const _first = StreamSource(
  name: 'First',
  url: 'https://8.8.8.8/first.m3u8',
  providerName: 'A',
);

/// [_first] as its provider answers a new lookup: a renewed signed link.
const _firstRenewed = StreamSource(
  name: 'First',
  url: 'https://8.8.8.8/first.m3u8?token=renewed',
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
    // Saves run on one app-wide queue; one left waiting by an earlier
    // test's fake clock would hold this test's saves.
    StorageService.debugResetWrites();
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
    StreamDiscovery? discovery,
    StreamDiscovery Function()? onRediscover,
    EpisodeSwitch? onPlayEpisode,
    PlaybackSettingsController? playbackSettings,
  }) async {
    // With an episode switch, the player is S01E01 of a series whose next
    // episode is S01E02.
    final series = onPlayEpisode != null;
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          item: MediaItem(
            id: '1',
            type: series ? 'series' : 'movie',
            name: 'Clip',
          ),
          source: sources.first,
          sources: sources,
          storage: storage,
          playbackSettings:
              playbackSettings ?? PlaybackSettingsController(storage: storage),
          discovery: discovery,
          onRediscover: onRediscover,
          onPlayEpisode: onPlayEpisode,
          season: series ? 1 : null,
          episode: series ? 1 : null,
          episodeContext: series
              ? Future.value(
                  const EpisodeContext(
                    current: EpisodeRef(season: 1, episode: 1),
                    next: EpisodeRef(season: 1, episode: 2),
                  ),
                )
              : null,
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

  /// The engine plays: the open player's position moves on, as a real
  /// engine's does once frames arrive. A source counts as playing only
  /// then, not when its engine merely accepts play.
  Future<void> playFor(WidgetTester tester) async {
    for (final player in engine.live) {
      if (player.playing) player.position += const Duration(seconds: 5);
    }
    await advance(tester, const Duration(seconds: 1));
  }

  /// Presses the remote's next-track key and lets the switch's position save
  /// finish. Saves are real file writes on one app-wide queue: one left
  /// waiting here would hold every later test's saves too.
  Future<void> pressNextEpisode(
    WidgetTester tester, {
    required bool Function() asked,
  }) async {
    await tester.sendKeyEvent(
      LogicalKeyboardKey.mediaTrackNext,
      platform: 'android',
    );
    for (var i = 0; i < 60 && !asked(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await advance(tester);
  }

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

    await playFor(tester);
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

  // Starts that never played (playback audit of 27 November 2026,
  // docs/playback-audit/RELIABILITY_OPTIMIZATION_REPORT.md): accepting play
  // is not playing, and known sources are not held back or dropped.
  group('starts that never play', () {
    _testSession('a source that accepts play but fails before it moves goes '
        'to the next source, without reconnecting or refreshing', (
      tester,
    ) async {
      var refreshes = 0;
      engine.onCreate = (player) => player.initialize();
      await openPlayer(
        tester,
        sources: const [_first, _second],
        discovery: StreamDiscovery()
          ..add(_first)
          ..add(_second),
        onRediscover: () {
          refreshes++;
          return StreamDiscovery();
        },
      );
      await advance(tester);
      expect(showsVideo(), isTrue);

      // No frame yet: the position never moved.
      engine.players.single.fail('Source error');
      await advance(tester, const Duration(seconds: 4));

      // Before: two reconnects of the same source, then a refresh that held
      // everything else back.
      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _second.url,
      ]);
      expect(refreshes, 0);
      expect(engine.players.last.playCalls, 1);
      await closePlayer(tester);
    });

    _testSession('an engine that accepts play but never moves is given up '
        'after the stall limit', (tester) async {
      // Never buffering either, so the stall watchdog cannot see it.
      engine.onCreate = (player) => player.initialize();
      await openPlayer(tester, sources: const [_first, _second]);
      await advance(tester);
      expect(engine.players, hasLength(1));

      await advance(tester, const Duration(seconds: 20));
      expect(engine.players, hasLength(1), reason: 'not before the limit');

      await advance(tester, const Duration(seconds: 6));
      // Before: the first source stayed open forever.
      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _second.url,
      ]);
      expect(engine.players.first.disposed, isTrue);
      await closePlayer(tester);
    });

    _testSession('a refresh that answers with fewer sources keeps the known '
        'ones it did not return', (tester) async {
      final lookup = StreamDiscovery()
        ..add(_first)
        ..add(_second)
        ..complete();
      // The refresh renews only the first link, which then fails too.
      final refresh = StreamDiscovery()
        ..add(_firstRenewed)
        ..complete();
      engine.onCreate = (player) => player.uri == _firstRenewed.url
          ? player.fail('Source error: response code: 403')
          : player.initialize();
      await openPlayer(
        tester,
        sources: const [_first, _second],
        discovery: lookup,
        onRediscover: () => refresh,
      );
      await advance(tester);
      await playFor(tester);
      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);

      // Before: the error screen, with the second source never tried.
      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _firstRenewed.url,
        _second.url,
      ]);
      expect(engine.players.last.playCalls, 1);
      await closePlayer(tester);
    });

    _testSession('a refresh that has not answered does not hold back a known '
        'source for long, and its late link is still offered', (tester) async {
      final lookup = StreamDiscovery()
        ..add(_first)
        ..add(_second);
      final refresh = StreamDiscovery();
      // The known second source turns out dead too.
      engine.onCreate = (player) => player.uri == _second.url
          ? player.fail('Source error: response code: 404')
          : player.initialize();
      await openPlayer(
        tester,
        sources: const [_first, _second],
        discovery: lookup,
        onRediscover: () => refresh,
      );
      await advance(tester);
      await playFor(tester);
      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);
      expect(engine.players, hasLength(1), reason: 'the refresh may answer');

      await advance(tester, const Duration(seconds: 10));
      // Before: up to the lookup's 60 s search cap.
      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _second.url,
      ]);
      expect(refresh.isCancelled, isFalse);
      expect(engine.live, isEmpty, reason: 'nothing left to try for now');

      // The refresh answers after all: its renewed link plays.
      refresh.add(_firstRenewed);
      await advance(tester);
      expect(engine.players.last.uri, _firstRenewed.url);
      expect(engine.players.last.playCalls, 1);
      await closePlayer(tester);
    });
  });

  // PB-05 (docs/playback-audit/PLAYBACK_AUDIT_REPORT.md): a link that stops
  // working is refreshed by a new provider lookup, never by the one still
  // running, which only holds the links it already gave.
  group('link refresh while the first lookup still runs', () {
    _testSession('a refresh that hands back the running lookup does not '
        'reopen the dead link', (tester) async {
      final lookup = StreamDiscovery()..add(_first);
      var refreshes = 0;
      engine.onCreate = (player) => player.initialize();
      await openPlayer(
        tester,
        sources: const [_first],
        discovery: lookup,
        onRediscover: () {
          refreshes++;
          return lookup;
        },
      );
      await advance(tester);
      expect(showsVideo(), isTrue);
      // A provider that answered late adds a fallback.
      lookup.add(_second);
      await advance(tester);

      await playFor(tester);
      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);

      expect(refreshes, 1);
      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _second.url,
      ]);
      expect(lookup.isCancelled, isFalse);
      expect(engine.players.last.playCalls, 1);
      await closePlayer(tester);
    });

    _testSession('a fresh lookup renews the link, and the first lookup\'s '
        'late sources still arrive', (tester) async {
      final lookup = StreamDiscovery()..add(_first);
      final refresh = StreamDiscovery()..add(_firstRenewed);
      engine.onCreate = (player) => player.uri == _firstRenewed.url
          ? player.fail('Source error: response code: 403')
          : player.initialize();
      await openPlayer(
        tester,
        sources: const [_first],
        discovery: lookup,
        onRediscover: () => refresh,
      );
      await advance(tester);

      await playFor(tester);
      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);
      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _firstRenewed.url,
      ]);

      // The renewed link fails while opening. A provider of the first lookup
      // answers only now; its source is the next one tried.
      lookup.add(_second);
      await advance(tester);

      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _firstRenewed.url,
        _second.url,
      ]);
      expect(lookup.isCancelled, isFalse);
      expect(engine.players.last.playCalls, 1);
      await closePlayer(tester);
    });

    _testSession('a link that keeps dying is refreshed at most the budget, '
        'and each refresh cancels the one before', (tester) async {
      final lookup = StreamDiscovery()..add(_first);
      final refreshes = <StreamDiscovery>[];
      engine.onCreate = (player) => player.initialize();
      await openPlayer(
        tester,
        sources: const [_first],
        discovery: lookup,
        onRediscover: () {
          final renewed = StreamSource(
            name: _first.name,
            url: '${_first.url}?token=${refreshes.length}',
            providerName: _first.providerName,
          );
          final refresh = StreamDiscovery()..add(renewed);
          refreshes.add(refresh);
          return refresh;
        },
      );
      await advance(tester);

      for (var i = 0; i <= LinkRefreshBudget.maxPerSession; i++) {
        expect(showsVideo(), isTrue);
        await playFor(tester);
        engine.players.last.fail('Source error: response code: 403');
        await advance(tester);
      }

      expect(refreshes, hasLength(LinkRefreshBudget.maxPerSession));
      expect(refreshes.first.isCancelled, isTrue);
      expect(engine.players, hasLength(1 + LinkRefreshBudget.maxPerSession));
      expect(engine.live, isEmpty);
      expect(showsVideo(), isFalse);
      expect(lookup.isCancelled, isFalse);
      await closePlayer(tester);
    });
  });

  // PB-04 (docs/playback-audit/PLAYBACK_AUDIT_REPORT.md): a link refresh
  // that finds a source while the viewer is moving to another episode. The
  // remote's next-track key reaches the player on the TV layout.
  group('episode switch during a link refresh', () {
    setUp(() {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
        supportsPictureInPicture: false,
      );
    });

    /// Plays S01E01 from [_first], makes it fail so a refresh starts, and
    /// asks for the next episode while the refresh still waits.
    Future<({StreamDiscovery refresh, List<EpisodeRef> asked})> startSwitch(
      WidgetTester tester,
      EpisodeSwitch onPlayEpisode,
    ) async {
      final lookup = StreamDiscovery()..add(_first);
      final refresh = StreamDiscovery();
      final asked = <EpisodeRef>[];
      engine.onCreate = (player) => player.initialize();
      await openPlayer(
        tester,
        sources: const [_first],
        discovery: lookup,
        onRediscover: () => refresh,
        onPlayEpisode: (target, handOff) {
          asked.add(target);
          return onPlayEpisode(target, handOff);
        },
      );
      await advance(tester);
      expect(showsVideo(), isTrue);
      await playFor(tester);
      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);
      // The refresh has no source yet: nothing new opened.
      expect(engine.players, hasLength(1));

      await pressNextEpisode(tester, asked: () => asked.isNotEmpty);
      expect(asked.map((ref) => ref.episode), [2]);
      return (refresh: refresh, asked: asked);
    }

    _testSession('a link found while the next episode is looked up does not '
        'reopen the old episode', (tester) async {
      final found = Completer<void>();
      EpisodeHandOff? handOff;
      final started = await startSwitch(tester, (target, offered) async {
        handOff = offered;
        await found.future;
      });

      started.refresh.add(_firstRenewed);
      await advance(tester);
      // Before the fix: S01E01 opened again (and played) behind the switch.
      expect(engine.players, hasLength(1));

      // The next episode's streams are found: this player lets go.
      await handOff!.release();
      await advance(tester);
      expect(engine.live, isEmpty);
      expect(engine.players, hasLength(1));
      await closePlayer(tester);
    });

    _testSession('when the next episode finds no stream, the old one resumes '
        'with the refreshed link, not the dead one', (tester) async {
      final found = Completer<void>();
      final started = await startSwitch(tester, (_, _) => found.future);

      started.refresh.add(_firstRenewed);
      await advance(tester);
      found.complete();
      await advance(tester);

      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _firstRenewed.url,
      ]);
      expect(engine.players.last.playCalls, 1);
      expect(showsVideo(), isTrue);
      await closePlayer(tester);
    });

    _testSession('when the new episode\'s player does not open after the '
        'engine was released, the old one resumes with the refreshed link', (
      tester,
    ) async {
      final found = Completer<void>();
      final started = await startSwitch(tester, (_, handOff) async {
        await found.future;
        await handOff.release();
        // Home could not open the new episode after all.
      });

      started.refresh.add(_firstRenewed);
      await advance(tester);
      found.complete();
      await advance(tester);

      expect(engine.players.map((player) => player.uri), [
        _first.url,
        _firstRenewed.url,
      ]);
      expect(engine.live.single.uri, _firstRenewed.url);
      expect(engine.players.last.playCalls, 1);
      await closePlayer(tester);
    });

    // The auto-next countdown keeps running if the stream drops during the
    // credits, so it can start the switch while a refresh waits.
    _testSession('the auto-next countdown moves on during a refresh without '
        'reopening the old episode', (tester) async {
      final playback = PlaybackSettingsController(storage: storage);
      await tester.runAsync(
        () =>
            playback.update(playback.value.copyWith(autoPlayNextEpisode: true)),
      );
      final lookup = StreamDiscovery()..add(_first);
      final refresh = StreamDiscovery();
      final asked = <EpisodeRef>[];
      final found = Completer<void>();
      EpisodeHandOff? handOff;
      engine.onCreate = (player) =>
          player.initialize(duration: const Duration(minutes: 10));
      await openPlayer(
        tester,
        sources: const [_first],
        discovery: lookup,
        onRediscover: () => refresh,
        playbackSettings: playback,
        onPlayEpisode: (target, offered) async {
          asked.add(target);
          handOff = offered;
          await found.future;
        },
      );
      await advance(tester);
      expect(showsVideo(), isTrue);

      // The credits: the next-episode card and its countdown appear.
      engine.players.single.position = const Duration(minutes: 9, seconds: 58);
      await advance(tester);
      expect(find.textContaining('Next episode ·'), findsOneWidget);

      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);
      expect(engine.players, hasLength(1));

      // The countdown runs out and the switch saves the position (real
      // file writes) before asking for the next episode.
      for (var i = 0; i < 40 && asked.isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(asked.map((ref) => ref.episode), [2]);

      refresh.add(_firstRenewed);
      await advance(tester);
      expect(engine.players, hasLength(1));

      // The next episode's streams are found: this player lets go.
      await handOff!.release();
      await advance(tester);
      expect(engine.live, isEmpty);
      expect(engine.players, hasLength(1));
      await closePlayer(tester);
    });

    // A Watch Party guest follows the host to another episode through
    // _PartyHandle.remoteEpisode, the same switch, while its own link is
    // being refreshed.
    _testSession('a guest following the host to the next episode during a '
        'refresh does not reopen the old episode', (tester) async {
      final (party, socket) = await _joinAsGuest(tester);
      addTearDown(() {
        party.dispose();
        WatchPartyController.active.value = null;
      });
      final lookup = StreamDiscovery()..add(_first);
      final refresh = StreamDiscovery();
      final asked = <EpisodeRef>[];
      EpisodeHandOff? handOff;
      engine.onCreate = (player) => player.initialize();
      await openPlayer(
        tester,
        sources: const [_first],
        discovery: lookup,
        onRediscover: () => refresh,
        onPlayEpisode: (target, offered) {
          asked.add(target);
          handOff = offered;
          return Completer<void>().future;
        },
      );
      await advance(tester);
      expect(showsVideo(), isTrue);

      await playFor(tester);
      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);
      expect(engine.players, hasLength(1));

      // The host moves the room to S01E02.
      await tester.runAsync(() async {
        socket.receive({'t': 'room', 'room': _partyRoom(episode: 2)});
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      for (var i = 0; i < 60 && asked.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(asked.map((ref) => ref.episode), [2]);

      refresh.add(_firstRenewed);
      await advance(tester);
      expect(engine.players, hasLength(1));

      await handOff!.release();
      await advance(tester);
      expect(engine.live, isEmpty);
      expect(engine.players, hasLength(1));
      await closePlayer(tester);
    });

    _testSession('a refresh with no switch still plays the renewed link at '
        'once', (tester) async {
      final lookup = StreamDiscovery()..add(_first);
      final refresh = StreamDiscovery();
      engine.onCreate = (player) => player.initialize();
      await openPlayer(
        tester,
        sources: const [_first],
        discovery: lookup,
        onRediscover: () => refresh,
        onPlayEpisode: (_, _) async {},
      );
      await advance(tester);
      await playFor(tester);
      engine.players.single.fail('Source error: response code: 403');
      await advance(tester);
      refresh.add(_firstRenewed);
      await advance(tester);

      expect(engine.players.last.uri, _firstRenewed.url);
      expect(engine.players.last.playCalls, 1);
      await closePlayer(tester);
    });

    _testSession('a next episode that finds no stream leaves the playing '
        'episode playing, and repeated presses ask once', (tester) async {
      final found = Completer<void>();
      final asked = <EpisodeRef>[];
      engine.onCreate = (player) => player.initialize();
      await openPlayer(
        tester,
        sources: const [_first],
        onPlayEpisode: (target, _) {
          asked.add(target);
          return found.future;
        },
      );
      await advance(tester);
      final playing = engine.players.single;
      expect(playing.playCalls, 1);

      await pressNextEpisode(tester, asked: () => asked.isNotEmpty);
      // A second press while the switch runs is ignored.
      await pressNextEpisode(tester, asked: () => asked.length > 1);
      expect(asked, hasLength(1));

      found.complete();
      await advance(tester);
      expect(engine.players, hasLength(1));
      expect(playing.disposed, isFalse);
      // Paused for the switch, then playing again.
      expect(playing.playCalls, 2);
      await closePlayer(tester);
    });
  });

  // PB-19 (docs/REELISH_PLAYBACK_AUDIT.md). The test device's language is
  // English and the preferred audio language is "device".
  _testSession(
    'opening keeps a playing track already in the preferred language',
    (tester) async {
      // As on an HLS stream with the audio inside each variant: the first
      // English track belongs to another variant than the playing one.
      engine.audioTracks = const [
        VideoAudioTrack(
          id: '1',
          label: null,
          language: 'en',
          isSelected: false,
        ),
        VideoAudioTrack(id: '6', label: null, language: 'en', isSelected: true),
      ];
      engine.onCreate = (player) => player.initialize();
      await openPlayer(tester, sources: const [_first]);
      await advance(tester);

      expect(showsVideo(), isTrue);
      expect(engine.audioSelections, isEmpty);
      await closePlayer(tester);
    },
  );

  _testSession('opening still switches to the preferred language', (
    tester,
  ) async {
    engine.audioTracks = const [
      VideoAudioTrack(id: '1', label: null, language: 'ja', isSelected: true),
      VideoAudioTrack(id: '2', label: null, language: 'en', isSelected: false),
    ];
    engine.onCreate = (player) => player.initialize();
    await openPlayer(tester, sources: const [_first]);
    await advance(tester);

    expect(showsVideo(), isTrue);
    expect(engine.audioSelections, ['2']);
    await closePlayer(tester);
  });
}

/// A session test on the platform whose engine is the registered fake.
void _testSession(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.linux),
);

/// The Watch Party room's side of the connection: messages in, sent ones
/// recorded.
class _PartySocket implements PartySocket {
  final _incoming = StreamController<dynamic>();

  @override
  int? closeCode;

  @override
  Stream<dynamic> get messages => _incoming.stream;

  @override
  void send(String text) {}

  void receive(Map<String, Object?> message) =>
      _incoming.add(jsonEncode(message));

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode ??= code;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// A room watching series 1, S01E01 (the session tests' title) at [episode].
Map<String, Object?> _partyRoom({required int episode}) => {
  'code': '12345678',
  'phase': 'watching',
  'content': {
    'tmdbId': 1,
    'type': 'series',
    'title': 'Clip',
    'season': 1,
    'episode': episode,
  },
  'settings': {'capacity': 5, 'guestControl': false, 'waitForAll': true},
  'host': {'pid': 'host-pid', 'name': 'Host', 'avatar': 'avatar2'},
  'hostConnected': true,
  'playback': {
    'status': 'playing',
    'positionMs': 0,
    'rate': 1,
    'at': DateTime.now().millisecondsSinceEpoch,
    'seq': episode,
    'by': 'host-pid',
  },
  'participants': [
    {
      'pid': 'host-pid',
      'name': 'Host',
      'avatar': 'avatar2',
      'host': true,
      'status': 'joined',
    },
  ],
};

/// Joins a party as a guest, with the room at S01E01. Runs on real time:
/// the connection and the sign-in it needs are real futures.
Future<(WatchPartyController, _PartySocket)> _joinAsGuest(
  WidgetTester tester,
) async {
  final socket = _PartySocket();
  late WatchPartyController party;
  await tester.runAsync(() async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient(
        (_) async => http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final account = AccountController(
      api: api,
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's1',
          accessToken: 'access-1',
          accessExpiresAt: now + 900,
          refreshToken: 'refresh-1',
          refreshExpiresAt: now + 86400,
          userId: 'u1',
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
    party = WatchPartyController(
      code: '12345678',
      account: account,
      api: api,
      profile: ProfileController(directory: () async => Directory.systemTemp),
      connector: (_, _) async => socket,
    );
    await party.start();
    socket.receive({
      't': 'welcome',
      'you': {'pid': 'guest-pid'},
      'room': _partyRoom(episode: 1),
      'serverTime': DateTime.now().millisecondsSinceEpoch,
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  return (party, socket);
}
