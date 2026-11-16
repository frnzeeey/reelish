// A signed-in account against a fake Reelish API, for tests that need an
// entitlement (GET /supporters/me) or an equipped avatar frame (GET /me).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/account/account_controller.dart';
import 'package:onfeed/src/account/avatar_frames.dart';
import 'package:onfeed/src/account/session_store.dart';
import 'package:onfeed/src/account/supporter_controller.dart';
import 'package:onfeed/src/spotlight/spotlight_motion_controller.dart';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// An account whose entitlement is [entitlement] ('free', 'supporter' or
/// 'founder') and who wears [frame] (an avatar frame id, or none).
Future<
  ({
    AccountController account,
    SupporterController supporters,
    AvatarFrames frames,
  })
>
fakeAccount({String entitlement = 'free', String? frame}) async {
  final api = AccountApi(
    baseUrl: Uri.parse('https://api.reelish.test'),
    client: MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/supporters/me')) {
        return http.Response(
          jsonEncode({
            'code': 'RS-ABCD-2345',
            'status': entitlement == 'supporter' ? 'verified' : 'none',
            'since': null,
            'recognition': {'listed': false, 'name': ''},
            'entitlement': entitlement,
          }),
          200,
        );
      }
      if (path.endsWith('/me')) {
        return http.Response(
          jsonEncode({
            'user': {'id': 'user-1', 'username': 'viewer'},
            'badges': <String>[],
            'frames': {
              'equipped': frame,
              'available': [?frame],
              'collected': <String>[],
            },
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
        userId: 'user-1',
        username: 'viewer',
      ),
    ),
  );
  await account.restore();
  final supporters = SupporterController(account: account, api: api);
  await supporters.refresh();
  final frames = AvatarFrames(account: account, api: api);
  await frames.refresh();
  return (account: account, supporters: supporters, frames: frames);
}

/// A Spotlight animation controller for an account with [entitlement].
Future<SpotlightMotionController> fakeSpotlightMotion({
  String entitlement = 'supporter',
}) async {
  final (:supporters, account: _, frames: _) = await fakeAccount(
    entitlement: entitlement,
  );
  final motion = SpotlightMotionController(supporters: supporters);
  await motion.load();
  return motion;
}
