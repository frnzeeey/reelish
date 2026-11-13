import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/social/friends_privacy_screen.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Reelish API's /social/profile routes, with the handle rules that
/// matter to the app.
class _FakeServer {
  Map<String, Object?>? profile;
  final taken = <String>{'taken_one'};
  bool down = false;
  final requests =
      <({String method, String path, Map<String, Object?> body})>[];

  http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String code, String message) => _json({
    'error': {'code': code, 'message': message, 'requestId': 'r'},
  }, status);

  Future<http.Response> handle(http.Request request) async {
    if (down) throw const SocketException('offline');
    final path = request.url.path;
    final body = request.body.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(request.body) as Map);
    requests.add((method: request.method, path: path, body: body));
    if (path == '/api/v1/social/profile/code' && request.method == 'POST') {
      if (profile == null) {
        return _error(409, 'friends_off', 'Turn on Friends first.');
      }
      profile = {...profile!, 'friendCode': 'WXYZ6789'};
      return _json({'profile': profile});
    }
    expect(path, '/api/v1/social/profile');
    switch (request.method) {
      case 'GET':
        return _json({'profile': profile});
      case 'DELETE':
        profile = null;
        return _json({'ok': true});
      case 'PUT':
        final handle = body['handle'];
        if (handle is String && taken.contains(handle.toLowerCase())) {
          return _error(
            409,
            'handle_taken',
            'That handle is taken. Try another.',
          );
        }
        if (profile == null) {
          if (handle == null) {
            return _error(400, 'handle_required', 'Choose a handle.');
          }
          profile = {
            'handle': handle,
            'friendCode': 'ABCD2345',
            'displayName': null,
            'avatar': null,
            'findByCode': true,
            'findByHandle': false,
            'allowRecommendations': true,
            'shareActivity': false,
            'handleChangeableAt': 0,
            'createdAt': 1,
          };
          return _json({'profile': profile}, 201);
        }
        profile = {...profile!, ...body};
        return _json({'profile': profile});
    }
    return _error(404, 'not_found', 'Not found.');
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Future<(SocialController, AccountController)> _controller(
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
  return (SocialController(account: account, api: api), account);
}

/// A phone held upright, tall enough that every row of the page is built.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 3600);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

Widget _app(SocialController social) => MaterialApp(
  home: Scaffold(
    body: FriendsPrivacyScreen(controller: social, onBack: () {}),
  ),
);

void main() {
  late _FakeServer server;

  setUp(() {
    server = _FakeServer();
    SharedPreferences.setMockInitialValues({});
  });

  group('SocialController', () {
    test('Friends is off until turned on, and known once asked', () async {
      final (social, _) = await _controller(server);
      expect(social.known, isFalse);
      await social.refresh();
      expect(social.known, isTrue);
      expect(social.enabled, isFalse);
    });

    test('turning on, changing settings and turning off', () async {
      final (social, _) = await _controller(server);
      expect(await social.enable('movie_night'), isNull);
      expect(social.profile!.handle, 'movie_night');
      expect(social.profile!.formattedCode, 'ABCD-2345');
      expect(social.profile!.findByHandle, isFalse);

      expect(await social.setSetting(SocialSetting.findByHandle, true), isNull);
      expect(server.requests.last.body, {'findByHandle': true});
      expect(social.profile!.findByHandle, isTrue);

      expect(await social.setDisplayName('  '), isNull);
      expect(server.requests.last.body, {'displayName': null});
      expect(await social.setAvatar('avatar2'), isNull);
      expect(social.profile!.avatar, 'avatar2');

      expect(await social.disable(), isNull);
      expect(server.requests.last.method, 'DELETE');
      expect(social.enabled, isFalse);
      expect(social.known, isTrue);
    });

    test('a new friend code replaces the old one', () async {
      final (social, _) = await _controller(server);
      await social.enable('movie_night');
      expect(await social.resetCode(), isNull);
      expect(social.profile!.formattedCode, 'WXYZ-6789');
    });

    test(
      'a refused handle returns the server message and changes nothing',
      () async {
        final (social, _) = await _controller(server);
        final error = await social.enable('taken_one');
        expect(error, 'That handle is taken. Try another.');
        expect(social.enabled, isFalse);
      },
    );

    test('offline: a plain message, and the saved copy still shows', () async {
      final (social, _) = await _controller(server);
      await social.enable('movie_night');

      // A fresh launch, offline: the saved copy for this account.
      server.down = true;
      final (later, _) = await _controller(server);
      await later.refresh();
      expect(later.failed, isTrue);
      expect(later.profile?.handle, 'movie_night');
      expect(
        await later.setSetting(SocialSetting.findByCode, false),
        contains('could not be reached'),
      );
    });

    test('another account never sees the saved copy', () async {
      final (social, _) = await _controller(server);
      await social.enable('movie_night');
      server.down = true;
      final (other, _) = await _controller(server, userId: 'user-2');
      await other.refresh();
      expect(other.profile, isNull);
      expect(other.known, isFalse);
    });

    test('a malformed answer is not taken as Friends off', () async {
      final api = AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient((_) async => http.Response('{"weird":1}', 200)),
      );
      final (_, account) = await _controller(server);
      final social = SocialController(account: account, api: api);
      await social.refresh();
      expect(social.failed, isTrue);
      expect(social.known, isFalse);
    });

    test('never sends the Trakt username', () async {
      final (social, _) = await _controller(server);
      await social.enable('movie_night');
      await social.setDisplayName('Ana');
      for (final request in server.requests) {
        expect(jsonEncode(request.body), isNot(contains('trakt_name')));
      }
    });
  });

  group('Friends & privacy page', () {
    testWidgets('phone: turn on with a handle, then turn off', (tester) async {
      _tall(tester);
      final (social, _) = await _controller(server);
      await tester.pumpWidget(_app(social));
      await tester.pumpAndSettle();
      expect(find.text('Turn on Friends'), findsOneWidget);

      await tester.tap(find.text('Turn on Friends'));
      await tester.pumpAndSettle();
      // Checked in the app first: nothing is sent.
      await tester.enterText(find.byType(TextField), '1bad');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('starting with a letter'), findsOneWidget);
      expect(server.requests.where((r) => r.method == 'PUT'), isEmpty);

      // Refused by the server: the dialog stays open with its message.
      await tester.enterText(find.byType(TextField), 'taken_one');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('That handle is taken. Try another.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'movie_night');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('@movie_night'), findsOneWidget);
      expect(find.text('ABCD-2345'), findsOneWidget);
      expect(find.text('Not shared'), findsNWidgets(2));
      expect(find.textContaining('trakt_name'), findsNothing);
      await tester.tap(find.text('Turn off Friends'));
      await tester.pumpAndSettle();
      // Cancel is the focused, safe choice.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(social.enabled, isTrue);

      await tester.tap(find.text('Turn off Friends'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
      await tester.pumpAndSettle();
      expect(social.enabled, isFalse);
      expect(find.text('Turn on Friends'), findsOneWidget);
    });

    testWidgets('a privacy switch sends only that setting', (tester) async {
      _tall(tester);
      final (social, _) = await _controller(server);
      await social.enable('movie_night');
      await tester.pumpWidget(_app(social));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Found by handle'));
      await tester.pumpAndSettle();
      expect(server.requests.last.body, {'findByHandle': true});
      expect(social.profile!.findByHandle, isTrue);
    });

    testWidgets('offline with nothing saved: a way to try again', (
      tester,
    ) async {
      server.down = true;
      final (social, _) = await _controller(server);
      await tester.pumpWidget(_app(social));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      server.down = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Turn on Friends'), findsOneWidget);
    });

    testWidgets(
      'Windows: the same page, the code can be copied',
      (tester) async {
        final (social, _) = await _controller(server);
        await social.enable('movie_night');
        await tester.pumpWidget(_app(social));
        await tester.pumpAndSettle();
        expect(find.text('ABCD-2345'), findsOneWidget);
        expect(find.text('Copy'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('TV: the code is shown, with nothing to copy to', (
      tester,
    ) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final (social, _) = await _controller(server);
      await social.enable('movie_night');
      await tester.pumpWidget(_app(social));
      await tester.pumpAndSettle();
      expect(find.text('ABCD-2345'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
    });
  });

  test('the app checks handles as the server does', () {
    // backend/src/social/profiles.ts handlePattern.
    for (final good in ['abc', 'Movie_Night', 'a${'b' * 19}']) {
      expect(handlePattern.hasMatch(good), isTrue, reason: good);
    }
    for (final bad in ['ab', '_abc', '1abc', 'a b', 'émile', 'a${'b' * 20}']) {
      expect(handlePattern.hasMatch(bad), isFalse, reason: bad);
    }
  });
}
