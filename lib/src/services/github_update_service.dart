import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'storage_service.dart';

class GitHubUpdate {
  const GitHubUpdate({
    required this.version,
    required this.notes,
    required this.downloadUri,
  });

  final String version;
  final String notes;
  final Uri downloadUri;
}

abstract final class GitHubUpdateService {
  static const _releasesUri =
      'https://api.github.com/repos/frnzeeey/reelish/releases/latest';
  static const _apkAssetNames = ['reelish.apk', 'app-release.apk'];
  static const _installerChannel = MethodChannel('onfeed/app_update');
  static const _lastCheckKey = 'onfeed.update.github.lastCheckedAt.v1';
  static const _lastResultKey = 'onfeed.update.github.lastResult.v1';
  static const checkInterval = Duration(hours: 6);
  // Keep the updater from consuming unbounded app-cache storage if a release
  // asset is misconfigured or the server omits Content-Length.
  static const maxApkDownloadBytes = 512 * 1024 * 1024;

  static Future<GitHubUpdate?> checkForUpdate({
    bool forceRefresh = false,
    StorageService? storage,
    http.Client? client,
    DateTime Function()? clock,
    Future<String?> Function()? installedVersionLoader,
  }) async {
    final settings = storage ?? StorageService();
    final now = (clock ?? DateTime.now)();
    final installedVersion = _parseVersion(
      await (installedVersionLoader ?? _installedVersion)() ?? '',
    );
    if (installedVersion == null) return null;

    final cached = await _readCachedResult(settings, installedVersion);
    final lastCheck = DateTime.tryParse(
      await settings.readSetting(_lastCheckKey) ?? '',
    );
    if (!forceRefresh &&
        lastCheck != null &&
        now.difference(lastCheck) < checkInterval) {
      if (kDebugMode) {
        debugPrint('[UPDATE] GitHub check skipped; cached result reused.');
      }
      return cached;
    }

    // Persist before the request, so relaunches do not repeat a failing call.
    await settings.saveSetting(_lastCheckKey, now.toUtc().toIso8601String());
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .get(
            Uri.parse(_releasesUri),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'ReelishApp',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return cached;

      final release = jsonDecode(response.body);
      if (release is! Map<String, dynamic> ||
          release['draft'] == true ||
          release['prerelease'] == true) {
        await _saveCachedResult(settings, checkedAt: now, update: null);
        return null;
      }

      final tag = release['tag_name'];
      final assets = release['assets'];
      if (tag is! String || assets is! List) return cached;

      final releaseVersion = _parseVersion(tag);
      if (releaseVersion == null ||
          _compareVersions(releaseVersion, installedVersion) <= 0) {
        await _saveCachedResult(settings, checkedAt: now, update: null);
        return null;
      }

      for (final assetName in _apkAssetNames) {
        for (final asset in assets) {
          if (asset is Map<String, dynamic> &&
              asset['name'] == assetName &&
              asset['browser_download_url'] is String) {
            final downloadUri = Uri.tryParse(asset['browser_download_url']);
            if (downloadUri == null ||
                downloadUri.scheme != 'https' ||
                downloadUri.host != 'github.com') {
              await _saveCachedResult(settings, checkedAt: now, update: null);
              return null;
            }
            final update = GitHubUpdate(
              version: tag,
              notes: release['body'] is String ? release['body'] as String : '',
              downloadUri: downloadUri,
            );
            await _saveCachedResult(settings, checkedAt: now, update: update);
            return update;
          }
        }
      }
      await _saveCachedResult(settings, checkedAt: now, update: null);
      return null;
    } catch (_) {
      return cached;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Future<String?> _installedVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
  }

  static Future<GitHubUpdate?> _readCachedResult(
    StorageService storage,
    List<int> installedVersion,
  ) async {
    try {
      final raw = await storage.readSetting(_lastResultKey);
      if (raw == null) return null;
      final cached = jsonDecode(raw);
      if (cached is! Map || cached['hasUpdate'] != true) return null;
      final version = cached['version'];
      final notes = cached['notes'];
      final uriRaw = cached['downloadUri'];
      if (version is! String || notes is! String || uriRaw is! String) {
        return null;
      }
      final parsedVersion = _parseVersion(version);
      final uri = Uri.tryParse(uriRaw);
      if (parsedVersion == null ||
          _compareVersions(parsedVersion, installedVersion) <= 0 ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com') {
        return null;
      }
      return GitHubUpdate(version: version, notes: notes, downloadUri: uri);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveCachedResult(
    StorageService storage, {
    required DateTime checkedAt,
    required GitHubUpdate? update,
  }) async {
    await storage.saveSetting(
      _lastResultKey,
      jsonEncode({
        'checkedAt': checkedAt.toUtc().toIso8601String(),
        'hasUpdate': update != null,
        if (update != null) ...{
          'version': update.version,
          'notes': update.notes,
          'downloadUri': update.downloadUri.toString(),
        },
      }),
    );
  }

  /// Downloads the release APK into the app cache. Android still shows its
  /// standard installation confirmation to the user.
  static Future<File> downloadApk(
    GitHubUpdate update, {
    void Function(int received, int total)? onProgress,
  }) async {
    final directory = await getTemporaryDirectory();
    final safeVersion = update.version.replaceAll(
      RegExp(r'[^a-zA-Z0-9._-]'),
      '_',
    );
    final file = File('${directory.path}/reelish-update-$safeVersion.apk');
    if (await file.exists() && await file.length() > 0) return file;
    if (await file.exists()) await file.delete();
    final partialFile = File('${file.path}.part');

    final request = http.Request('GET', update.downloadUri);
    request.headers['User-Agent'] = 'ReelishApp';
    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) {
        throw HttpException('APK download failed (${response.statusCode}).');
      }

      final total = response.contentLength ?? 0;
      if (total > maxApkDownloadBytes) {
        throw const HttpException('The APK download exceeds the size limit.');
      }
      var received = 0;
      final sink = partialFile.openWrite();
      try {
        await for (final chunk in response.stream) {
          if (chunk.length > maxApkDownloadBytes - received) {
            throw const HttpException(
              'The APK download exceeds the size limit.',
            );
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();
        if (received == 0 || (total > 0 && received != total)) {
          throw const HttpException('The APK download was incomplete.');
        }
        return await partialFile.rename(file.path);
      } catch (_) {
        await sink.close();
        rethrow;
      }
    } catch (_) {
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Opens Android's installer for the previously downloaded release APK.
  /// Android can request the user to allow installs from this source first.
  static Future<String> installApk(File apk) async =>
      await _installerChannel.invokeMethod<String>('installApk', {
        'path': apk.path,
      }) ??
      'failed';

  static List<int>? _parseVersion(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final core = normalized.split(RegExp(r'[-+]')).first;
    final parts = core.split('.');
    if (parts.length != 3) return null;
    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((part) => part == null)) return null;
    return numbers.cast<int>();
  }

  static int _compareVersions(List<int> left, List<int> right) {
    for (var i = 0; i < 3; i++) {
      final comparison = left[i].compareTo(right[i]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }
}
