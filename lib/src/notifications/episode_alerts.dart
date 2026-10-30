// New-episode alerts: the settings the user changes, the system
// notifications, and the checks: every few hours in the background on
// Android (WorkManager), and while the app runs (launch, resume, a timer)
// on Android and Windows. Not offered on TV.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:workmanager/workmanager.dart';

import '../account/account_api.dart';
import '../account/account_controller.dart';
import '../account/backend_config.dart';
import '../platform/device_capabilities.dart';
import '../services/storage_service.dart';
import 'episode_check.dart';

/// Where the session's episode-check token is kept: secure storage, with
/// the account it belongs to.
class AlertTokenStore {
  const AlertTokenStore([this._storage = const FlutterSecureStorage()]);

  static const _key = 'reelish.alerts.v1';
  final FlutterSecureStorage _storage;

  Future<String?> read(String userId) async {
    try {
      final decoded = jsonDecode(await _storage.read(key: _key) ?? '');
      if (decoded is Map && decoded['userId'] == userId) {
        final token = decoded['token'];
        if (token is String) return token;
      }
    } catch (_) {
      // Missing or unreadable: issue a new one.
    }
    return null;
  }

  Future<void> write(String userId, String token) => _storage.write(
    key: _key,
    value: jsonEncode({'userId': userId, 'token': token}),
  );

  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

/// System notifications for new episodes.
class SystemEpisodeNotifier implements EpisodeNotifier {
  SystemEpisodeNotifier([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  static const _channel = AndroidNotificationDetails(
    'new_episodes',
    'New episodes',
    channelDescription: 'New episodes of series you follow',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    icon: 'ic_launcher_monochrome',
  );

  static const _details = NotificationDetails(android: _channel);

  static const initialization = InitializationSettings(
    android: AndroidInitializationSettings('ic_launcher_monochrome'),
    windows: WindowsInitializationSettings(
      appName: 'Reelish',
      appUserModelId: 'io.github.frnzeeey.reelish',
      // Fixed: Windows keys the app's notification settings to it.
      guid: '6f2b0f3e-6c1d-4f63-9a0e-5b8f7d2c41a9',
    ),
  );

  Future<void> _init() async {
    if (_ready) return;
    await _plugin.initialize(settings: initialization);
    _ready = true;
  }

  /// Asks for permission where the system needs it (Android 13+). True
  /// when notifications can be shown.
  Future<bool> requestPermission() async {
    await _init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return true;
    return await android.requestNotificationsPermission() ?? false;
  }

  static String _label(NewEpisode e) =>
      'S${e.season} E${e.episode}${e.episodeName.isEmpty ? '' : ' · ${e.episodeName}'}';

  @override
  Future<void> showNew(List<NewEpisode> episodes) async {
    await _init();
    if (episodes.length <= 3) {
      for (final e in episodes) {
        await _plugin.show(
          id: e.tmdbId & 0x3fffffff,
          title: 'New episode of ${e.seriesName}',
          body: '${_label(e)} is out now.',
          notificationDetails: _details,
        );
      }
      return;
    }
    final names = episodes.map((e) => e.seriesName).toList();
    await _plugin.show(
      id: 1,
      title: '${episodes.length} new episodes',
      body: '${names.take(3).join(', ')} and ${names.length - 3} more.',
      notificationDetails: _details,
    );
  }

  @override
  Future<void> showPopular(List<NewEpisode> episodes) async {
    await _init();
    final names = episodes.map((e) => e.seriesName).toList();
    final shown = names.take(3).join(', ');
    await _plugin.show(
      id: 2,
      title: 'New on popular series',
      body: names.length > 3
          ? '$shown and ${names.length - 3} more have new episodes.'
          : '$shown ${names.length == 1 ? 'has a new episode' : 'have new episodes'}.',
      notificationDetails: _details,
    );
  }
}

const _taskName = 'reelish.episodeAlerts';

/// Runs the background check when WorkManager starts the task (Android).
/// Called from `episodeAlertsDispatcher` in `main.dart`: the entry point
/// lives there because a callback handle keeps its library's URI in the
/// release binary, and the release check rejects `package:onfeed/src`.
void runEpisodeAlertsTask() {
  Workmanager().executeTask((task, _) async {
    DartPluginRegistrant.ensureInitialized();
    try {
      await EpisodeAlerts.runBackgroundCheck();
    } catch (_) {
      // Nothing to retry for; the next period checks again.
    }
    return true;
  });
}

class EpisodeAlerts extends ChangeNotifier {
  EpisodeAlerts({
    AccountApi? api,
    StorageService? storage,
    EpisodeNotifier? notifier,
    AlertTokenStore? tokens,
    this._requestPermission,
    this.background = true,
  }) : _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _storage = storage ?? StorageService(),
       _notifier = notifier ?? SystemEpisodeNotifier(),
       _tokens = tokens ?? const AlertTokenStore();

  static EpisodeAlerts instance = EpisodeAlerts();

  /// How often the app checks: in the background, and while it runs.
  static const interval = Duration(hours: 6);

  /// Whether this device offers alerts: Android phones and tablets, and
  /// Windows. Android TV has no useful notification shade.
  static bool get supported =>
      !kIsWeb &&
      !DeviceCapabilities.isTv &&
      (Platform.isAndroid || Platform.isWindows);

  final AccountApi _api;
  final StorageService _storage;
  final EpisodeNotifier _notifier;
  final AlertTokenStore _tokens;
  final Future<bool> Function()? _requestPermission;

  /// Off in tests: schedules no WorkManager task and no timer.
  final bool background;

  AccountController? _account;
  String? _userId;
  EpisodeAlertSettings _settings = const EpisodeAlertSettings();
  DateTime? _lastChecked;
  String? _error;
  bool _checking = false;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  EpisodeAlertSettings get settings => _settings;
  DateTime? get lastChecked => _lastChecked;
  String? get error => _error;
  bool get checking => _checking;

  /// Starts the background scheduler on Android with [dispatcher], a
  /// top-level `@pragma('vm:entry-point')` function that calls
  /// [runEpisodeAlertsTask]; call once at startup.
  static Future<void> initializeBackground(void Function() dispatcher) async {
    if (kIsWeb || !Platform.isAndroid) return;
    await Workmanager().initialize(dispatcher);
  }

  void attach(AccountController account) {
    _account?.removeListener(_accountChanged);
    _account = account..addListener(_accountChanged);
    // Back in the foreground after a while: check if it is time.
    if (background) _lifecycle ??= AppLifecycleListener(onResume: _resumed);
    _accountChanged();
  }

  void _resumed() {
    final last = _lastChecked;
    if (_settings.enabled &&
        supported &&
        (last == null || DateTime.now().difference(last) > interval)) {
      unawaited(checkNow());
    }
  }

  void _accountChanged() {
    final userId = _account?.status == AccountStatus.signedIn
        ? _account?.userId
        : null;
    if (userId == _userId) return;
    final previous = _userId;
    _userId = userId;
    unawaited(_switchTo(userId, signedOut: previous != null && userId == null));
  }

  Future<void> _switchTo(String? userId, {required bool signedOut}) async {
    _timer?.cancel();
    _settings = const EpisodeAlertSettings();
    _lastChecked = null;
    _error = null;
    if (signedOut || userId == null) {
      // Alerts belong to the signed-in account; stop them with it.
      await EpisodeAlertStore.setActiveUser(null);
      await _tokens.clear();
      await _cancelBackground();
      notifyListeners();
      return;
    }
    await EpisodeAlertStore.setActiveUser(userId);
    final entry = await EpisodeAlertStore.entry(userId);
    if (_userId != userId) return;
    _settings = EpisodeAlertStore.settingsOf(entry);
    final at = entry['lastChecked'];
    _lastChecked = at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null;
    notifyListeners();
    if (_settings.enabled && supported) {
      await _schedule();
      if (_lastChecked == null ||
          DateTime.now().difference(_lastChecked!) > interval) {
        unawaited(checkNow());
      }
    }
  }

  /// Turns alerts on (asking for notification permission where needed) or
  /// off. Returns false when permission was refused.
  Future<bool> setEnabled(bool value) async {
    final userId = _userId;
    if (userId == null) return false;
    _error = null;
    if (value) {
      final allowed =
          await (_requestPermission ??
              (_notifier is SystemEpisodeNotifier
                  ? _notifier.requestPermission
                  : () async => true))();
      if (!allowed) {
        _error =
            'Notifications are blocked for Reelish. Allow them in your '
            'system settings, then try again.';
        notifyListeners();
        return false;
      }
    }
    await _save(_settings.copyWith(enabled: value));
    if (value) {
      await _schedule();
      await checkNow();
    } else {
      _timer?.cancel();
      await _cancelBackground();
    }
    return true;
  }

  Future<void> setSources({bool? myList, bool? watching, bool? popular}) =>
      _save(
        _settings.copyWith(
          myList: myList,
          watching: watching,
          popular: popular,
        ),
      );

  Future<void> _save(EpisodeAlertSettings value) async {
    final userId = _userId;
    if (userId == null) return;
    _settings = value;
    notifyListeners();
    await EpisodeAlertStore.update(userId, (e) {
      e['settings'] = EpisodeAlertStore.settingsJson(value);
    });
  }

  /// The session's episode-check token, issued when missing.
  Future<String?> _alertToken(String userId, {bool fresh = false}) async {
    if (!fresh) {
      final stored = await _tokens.read(userId);
      if (stored != null) return stored;
    }
    final access = await _account?.accessToken();
    if (access == null) return null;
    final token = await _api.notificationToken(access);
    await _tokens.write(userId, token);
    return token;
  }

  /// Checks now, while the app runs.
  Future<void> checkNow() async {
    final userId = _userId;
    if (userId == null || !_settings.enabled || _checking) return;
    _checking = true;
    notifyListeners();
    try {
      var token = await _alertToken(userId);
      if (token == null) return;
      try {
        await _run(userId, token);
      } on AccountApiException catch (error) {
        if (!error.isUnauthorized) rethrow;
        // Replaced or expired: issue a new one once.
        token = await _alertToken(userId, fresh: true);
        if (token == null) return;
        await _run(userId, token);
      }
      _error = null;
    } on AccountApiException catch (error) {
      _error = error.code == 'network'
          ? 'Could not reach Reelish. Alerts will check again later.'
          : 'The last check did not finish. Alerts will check again later.';
    } catch (_) {
      _error = 'The last check did not finish. Alerts will check again later.';
    } finally {
      _checking = false;
      if (_userId == userId) {
        final entry = await EpisodeAlertStore.entry(userId);
        final at = entry['lastChecked'];
        if (at is int) _lastChecked = DateTime.fromMillisecondsSinceEpoch(at);
      }
      notifyListeners();
    }
  }

  Future<void> _run(String userId, String token) => EpisodeCheck.run(
    userId: userId,
    alertToken: token,
    api: _api,
    storage: _storage,
    notifier: _notifier,
  );

  Future<void> _schedule() async {
    if (!background || !supported) return;
    _timer?.cancel();
    // While the app runs (the only way on Windows).
    _timer = Timer.periodic(interval, (_) => unawaited(checkNow()));
    if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        _taskName,
        _taskName,
        frequency: interval,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    }
  }

  Future<void> _cancelBackground() async {
    if (!background || kIsWeb || !Platform.isAndroid) return;
    try {
      await Workmanager().cancelByUniqueName(_taskName);
    } catch (_) {}
  }

  /// The background task's check: no session, no refresh; only the stored
  /// episode-check token, which the API accepts for nothing else.
  static Future<void> runBackgroundCheck() async {
    WidgetsFlutterBinding.ensureInitialized();
    final userId = await EpisodeAlertStore.activeUser();
    if (userId == null) return;
    const tokens = AlertTokenStore();
    final token = await tokens.read(userId);
    if (token == null) return;
    try {
      await EpisodeCheck.run(
        userId: userId,
        alertToken: token,
        api: AccountApi(baseUrl: BackendConfig.apiUrl),
        storage: StorageService(),
        notifier: SystemEpisodeNotifier(),
      );
    } on AccountApiException catch (error) {
      // A dead token waits for the app to issue a new one.
      if (error.isUnauthorized) await tokens.clear();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    _account?.removeListener(_accountChanged);
    super.dispose();
  }
}
