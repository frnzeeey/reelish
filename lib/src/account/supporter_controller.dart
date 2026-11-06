// The signed-in account's place in the Reelish Supporters Program. The Reelish
// API decides it; this only reads it, and keeps a copy per account so a badge
// shows at once and offline. The copy is display only and unlocks nothing: the
// server's answer replaces it, and the public list comes from the server.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_api.dart';
import 'account_controller.dart';
import 'backend_config.dart';

enum SupporterState { none, pending, verified }

/// The account's status, as the server reported it.
@immutable
class SupporterStatus {
  const SupporterStatus({
    required this.code,
    this.state = SupporterState.none,
    this.since,
    this.listed = false,
    this.publicName = '',
  });

  /// Pasted into the Buy Me a Coffee message to name this account.
  final String code;
  final SupporterState state;

  /// When the first verified donation was made.
  final DateTime? since;

  /// Whether the account chose to appear on the public list, and as whom.
  final bool listed;
  final String publicName;

  static SupporterStatus? fromJson(Object? value) {
    if (value is! Map) return null;
    final code = value['code'];
    if (code is! String || code.isEmpty) return null;
    final since = value['since'];
    final recognition = value['recognition'];
    return SupporterStatus(
      code: code,
      state: switch (value['status']) {
        'verified' => SupporterState.verified,
        'pending' => SupporterState.pending,
        _ => SupporterState.none,
      },
      since: since is int
          ? DateTime.fromMillisecondsSinceEpoch(since * 1000, isUtc: true)
          : null,
      listed: recognition is Map && recognition['listed'] == true,
      publicName: recognition is Map && recognition['name'] is String
          ? recognition['name'] as String
          : '',
    );
  }

  Map<String, Object?> toJson() => {
    'code': code,
    'status': state.name,
    'since': since == null ? null : since!.millisecondsSinceEpoch ~/ 1000,
    'recognition': {'listed': listed, 'name': publicName},
  };
}

/// A name on the public list, with the month its supporter joined.
typedef PublicSupporter = ({String name, String since});

class SupporterController extends ChangeNotifier {
  SupporterController({AccountController? account, AccountApi? api})
    : _account = account ?? AccountController.instance,
      _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl);

  static final instance = SupporterController();

  static const _cachePrefix = 'reelish.supporter.v1.';

  final AccountController _account;
  final AccountApi _api;

  SupporterStatus? _status;
  bool _loading = false;
  bool _failed = false;
  String? _loadedFor;

  SupporterStatus? get status => _status;
  bool get loading => _loading;

  /// The last refresh failed, so [status] may be out of date or missing.
  bool get failed => _failed;

  bool get isSupporter => _status?.state == SupporterState.verified;

  /// Shows the saved status for this account, then asks the server.
  Future<void> refresh() async {
    final userId = _account.userId;
    if (userId == null) {
      _status = null;
      _loadedFor = null;
      notifyListeners();
      return;
    }
    if (_loadedFor != userId) {
      _loadedFor = userId;
      _status = await _readCache(userId);
      notifyListeners();
    }
    if (_loading) return;
    _loading = true;
    _failed = false;
    notifyListeners();
    try {
      final token = await _account.accessToken();
      if (token == null) throw const AccountApiException('missing_token', '');
      await _accept(userId, await _api.supporterStatus(token));
    } catch (_) {
      _failed = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Asks for a review of a donation made without the code. It can only ever
  /// show as pending; the badge comes after the donation is checked.
  Future<bool> requestReview() => _update(_api.requestSupporterReview);

  /// Joins or leaves the public list. [name] is what the list shows.
  Future<bool> setRecognition({required bool listed, String name = ''}) =>
      _update(
        (token) =>
            _api.setSupporterRecognition(token, listed: listed, name: name),
      );

  Future<bool> _update(
    Future<Map<String, dynamic>> Function(String token) call,
  ) async {
    final userId = _account.userId;
    if (userId == null) return false;
    try {
      final token = await _account.accessToken();
      if (token == null) return false;
      await _accept(userId, await call(token));
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The people who chose to appear; throws when it cannot be loaded.
  Future<List<PublicSupporter>> publicList() async {
    final token = await _account.accessToken();
    if (token == null) throw const AccountApiException('missing_token', '');
    return _api.publicSupporters(token);
  }

  Future<void> _accept(String userId, Map<String, dynamic> body) async {
    final next = SupporterStatus.fromJson(body);
    if (next == null) {
      throw const AccountApiException('unavailable', 'Unexpected response.');
    }
    // The account may have changed while this was on its way.
    if (_account.userId != userId) return;
    _status = next;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$_cachePrefix$userId',
        jsonEncode(next.toJson()),
      );
    } catch (_) {
      // Only a convenience.
    }
  }

  Future<SupporterStatus?> _readCache(String userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString('$_cachePrefix$userId');
      return saved == null ? null : SupporterStatus.fromJson(jsonDecode(saved));
    } catch (_) {
      return null;
    }
  }
}
