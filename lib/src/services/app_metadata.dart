import 'package:package_info_plus/package_info_plus.dart';

/// Version and build details for the running app.
abstract final class AppMetadata {
  /// Read once; a rebuild must not start another platform call.
  static final Future<PackageInfo> packageInfo = PackageInfo.fromPlatform();

  static const gitSha = String.fromEnvironment(
    'REELISH_GIT_SHA',
    defaultValue: 'unknown',
  );

  static const buildTag = String.fromEnvironment(
    'REELISH_BUILD_TAG',
    defaultValue: 'local',
  );

  static const projectUrl = 'https://github.com/frnzeeey/reelish';
}
