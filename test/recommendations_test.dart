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
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/social/friends_screen.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/recommendations_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:onfeed/src/widgets/social/share_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _poster = 'https://image.tmdb.org/t/p/w500/abc_DEF-1.jpg';
const _dune = MediaItem(
  id: '438631',
  type: 'movie',
  name: 'Dune',
  year: '2021',
  poster: _poster,
);

Map<String, Object?> _item(String id, {bool read = false, String? from}) => {
  'id': id,
  'from': from == null
      ? null
      : {'handle': from, 'displayName': null, 'avatar': null},
  'media': {
    'type': 'movie',
    'id': '438631',
    'title': 'Dune $id',
    'year': '2021',
    'poster': _poster,
  },
  'message': 'Watch it',
  'createdAt': 1700000000000,
  'read': read,
};

/// The Reelish API's Friends and recommendation routes, for one account.
class _FakeServer {
  var inbox = <Map<String, Object?>>[
    _item('a', from: 'ben'),
    _item('b', from: 'cara'),
    _item('c', read: true),
  ];
  bool down = false;
  int failSends = 0;
  final requests =
      <({String method, String path, Map<String, Object?> body})>[];

  http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  int get unread => inbox.where((i) => i['read'] != true).length;

  Future<http.Response> handle(http.Request request) async {
    if (down) throw const SocketException('offline');
    final path = request.url.path.replaceFirst('/api/v1', '');
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(request.body) as Map);
    requests.add((method: request.method, path: path, body: body));
    switch ((request.method, path)) {
      case ('GET', '/social/profile'):
        return _json({
          'profile': {'handle': 'me', 'friendCode': 'MEME2345'},
          'counts': {'friends': 2, 'incoming': 0, 'unread': unread},
        });
      case ('GET', '/social/friends'):
        return _json({
          'friends': [
            {'handle': 'ben', 'displayName': 'Ben'},
            {'handle': 'cara'},
          ],
          'incoming': [],
          'outgoing': [],
          'cursor': null,
        });
      case ('GET', '/social/recommendations/sent'):
        return _json({
          'items': [
            {
              ..._item('s'),
              'from': null,
              'to': {'handle': 'ben', 'displayName': 'Ben'},
            }..remove('read'),
          ],
        });
      case ('GET', '/social/recommendations'):
        return _json({'items': inbox, 'cursor': null, 'unread': unread});
      case ('POST', '/social/recommendations/read'):
        final ids = body['ids'] as List?;
        inbox = [
          for (final item in inbox)
            if (ids == null || ids.contains(item['id']))
              {...item, 'read': true}
            else
              item,
        ];
        return _json({'marked': 1});
      case ('POST', '/social/recommendations'):
        if (failSends > 0) {
          failSends--;
          throw const SocketException('dropped');
        }
        final recipients = (body['recipients'] as List).cast<String>();
        return _json({
          'sent': [
            for (final h in recipients)
              if (h != 'cara') h,
          ],
          'notSent': [
            for (final h in recipients)
              if (h == 'cara') h,
          ],
        }, 201);
    }
    if (request.method == 'DELETE' &&
        path.startsWith('/social/recommendations/')) {
      final id = path.split('/').last;
      inbox = [
        for (final item in inbox)
          if (item['id'] != id) item,
      ];
      return _json({'ok': true});
    }
    return _json({
      'error': {'code': 'not_found', 'message': 'Not found.'},
    }, 404);
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

typedef _Controllers = ({
  SocialController social,
  FriendsController friends,
  RecommendationsController recommendations,
});

Future<_Controllers> _controllers(
  _FakeServer server, {
  String userId = 'user-1',
}) async {
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
        userId: userId,
        username: 'trakt_name',
      ),
    ),
  );
  await account.restore();
  final social = SocialController(account: account, api: api);
  return (
    social: social,
    friends: FriendsController(account: account, api: api, social: social),
    recommendations: RecommendationsController(
      account: account,
      api: api,
      social: social,
    ),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 3600);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  late _FakeServer server;

  setUp(() {
    server = _FakeServer();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => SocialTitles.open = null);

  group('A card', () {
    test('carries only a TMDB title, its year and TMDB artwork', () {
      expect(cardOf(_dune), {
        'type': 'movie',
        'id': '438631',
        'title': 'Dune',
        'year': '2021',
        'poster': _poster,
      });
      const odd = MediaItem(
        id: '7',
        type: 'series',
        name: 'Show',
        year: 'soon',
        poster: 'https://example.com/x.jpg',
      );
      expect(cardOf(odd), {'type': 'series', 'id': '7', 'title': 'Show'});
      expect(
        cardOf(const MediaItem(id: 'tt123', type: 'movie', name: 'X')),
        isNull,
      );
      expect(cardOf(const MediaItem(id: '1', type: 'tv', name: 'X')), isNull);
    });

    test('what a send did, in one sentence', () {
      expect(
        shareSummary((error: null, sent: ['ben'], notSent: [])),
        'Sent to @ben',
      );
      expect(
        shareSummary((error: null, sent: ['ben', 'dev'], notSent: ['cara'])),
        'Sent to @ben and @dev. @cara does not take recommendations right now.',
      );
      expect(
        shareSummary((error: null, sent: [], notSent: ['cara', 'eve'])),
        'Not sent: 2 friends do not take recommendations right now.',
      );
    });
  });

  group('RecommendationsController', () {
    test('loads the inbox and the unread count', () async {
      final c = await _controllers(server);
      await c.social.refresh();
      await c.recommendations.load();
      expect(c.recommendations.items.map((i) => i.id), ['a', 'b', 'c']);
      expect(c.recommendations.items.first.from?.handle, 'ben');
      expect(c.recommendations.items.last.from, isNull);
      expect(c.social.counts.unread, 2);
    });

    test('opening one marks only it; opening the inbox marks all', () async {
      final c = await _controllers(server);
      await c.social.refresh();
      await c.recommendations.load();
      await c.recommendations.markRead(c.recommendations.items.first);
      expect(server.requests.last.body, {
        'ids': ['a'],
      });
      expect(c.social.counts.unread, 1);
      expect(c.recommendations.items.first.read, isTrue);

      await c.recommendations.markRead();
      expect(server.requests.last.body, <String, Object?>{});
      expect(c.social.counts.unread, 0);
      expect(c.recommendations.items.every((i) => i.read), isTrue);

      // Nothing left to mark: no request.
      final before = server.requests.length;
      await c.recommendations.markRead();
      expect(server.requests.length, before);
    });

    test('remove takes it out and fixes the count', () async {
      final c = await _controllers(server);
      await c.social.refresh();
      await c.recommendations.load();
      expect(
        await c.recommendations.remove(c.recommendations.items[1]),
        isNull,
      );
      expect(c.recommendations.items.map((i) => i.id), ['a', 'c']);
      expect(c.social.counts.unread, 1);
    });

    test('a send names the friends, the card and its key', () async {
      final c = await _controllers(server);
      final result = await c.recommendations.send(
        _dune,
        recipients: ['ben', 'cara'],
        clientId: 'key-0001',
        message: '  You will love it ',
      );
      expect(result.error, isNull);
      expect(result.sent, ['ben']);
      expect(result.notSent, ['cara']);
      expect(server.requests.last.body, {
        'recipients': ['ben', 'cara'],
        'media': cardOf(_dune),
        'clientId': 'key-0001',
        'message': 'You will love it',
      });
    });

    test('a title that is not TMDB\'s is not sent', () async {
      final c = await _controllers(server);
      final result = await c.recommendations.send(
        const MediaItem(id: 'tt1', type: 'movie', name: 'X'),
        recipients: ['ben'],
        clientId: 'key-0001',
      );
      expect(result.error, isNotNull);
      expect(server.requests, isEmpty);
    });

    test('offline: the saved inbox; another account never sees it', () async {
      final c = await _controllers(server);
      await c.recommendations.load();
      server.down = true;
      final later = await _controllers(server);
      await later.recommendations.load();
      expect(later.recommendations.failed, isTrue);
      expect(later.recommendations.items, hasLength(3));
      final other = await _controllers(server, userId: 'user-2');
      await other.recommendations.load();
      expect(other.recommendations.items, isEmpty);
    });

    test('turning Friends off forgets the saved inbox', () async {
      final c = await _controllers(server);
      await c.recommendations.load();
      await c.recommendations.forget();
      server.down = true;
      final later = await _controllers(server);
      await later.recommendations.load();
      expect(later.recommendations.items, isEmpty);
    });
  });

  group('Share dialog', () {
    Future<void> open(WidgetTester tester, _Controllers c) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => shareWithFriends(
                  context,
                  _dune,
                  friends: c.friends,
                  recommendations: c.recommendations,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('choose friends, add a note, send', (tester) async {
      _tall(tester);
      final c = await _controllers(server);
      await open(tester, c);
      expect(find.text('Share “Dune”'), findsOneWidget);
      final send = find.widgetWithText(FilledButton, 'Send');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);

      await tester.tap(find.text('Ben'));
      await tester.tap(find.text('@cara'));
      await tester.pump();
      expect(find.text('Send to 2'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'So good');
      await tester.tap(find.text('Send to 2'));
      await tester.pumpAndSettle();
      final sent = server.requests.last.body;
      expect(sent['recipients'], ['ben', 'cara']);
      expect(sent['message'], 'So good');
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text(
          'Sent to @ben. @cara does not take recommendations right now.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a failed send stays open, and the retry reuses its key', (
      tester,
    ) async {
      _tall(tester);
      final c = await _controllers(server);
      server.failSends = 1;
      await open(tester, c);
      await tester.tap(find.text('Ben'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('could not be reached'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();
      final sends = server.requests
          .where((r) => r.path == '/social/recommendations')
          .toList();
      expect(sends, hasLength(2));
      expect(sends[0].body['clientId'], sends[1].body['clientId']);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('TV: friends to tick, no note to type', (tester) async {
      _tall(tester);
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final c = await _controllers(server);
      await open(tester, c);
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('Friends page', () {
    testWidgets('shows what friends sent; opening one marks it read', (
      tester,
    ) async {
      _tall(tester);
      final opened = <String>[];
      SocialTitles.open = (item) async => opened.add(item.id);
      final c = await _controllers(server);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FriendsScreen(
              social: c.social,
              friends: c.friends,
              recommendations: c.recommendations,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('RECOMMENDED TO YOU · 2 NEW'), findsOneWidget);
      expect(find.text('From @ben'), findsOneWidget);
      expect(find.text('“Watch it”'), findsNWidgets(3));
      await tester.tap(find.text('Dune a (2021)'));
      await tester.pumpAndSettle();
      expect(opened, ['438631']);
      expect(find.text('RECOMMENDED TO YOU · 1 NEW'), findsOneWidget);
    });

    testWidgets('the full inbox marks everything read and can remove', (
      tester,
    ) async {
      _tall(tester);
      final c = await _controllers(server);
      await c.social.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecommendationsScreen(
              recommendations: c.recommendations,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(c.social.counts.unread, 0);
      expect(server.unread, 0);
      expect(find.text('YOU SENT'), findsOneWidget);
      expect(find.text('To Ben'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
      expect(server.inbox.map((i) => i['id']), ['b', 'c']);
      expect(find.text('Removed “Dune a”'), findsOneWidget);
    });
  });
}
