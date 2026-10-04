import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../models/app_update.dart';
import 'storage_service.dart';
import 'update_config.dart';

/// Lets the user stop an APK download that is in progress.
class UpdateDownloadCancellation {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

class UpdateDownloadCancelled extends UpdateException {
  const UpdateDownloadCancelled() : super('The download was cancelled.');
}

/// Checks GitHub Releases for a newer Reelish build, downloads its APK and
/// hands it to Android's package installer.
abstract final class GitHubUpdateService {
  static const _installerChannel = MethodChannel('onfeed/app_update');
  static const _nextCheckKey = 'onfeed.update.github.nextCheckAt.v2';
  static const _lastResultKey = 'onfeed.update.github.lastResult.v2';
  static const _updatesDirectoryName = 'updates';
  static final _abiPattern = RegExp(
    r'arm64|armeabi|x86|mips',
    caseSensitive: false,
  );
  static final _digestPattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

  static Future<UpdateCheckResult>? _inFlight;

  /// Compares the installed version with the latest GitHub release.
  ///
  /// Requests are throttled by [UpdateConfig.checkInterval] across app
  /// launches; within that window the last result is reused. Concurrent calls
  /// share one request. This never throws.
  static Future<UpdateCheckResult> checkForUpdate({
    bool forceRefresh = false,
    StorageService? storage,
    http.Client? client,
    DateTime Function()? clock,
    Future<String?> Function()? installedVersionLoader,
  }) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _check(
      forceRefresh: forceRefresh,
      storage: storage ?? StorageService(),
      client: client,
      now: (clock ?? DateTime.now)(),
      installedVersionLoader: installedVersionLoader ?? _installedVersion,
    );
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  static Future<UpdateCheckResult> _check({
    required bool forceRefresh,
    required StorageService storage,
    required http.Client? client,
    required DateTime now,
    required Future<String?> Function() installedVersionLoader,
  }) async {
    try {
      final installed = AppVersion.tryParse(
        await installedVersionLoader() ?? '',
      );
      if (installed == null) {
        return const UpdateCheckResult(UpdateCheckStatus.unavailable);
      }

      final cached = await _readCachedResult(storage, installed);
      final nextCheck = DateTime.tryParse(
        await storage.readSetting(_nextCheckKey) ?? '',
      );
      if (!forceRefresh &&
          nextCheck != null &&
          now.isBefore(nextCheck) &&
          // A clock moved backwards would otherwise block checks for days.
          nextCheck.difference(now) <= UpdateConfig.checkInterval) {
        _log('GitHub check skipped until ${nextCheck.toIso8601String()}.');
        return cached ?? const UpdateCheckResult(UpdateCheckStatus.unavailable);
      }

      // Saved before the request, so relaunches never repeat a failing call.
      await _saveNextCheck(storage, now.add(UpdateConfig.checkInterval));
      final (result, retryAfter) = await _fetchLatestRelease(client, installed);
      _log('GitHub check: ${result.status.name}.');

      if (_isDefinitive(result.status)) {
        await _saveCachedResult(storage, result);
        if (result.status == UpdateCheckStatus.upToDate) {
          await deleteDownloadedUpdates();
        }
        return result;
      }
      await _saveNextCheck(storage, now.add(retryAfter));
      // Keep offering a known update while GitHub is briefly unreachable.
      if (!forceRefresh && cached != null) return cached;
      return result;
    } catch (error) {
      _log('GitHub check failed: $error');
      return const UpdateCheckResult(UpdateCheckStatus.invalidResponse);
    }
  }

  static bool _isDefinitive(UpdateCheckStatus status) => switch (status) {
    UpdateCheckStatus.updateAvailable ||
    UpdateCheckStatus.upToDate ||
    UpdateCheckStatus.noRelease ||
    UpdateCheckStatus.missingApk => true,
    _ => false,
  };

  /// Returns the result and, for failures, how long to wait before retrying.
  static Future<(UpdateCheckResult, Duration)> _fetchLatestRelease(
    http.Client? client,
    AppVersion installed,
  ) async {
    const retrySoon = Duration(minutes: 15);
    final httpClient = client ?? http.Client();
    final http.Response response;
    try {
      response = await httpClient
          .get(
            UpdateConfig.latestReleaseUri,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': UpdateConfig.userAgent,
            },
          )
          .timeout(UpdateConfig.requestTimeout);
    } on Exception {
      // SocketException, TimeoutException, HandshakeException, ClientException.
      return (
        const UpdateCheckResult(UpdateCheckStatus.networkError),
        retrySoon,
      );
    } finally {
      if (client == null) httpClient.close();
    }

    final status = response.statusCode;
    if (status == 404) {
      // GitHub answers 404 when the repository has no published release.
      return (const UpdateCheckResult(UpdateCheckStatus.noRelease), retrySoon);
    }
    if (status == 429 ||
        (status == 403 && response.headers['x-ratelimit-remaining'] == '0')) {
      return (
        const UpdateCheckResult(UpdateCheckStatus.rateLimited),
        _rateLimitRetry(response.headers),
      );
    }
    if (status != 200) {
      return (
        const UpdateCheckResult(UpdateCheckStatus.serverError),
        const Duration(minutes: 30),
      );
    }

    final Object? release;
    try {
      release = jsonDecode(response.body);
    } on FormatException {
      return (
        const UpdateCheckResult(UpdateCheckStatus.invalidResponse),
        retrySoon,
      );
    }
    return (parseRelease(release, installed), retrySoon);
  }

  /// Interprets a `releases/latest` response for the [installed] version.
  @visibleForTesting
  static UpdateCheckResult parseRelease(Object? release, AppVersion installed) {
    if (release is! Map<String, dynamic>) {
      return const UpdateCheckResult(UpdateCheckStatus.invalidResponse);
    }
    if (release['draft'] == true || release['prerelease'] == true) {
      return const UpdateCheckResult(UpdateCheckStatus.noRelease);
    }
    final tag = release['tag_name'];
    final latest = tag is String ? AppVersion.tryParse(tag) : null;
    if (tag is! String || latest == null) {
      return const UpdateCheckResult(UpdateCheckStatus.invalidResponse);
    }
    if (!(latest > installed)) {
      return UpdateCheckResult(
        UpdateCheckStatus.upToDate,
        latestVersion: latest,
      );
    }

    final assets = release['assets'];
    final asset = assets is List ? selectApkAsset(assets) : null;
    if (asset == null) {
      return UpdateCheckResult(
        UpdateCheckStatus.missingApk,
        latestVersion: latest,
      );
    }
    final digest = _digestPattern.firstMatch(asset['digest'] as String? ?? '');
    final size = asset['size'];
    final htmlUrl = release['html_url'];
    final name = release['name'];
    final body = release['body'];
    return UpdateCheckResult(
      UpdateCheckStatus.updateAvailable,
      latestVersion: latest,
      update: AppUpdate(
        currentVersion: installed,
        latestVersion: latest,
        tagName: tag,
        releaseName: name is String && name.trim().isNotEmpty
            ? name.trim()
            : 'Reelish $latest',
        releaseNotes: body is String ? body : '',
        downloadUri: Uri.parse(asset['browser_download_url'] as String),
        assetName: asset['name'] as String,
        releaseUri: htmlUrl is String ? Uri.tryParse(htmlUrl) : null,
        sizeBytes: size is int ? size : null,
        sha256: digest?.group(1)?.toLowerCase(),
      ),
    );
  }

  /// Picks the Android APK from release assets: a configured name first,
  /// otherwise a single universal (non ABI-specific) APK. Source archives and
  /// ambiguous sets of APKs are never selected.
  @visibleForTesting
  static Map<String, dynamic>? selectApkAsset(List<dynamic> assets) {
    final candidates = assets.whereType<Map<String, dynamic>>().where((asset) {
      final name = asset['name'];
      final url = asset['browser_download_url'];
      final size = asset['size'];
      final state = asset['state'];
      if (name is! String || url is! String) return false;
      if (!name.toLowerCase().endsWith('.apk')) return false;
      if (state != null && state != 'uploaded') return false;
      if (size is int && (size <= 0 || size > UpdateConfig.maxApkBytes)) {
        return false;
      }
      final uri = Uri.tryParse(url);
      return uri != null && UpdateConfig.isTrustedAssetUri(uri);
    }).toList();

    for (final preferred in UpdateConfig.apkAssetNames) {
      for (final asset in candidates) {
        if ((asset['name'] as String).toLowerCase() == preferred) return asset;
      }
    }
    final universal = candidates
        .where((asset) => !_abiPattern.hasMatch(asset['name'] as String))
        .toList();
    return universal.length == 1 ? universal.single : null;
  }

  static Duration _rateLimitRetry(Map<String, String> headers) {
    final retryAfter = int.tryParse(headers['retry-after'] ?? '');
    if (retryAfter != null) return Duration(seconds: retryAfter);
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (reset != null) {
      final wait = DateTime.fromMillisecondsSinceEpoch(
        reset * 1000,
      ).difference(DateTime.now());
      if (wait > Duration.zero && wait <= UpdateConfig.checkInterval) {
        return wait;
      }
    }
    return const Duration(hours: 1);
  }

  static Future<String?> _installedVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveNextCheck(StorageService storage, DateTime at) =>
      storage.saveSetting(_nextCheckKey, at.toUtc().toIso8601String());

  static Future<UpdateCheckResult?> _readCachedResult(
    StorageService storage,
    AppVersion installed,
  ) async {
    try {
      final raw = await storage.readSetting(_lastResultKey);
      if (raw == null) return null;
      final cached = jsonDecode(raw);
      if (cached is! Map) return null;
      final status = UpdateCheckStatus.values.asNameMap()[cached['status']];
      final latest = AppVersion.tryParse(
        cached['latestVersion'] as String? ?? '',
      );
      if (status == null || !_isDefinitive(status)) return null;
      // Re-evaluate against the installed version: after updating, a cached
      // "update available" must not be offered again.
      if (latest != null && !(latest > installed)) {
        return UpdateCheckResult(
          UpdateCheckStatus.upToDate,
          latestVersion: latest,
        );
      }
      if (status != UpdateCheckStatus.updateAvailable) {
        return UpdateCheckResult(status, latestVersion: latest);
      }
      final update = AppUpdate.fromJson(cached['update'], installed);
      if (update == null ||
          !UpdateConfig.isTrustedAssetUri(update.downloadUri)) {
        return null;
      }
      return UpdateCheckResult(
        UpdateCheckStatus.updateAvailable,
        latestVersion: latest,
        update: update,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveCachedResult(
    StorageService storage,
    UpdateCheckResult result,
  ) => storage.saveSetting(
    _lastResultKey,
    jsonEncode({
      'status': result.status.name,
      'latestVersion': result.latestVersion?.toString(),
      'update': result.update?.toJson(),
    }),
  );

  /// Downloads the release APK into `<cache>/updates`, verifying its size and,
  /// when GitHub provides one, its SHA-256 digest. A verified download from an
  /// earlier attempt is reused. Partial or invalid files are always deleted.
  ///
  /// Throws [UpdateException] with a user-facing message on failure.
  static Future<File> downloadApk(
    AppUpdate update, {
    void Function(int received, int? total)? onProgress,
    UpdateDownloadCancellation? cancellation,
    http.Client? client,
    Future<Directory> Function()? cacheDirectory,
  }) async {
    if (!UpdateConfig.isTrustedAssetUri(update.downloadUri)) {
      throw const UpdateException(
        'The update download link is not a Reelish release.',
      );
    }
    final directory = await _updatesDirectory(cacheDirectory);
    final file = File(
      '${directory.path}${Platform.pathSeparator}reelish-${_safeName(update.latestVersion.toString())}.apk',
    );
    final partialFile = File('${file.path}.part');

    if (await file.exists()) {
      if (await _matchesExpected(file, update)) {
        onProgress?.call(await file.length(), await file.length());
        return file;
      }
      await file.delete();
    }
    // Remove older updates and abandoned partial downloads.
    await for (final entity in directory.list()) {
      if (entity is File) await _deleteQuietly(entity);
    }

    final httpClient = client ?? http.Client();
    cancellation?._onCancel = httpClient.close;
    IOSink? sink;
    try {
      final request = http.Request('GET', update.downloadUri)
        ..headers['User-Agent'] = UpdateConfig.userAgent
        ..headers['Accept'] = 'application/octet-stream';
      final response = await httpClient
          .send(request)
          .timeout(UpdateConfig.requestTimeout * 3);
      if (response.statusCode != 200) {
        throw UpdateException(switch (response.statusCode) {
          404 => 'The update file was removed from GitHub.',
          403 ||
          429 => 'GitHub is limiting downloads right now. Try again later.',
          >= 500 => 'GitHub is unavailable right now. Try again later.',
          _ => 'The download failed (HTTP ${response.statusCode}).',
        });
      }

      final total = response.contentLength ?? update.sizeBytes;
      if (total != null && total > UpdateConfig.maxApkBytes) {
        throw const UpdateException('The update file is unexpectedly large.');
      }
      var received = 0;
      sink = partialFile.openWrite();
      await for (final chunk in response.stream.timeout(
        UpdateConfig.downloadIdleTimeout,
      )) {
        if (cancellation?.isCancelled ?? false) {
          throw const UpdateDownloadCancelled();
        }
        received += chunk.length;
        if (received > UpdateConfig.maxApkBytes) {
          throw const UpdateException('The update file is unexpectedly large.');
        }
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (cancellation?.isCancelled ?? false) {
        throw const UpdateDownloadCancelled();
      }
      if (received == 0 || (total != null && received != total)) {
        throw const UpdateException(
          'The download was incomplete. Check your connection and try again.',
        );
      }
      if (!await _matchesExpected(partialFile, update)) {
        throw const UpdateException(
          'The downloaded update failed its integrity check. Try again.',
        );
      }
      return await partialFile.rename(file.path);
    } catch (error) {
      await sink?.close().catchError((_) {});
      await _deleteQuietly(partialFile);
      if (cancellation?.isCancelled ?? false) {
        throw const UpdateDownloadCancelled();
      }
      _log('APK download failed: $error');
      throw switch (error) {
        UpdateException() => error,
        TimeoutException() => const UpdateException(
          'The download stalled. Check your connection and try again.',
        ),
        FileSystemException() => const UpdateException(
          'Could not save the update. Free up storage space and try again.',
        ),
        _ => const UpdateException(
          'The download was interrupted. Check your connection and try again.',
        ),
      };
    } finally {
      cancellation?._onCancel = null;
      if (client == null) httpClient.close();
    }
  }

  static Future<bool> _matchesExpected(File file, AppUpdate update) async {
    final length = await file.length();
    if (length == 0) return false;
    if (update.sizeBytes != null && length != update.sizeBytes) return false;
    final expected = update.sha256;
    if (expected == null) return true;
    final actual = await sha256.bind(file.openRead()).first;
    return actual.toString() == expected;
  }

  static Future<Directory> _updatesDirectory(
    Future<Directory> Function()? cacheDirectory,
  ) async {
    final cache = await (cacheDirectory ?? getTemporaryDirectory)();
    // Must match the FileProvider path in res/xml/update_file_paths.xml.
    final directory = Directory(
      '${cache.path}${Platform.pathSeparator}$_updatesDirectoryName',
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// Removes downloaded update APKs, including files from older app versions
  /// that stored them directly in the cache directory.
  static Future<void> deleteDownloadedUpdates({
    Future<Directory> Function()? cacheDirectory,
  }) async {
    try {
      final cache = await (cacheDirectory ?? getTemporaryDirectory)();
      final updates = Directory(
        '${cache.path}${Platform.pathSeparator}$_updatesDirectoryName',
      );
      if (await updates.exists()) await updates.delete(recursive: true);
      await for (final entity in cache.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && name.startsWith('reelish-update-')) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {
      // Cache cleanup is best effort.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static String _safeName(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

  /// Whether Android currently lets Reelish open the package installer
  /// ("Install unknown apps"). Always true below Android 8.
  static Future<bool> canInstallPackages() async {
    try {
      return await _installerChannel.invokeMethod<bool>(
            'canRequestPackageInstalls',
          ) ??
          true;
    } catch (_) {
      // Let Android's installer explain the restriction if the check fails.
      return true;
    }
  }

  /// Opens the "Install unknown apps" settings page for Reelish. Returns
  /// false when no settings page could be opened.
  static Future<bool> openInstallPermissionSettings() async {
    try {
      return await _installerChannel.invokeMethod<bool>(
            'openInstallPermissionSettings',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Validates the downloaded APK and opens Android's installer for it.
  /// Android always asks the user to confirm the installation.
  ///
  /// Throws [UpdateException] when the APK is not a valid Reelish update.
  static Future<void> installApk(File apk, AppUpdate update) async {
    try {
      final info = await _installerChannel.invokeMapMethod<String, Object?>(
        'inspectApk',
        {'path': apk.path},
      );
      if (info == null || info['packageName'] != info['installedPackageName']) {
        await _deleteQuietly(apk);
        throw const UpdateException(
          'The downloaded file is not a Reelish update.',
        );
      }
      final apkVersion = AppVersion.tryParse(
        info['versionName'] as String? ?? '',
      );
      if (apkVersion != update.latestVersion) {
        await _deleteQuietly(apk);
        throw UpdateException(
          'The release is labelled ${update.latestVersion}, but its APK is '
          'version ${apkVersion ?? 'unknown'}. The release needs to be fixed.',
        );
      }
      final versionCode = info['versionCode'];
      final installedVersionCode = info['installedVersionCode'];
      if (versionCode is int &&
          installedVersionCode is int &&
          versionCode < installedVersionCode) {
        throw UpdateException(
          'Android cannot install this update because its build number '
          '($versionCode) is lower than the installed build '
          '($installedVersionCode).',
        );
      }
      await _installerChannel.invokeMethod<String>('installApk', {
        'path': apk.path,
      });
    } on PlatformException catch (error) {
      throw UpdateException(
        error.message ?? "Could not open Android's package installer.",
      );
    } on MissingPluginException {
      throw const UpdateException(
        'Installing updates is not supported on this device.',
      );
    }
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint('[UPDATE] $message');
  }
}
