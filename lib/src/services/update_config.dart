/// Settings for the GitHub Releases based Android updater.
///
/// Releases are published as `vX.Y.Z` tags with a `reelish.apk` asset:
///
/// ```bash
/// flutter build apk --release --build-name 1.0.1 --build-number 1
/// gh release create v1.0.1 build/app/outputs/flutter-apk/reelish.apk \
///   --title "Reelish v1.0.1" --generate-notes
/// ```
abstract final class UpdateConfig {
  static const githubOwner = 'frnzeeey';
  static const githubRepository = 'reelish';

  /// Asset names accepted as the Android build, in order of preference.
  /// `app-release.apk` is Flutter's default output name.
  static const apkAssetNames = ['reelish.apk', 'app-release.apk'];

  /// Minimum time between automatic GitHub API requests. Unauthenticated
  /// requests are limited to 60 per hour per IP address, which may be shared
  /// by many devices on carrier networks.
  static const checkInterval = Duration(hours: 6);
  static const requestTimeout = Duration(seconds: 10);

  /// A download that receives no data for this long is treated as stalled.
  /// There is no total download time limit, so slow connections still finish.
  static const downloadIdleTimeout = Duration(seconds: 30);

  /// Upper bound on the APK size, so a misconfigured asset cannot fill the
  /// device cache.
  static const maxApkBytes = 512 * 1024 * 1024;

  static const userAgent = 'ReelishApp';

  static Uri get latestReleaseUri => Uri.https(
    'api.github.com',
    '/repos/$githubOwner/$githubRepository/releases/latest',
  );

  static Uri get releasesPageUri =>
      Uri.https('github.com', '/$githubOwner/$githubRepository/releases');

  /// Release assets are only downloaded from this repository's release paths.
  static bool isTrustedAssetUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.path.startsWith('/$githubOwner/$githubRepository/releases/download/');
}
