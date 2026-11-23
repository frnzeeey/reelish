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

/// The share dialog, top to bottom: a header (title, the one line about
/// what the link does, close), the code as the centrepiece, one line on
/// scanning, the link as a field, the secondary actions as one row of
/// quiet tiles, and the one primary action full width. Feedback (copied,
/// saved, failed) shows inside the dialog, where the eye already is.
class _ShareDialogState extends State<_ShareDialog> {
  /// The action running now ('card', 'save', 'text'); others wait.
  String? _running;
  bool _copied = false;
  Timer? _copiedTimer;

  /// A short result under the actions, and whether it is a failure.
  String? _status;
  bool _failed = false;
  Timer? _statusTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _statusTimer?.cancel();
    super.dispose();
  }

  void _say(String message, {bool failed = false}) {
    _statusTimer?.cancel();
    setState(() {
      _status = message;
      _failed = failed;
    });
    _statusTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _status = null);
    });
  }

  Future<void> _run(String name, Future<void> Function() action) async {
    if (_running != null) return;
    setState(() => _running = name);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  Future<void> _copy() async {
    await ShareService.copy(widget.link.toString());
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _shareText() => _run('text', () async {
    final shared = await ShareService.shareText(
      ShareService.message(widget.target, widget.link),
    );
    if (!shared && mounted) {
      _say('Couldn’t open sharing. Copy the link instead.', failed: true);
    }
  });

  Future<void> _shareCard() => _run('card', () async {
    final shared = await ShareService.shareCard(widget.target, widget.link);
    if (!shared && mounted) {
      _say('Couldn’t share the image. Try Save image instead.', failed: true);
    }
  });

  Future<void> _save() => _run('save', () async {
    final where = await ShareService.saveCard(widget.target, widget.link);
    if (!mounted) return;
    if (where == null) {
      _say('Couldn’t save the image.', failed: true);
    } else {
      _say('Saved to ${where.endsWith('.png') ? 'Pictures\\Reelish' : where}');
    }
  });

  @override
  Widget build(BuildContext context) {
    final tv = DeviceCapabilities.isTv;
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(tv ? 480.0 : 400.0, screen.width - AppSpace.md * 2);
    const pad = AppSpace.lg;
    // The centrepiece, sized to the room it has: most of the dialog's width,
    // never so tall the actions leave the screen; larger on TV, for a sofa.
    final code = math
        .min(
          math.min(width - pad * 2 - 24, tv ? 320.0 : 248.0),
          screen.height * (tv ? .42 : .34),
        )
        .clamp(150.0, 320.0);
    final display = widget.link.toString().replaceFirst(
      RegExp(r'^https://'),
      '',
    );
    final share = ShareService.canShare;
    return Dialog(
      backgroundColor: GlassTheme.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.lg,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        side: BorderSide(color: GlassTheme.border),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(pad, pad, pad, pad),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(tv),
              const SizedBox(height: AppSpace.lg),
              Center(child: _code(code)),
              const SizedBox(height: AppSpace.sm),
              Text(
                tv
                    ? 'Point a phone’s camera at the code to open it there.'
                    : 'Scan with a phone camera to open it.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.bodySmall,
                ),
              ),
              const SizedBox(height: AppSpace.md),
              _linkField(display, copyable: !tv && share),
              if (!tv) ...[
                const SizedBox(height: AppSpace.sm),
                _secondaryActions(share),
              ],
              if (_status case final status?) ...[
                const SizedBox(height: AppSpace.sm),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _failed ? GlassTheme.danger : GlassTheme.muted,
                    fontSize: AppTextSize.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.md),
              _primary(tv, share),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(bool tv) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: TextStyle(
                color: GlassTheme.textPrimary,
                fontSize: AppTextSize.titleLarge,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
            if (widget.note case final note?) ...[
              const SizedBox(height: AppSpace.xxs),
              Text(
                note,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.bodySmall,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
      // On TV, Close is the focused button at the foot instead.
      if (!tv) ...[
        const SizedBox(width: AppSpace.xs),
        IconButton(
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.pop(context),
          icon: Icon(ReelishIcons.close, color: GlassTheme.muted),
        ),
      ],
    ],
  );

  /// The code in its cream frame, lifted a little off the dialog.
  Widget _code(double size) => DecoratedBox(
    decoration: BoxDecoration(
      color: ReelishQrColors.paper,
      borderRadius: BorderRadius.circular(AppRadius.xl + 4),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .28),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xs),
      child: ReelishQrCode(
        link: widget.link.toString(),
        size: size,
        semanticLabel: 'QR code for ${widget.title}',
      ),
    ),
  );

  /// The link, readable in full where it fits. Where the share sheet is
  /// the primary action, tapping it copies; elsewhere Copy link is the
  /// primary action and this only shows the link.
  Widget _linkField(String display, {required bool copyable}) {
    // The whole link, wrapping to a second line if it must: the code at
    // its end is what tells one invitation from another, so it is never
    // the part cut off, and it stands out in the accent.
    final slash = display.lastIndexOf('/');
    final Widget text = _copied
        ? Text(
            'Link copied',
            style: TextStyle(
              color: GlassTheme.primary,
              fontSize: AppTextSize.bodySmall,
              fontWeight: FontWeight.w600,
            ),
          )
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(text: display.substring(0, slash + 1)),
                TextSpan(
                  text: display.substring(slash + 1),
                  style: TextStyle(
                    color: GlassTheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: AppTextSize.bodySmall,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          );
    final field = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: EdgeInsets.only(
        left: AppSpace.md,
        right: copyable ? AppSpace.xs : AppSpace.md,
        top: AppSpace.xs,
        bottom: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: GlassTheme.elevatedSurface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: GlassTheme.border),
      ),
      child: Row(
        children: [
          Icon(ReelishIcons.link, size: 18, color: GlassTheme.muted),
          const SizedBox(width: AppSpace.xs),
          Expanded(child: text),
          if (copyable)
            Padding(
              padding: const EdgeInsets.all(AppSpace.xs),
              child: Icon(
                _copied ? ReelishIcons.check : ReelishIcons.copy,
                size: 18,
                color: _copied ? GlassTheme.primary : GlassTheme.muted,
              ),
            ),
        ],
      ),
    );
    if (!copyable) return Semantics(label: display, child: field);
    return Semantics(
      button: true,
      label: _copied ? 'Link copied' : 'Copy link $display',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => unawaited(_copy()),
          child: field,
        ),
      ),
    );
  }

  /// Share image, Save image and Full screen: one row of equal, quiet
  /// tiles, so none competes with the primary action.
  Widget _secondaryActions(bool share) {
    final tiles = <Widget>[
      if (share)
        _ActionTile(
          icon: ReelishIcons.addPhoto,
          label: 'Share image',
          busy: _running == 'card',
          onTap: _running == null ? () => unawaited(_shareCard()) : null,
        ),
      if (widget.canSave)
        _ActionTile(
          icon: ReelishIcons.download,
          label: 'Save image',
          busy: _running == 'save',
          onTap: _running == null ? () => unawaited(_save()) : null,
        ),
      _ActionTile(
        icon: ReelishIcons.fullscreen,
        label: 'Full screen',
        onTap: () => unawaited(
          ShareSheet.fullScreen(context, widget.link, title: widget.title),
        ),
      ),
    ];
    return Row(
      children: [
        for (final (index, tile) in tiles.indexed) ...[
          if (index > 0) const SizedBox(width: AppSpace.xs),
          Expanded(child: tile),
        ],
      ],
    );
  }

  /// The one filled button: Share link where there is a share sheet, Copy
  /// link where there is not (Windows), Close on TV (the remote's way out).
  Widget _primary(bool tv, bool share) {
    // Full width; the shape and finish stay the theme's (its glass is
    // drawn for its own pill shape).
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
    );
    if (tv) {
      return FilledButton(
        autofocus: true,
        style: style,
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      );
    }
    if (share) {
      return FilledButton.icon(
        style: style,
        onPressed: _running == null ? () => unawaited(_shareText()) : null,
        icon: _running == 'text'
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(ReelishIcons.share),
        label: const Text('Share link'),
      );
    }
    return FilledButton.icon(
      style: style,
      onPressed: () => unawaited(_copy()),
      icon: Icon(_copied ? ReelishIcons.check : ReelishIcons.copy),
      label: Text(_copied ? 'Link copied' : 'Copy link'),
    );
  }
}

/// A secondary action: an icon over a short label, on a quiet surface.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled
        ? GlassTheme.textPrimary
        : GlassTheme.textPrimary.withValues(alpha: .4);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: GlassTheme.elevatedSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: GlassTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.xxs,
                vertical: AppSpace.sm,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: busy
                        ? CircularProgressIndicator(
                            strokeWidth: 2,
                            color: GlassTheme.primary,
                          )
                        : Icon(icon, size: 20, color: color),
                  ),
                  const SizedBox(height: AppSpace.xxs + 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontSize: AppTextSize.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
