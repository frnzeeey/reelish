// Watch Party 2.0: how viewer actions reach the room (coalesced, confirmed),
// presence pings, reactions, chat and invitation links.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/profile_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/screens/watch_party/join_party_screen.dart';
import 'package:onfeed/src/screens/watch_party/waiting_room_screen.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/watch_party/party_links.dart';
import 'package:onfeed/src/watch_party/party_models.dart';
import 'package:onfeed/src/watch_party/party_player_sync.dart';
import 'package:onfeed/src/watch_party/watch_party_controller.dart';
import 'package:onfeed/src/widgets/player/party_activity.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class _Socket implements PartySocket {
  final _incoming = StreamController<dynamic>();
  final raw = <String>[];
  @override
  int? closeCode;

  @override
  Stream<dynamic> get messages => _incoming.stream;

  @override
  void send(String text) => raw.add(text);

  List<Map<String, dynamic>> get sent => [
    for (final text in raw)
      if (text.startsWith('{')) jsonDecode(text) as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> ofType(String t) =>
      sent.where((m) => m['t'] == t).toList();

  void receive(Object message) =>
      _incoming.add(message is String ? message : jsonEncode(message));

  Future<void> drop() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode ??= code;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

Future<void> _settle([int ms = 10]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

Map<String, Object?> _welcome({
  required String you,
  String hostPid = 'host-pid',
  String status = 'paused',
  int positionMs = 0,
  int seq = 1,
  int? at,
  List<String>? features = const ['reactions', 'chat'],
  bool guestControl = false,
}) {
  final now = at ?? DateTime.now().millisecondsSinceEpoch;
  return {
    't': 'welcome',
    'you': {'pid': you},
    'serverTime': now,
    'features': ?features,
    'room': {
      'code': '12345678',
      'phase': 'watching',
      'content': {'tmdbId': 603, 'type': 'movie', 'title': 'The Matrix'},
      'settings': {
        'capacity': 5,
        'guestControl': guestControl,
        'waitForAll': false,
      },
      'host': {'pid': hostPid, 'name': 'Host', 'avatar': null},
      'hostConnected': true,
      'playback': {
        'status': status,
        'positionMs': positionMs,
        'rate': 1,
        'at': now,
        'seq': seq,
        'by': hostPid,
      },
      'participants': [
        {'pid': hostPid, 'name': 'Host', 'host': true, 'status': 'playing'},
        {'pid': 'guest-pid', 'name': 'Sam', 'host': false, 'status': 'playing'},
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<_Socket> sockets;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sockets = [];
  });
  tearDown(() => WatchPartyController.active.value = null);

  Future<WatchPartyController> start({
    Duration controlInterval = const Duration(milliseconds: 200),
    Duration textPingInterval = const Duration(hours: 1),
    Duration silenceLimit = const Duration(seconds: 35),
    Duration backoff = Duration.zero,
  }) async {
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    final account = AccountController(
      api: api,
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's1',
          accessToken: 'access-1',
          accessExpiresAt: _now() + 900,
          refreshToken: 'refresh-1',
          refreshExpiresAt: _now() + 86400,
          userId: 'u1',
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
    final controller = WatchPartyController(
      code: '12345678',
      account: account,
      api: api,
      profile: ProfileController(directory: () async => Directory.systemTemp),
      backoff: (_) => backoff,
      controlInterval: controlInterval,
      textPingInterval: textPingInterval,
      silenceLimit: silenceLimit,
      connector: (_, _) async {
        final socket = _Socket();
        sockets.add(socket);
        return socket;
      },
    );
    await controller.start();
    return controller;
  }

  group('viewer actions', () {
    test('a held seek key reaches the room as the first press and the last, '
        'not one message per repeat', () async {
      final party = await start();
      sockets.single.receive(_welcome(you: 'host-pid'));
      await _settle();
      // Twelve key repeats, about 30 a second.
      for (var i = 1; i <= 12; i++) {
        party.control('seek', i * 10000);
        await _settle(30);
      }
      final early = sockets.single.ofType('control');
      expect(early.length, lessThan(4), reason: 'held back, not flooded');
      expect(early.first['positionMs'], 10000);
      expect(party.controlPending, isTrue);
      await _settle(250);
      final sent = sockets.single.ofType('control');
      expect(sent.last['positionMs'], 120000, reason: 'the last press wins');
      expect(sent.length, lessThanOrEqualTo(4));
      party.dispose();
    });

    test('a seek held back while playing is sent from where playback has '
        'reached; one while paused stays put', () async {
      final party = await start(
        controlInterval: const Duration(milliseconds: 150),
      );
      sockets.single.receive(_welcome(you: 'host-pid', status: 'playing'));
      await _settle();
      party
        ..control('seek', 1000)
        ..control('seek', 50000);
      await _settle(250);
      final playing = sockets.single.ofType('control');
      expect(playing, hasLength(2));
      expect(playing.last['positionMs'] as int, greaterThan(50000));
      party.dispose();

      final paused = await start(
        controlInterval: const Duration(milliseconds: 150),
      );
      sockets.last.receive(_welcome(you: 'host-pid'));
      await _settle();
      paused
        ..control('seek', 1000)
        ..control('seek', 50000);
      await _settle(250);
      expect(sockets.last.ofType('control').last['positionMs'], 50000);
      paused.dispose();
    });

    test(
      'a seek made offline while paused is sent where it was made',
      () async {
        final party = await start(backoff: const Duration(milliseconds: 60));
        sockets[0].receive(_welcome(you: 'host-pid'));
        await _settle();
        await sockets[0].drop();
        await _settle();
        expect(party.connection, PartyConnection.reconnecting);
        party.control('seek', 30000);
        await _settle(150);
        sockets[1].receive(_welcome(you: 'host-pid'));
        await _settle();
        final sent = sockets[1].ofType('control').single;
        expect(sent['action'], 'seek');
        expect(sent['positionMs'], 30000, reason: 'paused: nothing moved on');
        party.dispose();
      },
    );

    test('until its own action comes back, a newer change from someone else '
        'is not applied over it', () async {
      final party = await start();
      sockets.single.receive(
        _welcome(you: 'guest-pid', guestControl: true, status: 'playing'),
      );
      await _settle();
      party.control('pause', 40000);
      expect(party.controlPending, isTrue);
      // Someone else's seek reached the room first.
      sockets.single.receive({
        't': 'state',
        'playback': {
          'status': 'playing',
          'positionMs': 90000,
          'at': DateTime.now().millisecondsSinceEpoch,
          'seq': 2,
          'by': 'host-pid',
        },
      });
      await _settle();
      expect(party.controlPending, isTrue, reason: 'still waiting for ours');
      sockets.single.receive({
        't': 'state',
        'playback': {
          'status': 'paused',
          'positionMs': 40000,
          'at': DateTime.now().millisecondsSinceEpoch,
          'seq': 3,
          'by': 'guest-pid',
        },
      });
      await _settle();
      expect(party.controlPending, isFalse);
      expect(party.room!.playback.seq, 3);
      party.dispose();
    });

    test(
      'a refused action stops holding the room back after a while',
      () async {
        final party = await start();
        sockets.single.receive(_welcome(you: 'host-pid'));
        await _settle();
        party.control('play', 0);
        expect(party.controlPending, isTrue);
        sockets.single.receive({'t': 'error', 'code': 'not_allowed'});
        await _settle();
        // Bounded: never applied as long as the room keeps quiet.
        await _settle(3100);
        expect(party.controlPending, isFalse);
        party.dispose();
      },
    );

    test(
      'the host sends no heartbeat while its own change is on the way',
      () async {
        final party = await start();
        sockets.single.receive(_welcome(you: 'host-pid', status: 'playing'));
        await _settle();
        party
          ..control('seek', 5000)
          ..heartbeat(5100);
        expect(sockets.single.ofType('heartbeat'), isEmpty);
        party.dispose();
      },
    );

    test('with the player: a held key on the host moves the player each press '
        'but the room only a few times', () async {
      final party = await start();
      sockets.single.receive(_welcome(you: 'host-pid', status: 'playing'));
      await _settle();
      final sync = PartyPlayerSync(
        party,
        checkEvery: const Duration(hours: 1),
        heartbeatEvery: const Duration(hours: 1),
      );
      sync.attach(_Player());
      final watch = Stopwatch()..start();
      for (var i = 1; i <= 20; i++) {
        sync.localSeek(Duration(seconds: 10 * i));
        await _settle(20);
      }
      watch.stop();
      await _settle(250);
      // One per 200 ms interval at most, plus the first and the last.
      final most = watch.elapsedMilliseconds ~/ 200 + 2;
      final sent = sockets.single.ofType('control');
      expect(sent.length, lessThanOrEqualTo(most));
      expect(sent.length, lessThan(20));
      expect(sent.last['positionMs'] as int, greaterThanOrEqualTo(200000));
      sync.dispose();
      party.dispose();
    });
  });

  group('presence', () {
    test('tells the room it is here with text pings', () async {
      final party = await start(
        textPingInterval: const Duration(milliseconds: 40),
      );
      sockets.single.receive(_welcome(you: 'guest-pid'));
      await _settle(130);
      expect(
        sockets.single.raw.where((t) => t == 'ping').length,
        greaterThan(1),
      );
      party.dispose();
      final count = sockets.single.raw.where((t) => t == 'ping').length;
      await _settle(120);
      expect(
        sockets.single.raw.where((t) => t == 'ping').length,
        count,
        reason: 'stops with the party',
      );
    });

    test('pongs do not hide a room that stopped delivering', () async {
      final party = await start(
        silenceLimit: const Duration(milliseconds: 150),
        textPingInterval: const Duration(milliseconds: 20),
      );
      sockets.single.receive(_welcome(you: 'guest-pid', status: 'playing'));
      await _settle();
      final first = sockets.single;
      // Pongs keep coming the whole time; the room says nothing. The silence
      // check still reconnects (allowing for a slow, busy test machine).
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (sockets.length == 1 && DateTime.now().isBefore(deadline)) {
        first.receive('pong');
        await _settle(20);
      }
      expect(sockets.length, greaterThan(1), reason: 'reconnected');
      party.dispose();
    });

    test('a socket the room closed as gone reconnects', () async {
      final party = await start();
      sockets.single.receive(_welcome(you: 'guest-pid'));
      await _settle();
      sockets.single.closeCode = 4008;
      await sockets.single.drop();
      await _settle(30);
      expect(sockets, hasLength(2));
      expect(party.endReason, isNull);
      party.dispose();
    });
  });

  group('reactions', () {
    test('sends a reaction, shows it here at once, and names others', () async {
      final party = await start();
      final seen = <PartyReaction>[];
      final sub = party.reactions.listen(seen.add);
      sockets.single.receive(_welcome(you: 'guest-pid'));
      await _settle();
      expect(party.react('laugh'), isTrue);
      expect(sockets.single.ofType('react').single, {
        't': 'react',
        'emoji': 'laugh',
      });
      expect(party.react('fire'), isFalse, reason: 'too soon');
      expect(party.react('unknown'), isFalse);
      sockets.single
        ..receive({'t': 'reaction', 'pid': 'host-pid', 'emoji': 'love'})
        ..receive({'t': 'reaction', 'pid': 'host-pid', 'emoji': '<b>'})
        // The room never echoes this device's own, but if it did...
        ..receive({'t': 'reaction', 'pid': 'guest-pid', 'emoji': 'laugh'});
      await _settle();
      expect(seen.map((r) => (r.emoji, r.name)), [
        ('laugh', 'Sam'),
        ('love', 'Host'),
      ]);
      expect(seen.first.glyph, '😂');
      await sub.cancel();
      party.dispose();
    });

    test(
      'an older room without reactions or chat is never sent them',
      () async {
        final party = await start();
        sockets.single.receive(_welcome(you: 'guest-pid', features: null));
        await _settle();
        expect(party.supportsReactions, isFalse);
        expect(party.supportsChat, isFalse);
        expect(party.react('laugh'), isFalse);
        expect(party.sendChat('hello'), isFalse);
        expect(sockets.single.ofType('react'), isEmpty);
        expect(sockets.single.ofType('chat'), isEmpty);
        party.dispose();
      },
    );
  });

  group('chat', () {
    test('a line appears once the room relays it, in the room\'s order, and '
        'counts as unread only from others', () async {
      final party = await start();
      sockets.single.receive(_welcome(you: 'guest-pid'));
      await _settle();
      expect(party.sendChat('   '), isFalse);
      expect(party.sendChat('  hello\n  there '), isTrue);
      final sent = sockets.single.ofType('chat').single;
      expect(sent['text'], 'hello there');
      expect(sent['id'], isA<String>());
      expect(party.messages, isEmpty, reason: 'shown when relayed');
      expect(party.sendChat('again'), isFalse, reason: 'too soon');

      sockets.single
        ..receive({
          't': 'chat',
          'pid': 'host-pid',
          'name': 'Host',
          'text': 'welcome!',
          'at': 1000,
        })
        ..receive({
          't': 'chat',
          'pid': 'guest-pid',
          'name': 'Sam',
          'text': 'hello there',
          'at': 1001,
          'id': sent['id'],
        });
      await _settle();
      expect(party.messages.map((m) => (m.name, m.text, m.mine)), [
        ('Host', 'welcome!', false),
        ('Sam', 'hello there', true),
      ]);
      expect(party.unreadChat, 1);
      party.markChatRead();
      expect(party.unreadChat, 0);
      party.dispose();
    });

    test(
      'keeps the chat across a reconnect, and only the latest lines',
      () async {
        final party = await start();
        sockets[0].receive(_welcome(you: 'guest-pid'));
        await _settle();
        for (var i = 0; i < WatchPartyController.maxChatMessages + 5; i++) {
          sockets[0].receive({
            't': 'chat',
            'pid': 'host-pid',
            'name': 'Host',
            'text': 'line $i',
            'at': i,
          });
        }
        await _settle();
        expect(party.messages, hasLength(WatchPartyController.maxChatMessages));
        expect(party.messages.first.text, 'line 5');
        await sockets[0].drop();
        await _settle(30);
        sockets[1].receive(_welcome(you: 'guest-pid'));
        await _settle();
        expect(party.messages, hasLength(WatchPartyController.maxChatMessages));
        party.dispose();
      },
    );

    test('drops malformed lines and caps long ones', () async {
      final party = await start();
      sockets.single.receive(_welcome(you: 'guest-pid'));
      await _settle();
      sockets.single
        ..receive({'t': 'chat', 'pid': 7, 'text': 'x'})
        ..receive({'t': 'chat', 'pid': 'host-pid', 'text': ''})
        ..receive({'t': 'chat', 'pid': 'host-pid', 'text': 'y' * 900});
      await _settle();
      expect(party.messages.single.text.length, 300);
      expect(party.messages.single.name, 'Viewer');
      party.dispose();
    });

    test('is not sent while disconnected', () async {
      final party = await start(backoff: const Duration(seconds: 5));
      sockets.single.receive(_welcome(you: 'guest-pid'));
      await _settle();
      await sockets.single.drop();
      await _settle();
      expect(party.sendChat('anyone?'), isFalse);
      expect(party.react('wow'), isFalse);
      party.dispose();
    });
  });

  group('invitation links', () {
    test('reads the code from the app link and the shared web page', () {
      expect(
        partyCodeFromLink(Uri.parse('reelish://party/12345678')),
        '12345678',
      );
      expect(
        partyCodeFromLink(
          Uri.parse('https://api.example.dev/api/v1/join/00012345'),
        ),
        '00012345',
      );
    });

    test('ignores anything else', () {
      for (final link in [
        'reelish://party/1234567',
        'reelish://party/123456789',
        'reelish://party/1234abcd',
        'reelish://other/12345678',
        'reelish://party/12345678/extra',
        'http://api.example.dev/api/v1/join/12345678',
        'https://api.example.dev/api/v1/join/12345678/x',
        'https://api.example.dev/api/v1/party/12345678',
        'javascript:alert(1)',
      ]) {
        expect(partyCodeFromLink(Uri.parse(link)), isNull, reason: link);
      }
    });

    test('a link only leaves its code for Home, once', () {
      PartyLinks.pending.value = null;
      PartyLinks.receive('reelish://party/87654321');
      expect(PartyLinks.pending.value, '87654321');
      expect(PartyLinks.take(), '87654321');
      expect(PartyLinks.take(), isNull);
      for (final bad in [
        null,
        42,
        'reelish://party/1',
        'https://evil.example/x',
        'reelish://party/${'1' * 80}',
      ]) {
        PartyLinks.receive(bad);
        expect(PartyLinks.pending.value, isNull, reason: '$bad');
      }
    });

    testWidgets('Join a party opened from a link looks the code up but '
        'waits for the viewer to join', (tester) async {
      final looked = <String>[];
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: JoinPartyScreen(
            initialCode: '12345678',
            preview: (code) async {
              looked.add(code);
              return const PartyPreview(
                code: '12345678',
                phase: PartyPhase.watching,
                content: PartyContent(
                  tmdbId: 603,
                  type: 'movie',
                  title: 'The Matrix',
                ),
                hostName: 'Host',
                participants: 2,
                capacity: 5,
              );
            },
            open: (_, code) => opened = code,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(looked, ['12345678']);
      expect(find.text('The Matrix'), findsOneWidget);
      expect(opened, isNull, reason: 'never joins on its own');
      await tester.tap(find.widgetWithText(FilledButton, 'Join party'));
      expect(opened, '12345678');
    });
  });

  group('screens', () {
    Future<(WatchPartyController, _Socket)> connected(
      WidgetTester tester,
    ) async {
      late WatchPartyController party;
      final socket = _Socket();
      await tester.runAsync(() async {
        final api = AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((_) async => http.Response('{}', 200)),
        );
        final account = AccountController(
          api: api,
          store: MemorySessionStore(
            StoredSession(
              sessionId: 's1',
              accessToken: 'access-1',
              accessExpiresAt: _now() + 900,
              refreshToken: 'refresh-1',
              refreshExpiresAt: _now() + 86400,
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
          profile: ProfileController(
            directory: () async => Directory.systemTemp,
          ),
          textPingInterval: const Duration(hours: 1),
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

    Map<String, Object?> lobby({List<String>? features}) {
      final welcome = _welcome(you: 'guest-pid', features: features);
      final room = Map<String, Object?>.from(welcome['room']! as Map);
      return {
        ...welcome,
        'room': {...room, 'phase': 'lobby'},
      };
    }

    testWidgets('the waiting room offers reactions and chat', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      final (party, socket) = await connected(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: WaitingRoomScreen(party: party, openPlayer: (_, _) async {}),
        ),
      );
      socket.receive(lobby(features: ['reactions', 'chat']));
      await deliver(tester);
      await tester.scrollUntilVisible(
        find.text('Send a message'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('REACTIONS AND CHAT'), findsOneWidget);

      await tester.tap(find.text('😂'));
      await tester.pump();
      expect(socket.ofType('react').single['emoji'], 'laugh');

      await tester.enterText(find.byType(TextField), 'popcorn ready');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(socket.ofType('chat').single['text'], 'popcorn ready');

      socket.receive({
        't': 'chat',
        'pid': 'host-pid',
        'name': 'Host',
        'text': 'starting soon',
        'at': 1,
      });
      await deliver(tester);
      expect(find.textContaining('starting soon'), findsOneWidget);
      // Read here, on screen: nothing counts as unread.
      expect(party.unreadChat, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older room shows no reactions or chat', (tester) async {
      final (party, socket) = await connected(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: WaitingRoomScreen(party: party, openPlayer: (_, _) async {}),
        ),
      );
      socket.receive(lobby());
      await deliver(tester);
      expect(find.text('REACTIONS AND CHAT'), findsNothing);
      expect(find.text('Send a message'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('over the video: others\' reactions rise and fade, and a new '
        'line shows for a moment unless the chat is open', (tester) async {
      final (party, socket) = await connected(tester);
      socket.receive(_welcome(you: 'guest-pid'));
      await deliver(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: PartyActivityLayer(party: party, topInset: 100),
                ),
                Align(
                  alignment: Alignment.topRight,
                  child: PartyChatButton(party: party, onPressed: () {}),
                ),
              ],
            ),
          ),
        ),
      );
      socket.receive({'t': 'reaction', 'pid': 'host-pid', 'emoji': 'fire'});
      await deliver(tester);
      expect(find.text('🔥'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('🔥'), findsNothing, reason: 'gone after it fades');

      socket.receive({
        't': 'chat',
        'pid': 'host-pid',
        'name': 'Host',
        'text': 'look at this',
        'at': 1,
      });
      await deliver(tester);
      expect(find.textContaining('look at this'), findsOneWidget);
      expect(party.unreadChat, 1);
      expect(find.byTooltip('Reactions and chat, 1 new'), findsOneWidget);

      party.chatViewChanged(open: true);
      socket.receive({
        't': 'chat',
        'pid': 'host-pid',
        'name': 'Host',
        'text': 'seen in the chat',
        'at': 2,
      });
      await deliver(tester);
      expect(find.textContaining('seen in the chat'), findsNothing);
      expect(party.unreadChat, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      party.dispose();
    });
  });
}

class _Player implements PartyPlayerHandle {
  @override
  bool ready = true;
  @override
  bool playing = true;
  @override
  bool buffering = false;
  @override
  bool completed = false;
  @override
  bool failed = false;
  @override
  Duration position = Duration.zero;
  @override
  int? season;
  @override
  int? episode;

  @override
  Future<void> remotePlay() async => playing = true;
  @override
  Future<void> remotePause() async => playing = false;
  @override
  Future<void> remoteSeek(Duration to) async => position = to;
  @override
  Future<void> remoteSpeed(double rate) async {}
  @override
  void remoteEpisode(int season, int episode) {}
  @override
  void notice(String message) {}
}
