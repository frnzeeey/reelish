// Friends: the signed-in account's social profile (handle, friend code, what
// friends see) and its privacy settings. The Reelish API owns and enforces
// all of it (backend/src/social/); this reads and changes it, and keeps a
// copy per account so the Profile page can show it offline. The copy only
// decides what is shown. docs/friends-activity/.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';

/// The privacy switches, by the name the API uses.
enum SocialSetting {
  findByCode('findByCode'),
  findByHandle('findByHandle'),
  allowRecommendations('allowRecommendations'),
  shareActivity('shareActivity');

  const SocialSetting(this.field);
  final String field;
}

/// The account's own view of its social profile.
@immutable
class SocialProfile {
  const SocialProfile({
    required this.handle,
    required this.friendCode,
    this.displayName,
    this.avatar,
    this.findByCode = true,
    this.findByHandle = false,
    this.allowRecommendations = true,
    this.shareActivity = false,
    this.handleChangeableAt,
  });

  final String handle;

  /// Eight letters and digits; shown as two groups of four.
  final String friendCode;

  /// Shown to friends only when set.
  final String? displayName;

  /// An `AvatarPreset` id shown to friends, or null.
  final String? avatar;
  final bool findByCode;
  final bool findByHandle;
  final bool allowRecommendations;
  final bool shareActivity;

  /// When the handle may change again; null or past: now.
  final DateTime? handleChangeableAt;

  /// The code as people read it aloud: `ABCD-EFGH`.
  String get formattedCode => friendCode.length == 8
      ? '${friendCode.substring(0, 4)}-${friendCode.substring(4)}'
      : friendCode;

  bool value(SocialSetting setting) => switch (setting) {
    SocialSetting.findByCode => findByCode,
    SocialSetting.findByHandle => findByHandle,
    SocialSetting.allowRecommendations => allowRecommendations,
    SocialSetting.shareActivity => shareActivity,
  };

  static SocialProfile? fromJson(Object? value) {
    if (value is! Map) return null;
    final handle = value['handle'];
    final code = value['friendCode'];
    if (handle is! String || handle.isEmpty || code is! String) return null;
    final changeable = value['handleChangeableAt'];
    String? text(Object? field) =>
        field is String && field.isNotEmpty ? field : null;
    return SocialProfile(
      handle: handle,
      friendCode: code,
      displayName: text(value['displayName']),
      avatar: text(value['avatar']),
      findByCode: value['findByCode'] != false,
      findByHandle: value['findByHandle'] == true,
      allowRecommendations: value['allowRecommendations'] != false,
      shareActivity: value['shareActivity'] == true,
      handleChangeableAt: changeable is int
          ? DateTime.fromMillisecondsSinceEpoch(changeable, isUtc: true)
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'handle': handle,
    'friendCode': friendCode,
    'displayName': displayName,
    'avatar': avatar,
    'findByCode': findByCode,
    'findByHandle': findByHandle,
    'allowRecommendations': allowRecommendations,
    'shareActivity': shareActivity,
    'handleChangeableAt': handleChangeableAt?.millisecondsSinceEpoch,
  };
}

/// How many friends the account has, how many requests wait for it and how
/// many recommendations it has not opened.
@immutable
class SocialCounts {
  const SocialCounts({this.friends = 0, this.incoming = 0, this.unread = 0});

  static const zero = SocialCounts();

  final int friends;
  final int incoming;
  final int unread;

  /// Something waits for the person: a request or an unopened title.
  bool get anyNew => incoming > 0 || unread > 0;

  static SocialCounts? fromJson(Object? value) {
    if (value is! Map) return null;
    final friends = value['friends'];
    final incoming = value['incoming'];
    final unread = value['unread'] ?? 0;
    if (friends is! int || incoming is! int || unread is! int) return null;
    return SocialCounts(friends: friends, incoming: incoming, unread: unread);
  }

  Map<String, int> toJson() => {
    'friends': friends,
    'incoming': incoming,
    'unread': unread,
  };
}

/// What the app checks before sending a handle; the server decides.
final handlePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]{2,19}$');
const maxHandleLength = 20;
const maxSocialNameLength = 40;

class SocialController extends ChangeNotifier {
  SocialController({AccountController? account, AccountApi? api})
    : _account = account ?? AccountController.instance,
      _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl);

  static final instance = SocialController();

  static const cachePrefix = 'reelish.social.v1.';

  final AccountController _account;
  final AccountApi _api;

  String? _loadedFor;
  bool _known = false;
  SocialProfile? _profile;
  bool _loading = false;
  bool _failed = false;
  bool _busy = false;
  SocialCounts _counts = SocialCounts.zero;
  DateTime? _refreshedAt;

  /// How long the Profile page trusts the last answer before asking again.
  static const staleAfter = Duration(minutes: 2);

  bool get _current => _loadedFor != null && _loadedFor == _account.userId;

  /// This account's profile, or null while Friends is off or not yet known.
  SocialProfile? get profile => _current ? _profile : null;

  /// Whether Friends is known to be on or off for this account.
  bool get known => _current && _known;
  bool get enabled => profile != null;

  /// Friends and waiting requests, as the server last counted them.
  SocialCounts get counts => _current ? _counts : SocialCounts.zero;
  bool get loading => _loading;

  /// The last refresh failed: what shows may be out of date.
  bool get failed => _failed;

  /// A change is on its way to the server.
  bool get busy => _busy;

  Future<void>? _refreshing;

  /// The saved copy for this account, without asking the server.
  Future<void> restoreSaved() async {
    final userId = _account.userId;
    if (userId == null || _loadedFor == userId) return;
    await _restore(userId);
    notifyListeners();
  }

  /// For the Profile page: asks the server only when Friends may be on and
  /// the last answer is older than [staleAfter], so opening Profile often
  /// costs no requests.
  Future<void> refreshIfStale() async {
    await restoreSaved();
    if (known && !enabled) return;
    final at = _refreshedAt;
    if (_current && at != null && DateTime.now().difference(at) < staleAfter) {
      return;
    }
    await refresh();
  }

  /// Corrects the counts after a change made elsewhere in the app (a request
  /// answered, a friend removed), until the next refresh.
  void adjustCounts({int friends = 0, int incoming = 0, int unread = 0}) {
    if (!_current) return;
    _counts = SocialCounts(
      friends: (_counts.friends + friends).clamp(0, 1 << 20),
      incoming: (_counts.incoming + incoming).clamp(0, 1 << 20),
      unread: (_counts.unread + unread).clamp(0, 1 << 20),
    );
    notifyListeners();
  }

  /// The unread count as the inbox just read it.
  void setUnread(int unread) {
    if (!_current || unread == _counts.unread) return;
    _counts = SocialCounts(
      friends: _counts.friends,
      incoming: _counts.incoming,
      unread: unread,
    );
    notifyListeners();
  }

  /// The saved copy, then the server's answer.
  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    // Started as a page opens, mid-build: tell listeners after it.
    await Future<void>.value();
    final userId = _account.userId;
    if (userId == null) return;
    if (_loadedFor != userId) await _restore(userId);
    _loading = true;
    _failed = false;
    notifyListeners();
    try {
      final token = await _account.accessToken();
      if (token == null) throw const AccountApiException('missing_token', '');
      await _accept(userId, await _api.socialProfile(token));
      _refreshedAt = DateTime.now();
    } catch (_) {
      _failed = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Turns Friends on with [handle]. Returns an error to show, or null.
  Future<String?> enable(String handle) =>
      _change((token) => _api.updateSocialProfile(token, {'handle': handle}));

  Future<String?> setHandle(String handle) => enable(handle);

  /// The name friends see; empty stops sharing one.
  Future<String?> setDisplayName(String name) => _change(
    (token) => _api.updateSocialProfile(token, {
      'displayName': name.trim().isEmpty ? null : name.trim(),
    }),
  );

  /// The avatar preset friends see; null stops sharing one.
  Future<String?> setAvatar(String? presetId) =>
      _change((token) => _api.updateSocialProfile(token, {'avatar': presetId}));

  Future<String?> setSetting(SocialSetting setting, bool value) => _change(
    (token) => _api.updateSocialProfile(token, {setting.field: value}),
  );

  /// A new friend code; the old one stops working.
  Future<String?> resetCode() => _change(_api.resetFriendCode);

  /// Turns Friends off; the server deletes every social row of the account.
  Future<String?> disable() => _change((token) async {
    await _api.disableFriends(token);
    return const {'profile': null};
  });

  Future<String?> _change(
    Future<Map<String, dynamic>> Function(String token) call,
  ) async {
    final userId = _account.userId;
    if (userId == null || _busy) return 'Try again in a moment.';
    _busy = true;
    notifyListeners();
    try {
      final token = await _account.accessToken();
      if (token == null) return 'Sign in again to change this.';
      await _accept(userId, await call(token));
      return null;
    } on AccountApiException catch (error) {
      return messageFor(error);
    } catch (_) {
      return 'Something went wrong. Try again later.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// A message for [error]: the server's own for a refused change (it is
  /// written for people), a fixed one otherwise.
  static String messageFor(AccountApiException error) {
    if (error.code == 'network') {
      return 'Reelish could not be reached. Check your connection and try again.';
    }
    if (error.isUnauthorized) return 'Sign in again to change this.';
    final status = error.status ?? 0;
    if (status == 400 || status == 404 || status == 409 || status == 429) {
      return error.message.isEmpty ? 'That was not accepted.' : error.message;
    }
    return 'Something went wrong. Try again later.';
  }

  Future<void> _accept(String userId, Map<String, dynamic> body) async {
    if (!body.containsKey('profile')) {
      throw const AccountApiException('unavailable', 'Unexpected response.');
    }
    final next = SocialProfile.fromJson(body['profile']);
    if (body['profile'] != null && next == null) {
      throw const AccountApiException('unavailable', 'Unexpected response.');
    }
    // The account may have changed while this was on its way.
    if (_account.userId != userId) return;
    _loadedFor = userId;
    _known = true;
    _profile = next;
    // A change answers with the profile only: the counts stay as they were.
    if (next == null) {
      _counts = SocialCounts.zero;
    } else if (SocialCounts.fromJson(body['counts']) case final counts?) {
      _counts = counts;
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$cachePrefix$userId',
        jsonEncode({
          'on': next != null,
          'profile': next?.toJson(),
          'counts': _counts.toJson(),
        }),
      );
    } catch (_) {
      // Only a convenience.
    }
  }

  Future<void> _restore(String userId) async {
    _loadedFor = userId;
    _known = false;
    _profile = null;
    _counts = SocialCounts.zero;
    _refreshedAt = null;
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString('$cachePrefix$userId');
      if (saved == null) return;
      final decoded = jsonDecode(saved);
      if (decoded is! Map) return;
      _profile = decoded['on'] == true
          ? SocialProfile.fromJson(decoded['profile'])
          : null;
      _known = decoded['on'] == false || _profile != null;
      _counts = SocialCounts.fromJson(decoded['counts']) ?? SocialCounts.zero;
    } catch (_) {
      // A damaged copy is ignored; the server's answer replaces it.
    }
  }
}
