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
  static final _digestPattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

  static Future<UpdateCheckResult>? _inFlight;
  static bool _inFlightForced = false;

  /// Compares the installed version with the latest GitHub release.
  ///
  /// Requests are throttled by [UpdateConfig.checkInterval] across app
  /// launches; within that window the last result is reused. Concurrent calls
  /// share one request, except that a forced check never takes the answer of
  /// a throttled background check: it waits for it, then asks GitHub. This
  /// never throws.
  static Future<UpdateCheckResult> checkForUpdate({
    bool forceRefresh = false,
    StorageService? storage,
    http.Client? client,
    DateTime Function()? clock,
    Future<String?> Function()? installedVersionLoader,
  }) {
    Future<UpdateCheckResult> again() => checkForUpdate(
      forceRefresh: forceRefresh,
      storage: storage,
      client: client,
      clock: clock,
      installedVersionLoader: installedVersionLoader,
    );
    final pending = _inFlight;
    if (pending != null) {
      if (_inFlightForced || !forceRefresh) return pending;
      return pending.then((_) {
        if (identical(_inFlight, pending)) _inFlight = null;
        return again();
      });
    }
    final future = _check(
      forceRefresh: forceRefresh,
      storage: storage ?? StorageService(),
      client: client,
      now: (clock ?? DateTime.now)(),
      installedVersionLoader: installedVersionLoader ?? _installedVersion,
    );
    _inFlight = future;
    _inFlightForced = forceRefresh;
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
        _log('Installed version could not be read; update checks disabled.');
        return const UpdateCheckResult(UpdateCheckStatus.unavailable);
      }
      _log('Installed version: $installed (force: $forceRefresh).');

      final cached = await _readCachedResult(storage, installed);
      final nextCheck = DateTime.tryParse(
        await storage.readSetting(_nextCheckKey) ?? '',
      );
      // A result is only valid for the version it was computed against.
      // After an update, reinstall or downgrade it is re-checked at once, so
      // an old "up to date" can never hide a newer release.
      final cachedFor = await _cachedInstalledVersion(storage);
      final installChanged =
          cachedFor != null && cachedFor != installed.toString();
      if (installChanged) {
        _log(
          'Installed version changed since the last check '
          '(${cachedFor.isEmpty ? 'unknown' : cachedFor} -> $installed); '
          're-checking.',
        );
        // Mark the stale result as seen, so a failed re-check falls back to
        // the normal throttle instead of retrying on every resume.
        await storage.saveSetting(
          _lastResultKey,
          jsonEncode({'installedVersion': installed.toString()}),
        );
      }
      if (!forceRefresh &&
          !installChanged &&
          nextCheck != null &&
          now.isBefore(nextCheck) &&
          // A clock moved backwards would otherwise block checks for days.
          nextCheck.difference(now) <= UpdateConfig.checkInterval) {
        _log(
          'GitHub check skipped until ${nextCheck.toIso8601String()}; '
          'cached result: ${cached?.status.name ?? 'none'}'
          '${cached?.latestVersion == null ? '' : ' (${cached!.latestVersion})'}.',
        );
        // After updating, the cached release equals the installed version:
        // the APK that installed it is no longer needed.
        if (cached?.status == UpdateCheckStatus.upToDate) {
          await deleteDownloadedUpdates();
        }
        return cached ?? const UpdateCheckResult(UpdateCheckStatus.unavailable);
      }

      // Saved before the request, so relaunches never repeat a failing call.
      await _saveNextCheck(storage, now.add(UpdateConfig.checkInterval));
      final (result, retryAfter) = await _fetchLatestRelease(client, installed);
      _log(
        'GitHub check: ${result.status.name}; installed $installed, latest '
        '${result.latestVersion ?? 'unknown'}.',
      );

      if (_isDefinitive(result.status)) {
        await _saveCachedResult(storage, result, installed);
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
    final latest = tag is String ? releaseVersion(tag) : null;
    _log(
      'Latest release: tag $tag, id ${release['id']}, published '
      '${release['published_at']}, name "${release['name']}".',
    );
    if (tag is! String || latest == null) {
      _log('Release tag is not vMAJOR.MINOR.PATCH; ignoring it.');
      return const UpdateCheckResult(UpdateCheckStatus.invalidResponse);
    }
    if (!(latest > installed)) {
      _log(
        'No update: release $latest is not newer than installed $installed.',
      );
      return UpdateCheckResult(
        UpdateCheckStatus.upToDate,
        latestVersion: latest,
      );
    }

    final assets = release['assets'];
    final asset = assets is List ? selectApkAsset(assets, tag: tag) : null;
    if (asset == null) {
      _log(
        'Release $tag has no usable ${UpdateConfig.apkAssetName}; assets: '
        '${assets is List ? assets.whereType<Map>().map((a) => a['name']).join(', ') : 'none'}.',
      );
      return UpdateCheckResult(
        UpdateCheckStatus.missingApk,
        latestVersion: latest,
      );
    }
    _log(
      'Update available: $installed -> $latest. Asset ${asset['name']}, '
      '${asset['size']} bytes, digest '
      '${asset['digest'] == null ? 'not provided' : 'provided'}, '
      'URL ${asset['browser_download_url']}.',
    );
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

  /// The version a release tag names. Only the workflow's `vMAJOR.MINOR.PATCH`
  /// form is accepted (a bare `MAJOR.MINOR.PATCH` too, for older releases);
  /// pre-release, partial or other tags are not Reelish releases.
  @visibleForTesting
  static AppVersion? releaseVersion(String tag) =>
      _releaseTagPattern.hasMatch(tag) ? AppVersion.tryParse(tag) : null;

  static final _releaseTagPattern = RegExp(r'^v?\d+\.\d+\.\d+$');

  /// Picks the Android APK of release [tag]: the asset named exactly
  /// [UpdateConfig.apkAssetName], fully uploaded, of a plausible size, and
  /// downloadable only from this release's own download path. Source
  /// archives, checksums, debug or per-ABI APKs, and assets pointing at
  /// another release are never selected.
  @visibleForTesting
  static Map<String, dynamic>? selectApkAsset(
    List<dynamic> assets, {
    required String tag,
  }) {
    final matches = assets.whereType<Map<String, dynamic>>().where((asset) {
      final name = asset['name'];
      final url = asset['browser_download_url'];
      final size = asset['size'];
      final state = asset['state'];
      if (name != UpdateConfig.apkAssetName || url is! String) return false;
      if (state != null && state != 'uploaded') return false;
      if (size is! int || size <= 0 || size > UpdateConfig.maxApkBytes) {
        return false;
      }
      final uri = Uri.tryParse(url);
      return uri != null &&
          UpdateConfig.isReleaseAssetUri(uri, tag: tag, name: name as String);
    }).toList();
    // GitHub asset names are unique within a release; anything else is
    // malformed data, so nothing is offered.
    return matches.length == 1 ? matches.single : null;
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
      if (cached['installedVersion'] != installed.toString()) return null;
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
          update.latestVersion != latest ||
          releaseVersion(update.tagName) != update.latestVersion ||
          !UpdateConfig.isReleaseAssetUri(
            update.downloadUri,
            tag: update.tagName,
            name: update.assetName,
          )) {
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

  /// The installed version the cached result was computed for: null when
  /// nothing is cached, empty for results saved before this was recorded.
  static Future<String?> _cachedInstalledVersion(StorageService storage) async {
    try {
      final raw = await storage.readSetting(_lastResultKey);
      if (raw == null) return null;
      final cached = jsonDecode(raw);
      return cached is Map ? (cached['installedVersion'] as String? ?? '') : '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> _saveCachedResult(
    StorageService storage,
    UpdateCheckResult result,
    AppVersion installed,
  ) => storage.saveSetting(
    _lastResultKey,
    jsonEncode({
      'installedVersion': installed.toString(),
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
    if (!UpdateConfig.isReleaseAssetUri(
      update.downloadUri,
      tag: update.tagName,
      name: update.assetName,
    )) {
      _log('Refusing download from ${update.downloadUri}.');
      throw const UpdateException(
        'The update download link is not a Reelish release.',
      );
    }
    final Directory directory;
    final File file;
    try {
      directory = await _updatesDirectory(cacheDirectory);
      // One deterministic name per version, so an APK of another version is
      // never mistaken for this one.
      file = File(
        '${directory.path}${Platform.pathSeparator}reelish-${_safeName(update.latestVersion.toString())}.apk',
      );
      if (await file.exists()) {
        if (await _matchesExpected(file, update)) {
          final length = await file.length();
          _log('Reusing verified download ${file.path} ($length bytes).');
          onProgress?.call(length, length);
          return file;
        }
        _log('Discarding ${file.path}: it does not match the release asset.');
        await file.delete();
      }
      // Remove older updates and abandoned partial downloads.
      await for (final entity in directory.list()) {
        if (entity is File) await _deleteQuietly(entity);
      }
    } on FileSystemException catch (error) {
      _log('Update cache unavailable: $error');
      throw const UpdateException(
        'Could not save the update. Free up storage space and try again.',
      );
    }
    final partialFile = File('${file.path}.part');
    _log(
      'Downloading ${update.assetName} for ${update.tagName} from '
      '${update.downloadUri} (${update.sizeBytes ?? 'unknown'} bytes).',
    );

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
      _log(
        'Download complete: $received bytes, '
        '${update.sha256 == null ? 'size verified (no digest published)' : 'SHA-256 verified'}.',
      );
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
      _log(
        'APK inspection: package ${info?['packageName']}, version '
        '${info?['versionName']} (${info?['versionCode']}), installed build '
        '${info?['installedVersionCode']}, same signer: ${info?['sameSigner']}.',
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
      // Android only updates an app with an APK signed by the same key. Null
      // means the signers could not be read; Android still enforces it.
      if (info['sameSigner'] == false) {
        await _deleteQuietly(apk);
        throw const UpdateException(
          'This update is signed with a different key than the installed '
          'Reelish, so Android cannot install it over this version. The '
          'release needs to be fixed.',
        );
      }
      _log('Opening the Android installer for ${update.tagName}.');
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
