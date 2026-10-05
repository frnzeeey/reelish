import 'dart:async';
import 'dart:io';

import 'package:feather_icon_font/feather_icon_font.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/app_update.dart';
import '../services/github_update_service.dart';
import 'update_dialog.dart';

/// What the update flow is doing. One value, so states such as "checking"
/// and "downloading" can never both be true.
enum UpdateFlowPhase {
  idle,

  /// A silent check on app start or resume is waiting for GitHub.
  checkingInBackground,

  /// A check the user started from About is waiting for GitHub.
  checkingManually,

  /// The update prompt, download, permission or installer step is showing.
  updating,
}

/// Coordinates the update UI: prompt → download → install permission →
/// Android installer. Only one update runs at a time.
abstract final class AppUpdateFlow {
  static UpdateFlowPhase _phase = UpdateFlowPhase.idle;

  /// Identifies the flow that owns [_phase]; a user-started check takes over
  /// from a background check still waiting for GitHub.
  static int _owner = 0;

  @visibleForTesting
  static UpdateFlowPhase get phase => _phase;

  @visibleForTesting
  static void resetForTest() {
    _phase = UpdateFlowPhase.idle;
    _owner++;
    _offeredThisSession.clear();
  }

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
    if (!isSupported || _phase != UpdateFlowPhase.idle) return;
    final owner = ++_owner;
    _phase = UpdateFlowPhase.checkingInBackground;
    try {
      final result = await (checker ?? GitHubUpdateService.checkForUpdate)();
      // A manual check started meanwhile reports the outcome itself.
      if (owner != _owner) return;
      final update = result.update;
      if (!result.hasUpdate || update == null || !context.mounted) return;
      if (_offeredThisSession.contains(update.tagName)) return;
      // Never interrupt playback or another screen; the next resume retries.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      _offeredThisSession.add(update.tagName);
      _phase = UpdateFlowPhase.updating;
      await _offer(context, update);
    } catch (_) {
      // Update checks must never disturb normal app use.
    } finally {
      if (owner == _owner) _phase = UpdateFlowPhase.idle;
    }
  }

  /// User-started check, which reports every outcome. It always asks GitHub,
  /// and takes over from a background check that is still running.
  static Future<void> checkManually(
    BuildContext context, {
    Future<UpdateCheckResult> Function()? checker,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    switch (_phase) {
      case UpdateFlowPhase.updating:
        messenger?.showSnackBar(
          const SnackBar(content: Text('An update is already in progress.')),
        );
        return;
      case UpdateFlowPhase.checkingManually:
        return; // A second tap while the first check runs.
      case UpdateFlowPhase.idle || UpdateFlowPhase.checkingInBackground:
        break;
    }
    final owner = ++_owner;
    _phase = UpdateFlowPhase.checkingManually;
    try {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Checking for updates…'),
          duration: Duration(seconds: 2),
        ),
      );
      final result =
          await (checker ??
              () => GitHubUpdateService.checkForUpdate(forceRefresh: true))();
      if (owner != _owner || !context.mounted) return;
      messenger?.hideCurrentSnackBar();
      final update = result.update;
      if (result.hasUpdate && update != null) {
        _offeredThisSession.add(update.tagName);
        _phase = UpdateFlowPhase.updating;
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
    } catch (_) {
      if (context.mounted) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Unable to check for updates.')),
        );
      }
    } finally {
      if (owner == _owner) _phase = UpdateFlowPhase.idle;
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
