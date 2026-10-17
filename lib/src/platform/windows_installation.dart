import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How the running Windows copy of Reelish was installed.
///
/// The installer (`Reelish-Setup-x64.exe`, Inno Setup, per user) writes its
/// uninstaller next to `Reelish.exe`; a portable ZIP copy has none. Only an
/// installed copy can be updated in place: its installer knows the folder,
/// waits for Reelish to exit and replaces the files. A portable copy is
/// never modified by Reelish.
abstract final class WindowsInstallation {
  static bool? _usesInstaller;

  /// Whether this copy was installed by the Reelish installer. False on
  /// other platforms and when the check fails.
  static bool get usesInstaller {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return false;
    }
    return _usesInstaller ??= _detect();
  }

  @visibleForTesting
  static set debugUsesInstaller(bool? value) => _usesInstaller = value;

  static bool _detect() {
    try {
      final directory = File(Platform.resolvedExecutable).parent.path;
      return File('$directory\\unins000.exe').existsSync() &&
          File('$directory\\unins000.dat').existsSync();
    } catch (_) {
      return false;
    }
  }
}

/// The identity read from a downloaded installer's version resource and
/// Authenticode signature by the Windows runner.
class InstallerInspection {
  const InstallerInspection({
    required this.productName,
    required this.companyName,
    required this.version,
    required this.signature,
  });

  final String productName;
  final String companyName;

  /// `major.minor.patch` from the fixed product version, or null.
  final String? version;

  /// `valid`, `unsigned` or `invalid` (a signature that does not verify).
  final String signature;
}

/// The `reelish/app_update` channel in `windows/runner/app_update_channel.cpp`.
/// Arguments of the installer are fixed by the runner; nothing from release
/// metadata reaches a command line.
class WindowsInstallerBridge {
  const WindowsInstallerBridge();

  static const _channel = MethodChannel('reelish/app_update');

  /// Reads [path]'s version resource and checks its signature. Null when the
  /// file is not a readable Windows executable.
  Future<InstallerInspection?> inspect(String path) async {
    final info = await _channel.invokeMapMethod<String, Object?>(
      'inspectInstaller',
      {'path': path},
    );
    if (info == null) return null;
    // Inno Setup pads its version strings with spaces.
    return InstallerInspection(
      productName: (info['productName'] as String? ?? '').trim(),
      companyName: (info['companyName'] as String? ?? '').trim(),
      version: info['version'] as String?,
      signature: info['signature'] as String? ?? 'invalid',
    );
  }

  /// Free bytes on the volume of [path], or null when unknown.
  Future<int?> freeDiskSpace(String path) async {
    try {
      return await _channel.invokeMethod<int>('freeDiskSpace', {'path': path});
    } catch (_) {
      return null;
    }
  }

  /// Starts the installer at [path] for this app's folder, then closes
  /// Reelish's window. Returns false (and keeps Reelish open) when the
  /// installer could not be started.
  Future<bool> launchAndQuit(String path, {required String logPath}) async =>
      await _channel.invokeMethod<bool>('launchInstaller', {
        'path': path,
        'logPath': logPath,
      }) ??
      false;
}
