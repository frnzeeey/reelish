import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/collections/collection_models.dart';
import 'package:onfeed/src/collections/collection_store.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/social/friends_screen.dart';
import 'package:onfeed/src/social/friends_controller.dart';
import 'package:onfeed/src/social/recommendations_controller.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:onfeed/src/theme/reelish_icons.dart';
import 'package:onfeed/src/widgets/collections/collection_actions.dart';
import 'package:onfeed/src/widgets/collections/collection_cover.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _scifi = 'aaaaaaaaaaaaaaaaaaaaaaaa';
const _poster = 'https://image.tmdb.org/t/p/w500/p1.jpg';

/// A friend's page and one shared collection, as the API returns them.
class _FakeServer {
  bool shared = true;
  final requests = <String>[];

  http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/api/v1', '');
    requests.add(path);
    if (path == '/social/friends/ben') {
      return _json({
        'friend': {'handle': 'ben', 'displayName': 'Ben'},
        'collections': [
          if (shared)
            {
              'id': _scifi,
              'name': 'Sci-fi',
              'description': 'Space',
              'count': 2,
              'posters': [_poster, 'https://evil.example/x.jpg'],
            },
        ],
      });
    }
    if (path == '/social/friends/ben/collections/$_scifi') {
      if (!shared) {
        return _json({
          'error': {'code': 'not_found', 'message': 'Not found.'},
        }, 404);
      }
      return _json({
        'collection': {'id': _scifi, 'name': 'Sci-fi', 'count': 2},
        'items': [
          {
            'type': 'movie',
            'id': '2',
            'title': 'Zodiac',
            'year': '2007',
            'poster': _poster,
          },
          {'type': 'series', 'id': '1', 'title': 'Arrival', 'year': '2016'},
        ],
        'cursor': null,
      });
    }
    return _json({
      'error': {'code': 'not_found', 'message': 'Not found.'},
    }, 404);
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Future<FriendsController> _friends(_FakeServer server) async {
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
  return FriendsController(
    account: account,
    api: api,
    social: SocialController(account: account, api: api),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 3600);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SocialTitles.open = null);

  group('A collection', () {
    test('is private unless shared; an older saved copy reads private', () {
      final made = MediaCollection(
        id: _scifi,
        name: 'Sci-fi',
        order: 1,
        createdAt: 1,
        updatedAt: 1,
      );
      expect(made.shared, isFalse);
      expect(made.toJson().containsKey('visibility'), isFalse);
      final shared = made.copyWith(shared: true);
      expect(shared.toJson()['visibility'], 'friends');
      expect(MediaCollection.fromJson(shared.toJson())!.shared, isTrue);
      expect(MediaCollection.fromJson(made.toJson())!.shared, isFalse);
      expect(
        MediaCollection.fromJson({
          'id': _scifi,
          'name': 'Old',
          'visibility': 'everyone',
        })!.shared,
        isFalse,
      );
    });

    test('sharing is a change the sync sends', () async {
      final store = CollectionStore()..useAccount('user-1');
      await store.ready;
      final collection = await store.createCollection(name: 'Sci-fi');
      final changed = <String>[];
      CollectionStore.onRecordsChanged = (_, records) =>
          changed.addAll(records.keys);
      addTearDown(() => CollectionStore.onRecordsChanged = null);
      await store.setShared(collection.id, true);
      expect(store.library.collection(collection.id)!.shared, isTrue);
      expect(changed, ['collection:${collection.id}']);
      changed.clear();
      // Already shared: nothing to send.
      await store.setShared(collection.id, true);
      expect(changed, isEmpty);
    });
  });

  group('The collection menu', () {
    Future<CollectionStore> open(
      WidgetTester tester, {
      required bool shared,
      required bool canShare,
    }) async {
      final store = CollectionStore()..useAccount('user-1');
      await store.ready;
      final made = await store.createCollection(name: 'Sci-fi');
      if (shared) await store.setShared(made.id, true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => CollectionActions.manage(
                  context,
                  store,
                  store.library.collection(made.id)!,
                  canShare: canShare,
                ),
                child: const Text('options'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('options'));
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('offers sharing while Friends is on', (tester) async {
      final store = await open(tester, shared: false, canShare: true);
      await tester.tap(find.text('Share with friends'));
      await tester.pumpAndSettle();
      expect(store.library.collections.single.shared, isTrue);
      expect(find.text('Friends can now see Sci-fi'), findsOneWidget);
    });

    testWidgets('no sharing while Friends is off', (tester) async {
      await open(tester, shared: false, canShare: false);
      expect(find.text('Share with friends'), findsNothing);
      expect(find.text('Make private'), findsNothing);
    });

    testWidgets('a shared collection can always be made private', (
      tester,
    ) async {
      final store = await open(tester, shared: true, canShare: false);
      await tester.tap(find.text('Make private'));
      await tester.pumpAndSettle();
      expect(store.library.collections.single.shared, isFalse);
    });
  });

  testWidgets('a shared cover says so', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            CollectionCover(
              posters: [],
              icon: ReelishIcons.playlist,
              width: 100,
              shared: true,
            ),
            CollectionCover(
              posters: [],
              icon: ReelishIcons.playlist,
              width: 100,
            ),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('Shared with friends'), findsOneWidget);
    expect(find.byIcon(ReelishIcons.people), findsOneWidget);
  });

  group("A friend's shared collections", () {
    Future<FriendsController> show(
      WidgetTester tester,
      _FakeServer server,
    ) async {
      final friends = await _friends(server);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FriendScreen(
              person: const SocialPerson(handle: 'ben', displayName: 'Ben'),
              friends: friends,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return friends;
    }

    testWidgets('listed on their page, opened read-only, titles open', (
      tester,
    ) async {
      _tall(tester);
      final opened = <String>[];
      SocialTitles.open = (item) async => opened.add('${item.type}:${item.id}');
      final server = _FakeServer();
      await show(tester, server);
      expect(find.text('SHARED COLLECTIONS'), findsOneWidget);
      expect(find.text('2 titles · Space'), findsOneWidget);

      await tester.tap(find.text('Sci-fi'));
      await tester.pumpAndSettle();
      expect(find.text('Shared by Ben'), findsOneWidget);
      // Sorted by name; nothing to edit.
      final arrival = tester.getTopLeft(find.text('Arrival'));
      final zodiac = tester.getTopLeft(find.text('Zodiac'));
      expect(arrival.dx, lessThan(zodiac.dx));
      expect(find.byTooltip('Options'), findsNothing);
      await tester.tap(find.text('Zodiac'));
      expect(opened, ['movie:2']);
    });

    testWidgets('nothing shared: says so', (tester) async {
      _tall(tester);
      final server = _FakeServer()..shared = false;
      await show(tester, server);
      expect(find.text('Ben has not shared a collection yet.'), findsOne);
    });

    testWidgets('no longer shared when opened: says so', (tester) async {
      _tall(tester);
      final server = _FakeServer();
      await show(tester, server);
      server.shared = false;
      await tester.tap(find.text('Sci-fi'));
      await tester.pumpAndSettle();
      expect(
        find.text('Ben no longer shares this collection with you.'),
        findsOneWidget,
      );
    });

    test('artwork from someone else is TMDB only', () {
      final collection = SharedCollection.fromJson({
        'id': _scifi,
        'name': 'Sci-fi',
        'posters': [_poster, 'https://evil.example/x.jpg', 7],
      })!;
      expect(collection.posters, [_poster]);
      expect(
        sharedTitleFrom({
          'type': 'movie',
          'id': '1',
          'title': 'X',
          'poster': 'http://image.tmdb.org.evil/x.jpg',
        })!.poster,
        '',
      );
      expect(
        sharedTitleFrom({'type': 'person', 'id': '1', 'title': 'X'}),
        isNull,
      );
    });

    testWidgets('TV: the first title takes focus', (tester) async {
      _tall(tester);
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      final server = _FakeServer();
      await show(tester, server);
      await tester.tap(find.text('Sci-fi'));
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.descendant(
          of: find.byWidget(focused!.widget),
          matching: find.text('Arrival'),
        ),
        findsOneWidget,
      );
    });
  });
}
