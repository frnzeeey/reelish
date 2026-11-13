import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/social/friends_privacy_screen.dart';
import 'package:onfeed/src/screens/social/friends_screen.dart';
import 'package:onfeed/src/social/activity_publisher.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/recommendations_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _poster = 'https://image.tmdb.org/t/p/w500/dune.jpg';
const _dune = MediaItem(
  id: '438631',
  type: 'movie',
  name: 'Dune',
  year: '2021',
  poster: _poster,
);
const _dark = MediaItem(id: '70523', type: 'series', name: 'Dark');

/// The Reelish API's profile and activity routes.
class _FakeServer {
  bool sharing = true;
  bool down = false;

  /// Answers wait for this when set: a server that never replies.
  Completer<void>? hold;
  final requests =
      <({String method, String path, Map<String, Object?> body})>[];

  http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  List<({String method, String path, Map<String, Object?> body})>
  get activity => [
    for (final r in requests)
      if (r.path == '/social/activity' && r.method != 'GET') r,
  ];

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/api/v1', '');
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(request.body) as Map);
    requests.add((method: request.method, path: path, body: body));
    await hold?.future;
    if (down) throw const SocketException('offline');
    switch ((request.method, path)) {
      case ('GET', '/social/profile'):
        return _json({
          'profile': {
            'handle': 'me',
            'friendCode': 'MEME2345',
            'shareActivity': sharing,
          },
          'counts': {'friends': 1, 'incoming': 0, 'unread': 0},
        });
      case ('PUT', '/social/profile'):
        sharing = body['shareActivity'] == true;
        return _json({
          'profile': {
            'handle': 'me',
            'friendCode': 'MEME2345',
            'shareActivity': sharing,
          },
        });
      case ('PUT', '/social/activity'):
      case ('DELETE', '/social/activity'):
        return _json({'ok': true});
      case ('GET', '/social/activity'):
        return _json({
          'watching': [
            {
              'person': {'handle': 'ben', 'displayName': 'Ben'},
              'media': {
                'type': 'series',
                'id': '70523',
                'title': 'Dark',
                'poster': null,
              },
              'season': 1,
              'episode': 3,
              'startedAt': 1,
            },
          ],
        });
      case ('GET', '/social/friends'):
        return _json({
          'friends': [
            {'handle': 'ben', 'displayName': 'Ben'},
          ],
          'incoming': [],
          'outgoing': [],
          'cursor': null,
        });
      case ('GET', '/social/recommendations'):
        return _json({'items': [], 'cursor': null, 'unread': 0});
    }
    return _json({
      'error': {'code': 'not_found', 'message': 'Not found.'},
    }, 404);
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

typedef _Parts = ({
  AccountApi api,
  AccountController account,
  SocialController social,
});

Future<_Parts> _parts(_FakeServer server) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient(server.handle),
  );
  final account = AccountController(
    api: api,
    store: MemorySessionStore(
      StoredSession(
        sessionId: 'session',
        accessToken: 'access',
        accessExpiresAt: _now() + 3600,
        refreshToken: 'refresh',
        refreshExpiresAt: _now() + 86400,
        userId: 'user-1',
        username: 'trakt_name',
      ),
    ),
  );
  await account.restore();
  return (
    api: api,
    account: account,
    social: SocialController(account: account, api: api),
  );
}

void main() {
  late _FakeServer server;

  setUp(() {
    server = _FakeServer();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => SocialTitles.open = null);

  group('ActivityPublisher', () {
    // testWidgets runs in fake time: tester.pump(duration) moves the clock
    // and fires the publisher's timers.
    late ActivityPublisher publisher;

    Future<void> start(WidgetTester tester, {bool sharing = true}) async {
      server.sharing = sharing;
      final parts = await _parts(server);
      await parts.social.refresh();
      server.requests.clear();
      publisher = ActivityPublisher(
        account: parts.account,
        api: parts.api,
        social: parts.social,
      );
      addTearDown(publisher.dispose);
    }

    Future<void> wait(WidgetTester tester, Duration duration) async {
      // In steps, so timers set while waiting fire too.
      for (var left = duration; left > Duration.zero;) {
        final step = left > const Duration(seconds: 1)
            ? const Duration(seconds: 1)
            : left;
        await tester.pump(step);
        left -= step;
      }
    }

    testWidgets('nothing at all while sharing is off', (tester) async {
      await start(tester, sharing: false);
      expect(publisher.sessionFor(_dune), isNull);
      await wait(tester, const Duration(minutes: 2));
      expect(server.requests, isEmpty);
    });

    testWidgets("a title that is not TMDB's is never published", (
      tester,
    ) async {
      await start(tester);
      expect(
        publisher.sessionFor(
          const MediaItem(id: 'tt1', type: 'movie', name: 'X'),
        ),
        isNull,
      );
    });

    testWidgets('playing sends the card once; stopping clears after a moment', (
      tester,
    ) async {
      await start(tester);
      final session = publisher.sessionFor(_dune, season: 4, episode: 2)!;
      session.playing(remaining: const Duration(minutes: 90));
      await tester.pump();
      expect(server.activity.single.method, 'PUT');
      expect(server.activity.single.body, {
        'media': {
          'type': 'movie',
          'id': '438631',
          'title': 'Dune',
          'poster': _poster,
        },
        'remainingMs': 90 * 60 * 1000,
      });
      // The same again (an engine retry): nothing more.
      session.playing();
      await wait(tester, const Duration(minutes: 2));
      expect(server.activity, hasLength(1));

      session.stopped();
      await wait(tester, const Duration(seconds: 19));
      expect(server.activity, hasLength(1));
      await wait(tester, const Duration(seconds: 2));
      expect(server.activity.last.method, 'DELETE');
      // Stopping twice clears once.
      session.stopped();
      await wait(tester, const Duration(minutes: 1));
      expect(server.activity, hasLength(2));
    });

    testWidgets('a series names its episode', (tester) async {
      await start(tester);
      publisher.sessionFor(_dark, season: 1, episode: 3)!.playing();
      await tester.pump();
      final body = server.activity.single.body;
      expect((body['season'], body['episode']), (1, 3));
      expect(body.containsKey('remainingMs'), isFalse);
      await wait(tester, const Duration(minutes: 1));
    });

    testWidgets('the next episode starting soon after does not flicker', (
      tester,
    ) async {
      await start(tester);
      final first = publisher.sessionFor(_dark, season: 1, episode: 1)!;
      first.playing();
      await wait(tester, const Duration(minutes: 2));
      first.stopped();
      await wait(tester, const Duration(seconds: 5));
      publisher.sessionFor(_dark, season: 1, episode: 2)!.playing();
      await wait(tester, const Duration(minutes: 1));
      expect(server.activity.map((r) => r.method), ['PUT', 'PUT']);
      expect(server.activity.last.body['episode'], 2);
    });

    testWidgets('at most one update a minute; the latest wins', (tester) async {
      await start(tester);
      publisher.sessionFor(_dune)!.playing();
      await tester.pump();
      publisher.sessionFor(_dark, season: 1, episode: 1)!.playing();
      publisher.sessionFor(_dark, season: 1, episode: 2)!.playing();
      await wait(tester, const Duration(seconds: 58));
      expect(server.activity, hasLength(1));
      await wait(tester, const Duration(seconds: 3));
      expect(server.activity, hasLength(2));
      expect(server.activity.last.body['episode'], 2);
      await wait(tester, const Duration(minutes: 1));
    });

    testWidgets(
      'playback never waits: a server that never answers changes nothing',
      (tester) async {
        await start(tester);
        server.hold = Completer<void>();
        final session = publisher.sessionFor(_dune)!;
        // Both return at once, with the request still open.
        session.playing();
        session.stopped();
        // The clear waits for the publish still on its way.
        await wait(tester, const Duration(seconds: 10));
        expect(server.activity.single.method, 'PUT');
        // The publish times out, but may have arrived: the clear follows.
        await wait(tester, const Duration(minutes: 1));
        expect(server.activity.map((r) => r.method), ['PUT', 'DELETE']);
        server.hold!.complete();
        await wait(tester, const Duration(minutes: 1));
        expect(server.activity, hasLength(2));
      },
    );

    testWidgets('a publish is noted on the device until it is cleared', (
      tester,
    ) async {
      await start(tester);
      final session = publisher.sessionFor(_dune)!;
      session.playing();
      await tester.pump();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(ActivityPublisher.leftoverKey), 'user-1');
      session.stopped();
      await wait(tester, const Duration(seconds: 21));
      expect(server.activity.last.method, 'DELETE');
      expect(preferences.getString(ActivityPublisher.leftoverKey), isNull);
      await wait(tester, const Duration(minutes: 1));
    });

    testWidgets('the next launch clears what a crash left published', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        ActivityPublisher.leftoverKey: 'user-1',
      });
      await start(tester);
      publisher.attach();
      await wait(tester, const Duration(seconds: 1));
      expect(server.activity.map((r) => r.method), ['DELETE']);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(ActivityPublisher.leftoverKey), isNull);
    });

    testWidgets("another account's leftover is not cleared with this one", (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        ActivityPublisher.leftoverKey: 'someone-else',
      });
      await start(tester);
      publisher.attach();
      await wait(tester, const Duration(seconds: 1));
      expect(server.activity, isEmpty);
    });

    testWidgets('failures are dropped', (tester) async {
      await start(tester);
      server.down = true;
      final session = publisher.sessionFor(_dune)!;
      session.playing();
      await wait(tester, const Duration(seconds: 30));
      session.stopped();
      await wait(tester, const Duration(minutes: 1));
      // Nothing throws; a clear is still tried, in case the publish arrived
      // before the connection dropped.
      expect(server.activity.map((r) => r.method), ['PUT', 'DELETE']);
    });
  });

  testWidgets('Friends page: who is watching what, and it opens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    final opened = <String>[];
    SocialTitles.open = (item) async => opened.add('${item.type}:${item.id}');
    final parts = await _parts(server);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FriendsScreen(
            social: parts.social,
            friends: FriendsController(
              account: parts.account,
              api: parts.api,
              social: parts.social,
            ),
            recommendations: RecommendationsController(
              account: parts.account,
              api: parts.api,
              social: parts.social,
            ),
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('WATCHING NOW'), findsOneWidget);
    expect(find.text('@ben · Watching Dark · S1 E3'), findsOneWidget);
    await tester.tap(find.text('@ben · Watching Dark · S1 E3'));
    expect(opened, ['series:70523']);
  });

  testWidgets('Friends & privacy: the sharing switch', (tester) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    server.sharing = false;
    final parts = await _parts(server);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FriendsPrivacyScreen(controller: parts.social, onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Share what I'm watching"));
    await tester.pumpAndSettle();
    expect(server.requests.last.body, {'shareActivity': true});
    expect(parts.social.profile!.shareActivity, isTrue);
  });
}
