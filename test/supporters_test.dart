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
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/supporters_screen.dart';
import 'package:onfeed/src/support/support_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/account_badges.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _code = 'RS-ABCD-2345';

Map<String, Object?> _body({
  String status = 'none',
  int? since,
  bool listed = false,
  String name = '',
}) => {
  'code': _code,
  'status': status,
  'since': since,
  'recognition': {'listed': listed, 'name': name},
};

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session(String userId) => StoredSession(
  sessionId: 'session',
  accessToken: 'access',
  accessExpiresAt: _now() + 3600,
  refreshToken: 'refresh',
  refreshExpiresAt: _now() + 86400,
  userId: userId,
  username: 'viewer',
);

/// A controller on a fake Reelish API. [respond] answers each request.
Future<SupporterController> _controller(
  Future<http.Response> Function(http.Request) respond, {
  String userId = 'user-1',
}) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient(respond),
  );
  final account = AccountController(
    api: api,
    store: MemorySessionStore(_session(userId)),
  );
  await account.restore();
  return SupporterController(account: account, api: api);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Future<http.Response> Function(http.Request) _api(
  Map<String, Object?> status, {
  List<Map<String, String>> supporters = const [],
}) =>
    (request) async => request.url.path.endsWith('/public')
    ? _json({'supporters': supporters})
    : _json(status);

Future<void> _show(
  WidgetTester tester,
  SupporterController controller, {
  Future<bool> Function(Uri)? openLink,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: GlassTheme.dark,
      home: SupportersScreen(controller: controller, openLink: openLink),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Status', () {
    test('reads what the server says, and nothing else', () {
      final status = SupporterStatus.fromJson(
        _body(status: 'verified', since: 1719825600, listed: true, name: 'Sam'),
      )!;
      expect(status.state, SupporterState.verified);
      expect(status.since!.year, 2024);
      expect(status.publicName, 'Sam');
      expect(
        SupporterStatus.fromJson(_body(status: 'hacked'))!.state,
        SupporterState.none,
      );
      expect(SupporterStatus.fromJson('x'), isNull);
      expect(SupporterStatus.fromJson({'status': 'verified'}), isNull);
    });

    test('the server replaces a saved status, in both directions', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.supporter.v1.user-1': jsonEncode(_body(status: 'verified')),
      });
      final controller = await _controller(_api(_body()));
      await controller.refresh();
      expect(controller.isSupporter, isFalse);
    });

    test('offline, the saved status still shows', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.supporter.v1.user-1': jsonEncode(
          _body(status: 'verified', since: 1719825600),
        ),
      });
      final controller = await _controller(
        (_) async => throw const SocketException('offline'),
      );
      await controller.refresh();
      expect(controller.isSupporter, isTrue);
      expect(controller.failed, isTrue);
    });

    test('one account never sees another account\'s saved status', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.supporter.v1.someone-else': jsonEncode(
          _body(status: 'verified'),
        ),
      });
      final controller = await _controller(
        (_) async => throw const SocketException('offline'),
      );
      await controller.refresh();
      expect(controller.isSupporter, isFalse);
    });

    test(
      'asking for a review shows as pending, never as a supporter',
      () async {
        final controller = await _controller((request) async {
          return request.method == 'POST'
              ? _json(_body(status: 'pending'))
              : _json(_body());
        });
        await controller.refresh();
        expect(await controller.requestReview(), isTrue);
        expect(controller.status!.state, SupporterState.pending);
        expect(controller.isSupporter, isFalse);
      },
    );

    test('a failed save reports it, without changing the status', () async {
      final controller = await _controller((request) async {
        return request.method == 'PUT'
            ? _json({
                'error': {'code': 'invalid_name', 'message': 'No.'},
              }, 400)
            : _json(_body(status: 'verified'));
      });
      await controller.refresh();
      expect(await controller.setRecognition(listed: true, name: 'x'), isFalse);
      expect(controller.status!.listed, isFalse);
    });
  });

  group('The page', () {
    testWidgets('invites someone who has not donated, and shows their code', (
      tester,
    ) async {
      await _show(tester, await _controller(_api(_body())));
      expect(find.text('Support Reelish'), findsOneWidget);
      expect(find.text(_code), findsOneWidget);
      expect(find.text('I forgot to add my code'), findsOneWidget);
      expect(find.byType(SupporterBadge), findsNothing);
      // One privilege, said plainly, and joining stays open to everyone.
      expect(find.textContaining('host Watch Parties'), findsOneWidget);
      expect(
        find.textContaining('anyone can join a Watch Party'),
        findsOneWidget,
      );
    });

    testWidgets('thanks a supporter, with their badge and date', (
      tester,
    ) async {
      final since = DateTime.utc(2026, 3, 15).millisecondsSinceEpoch ~/ 1000;
      await _show(
        tester,
        await _controller(_api(_body(status: 'verified', since: since))),
      );
      expect(find.text('Thank you for supporting Reelish'), findsOneWidget);
      expect(find.byType(SupporterBadge), findsOneWidget);
      expect(find.textContaining('Supporter since March 2026'), findsOneWidget);
      expect(find.text(_code), findsNothing);
      expect(find.text('Show me on the supporters list'), findsOneWidget);
    });

    testWidgets('a pending review is not shown as a badge', (tester) async {
      await _show(tester, await _controller(_api(_body(status: 'pending'))));
      expect(find.byType(SupporterBadge), findsNothing);
      expect(find.textContaining('Review requested'), findsOneWidget);
      expect(find.text('I forgot to add my code'), findsNothing);
    });

    testWidgets('the main button matches the app\'s other primary buttons', (
      tester,
    ) async {
      await _show(tester, await _controller(_api(_body())));
      final label = tester.widget<Text>(find.text('Support Reelish'));
      final style = DefaultTextStyle.of(
        tester.element(find.byWidget(label)),
      ).style;
      expect(style.fontWeight, FontWeight.w700);
    });

    group('on TV', () {
      setUp(() {
        DeviceCapabilities.debugOverride = const DeviceCapabilities(
          isTelevision: true,
          hasTouchscreen: false,
        );
      });
      tearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );

      testWidgets('says what to do elsewhere, with no button or copying', (
        tester,
      ) async {
        await _show(tester, await _controller(_api(_body())));
        expect(find.text('Support Reelish'), findsNothing);
        expect(find.text(SupportConfig.donationPageLabel), findsOneWidget);
        expect(find.text(_code), findsOneWidget);
        expect(find.textContaining('Select to copy'), findsNothing);
      });

      testWidgets('a supporter is not shown a code they no longer need', (
        tester,
      ) async {
        await _show(tester, await _controller(_api(_body(status: 'verified'))));
        expect(find.text('Support again'), findsNothing);
        expect(find.text(_code), findsNothing);
        expect(find.text(SupportConfig.donationPageLabel), findsOneWidget);
      });

      testWidgets('the remote can reach something on the page', (tester) async {
        await _show(tester, await _controller(_api(_body())));
        expect(
          find.text('I donated: check again'),
          findsOneWidget,
          reason: 'with no button, this is the first control',
        );
      });
    });

    group('the review email', () {
      /// A fake API that starts with [status] and counts review requests.
      Future<({SupporterController controller, List<String> claims})> setUp({
        String status = 'none',
      }) async {
        final claims = <String>[];
        var current = status;
        final controller = await _controller((request) async {
          if (request.url.path.endsWith('/public')) {
            return _json({'supporters': []});
          }
          if (request.url.path.endsWith('/claim')) {
            claims.add(request.method);
            current = 'pending';
          }
          return _json(_body(status: current));
        });
        return (controller: controller, claims: claims);
      }

      testWidgets('shows where to send it, and asks nothing yet', (
        tester,
      ) async {
        final fake = await setUp();
        await _show(tester, fake.controller);
        await tester.tap(find.text('I forgot to add my code'));
        await tester.pumpAndSettle();
        expect(find.text(SupportConfig.contactEmail), findsOneWidget);
        expect(find.text('Supporter review $_code'), findsOneWidget);
        expect(fake.claims, isEmpty, reason: 'nothing has been sent yet');
      });

      testWidgets('closing leaves the account as it was', (tester) async {
        final fake = await setUp();
        await _show(tester, fake.controller);
        await tester.tap(find.text('I forgot to add my code'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(fake.claims, isEmpty);
        expect(find.textContaining('Review requested'), findsNothing);
      });

      testWidgets('opening an email app alone asks for nothing', (
        tester,
      ) async {
        final fake = await setUp();
        final opened = <Uri>[];
        await _show(
          tester,
          fake.controller,
          openLink: (link) async {
            opened.add(link);
            return true;
          },
        );
        await tester.tap(find.text('I forgot to add my code'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open email app'));
        await tester.pumpAndSettle();
        expect(opened.single.scheme, 'mailto');
        expect(opened.single.path, SupportConfig.contactEmail);
        expect(opened.single.toString(), contains(_code));
        expect(fake.claims, isEmpty);
      });

      testWidgets('with no email app, it says so and the details stay', (
        tester,
      ) async {
        final fake = await setUp();
        await _show(tester, fake.controller, openLink: (_) async => false);
        await tester.tap(find.text('I forgot to add my code'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open email app'));
        await tester.pumpAndSettle();
        expect(find.textContaining('No email app was found'), findsOneWidget);
        expect(find.text(SupportConfig.contactEmail), findsOneWidget);
        expect(find.text('Copy details'), findsOneWidget);
      });

      testWidgets('only "I sent it" asks for the review', (tester) async {
        final fake = await setUp();
        await _show(tester, fake.controller);
        await tester.tap(find.text('I forgot to add my code'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('I sent it'));
        await tester.pumpAndSettle();
        expect(fake.claims, ['POST']);
        expect(find.textContaining('Review requested'), findsOneWidget);
      });

      testWidgets('stays reachable while pending', (tester) async {
        final fake = await setUp(status: 'pending');
        await _show(tester, fake.controller);
        await tester.tap(find.text('See the review email'));
        await tester.pumpAndSettle();
        expect(find.text(SupportConfig.contactEmail), findsOneWidget);
        expect(find.text('I sent it'), findsNothing);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(fake.claims, isEmpty);
      });

      testWidgets('fits a small phone', (tester) async {
        final fake = await setUp();
        await _show(tester, fake.controller);
        await tester.tap(find.text('I forgot to add my code'));
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(const Size(320, 560));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('copies the code', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _show(tester, await _controller(_api(_body())));
      await tester.tap(find.text(_code));
      await tester.pump();
      expect(copied, [_code]);
    });

    testWidgets('an empty list says so, with no made-up names', (tester) async {
      await _show(tester, await _controller(_api(_body())));
      expect(
        find.textContaining('Supporters who choose to be shown'),
        findsOneWidget,
      );
    });

    testWidgets('lists the people who chose to appear', (tester) async {
      await _show(
        tester,
        await _controller(
          _api(
            _body(),
            supporters: [
              {'name': 'Sam', 'since': '2026-03'},
            ],
          ),
        ),
      );
      expect(find.text('Sam'), findsOneWidget);
      expect(find.byType(SupporterEmblem), findsWidgets);
    });

    testWidgets('still works when the status cannot be loaded', (tester) async {
      await _show(
        tester,
        await _controller((_) async => throw const SocketException('offline')),
      );
      expect(find.text('Support Reelish'), findsOneWidget);
      expect(find.textContaining('could not be loaded'), findsWidgets);
    });

    testWidgets('fits a narrow phone with large text', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 2600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await _controller(_api(_body()));
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 2600),
            textScaler: TextScaler.linear(1.4),
          ),
          child: MaterialApp(
            theme: GlassTheme.dark,
            home: SupportersScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Configuration', () {
    test('every link to the donation page comes from one place', () {
      expect(SupportConfig.donationPage.scheme, 'https');
      expect(SupportConfig.donationPageLabel, isNot(contains('https')));
      final strays = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where((file) => !file.path.endsWith('support_service.dart'))
          .where((file) => file.readAsStringSync().contains('buymeacoffee.com'))
          .map((file) => file.path);
      expect(strays, isEmpty);
    });

    test('no webhook secret reaches the app', () {
      final text = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => file.readAsStringSync())
          .join();
      expect(text, isNot(contains('BMC_WEBHOOK_SECRET')));
    });
  });
}
