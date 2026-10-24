import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_config.dart';
import '../services/windows_update_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/app_update_flow.dart';
import '../widgets/settings/settings_components.dart';
import '../widgets/update_dialog.dart';
import 'desktop_update_dialogs.dart';

/// Settings → About on Windows: version, update status, last check, the
/// update action for the current state, and the automatic-check switch.
class WindowsUpdateSection extends StatefulWidget {
  const WindowsUpdateSection({
    super.key,
    required this.installedVersion,
    this.controller,
  });

  final String installedVersion;

  /// Defaults to [AppUpdateFlow.windowsController].
  final WindowsUpdateController? controller;

  @override
  State<WindowsUpdateSection> createState() => _WindowsUpdateSectionState();
}

class _WindowsUpdateSectionState extends State<WindowsUpdateSection> {
  WindowsUpdateController get _controller =>
      widget.controller ?? AppUpdateFlow.windowsController;

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  String _status(WindowsUpdateController c) {
    final version = c.update?.latestVersion;
    return switch (c.stage) {
      WindowsUpdateStage.idle => 'Not checked yet this session.',
      WindowsUpdateStage.checking => 'Checking for updates…',
      WindowsUpdateStage.upToDate => "You're up to date.",
      WindowsUpdateStage.available => 'Version $version is available.',
      WindowsUpdateStage.downloading =>
        c.progress == null
            ? 'Downloading version $version…'
            : 'Downloading version $version… '
                  '${(c.progress! * 100).floor()}% of '
                  '${formatMegabytes(c.total!)} MB'
                  '${c.bytesPerSecond == null ? '' : ' · ${formatTransferSpeed(c.bytesPerSecond!)}'}',
      WindowsUpdateStage.verifying => 'Verifying version $version…',
      WindowsUpdateStage.ready =>
        'Version $version is downloaded and ready to install.',
      WindowsUpdateStage.installing => 'Starting the installer…',
      WindowsUpdateStage.failed => c.error ?? 'The update failed.',
    };
  }

  /// The one action that fits the current state.
  Widget? _action(BuildContext context, WindowsUpdateController c) {
    final update = c.update;
    Widget button(String label, VoidCallback? onPressed) => FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        textStyle: const TextStyle(
          fontFamily: GlassTheme.fontFamily,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(label),
    );
    return switch (c.stage) {
      WindowsUpdateStage.available when update != null => button(
        c.canInstallInApp ? 'Update now' : 'Download update',
        () => AppUpdateFlow.updateFromSettings(
          context,
          update,
          confirm: !c.canInstallInApp,
        ),
      ),
      WindowsUpdateStage.failed when update != null => button(
        'Retry',
        c.canInstallInApp
            ? () => AppUpdateFlow.updateFromSettings(
                context,
                update,
                confirm: false,
              )
            : () => AppUpdateFlow.checkManually(context),
      ),
      WindowsUpdateStage.downloading ||
      WindowsUpdateStage.verifying => OutlinedButton(
        onPressed: c.stage == WindowsUpdateStage.downloading
            ? c.cancelDownload
            : null,
        child: const Text('Cancel'),
      ),
      WindowsUpdateStage.ready when update != null => button(
        'Restart and install',
        () => AppUpdateFlow.updateFromSettings(context, update, confirm: false),
      ),
      _ => null,
    };
  }

  Future<void> _viewReleaseNotes(
    BuildContext context,
    WindowsUpdateController c,
  ) async {
    final update = c.update;
    if (update != null) {
      await showDialog<void>(
        context: context,
        builder: (_) =>
            DesktopUpdateAvailableDialog(update: update, readOnly: true),
      );
      return;
    }
    final opened = await launchUrl(
      UpdateConfig.releasesPageUri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not open the release page.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final c = _controller;
      final lastChecked = c.lastChecked;
      final downloading =
          c.stage == WindowsUpdateStage.downloading ||
          c.stage == WindowsUpdateStage.verifying;
      return SettingsSection(
        label: 'APPLICATION UPDATES',
        children: [
          SettingsTile(
            icon: Symbols.verified_rounded,
            title: 'Current version',
            value: widget.installedVersion,
          ),
          Semantics(
            liveRegion: true,
            child: SettingsTile(
              icon: c.stage == WindowsUpdateStage.failed
                  ? Symbols.error_rounded
                  : Symbols.system_update_rounded,
              title: 'Update status',
              description: _status(c),
              trailing: _action(context, c),
              mergeSemantics: false,
            ),
          ),
          if (downloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: c.stage == WindowsUpdateStage.verifying
                      ? null
                      : c.progress,
                  minHeight: 6,
                  backgroundColor: GlassTheme.glassStrong,
                ),
              ),
            ),
          SettingsTile(
            icon: Symbols.schedule_rounded,
            title: 'Last checked',
            value: lastChecked == null
                ? 'Never'
                : formatUpdateDate(lastChecked),
          ),
          SettingsTile(
            icon: Symbols.refresh_rounded,
            title: 'Check for updates',
            description: 'Look for a newer release on GitHub.',
            enabled: !c.isBusy,
            onTap: () => AppUpdateFlow.checkManually(context),
          ),
          SettingsSwitchTile(
            icon: Symbols.update_rounded,
            title: 'Check for updates automatically',
            description:
                'About once every few hours, after Reelish starts. Updates '
                'are never installed without asking.',
            value: c.autoCheck,
            onChanged: c.setAutoCheck,
          ),
          SettingsTile(
            icon: Symbols.article_rounded,
            title: 'View release notes',
            description: c.update == null
                ? 'Opens the Reelish releases page in your browser.'
                : "What's new in version ${c.update!.latestVersion}.",
            onTap: () => _viewReleaseNotes(context, c),
          ),
          SettingsTile(
            icon: Symbols.inventory_2_rounded,
            title: 'Installation',
            value: c.canInstallInApp ? 'Installed' : 'Portable (ZIP)',
            description: c.canInstallInApp
                ? 'Updates install in place. Your settings, library and '
                      'plugins are kept.'
                : 'Updates are verified and saved to Downloads for you to '
                      'extract. Install Reelish with '
                      '${UpdateConfig.windowsInstallerAssetName} to update in '
                      'one step.',
          ),
        ],
      );
    },
  );
}
