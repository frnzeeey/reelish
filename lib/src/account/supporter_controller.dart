// The signed-in account's place in the Reelish Supporters Program, and its
// entitlement: whether it has the supporter perks. The Reelish API decides both
// (backend/src/entitlements.ts); this only reads them, and keeps a copy per
// account so they show at once and offline. The copy only chooses what to show:
// the server enforces what it can, and a supporter app icon asks it afresh.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_api.dart';
import 'account_controller.dart';
import 'backend_config.dart';

enum SupporterState { none, pending, verified }

/// What the account may use: free features; those plus every supporter perk;
/// or, for the Founder, the Supporter entitlement as a whole plus the Founder
/// identity. The Founder never needs a donation.
enum Entitlement { free, supporter, founder }

/// Every supporter perk. Each is unlocked by the same entitlement, so the
/// Founder has every one, including any added later.
///
/// Adding one: name it here and in `SupporterPerk` in
/// backend/src/entitlements.ts, check [SupporterController.has] in the app,
/// and call `requirePerk` wherever the server enforces it. Nothing names the
/// Founder: inheritance happens in the entitlement.
enum SupporterPerk { hostWatchParty, appThemes, appIcons }

/// The Founder's own perks: the Founder Collection's cosmetics, which no
/// donation unlocks. Each is the Founder entitlement as a whole, so a
/// cosmetic added to the collection later is the Founder's with no extra
/// work, and never a supporter's.
///
/// Adding one: name it here and in `FounderPerk` in
/// backend/src/entitlements.ts, and check [SupporterController.hasFounderPerk].
/// Nothing names the Founder's account: the server decides the entitlement
/// from its own secret.
enum FounderPerk { founderThemes, founderIcons, profileAccent, founderAvatar }

/// The account's status, as the server reported it.
@immutable
class SupporterStatus {
  const SupporterStatus({
    required this.code,
    this.state = SupporterState.none,
    this.since,
    this.listed = false,
    this.publicName = '',
    this.entitlement = Entitlement.free,
  });

  /// Pasted into the Buy Me a Coffee message to name this account.
  final String code;
  final SupporterState state;

  /// When the first verified donation was made.
  final DateTime? since;

  /// Whether the account chose to appear on the public list, and as whom.
  final bool listed;
  final String publicName;

  /// As the server decided it. The donation's [state] stays honest: a
  /// Founder who never donated is `none` with [Entitlement.founder].
  final Entitlement entitlement;

  static SupporterStatus? fromJson(Object? value) {
    if (value is! Map) return null;
    final code = value['code'];
    if (code is! String || code.isEmpty) return null;
    final since = value['since'];
    final recognition = value['recognition'];
    final state = switch (value['status']) {
      'verified' => SupporterState.verified,
      'pending' => SupporterState.pending,
      _ => SupporterState.none,
    };
    return SupporterStatus(
      code: code,
      state: state,
      entitlement: switch (value['entitlement']) {
        'founder' => Entitlement.founder,
        'supporter' => Entitlement.supporter,
        'free' => Entitlement.free,
        // An API or a saved copy from before entitlements: the donation.
        _ =>
          state == SupporterState.verified
              ? Entitlement.supporter
              : Entitlement.free,
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
    'entitlement': entitlement.name,
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

  /// A verified donation: the Supporters page and the badge go by this.
  bool get isSupporter => _status?.state == SupporterState.verified;

  /// The entitlement the server last reported for this account.
  Entitlement get entitlement => _status?.entitlement ?? Entitlement.free;

  /// Whether this account has [perk]. Every perk is the Supporter
  /// entitlement, which the Founder inherits, so this is the one check any
  /// supporter feature makes.
  bool has(SupporterPerk perk) => entitlement != Entitlement.free;

  /// Whether this account has the Founder's [perk]: the Founder entitlement
  /// only, never a donation. Like [has] it reads the last answer for this
  /// account, which decides only what shows; activating a Founder cosmetic
  /// asks the server afresh first.
  bool hasFounderPerk(FounderPerk perk) => entitlement == Entitlement.founder;

  Future<void>? _refreshing;

  /// Shows this account's saved status without asking the server: for
  /// launch, so a theme's accent is right on the first screen.
  Future<void> restoreSaved() async {
    final userId = _account.userId;
    if (userId == null || _loadedFor == userId) return;
    _loadedFor = userId;
    _status = await _readCache(userId);
    notifyListeners();
  }

  /// Shows the saved status for this account, then asks the server. A call
  /// while one is running waits for that one, so its caller sees the
  /// server's answer rather than the saved status.
  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    // Screens start this as they open, while a build is under way; waiting a
    // microtask means no listener is told to rebuild in the middle of it.
    await Future<void>.value();
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
