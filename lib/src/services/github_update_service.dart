import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

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
  static const _apkAssetName = 'app-release.apk';
  static const _installerChannel = MethodChannel('onfeed/app_update');

  static Future<GitHubUpdate?> checkForUpdate() async {
    try {
      final response = await http
          .get(
            Uri.parse(_releasesUri),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'ReelishApp',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final release = jsonDecode(response.body);
      if (release is! Map<String, dynamic> ||
          release['draft'] == true ||
          release['prerelease'] == true) {
        return null;
      }

      final tag = release['tag_name'];
      final assets = release['assets'];
      if (tag is! String || assets is! List) return null;

      final releaseVersion = _parseVersion(tag);
      if (releaseVersion == null) return null;

      final installedInfo = await PackageInfo.fromPlatform();
      final installedVersion = _parseVersion(installedInfo.version);
      if (installedVersion == null ||
          _compareVersions(releaseVersion, installedVersion) <= 0) {
        return null;
      }

      for (final asset in assets) {
        if (asset is Map<String, dynamic> &&
            asset['name'] == _apkAssetName &&
            asset['browser_download_url'] is String) {
          final downloadUri = Uri.tryParse(asset['browser_download_url']);
          if (downloadUri == null ||
              downloadUri.scheme != 'https' ||
              downloadUri.host != 'github.com') {
            return null;
          }
          return GitHubUpdate(
            version: tag,
            notes: release['body'] is String ? release['body'] as String : '',
            downloadUri: downloadUri,
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Downloads the APK into the app's cache so the user never has to visit
  /// GitHub to obtain the update. Android still presents its normal install UI.
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
      var received = 0;
      final sink = partialFile.openWrite();
      try {
        await for (final chunk in response.stream) {
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

  /// Opens Android's package installer for a previously downloaded APK.
  /// Returns `permission_required` when Android first needs the user to allow
  /// installs from Reelish, or `installer_opened` when installation can start.
  static Future<String> installApk(File apk) async {
    return await _installerChannel.invokeMethod<String>(
          'installApk',
          {'path': apk.path},
        ) ??
        'failed';
  }

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
