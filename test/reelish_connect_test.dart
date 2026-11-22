import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/backend_config.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/connect/connect_screen.dart';
import 'package:onfeed/src/connect/invite_controller.dart';
import 'package:onfeed/src/connect/reelish_qr.dart';
import 'package:onfeed/src/connect/share_service.dart';
import 'package:onfeed/src/connect/share_sheet.dart';
import 'package:onfeed/src/connect/share_target.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/social/social_controller.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/watch_party/party_links.dart';
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _base = Uri.parse('https://reelish-api.frnzgularez.workers.dev');
final _site = Uri.parse('https://reelishofficial.netlify.app');
final _staging = Uri.parse(
  'https://reelish-api-staging.frnzgularez.workers.dev',
);

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session() => StoredSession(
  sessionId: 'session',
  accessToken: 'access',
  accessExpiresAt: _now() + 3600,
  refreshToken: 'refresh',
  refreshExpiresAt: _now() + 86400,
  userId: 'user-1',
  username: 'viewer',
);

/// A signed-in account whose API answers with [handler].
Future<AccountController> _account(
  Future<http.Response> Function(http.Request request) handler,
) async {
  final account = AccountController(
    api: AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient(handler),
    ),
    store: MemorySessionStore(_session()),
  );
  await account.restore();
  return account;
}

/// As the Worker answers: UTF-8 JSON (its messages use curly quotes).
http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(String code, String message, int status) => _json({
  'error': {'code': code, 'message': message, 'requestId': 'r'},
}, status);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Share targets', () {
    test(
      'every kind has one web link and one app link, and both parse back',
      () {
        const targets = <ShareTarget>[
          AppInvite('ABCD2345'),
          AppInvite(),
          FriendShare('WXYZ6789'),
          TitleShare(type: 'movie', tmdbId: 550),
          TitleShare(type: 'series', tmdbId: 1399),
          PartyShare('12345678'),
        ];
        for (final target in targets) {
          final web = target.webUri(_base);
          expect(web.host, _base.host);
          expect(ShareTarget.parse(web), target, reason: '$web');
          expect(
            ShareTarget.parse(target.appUri),
            target,
            reason: '${target.appUri}',
          );
        }
        expect(
          const TitleShare(type: 'series', tmdbId: 1399).webUri(_base).path,
          '/tv/1399',
        );
      },
    );

    test('a movie and a series with the same number never meet', () {
      final movie = ShareTarget.parse(Uri.parse('reelish://movie/42'));
      final series = ShareTarget.parse(Uri.parse('reelish://tv/42'));
      expect(movie, isNot(series));
      expect((series! as TitleShare).type, 'series');
    });

    test('links as a QR code carries them, in capitals, parse the same', () {
      for (final link in [
        'HTTPS://REELISH-API.FRNZGULAREZ.WORKERS.DEV/INVITE/ABCD2345',
        'HTTPS://REELISH-API.FRNZGULAREZ.WORKERS.DEV/TV/1399',
        'HTTPS://REELISH-API.FRNZGULAREZ.WORKERS.DEV/DOWNLOAD',
      ]) {
        expect(ShareTarget.parse(Uri.parse(link)), isNotNull, reason: link);
      }
    });

    test('the party page shipped before keeps opening the party', () {
      expect(
        ShareTarget.parse(Uri.parse('$_base/api/v1/join/12345678')),
        const PartyShare('12345678'),
      );
    });

    test('anything else is ignored', () {
      for (final link in [
        'reelish://movie/0',
        'reelish://movie/abc',
        'reelish://invite/ABCD0000',
        'reelish://add/short',
        'reelish://party/1234',
        'reelish://settings/x',
        'http://reelish-api.frnzgularez.workers.dev/movie/550',
        'https://example.com/movie/550/extra',
        'javascript://movie/550',
        'reelish://movie/550/extra',
      ]) {
        expect(ShareTarget.parse(Uri.parse(link)), isNull, reason: link);
      }
    });

    test('a title shares only with a TMDB id', () {
      expect(
        TitleShare.of(
          const MediaItem(id: '550', type: 'movie', name: 'Fight Club'),
        ),
        const TitleShare(type: 'movie', tmdbId: 550),
      );
      expect(
        TitleShare.of(
          const MediaItem(id: 'tt0137523', type: 'movie', name: 'x'),
        ),
        isNull,
      );
      expect(
        TitleShare.of(const MediaItem(id: '12', type: 'person', name: 'x')),
        isNull,
      );
    });
  });

  group('Incoming links', () {
    setUp(() {
      PartyLinks.pending.value = null;
      ConnectLinks.pending.value = null;
    });

    test('parties still go to Join a party; the rest wait for Home', () {
      PartyLinks.receive('reelish://party/87654321');
      expect(PartyLinks.take(), '87654321');
      expect(ConnectLinks.take(), isNull);

      PartyLinks.receive('reelish://tv/1399');
      expect(
        ConnectLinks.take(),
        const TitleShare(type: 'series', tmdbId: 1399),
      );
      PartyLinks.receive('$_staging/add/WXYZ6789');
      expect(ConnectLinks.take(), const FriendShare('WXYZ6789'));
      expect(PartyLinks.take(), isNull);
    });

    test('long, broken and foreign links are dropped', () {
      for (final link in [
        null,
        42,
        'reelish://movie/${'9' * 200}',
        'not a link',
        'https://example.com/',
      ]) {
        PartyLinks.receive(link);
        expect(ConnectLinks.pending.value, isNull, reason: '$link');
        expect(PartyLinks.pending.value, isNull, reason: '$link');
      }
    });
  });

  group('QR codes', () {
    test('Reelish links are sent compact, leaving the centre for the logo', () {
      for (final base in [_site, _base, _staging]) {
        for (final target in const [
          AppInvite('ABCD2345'),
          FriendShare('WXYZ6789'),
          TitleShare(type: 'series', tmdbId: 1234567),
          PartyShare('12345678'),
        ]) {
          final data = ReelishQrData.encode(target.webUri(base).toString());
          // No centre alignment pattern under the logo.
          expect(data.typeNumber, inInclusiveRange(2, 6), reason: data.link);
          expect(data.logoModules, greaterThanOrEqualTo(7), reason: data.link);
          expect(
            data.logoCoverage,
            lessThanOrEqualTo(ReelishQrData.maxCoverage),
            reason: data.link,
          );
        }
      }
    });

    test('a code holds the link exactly as shared, at Q with the logo', () {
      // Scanners offer to open only links they recognise; a rewritten
      // (capitalised) link showed as text to copy.
      final link = const AppInvite('ABCD2345').webUri(_staging).toString();
      final data = ReelishQrData.encode(link);
      expect(data.link, link);
      expect(data.errorCorrection, QrErrorCorrectLevel.quartile);
      expect(data.logoModules, greaterThan(0));
      // Every module matches a plain code of the exact link: nothing was
      // rewritten on the way in.
      final reference = QrImage(
        QrCode(
          payload: QrPayload.fromString(link),
          errorCorrectLevel: QrErrorCorrectLevel.quartile,
        ),
      );
      expect(data.moduleCount, reference.moduleCount);
      for (var row = 0; row < data.moduleCount; row++) {
        for (var col = 0; col < data.moduleCount; col++) {
          expect(
            data.isDark(row, col),
            reference.isDark(row, col),
            reason: '$row,$col',
          );
        }
      }
    });

    test('a long link is drawn plain at H, never with a risky logo', () {
      final long = ReelishQrData.encode(
        'https://example.com/a-much-longer-path/with_underscores'
        '?and=query&more=1&even=more&and=then-some-more-to-be-sure',
      );
      expect(long.typeNumber, greaterThan(6));
      expect(long.errorCorrection, QrErrorCorrectLevel.high);
      expect(long.logoModules, 0);
      expect(
        long.isUnderLogo(long.moduleCount ~/ 2, long.moduleCount ~/ 2),
        isFalse,
      );
    });

    test('the logo never touches a finder pattern', () {
      final data = ReelishQrData.encode(
        const AppInvite('ABCD2345').webUri(_base).toString(),
      );
      for (var row = 0; row < data.moduleCount; row++) {
        for (var col = 0; col < data.moduleCount; col++) {
          expect(
            data.isFinder(row, col) && data.isUnderLogo(row, col),
            isFalse,
          );
        }
      }
      // A finder's corner is dark, as the standard draws it.
      expect(data.isDark(0, 0), isTrue);
      expect(data.isDark(data.moduleCount - 1, 0), isTrue);
    });

    test('the share card renders as a PNG', () async {
      final png = await ReelishQrCard.render(
        link: const PartyShare('12345678').webUri(_base).toString(),
        title: 'Join my watch party',
        subtitle: 'Code 1234 5678',
      );
      expect(png.length, greaterThan(10000));
      expect(
        png.sublist(0, 8),
        Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      );
    });
  });

  group('Share address', () {
    test('links point to the website, which forwards them', () {
      expect(BackendConfig.shareUrl, _site);
      expect(
        const AppInvite('ABCD2345').webUri(BackendConfig.shareUrl!).toString(),
        'https://reelishofficial.netlify.app/invite/ABCD2345',
      );
      // Parsed back like any other host's link.
      expect(
        ShareTarget.parse(Uri.parse('$_site/tv/1399')),
        const TitleShare(type: 'series', tmdbId: 1399),
      );
    });
  });

  group('Share text', () {
    test('every message carries its link, and says nothing private', () {
      final link = Uri.parse('https://x.test/l');
      for (final target in const <ShareTarget>[
        AppInvite('ABCD2345'),
        FriendShare('WXYZ6789'),
        TitleShare(type: 'movie', tmdbId: 550, name: 'Fight Club'),
        PartyShare('12345678'),
      ]) {
        final message = ShareService.message(target, link);
        expect(message, contains('$link'));
        expect(message.toLowerCase(), isNot(contains('free movies')));
      }
      expect(
        ShareService.message(const PartyShare('12345678'), link),
        contains('1234 5678'),
      );
      expect(
        ShareService.fileName(const TitleShare(type: 'series', tmdbId: 9)),
        'reelish-series-9',
      );
    });
  });

  group('Invitations', () {
    test('loads the code and how many joined', () async {
      final account = await _account((request) async {
        expect(request.url.path, '/api/v1/referrals/me');
        return _json({'code': 'ABCD2345', 'joined': 3, 'invited': false});
      });
      final invites = InviteController(
        account: account,
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient(
            (_) async =>
                _json({'code': 'ABCD2345', 'joined': 3, 'invited': false}),
          ),
        ),
      );
      await invites.refresh();
      expect(invites.code, 'ABCD2345');
      expect(invites.joined, 3);
      expect(invites.invited, isFalse);
      expect(invites.failed, isFalse);
    });

    test(
      'a kept invitation is accepted once signed in, then forgotten',
      () async {
        final calls = <String>[];
        final api = AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((request) async {
            calls.add('${request.method} ${request.url.path} ${request.body}');
            return _json({'credited': true}, 201);
          }),
        );
        final invites = InviteController(
          account: await _account((_) async => _json({})),
          api: api,
        );
        await InviteController.keep('ABCD2345');
        expect(await invites.acceptKept(), contains('Invitation accepted'));
        expect(calls.single, contains('POST /api/v1/referrals/claim'));
        expect(calls.single, contains('ABCD2345'));
        expect(invites.invited, isTrue);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(InviteController.pendingKey), isNull);
        // Nothing kept: nothing to say, no request.
        expect(await invites.acceptKept(), isNull);
        expect(calls, hasLength(1));
      },
    );

    test(
      'refused for good: said once and forgotten; a network failure keeps it',
      () async {
        var offline = false;
        final api = AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((_) async {
            if (offline) throw http.ClientException('offline');
            return _error('own_invite', 'That’s your own invite code.', 409);
          }),
        );
        final invites = InviteController(
          account: await _account((_) async => _json({})),
          api: api,
        );
        await InviteController.keep('ABCD2345');
        expect(await invites.acceptKept(), 'That’s your own invite code.');
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(InviteController.pendingKey), isNull);

        offline = true;
        await InviteController.keep('WXYZ6789');
        expect(await invites.acceptKept(), isNull);
        expect(preferences.getString(InviteController.pendingKey), 'WXYZ6789');
      },
    );
  });

  group('Reelish Connect page', () {
    Future<void> pump(WidgetTester tester, InviteController invites) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final social = SocialController(
        account: await tester.runAsync(
          () => _account((_) async => _json({'profile': null})),
        ),
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((_) async => _json({'profile': null})),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          home: Scaffold(
            body: ConnectScreen(invites: invites, social: social),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    testWidgets('shows the invitation, who joined, and every way to share', (
      tester,
    ) async {
      final account = await tester.runAsync(
        () => _account((_) async => _json({})),
      );
      final invites = InviteController(
        account: account,
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient(
            (_) async =>
                _json({'code': 'ABCD2345', 'joined': 2, 'invited': false}),
          ),
        ),
      );
      await pump(tester, invites);
      expect(find.text('Reelish Connect'), findsOneWidget);
      expect(find.text('ABCD-2345'), findsOneWidget);
      expect(find.text('Joined with your invitation'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Got an invite code?'), findsOneWidget);
      // Friends off: the way to turn it on, never a dead control.
      expect(find.text('Turn on Friends'), findsOneWidget);
      expect(find.text('Join with a code'), findsOneWidget);
      expect(find.text('SHARE MOVIES AND SERIES'), findsOneWidget);
    });

    testWidgets('a failed load offers a retry, not a code', (tester) async {
      final account = await tester.runAsync(
        () => _account((_) async => _json({})),
      );
      final invites = InviteController(
        account: account,
        api: AccountApi(
          baseUrl: Uri.parse('https://api.reelish.test'),
          client: MockClient((_) async => _error('unavailable', 'Down', 503)),
        ),
      );
      await pump(tester, invites);
      expect(find.text('Couldn’t load your invitation'), findsOneWidget);
      expect(find.text('Joined with your invitation'), findsNothing);
    });
  });

  group('Sharing per device', () {
    tearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );

    Future<void> open(WidgetTester tester, ShareTarget target) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ShareSheet.show(
                  context,
                  target,
                  title: 'Share Fight Club',
                  base: _base,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a title: its QR code, its link, copy and full screen', (
      tester,
    ) async {
      await open(tester, const TitleShare(type: 'movie', tmdbId: 550));
      expect(find.text('Share Fight Club'), findsOneWidget);
      expect(find.byType(ReelishQrCode), findsOneWidget);
      expect(
        find.text('reelish-api.frnzgularez.workers.dev/movie/550'),
        findsOneWidget,
      );
      expect(find.text('Copy link'), findsOneWidget);

      await tester.tap(find.text('Full screen'));
      await tester.pumpAndSettle();
      // Edge to edge, on the code's own cream.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
      expect(scaffold.backgroundColor, ReelishQrColors.paper);
      expect(find.byType(ReelishQrCode), findsOneWidget);
    });

    testWidgets('on TV: the code to scan and Close, focused for the remote', (
      tester,
    ) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      await open(tester, const PartyShare('12345678'));
      expect(find.byType(ReelishQrCode), findsOneWidget);
      expect(find.textContaining('Point a phone’s camera'), findsOneWidget);
      expect(find.text('Copy link'), findsNothing);
      expect(find.text('Share link'), findsNothing);
      expect(Focus.of(tester.element(find.text('Close'))).hasFocus, isTrue);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(ReelishQrCode), findsNothing);
    });

    testWidgets('a build without a Reelish API says so, with no dialog', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ShareSheet.show(
                  context,
                  const AppInvite('ABCD2345'),
                  title: 'Invite',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text('Sharing isn’t available in this build.'),
        findsOneWidget,
      );
      expect(find.byType(ReelishQrCode), findsNothing);
    });

    test('a TV shows codes; it has no share sheet', () {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      expect(ShareService.canShare, isFalse);
      expect(ShareService.showsOnly, isTrue);
    });
  });
}
