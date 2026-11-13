import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/social/friends_screen.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _person(String handle, {String? name}) => {
  'handle': handle,
  'displayName': name,
  'avatar': null,
  'since': 1700000000000,
};

/// The Reelish API's Friends routes for one signed-in account ("me"), with
/// the outcomes that matter to the app.
class _FakeServer {
  final known = <String, Map<String, Object?>>{
    'ben': _person('ben', name: 'Ben'),
    'cara': _person('cara'),
    'dev': _person('dev'),
  };
  final codes = {'BENC2345': 'ben', 'CARA2345': 'cara'};
  var friends = <String>['dev'];
  var incoming = <String>['cara'];
  var outgoing = <String>[];
  final blocked = <String>[];
  bool down = false;
  final requests =
      <({String method, String path, Map<String, Object?> body})>[];

  http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _notFound() => _json({
    'error': {
      'code': 'not_found',
      'message': 'No one was found. Check it and try again.',
      'requestId': 'r',
    },
  }, 404);

  Future<http.Response> handle(http.Request request) async {
    if (down) throw const SocketException('offline');
    final path = request.url.path.replaceFirst('/api/v1', '');
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(request.body) as Map);
    requests.add((method: request.method, path: path, body: body));
    final method = request.method;
    if (path == '/social/profile' && method == 'GET') {
      return _json({
        'profile': {
          'handle': 'me',
          'friendCode': 'MEME2345',
          'findByCode': true,
          'findByHandle': false,
          'allowRecommendations': true,
          'shareActivity': false,
        },
        'counts': {'friends': friends.length, 'incoming': incoming.length},
      });
    }
    if (path == '/social/friends' && method == 'GET') {
      return _json({
        'friends': [for (final h in friends) known[h]],
        'incoming': [for (final h in incoming) known[h]],
        'outgoing': [for (final h in outgoing) known[h]],
        'cursor': null,
        'counts': {'friends': friends.length, 'incoming': incoming.length},
      });
    }
    if (path == '/social/requests' && method == 'POST') {
      final handle = body['code'] != null
          ? codes[body['code']]
          : (body['handle'] == 'cara' ? 'cara' : null);
      if (handle == null) return _notFound();
      if (incoming.remove(handle)) {
        friends = [...friends, handle];
        return _json({'status': 'friends', 'person': known[handle]});
      }
      outgoing = [...outgoing, handle];
      return _json({'status': 'requested', 'person': known[handle]}, 201);
    }
    final parts = path.split('/');
    final handle = parts.length > 3 ? parts[3] : '';
    if (path.endsWith('/accept')) {
      if (!incoming.remove(handle)) return _notFound();
      friends = [...friends, handle];
      return _json({'status': 'friends', 'person': known[handle]});
    }
    if (path.endsWith('/decline')) {
      return incoming.remove(handle) ? _json({'ok': true}) : _notFound();
    }
    if (path.startsWith('/social/requests/') && method == 'DELETE') {
      return outgoing.remove(handle) ? _json({'ok': true}) : _notFound();
    }
    if (path.startsWith('/social/friends/')) {
      if (!friends.contains(handle)) return _notFound();
      if (method == 'DELETE') {
        friends.remove(handle);
        return _json({'ok': true});
      }
      return _json({'friend': known[handle]});
    }
    if (path == '/social/blocks' && method == 'POST') {
      final target = body['handle'] as String;
      friends.remove(target);
      incoming.remove(target);
      outgoing.remove(target);
      blocked.add(target);
      return _json({'ok': true});
    }
    if (path == '/social/blocks' && method == 'GET') {
      return _json({
        'blocked': [for (final h in blocked) known[h]],
      });
    }
    if (path.startsWith('/social/blocks/') && method == 'DELETE') {
      return blocked.remove(handle) ? _json({'ok': true}) : _notFound();
    }
    if (path == '/social/reports' && method == 'POST') {
      return _json({'id': 'report'}, 201);
    }
    return _notFound();
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Future<(FriendsController, SocialController)> _controllers(
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
    FriendsController(account: account, api: api, social: social),
    social,
  );
}

void _tall(WidgetTester tester, {Size size = const Size(1080, 3600)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = size.width > 1500 ? 1.5 : 2.5;
  addTearDown(tester.view.reset);
}

Widget _app(FriendsController friends, SocialController social) => MaterialApp(
  home: Scaffold(
    body: FriendsScreen(social: social, friends: friends, onBack: () {}),
  ),
);

void main() {
  late _FakeServer server;

  setUp(() {
    server = _FakeServer();
    SharedPreferences.setMockInitialValues({});
  });

  group('What Add friend sends', () {
    test('a code, typed any way, or a handle', () {
      expect(friendTarget('abcd-2345'), {'code': 'ABCD2345'});
      expect(friendTarget(' ABCD 2345 '), {'code': 'ABCD2345'});
      expect(friendTarget('@movie_night'), {'handle': 'movie_night'});
      expect(friendTarget('movie_night'), {'handle': 'movie_night'});
      // O and 1 are never in a code: this is a handle.
      expect(friendTarget('moviebuf'), {'handle': 'moviebuf'});
      expect(friendTarget('@1bad'), isNull);
      expect(friendTarget('!!'), isNull);
    });
  });

  group('FriendsController', () {
    test('loads friends and requests', () async {
      final (friends, social) = await _controllers(server);
      await social.refresh();
      await friends.load();
      expect(friends.friends.map((p) => p.handle), ['dev']);
      expect(friends.incoming.map((p) => p.handle), ['cara']);
      expect(social.counts.incoming, 1);
    });

    test('a request by code waits; adding someone who asked accepts', () async {
      final (friends, social) = await _controllers(server);
      await social.refresh();
      await friends.load();

      final sent = await friends.add('benc-2345');
      expect(sent.error, isNull);
      expect(sent.friends, isFalse);
      expect(friends.outgoing.map((p) => p.handle), ['ben']);

      final mutual = await friends.add('CARA2345');
      expect(mutual.friends, isTrue);
      expect(friends.incoming, isEmpty);
      expect(friends.friends.map((p) => p.handle), ['cara', 'dev']);
      expect(social.counts.incoming, 0);
      expect(social.counts.friends, 2);
    });

    test('unknown people get the server message', () async {
      final (friends, _) = await _controllers(server);
      final result = await friends.add('ZZZZ-ZZZZ');
      expect(result.error, 'No one was found. Check it and try again.');
      final malformed = await friends.add('!!');
      expect(malformed.error, contains('friend code'));
      expect(
        server.requests.where((r) => r.path == '/social/requests'),
        hasLength(1),
      );
    });

    test(
      'accept, decline, cancel and remove change the lists and counts',
      () async {
        final (friends, social) = await _controllers(server);
        await social.refresh();
        await friends.load();
        final cara = friends.incoming.single;
        expect(await friends.accept(cara), isNull);
        expect(friends.friends.map((p) => p.handle), ['cara', 'dev']);
        expect(social.counts, isA<SocialCounts>());
        expect(social.counts.friends, 2);
        expect(social.counts.incoming, 0);

        await friends.add('BENC2345');
        expect(await friends.cancel(friends.outgoing.single), isNull);
        expect(friends.outgoing, isEmpty);

        expect(await friends.remove(friends.friends.first), isNull);
        expect(friends.friends.map((p) => p.handle), ['dev']);
        expect(social.counts.friends, 1);
      },
    );

    test('blocking takes the person off every list', () async {
      final (friends, social) = await _controllers(server);
      await social.refresh();
      await friends.load();
      expect(await friends.block(friends.incoming.single), isNull);
      expect(friends.incoming, isEmpty);
      expect(social.counts.incoming, 0);
      expect((await friends.blocked()).map((p) => p.handle), ['cara']);
      expect(await friends.unblock(const SocialPerson(handle: 'cara')), isNull);
      expect(await friends.blocked(), isEmpty);
    });

    test('a person gone on the server is dropped here too', () async {
      final (friends, _) = await _controllers(server);
      await friends.load();
      server.friends = [];
      final error = await friends.remove(friends.friends.single);
      expect(error, isNotNull);
      expect(friends.friends, isEmpty);
    });

    test('report sends the reason and note, and blocks when asked', () async {
      final (friends, _) = await _controllers(server);
      await friends.load();
      final dev = friends.friends.single;
      expect(
        await friends.report(
          dev,
          reason: ReportReason.harassment,
          note: ' rude ',
          alsoBlock: true,
        ),
        isNull,
      );
      final report = server.requests.firstWhere(
        (r) => r.path == '/social/reports',
      );
      expect(report.body, {
        'handle': 'dev',
        'reason': 'harassment',
        'note': 'rude',
      });
      expect(server.blocked, ['dev']);
      expect(friends.friends, isEmpty);
    });

    test(
      'offline: the last list shows; another account never sees it',
      () async {
        final (friends, _) = await _controllers(server);
        await friends.load();
        server.down = true;
        final (later, _) = await _controllers(server);
        await later.load();
        expect(later.failed, isTrue);
        expect(later.loaded, isTrue);
        expect(later.friends.map((p) => p.handle), ['dev']);

        final (other, _) = await _controllers(server, userId: 'user-2');
        await other.load();
        expect(other.friends, isEmpty);
        expect(other.loaded, isFalse);
      },
    );

    test('turning Friends off forgets the saved list', () async {
      final (friends, _) = await _controllers(server);
      await friends.load();
      await friends.forget();
      server.down = true;
      final (later, _) = await _controllers(server);
      await later.load();
      expect(later.friends, isEmpty);
    });
  });

  group('Friends page', () {
    testWidgets('phone: accept a request, add a friend', (tester) async {
      _tall(tester);
      final (friends, social) = await _controllers(server);
      await tester.pumpWidget(_app(friends, social));
      await tester.pumpAndSettle();
      expect(find.text('REQUESTS · 1'), findsOneWidget);
      expect(find.text('@cara'), findsOneWidget);
      expect(find.textContaining('trakt_name'), findsNothing);

      await tester.tap(find.byTooltip('Accept'));
      await tester.pumpAndSettle();
      expect(find.text('REQUESTS · 1'), findsNothing);
      expect(find.text('FRIENDS · 2'), findsOneWidget);

      await tester.tap(find.text('Add by code or @handle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ZZZZ-ZZZZ');
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      // Refused: the dialog stays open with the reason.
      expect(find.text('No one was found. Check it and try again.'), findsOne);
      await tester.enterText(find.byType(TextField), 'benc-2345');
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      expect(find.text('Request sent to @ben'), findsOneWidget);
      expect(find.text('SENT'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
    });

    testWidgets('declining asks first; Cancel changes nothing', (tester) async {
      _tall(tester);
      final (friends, social) = await _controllers(server);
      await tester.pumpWidget(_app(friends, social));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Decline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(server.incoming, ['cara']);
      await tester.tap(find.byTooltip('Decline'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Decline'));
      await tester.pumpAndSettle();
      expect(server.incoming, isEmpty);
      expect(find.text('Request declined'), findsOneWidget);
    });

    testWidgets("a friend's page: block after confirming", (tester) async {
      _tall(tester);
      final (friends, social) = await _controllers(server);
      var closed = false;
      await friends.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FriendScreen(
              person: friends.friends.single,
              friends: friends,
              onBack: () => closed = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Remove friend'), findsOneWidget);
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();
      expect(server.blocked, ['dev']);
      expect(closed, isTrue);
    });

    testWidgets('report: a reason is required', (tester) async {
      _tall(tester);
      final (friends, social) = await _controllers(server);
      await friends.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FriendScreen(
              person: friends.friends.single,
              friends: friends,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      final report = find.widgetWithText(FilledButton, 'Report');
      expect(tester.widget<FilledButton>(report).onPressed, isNull);
      await tester.tap(find.text('Spam'));
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(report);
      await tester.pumpAndSettle();
      final sent = server.requests.firstWhere(
        (r) => r.path == '/social/reports',
      );
      expect(sent.body['reason'], 'spam');
      // "Also block" was switched off.
      expect(server.blocked, isEmpty);
    });

    testWidgets(
      'Windows: adding and requests beside the list',
      (tester) async {
        _tall(tester, size: const Size(1920, 1400));
        final (friends, social) = await _controllers(server);
        await tester.pumpWidget(_app(friends, social));
        await tester.pumpAndSettle();
        final add = tester.getTopLeft(find.text('ADD A FRIEND'));
        final list = tester.getTopLeft(find.textContaining('FRIENDS ·'));
        expect(list.dx, greaterThan(add.dx));
        expect(list.dy, add.dy);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('TV: two columns, and the request buttons take focus', (
      tester,
    ) async {
      _tall(tester, size: const Size(1920, 1080));
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final (friends, social) = await _controllers(server);
      await tester.pumpWidget(_app(friends, social));
      await tester.pumpAndSettle();
      final add = tester.getTopLeft(find.text('ADD A FRIEND'));
      final list = tester.getTopLeft(find.textContaining('FRIENDS ·'));
      expect(list.dx, greaterThan(add.dx));
      final accept = find.byTooltip('Accept');
      Focus.of(
        tester.element(
          find.descendant(of: accept, matching: find.byType(Icon)),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(server.friends, ['dev', 'cara']);
    });

    testWidgets('Friends off: one way to turn it on', (tester) async {
      _tall(tester);
      final api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient(
          (_) async => http.Response(
            '{"profile":null}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      final account = AccountController(
        api: api,
        store: MemorySessionStore(
          StoredSession(
            sessionId: 's',
            accessToken: 'a',
            accessExpiresAt: _now() + 3600,
            refreshToken: 'r',
            refreshExpiresAt: _now() + 86400,
            userId: 'user-off',
            username: 'x',
          ),
        ),
      );
      await account.restore();
      final offSocial = SocialController(account: account, api: api);
      await tester.pumpWidget(
        _app(
          FriendsController(account: account, api: api, social: offSocial),
          offSocial,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Turn on Friends'), findsOneWidget);
      expect(find.text('ADD A FRIEND'), findsNothing);
    });
  });
}
