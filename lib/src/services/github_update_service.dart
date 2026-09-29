import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

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
