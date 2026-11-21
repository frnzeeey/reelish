// Draws Together with a full set of data in the real engine and the app's
// own fonts, on the phone, TV and Windows layouts, and walks the TV layout
// with the D-pad:
//
//   flutter test integration_test/together_layout_test.dart -d windows
//
// Widget tests draw text in the Ahem test font, far wider than Montserrat,
// so they cannot show how the real page fits. Here nothing is faked but the
// Reelish API: friends (one with a long name), two watching now, a request
// in each direction and shared discoveries with notes. Each layout must draw
// without an overflow; with SAVE_SHOTS set (a folder), it is also saved as a
// picture for review.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/social/friends_screen.dart';
import 'package:onfeed/src/screens/social/together_sections.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/recommendations_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _shots = String.fromEnvironment('SAVE_SHOTS');

Map<String, Object?> _person(String handle, [String? name]) => {
  'handle': handle,
  'displayName': name,
  'avatar': null,
  'since': 1700000000000,
};

Map<String, Object?> _media(String id, String title, String type) => {
  'type': type,
  'id': id,
  'title': title,
  'year': '2024',
  'poster': null,
};

http.Response _json(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// The Reelish API for one account with friends, requests, people watching
/// and shared discoveries.
Future<http.Response> _api(http.Request request) async {
  final path = request.url.path.replaceFirst('/api/v1', '');
  switch ((request.method, path)) {
    case ('GET', '/social/profile'):
      return _json({
        'profile': {
          'handle': 'movie_night',
          'friendCode': 'MEME2345',
          'findByCode': true,
          'findByHandle': true,
          'allowRecommendations': true,
          'shareActivity': true,
        },
        'counts': {'friends': 5, 'incoming': 1, 'unread': 2},
      });
    case ('GET', '/social/friends'):
      return _json({
        'friends': [
          _person('ben', 'Ben'),
          _person('anastasia', 'Anastasia Montgomery-Richardson'),
          _person('cara'),
          _person('dev', 'Dev'),
          _person('kim', 'Kim'),
        ],
        'incoming': [_person('eli', 'Eli')],
        'outgoing': [_person('fay')],
        'cursor': null,
      });
    case ('GET', '/social/activity'):
      return _json({
        'watching': [
          {
            'person': _person('ben', 'Ben'),
            'media': _media('70523', 'Dark', 'series'),
            'season': 2,
            'episode': 4,
            'startedAt': 1,
          },
          {
            'person': _person('anastasia', 'Anastasia Montgomery-Richardson'),
            'media': _media(
              '120',
              'The Lord of the Rings: The Fellowship of the Ring',
              'movie',
            ),
            'startedAt': 1,
          },
        ],
      });
    case ('GET', '/social/recommendations'):
      return _json({
        'items': [
          for (final (i, (title, note)) in const [
            ('Past Lives', 'This one stayed with me for days.'),
            (
              'Everything Everywhere All at Once',
              'Bring tissues. And a hot dog. Trust me on this, you will see '
                  'why about an hour in.',
            ),
            ('Arrival', null),
            ('Paddington 2', 'Movie night pick for the family.'),
          ].indexed)
            {
              'id': 'r$i',
              'from': _person(i.isEven ? 'ben' : 'anastasia'),
              'media': _media('${900 + i}', title, 'movie'),
              'message': note,
              'createdAt': 1700000000000,
              'read': i > 1,
            },
        ],
        'cursor': null,
        'unread': 2,
      });
    case ('GET', '/social/recommendations/sent'):
      return _json({'items': []});
    case ('GET', '/social/blocks'):
      return _json({'blocked': []});
  }
  return http.Response(
    jsonEncode({
      'error': {'code': 'not_found', 'message': 'Not found.'},
    }),
    404,
    headers: {'content-type': 'application/json'},
  );
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Future<Widget> _page() async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient(_api),
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
  final social = SocialController(account: account, api: api);
  // Together's page, as TogetherScreen builds it, with these controllers.
  return FriendsScreen(
    title: 'Together',
    greet: true,
    social: social,
    friends: FriendsController(account: account, api: api, social: social),
    recommendations: RecommendationsController(
      account: account,
      api: api,
      social: social,
    ),
    movieNight: MovieNightCard(onJoin: () {}, onPickTitle: () {}),
  );
}

final _frame = GlobalKey();

/// Draws the page in [size] logical pixels, tall enough that every section
/// is built, and fails on any layout overflow.
Future<void> _draw(
  WidgetTester tester,
  String name,
  Size size, {
  double textScale = 1,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final page = await tester.runAsync(_page);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: GlassTheme.dark,
      home: RepaintBoundary(
        key: _frame,
        child: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: Scaffold(body: page!),
        ),
      ),
    ),
  );
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(tester.takeException(), isNull, reason: '$name overflowed or threw');
  expect(find.text('Together'), findsWidgets);
  expect(find.byType(FriendsStrip), findsOneWidget, reason: name);
  expect(find.textContaining('REQUESTS'), findsOneWidget, reason: name);
  if (_shots.isNotEmpty) {
    final boundary =
        _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$_shots/together_$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
    });
  }
}

/// Shows one interface on the Windows engine. Returns the reset, which a
/// test calls at the end of its body: flutter_test checks the platform
/// override before tear-downs run.
VoidCallback _useLayout({required bool tv, required bool phone}) {
  if (phone || tv) debugDefaultTargetPlatformOverride = TargetPlatform.android;
  DeviceCapabilities.debugOverride = DeviceCapabilities(
    isTelevision: tv,
    hasTouchscreen: !tv,
  );
  return () {
    debugDefaultTargetPlatformOverride = null;
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
  };
}

/// The first text inside [node]'s widget, to name it in the output.
String _label(FocusNode node) {
  String? text;
  void visit(Element element) {
    if (text != null) return;
    final widget = element.widget;
    if (widget is Text && widget.data != null) {
      text = widget.data;
      return;
    }
    if (widget is Tooltip && widget.message != null) {
      text = widget.message;
      return;
    }
    element.visitChildren(visit);
  }

  (node.context! as Element).visitChildren(visit);
  return text ?? node.debugLabel ?? '?';
}

/// Focusable controls on the page.
List<FocusNode> _focusable() => [
  for (final node in FocusManager.instance.rootScope.traversalDescendants)
    if (node.canRequestFocus && !node.skipTraversal && node.context != null)
      node,
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('phone, small: 360 dp wide', (tester) async {
    final reset = _useLayout(tv: false, phone: true);
    try {
      await _draw(tester, 'phone_360', const Size(360, 2600));
    } finally {
      reset();
    }
  });

  testWidgets('phone at 200 % text', (tester) async {
    final reset = _useLayout(tv: false, phone: true);
    try {
      await _draw(
        tester,
        'phone_412_text200',
        const Size(412, 4200),
        textScale: 2,
      );
    } finally {
      reset();
    }
  });

  testWidgets('Windows: a 1280 px window and a full HD one', (tester) async {
    final reset = _useLayout(tv: false, phone: false);
    try {
      expect(DeviceCapabilities.isDesktop, isTrue);
      await _draw(tester, 'windows_1280', const Size(1280, 1500));
      await _draw(tester, 'windows_1920', const Size(1920, 1300));
    } finally {
      reset();
    }
  });

  testWidgets('TV: draws, and a remote reaches every section', (tester) async {
    final reset = _useLayout(tv: true, phone: false);
    try {
      expect(DeviceCapabilities.isTv, isTrue);
      await _draw(tester, 'tv_960', const Size(960, 1600));

      // A remote session: key presses only, as a viewer would make them.
      // (Focusing a control from code in between would break Flutter's
      // directional history, where Down after Up goes back.)
      _focusable().first.requestFocus();
      await tester.pump();
      String here() => _label(FocusManager.instance.primaryFocus!);
      final path = <String>[here()];
      Future<String> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pump(const Duration(milliseconds: 80));
        path.add(here());
        return path.last;
      }

      const right = LogicalKeyboardKey.arrowRight;
      const left = LogicalKeyboardKey.arrowLeft;
      const down = LogicalKeyboardKey.arrowDown;

      expect(here(), 'B', reason: 'the first friend leads');
      // Along the friends strip to Add, and back.
      for (final face in ['A', 'C', 'D', 'K', 'Add']) {
        expect(await press(right), face);
      }
      for (final face in ['K', 'D', 'C', 'A', 'B']) {
        expect(await press(left), face);
      }
      // Down the left column: Messages, Movie night, the discoveries.
      expect(await press(down), 'Messages');
      expect(await press(down), 'Join with a code');
      expect(await press(down), 'Pick a title to host');
      expect(await press(down), 'NEW', reason: 'the first poster');
      // Along the posters.
      expect(await press(right), 'NEW');
      expect(await press(right), 'Arrival');
      expect(await press(right), 'Paddington 2');
      // Across to the people, then all the way down the right column.
      for (var i = 0; i < 4 && !path.last.contains('Eli'); i++) {
        await press(LogicalKeyboardKey.arrowUp);
        await press(right);
      }
      var last = '';
      for (var i = 0; i < 20 && here() != last; i++) {
        last = here();
        await press(down);
      }
      // ignore: avoid_print
      print('TV_REMOTE ${path.join(' > ')}');
      expect(here(), 'Blocked people', reason: 'the bottom of the page');
      for (final row in [
        'Add by code or @handle',
        'Your friend code',
        'Friends & privacy',
      ]) {
        expect(path, contains(row));
      }
      expect(tester.takeException(), isNull);
    } finally {
      reset();
    }
  });
}
