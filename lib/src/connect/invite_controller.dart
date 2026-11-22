// Reelish Connect invitations, in the app: this account's invite code and
// how many people joined with it, and accepting a friend's invitation, from
// a link (kept until someone is signed in) or a code typed in.
// backend/src/referrals.ts holds the rules; nothing is rewarded.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';

class InviteController extends ChangeNotifier {
  InviteController({AccountController? account, AccountApi? api})
    : _account = account ?? AccountController.instance,
      _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl);

  static final instance = InviteController();

  /// An invitation opened before it could be accepted (signed out, or
  /// before Reelish was installed and the link opened again).
  static const pendingKey = 'reelish.connect.pendingInvite';

  final AccountController _account;
  final AccountApi _api;

  String? _loadedFor;
  String? _code;
  int _joined = 0;
  bool _invited = false;
  bool _loading = false;
  bool _failed = false;

  bool get _current => _loadedFor != null && _loadedFor == _account.userId;

  /// This account's invite code, once loaded.
  String? get code => _current ? _code : null;

  /// How many people joined with it.
  int get joined => _current ? _joined : 0;

  /// Whether this account joined through someone's invitation.
  bool get invited => _current && _invited;
  bool get loading => _loading;
  bool get failed => _failed;

  Future<void>? _refreshing;

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    await Future<void>.value();
    final userId = _account.userId;
    if (userId == null) return;
    _loading = true;
    _failed = false;
    notifyListeners();
    try {
      final token = await _account.accessToken();
      if (token == null) throw const AccountApiException('missing_token', '');
      final body = await _api.invites(token);
      final code = body['code'];
      if (code is! String) throw const AccountApiException('bad_reply', '');
      _code = code;
      _joined = (body['joined'] as num?)?.toInt() ?? 0;
      _invited = body['invited'] == true;
      _loadedFor = userId;
    } catch (_) {
      _failed = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Keeps an invitation's [code] until it can be accepted.
  static Future<void> keep(String code) async =>
      (await SharedPreferences.getInstance()).setString(pendingKey, code);

  /// Accepts a kept invitation, if any. Returns what to tell the person, or
  /// null when there was nothing to say (none kept, or a network failure,
  /// which keeps it for next time).
  Future<String?> acceptKept() async {
    final preferences = await SharedPreferences.getInstance();
    final code = preferences.getString(pendingKey);
    if (code == null) return null;
    final result = await accept(code);
    if (result.settled) await preferences.remove(pendingKey);
    return result.settled ? result.message : null;
  }

  /// Accepts invite [code] for this account.
  Future<InviteResult> accept(String code) async {
    try {
      final token = await _account.accessToken();
      if (token == null) {
        return const InviteResult(false, 'Sign in to accept the invitation.');
      }
      await _api.acceptInvite(token, code);
      // Accepted before this account's invitations were loaded (a link at
      // launch): what is known so far belongs to it.
      final userId = _account.userId;
      if (_loadedFor != userId) {
        _loadedFor = userId;
        _code = null;
        _joined = 0;
      }
      _invited = true;
      notifyListeners();
      return const InviteResult(
        true,
        'Invitation accepted. Your friend will see you joined.',
      );
    } on AccountApiException catch (error) {
      return switch (error.code) {
        'own_invite' ||
        'already_invited' ||
        'invite_too_late' ||
        'invite_not_found' => InviteResult(true, error.message),
        // Rate limits and outages: try again later.
        _ => InviteResult(
          false,
          error.message.isEmpty
              ? 'Couldn’t accept the invitation. Try again.'
              : error.message,
        ),
      };
    } catch (_) {
      return const InviteResult(
        false,
        'Couldn’t accept the invitation. Check your connection.',
      );
    }
  }
}

/// What accepting an invitation came to: [settled] when there is nothing
/// more to try (accepted, or refused for good), and what to show.
@immutable
class InviteResult {
  const InviteResult(this.settled, this.message);

  final bool settled;
  final String message;
}
