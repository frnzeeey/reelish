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
import 'package:onfeed/src/account/trakt_avatar.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/profile_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _avatar =
    'https://walter-r2.trakt.tv/images/users/000/000/001/avatars/large/a1.jpg';
const _newAvatar =
    'https://walter-r2.trakt.tv/images/users/000/000/001/avatars/large/b2.jpg';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

StoredSession _session({String username = 'sam', String? avatar = _avatar}) =>
    StoredSession(
      sessionId: 'session',
      accessToken: 'access',
      accessExpiresAt: _now() + 3600,
      refreshToken: 'refresh',
      refreshExpiresAt: _now() + 86400,
      userId: 'user-1',
      username: username,
      traktAvatarUrl: avatar,
    );

/// A session store that counts its writes.
class _CountingStore extends MemorySessionStore {
  _CountingStore(super.session);
  int writes = 0;

  @override
  Future<void> write(StoredSession session) {
    writes++;
    return super.write(session);
  }
}

Map<String, Object?> _me({
  String id = 'user-1',
  Object? username = 'sam',
  Object? avatar = _avatar,
  bool withAvatar = true,
}) => {
  'user': {'id': id, 'username': username, if (withAvatar) 'avatarUrl': avatar},
  'badges': <String>[],
};

/// An account whose GET /me answers [bodies] in turn; null fails offline.
Future<(AccountController, _CountingStore, List<Uri>)> _account(
  List<Map<String, Object?>?> bodies, {
  StoredSession? stored,
}) async {
  final requests = <Uri>[];
  final store = _CountingStore(stored ?? _session());
  final controller = AccountController(
    api: AccountApi(
      baseUrl: Uri.parse('https://api.reelish.test'),
      client: MockClient((request) async {
        requests.add(request.url);
        final body = bodies.length > 1 ? bodies.removeAt(0) : bodies.first;
        if (body == null) throw const SocketException('offline');
        return http.Response(jsonEncode(body), 200);
      }),
    ),
    store: store,
  );
  await controller.restore();
  return (controller, store, requests);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('The avatar URL', () {
    test('a Gravatar link never falls back to the Trakt stand-in', () {
      final cleaned = Uri.parse(
        cleanTraktAvatarUrl(
          'https://secure.gravatar.com/avatar/abc?d=https%3A%2F%2Fwalter-r2.trakt.tv%2Fhotlink-ok%2Fplaceholders%2Ffry.png&r=pg',
        )!,
      );
      expect(cleaned.queryParameters['d'], '404');
      expect(cleaned.queryParameters['r'], 'pg');
    });

    test('only Trakt and Gravatar images over HTTPS are used', () {
      expect(cleanTraktAvatarUrl(_avatar), _avatar);
      expect(
        cleanTraktAvatarUrl('https://secure.gravatar.com/avatar/abc'),
        isNotNull,
      );
      for (final bad in [
        'http://walter-r2.trakt.tv/a.jpg',
        'https://evil.example/a.jpg',
        'https://trakt.tv.evil.example/a.jpg',
        'https://u:p@walter-r2.trakt.tv/a.jpg',
        'https://walter-r2.trakt.tv:8443/a.jpg',
        'https://walter-r2.trakt.tv/hotlink-ok/placeholders/medium/fry.png',
        'file:///etc/passwd',
        '',
        7,
        null,
      ]) {
        expect(cleanTraktAvatarUrl(bad), isNull, reason: '$bad');
      }
    });
  });

  group('The saved session', () {
    test('a session saved before avatars still loads', () {
      final old = jsonEncode({
        'sessionId': 's',
        'accessToken': 'a',
        'accessExpiresAt': 1,
        'refreshToken': 'r',
        'refreshExpiresAt': 2,
        'userId': 'u',
        'username': 'sam',
      });
      final session = StoredSession.tryParse(old)!;
      expect(session.username, 'sam');
      expect(session.traktAvatarUrl, isNull);
    });

    test('keeps the avatar through a save, a token refresh and a reload', () {
      final saved = StoredSession.tryParse(jsonEncode(_session().toJson()))!;
      expect(saved.traktAvatarUrl, _avatar);
      final refreshed = saved.withTokens({
        'sessionId': 's2',
        'accessToken': 'a2',
        'accessExpiresAt': 3,
        'refreshToken': 'r2',
        'refreshExpiresAt': 4,
      });
      expect(refreshed.traktAvatarUrl, _avatar);
    });

    test('a sign-in answer brings the avatar, checked', () {
      final session = {
        'sessionId': 's',
        'accessToken': 'a',
        'accessExpiresAt': 1,
        'refreshToken': 'r',
        'refreshExpiresAt': 2,
      };
      expect(
        StoredSession.fromResponse(session, {
          'id': 'u',
          'username': 'sam',
          'avatarUrl': _avatar,
        }).traktAvatarUrl,
        _avatar,
      );
      expect(
        StoredSession.fromResponse(session, {
          'id': 'u',
          'username': 'sam',
          'avatarUrl': 'https://evil.example/x.jpg',
        }).traktAvatarUrl,
        isNull,
      );
    });
  });

  group('Bringing the profile in', () {
    test(
      'a rename and a new avatar from the API are saved and shown',
      () async {
        final (account, store, _) = await _account([
          _me(username: 'samantha', avatar: _newAvatar),
        ]);
        var notified = 0;
        account.addListener(() => notified++);
        await account.fetchMe();
        expect(account.username, 'samantha');
        expect(account.traktAvatarUrl, _newAvatar);
        expect(store.session!.traktAvatarUrl, _newAvatar);
        expect(notified, 1);
      },
    );

    test('nothing changed, nothing written', () async {
      final (account, store, _) = await _account([_me()]);
      await account.fetchMe();
      expect(store.writes, 0);
    });

    test('a removed avatar is removed', () async {
      final (account, _, _) = await _account([_me(avatar: null)]);
      await account.fetchMe();
      expect(account.traktAvatarUrl, isNull);
      expect(account.username, 'sam');
    });

    test('an empty name or an older API never blanks the profile', () async {
      final (account, store, _) = await _account([
        _me(username: '', withAvatar: false),
        _me(username: null, withAvatar: false),
      ]);
      await account.fetchMe();
      await account.fetchMe();
      expect(account.username, 'sam');
      expect(account.traktAvatarUrl, _avatar);
      expect(store.writes, 0);
    });

    test('an avatar URL that is not Trakt\'s is not used', () async {
      final (account, _, _) = await _account([
        _me(avatar: 'https://tracker.example/pixel.gif'),
      ]);
      await account.fetchMe();
      expect(account.traktAvatarUrl, isNull);
    });

    test('another account\'s answer is ignored', () async {
      final (account, store, _) = await _account([
        _me(id: 'someone-else', username: 'intruder', avatar: _newAvatar),
      ]);
      await account.fetchMe();
      expect(account.username, 'sam');
      expect(account.traktAvatarUrl, _avatar);
      expect(store.writes, 0);
    });

    test('offline, the saved profile stays', () async {
      final (account, _, _) = await _account([null]);
      expect(await account.fetchMe(), isNull);
      expect(account.username, 'sam');
      expect(account.traktAvatarUrl, _avatar);
    });

    test('callers at the same time share one request', () async {
      final (account, _, requests) = await _account([_me()]);
      await Future.wait([account.fetchMe(), account.fetchMe()]);
      expect(requests.where((url) => url.path.endsWith('/me')), hasLength(1));
    });

    test('signing out leaves no profile to come back', () async {
      final (account, store, _) = await _account([_me()]);
      await account.signOut();
      expect(account.traktAvatarUrl, isNull);
      expect(store.session, isNull);
    });
  });

  group('The avatar a profile shows', () {
    Future<ProfileController> loaded(Map<String, Object?>? entry) async {
      SharedPreferences.setMockInitialValues({
        if (entry != null)
          ProfileController.storageKey: jsonEncode({'user-1': entry}),
      });
      final profile = ProfileController(
        directory: () async => Directory.systemTemp.createTempSync('sync'),
      );
      await profile.loadFor('user-1');
      return profile;
    }

    test('a new profile starts with the Trakt picture', () async {
      expect((await loaded(null)).avatar, const ProfileAvatar.trakt());
    });

    test(
      'profiles from before show it too, keeping their other choices',
      () async {
        final legacy = await loaded({
          'displayName': 'Sam',
          'avatar': 'initials',
        });
        expect(legacy.avatar, const ProfileAvatar.trakt());
        expect(legacy.displayName, 'Sam');
        final preset = await loaded({'avatar': 'preset', 'preset': 'avatar2'});
        expect(preset.avatar, const ProfileAvatar.preset('avatar2'));
      },
    );

    test('an initial chosen on purpose stays chosen', () async {
      final profile = await loaded(null);
      await profile.setAvatar(const ProfileAvatar.initials());
      final again = await loaded(
        (jsonDecode(
                  (await SharedPreferences.getInstance()).getString(
                    ProfileController.storageKey,
                  )!,
                )
                as Map)['user-1']
            as Map<String, Object?>,
      );
      expect(again.avatar, const ProfileAvatar.initials());
    });
  });

  group('Drawing it', () {
    Future<void> draw(WidgetTester tester, ProfileAvatar avatar, String? url) =>
        tester.pumpWidget(
          MaterialApp(
            theme: GlassTheme.dark,
            home: Center(
              child: ProfileAvatarView(
                avatar: avatar,
                name: 'Sam',
                traktUrl: url,
                size: 64,
              ),
            ),
          ),
        );

    NetworkImage? network(WidgetTester tester) {
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        final provider = image.image;
        final inner = provider is ResizeImage
            ? provider.imageProvider
            : provider;
        if (inner is NetworkImage) return inner;
      }
      return null;
    }

    testWidgets('the Trakt picture loads from its URL', (tester) async {
      await draw(tester, const ProfileAvatar.trakt(), _avatar);
      expect(network(tester)?.url, _avatar);
      // The initial shows until (and unless) the picture arrives.
      expect(find.text('S'), findsOneWidget);
    });

    testWidgets('without a Trakt picture, the initial', (tester) async {
      await draw(tester, const ProfileAvatar.trakt(), null);
      expect(network(tester), isNull);
      expect(find.text('S'), findsOneWidget);
    });

    testWidgets('a preset chosen on this device wins', (tester) async {
      await draw(tester, const ProfileAvatar.preset('avatar1'), _avatar);
      expect(network(tester), isNull);
    });
  });
}
