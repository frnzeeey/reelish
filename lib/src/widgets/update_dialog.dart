import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:feather_icon_font/feather_icon_font.dart';
import 'package:flutter/material.dart';

import '../models/app_update.dart';
import '../services/github_update_service.dart';
import '../theme/glass_theme.dart';

/// Turns GitHub release Markdown (including `--generate-notes` output) into
/// plain text. Returns an empty string when nothing meaningful remains.
String formatReleaseNotes(String markdown) {
  final skipped = RegExp(
    r"^(what's changed|new contributors)$|^full changelog|made their first contribution"
    // Build provenance the release workflow adds for verification; useful
    // on GitHub, noise in the app.
    r'|^(version|commit|apk sha-256|built by):',
    caseSensitive: false,
  );
  final lines = <String>[];
  for (var line in const LineSplitter().convert(markdown)) {
    line = line
        .trim()
        .replaceFirst(RegExp(r'^#+\s*'), '')
        .replaceFirst(RegExp(r'^[-*+]\s+'), '• ')
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\([^)]*\)'),
          (match) => match[1]!,
        )
        .replaceAll(RegExp(r'\*\*|__|`|<!--.*?-->'), '')
        // Generated notes end each item with "by @user in <pull request url>".
        .replaceFirst(RegExp(r'\s+by @\S+ in https://\S+$'), '')
        .trim();
    if (skipped.hasMatch(line.replaceFirst('• ', ''))) continue;
    if (line.isEmpty && (lines.isEmpty || lines.last.isEmpty)) continue;
    lines.add(line);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

/// Card-style dialog frame matching Reelish's surfaces.
class _UpdateDialogFrame extends StatelessWidget {
  const _UpdateDialogFrame({
    required this.icon,
    required this.title,
    required this.children,
    required this.actions,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: GlassTheme.surface,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(26),
      side: const BorderSide(color: GlassTheme.border),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: GlassTheme.primary.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: GlassTheme.primary, size: 22),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -.4,
              ),
            ),
            const SizedBox(height: 8),
            ...children,
            const SizedBox(height: 20),
            Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
    );
    const textStyle = TextStyle(fontWeight: FontWeight.w700);
    const size = Size.fromHeight(48);
    return primary
        ? FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              minimumSize: size,
              shape: shape,
              textStyle: textStyle,
            ),
            child: Text(label),
          )
        : TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              minimumSize: size,
              shape: shape,
              textStyle: textStyle,
              foregroundColor: GlassTheme.textPrimary,
              backgroundColor: GlassTheme.glassStrong,
            ),
            child: Text(label),
          );
  }
}

TextStyle? _bodyStyle(BuildContext context) => Theme.of(
  context,
).textTheme.bodyMedium?.copyWith(color: GlassTheme.muted, height: 1.5);

/// Offers a newer release. Pops `true` when the user chooses to update.
class UpdateAvailableDialog extends StatelessWidget {
  const UpdateAvailableDialog({super.key, required this.update});

  final AppUpdate update;

  @override
  Widget build(BuildContext context) {
    final notes = formatReleaseNotes(update.releaseNotes);
    return _UpdateDialogFrame(
      icon: FeatherIcons.downloadCloud,
      title: 'New Reelish update available',
      actions: [
        _DialogButton(
          label: 'Later',
          onPressed: () => Navigator.pop(context, false),
        ),
        _DialogButton(
          label: 'Update now',
          primary: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
      children: [
        Text(
          'Version ${update.latestVersion} is now available. '
          "You're currently using version ${update.currentVersion}.",
          style: _bodyStyle(context),
        ),
        if (update.sizeBytes != null) ...[
          const SizedBox(height: 6),
          Text(
            'Download size: ${_megabytes(update.sizeBytes!)} MB',
            style: _bodyStyle(context)?.copyWith(fontSize: 12.5),
          ),
        ],
        if (notes.isNotEmpty) ...[
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
              maxHeight: MediaQuery.sizeOf(context).height * .3,
            ),
            decoration: BoxDecoration(
              color: GlassTheme.glassBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: GlassTheme.border),
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    notes,
                    style: _bodyStyle(context)?.copyWith(
                      color: GlassTheme.textPrimary.withValues(alpha: .86),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Downloads the update with progress, cancel and retry. Pops the verified
/// APK file, or null when the user cancels or closes after a failure.
class UpdateDownloadDialog extends StatefulWidget {
  const UpdateDownloadDialog({super.key, required this.update, this.download});

  final AppUpdate update;

  /// Replaces [GitHubUpdateService.downloadApk], for tests.
  final Future<File> Function(
    void Function(int received, int? total) onProgress,
    UpdateDownloadCancellation cancellation,
  )?
  download;

  @override
  State<UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<UpdateDownloadDialog> {
  UpdateDownloadCancellation? _cancellation;
  int _received = 0;
  int? _total;
  String? _error;
  int _lastPercent = -1;
  DateTime _lastPaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  void _start() {
    final cancellation = UpdateDownloadCancellation();
    _cancellation = cancellation;
    _error = null;
    _received = 0;
    _total = widget.update.sizeBytes;
    _lastPercent = -1;
    unawaited(_run(cancellation));
  }

  Future<void> _run(UpdateDownloadCancellation cancellation) async {
    try {
      final download =
          widget.download ??
          (onProgress, cancellation) => GitHubUpdateService.downloadApk(
            widget.update,
            onProgress: onProgress,
            cancellation: cancellation,
          );
      final file = await download(_onProgress, cancellation);
      _cancellation = null;
      if (mounted) Navigator.pop(context, file);
    } on UpdateDownloadCancelled {
      // The dialog was already closed by the user.
    } catch (error) {
      _cancellation = null;
      if (!mounted || cancellation.isCancelled) return;
      setState(() {
        _error = error is UpdateException
            ? error.message
            : 'The download failed. Try again.';
      });
    }
  }

  void _onProgress(int received, int? total) {
    if (!mounted) return;
    // Repaint at most once per percent or every 150 ms, not on every chunk.
    final percent = total != null && total > 0 ? received * 100 ~/ total : -1;
    final now = DateTime.now();
    if (percent == _lastPercent &&
        now.difference(_lastPaint) < const Duration(milliseconds: 150)) {
      return;
    }
    _lastPercent = percent;
    _lastPaint = now;
    setState(() {
      _received = received;
      _total = total;
    });
  }

  void _close() {
    _cancellation?.cancel();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final total = _total;
    final progress = total != null && total > 0
        ? (_received / total).clamp(0.0, 1.0)
        : null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: error != null
          ? _UpdateDialogFrame(
              icon: FeatherIcons.alertCircle,
              title: 'Download failed',
              actions: [
                _DialogButton(label: 'Close', onPressed: _close),
                _DialogButton(
                  label: 'Retry',
                  primary: true,
                  onPressed: () => setState(_start),
                ),
              ],
              children: [Text(error, style: _bodyStyle(context))],
            )
          : _UpdateDialogFrame(
              icon: FeatherIcons.download,
              title: 'Downloading Reelish ${widget.update.latestVersion}',
              actions: [_DialogButton(label: 'Cancel', onPressed: _close)],
              children: [
                Text(
                  'Keep Reelish open until the download finishes.',
                  style: _bodyStyle(context),
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: GlassTheme.glassStrong,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      progress == null
                          ? 'Downloading…'
                          : '${(progress * 100).floor()}%',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      total != null && total > 0
                          ? '${_megabytes(_received)} MB / ${_megabytes(total)} MB'
                          : '${_megabytes(_received)} MB',
                      style: _bodyStyle(context),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// Explains Android's "Install unknown apps" permission. Pops `true` when the
/// user chooses to open the settings page.
class InstallPermissionDialog extends StatelessWidget {
  const InstallPermissionDialog({super.key});

  @override
  Widget build(BuildContext context) => _UpdateDialogFrame(
    icon: FeatherIcons.shield,
    title: 'Allow Reelish to install updates',
    actions: [
      _DialogButton(
        label: 'Not now',
        onPressed: () => Navigator.pop(context, false),
      ),
      _DialogButton(
        label: 'Open settings',
        primary: true,
        onPressed: () => Navigator.pop(context, true),
      ),
    ],
    children: [
      Text(
        'Android requires permission for Reelish to install downloaded '
        'updates.\n\nTurn on "Allow from this source" for Reelish, then '
        'return to Reelish to continue.',
        style: _bodyStyle(context),
      ),
    ],
  );
}

/// A single-button message about an update problem.
class UpdateNoticeDialog extends StatelessWidget {
  const UpdateNoticeDialog({
    super.key,
    required this.title,
    required this.message,
    this.icon = FeatherIcons.alertCircle,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => _UpdateDialogFrame(
    icon: icon,
    title: title,
    actions: [
      _DialogButton(
        label: 'OK',
        primary: true,
        onPressed: () => Navigator.pop(context),
      ),
    ],
    children: [Text(message, style: _bodyStyle(context))],
  );
}
