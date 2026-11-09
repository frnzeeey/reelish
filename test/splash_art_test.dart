import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/platform/splash_art.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('onfeed/splash');

/// The status saved on the device for user-1, as the server last gave it.
Map<String, Object> _saved(String entitlement) => {
  'reelish.supporter.v1.user-1': jsonEncode({
    'code': 'RS-ABCD-2345',
    'status': entitlement == 'supporter' ? 'verified' : 'none',
    'entitlement': entitlement,
  }),
};

/// A signed-in account whose server answers [entitlement].
Future<(AccountController, SupporterController)> _account(
  String entitlement,
) async {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient(
      (_) async => http.Response(
        jsonEncode({
          'code': 'RS-ABCD-2345',
          'status': 'none',
          'recognition': {'listed': false, 'name': ''},
          'entitlement': entitlement,
        }),
        200,
      ),
    ),
  );
  final account = AccountController(
    api: api,
    store: MemorySessionStore(
      StoredSession(
        sessionId: 'session',
        accessToken: 'access',
        accessExpiresAt: now + 3600,
        refreshToken: 'refresh',
        refreshExpiresAt: now + 86400,
        userId: 'user-1',
        username: 'viewer',
      ),
    ),
  );
  await account.restore();
  final supporters = SupporterController(account: account, api: api);
  await supporters.restoreSaved();
  return (account, supporters);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<bool> requests;

  /// What the fake Android side answers: true on Android 13 and later.
  var applies = true;

  setUp(() {
    requests = [];
    applies = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          requests.add((call.arguments as Map)['crest'] as bool);
          return applies;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<SplashArtStore> nextLaunch({bool android = true}) async {
    final store = SplashArtStore(android: android);
    await store.load();
    return store;
  }

  test('the Reelish logo when nothing is saved', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await nextLaunch();
    expect(store.art, SplashArt.reelish);
    expect(store.nativeArt, SplashArt.reelish);
  });

  test('the Founder gets the crest, in the system splash too', () async {
    SharedPreferences.setMockInitialValues(_saved('founder'));
    final (account, supporters) = await _account('founder');
    final store = SplashArtStore(android: true);
    await store.load();
    store.attach(account, supporters);
    await store.settled;
    expect(requests, [true]);
    final next = await nextLaunch();
    expect(next.art, SplashArt.sovereignCrest);
    expect(next.nativeArt, SplashArt.sovereignCrest);
  });

  test('a Supporter keeps the logo: the crest is the Founder\'s', () async {
    SharedPreferences.setMockInitialValues(_saved('supporter'));
    final (account, supporters) = await _account('supporter');
    final store = SplashArtStore(android: true)..attach(account, supporters);
    await store.settled;
    expect(requests, [false]);
    expect((await nextLaunch()).art, SplashArt.reelish);
  });

  test(
    'below Android 13 the system splash keeps the logo, and is asked once',
    () async {
      applies = false;
      SharedPreferences.setMockInitialValues(_saved('founder'));
      final (account, supporters) = await _account('founder');
      final store = SplashArtStore(android: true)..attach(account, supporters);
      await store.settled;
      // Further changes in the same launch do not ask again.
      await supporters.refresh();
      await store.settled;
      expect(requests, [true]);
      final next = await nextLaunch();
      expect(next.art, SplashArt.sovereignCrest);
      // Flutter's splash then moves from the logo to the crest.
      expect(next.nativeArt, SplashArt.reelish);
    },
  );

  test('Windows has no system splash to set', () async {
    SharedPreferences.setMockInitialValues(_saved('founder'));
    final (account, supporters) = await _account('founder');
    final store = SplashArtStore(android: false)..attach(account, supporters);
    await store.settled;
    expect(requests, isEmpty);
    final next = await nextLaunch(android: false);
    expect(next.art, SplashArt.sovereignCrest);
    expect(next.nativeArt, SplashArt.reelish);
  });

  test('signing out brings the logo back', () async {
    SharedPreferences.setMockInitialValues(_saved('founder'));
    final (account, supporters) = await _account('founder');
    final store = SplashArtStore(android: true)..attach(account, supporters);
    await store.settled;
    await account.signOut();
    await store.settled;
    expect(requests, [true, false]);
    final next = await nextLaunch();
    expect(next.art, SplashArt.reelish);
    expect(next.nativeArt, SplashArt.reelish);
  });

  test('the logo comes back when the server no longer says Founder', () async {
    SharedPreferences.setMockInitialValues(_saved('founder'));
    final (account, supporters) = await _account('free');
    final store = SplashArtStore(android: true)..attach(account, supporters);
    await store.settled;
    await supporters.refresh();
    await store.settled;
    expect((await nextLaunch()).art, SplashArt.reelish);
  });

  test(
    'every launch tells the system splash, even when nothing changed',
    () async {
      SharedPreferences.setMockInitialValues({
        ..._saved('free'),
        'reelish.splash_art.v1': 'reelish',
        'reelish.splash_art.native.v1': 'reelish',
      });
      final (account, supporters) = await _account('free');
      final store = await nextLaunch();
      store.attach(account, supporters);
      await store.settled;
      // Android may have kept a crest this app no longer has a record of.
      expect(requests, [false]);
    },
  );
}
