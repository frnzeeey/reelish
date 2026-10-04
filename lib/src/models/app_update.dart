/// A semantic version such as `1.0.10` or `v2.0.0-beta.1`.
///
/// Components are compared numerically, so `1.0.10 > 1.0.9` and
/// `1.10.0 > 1.9.0`. A pre-release sorts before its release
/// (`1.0.0-beta < 1.0.0`) and build metadata (`+5`) is ignored.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.preRelease = '']);

  final int major;
  final int minor;
  final int patch;
  final String preRelease;

  static final _pattern = RegExp(
    r'^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// Parses `1`, `1.2`, `1.2.3`, and the same with a `v` prefix,
  /// pre-release or build suffix. Returns null for anything else.
  static AppVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    int part(int group) => int.parse(match.group(group) ?? '0');
    return AppVersion(part(1), part(2), part(3), match.group(4) ?? '');
  }

  @override
  int compareTo(AppVersion other) {
    for (final (left, right) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (left != right) return left.compareTo(right);
    }
    if (preRelease == other.preRelease) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    return _comparePreRelease(preRelease, other.preRelease);
  }

  static int _comparePreRelease(String left, String right) {
    final a = left.split('.');
    final b = right.split('.');
    for (var i = 0; i < a.length && i < b.length; i++) {
      final x = int.tryParse(a[i]);
      final y = int.tryParse(b[i]);
      final comparison = switch ((x, y)) {
        (int x, int y) => x.compareTo(y),
        (int _, null) => -1,
        (null, int _) => 1,
        _ => a[i].compareTo(b[i]),
      };
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease.isEmpty ? '' : '-$preRelease'}';
}

/// A newer GitHub release that has a downloadable APK.
class AppUpdate {
  const AppUpdate({
    required this.currentVersion,
    required this.latestVersion,
    required this.tagName,
    required this.releaseName,
    required this.releaseNotes,
    required this.downloadUri,
    required this.assetName,
    this.releaseUri,
    this.sizeBytes,
    this.sha256,
  });

  final AppVersion currentVersion;
  final AppVersion latestVersion;
  final String tagName;
  final String releaseName;
  final String releaseNotes;
  final Uri downloadUri;
  final String assetName;
  final Uri? releaseUri;

  /// Asset size reported by GitHub, used to detect truncated downloads.
  final int? sizeBytes;

  /// Lowercase hex SHA-256 reported by GitHub for the asset, when available.
  final String? sha256;

  Map<String, Object?> toJson() => {
    'latestVersion': latestVersion.toString(),
    'tagName': tagName,
    'releaseName': releaseName,
    'releaseNotes': releaseNotes,
    'downloadUri': downloadUri.toString(),
    'assetName': assetName,
    'releaseUri': releaseUri?.toString(),
    'sizeBytes': sizeBytes,
    'sha256': sha256,
  };

  static AppUpdate? fromJson(Object? json, AppVersion currentVersion) {
    if (json is! Map) return null;
    final latest = AppVersion.tryParse(json['latestVersion'] as String? ?? '');
    final downloadUri = Uri.tryParse(json['downloadUri'] as String? ?? '');
    final tagName = json['tagName'];
    final assetName = json['assetName'];
    if (latest == null ||
        downloadUri == null ||
        tagName is! String ||
        assetName is! String) {
      return null;
    }
    final releaseUri = json['releaseUri'];
    final sizeBytes = json['sizeBytes'];
    final sha256 = json['sha256'];
    return AppUpdate(
      currentVersion: currentVersion,
      latestVersion: latest,
      tagName: tagName,
      releaseName: json['releaseName'] as String? ?? '',
      releaseNotes: json['releaseNotes'] as String? ?? '',
      downloadUri: downloadUri,
      assetName: assetName,
      releaseUri: releaseUri is String ? Uri.tryParse(releaseUri) : null,
      sizeBytes: sizeBytes is int ? sizeBytes : null,
      sha256: sha256 is String ? sha256 : null,
    );
  }
}

enum UpdateCheckStatus {
  /// A newer release with a valid APK exists.
  updateAvailable,

  /// The installed version is the same as or newer than the latest release.
  upToDate,

  /// The repository has no published (non-draft, non-prerelease) release.
  noRelease,

  /// A newer release exists but has no usable APK asset.
  missingApk,

  /// The device could not reach GitHub.
  networkError,

  /// GitHub refused the request because of API rate limits.
  rateLimited,

  /// GitHub returned a server error (5xx) or an unexpected status.
  serverError,

  /// The response could not be understood.
  invalidResponse,

  /// The installed version could not be read, or the platform is not Android.
  unavailable,
}

class UpdateCheckResult {
  const UpdateCheckResult(this.status, {this.update, this.latestVersion});

  final UpdateCheckStatus status;
  final AppUpdate? update;
  final AppVersion? latestVersion;

  bool get hasUpdate =>
      status == UpdateCheckStatus.updateAvailable && update != null;

  /// Text for a check the user started; automatic checks stay silent.
  String get message => switch (status) {
    UpdateCheckStatus.updateAvailable =>
      'Reelish ${update?.latestVersion} is available.',
    UpdateCheckStatus.upToDate => 'Reelish is up to date.',
    UpdateCheckStatus.noRelease => 'No releases have been published yet.',
    UpdateCheckStatus.missingApk =>
      'Reelish ${latestVersion ?? 'update'} was released, but its Android '
          'download is not available yet. Try again later.',
    UpdateCheckStatus.networkError =>
      'Unable to check for updates. Please check your internet connection.',
    UpdateCheckStatus.rateLimited =>
      'GitHub is limiting update checks right now. Try again later.',
    UpdateCheckStatus.serverError =>
      'GitHub is unavailable right now. Try again later.',
    UpdateCheckStatus.invalidResponse =>
      'Unable to read the latest release information. Try again later.',
    UpdateCheckStatus.unavailable =>
      'Update checks are not available on this device.',
  };
}

/// A download or installation step failed with a message safe to show.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
