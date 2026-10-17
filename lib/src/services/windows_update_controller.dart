import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import '../models/app_update.dart';
import '../platform/windows_installation.dart';
import 'github_update_service.dart';
import 'storage_service.dart';

/// Where a Windows update is. One value, so the Settings section and the
/// update dialogs always agree.
enum WindowsUpdateStage {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,

  /// The installer is downloaded and verified; Reelish has not closed yet.
  ready,

  /// The installer was started and Reelish is closing.
  installing,
  failed,
}

typedef UpdateDownloader =
    Future<({File file, AppUpdate update})> Function(
      AppUpdate update,
      void Function(int received, int? total) onProgress,
      UpdateDownloadCancellation cancellation,
    );

/// Checks, downloads, verifies and hands over Windows updates.
///
/// Installed copies ([WindowsInstallation.usesInstaller]) download the
/// release's installer. Before it may run, the installer must match the
/// release's SHA-256, be a Windows executable whose version resource names
/// Reelish by frnzeeey at exactly the offered version, and carry no invalid
/// signature. It is checked against the SHA-256 again just before it starts.
/// The runner then starts it with fixed arguments and closes Reelish; the
/// installer waits for Reelish to exit before replacing any file, and
/// relaunches it. Nothing is installed without the user choosing to.
class WindowsUpdateController extends ChangeNotifier {
  WindowsUpdateController({
    Future<UpdateCheckResult> Function({required bool force})? checker,
    this._downloader,
    this._bridge = const WindowsInstallerBridge(),
    StorageService? storage,
    bool Function()? playbackActive,
    this._cacheDirectory,
  }) : _checker = checker ?? _defaultCheck,
       _storage = storage ?? StorageService(),
       _playbackActive = playbackActive ?? _libmpvPlayerAlive;

  static final instance = WindowsUpdateController();

  static const _autoCheckKey = 'onfeed.update.windows.autoCheck';
  static const _dismissedKey = 'onfeed.update.windows.dismissedTag';
  static const productName = 'Reelish';
  static const companyName = 'frnzeeey';

  final Future<UpdateCheckResult> Function({required bool force}) _checker;
  final UpdateDownloader? _downloader;
  final WindowsInstallerBridge _bridge;
  final StorageService _storage;
  final bool Function() _playbackActive;
  final Future<Directory> Function()? _cacheDirectory;

  WindowsUpdateStage _stage = WindowsUpdateStage.idle;
  AppUpdate? _update;
  AppUpdate? _verified;
  File? _file;
  String? _error;
  int _received = 0;
  int? _total;
  double? _bytesPerSecond;
  DateTime? _lastChecked;
  bool _autoCheck = true;
  String? _dismissedTag;
  Future<void>? _loading;
  UpdateDownloadCancellation? _cancellation;
  Future<UpdateCheckResult>? _checking;

  WindowsUpdateStage get stage => _stage;
  AppUpdate? get update => _update;
  String? get error => _error;
  int get received => _received;
  int? get total => _total;
  double? get bytesPerSecond => _bytesPerSecond;
  DateTime? get lastChecked => _lastChecked;
  bool get autoCheck => _autoCheck;

  /// Installed copies download and run the installer; portable copies get
  /// the verified ZIP in Downloads instead.
  bool get canInstallInApp => WindowsInstallation.usesInstaller;

  bool get isBusy => switch (_stage) {
    WindowsUpdateStage.checking ||
    WindowsUpdateStage.downloading ||
    WindowsUpdateStage.verifying ||
    WindowsUpdateStage.installing => true,
    _ => false,
  };

  double? get progress {
    final total = _total;
    return total != null && total > 0
        ? (_received / total).clamp(0.0, 1.0)
        : null;
  }

  /// Reads the saved preferences once.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _autoCheck = await _storage.readSetting(_autoCheckKey) != 'false';
      _dismissedTag = await _storage.readSetting(_dismissedKey);
      _lastChecked = await GitHubUpdateService.lastSuccessfulCheck(
        storage: _storage,
      );
    } catch (_) {
      // Defaults: automatic checks on, nothing dismissed.
    }
    notifyListeners();
  }

  Future<void> setAutoCheck(bool value) async {
    _autoCheck = value;
    notifyListeners();
    await _storage.saveSetting(_autoCheckKey, value.toString());
  }

  /// "Later" on an automatic prompt: that release is not offered
  /// automatically again. Settings still shows it, and newer releases are
  /// offered as usual.
  Future<void> dismiss(AppUpdate update) async {
    _dismissedTag = update.tagName;
    await _storage.saveSetting(_dismissedKey, update.tagName);
  }

  bool isDismissed(AppUpdate update) => _dismissedTag == update.tagName;

  /// Asks GitHub (or, unless [force], the throttled cache) for a newer
  /// release. A download or installation in progress is never disturbed:
  /// its state stays as it is.
  Future<UpdateCheckResult> check({bool force = false}) {
    final pending = _checking;
    if (pending != null && !force) return pending;
    final future = _check(force);
    _checking = future;
    return future.whenComplete(() {
      if (identical(_checking, future)) _checking = null;
    });
  }

  Future<UpdateCheckResult> _check(bool force) async {
    await load();
    final busy =
        _stage != WindowsUpdateStage.idle &&
        _stage != WindowsUpdateStage.upToDate &&
        _stage != WindowsUpdateStage.available &&
        _stage != WindowsUpdateStage.failed;
    final previous = _stage;
    if (!busy) _setStage(WindowsUpdateStage.checking);
    UpdateCheckResult result;
    try {
      result = await _checker(force: force);
    } catch (_) {
      result = const UpdateCheckResult(UpdateCheckStatus.invalidResponse);
    }
    _lastChecked =
        await GitHubUpdateService.lastSuccessfulCheck(storage: _storage) ??
        _lastChecked;
    if (busy) {
      notifyListeners();
      return result;
    }
    final update = result.update;
    if (result.hasUpdate && update != null) {
      if (_update?.tagName != update.tagName) {
        _verified = null;
        _file = null;
      }
      _update = update;
      _error = null;
      _setStage(
        _verified != null
            ? WindowsUpdateStage.ready
            : WindowsUpdateStage.available,
      );
    } else if (result.status == UpdateCheckStatus.upToDate ||
        result.status == UpdateCheckStatus.noRelease) {
      _update = null;
      _verified = null;
      _file = null;
      _error = null;
      _setStage(WindowsUpdateStage.upToDate);
    } else if (force) {
      _error = result.message;
      _setStage(WindowsUpdateStage.failed);
    } else {
      // A silent check that failed keeps whatever was known before.
      _setStage(
        previous == WindowsUpdateStage.checking
            ? WindowsUpdateStage.idle
            : previous,
      );
    }
    return result;
  }

  /// Downloads and verifies the offered installer. Returns when it is ready
  /// to install, failed, or was cancelled; see [stage] and [error].
  Future<void> download() async {
    final update = _update;
    if (update == null || isBusy || _stage == WindowsUpdateStage.ready) return;
    final cancellation = UpdateDownloadCancellation();
    _cancellation = cancellation;
    _error = null;
    _received = 0;
    _total = update.sizeBytes;
    _bytesPerSecond = null;
    _setStage(WindowsUpdateStage.downloading);
    try {
      await _ensureFreeSpace(update);
      final speed = _SpeedMeter();
      final (:file, update: verified) = await (_downloader ?? _defaultDownload)(
        update,
        (received, total) {
          if (cancellation.isCancelled) return;
          _received = received;
          _total = total;
          _bytesPerSecond = speed.sample(received);
          if (total != null && received >= total) {
            _stage = WindowsUpdateStage.verifying;
          }
          notifyListeners();
        },
        cancellation,
      );
      if (cancellation.isCancelled) return;
      _setStage(WindowsUpdateStage.verifying);
      final problem = await _inspect(file, verified);
      if (cancellation.isCancelled) return;
      if (problem != null) {
        await _deleteQuietly(file);
        throw UpdateException(problem);
      }
      _file = file;
      _verified = verified;
      _setStage(WindowsUpdateStage.ready);
    } on UpdateDownloadCancelled {
      // cancelDownload() already reset the state.
    } catch (error) {
      if (cancellation.isCancelled) return;
      _error = error is UpdateException
          ? error.message
          : 'The download failed. Try again.';
      _setStage(WindowsUpdateStage.failed);
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
  }

  void cancelDownload() {
    final cancellation = _cancellation;
    if (cancellation == null) return;
    _cancellation = null;
    cancellation.cancel();
    _received = 0;
    _bytesPerSecond = null;
    _setStage(
      _update == null ? WindowsUpdateStage.idle : WindowsUpdateStage.available,
    );
  }

  /// Starts the verified installer and closes Reelish. Returns a message
  /// when it cannot (playback running, file changed, launch failed); Reelish
  /// then stays open and the update stays ready.
  Future<String?> install() async {
    final file = _file;
    final verified = _verified;
    if (_stage != WindowsUpdateStage.ready ||
        file == null ||
        verified == null) {
      return 'The update is not ready to install yet.';
    }
    if (_playbackActive()) {
      return 'Stop playback and close the player first. Your update is '
          'downloaded and will be ready when you are.';
    }
    _setStage(WindowsUpdateStage.installing);
    // Checked once more just before it runs, so a file changed after it was
    // verified is never started.
    if (!await GitHubUpdateService.verifyDownload(file, verified)) {
      await _deleteQuietly(file);
      _file = null;
      _verified = null;
      _setStage(WindowsUpdateStage.available);
      return 'The downloaded update changed since it was verified, so it was '
          'removed. Download it again to continue.';
    }
    try {
      final directory = await GitHubUpdateService.updatesDirectory(
        cacheDirectory: _cacheDirectory,
      );
      final launched = await _bridge.launchAndQuit(
        file.path,
        logPath: '${directory.path}\\install.log',
      );
      if (launched) return null;
    } catch (_) {
      // Reported below.
    }
    _setStage(WindowsUpdateStage.ready);
    return 'The installer could not be started. Windows security software '
        'may have blocked it. Try again, or download the installer from the '
        'release page.';
  }

  Future<void> _ensureFreeSpace(AppUpdate update) async {
    final size = update.sizeBytes;
    if (size == null) return;
    final directory = await GitHubUpdateService.updatesDirectory(
      cacheDirectory: _cacheDirectory,
    );
    final free = await _bridge.freeDiskSpace(directory.path);
    // The download, plus room for the installer to unpack the app.
    if (free != null && free < size * 4) {
      throw const UpdateException(
        'There is not enough free disk space for the update. Free up some '
        'space and try again.',
      );
    }
  }

  /// Why [file] must not run, or null when it is the expected installer.
  Future<String?> _inspect(File file, AppUpdate update) async {
    if (!canInstallInApp) return null; // A ZIP is never run.
    try {
      final header = await file
          .openRead(0, 2)
          .expand((bytes) => bytes)
          .toList();
      if (header.length != 2 || header[0] != 0x4D || header[1] != 0x5A) {
        return 'The downloaded file is not a Windows installer.';
      }
      final info = await _bridge.inspect(file.path);
      return installerProblem(info, update.latestVersion);
    } catch (_) {
      return 'The downloaded installer could not be checked.';
    }
  }

  /// Why an installer described by [info] is not Reelish [expected].
  @visibleForTesting
  static String? installerProblem(
    InstallerInspection? info,
    AppVersion expected,
  ) {
    if (info == null) return 'The downloaded file is not a Windows installer.';
    if (info.signature != 'valid' && info.signature != 'unsigned') {
      return "The installer's digital signature is not valid.";
    }
    if (info.productName != productName || info.companyName != companyName) {
      return 'The downloaded file is not a Reelish installer.';
    }
    final version = AppVersion.tryParse(info.version ?? '');
    if (version != expected) {
      return 'The release is labelled $expected, but its installer is '
          'version ${version ?? 'unknown'}. The release needs to be fixed.';
    }
    return null;
  }

  void _setStage(WindowsUpdateStage stage) {
    _stage = stage;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _cancellation?.cancel();
    _cancellation = null;
    _stage = WindowsUpdateStage.idle;
    _update = null;
    _verified = null;
    _file = null;
    _error = null;
    _loading = null;
    _checking = null;
  }

  static Future<UpdateCheckResult> _defaultCheck({required bool force}) =>
      GitHubUpdateService.checkForUpdate(forceRefresh: force);

  Future<({File file, AppUpdate update})> _defaultDownload(
    AppUpdate update,
    void Function(int received, int? total) onProgress,
    UpdateDownloadCancellation cancellation,
  ) => GitHubUpdateService.downloadUpdate(
    update,
    onProgress: onProgress,
    cancellation: cancellation,
    cacheDirectory: _cacheDirectory,
  );

  /// On Windows every player is libmpv; one alive means a title is open.
  static bool _libmpvPlayerAlive() {
    try {
      return MediaKitVideoPlayer.shared?.activePlayerId != null;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Download speed averaged over the last few seconds.
class _SpeedMeter {
  final _samples = <(DateTime, int)>[];

  double? sample(int received) {
    final now = DateTime.now();
    _samples.add((now, received));
    while (_samples.length > 2 &&
        now.difference(_samples.first.$1) > const Duration(seconds: 4)) {
      _samples.removeAt(0);
    }
    final (start, startBytes) = _samples.first;
    final elapsed = now.difference(start).inMilliseconds;
    if (elapsed < 500) return null;
    return (received - startBytes) * 1000 / elapsed;
  }
}
