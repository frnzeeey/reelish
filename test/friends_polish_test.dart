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
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/screens/social/friends_privacy_screen.dart';
import 'package:onfeed/src/screens/social/friends_screen.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/recommendations_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _long = 'Maximilian Alexander Wolfgang von Hohenst';

/// The Friends routes with long names everywhere, as a stress for layout.
class _FakeServer {
  int incoming = 2;
  int unread = 1;
  bool on = true;
  final requests = <String>[];

  http.Response _json(Object? body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  Map<String, Object?> _person(String handle) => {
    'handle': handle,
    'displayName': _long,
    'avatar': null,
    'since': 1700000000000,
  };

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/api/v1', '');
    requests.add('${request.method} $path');
    switch ((request.method, path)) {
      case ('GET', '/social/profile'):
        return _json({
          'profile': on
              ? {
                  'handle': 'a_very_long_handle20',
                  'friendCode': 'ABCD2345',
                  'displayName': _long,
                }
              : null,
          'counts': {'friends': 3, 'incoming': incoming, 'unread': unread},
        });
      case ('GET', '/social/friends'):
        return _json({
          'friends': [
            _person('ben_has_a_long_name'),
            _person('cara_has_long_names'),
          ],
          'incoming': [_person('dev_is_asking_nicely')],
          'outgoing': [_person('eve_waits_for_answer')],
          'cursor': null,
        });
      case ('GET', '/social/recommendations'):
        return _json({
          'items': [
            {
              'id': 'r1',
              'from': _person('ben_has_a_long_name'),
              'media': {
                'type': 'movie',
                'id': '1',
                'title': 'The Lord of the Rings: The Return of the King',
                'year': '2003',
              },
              'message': 'x' * 200,
              'createdAt': 1,
              'read': false,
            },
          ],
          'cursor': null,
          'unread': unread,
        });
      case ('GET', '/social/recommendations/sent'):
        return _json({'items': []});
      case ('GET', '/social/activity'):
        return _json({
          'watching': [
            {
              'person': _person('cara_has_long_names'),
              'media': {
                'type': 'series',
                'id': '2',
                'title': 'Avatar: The Last Airbender, Book Three',
              },
              'season': 3,
              'episode': 21,
            },
          ],
        });
      case ('GET', '/social/friends/ben_has_a_long_name'):
        return _json({
          'friend': _person('ben_has_a_long_name'),
          'collections': [
            {
              'id': 'a' * 24,
              'name': 'An extremely long collection name for testing',
              'description': 'd' * 300,
              'count': 1234,
              'posters': [],
            },
          ],
        });
    }
    return http.Response(
      jsonEncode({
        'error': {'code': 'not_found', 'message': 'Not found.'},
      }),
      404,
    );
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

typedef _Parts = ({
  AccountController account,
  SocialController social,
  FriendsController friends,
  RecommendationsController recommendations,
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
        sessionId: 's1',
        accessToken: 'access-1',
        accessExpiresAt: _now() + 900,
        refreshToken: 'refresh-1',
        refreshExpiresAt: _now() + 86400,
        userId: 'u1',
        username: 'trakt_name',
      ),
    ),
  );
  await account.restore();
  final social = SocialController(account: account, api: api);
  return (
    account: account,
    social: social,
    friends: FriendsController(account: account, api: api, social: social),
    recommendations: RecommendationsController(
      account: account,
      api: api,
      social: social,
    ),
  );
}

class _Storage extends StorageService {
  @override
  Future<List<MediaItem>> history() async => const [];

  @override
  Future<List<MediaItem>> favorites() async => const [];
}

Widget _app(Widget page, {double textScale = 1}) => MaterialApp(
  theme: GlassTheme.dark,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: page),
    ),
  ),
);

void _screen(WidgetTester tester, Size size, {double ratio = 1}) {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
}

void main() {
  late _FakeServer server;

  setUp(() {
    server = _FakeServer();
    SharedPreferences.setMockInitialValues({});
  });

  group('Profile: the Friends row', () {
    Future<_Parts> show(WidgetTester tester) async {
      _screen(tester, const Size(420, 1800));
      final parts = await _parts(server);
      final profile = ProfileController(
        directory: () async => Directory.systemTemp,
      );
      await profile.loadFor('u1');
      await tester.pumpWidget(
        _app(
          ProfileScreen(
            storage: _Storage(),
            account: parts.account,
            profile: profile,
            social: parts.social,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return parts;
    }

    testWidgets('requests first, with the dot and a spoken summary', (
      tester,
    ) async {
      await show(tester);
      expect(find.text('2 requests'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp('2 friend requests, 1 new recommendation'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('then new recommendations', (tester) async {
      server.incoming = 0;
      await show(tester);
      expect(find.text('1 new recommendation'), findsOneWidget);
    });

    testWidgets('nothing new: the friend count, and no dot', (tester) async {
      server
        ..incoming = 0
        ..unread = 0;
      await show(tester);
      expect(find.text('3 friends'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('friend request')), findsNothing);
    });

    testWidgets('Friends off as last known: no request at all', (tester) async {
      SharedPreferences.setMockInitialValues({
        '${SocialController.cachePrefix}u1': jsonEncode({'on': false}),
      });
      await show(tester);
      expect(find.text('Off'), findsOneWidget);
      expect(server.requests, isEmpty);
    });
  });

  group('Long names and large text', () {
    for (final (label, size, scale) in [
      ('a small phone at 200% text', const Size(320, 640), 2.0),
      ('a phone', const Size(390, 844), 1.0),
      ('a TV', const Size(960, 540), 1.0),
    ]) {
      testWidgets('nothing overflows on $label', (tester) async {
        _screen(tester, size);
        final tv = size.width >= 960;
        if (tv) {
          DeviceCapabilities.debugOverride = const DeviceCapabilities(
            isTelevision: true,
            hasTouchscreen: false,
          );
          addTearDown(
            () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
          );
        }
        final parts = await _parts(server);
        await tester.pumpWidget(
          _app(
            FriendsScreen(
              social: parts.social,
              friends: parts.friends,
              recommendations: parts.recommendations,
              onBack: () {},
            ),
            textScale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          _app(
            FriendScreen(
              person: const SocialPerson(handle: 'ben_has_a_long_name'),
              friends: parts.friends,
              onBack: () {},
            ),
            textScale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          _app(
            RecommendationsScreen(
              recommendations: parts.recommendations,
              onBack: () {},
            ),
            textScale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          _app(
            FriendsPrivacyScreen(controller: parts.social, onBack: () {}),
            textScale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('a person row reads as one item, with its details', (
    tester,
  ) async {
    _screen(tester, const Size(420, 2400));
    final parts = await _parts(server);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        FriendsScreen(
          social: parts.social,
          friends: parts.friends,
          recommendations: parts.recommendations,
          onBack: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final node = tester.getSemantics(
      find.textContaining('@cara_has_long_names · Friends since'),
    );
    expect(node.label, contains(_long));
    expect(node.label, contains('@cara_has_long_names'));
    // A request row keeps Accept and Decline as their own buttons.
    for (final action in ['Accept', 'Decline']) {
      final button = tester.getSemantics(find.byTooltip(action));
      expect(button.tooltip, action);
      expect(button.label, isNot(contains(_long)));
    }
    semantics.dispose();
  });

  testWidgets('phone: pull to refresh asks again, even within two minutes', (
    tester,
  ) async {
    _screen(tester, const Size(420, 900));
    final parts = await _parts(server);
    await tester.pumpWidget(
      _app(
        FriendsScreen(
          social: parts.social,
          friends: parts.friends,
          recommendations: parts.recommendations,
          onBack: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = server.requests
        .where((r) => r == 'GET /social/profile')
        .length;
    await tester.fling(
      find.byType(Scrollable).first,
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();
    expect(
      server.requests.where((r) => r == 'GET /social/profile').length,
      before + 1,
    );
  });

  testWidgets('TV: the remote reaches a friend and opens them', (tester) async {
    _screen(tester, const Size(1920, 1080));
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    addTearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );
    final parts = await _parts(server);
    await tester.pumpWidget(
      _app(
        FriendsScreen(
          social: parts.social,
          friends: parts.friends,
          recommendations: parts.recommendations,
          onBack: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    // No pull to refresh on a remote.
    expect(find.byType(RefreshIndicator), findsNothing);
    final friend = find.textContaining('@ben_has_a_long_name · Friends since');
    bool focusedOnFriend() {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      return find
          .descendant(of: find.byWidget(focused.widget), matching: friend)
          .evaluate()
          .isNotEmpty;
    }

    // Into the page, across to the friends column, then down to Ben.
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    for (var press = 0; press < 12 && !focusedOnFriend(); press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(focusedOnFriend(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Remove friend'), findsOneWidget);
  });
}
