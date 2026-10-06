import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_theme.dart';

/// Copies a manifest URL and briefly confirms it in place and in a snackbar.
class CopyManifestButton extends StatefulWidget {
  const CopyManifestButton({
    super.key,
    required this.manifestUrl,
    required this.pluginName,
    this.filled = false,
    this.compact = false,
  });

  final Uri? manifestUrl;
  final String pluginName;
  final bool filled;
  final bool compact;

  static Future<void> copy(BuildContext context, Uri url) async {
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Manifest URL copied'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  State<CopyManifestButton> createState() => _CopyManifestButtonState();
}

class _CopyManifestButtonState extends State<CopyManifestButton> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final url = widget.manifestUrl;
    if (url == null) return;
    await CopyManifestButton.copy(context, url);
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.manifestUrl != null;
    final icon = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: Icon(
        _copied ? Symbols.check_rounded : Symbols.content_copy_rounded,
        key: ValueKey(_copied),
        size: 18,
      ),
    );
    final label = Text(
      !available
          ? 'No manifest'
          : _copied
          ? 'Copied'
          : (widget.compact ? 'Copy' : 'Copy manifest'),
    );
    return Semantics(
      button: true,
      label: available
          ? 'Copy manifest URL for ${widget.pluginName}'
          : 'No manifest URL available for ${widget.pluginName}',
      excludeSemantics: true,
      child: widget.filled
          ? FilledButton.tonalIcon(
              onPressed: available ? _copy : null,
              icon: icon,
              label: label,
            )
          : OutlinedButton.icon(
              onPressed: available ? _copy : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: GlassTheme.textPrimary,
                side: const BorderSide(color: GlassTheme.border),
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              icon: icon,
              label: label,
            ),
    );
  }
}
