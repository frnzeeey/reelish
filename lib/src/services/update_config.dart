import 'package:flutter/foundation.dart';

import '../platform/windows_installation.dart';

/// Settings for the GitHub Releases based Android updater.
///
/// Releases are published only by `.github/workflows/release.yml` (see
/// `docs/releasing.md`): pushing a `vX.Y.Z` tag builds that exact commit,
/// checks that `pubspec.yaml` says `X.Y.Z`, verifies the APK, and publishes it
/// as the `reelish.apk` asset of release `vX.Y.Z`. Never upload an APK by
/// hand: the updater trusts that the tag, the APK's version and the asset all
/// describe the same build.
abstract final class UpdateConfig {
  static const githubOwner = 'frnzeeey';
  static const githubRepository = 'reelish';

  /// The only release asset the updater downloads. The release workflow
  /// uploads the APK under exactly this name.
  static const apkAssetName = 'reelish.apk';

  /// The Windows release asset: a portable ZIP of the whole app folder,
  /// published by `.github/workflows/release-windows.yml`.
  static const windowsAssetName = 'Reelish-Windows-x64.zip';

  /// The Windows installer (Inno Setup, per user, no administrator rights),
  /// published by the same workflow. Installed copies update from it.
  static const windowsInstallerAssetName = 'Reelish-Setup-x64.exe';

  /// The asset this platform updates from: the APK on Android; on Windows
  /// the installer for installed copies and the ZIP for portable ones.
  static String get assetName {
    if (defaultTargetPlatform != TargetPlatform.windows) return apkAssetName;
    return WindowsInstallation.usesInstaller
        ? windowsInstallerAssetName
        : windowsAssetName;
  }

  /// Windows updates are only offered with a SHA-256: GitHub's asset digest,
  /// or else the `<asset>.sha256` file the workflow publishes beside it.
  /// Android keeps its size check, since Android itself verifies the APK's
  /// signature against the installed app.
  static bool get requiresChecksum =>
      defaultTargetPlatform == TargetPlatform.windows;

  /// The checksum file published next to [assetName].
  static String checksumAssetName(String assetName) => '$assetName.sha256';

  /// Upper bound on a `.sha256` file (`<64 hex>  <name>`).
  static const maxChecksumBytes = 4096;

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

  /// GitHub's latest *published* release: never a draft or a pre-release,
  /// and chosen by publish date and the "latest" flag, not by tag name.
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
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.path.startsWith('/$githubOwner/$githubRepository/releases/download/');

  /// Whether [uri] is exactly the download link of asset [name] in release
  /// [tag], so an asset of another (older) release is never accepted.
  static bool isReleaseAssetUri(
    Uri uri, {
    required String tag,
    required String name,
  }) =>
      isTrustedAssetUri(uri) &&
      _sameSegments(uri.pathSegments, [
        githubOwner,
        githubRepository,
        'releases',
        'download',
        tag,
        name,
      ]);

  /// Hosts a Windows download may be redirected to: GitHub serves release
  /// assets from github.com through its githubusercontent.com storage.
  /// Integrity still comes from the SHA-256, not from the host.
  static bool isTrustedRedirectUri(Uri uri) =>
      uri.scheme == 'https' &&
      !uri.hasFragment &&
      (uri.host == 'github.com' ||
          (uri.host.endsWith('.githubusercontent.com') &&
              uri.host != 'raw.githubusercontent.com'));

  static bool _sameSegments(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
