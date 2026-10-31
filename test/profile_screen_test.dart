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
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/account_settings_screen.dart';
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/screens/tv/tv_home_shell.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage extends StorageService {
  _Storage({this.historyItems = const [], this.favoriteItems = const []});

  final List<MediaItem> historyItems;
  final List<MediaItem> favoriteItems;
  var reads = 0;

  @override
  Future<List<MediaItem>> history() async {
    reads++;
    return historyItems;
  }

  @override
  Future<List<MediaItem>> favorites() async => favoriteItems;
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  late AccountController account;
  late ProfileController profile;
  late List<String> calls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        return http.Response(jsonEncode({}), 200);
      }),
    );
    account = AccountController(
      api: api,
      store: MemorySessionStore(
        StoredSession(
          sessionId: 's1',
          accessToken: 'access-1',
          accessExpiresAt: _now() + 900,
          refreshToken: 'refresh-1',
          refreshExpiresAt: _now() + 86400,
          userId: 'u1',
          username: 'franze',
        ),
      ),
    );
    await account.restore();
    profile = ProfileController(directory: () async => Directory.systemTemp);
    await profile.loadFor('u1');
    await profile.setDisplayName('Franz');
  });

  Widget app(Widget page) => MaterialApp(
    theme: GlassTheme.dark,
    home: Scaffold(body: page),
  );

  test('activity counts My list, watched, and titles left part-way', () {
    final activity = ProfileActivity.from(
      favorites: const [
        MediaItem(id: '1', type: 'movie', name: 'A'),
        MediaItem(id: '2', type: 'movie', name: 'B'),
      ],
      history: const [
        MediaItem(
          id: '3',
          type: 'movie',
          name: 'C',
          resumeMs: 600000,
          durationMs: 6000000,
        ),
        MediaItem(
          id: '4',
          type: 'movie',
          name: 'D',
          resumeMs: 5990000,
          durationMs: 6000000,
        ),
        MediaItem(id: '5', type: 'series', name: 'E', resumeMs: 1000),
        MediaItem(id: '6', type: 'movie', name: 'F'),
      ],
    );
    expect(activity.myList, 2);
    expect(activity.watched, 4);
    expect(activity.inProgress, 2, reason: 'C and E; D is at its end');
    expect(activity.isEmpty, isFalse);
  });

  testWidgets('shows who is signed in and their activity from this device', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    var libraryOpened = 0;
    final storage = _Storage(
      favoriteItems: const [MediaItem(id: '1', type: 'movie', name: 'A')],
      historyItems: const [
        MediaItem(id: '3', type: 'movie', name: 'C', resumeMs: 1000),
      ],
    );
    await tester.pumpWidget(
      app(
        ProfileScreen(
          storage: storage,
          account: account,
          profile: profile,
          onOpenLibrary: () => libraryOpened++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Franz'), findsOneWidget);
    // The name once: the Trakt username is not repeated under it.
    expect(find.textContaining('franze'), findsNothing);
    expect(find.text('Signed in with Trakt'), findsOneWidget);
    expect(find.bySemanticsLabel('1 On My list'), findsOneWidget);
    expect(find.bySemanticsLabel('1 Watched'), findsOneWidget);
    expect(find.bySemanticsLabel('1 In progress'), findsOneWidget);
    expect(calls, isEmpty, reason: 'no network request to show the page');

    await tester.tap(find.text('On My list'));
    expect(libraryOpened, 1);
    await tester.tap(find.text('Open my library'));
    expect(libraryOpened, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a display name the username shows once, with a '
      'prompt to add one', (tester) async {
    final unnamed = ProfileController(
      directory: () async => Directory.systemTemp,
    );
    await unnamed.loadFor('u2');
    await tester.pumpWidget(
      app(
        ProfileScreen(storage: _Storage(), account: account, profile: unnamed),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('franze'), findsOneWidget);
    expect(find.textContaining('@franze'), findsNothing);
    expect(find.text('Signed in with Trakt'), findsOneWidget);
    expect(
      find.text(
        'Add a display name so friends recognise you in watch parties.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an empty library says what will appear', (tester) async {
    await tester.pumpWidget(
      app(
        ProfileScreen(storage: _Storage(), account: account, profile: profile),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Titles you watch and add to My list show up here.'),
      findsOneWidget,
    );
    expect(find.text('Open my library'), findsNothing, reason: 'no callback');
  });

  testWidgets('re-reads the activity when asked, not on every rebuild', (
    tester,
  ) async {
    final storage = _Storage();
    Widget page(int token) => app(
      ProfileScreen(
        storage: storage,
        account: account,
        profile: profile,
        refreshToken: token,
      ),
    );
    await tester.pumpWidget(page(0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page(0));
    await tester.pumpAndSettle();
    expect(storage.reads, 1);
    await tester.pumpWidget(page(1));
    await tester.pumpAndSettle();
    expect(storage.reads, 2);
  });

  testWidgets('Edit profile opens the existing Profile and account page', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        ProfileScreen(storage: _Storage(), account: account, profile: profile),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountSettingsScreen), findsOneWidget);
  });

  testWidgets('sign out asks first, and only then ends the session', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        ProfileScreen(storage: _Storage(), account: account, profile: profile),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Sign out'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(account.status, AccountStatus.signedIn);

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(account.status, AccountStatus.signedOut);
    expect(calls, contains('POST /api/v1/auth/logout'));
    // No personal details once signed out.
    expect(find.text('Franz'), findsNothing);
  });

  test('the TV rail puts Profile first, then every destination once', () {
    expect(tvRailOrder.first, TvDestination.profile);
    expect(tvRailOrder.toSet(), TvDestination.values.toSet());
    expect(tvRailOrder, hasLength(TvDestination.values.length));
  });
}
