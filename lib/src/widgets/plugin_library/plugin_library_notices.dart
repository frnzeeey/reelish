import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_theme.dart';

const _warning = Color(0xFFFFB547);

/// The quiet community/third-party notice shown with the catalog.
class PluginSafetyNotice extends StatelessWidget {
  const PluginSafetyNotice({super.key, this.attribution});

  /// Where the catalog comes from, e.g. "Catalog from the Community Plugin
  /// Library, curated by wolf knight."
  final String? attribution;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .03),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(
            Symbols.shield_rounded,
            size: 18,
            color: GlassTheme.muted,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Community plugins are third-party providers that Reelish does not '
            'make or maintain. They may change, become unavailable or stop '
            'working. Only install plugins from sources you trust.'
            '${attribution == null ? '' : '\n$attribution'}',
            style: const TextStyle(
              color: GlassTheme.muted,
              fontSize: 11,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Explains that an offline copy of the catalog is on screen.
class PluginOfflineBanner extends StatelessWidget {
  const PluginOfflineBanner({
    super.key,
    required this.message,
    required this.onRetry,
    this.retrying = false,
  });

  final String message;
  final VoidCallback onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: _warning.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _warning.withValues(alpha: .2)),
      ),
      child: Row(
        children: [
          const Icon(Symbols.cloud_off_rounded, size: 18, color: _warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: retrying ? null : onRetry,
            style: TextButton.styleFrom(
              foregroundColor: _warning,
              minimumSize: const Size(48, 44),
            ),
            child: Text(retrying ? 'Retrying…' : 'Retry'),
          ),
        ],
      ),
    ),
  );
}

/// A centered icon, title, message and optional primary and secondary
/// actions.
class PluginMessageState extends StatelessWidget {
  const PluginMessageState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.busy = false,
    this.secondaryLabel,
    this.secondaryIcon,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;
  final bool busy;
  final String? secondaryLabel;
  final IconData? secondaryIcon;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: GlassTheme.primary.withValues(alpha: .12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: GlassTheme.primary, size: 28),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: GlassTheme.muted,
            fontSize: 13,
            height: 1.45,
          ),
        ),
        if (actionLabel != null || secondaryLabel != null) ...[
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              if (actionLabel != null)
                FilledButton.icon(
                  onPressed: busy ? null : onAction,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(actionIcon ?? Symbols.refresh_rounded),
                  label: Text(actionLabel!),
                ),
              if (secondaryLabel != null)
                OutlinedButton.icon(
                  onPressed: onSecondary,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                  ),
                  icon: Icon(secondaryIcon ?? Symbols.add_link_rounded),
                  label: Text(secondaryLabel!),
                ),
            ],
          ),
        ],
      ],
    ),
  );
}

/// Points people at the manual installer when a provider is not listed.
class PluginManualInstallPrompt extends StatelessWidget {
  const PluginManualInstallPrompt({super.key, required this.onPaste});

  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .03),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: GlassTheme.border),
    ),
    child: Row(
      children: [
        const Icon(Symbols.add_link_rounded, size: 18, color: GlassTheme.muted),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            "Can't find a provider? Paste its manifest URL.",
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(
          onPressed: onPaste,
          style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
          child: const Text('Paste URL'),
        ),
      ],
    ),
  );
}
