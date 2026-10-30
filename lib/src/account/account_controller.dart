// The signed-in Trakt account: restores the stored session at launch,
// hands out fresh access tokens (one shared refresh at a time), runs the
// device sign-in, and signs out.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/device_capabilities.dart';
import 'account_api.dart';
import 'backend_config.dart';
import 'session_store.dart';

enum AccountStatus { restoring, signedOut, signedIn }

class AccountController extends ChangeNotifier {
  AccountController({
    AccountApi? api,
    SessionStore? store,
    Future<bool> Function(Uri url)? openBrowser,
  }) : _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _store = store ?? SecureSessionStore(),
       _openBrowser = openBrowser ?? _launchExternal;

  static Future<bool> _launchExternal(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// The app's account, used by services built without one (TMDB).
  static AccountController instance = AccountController();

  final AccountApi _api;
  final SessionStore _store;
  final Future<bool> Function(Uri url) _openBrowser;

  AccountStatus _status = AccountStatus.restoring;
  AccountStatus get status => _status;

  StoredSession? _session;
  String? get username => _session?.username;

  /// The Reelish account id, which keys this device's profile.
  String? get userId => _session?.userId;

  /// Why the last session ended on its own, for the sign-in screen.
  String? _endedReason;
  String? get endedReason => _endedReason;

  Future<StoredSession?>? _refreshing;

  /// Reads the stored session. A stored session counts as signed in until
  /// the backend says otherwise, so launch never waits on the network.
  Future<void> restore() async {
    final stored = await _store.read();
    if (stored == null || stored.refreshExpired) {
      if (stored != null) await _store.clear();
      _set(AccountStatus.signedOut, null);
      return;
    }
    _set(AccountStatus.signedIn, stored);
  }

  /// A valid access token, refreshed first when it is about to expire;
  /// null when signed out. Concurrent callers share one refresh.
  Future<String?> accessToken({bool forceRefresh = false}) async {
    final session = _session;
    if (session == null) return null;
    if (!forceRefresh && !session.accessStale) return session.accessToken;
    final refreshed = await (_refreshing ??= _refresh(
      session,
    ).whenComplete(() => _refreshing = null));
    return refreshed?.accessToken;
  }

  Future<StoredSession?> _refresh(StoredSession session) async {
    try {
      final next = session.withTokens(await _api.refresh(session.refreshToken));
      // Signed out while refreshing: do not resurrect the session.
      if (_session?.sessionId != session.sessionId) return null;
      await _store.write(next);
      _session = next;
      return next;
    } on AccountApiException catch (error) {
      if (error.isUnauthorized) {
        await _end('Your session ended. Sign in again to continue.');
        return null;
      }
      // Offline or the service is down: keep the session for a retry.
      rethrow;
    }
  }

  /// Called when the API rejected a token that looked valid.
  Future<String?> onUnauthorized() => accessToken(forceRefresh: true);

  /// The sign-in this device offers first: the browser where there is one
  /// to hand, a code on TV hardware.
  static SignInMethod get preferredMethod =>
      DeviceCapabilities.isTv ? SignInMethod.code : SignInMethod.browser;

  /// Starts a Trakt sign-in; see [DeviceSignIn].
  DeviceSignIn startSignIn({SignInMethod? method}) =>
      DeviceSignIn._(this, method ?? preferredMethod);

  Future<void> _completeSignIn(DeviceAuthorized authorized) async {
    final session = StoredSession.fromResponse(
      authorized.session,
      authorized.user,
    );
    await _store.write(session);
    _endedReason = null;
    _set(AccountStatus.signedIn, session);
  }

  /// Signs this device out. The local session is cleared even when the
  /// backend cannot be reached; its refresh token then simply expires.
  Future<void> signOut() async {
    final token = _session?.accessToken;
    if (token != null) {
      try {
        await _api.logout(token);
      } on AccountApiException catch (_) {
        // Best effort.
      }
    }
    await _end(null);
  }

  /// Signs every device out. Needs the backend, so failures are thrown.
  Future<void> signOutEverywhere() async {
    final token = await accessToken();
    if (token == null) return;
    await _api.logoutAll(token);
    await _end(null);
  }

  /// Deletes the Reelish account and revokes Trakt access. Data kept on
  /// this device (My list, history, plugins) is not touched.
  Future<void> deleteAccount() async {
    final token = await accessToken();
    if (token == null) return;
    await _api.deleteAccount(token);
    await _end(null);
  }

  Future<void> _end(String? reason) async {
    await _store.clear();
    _endedReason = reason;
    _set(AccountStatus.signedOut, null);
  }

  void _set(AccountStatus status, StoredSession? session) {
    _session = session;
    _status = status;
    notifyListeners();
  }

  static String get platformName => DeviceCapabilities.isTv
      ? 'android_tv'
      : DeviceCapabilities.isDesktop
      ? 'windows'
      : 'android';

  /// A generic label for the sessions list; no device identifiers.
  static String get deviceLabel => DeviceCapabilities.isTv
      ? 'Android TV'
      : DeviceCapabilities.isDesktop
      ? 'Windows PC'
      : 'Android device';
}

enum DeviceSignInPhase { starting, waiting, expired, denied, failed, done }

/// How the user approves Reelish on Trakt.
enum SignInMethod {
  /// Trakt opens in the browser; it returns to the Reelish API, not the app.
  browser,

  /// A code entered at trakt.tv on any device (TV, or no browser).
  code,
}

/// One Trakt sign-in. With [SignInMethod.browser] it opens Trakt in the
/// browser; with [SignInMethod.code] it shows a code to enter at trakt.tv.
/// Either way it polls the Reelish API at the interval it asks for until
/// the sign-in is approved, declined or expires. Where the API has browser
/// sign-in turned off, it falls back to a code. [cancel] stops polling.
class DeviceSignIn extends ChangeNotifier {
  DeviceSignIn._(this._account, this.method) {
    unawaited(_start());
  }

  final AccountController _account;
  SignInMethod method;

  DeviceSignInPhase phase = DeviceSignInPhase.starting;

  /// The code to show, for [SignInMethod.code].
  DeviceCodeStart? code;

  /// The Trakt page, for [SignInMethod.browser].
  Uri? authorizeUrl;

  /// Whether the browser could not be opened; the page then offers a code.
  bool browserFailed = false;
  DateTime? expiresAt;
  String? error;

  String? _pollToken;
  int _interval = 5;
  Timer? _timer;
  bool _cancelled = false;

  Future<void> _start() async {
    try {
      if (method == SignInMethod.browser) {
        try {
          await _startBrowser();
          return;
        } on AccountApiException catch (exception) {
          if (exception.code != 'web_sign_in_unavailable') rethrow;
          method = SignInMethod.code;
        }
      }
      final start = await _account._api.startDeviceSignIn(
        platform: AccountController.platformName,
        deviceName: AccountController.deviceLabel,
      );
      if (_cancelled) return;
      code = start;
      _begin(start.pollToken, start.expiresIn, start.interval);
    } on AccountApiException catch (exception) {
      _fail(exception);
    }
  }

  Future<void> _startBrowser() async {
    final start = await _account._api.startWebSignIn(
      platform: AccountController.platformName,
      deviceName: AccountController.deviceLabel,
    );
    if (_cancelled) return;
    authorizeUrl = start.authorizeUrl;
    _begin(start.pollToken, start.expiresIn, start.interval);
    await openBrowser();
  }

  void _begin(String pollToken, int expiresIn, int interval) {
    _pollToken = pollToken;
    _interval = interval;
    expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    _update(DeviceSignInPhase.waiting);
    _schedule(interval);
  }

  /// Opens (or reopens) the Trakt page for a browser sign-in.
  Future<void> openBrowser() async {
    final url = authorizeUrl;
    if (url == null || _cancelled) return;
    bool opened;
    try {
      opened = await _account._openBrowser(url);
    } catch (_) {
      opened = false;
    }
    if (browserFailed != !opened) {
      browserFailed = !opened;
      notifyListeners();
    }
  }

  void _schedule(int seconds) {
    _timer?.cancel();
    if (_cancelled) return;
    _timer = Timer(Duration(seconds: seconds.clamp(1, 60)), _poll);
  }

  Future<void> _poll() async {
    final pollToken = _pollToken;
    if (_cancelled || pollToken == null) return;
    if (expiresAt != null && DateTime.now().isAfter(expiresAt!)) {
      _update(DeviceSignInPhase.expired);
      return;
    }
    try {
      final api = _account._api;
      final result = method == SignInMethod.browser
          ? await api.pollWebSignIn(pollToken)
          : await api.pollDeviceSignIn(pollToken);
      if (_cancelled) return;
      switch (result) {
        case DevicePending(:final interval):
          _interval = interval;
          _schedule(interval);
        case DeviceAuthorized():
          await _account._completeSignIn(result);
          _update(DeviceSignInPhase.done);
      }
    } on AccountApiException catch (exception) {
      if (_cancelled) return;
      switch (exception.code) {
        case 'sign_in_denied':
          _update(DeviceSignInPhase.denied);
        case 'sign_in_expired' || 'unknown_sign_in':
          _update(DeviceSignInPhase.expired);
        case 'network' || 'rate_limited':
          // A dropped connection keeps the code valid; try again shortly.
          _schedule(_interval + 5);
        default:
          _fail(exception);
      }
    }
  }

  void _fail(AccountApiException exception) {
    if (_cancelled) return;
    error = exception.code == 'not_configured'
        ? exception.message
        : exception.code == 'network'
        ? 'Could not reach Reelish. Check your connection and try again.'
        : exception.code == 'sign_in_failed'
        ? 'Trakt could not finish signing you in. Try again.'
        : 'Sign-in is not available right now. Try again later.';
    _update(DeviceSignInPhase.failed);
  }

  void _update(DeviceSignInPhase next) {
    if (_cancelled) return;
    phase = next;
    notifyListeners();
  }

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}
