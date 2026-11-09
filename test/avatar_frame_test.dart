import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_badges.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/avatar_frames.dart';
import 'package:onfeed/src/account/profile_controller.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/screens/avatar_frames_screen.dart';
import 'package:onfeed/src/screens/profile_screen.dart';
import 'package:onfeed/src/screens/watch_party/party_widgets.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/avatar_frames.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/watch_party/party_models.dart';
import 'package:onfeed/src/widgets/avatar_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A fake Reelish API for one signed-in account. [entitlement] answers
/// /supporters/me; [frames] is what /me reports, and PUT /me/frame changes
/// it as the server would (refusing what [allowed] does not hold).
class _Server {
  _Server(this.entitlement, {this.equipped, Set<String>? allowed})
    : allowed = allowed ?? {};

  String entitlement;
  String? equipped;
  Set<String> allowed;
  bool offline = false;
  int meCalls = 0;

  Map<String, Object?> get frames => {
    'equipped': equipped,
    'available': allowed.toList(),
    'collected': <String>[],
  };

  Future<(AccountController, SupporterController, AvatarFrames)> start({
    String userId = 'user-1',
  }) async {
    final api = AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient((request) async {
        if (offline) throw const SocketException('offline');
        final path = request.url.path;
        if (path.endsWith('/supporters/me')) {
          return http.Response(
            jsonEncode({
              'code': 'RS-ABCD-2345',
              'status': entitlement == 'supporter' ? 'verified' : 'none',
              'recognition': {'listed': false, 'name': ''},
              'entitlement': entitlement,
            }),
            200,
          );
        }
        if (path.endsWith('/me/frame')) {
          final id = (jsonDecode(request.body) as Map)['frame'] as String?;
          if (id != null && !allowed.contains(id)) {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'supporter_required',
                  'message': 'Avatar frames are for Reelish Supporters.',
                },
              }),
              403,
            );
          }
          equipped = id;
          return http.Response(jsonEncode({'frames': frames}), 200);
        }
        if (path.endsWith('/me')) {
          meCalls++;
          return http.Response(
            jsonEncode({
              'user': {'id': userId, 'username': 'viewer'},
              'badges': <String>[],
              'frames': frames,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
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
          username: 'viewer',
        ),
      ),
    );
    await account.restore();
    return (
      account,
      SupporterController(account: account, api: api),
      AvatarFrames(account: account, api: api),
    );
  }
}

const _supporterFrames = {
  'aurora',
  'celestial',
  'royal',
  'rose_gold',
  'eclipse',
  'nebula',
  'prism',
  'obsidian',
  'supporter',
  'premiere_2026',
};

Widget _app(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: Center(child: child)),
  ),
);

Widget _disc(double size) => SizedBox.square(dimension: size);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('The collection', () {
    test('every frame has a unique, stable id the server lists too', () {
      final ids = AvatarFrameStyle.all.map((style) => style.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.toSet(), {..._supporterFrames, 'founder'});
      expect(
        AvatarFrameStyle.all
            .where((style) => style.founderOnly)
            .map((s) => s.id),
        ['founder'],
      );
      expect(AvatarFrameStyle.byId('premiere_2026')!.limited, isTrue);
      expect(AvatarFrameStyle.byId('retired_frame'), isNull);
      expect(AvatarFrameStyle.byId(null), isNull);
    });

    test('the backend catalog names the same frames', () {
      final source = File('backend/src/frames.ts').readAsStringSync();
      for (final style in AvatarFrameStyle.all) {
        expect(source, contains("id: '${style.id}'"), reason: style.id);
      }
    });

    testWidgets('every frame draws at small, standard and large sizes', (
      tester,
    ) async {
      for (final style in AvatarFrameStyle.all) {
        for (final size in [40.0, 84.0, 132.0]) {
          await tester.pumpWidget(
            _app(AvatarFrame(style: style, size: size, child: _disc(size))),
          );
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull, reason: '${style.id} $size');
          // The avatar keeps its own size inside the frame.
          final pad = AvatarFrame.paddingFor(size, style);
          expect(
            tester.getSize(find.byType(AvatarFrame)),
            Size.square(size + pad * 2),
          );
        }
      }
    });
  });

  group('Motion', () {
    testWidgets('a moving frame loops, and stops when it leaves', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          AvatarFrame(
            style: AvatarFrameStyle.founder,
            size: 100,
            child: _disc(100),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 9));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a still frame never ticks', (tester) async {
      await tester.pumpWidget(
        _app(
          AvatarFrame(
            style: AvatarFrameStyle.celestial,
            size: 100,
            child: _disc(100),
          ),
        ),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    group('The Sovereign sheen', () {
      final sheen = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() == '_SheenPainter',
      );

      test('is the Founder frame, named Sovereign, with its id kept', () {
        final style = AvatarFrameStyle.founder;
        expect(style.id, 'founder');
        expect(style.name, 'Sovereign');
        expect(style.motion, FrameMotion.sheen);
        expect(AvatarFrame.periodOf(style), const Duration(seconds: 7));
      });

      testWidgets('sweeps over the laurel while it moves', (tester) async {
        await tester.pumpWidget(
          _app(
            AvatarFrame(
              style: AvatarFrameStyle.founder,
              size: 132,
              child: _disc(132),
            ),
          ),
        );
        expect(sheen, findsOneWidget);
        // Through a sweep, its sparkle and the rest after it.
        for (var ms = 0; ms < 7000; ms += 250) {
          await tester.pump(const Duration(milliseconds: 250));
          expect(tester.takeException(), isNull, reason: '$ms ms');
        }
        expect(tester.binding.hasScheduledFrame, isTrue);
      });

      testWidgets('is not drawn on a still frame', (tester) async {
        for (final (size, reduceMotion, animate) in [
          (132.0, true, true),
          (132.0, false, false),
          (40.0, false, true),
        ]) {
          await tester.pumpWidget(
            _app(
              AvatarFrame(
                style: AvatarFrameStyle.founder,
                size: size,
                animate: animate,
                child: _disc(size),
              ),
              reduceMotion: reduceMotion,
            ),
          );
          await tester.pump();
          expect(sheen, findsNothing, reason: '$size $reduceMotion $animate');
          expect(tester.binding.hasScheduledFrame, isFalse);
        }
      });
    });

    testWidgets('reduced motion shows the still frame', (tester) async {
      await tester.pumpWidget(
        _app(
          AvatarFrame(
            style: AvatarFrameStyle.aurora,
            size: 100,
            child: _disc(100),
          ),
          reduceMotion: true,
        ),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('pauses in the background and on a covered page', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          AvatarFrame(
            style: AvatarFrameStyle.roseGold,
            size: 100,
            child: _disc(100),
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pumpWidget(
        _app(
          TickerMode(
            enabled: false,
            child: AvatarFrame(
              style: AvatarFrameStyle.roseGold,
              size: 100,
              child: _disc(100),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('stops when scrolled out of view, and starts on return', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  AvatarFrame(
                    style: AvatarFrameStyle.prism,
                    size: 100,
                    child: _disc(100),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.binding.hasScheduledFrame, isTrue);
      scroll.jumpTo(1000);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isTrue);
    });
  });

  group('The account\'s frames', () {
    test('come from the server and are saved for this account', () async {
      final server = _Server(
        'supporter',
        equipped: 'nebula',
        allowed: _supporterFrames,
      );
      final (_, _, frames) = await server.start();
      await frames.refresh();
      expect(frames.equipped, 'nebula');
      expect(frames.mayEquip('aurora'), isTrue);
      expect(frames.mayEquip('founder'), isFalse);
      // Offline next launch: the saved frame shows at once.
      server.offline = true;
      final (_, _, again) = await server.start();
      await again.refresh();
      expect(again.equipped, 'nebula');
    });

    test('equipping follows the server, so a second device sees it', () async {
      final server = _Server('supporter', allowed: _supporterFrames);
      final (_, _, phone) = await server.start();
      await phone.refresh();
      expect(await phone.equip('royal'), FrameChange.applied);
      expect(phone.equipped, 'royal');
      final (_, _, tv) = await server.start();
      await tv.refresh();
      expect(tv.equipped, 'royal');
    });

    test('a free account cannot equip one, whatever it asks', () async {
      final server = _Server('free');
      final (_, _, frames) = await server.start();
      await frames.refresh();
      expect(await frames.equip('aurora'), FrameChange.notAllowed);
      expect(frames.equipped, isNull);
    });

    test(
      'a saved frame edited on the device is replaced by the server',
      () async {
        SharedPreferences.setMockInitialValues({
          'reelish.frames.v1.user-1': jsonEncode({
            'equipped': 'founder',
            'available': ['founder'],
          }),
        });
        final server = _Server('free');
        final (_, _, frames) = await server.start();
        await frames.refresh();
        expect(frames.equipped, isNull);
        expect(frames.mayEquip('founder'), isFalse);
      },
    );

    test('when support ends the server stops reporting the frame', () async {
      final server = _Server(
        'supporter',
        equipped: 'eclipse',
        allowed: _supporterFrames,
      );
      final (_, _, frames) = await server.start();
      await frames.refresh();
      expect(frames.equipped, 'eclipse');
      server
        ..entitlement = 'free'
        ..equipped = null
        ..allowed = {};
      await frames.refresh();
      expect(frames.equipped, isNull);
    });

    test('another account never sees this one\'s saved frame', () async {
      SharedPreferences.setMockInitialValues({
        'reelish.frames.v1.someone-else': jsonEncode({'equipped': 'founder'}),
      });
      final server = _Server('free')..offline = true;
      final (_, _, frames) = await server.start();
      await frames.refresh();
      expect(frames.equipped, isNull);
    });

    test('signing out clears it', () async {
      final server = _Server(
        'supporter',
        equipped: 'aurora',
        allowed: _supporterFrames,
      );
      final (account, _, frames) = await server.start();
      await frames.refresh();
      await account.signOut();
      await frames.refresh();
      expect(frames.equipped, isNull);
    });
  });

  group('The profile', () {
    Future<AvatarFrames> show(WidgetTester tester, _Server server) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late AccountController account;
      late AvatarFrames frames;
      final files = Directory.systemTemp.createTempSync('frames');
      final profile = ProfileController(directory: () async => files);
      await tester.runAsync(() async {
        (account, _, frames) = await server.start();
        await frames.refresh();
        await profile.loadFor('user-1');
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: ProfileScreen(
              storage: StorageService(filesDirectory: () async => files),
              account: account,
              profile: profile,
              badges: AccountBadges(account: account),
              frames: frames,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return frames;
    }

    testWidgets('wears the equipped frame round any avatar', (tester) async {
      await show(
        tester,
        _Server('supporter', equipped: 'royal', allowed: _supporterFrames),
      );
      final frame = tester.widget<AvatarFrame>(find.byType(AvatarFrame));
      expect(frame.style, AvatarFrameStyle.royal);
      expect(find.text('Royal'), findsOneWidget);
      // Changing the avatar stays possible, and keeps the frame.
      expect(find.byTooltip('Change avatar'), findsOneWidget);
    });

    testWidgets('a free account keeps its usual profile', (tester) async {
      await show(tester, _Server('free'));
      expect(find.byType(AvatarFrame), findsNothing);
      expect(find.text('Avatar frame'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
    });

    testWidgets('the Founder wears the Sovereign frame', (tester) async {
      await show(
        tester,
        _Server(
          'founder',
          equipped: 'founder',
          allowed: {..._supporterFrames, 'founder'},
        ),
      );
      final frame = tester.widget<AvatarFrame>(find.byType(AvatarFrame));
      expect(frame.style, AvatarFrameStyle.founder);
    });

    testWidgets('an unknown frame from the server shows none', (tester) async {
      await show(
        tester,
        _Server('supporter', equipped: 'from_a_newer_app', allowed: {}),
      );
      expect(find.byType(AvatarFrame), findsNothing);
    });
  });

  group('The Avatar frame page', () {
    Future<_Server> show(WidgetTester tester, _Server server) async {
      tester.view.physicalSize = const Size(412, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late SupporterController supporters;
      late AvatarFrames frames;
      late AccountController account;
      final files = Directory.systemTemp.createTempSync('frames');
      final profile = ProfileController(directory: () async => files);
      await tester.runAsync(() async {
        (account, supporters, frames) = await server.start();
        await supporters.refresh();
        await frames.refresh();
        await profile.loadFor('user-1');
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: AvatarFramesScreen(
              onBack: () {},
              frames: frames,
              supporters: supporters,
              account: account,
              profile: profile,
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      return server;
    }

    testWidgets('a regular account sees the collection locked, never Equip', (
      tester,
    ) async {
      await show(tester, _Server('free'));
      expect(find.text('ELEGANT'), findsOneWidget);
      expect(find.text('CINEMATIC'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Aurora frame.*for Reelish Supporters')),
        findsOneWidget,
      );
      // The Founder's frame is not shown to anyone else.
      expect(find.text('Sovereign'), findsNothing);
      await tester.tap(find.text('Aurora'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Equip'), findsNothing);
      expect(find.text('Become a Supporter'), findsOneWidget);
    });

    testWidgets('a supporter previews a frame and equips it', (tester) async {
      final server = await show(
        tester,
        _Server('supporter', allowed: _supporterFrames),
      );
      expect(find.text('No frame'), findsOneWidget);
      await tester.tap(find.text('Celestial'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Celestial'), findsNWidgets(2));
      await tester.runAsync(() async {
        await tester.tap(find.text('Equip'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 400));
      expect(server.equipped, 'celestial');
      expect(find.text('Remove frame'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Celestial frame.*equipped')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Founder sees every frame, Sovereign too', (tester) async {
      await show(
        tester,
        _Server(
          'founder',
          equipped: 'founder',
          allowed: {..._supporterFrames, 'founder'},
        ),
      );
      expect(
        find.bySemanticsLabel(RegExp('Sovereign frame.*equipped')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('for Reelish Supporters')),
        findsNothing,
      );
    });
  });

  testWidgets('a party guest shows the frame only the room reports', (
    tester,
  ) async {
    final guest = PartyParticipant.fromJson({
      'pid': 'p1',
      'name': 'Sam',
      'frame': 'nebula',
    })!;
    final plain = PartyParticipant.fromJson({'pid': 'p2', 'name': 'Ana'})!;
    expect(guest.frame, 'nebula');
    expect(plain.frame, isNull);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            PartyAvatar(name: guest.name, frame: guest.frame),
            PartyAvatar(name: plain.name, frame: plain.frame),
          ],
        ),
      ),
    );
    final frames = tester.widgetList<AvatarFrame>(find.byType(AvatarFrame));
    expect(frames.single.style, AvatarFrameStyle.nebula);
    // In a list it stays still.
    expect(frames.single.animate, isFalse);
  });

  testWidgets('small avatars take the frame\'s rim without growing', (
    tester,
  ) async {
    late AvatarFrames frames;
    await tester.runAsync(() async {
      (_, _, frames) = await _Server(
        'supporter',
        equipped: 'rose_gold',
        allowed: _supporterFrames,
      ).start();
      await frames.refresh();
    });
    await tester.pumpWidget(
      _app(
        AvatarFrameRim(
          frames: frames,
          child: const SizedBox.square(dimension: 24),
        ),
      ),
    );
    expect(tester.getSize(find.byType(AvatarFrameRim)), const Size(24, 24));
    expect(
      find.descendant(
        of: find.byType(AvatarFrameRim),
        matching: find.byType(DecoratedBox),
      ),
      findsOneWidget,
    );
  });
}
