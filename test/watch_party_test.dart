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
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';
import 'package:onfeed/src/screens/watch_party/create_party_screen.dart';
import 'package:onfeed/src/screens/watch_party/join_party_screen.dart';
import 'package:onfeed/src/screens/watch_party/waiting_room_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/watch_party/party_models.dart';
import 'package:onfeed/src/watch_party/party_player_sync.dart';
import 'package:onfeed/src/watch_party/playback_sync.dart';
import 'package:onfeed/src/watch_party/watch_party_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session() => StoredSession(
  sessionId: 's1',
  accessToken: 'access-1',
  accessExpiresAt: _now() + 900,
  refreshToken: 'refresh-1',
  refreshExpiresAt: _now() + 86400,
  userId: 'u1',
  username: 'viewer',
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class FakeSocket implements PartySocket {
  final _incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  final raw = <String>[];
  @override
  int? closeCode;

  @override
  Stream<dynamic> get messages => _incoming.stream;

  @override
  void send(String text) {
    raw.add(text);
    if (text.startsWith('{')) {
      sent.add(jsonDecode(text) as Map<String, dynamic>);
    }
  }

  void receive(Map<String, Object?> message) =>
      _incoming.add(jsonEncode(message));

  /// The server closes with [code].
  Future<void> drop([int? code]) async {
    closeCode = code;
    await _incoming.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode ??= code;
    if (!_incoming.isClosed) await _incoming.close();
  }

  Iterable<Map<String, dynamic>> ofType(String t) =>
      sent.where((m) => m['t'] == t);
}

Map<String, Object?> _roomJson({
  String hostPid = 'host-pid',
  String phase = 'lobby',
  int seq = 0,
  bool guestControl = false,
}) => {
  'code': '12345678',
  'phase': phase,
  'content': {
    'tmdbId': 603,
    'type': 'movie',
    'title': 'The Matrix',
    'posterPath': '/m.jpg',
  },
  'settings': {'capacity': 5, 'guestControl': guestControl, 'waitForAll': true},
  'host': {'pid': hostPid, 'name': 'Host', 'avatar': 'avatar2'},
  'hostConnected': true,
  'playback': {
    'status': 'idle',
    'positionMs': 0,
    'rate': 1,
    'at': 1000,
    'seq': seq,
    'by': null,
  },
  'participants': [
    {
      'pid': hostPid,
      'name': 'Host',
      'avatar': 'avatar2',
      'host': true,
      'status': 'joined',
    },
  ],
};

Map<String, Object?> _welcome(
  String you, {
  String hostPid = 'host-pid',
  int seq = 0,
}) => {
  't': 'welcome',
  'you': {'pid': you},
  'room': _roomJson(hostPid: hostPid, seq: seq),
  'serverTime': DateTime.now().millisecondsSinceEpoch,
};

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('party models', () {
    test(
      'a catalog title becomes room content, keeping only the poster file',
      () {
        const movie = MediaItem(
          id: '603',
          type: 'movie',
          name: 'The Matrix',
          poster: 'https://image.tmdb.org/t/p/w500/abc123.jpg',
        );
        final content = PartyContent.fromItem(movie)!;
        expect(content.toJson(), {
          'tmdbId': 603,
          'type': 'movie',
          'title': 'The Matrix',
          'posterPath': '/abc123.jpg',
        });
        expect(content.posterUrl, 'https://image.tmdb.org/t/p/w500/abc123.jpg');

        const series = MediaItem(id: '1399', type: 'series', name: 'GoT');
        expect(
          PartyContent.fromItem(series),
          isNull,
          reason: 'needs an episode',
        );
        final episode = PartyContent.fromItem(series, season: 1, episode: 2)!;
        expect(episode.episodeLabel, 'S1 · E2');
        expect(
          PartyContent.fromItem(
            const MediaItem(id: 'tt1', type: 'movie', name: 'X'),
          ),
          isNull,
        );
      },
    );

    test('remote data is parsed defensively', () {
      expect(PartyRoom.fromJson('nonsense'), isNull);
      expect(
        PartyRoom.fromJson({
          'code': '1',
          'content': {'tmdbId': -1},
        }),
        isNull,
      );
      final room = PartyRoom.fromJson({
        ..._roomJson(),
        'participants': [
          42,
          {'pid': 'a', 'status': 'weird'},
        ],
        'playback': {'status': 'playing', 'positionMs': -50, 'seq': 'x'},
      })!;
      expect(room.participants.single.status, ParticipantStatus.joined);
      expect(room.playback.positionMs, 0);
      expect(room.playback.seq, 0);
      expect(
        PartyContent.fromJson({
          'tmdbId': 1,
          'type': 'movie',
          'posterPath': '../x',
        })!.posterPath,
        isNull,
      );
    });

    test('codes are read from typed or pasted text', () {
      expect(partyCodeFrom('1234 5678'), '12345678');
      expect(partyCodeFrom('Join my party: 1234-5678!'), '12345678');
      expect(partyCodeFrom('1234567'), isNull);
      expect(partyCodeFrom('123456789'), isNull);
      expect(formatPartyCode('12345678'), '1234 5678');
    });
  });

  group('playback sync', () {
    test('the clock keeps the shortest round trip', () {
      final clock = ClockSync()..seed(10_000, 9_000);
      expect(clock.offsetMs, 1000);
      clock.add(1000, 2600, 1400); // 400 ms round trip: offset 1400
      expect(clock.offsetMs, 1400);
      clock.add(2000, 3000, 2900); // slower: ignored
      expect(clock.offsetMs, 1400);
      clock.add(3000, 4150, 3100); // faster: offset 1100
      expect(clock.offsetMs, 1100);
      expect(clock.serverNow(5000), 6100);
    });

    test('the room timeline advances only while playing', () {
      const playing = PartyPlayback(
        status: PlaybackStatus.playing,
        positionMs: 10_000,
        at: 50_000,
        seq: 1,
      );
      expect(expectedPositionMs(playing, 53_000), 13_000);
      expect(
        expectedPositionMs(playing, 49_000),
        10_000,
        reason: 'never before its stamp',
      );
      const paused = PartyPlayback(
        status: PlaybackStatus.paused,
        positionMs: 10_000,
        at: 50_000,
        seq: 1,
      );
      expect(expectedPositionMs(paused, 90_000), 10_000);
    });

    test('small gaps are ignored, medium ones nudged, large ones sought', () {
      expect(decideSync(300), SyncAction.none);
      expect(decideSync(-300), SyncAction.none);
      expect(decideSync(1200), SyncAction.slowDown);
      expect(decideSync(-1200), SyncAction.speedUp);
      expect(decideSync(3500), SyncAction.seek);
      expect(decideSync(-3500), SyncAction.seek);
      // A nudge continues until the gap has settled, so speed does not flap.
      expect(decideSync(300, nudging: true), SyncAction.slowDown);
      expect(decideSync(100, nudging: true), SyncAction.none);
    });
  });

  group('WatchPartyController', () {
    late List<FakeSocket> sockets;
    late List<String> tokens;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      sockets = [];
      tokens = [];
    });

    tearDown(() => WatchPartyController.active.value = null);

    Future<WatchPartyController> joined({
      MockClientHandler? http,
      Future<PartySocket> Function(Uri uri, String token)? connector,
    }) async {
      final api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient(http ?? (_) async => _json({})),
      );
      final account = AccountController(
        api: api,
        store: MemorySessionStore(_session()),
      );
      await account.restore();
      final profile = ProfileController(
        directory: () async => Directory.systemTemp,
      );
      await profile.loadFor('u1');
      await profile.setDisplayName('Franz');
      await profile.setAvatar(const ProfileAvatar.preset('avatar4'));
      final controller = WatchPartyController(
        code: '12345678',
        account: account,
        api: api,
        profile: profile,
        backoff: (_) => Duration.zero,
        connector:
            connector ??
            (uri, token) async {
              expect(
                uri.toString(),
                'wss://api.reelish.test/api/v1/party/12345678/socket',
              );
              tokens.add(token);
              final socket = FakeSocket();
              sockets.add(socket);
              return socket;
            },
      );
      await controller.start();
      return controller;
    }

    test(
      'joins with the session token, says hello and checks the clock',
      () async {
        final party = await joined();
        expect(tokens, ['access-1']);
        expect(WatchPartyController.active.value, party);
        sockets.single.receive(_welcome('guest-pid'));
        await _settle();
        expect(party.connection, PartyConnection.connected);
        expect(party.room!.content.title, 'The Matrix');
        expect(party.isHost, isFalse);
        expect(party.canControl, isFalse);
        expect(sockets.single.ofType('hello').single, {
          't': 'hello',
          'name': 'Franz',
          'avatar': 'avatar4',
        });
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(sockets.single.ofType('time'), hasLength(3));
        party.dispose();
      },
    );

    test('takes only newer timelines and passes them to the player', () async {
      final party = await joined();
      final socket = sockets.single;
      socket.receive(_welcome('guest-pid', seq: 2));
      await _settle();
      final seen = <int>[];
      final sub = party.playbackChanges.listen((p) => seen.add(p.seq));
      socket.receive({
        't': 'state',
        'playback': {
          'status': 'playing',
          'positionMs': 5000,
          'at': 1,
          'seq': 3,
        },
      });
      socket.receive({
        't': 'state',
        'playback': {'status': 'paused', 'positionMs': 1, 'at': 1, 'seq': 1},
      });
      // A heartbeat repeats the current sequence with a fresh position.
      socket.receive({
        't': 'state',
        'playback': {
          'status': 'playing',
          'positionMs': 9000,
          'at': 2,
          'seq': 3,
        },
      });
      await _settle();
      expect(seen, [3, 3]);
      expect(party.room!.playback.positionMs, 9000);
      await sub.cancel();
      party.dispose();
    });

    test('guests cannot send host actions; the host can', () async {
      final guest = await joined();
      sockets.last.receive(_welcome('guest-pid'));
      await _settle();
      guest
        ..control('play', 0)
        ..startWatching()
        ..remove('x')
        ..updateSettings(guestControl: true);
      expect(
        sockets.last.sent.where((m) => m['t'] != 'hello' && m['t'] != 'time'),
        isEmpty,
      );
      guest.dispose();

      final host = await joined();
      sockets.last.receive(_welcome('host-pid'));
      await _settle();
      expect(host.isHost, isTrue);
      host
        ..startWatching()
        ..updateSettings(guestControl: true)
        ..remove('guest')
        ..remove('host-pid')
        ..control('pause', 1234);
      final sent = sockets.last.sent.map((m) => m['t']).toList();
      expect(
        sent,
        containsAllInOrder(['start', 'settings', 'kick', 'control']),
      );
      expect(sockets.last.ofType('kick'), hasLength(1), reason: 'never itself');
      expect(sockets.last.ofType('settings').single, {
        't': 'settings',
        'guestControl': true,
      });
      expect(sockets.last.ofType('control').single['positionMs'], 1234);
      host.dispose();
    });

    test(
      'reconnects after a dropped connection and resends its status',
      () async {
        final party = await joined();
        sockets.first.receive(_welcome('guest-pid'));
        await _settle();
        party.reportStatus(ParticipantStatus.buffering);
        await sockets.first.drop(1006);
        await _settle();
        expect(sockets, hasLength(2));
        sockets.last.receive(_welcome('guest-pid'));
        await _settle();
        expect(party.connection, PartyConnection.connected);
        expect(sockets.last.ofType('status').single['state'], 'buffering');
        party.dispose();
      },
    );

    test('ends on the room\'s close codes without reconnecting', () async {
      for (final (code, reason) in [
        (4000, PartyEndReason.ended),
        (4001, PartyEndReason.replaced),
        (4003, PartyEndReason.removed),
      ]) {
        final party = await joined();
        sockets.last.receive(_welcome('guest-pid'));
        await _settle();
        final before = sockets.length;
        await sockets.last.drop(code);
        await _settle();
        expect(party.endReason, reason);
        expect(party.connection, PartyConnection.ended);
        expect(sockets.length, before);
        expect(WatchPartyController.active.value, isNull);
        party.dispose();
      }
    });

    test('a code that opens nothing ends with not found', () async {
      final party = await joined(
        http: (request) async => _json({
          'error': {'code': 'party_not_found', 'message': 'No party.'},
        }, 404),
        connector: (_, _) async =>
            throw const WebSocketException('not upgraded'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(party.endReason, PartyEndReason.notFound);
      party.dispose();
    });

    test('leaving tells the room and closes', () async {
      final party = await joined();
      final socket = sockets.single;
      socket.receive(_welcome('guest-pid'));
      await _settle();
      await party.leave();
      expect(socket.ofType('leave'), hasLength(1));
      expect(socket.closeCode, 1000);
      expect(party.endReason, PartyEndReason.left);
      party.dispose();
    });

    test('signing out leaves the party', () async {
      final socket = FakeSocket();
      final api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient((_) async => _json({})),
      );
      final account = AccountController(
        api: api,
        store: MemorySessionStore(_session()),
      );
      await account.restore();
      final party = WatchPartyController(
        code: '12345678',
        account: account,
        api: api,
        profile: ProfileController(directory: () async => Directory.systemTemp),
        connector: (_, _) async => socket,
      );
      await party.start();
      socket.receive(_welcome('guest-pid'));
      await _settle();
      await account.signOut();
      await _settle();
      expect(party.endReason, PartyEndReason.signedOut);
      expect(socket.ofType('leave'), hasLength(1));
      expect(socket.closeCode, 1000);
      expect(WatchPartyController.active.value, isNull);
      party.dispose();
    });

    test('gives up only after the outage limit', () async {
      final sockets = <FakeSocket>[];
      final api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient((_) async => _json({})),
      );
      final account = AccountController(
        api: api,
        store: MemorySessionStore(_session()),
      );
      await account.restore();
      final party = WatchPartyController(
        code: '12345678',
        account: account,
        api: api,
        profile: ProfileController(directory: () async => Directory.systemTemp),
        backoff: (_) => Duration.zero,
        maxOutage: Duration.zero,
        connector: (_, _) async {
          final socket = FakeSocket();
          sockets.add(socket);
          return socket;
        },
      );
      await party.start();
      sockets.single.receive(_welcome('guest-pid'));
      await _settle();
      await sockets.single.drop(1006);
      await _settle();
      expect(party.endReason, PartyEndReason.failed);
      expect(sockets, hasLength(1));
      party.dispose();
    });

    test('joining another party leaves the current one', () async {
      final first = await joined();
      sockets.first.receive(_welcome('guest-pid'));
      await _settle();
      final second = await joined();
      expect(first.endReason, PartyEndReason.left);
      expect(WatchPartyController.active.value, second);
      first.dispose();
      second.dispose();
    });
  });

  group('watch party screens', () {
    const preview = PartyPreview(
      code: '12345678',
      phase: PartyPhase.lobby,
      content: PartyContent(tmdbId: 603, type: 'movie', title: 'The Matrix'),
      hostName: 'Host',
      participants: 2,
      capacity: 5,
    );

    Widget app(Widget home) => MaterialApp(theme: GlassTheme.dark, home: home);

    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('join looks up a complete code and shows the party', (
      tester,
    ) async {
      final looked = <String>[];
      String? opened;
      await tester.pumpWidget(
        app(
          JoinPartyScreen(
            preview: (code) async {
              looked.add(code);
              return preview;
            },
            open: (_, code) => opened = code,
          ),
        ),
      );
      final join = find.widgetWithText(FilledButton, 'Join party');
      expect(tester.widget<FilledButton>(join).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '1234 56ab78');
      await tester.pumpAndSettle();
      expect(looked, ['12345678'], reason: 'digits only, looked up once');
      expect(find.text('The Matrix'), findsOneWidget);
      expect(
        find.textContaining('Hosted by Host · 2/5 people'),
        findsOneWidget,
      );
      await tester.tap(join);
      expect(opened, '12345678');
    });

    testWidgets('join pastes a code out of a message, and explains errors', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'Join my party: 8765-4321'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        app(
          JoinPartyScreen(
            preview: (code) async => throw const AccountApiException(
              'party_not_found',
              'x',
              status: 404,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Paste code'));
      await tester.pumpAndSettle();
      expect(find.text('87654321'), findsOneWidget);
      expect(
        find.text('No party has that code. Check it and try again.'),
        findsOneWidget,
      );
    });

    testWidgets('on TV the code is entered with the remote\'s keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.reset);
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final looked = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          home: JoinPartyScreen(
            preview: (code) async {
              looked.add(code);
              return preview;
            },
          ),
        ),
      );
      expect(find.byType(TvTextField), findsOneWidget);
      expect(find.text('Paste code'), findsNothing);
      // Select opens the TV keyboard dialog.
      tester.widget<TvFocusable>(find.byType(TvFocusable).first).onSelect!();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '12345678');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(looked, ['12345678']);
      expect(find.text('1234 5678'), findsOneWidget);
      expect(find.text('The Matrix'), findsOneWidget);
    });

    testWidgets('a full party cannot be joined', (tester) async {
      await tester.pumpWidget(
        app(
          JoinPartyScreen(
            preview: (_) async => const PartyPreview(
              code: '12345678',
              phase: PartyPhase.watching,
              content: PartyContent(tmdbId: 1, type: 'movie', title: 'X'),
              hostName: 'Host',
              participants: 5,
              capacity: 5,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '12345678');
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, 'This party is full');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.textContaining('watching now'), findsOneWidget);
    });

    testWidgets('create sends the chosen room settings', (tester) async {
      PartySettings? sent;
      String? opened;
      await tester.pumpWidget(
        app(
          CreatePartyScreen(
            content: const PartyContent(
              tmdbId: 1399,
              type: 'series',
              title: 'GoT',
              season: 1,
              episode: 2,
            ),
            create:
                ({required content, settings = const PartySettings()}) async {
                  sent = settings;
                  return '11112222';
                },
            open: (_, code) => opened = code,
          ),
        ),
      );
      expect(find.text('S1 · E2'), findsOneWidget);
      await tester.tap(find.byTooltip('Fewer people'));
      await tester.tap(find.text('Everyone can play and pause'));
      await tester.pump();
      await tester.tap(find.text('Create party'));
      await tester.pumpAndSettle();
      expect(opened, '11112222');
      expect(sent!.capacity, 4);
      expect(sent!.guestControl, isTrue);
      expect(sent!.waitForAll, isTrue);
    });

    testWidgets(
      'Windows: create keeps its action beside the form, not across the window',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        PartySettings? sent;
        String? opened;
        await tester.pumpWidget(
          app(
            CreatePartyScreen(
              content: const PartyContent(
                tmdbId: 1,
                type: 'movie',
                title: 'Film',
              ),
              create:
                  ({required content, settings = const PartySettings()}) async {
                    sent = settings;
                    return '11112222';
                  },
              open: (_, code) => opened = code,
            ),
          ),
        );
        final button = find.widgetWithText(FilledButton, 'Create party');
        expect(tester.getSize(button).width, lessThan(400));
        expect(find.text('Watch in sync'), findsOneWidget);
        await tester.tap(find.text('Wait for everyone'));
        await tester.pump();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(opened, '11112222');
        expect(sent!.waitForAll, isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'Windows: the code boxes take typing and pasted invitations',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {'text': 'Enter 8765-4321 in Join a party'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final looked = <String>[];
        String? opened;
        await tester.pumpWidget(
          app(
            JoinPartyScreen(
              preview: (code) async {
                looked.add(code);
                return preview;
              },
              open: (_, code) => opened = code,
            ),
          ),
        );
        final join = find.widgetWithText(FilledButton, 'Join party');
        expect(tester.widget<FilledButton>(join).onPressed, isNull);
        await tester.enterText(find.byType(TextField), '1234');
        await tester.pump();
        expect(find.text('4'), findsOneWidget, reason: 'shown in the boxes');
        expect(looked, isEmpty);

        await tester.tap(find.text('Paste code'));
        await tester.pumpAndSettle();
        expect(looked, ['87654321']);
        expect(find.text('The Matrix'), findsOneWidget);
        await tester.tap(join);
        // The room the server described (this fake always answers one).
        expect(opened, preview.code);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('create says why it failed', (tester) async {
      await tester.pumpWidget(
        app(
          CreatePartyScreen(
            content: const PartyContent(tmdbId: 1, type: 'movie', title: 'X'),
            create: ({required content, settings = const PartySettings()}) =>
                throw const AccountApiException('party_unavailable', 'x'),
          ),
        ),
      );
      await tester.tap(find.text('Create party'));
      await tester.pumpAndSettle();
      expect(
        find.text('Watch Party is unavailable right now. Try again later.'),
        findsOneWidget,
      );
    });

    Future<(WatchPartyController, FakeSocket)> connected(
      WidgetTester tester,
    ) async {
      late WatchPartyController party;
      final socket = FakeSocket();
      await tester.runAsync(() async {
        final api = AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((_) async => _json({})),
        );
        final account = AccountController(
          api: api,
          store: MemorySessionStore(_session()),
        );
        await account.restore();
        party = WatchPartyController(
          code: '12345678',
          account: account,
          api: api,
          profile: ProfileController(
            directory: () async => Directory.systemTemp,
          ),
          connector: (_, _) async => socket,
        );
        await party.start();
      });
      return (party, socket);
    }

    Future<void> deliver(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }

    testWidgets('the waiting room shows the code, people and host tools', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      final (party, socket) = await connected(tester);
      await tester.pumpWidget(app(WaitingRoomScreen(party: party)));
      socket.receive({
        't': 'welcome',
        'you': {'pid': 'host-pid'},
        'room': {
          ..._roomJson(),
          'participants': [
            {
              'pid': 'host-pid',
              'name': 'Host',
              'host': true,
              'status': 'ready',
            },
            {'pid': 'g', 'name': 'Guest', 'status': 'unavailable'},
          ],
        },
        'serverTime': 0,
      });
      await deliver(tester);
      expect(find.text('1234 5678'), findsOneWidget);
      expect(find.text('Host (you)'), findsOneWidget);
      expect(find.text('Can’t play this title'), findsOneWidget);
      expect(find.text('HOST'), findsOneWidget);
      // Leave and Start share the bar; the leave button is always there.
      expect(find.widgetWithText(OutlinedButton, 'Leave'), findsOneWidget);

      await tester.tap(find.byTooltip('Options for Guest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from party'));
      await tester.pumpAndSettle();
      expect(socket.ofType('kick').single['pid'], 'g');

      await tester.ensureVisible(find.text('Wait for everyone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wait for everyone'));
      await tester.pump();
      expect(socket.ofType('settings').single['waitForAll'], isFalse);

      // Ending the party for everyone sits apart, at the end of the page,
      // and asks first.
      await tester.scrollUntilVisible(
        find.text('End party'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('End party'));
      await tester.pumpAndSettle();
      expect(find.text('End the party?'), findsOneWidget);
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(socket.ofType('end'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'Windows: the waiting room keeps its actions in one row, not across '
      'the window',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final (party, socket) = await connected(tester);
        await tester.pumpWidget(app(WaitingRoomScreen(party: party)));
        socket.receive(_welcome('host-pid'));
        await deliver(tester);
        final start = find.widgetWithText(FilledButton, 'Start watching');
        expect(tester.getSize(start).width, lessThan(400));
        final leave = find.widgetWithText(OutlinedButton, 'Leave');
        expect(tester.getCenter(leave).dy, tester.getCenter(start).dy);
        expect(find.text('End party'), findsOneWidget);
        expect(find.text('1234 5678'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('starting opens everyone\'s player once, and says when no '
        'source was found', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      final (party, socket) = await connected(tester);
      final opened = <PartyContent>[];
      final closePlayer = Completer<void>();
      await tester.pumpWidget(
        app(
          WaitingRoomScreen(
            party: party,
            openPlayer: (_, content) {
              opened.add(content);
              return closePlayer.future;
            },
          ),
        ),
      );
      socket.receive(_welcome('host-pid'));
      await deliver(tester);
      await tester.tap(find.text('Start watching'));
      expect(socket.ofType('start'), hasLength(1));

      socket.receive({
        't': 'room',
        'room': {..._roomJson(), 'phase': 'watching'},
      });
      await deliver(tester);
      await tester.pump();
      expect(opened.single.title, 'The Matrix');
      expect(find.text('Opening the player…'), findsOneWidget);
      expect(socket.ofType('status').last['state'], 'loading');

      // Another room update while the player is open does not reopen it.
      socket.receive({
        't': 'room',
        'room': {..._roomJson(), 'phase': 'watching'},
      });
      await deliver(tester);
      expect(opened, hasLength(1));

      // The search ended without a player: no source on this device.
      closePlayer.complete();
      await deliver(tester);
      await tester.pump();
      expect(socket.ofType('status').last['state'], 'unavailable');
      expect(find.text('Back to the player'), findsOneWidget);
      expect(opened, hasLength(1), reason: 'closing does not reopen it');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the waiting room says when the party ended', (tester) async {
      final (party, socket) = await connected(tester);
      await tester.pumpWidget(app(WaitingRoomScreen(party: party)));
      socket.receive(_welcome('guest-pid'));
      await deliver(tester);
      expect(find.text('End party'), findsNothing, reason: 'guests only leave');
      socket.receive({'t': 'removed'});
      await deliver(tester);
      expect(find.text('The host removed you from the party.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('PartyPlayerSync', () {
    var now = 0;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      now = DateTime.now().millisecondsSinceEpoch;
    });
    tearDown(() => WatchPartyController.active.value = null);

    Future<(WatchPartyController, FakeSocket)> party({
      required String you,
      String hostPid = 'host-pid',
      Map<String, Object?> room = const {},
    }) async {
      final socket = FakeSocket();
      final api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient((_) async => _json({})),
      );
      final account = AccountController(
        api: api,
        store: MemorySessionStore(_session()),
      );
      await account.restore();
      final controller = WatchPartyController(
        code: '12345678',
        account: account,
        api: api,
        profile: ProfileController(directory: () async => Directory.systemTemp),
        connector: (_, _) async => socket,
      );
      await controller.start();
      socket.receive({
        't': 'welcome',
        'you': {'pid': you},
        'room': {
          ..._roomJson(hostPid: hostPid),
          'phase': 'watching',
          'playback': {
            'status': 'paused',
            'positionMs': 0,
            'at': now,
            'seq': 1,
            'by': hostPid,
          },
          ...room,
        },
        'serverTime': now,
      });
      await _settle();
      // The device clock and the server's agree exactly in these tests.
      controller.clock.add(now, now, now);
      return (controller, socket);
    }

    PartyPlayerSync syncFor(WatchPartyController controller) => PartyPlayerSync(
      controller,
      clock: () => now,
      checkEvery: const Duration(hours: 1),
      heartbeatEvery: const Duration(hours: 1),
    );

    void state(FakeSocket socket, Map<String, Object?> playback) =>
        socket.receive({'t': 'state', 'playback': playback});

    test('finds the active party only for its own title', () async {
      final (controller, _) = await party(you: 'guest-pid');
      expect(PartyPlayerSync.forTitle(id: '603', type: 'movie'), isNotNull);
      expect(PartyPlayerSync.forTitle(id: '604', type: 'movie'), isNull);
      expect(PartyPlayerSync.forTitle(id: '603', type: 'series'), isNull);
      controller.dispose();
      expect(PartyPlayerSync.forTitle(id: '603', type: 'movie'), isNull);
    });

    test(
      'a guest holds until the host starts, then joins at the host\'s place',
      () async {
        final (controller, socket) = await party(you: 'guest-pid');
        final sync = syncFor(controller);
        final player = FakePlayer()..playing = true;
        sync.attach(player);
        player.ready = true;
        sync.playerChanged();
        // The player auto-plays on open; the room has not started.
        expect(player.commands, ['pause']);
        expect(sync.state, PartySyncState.waitingForHost);
        expect(socket.ofType('status').last['state'], 'ready');

        now += 2000;
        state(socket, {
          'status': 'playing',
          'positionMs': 60_000,
          'at': now - 1000,
          'seq': 2,
          'by': 'host-pid',
        });
        await _settle();
        expect(player.commands, ['pause', 'seek 61000', 'play']);
        expect(
          socket.ofType('control'),
          isEmpty,
          reason: 'nothing echoed back',
        );
        sync.dispose();
        controller.dispose();
      },
    );

    test('a remote pause pauses the guest without sending a command', () async {
      final (controller, socket) = await party(
        you: 'guest-pid',
        room: {
          'playback': {
            'status': 'playing',
            'positionMs': 10_000,
            'at': now,
            'seq': 2,
            'by': 'host-pid',
          },
        },
      );
      final sync = syncFor(controller);
      final player = FakePlayer()
        ..ready = true
        ..playing = true
        ..position = const Duration(milliseconds: 10_000);
      sync.attach(player);
      sync.playerChanged();
      player.commands.clear();
      state(socket, {
        'status': 'paused',
        'positionMs': 10_200,
        'at': now,
        'seq': 3,
        'by': 'host-pid',
      });
      await _settle();
      expect(player.commands, ['pause']);
      expect(socket.ofType('control'), isEmpty);
      sync.dispose();
      controller.dispose();
    });

    test('drift is ignored, nudged or sought by size', () async {
      final (controller, socket) = await party(
        you: 'guest-pid',
        room: {
          'playback': {
            'status': 'playing',
            'positionMs': 100_000,
            'at': now,
            'seq': 2,
            'by': 'host-pid',
          },
        },
      );
      final sync = syncFor(controller);
      final player = FakePlayer()
        ..ready = true
        ..playing = true;
      sync.attach(player);

      Future<List<String>> at(int localMs) async {
        player
          ..position = Duration(milliseconds: localMs)
          ..commands.clear();
        // A heartbeat with the same timeline triggers a check.
        state(socket, {
          'status': 'playing',
          'positionMs': 100_000,
          'at': now,
          'seq': 2,
          'by': 'host-pid',
        });
        await _settle();
        return List.of(player.commands);
      }

      expect(await at(100_300), isEmpty);
      expect(await at(98_800), ['speed 1.05']);
      expect(await at(99_800), isEmpty, reason: 'nudging until settled');
      expect(await at(99_950), ['speed 1.0']);
      expect(await at(101_200), ['speed 0.95']);
      expect(await at(96_000), ['speed 1.0', 'seek 100000']);
      expect(sync.state, PartySyncState.catchingUp);
      sync.dispose();
      controller.dispose();
    });

    test('guests cannot control unless the host allows it', () async {
      final (controller, socket) = await party(you: 'guest-pid');
      final sync = syncFor(controller);
      final player = FakePlayer()..ready = true;
      sync.attach(player);
      expect(sync.allowLocal(), isFalse);
      expect(player.notices.single, 'Host controls playback.');
      expect(sync.allowEpisodeChange(), isFalse);
      sync.localPlay(Duration.zero);
      expect(socket.ofType('control'), isEmpty);
      sync.dispose();
      controller.dispose();
    });

    test('the host waits for everyone, then starts the room', () async {
      final (controller, socket) = await party(
        you: 'host-pid',
        room: {
          'participants': [
            {
              'pid': 'host-pid',
              'name': 'Host',
              'host': true,
              'status': 'ready',
            },
            {'pid': 'g', 'name': 'Guest', 'status': 'loading'},
          ],
        },
      );
      final sync = syncFor(controller);
      final player = FakePlayer()..position = const Duration(seconds: 5);
      sync.attach(player);
      player.ready = true;
      sync.playerChanged();
      expect(sync.state, PartySyncState.waitingForEveryone);
      expect(partySyncLabel(sync), 'Waiting for everyone · 1/2 ready');
      expect(socket.ofType('control'), isEmpty);

      socket.receive({
        't': 'participants',
        'participants': [
          {'pid': 'host-pid', 'name': 'Host', 'host': true, 'status': 'ready'},
          {'pid': 'g', 'name': 'Guest', 'status': 'ready'},
        ],
      });
      await _settle();
      final control = socket.ofType('control').single;
      expect(control['action'], 'play');
      expect(control['positionMs'], 5000);
      expect(player.commands, ['play']);
      sync.dispose();
      controller.dispose();
    });

    test('the host starts anyway after the wait limit', () async {
      final (controller, socket) = await party(
        you: 'host-pid',
        room: {
          'participants': [
            {
              'pid': 'host-pid',
              'name': 'Host',
              'host': true,
              'status': 'ready',
            },
            {'pid': 'g', 'name': 'Guest', 'status': 'loading'},
          ],
        },
      );
      final sync = syncFor(controller);
      final player = FakePlayer();
      sync.attach(player);
      player.ready = true;
      sync.playerChanged();
      now += 46_000;
      socket.receive({'t': 'error', 'code': 'nudge'}); // any room update
      await _settle();
      expect(socket.ofType('control').single['action'], 'play');
      sync.dispose();
      controller.dispose();
    });

    test(
      'the host\'s own pause is not undone before the room echoes it',
      () async {
        final (controller, socket) = await party(
          you: 'host-pid',
          room: {
            'playback': {
              'status': 'playing',
              'positionMs': 0,
              'at': now,
              'seq': 2,
              'by': 'host-pid',
            },
          },
        );
        final sync = syncFor(controller);
        final player = FakePlayer()
          ..ready = true
          ..playing = true;
        sync.attach(player);
        player
          ..playing = false
          ..commands.clear();
        sync.localPause(const Duration(seconds: 7));
        expect(socket.ofType('control').single['action'], 'pause');
        // The old "playing" timeline arrives again before the echo.
        state(socket, {
          'status': 'playing',
          'positionMs': 0,
          'at': now,
          'seq': 2,
          'by': 'host-pid',
        });
        await _settle();
        expect(player.commands, isEmpty);
        sync.dispose();
        controller.dispose();
      },
    );

    test('a guest follows the host to another episode', () async {
      final (controller, socket) = await party(
        you: 'guest-pid',
        room: {
          'content': {
            'tmdbId': 1399,
            'type': 'series',
            'title': 'GoT',
            'season': 1,
            'episode': 2,
          },
        },
      );
      final sync = syncFor(controller);
      final player = FakePlayer()
        ..ready = true
        ..season = 1
        ..episode = 2;
      sync.attach(player);
      socket.receive({
        't': 'room',
        'room': {
          ..._roomJson(),
          'phase': 'watching',
          'content': {
            'tmdbId': 1399,
            'type': 'series',
            'title': 'GoT',
            'season': 1,
            'episode': 3,
          },
          'playback': {
            'status': 'paused',
            'positionMs': 0,
            'at': now,
            'seq': 4,
          },
        },
      });
      await _settle();
      expect(player.commands, ['episode 1:3']);
      sync.dispose();
      controller.dispose();
    });

    test('reports a player that found nothing to play', () async {
      final (controller, socket) = await party(you: 'guest-pid');
      final sync = syncFor(controller);
      final player = FakePlayer()..failed = true;
      sync.attach(player);
      sync.playerChanged();
      expect(socket.ofType('status').last['state'], 'unavailable');
      sync.dispose();
      expect(
        socket.ofType('status').last['state'],
        'unavailable',
        reason: 'closing the player keeps the room told',
      );
      expect(sync.state, PartySyncState.unavailable);
      controller.dispose();
    });
  });
}

/// A player for sync tests: records the remote commands it receives.
class FakePlayer implements PartyPlayerHandle {
  @override
  bool ready = false;
  @override
  bool playing = false;
  @override
  bool buffering = false;
  @override
  bool failed = false;
  @override
  Duration position = Duration.zero;
  @override
  int? season;
  @override
  int? episode;
  final commands = <String>[];
  final notices = <String>[];
  double speed = 1;

  @override
  Future<void> remotePlay() async {
    commands.add('play');
    playing = true;
  }

  @override
  Future<void> remotePause() async {
    commands.add('pause');
    playing = false;
  }

  @override
  Future<void> remoteSeek(Duration to) async {
    commands.add('seek ${to.inMilliseconds}');
    position = to;
  }

  @override
  Future<void> remoteSpeed(double rate) async {
    commands.add('speed $rate');
    speed = rate;
  }

  @override
  void remoteEpisode(int season, int episode) =>
      commands.add('episode $season:$episode');

  @override
  void notice(String message) => notices.add(message);
}
