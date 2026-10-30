import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/backend_config.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:onfeed/src/screens/sign_in_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'dart:io';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session({int accessIn = 900, int refreshIn = 86400}) =>
    StoredSession(
      sessionId: 's1',
      accessToken: 'access-1',
      accessExpiresAt: _now() + accessIn,
      refreshToken: 'refresh-1',
      refreshExpiresAt: _now() + refreshIn,
      userId: 'u1',
      username: 'viewer',
    );

Map<String, Object> _tokens(int n) => {
  'sessionId': 's1',
  'accessToken': 'access-$n',
  'accessExpiresAt': _now() + 900,
  'refreshToken': 'refresh-$n',
  'refreshExpiresAt': _now() + 86400,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _error(int status, String code) => _json({
  'error': {'code': code, 'message': code},
}, status);

AccountController _controller(
  MockClientHandler handler, [
  StoredSession? stored,
]) => AccountController(
  api: AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient(handler),
  ),
  store: MemorySessionStore(stored),
);

void main() {
  group('BackendConfig', () {
    test('accepts HTTPS addresses only', () {
      expect(BackendConfig.parse('https://api.reelish.app/'), isNotNull);
      expect(BackendConfig.parse('http://127.0.0.1:8787'), isNull);
      expect(BackendConfig.parse('http://api.reelish.app'), isNull);
      expect(BackendConfig.parse('https://api.reelish.app?x=1'), isNull);
      expect(BackendConfig.parse(''), isNull);
      expect(BackendConfig.parse('not a url'), isNull);
    });
  });

  group('AccountController', () {
    test('restores a stored session without touching the network', () async {
      var calls = 0;
      final account = _controller((_) async {
        calls++;
        return _json({});
      }, _session());
      await account.restore();
      expect(account.status, AccountStatus.signedIn);
      expect(account.username, 'viewer');
      expect(await account.accessToken(), 'access-1');
      expect(calls, 0);
    });

    test('a session past its refresh expiry is cleared', () async {
      final store = MemorySessionStore(_session(refreshIn: -1));
      final account = AccountController(
        api: AccountApi(baseUrl: null),
        store: store,
      );
      await account.restore();
      expect(account.status, AccountStatus.signedOut);
      expect(store.session, isNull);
    });

    test('concurrent callers share one refresh of a stale token', () async {
      var refreshes = 0;
      final account = _controller((request) async {
        expect(request.url.path, '/api/v1/auth/refresh');
        expect(jsonDecode(request.body), {'refreshToken': 'refresh-1'});
        refreshes++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _json({'session': _tokens(2)});
      }, _session(accessIn: 10));
      await account.restore();
      final tokens = await Future.wait([
        account.accessToken(),
        account.accessToken(),
        account.accessToken(),
      ]);
      expect(tokens, ['access-2', 'access-2', 'access-2']);
      expect(refreshes, 1);
    });

    test('a rejected refresh signs out and says why', () async {
      final account = _controller(
        (_) async => _error(401, 'invalid_refresh'),
        _session(accessIn: 10),
      );
      await account.restore();
      expect(await account.accessToken(), isNull);
      expect(account.status, AccountStatus.signedOut);
      expect(account.endedReason, contains('Sign in again'));
    });

    test('an offline refresh keeps the session for later', () async {
      final account = _controller(
        (_) async => throw const SocketException('offline'),
        _session(accessIn: 10),
      );
      await account.restore();
      await expectLater(
        account.accessToken(),
        throwsA(isA<AccountApiException>()),
      );
      expect(account.status, AccountStatus.signedIn);
    });

    test('sign out clears the session even when offline', () async {
      final store = MemorySessionStore(_session());
      final account = AccountController(
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((_) async => throw const SocketException('x')),
        ),
        store: store,
      );
      await account.restore();
      await account.signOut();
      expect(account.status, AccountStatus.signedOut);
      expect(store.session, isNull);
    });

    test('without a configured service, sign-in explains why', () async {
      final account = AccountController(
        api: AccountApi(baseUrl: null),
        store: MemorySessionStore(),
      );
      await account.restore();
      final signIn = account.startSignIn();
      await Future<void>.delayed(Duration.zero);
      expect(signIn.phase, DeviceSignInPhase.failed);
      expect(signIn.error, contains('no Reelish service'));
      signIn.dispose();
    });
  });

  group('Device sign-in', () {
    testWidgets('polls at the interval until approved, then signs in', (
      tester,
    ) async {
      var polls = 0;
      Map? startBody;
      final store = MemorySessionStore();
      final account = AccountController(
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/device/start')) {
              startBody = jsonDecode(request.body) as Map;
              return _json({
                'pollToken': 'p' * 43,
                'userCode': 'ABCD1234',
                'verificationUrl': 'https://trakt.tv/activate',
                'expiresIn': 600,
                'interval': 2,
              });
            }
            polls++;
            if (polls < 3) {
              return _json({'status': 'pending', 'interval': 2}, 202);
            }
            return _json({
              'status': 'authorized',
              'session': _tokens(1),
              'user': {'id': 'u9', 'username': 'traktfan'},
            });
          }),
        ),
        store: store,
      );
      await account.restore();
      final signIn = account.startSignIn(method: SignInMethod.code);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(signIn.phase, DeviceSignInPhase.waiting);
      expect(signIn.code!.userCode, 'ABCD1234');
      expect(startBody?['platform'], 'android');

      await tester.pump(const Duration(seconds: 1));
      expect(polls, 0, reason: 'not before the interval');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(polls, 3);
      expect(signIn.phase, DeviceSignInPhase.done);
      expect(account.status, AccountStatus.signedIn);
      expect(account.username, 'traktfan');
      expect(store.session?.refreshToken, 'refresh-1');
      signIn.dispose();
    });

    testWidgets('a declined or expired code stops polling', (tester) async {
      for (final (code, phase) in [
        ('sign_in_denied', DeviceSignInPhase.denied),
        ('sign_in_expired', DeviceSignInPhase.expired),
      ]) {
        var polls = 0;
        final account = _controller((request) async {
          if (request.url.path.endsWith('/device/start')) {
            return _json({
              'pollToken': 'p' * 43,
              'userCode': 'X',
              'verificationUrl': 'https://trakt.tv/activate',
              'expiresIn': 600,
              'interval': 1,
            });
          }
          polls++;
          return _error(code == 'sign_in_denied' ? 403 : 410, code);
        });
        await account.restore();
        final signIn = account.startSignIn(method: SignInMethod.code);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(signIn.phase, phase);
        await tester.pump(const Duration(seconds: 10));
        expect(polls, 1);
        expect(account.status, AccountStatus.signedOut);
        signIn.dispose();
      }
    });
  });

  group('Browser sign-in', () {
    const authorize =
        'https://trakt.tv/oauth/authorize?response_type=code&state=s';

    http.Response webStart([String url = authorize]) => _json({
      'pollToken': 'w' * 43,
      'authorizeUrl': url,
      'expiresIn': 600,
      'interval': 4,
    });

    testWidgets('opens Trakt, polls the web endpoint, then signs in', (
      tester,
    ) async {
      final opened = <Uri>[];
      final paths = <String>[];
      var polls = 0;
      final account = AccountController(
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/web/start')) return webStart();
            polls++;
            if (polls < 2) {
              return _json({'status': 'pending', 'interval': 4}, 202);
            }
            return _json({
              'status': 'authorized',
              'session': _tokens(1),
              'user': {'id': 'u9', 'username': 'browserfan'},
            });
          }),
        ),
        store: MemorySessionStore(),
        openBrowser: (url) async {
          opened.add(url);
          return true;
        },
      );
      await account.restore();
      final signIn = account.startSignIn(method: SignInMethod.browser);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(signIn.phase, DeviceSignInPhase.waiting);
      expect(opened.single.toString(), authorize);
      expect(signIn.code, isNull);

      for (var i = 0; i < 2; i++) {
        await tester.pump(const Duration(seconds: 4));
      }
      expect(paths.where((p) => p.endsWith('/web/poll')), hasLength(2));
      expect(paths.any((p) => p.contains('/device/')), false);
      expect(signIn.phase, DeviceSignInPhase.done);
      expect(account.username, 'browserfan');
      signIn.dispose();
    });

    testWidgets('falls back to a code where the API has it turned off', (
      tester,
    ) async {
      final opened = <Uri>[];
      final account = AccountController(
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/web/start')) {
              return _error(503, 'web_sign_in_unavailable');
            }
            return _json({
              'pollToken': 'p' * 43,
              'userCode': 'CODE1234',
              'verificationUrl': 'https://trakt.tv/activate',
              'expiresIn': 600,
              'interval': 5,
            });
          }),
        ),
        store: MemorySessionStore(),
        openBrowser: (url) async {
          opened.add(url);
          return true;
        },
      );
      await account.restore();
      final signIn = account.startSignIn(method: SignInMethod.browser);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(signIn.method, SignInMethod.code);
      expect(signIn.phase, DeviceSignInPhase.waiting);
      expect(signIn.code!.userCode, 'CODE1234');
      expect(opened, isEmpty);
      signIn.dispose();
    });

    testWidgets('never opens an address that is not on Trakt', (tester) async {
      for (final url in [
        'https://evil.example/oauth/authorize',
        'http://trakt.tv/oauth/authorize',
        'https://trakt.tv.evil.example/x',
        'https://user@trakt.tv/x',
        'https://trakt.tv:8443/x',
        'intent://trakt.tv/x',
      ]) {
        final opened = <Uri>[];
        final account = AccountController(
          api: AccountApi(
            baseUrl: Uri.parse('https://api.reelish.test'),
            client: MockClient((_) async => webStart(url)),
          ),
          store: MemorySessionStore(),
          openBrowser: (url) async {
            opened.add(url);
            return true;
          },
        );
        await account.restore();
        final signIn = account.startSignIn(method: SignInMethod.browser);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(signIn.phase, DeviceSignInPhase.failed, reason: url);
        expect(opened, isEmpty, reason: url);
        signIn.dispose();
      }
    });

    testWidgets('a browser that will not open is reported, polling goes on', (
      tester,
    ) async {
      final account = AccountController(
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/web/start')) return webStart();
            return _json({'status': 'pending', 'interval': 4}, 202);
          }),
        ),
        store: MemorySessionStore(),
        openBrowser: (_) async => false,
      );
      await account.restore();
      final signIn = account.startSignIn(method: SignInMethod.browser);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(signIn.phase, DeviceSignInPhase.waiting);
      expect(signIn.browserFailed, true);
      signIn.dispose();
    });
  });

  group('Sign-in screen', () {
    Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
      final loader = FontLoader('Montserrat');
      for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/Montserrat-$weight.ttf'));
      }
      await loader.load();
    });

    AccountController browserAccount() => AccountController(
      api: AccountApi(
        baseUrl: Uri.parse('https://api.reelish.test'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/web/start')) {
            return _json({
              'pollToken': 'w' * 43,
              'authorizeUrl': 'https://trakt.tv/oauth/authorize',
              'expiresIn': 600,
              'interval': 4,
            });
          }
          if (request.url.path.endsWith('/device/start')) {
            return _json({
              'pollToken': 'p' * 43,
              'userCode': 'ABCD1234',
              'verificationUrl': 'https://trakt.tv/activate',
              'expiresIn': 600,
              'interval': 5,
            });
          }
          return _json({'status': 'pending', 'interval': 5}, 202);
        }),
      ),
      store: MemorySessionStore(),
      openBrowser: (_) async => true,
    );

    Widget app(AccountController account) => MaterialApp(
      theme: GlassTheme.dark,
      home: AccountGate(account: account, child: const Text('Home')),
    );

    for (final (name, size) in [
      ('small phone', const Size(320, 640)),
      ('phone', const Size(412, 892)),
    ]) {
      testWidgets('phone: browser first, code on request ($name)', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await loadFonts(tester);
        final account = browserAccount();
        await account.restore();
        await tester.pumpWidget(app(account));
        await tester.pump();

        expect(find.text('Sign in to Reelish'), findsOneWidget);
        expect(find.text('Continue with Trakt'), findsOneWidget);
        expect(find.text('Sign in with a code instead'), findsOneWidget);

        await tester.tap(find.text('Continue with Trakt'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Continue in your browser'), findsOneWidget);
        expect(find.text('Open Trakt again'), findsOneWidget);

        await tester.tap(find.text('Use a code instead'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('ABCD1234'), findsOneWidget);
        expect(find.text('Copy code and open Trakt'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.text('Cancel'));
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Continue with Trakt'), findsOneWidget);
      });
    }

    testWidgets(
      'Windows: browser sign-in with the same choices',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await loadFonts(tester);
        final account = browserAccount();
        await account.restore();
        await tester.pumpWidget(app(account));
        await tester.pump();
        expect(find.text('Continue with Trakt'), findsOneWidget);
        expect(find.text('Sign in with a code instead'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('TV: a code to enter elsewhere, no browser buttons', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.reset);
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      await loadFonts(tester);
      final account = browserAccount();
      await account.restore();
      await tester.pumpWidget(app(account));
      await tester.pump();
      expect(find.text('Sign in with a code instead'), findsNothing);

      await tester.tap(find.text('Sign in with Trakt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('ABCD1234'), findsOneWidget);
      expect(find.textContaining('On your phone or computer'), findsOneWidget);
      expect(find.text('Copy code and open Trakt'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Account settings', () {
    testWidgets('opens from Settings on a themed page with the profile', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final saved = AccountController.instance;
      addTearDown(() => AccountController.instance = saved);
      final account = AccountController(store: MemorySessionStore(_session()));
      await account.restore();
      AccountController.instance = account;
      final accent = AccentSettingsController();
      addTearDown(accent.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: SettingsScreen(
              onPlaybackSettings: () {},
              onAppearanceSettings: () {},
              accentSettings: accent,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Profile and account'));
      await tester.pumpAndSettle();

      // Text outside a Material draws in the debug fallback style (yellow
      // underlines): the page must bring its own Scaffold.
      final subtitle = find.text(
        'Your profile and Trakt sign-in on this device.',
      );
      expect(subtitle, findsOneWidget);
      expect(
        find.ancestor(of: subtitle, matching: find.byType(Scaffold)),
        findsOneWidget,
      );
      expect(find.text('viewer'), findsOneWidget);
      expect(find.text('Signed in with Trakt'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('DANGER ZONE'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('DANGER ZONE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('TmdbService through the gateway', () {
    TmdbService service(
      MockClient client,
      Future<String?> Function({bool forceRefresh}) token,
    ) => TmdbService(
      baseUrl: 'https://api.reelish.app/api/v1/tmdb',
      accessToken: token,
      testClient: client,
      network: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('8.8.8.8')],
      ),
      cache: TmdbResponseCache(
        directory: Directory.systemTemp.createTempSync('reelish-account-'),
      ),
      wait: (_) async {},
      jitter: () => 0,
    );

    test('sends the session token, never a TMDB key', () async {
      final requests = <http.BaseRequest>[];
      final tmdb = service(
        MockClient((request) async {
          requests.add(request);
          return _json({'page': 1, 'results': []});
        }),
        ({bool forceRefresh = false}) async => 'access-1',
      );
      await tmdb.popular('movie');
      expect(requests, hasLength(1));
      expect(requests.single.url.host, 'api.reelish.app');
      expect(requests.single.url.path, '/api/v1/tmdb/movie/popular');
      expect(requests.single.url.queryParameters.containsKey('api_key'), false);
      expect(requests.single.headers['Authorization'], 'Bearer access-1');
    });

    test('a 401 refreshes the session once and resends', () async {
      final seen = <String?>[];
      final refreshes = <bool>[];
      final tmdb = service(
        MockClient((request) async {
          seen.add(request.headers['Authorization']);
          return seen.length == 1
              ? _error(401, 'token_expired')
              : _json({'page': 1, 'results': []});
        }),
        ({bool forceRefresh = false}) async {
          refreshes.add(forceRefresh);
          return forceRefresh ? 'access-2' : 'access-1';
        },
      );
      await tmdb.popular('series');
      expect(seen, ['Bearer access-1', 'Bearer access-2']);
      expect(refreshes, [false, true]);
    });

    test(
      'signed out, the catalog asks for a sign-in without a request',
      () async {
        var requests = 0;
        final tmdb = service(
          MockClient((_) async {
            requests++;
            return _json({});
          }),
          ({bool forceRefresh = false}) async => null,
        );
        await expectLater(
          tmdb.popular('movie'),
          throwsA(isA<TmdbSignedOutException>()),
        );
        expect(requests, 0);
      },
    );
  });
}
