// The badges on the signed-in account. The Reelish API decides them; this only
// reads them, and keeps a copy per account so they show at once and offline. The
// copy is display only: the server's answer replaces it, it grants nothing, and
// no name or username plays any part.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_controller.dart';

enum AccountBadge { founder, supporter }

class AccountBadges extends ChangeNotifier {
  AccountBadges({AccountController? account})
    : _account = account ?? AccountController.instance;

  static final instance = AccountBadges();

  static const _cachePrefix = 'reelish.badges.v1.';

  final AccountController _account;

  Set<AccountBadge> _badges = const {};
  String? _loadedFor;
  bool _loading = false;

  bool has(AccountBadge badge) => _badges.contains(badge);

  /// Shows the saved badges for this account, then asks the server.
  Future<void> refresh() async {
    final userId = _account.userId;
    if (userId == null) {
      _set(const {});
      _loadedFor = null;
      return;
    }
    if (_loadedFor != userId) {
      _loadedFor = userId;
      _set(await _readCache(userId));
    }
    if (_loading) return;
    _loading = true;
    try {
      // The same request brings in the Trakt username and avatar.
      final body = await _account.fetchMe();
      if (body == null) return;
      final badges = parse(body);
      // The account may have changed while this was on its way.
      if (_account.userId != userId) return;
      _set(badges);
      await _writeCache(userId, badges);
    } catch (_) {
      // Offline: the saved badges stay. A badge is never worth an error.
    } finally {
      _loading = false;
    }
  }

  /// Reads `/me`; a name the app does not know is left out.
  @visibleForTesting
  static Set<AccountBadge> parse(Object? body) {
    final names = body is Map ? body['badges'] : null;
    return {
      if (names is List)
        for (final badge in AccountBadge.values)
          if (names.contains(badge.name)) badge,
    };
  }

  void _set(Set<AccountBadge> next) {
    if (setEquals(next, _badges)) return;
    _badges = next;
    notifyListeners();
  }

  Future<Set<AccountBadge>> _readCache(String userId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getString('$_cachePrefix$userId');
      return saved == null ? const {} : parse(jsonDecode(saved));
    } catch (_) {
      return const {};
    }
  }

  Future<void> _writeCache(String userId, Set<AccountBadge> badges) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        '$_cachePrefix$userId',
        jsonEncode({'badges': badges.map((badge) => badge.name).toList()}),
      );
    } catch (_) {
      // Only a convenience.
    }
  }
}
