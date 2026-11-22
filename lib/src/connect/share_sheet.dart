// Reelish Connect's one sharing surface: the QR code and the link for any
// ShareTarget, with what this device can do with them (copy the link,
// share it or its card, save the card, show the code full screen). Title
// pages, watch parties and the Connect page all open it.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import 'reelish_qr.dart';
import 'share_service.dart';
import 'share_target.dart';

abstract final class ShareSheet {
  /// Opens the share dialog for [target] under [title]. Says so, instead,
  /// when this build has no Reelish API to make links on.
  static Future<void> show(
    BuildContext context,
    ShareTarget target, {
    required String title,
    String? note,
    @visibleForTesting Uri? base,
  }) async {
    final link = ShareService.link(target, base: base);
    if (link == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Sharing isn’t available in this build.')),
      );
      return;
    }
    final canSave = await ShareService.canSave();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ShareDialog(
        target: target,
        link: link,
        title: title,
        note: note,
        canSave: canSave,
      ),
    );
  }

  /// [link]'s code alone, as large as the screen allows: for someone across
  /// the room or the table to scan.
  static Future<void> fullScreen(
    BuildContext context,
    Uri link, {
    required String title,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _FullScreenCode(link: link, title: title),
    ),
  );
}

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({
    required this.target,
    required this.link,
    required this.title,
    required this.canSave,
    this.note,
  });

  final ShareTarget target;
  final Uri link;
  final String title;
  final String? note;
  final bool canSave;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  bool _busy = false;

  void _say(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    await ShareService.copy(widget.link.toString());
    _say('Link copied');
  }

  Future<void> _shareText() => _run(() async {
    final shared = await ShareService.shareText(
      ShareService.message(widget.target, widget.link),
    );
    if (!shared) _say('Couldn’t open sharing. Copy the link instead.');
  });

  Future<void> _shareCard() => _run(() async {
    final shared = await ShareService.shareCard(widget.target, widget.link);
    if (!shared) _say('Couldn’t share the image. Try Save image instead.');
  });

  Future<void> _save() => _run(() async {
    final where = await ShareService.saveCard(widget.target, widget.link);
    _say(
      where == null
          ? 'Couldn’t save the image.'
          : 'Saved to ${where.endsWith('.png') ? 'Pictures\\Reelish' : where}',
    );
  });

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final screen = MediaQuery.sizeOf(context);
    // Big enough to scan from a sofa on TV; never more than fits.
    final code = math
        .min(tv ? 360.0 : 260.0, math.min(screen.width, screen.height) * .5)
        .clamp(160.0, 360.0);
    final display = widget.link.toString().replaceFirst(
      RegExp(r'^https://'),
      '',
    );
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: tv ? 460 : 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReelishQrCode(
                link: widget.link.toString(),
                size: code,
                semanticLabel: 'QR code for ${widget.title}',
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                tv
                    ? 'Point a phone’s camera at the code to open it there.'
                    : 'Scan with a phone camera, or share the link.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GlassTheme.muted),
              ),
              if (widget.note case final note?) ...[
                const SizedBox(height: AppSpace.xs),
                Text(
                  note,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GlassTheme.muted,
                    fontSize: AppTextSize.bodySmall,
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.sm),
              SelectableText(
                display,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: AppTextSize.bodySmall,
                ),
              ),
              if (!tv) ...[
                const SizedBox(height: AppSpace.md),
                Wrap(
                  spacing: AppSpace.xs,
                  runSpacing: AppSpace.xs,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => unawaited(_copy()),
                      icon: const Icon(ReelishIcons.copy),
                      label: const Text('Copy link'),
                    ),
                    if (ShareService.canShare)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => unawaited(_shareCard()),
                        icon: const Icon(ReelishIcons.addPhoto),
                        label: const Text('Share image'),
                      ),
                    if (widget.canSave)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => unawaited(_save()),
                        icon: const Icon(ReelishIcons.download),
                        label: const Text('Save image'),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(
                        ShareSheet.fullScreen(
                          context,
                          widget.link,
                          title: widget.title,
                        ),
                      ),
                      icon: const Icon(ReelishIcons.fullscreen),
                      label: const Text('Full screen'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          autofocus: tv,
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (ShareService.canShare)
          FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_shareText()),
            icon: const Icon(ReelishIcons.share),
            label: const Text('Share link'),
          ),
      ],
    );
  }
}

class _FullScreenCode extends StatelessWidget {
  const _FullScreenCode({required this.link, required this.title});

  final Uri link;
  final String title;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final size = math.min(screen.width, screen.height - 200) * .82;
    return Scaffold(
      // The code's own cream, edge to edge: nothing near it to confuse a
      // camera.
      backgroundColor: ReelishQrColors.paper,
      appBar: AppBar(
        backgroundColor: ReelishQrColors.paper,
        foregroundColor: ReelishQrColors.ink,
        elevation: 0,
        title: Text(title, style: const TextStyle(color: ReelishQrColors.ink)),
        leading: IconButton(
          autofocus: true,
          tooltip: 'Close',
          icon: const Icon(ReelishIcons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: ReelishQrCode(
          link: link.toString(),
          size: math.max(160, size),
          semanticLabel: 'QR code for $title',
        ),
      ),
    );
  }
}
