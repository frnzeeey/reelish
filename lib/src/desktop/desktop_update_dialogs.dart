import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/app_update.dart';
import '../services/windows_update_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/update_dialog.dart';

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

/// `October 17, 2026`, in local time.
String formatUpdateDate(DateTime date) {
  final local = date.toLocal();
  return '${_months[local.month - 1]} ${local.day}, ${local.year}';
}

/// `2.4 MB/s`, or `512 KB/s` below a megabyte per second.
String formatTransferSpeed(double bytesPerSecond) =>
    bytesPerSecond >= 1024 * 1024
    ? '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s'
    : '${(bytesPerSecond / 1024).round()} KB/s';

/// The release notes box shared by the desktop update dialogs. Its own
/// controller: a desktop Scrollbar with a visible thumb needs one.
class _ReleaseNotes extends StatefulWidget {
  const _ReleaseNotes({required this.notes});

  final String notes;

  @override
  State<_ReleaseNotes> createState() => _ReleaseNotesState();
}

class _ReleaseNotesState extends State<_ReleaseNotes> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 18),
      Text(
        "What's new",
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .32,
        ),
        decoration: BoxDecoration(
          color: GlassTheme.glassBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: GlassTheme.border),
        ),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                widget.notes,
                style: updateDialogBodyStyle(context)?.copyWith(
                  color: GlassTheme.textPrimary.withValues(alpha: .86),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Offers a newer release on Windows: both versions, the release date and
/// size, and the notes. Pops `true` for "Update now".
class DesktopUpdateAvailableDialog extends StatelessWidget {
  const DesktopUpdateAvailableDialog({
    super.key,
    required this.update,
    this.readOnly = false,
  });

  final AppUpdate update;

  /// Only shows the notes (Settings → View release notes).
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final notes = formatReleaseNotes(update.releaseNotes);
    final published = update.publishedAt;
    final details = [
      if (published != null) 'Released ${formatUpdateDate(published)}',
      if (update.sizeBytes != null)
        '${formatMegabytes(update.sizeBytes!)} MB download',
    ].join(' · ');
    return UpdateDialogFrame(
      icon: Symbols.system_update_rounded,
      title: readOnly
          ? 'Reelish ${update.latestVersion}'
          : 'Reelish update available',
      maxWidth: 520,
      actions: readOnly
          ? [
              UpdateDialogButton(
                label: 'Close',
                primary: true,
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
              ),
            ]
          : [
              UpdateDialogButton(
                label: 'Later',
                onPressed: () => Navigator.pop(context, false),
              ),
              UpdateDialogButton(
                label: 'Update now',
                primary: true,
                autofocus: true,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
      children: [
        Text(
          'Version ${update.latestVersion} is now available. '
          "You're currently running version ${update.currentVersion}.",
          style: updateDialogBodyStyle(context),
        ),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            details,
            style: updateDialogBodyStyle(context)?.copyWith(fontSize: 12.5),
          ),
        ],
        if (notes.isNotEmpty) _ReleaseNotes(notes: notes),
      ],
    );
  }
}

/// Follows a Windows update from download to installer handoff. Closing it
/// (Escape, "Continue in background", "Later") leaves a download running;
/// Settings → About shows its progress.
class DesktopUpdateProgressDialog extends StatefulWidget {
  const DesktopUpdateProgressDialog({super.key, required this.controller});

  final WindowsUpdateController controller;

  @override
  State<DesktopUpdateProgressDialog> createState() =>
      _DesktopUpdateProgressDialogState();
}

class _DesktopUpdateProgressDialogState
    extends State<DesktopUpdateProgressDialog> {
  String? _installError;

  WindowsUpdateController get _controller => widget.controller;

  Future<void> _install() async {
    setState(() => _installError = null);
    final error = await _controller.install();
    if (!mounted) return;
    setState(() => _installError = error);
  }

  void _close() => Navigator.pop(context);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final update = _controller.update;
      final version = update?.latestVersion.toString() ?? '';
      return switch (_controller.stage) {
        WindowsUpdateStage.downloading ||
        WindowsUpdateStage.verifying => _progress(context, version),
        WindowsUpdateStage.ready => _ready(context, version),
        WindowsUpdateStage.installing => UpdateDialogFrame(
          icon: Symbols.install_desktop_rounded,
          title: 'Installing Reelish $version',
          maxWidth: 480,
          actions: const [],
          children: [
            Text(
              'Reelish is closing so the installer can update it. It opens '
              'again when the update is installed.',
              style: updateDialogBodyStyle(context),
            ),
            const SizedBox(height: 18),
            const LinearProgressIndicator(minHeight: 6),
          ],
        ),
        WindowsUpdateStage.failed => UpdateDialogFrame(
          icon: Symbols.error_rounded,
          title: 'Update failed',
          maxWidth: 480,
          actions: [
            UpdateDialogButton(label: 'Close', onPressed: _close),
            UpdateDialogButton(
              label: 'Retry',
              primary: true,
              autofocus: true,
              onPressed: _controller.download,
            ),
          ],
          children: [
            Text(
              '${_controller.error ?? 'The update failed.'}\n\n'
              'Reelish was not changed, and you can keep using it.',
              style: updateDialogBodyStyle(context),
            ),
          ],
        ),
        _ => UpdateDialogFrame(
          icon: Symbols.download_rounded,
          title: 'Download cancelled',
          maxWidth: 480,
          actions: [
            UpdateDialogButton(label: 'Close', onPressed: _close),
            UpdateDialogButton(
              label: 'Download again',
              primary: true,
              onPressed: update == null ? null : _controller.download,
            ),
          ],
          children: [
            Text(
              'The partial download was removed. You can update any time '
              'from Settings → About.',
              style: updateDialogBodyStyle(context),
            ),
          ],
        ),
      };
    },
  );

  Widget _progress(BuildContext context, String version) {
    final verifying = _controller.stage == WindowsUpdateStage.verifying;
    final progress = _controller.progress;
    final total = _controller.total;
    final speed = _controller.bytesPerSecond;
    final received = _controller.received;
    return UpdateDialogFrame(
      icon: verifying
          ? Symbols.verified_user_rounded
          : Symbols.download_rounded,
      title: verifying
          ? 'Verifying the update'
          : 'Downloading Reelish $version',
      maxWidth: 480,
      actions: [
        UpdateDialogButton(
          label: 'Cancel',
          onPressed: verifying ? null : _controller.cancelDownload,
        ),
        UpdateDialogButton(
          label: 'Continue in background',
          primary: true,
          autofocus: true,
          onPressed: _close,
        ),
      ],
      children: [
        Text(
          verifying
              ? 'Checking the installer against the release checksum and '
                    'its Reelish identity.'
              : 'You can keep using Reelish while the update downloads.',
          style: updateDialogBodyStyle(context),
        ),
        const SizedBox(height: 18),
        Semantics(
          label: 'Download progress',
          value: progress == null ? null : '${(progress * 100).floor()}%',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: verifying ? null : progress,
              minHeight: 8,
              backgroundColor: GlassTheme.glassStrong,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              verifying
                  ? 'Verifying…'
                  : progress == null
                  ? 'Downloading…'
                  : '${(progress * 100).floor()}%',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                [
                  total != null && total > 0
                      ? '${formatMegabytes(received)} MB / ${formatMegabytes(total)} MB'
                      : '${formatMegabytes(received)} MB',
                  if (speed != null && !verifying) formatTransferSpeed(speed),
                ].join(' · '),
                textAlign: TextAlign.end,
                style: updateDialogBodyStyle(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ready(BuildContext context, String version) {
    final error = _installError;
    return UpdateDialogFrame(
      icon: Symbols.restart_alt_rounded,
      title: 'Ready to install Reelish $version',
      maxWidth: 480,
      actions: [
        UpdateDialogButton(label: 'Later', onPressed: _close),
        UpdateDialogButton(
          label: 'Restart and install',
          primary: true,
          autofocus: true,
          onPressed: _install,
        ),
      ],
      children: [
        Text(
          'The update was downloaded and verified. Reelish will close, '
          'install it and open again. Your settings, library, history and '
          'plugins are kept.',
          style: updateDialogBodyStyle(context),
        ),
        if (error != null) ...[
          const SizedBox(height: 14),
          Text(
            error,
            style: updateDialogBodyStyle(
              context,
            )?.copyWith(color: GlassTheme.coralBright),
          ),
        ],
      ],
    );
  }
}
