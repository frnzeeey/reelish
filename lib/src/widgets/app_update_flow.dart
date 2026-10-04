import 'dart:async';
import 'dart:io';

import 'package:feather_icon_font/feather_icon_font.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/app_update.dart';
import '../services/github_update_service.dart';
import 'update_dialog.dart';

/// Coordinates the update UI: prompt → download → install permission →
/// Android installer. Only one check or update runs at a time.
abstract final class AppUpdateFlow {
  static bool _busy = false;

  /// Releases already offered automatically during this app session. After
  /// "Later" the same release is offered again on the next app launch.
  static final _offeredThisSession = <String>{};

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Background check for app start and resume. Shows nothing unless a newer
  /// release with an APK exists; failures are silent.
  static Future<void> checkAutomatically(
    BuildContext context, {
    Future<UpdateCheckResult> Function()? checker,
  }) async {
    if (!isSupported || _busy) return;
    _busy = true;
    try {
      final result = await (checker ?? GitHubUpdateService.checkForUpdate)();
      final update = result.update;
      if (!result.hasUpdate || update == null || !context.mounted) return;
      if (_offeredThisSession.contains(update.tagName)) return;
      // Never interrupt playback or another screen; the next resume retries.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      _offeredThisSession.add(update.tagName);
      await _offer(context, update);
    } catch (_) {
      // Update checks must never disturb normal app use.
    } finally {
      _busy = false;
    }
  }

  /// User-started check, which reports every outcome.
  static Future<void> checkManually(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (_busy) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('An update is already in progress.')),
      );
      return;
    }
    _busy = true;
    try {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Checking for updates…'),
          duration: Duration(seconds: 2),
        ),
      );
      final result = await GitHubUpdateService.checkForUpdate(
        forceRefresh: true,
      );
      if (!context.mounted) return;
      messenger?.hideCurrentSnackBar();
      final update = result.update;
      if (result.hasUpdate && update != null) {
        _offeredThisSession.add(update.tagName);
        await _offer(context, update);
      } else if (result.status == UpdateCheckStatus.upToDate ||
          result.status == UpdateCheckStatus.noRelease) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Reelish is up to date.')),
        );
      } else {
        await _notice(
          context,
          title: result.status == UpdateCheckStatus.missingApk
              ? 'Update not ready yet'
              : 'Unable to check for updates',
          message: result.message,
          icon: result.status == UpdateCheckStatus.networkError
              ? FeatherIcons.wifiOff
              : FeatherIcons.alertCircle,
        );
      }
    } finally {
      _busy = false;
    }
  }

  static Future<void> _offer(BuildContext context, AppUpdate update) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => UpdateAvailableDialog(update: update),
    );
    if (accepted != true || !context.mounted) return;
    final apk = await showDialog<File>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDownloadDialog(update: update),
    );
    if (apk == null || !context.mounted) return;
    await _install(context, apk, update);
  }

  static Future<void> _install(
    BuildContext context,
    File apk,
    AppUpdate update,
  ) async {
    if (!await GitHubUpdateService.canInstallPackages()) {
      if (!context.mounted) return;
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (_) => const InstallPermissionDialog(),
      );
      if (openSettings != true || !context.mounted) return;

      final returned = _waitForResume();
      if (!await GitHubUpdateService.openInstallPermissionSettings()) {
        returned.cancel();
        if (context.mounted) {
          await _notice(
            context,
            title: 'Allow Reelish to install updates',
            message:
                'Open Android Settings → Apps → Reelish → Install unknown '
                'apps, allow it, then check for updates again from About.',
          );
        }
        return;
      }
      await returned.future;
      if (!context.mounted) return;
      if (!await GitHubUpdateService.canInstallPackages()) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text(
                'Reelish needs "Install unknown apps" permission to update. '
                'You can try again from About.',
              ),
            ),
          );
        }
        return;
      }
    }
    try {
      // Android shows its own confirmation. If the user cancels there, they
      // simply return to Reelish; the verified APK stays cached for a retry.
      await GitHubUpdateService.installApk(apk, update);
    } on UpdateException catch (error) {
      if (context.mounted) {
        await _notice(
          context,
          title: 'Unable to install the update',
          message: error.message,
        );
      }
    }
  }

  /// Completes when the app returns to the foreground (after Settings).
  static ({Future<void> future, void Function() cancel}) _waitForResume() {
    final completer = Completer<void>();
    late final AppLifecycleListener listener;
    void finish() {
      if (completer.isCompleted) return;
      listener.dispose();
      completer.complete();
    }

    listener = AppLifecycleListener(onResume: finish);
    return (
      future: completer.future.timeout(
        const Duration(minutes: 10),
        onTimeout: finish,
      ),
      cancel: finish,
    );
  }

  static Future<void> _notice(
    BuildContext context, {
    required String title,
    required String message,
    IconData icon = FeatherIcons.alertCircle,
  }) => showDialog<void>(
    context: context,
    builder: (_) =>
        UpdateNoticeDialog(title: title, message: message, icon: icon),
  );
}
