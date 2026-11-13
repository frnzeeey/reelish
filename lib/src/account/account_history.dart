// Keeps watch history and episode progress per account: points
// StorageService at whichever account is signed in, and hands the history
// this device kept before accounts were separated to the one account that
// owns it (the same owner personalised discovery uses).

import '../discovery/discovery_store.dart';
import '../services/storage_service.dart';
import 'account_controller.dart';

class AccountHistory {
  AccountHistory._(this._account, this._discovery);

  final AccountController _account;
  final DiscoveryStore _discovery;

  static AccountHistory? _attached;

  /// Follows [account] from now on. Called once at startup, after the
  /// stored session was restored and before Home reads the history.
  static void attach(AccountController account, {DiscoveryStore? discovery}) {
    final previous = _attached;
    if (previous != null) {
      previous._account.removeListener(previous._changed);
    }
    final next = AccountHistory._(account, discovery ?? DiscoveryStore());
    _attached = next;
    account.addListener(next._changed);
    next._changed();
  }

  bool _followed = false;
  String? _userId;

  void _changed() {
    final userId = _account.status == AccountStatus.signedIn
        ? _account.userId
        : null;
    // The account notifies for profile changes too; only a change of
    // account matters here.
    if (_followed && userId == _userId) return;
    _followed = true;
    _userId = userId;
    StorageService.useAccount(
      userId,
      ownsDeviceHistory: userId == null
          ? null
          : _discovery.claimDeviceHistory(userId),
    );
  }
}
