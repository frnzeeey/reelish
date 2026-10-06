import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/plugin_catalog.dart';
import '../../theme/glass_theme.dart';

/// Featured / verified / installed markers. Featured and verified only show
/// when the catalog itself sets them.
class PluginStatusBadges extends StatelessWidget {
  const PluginStatusBadges({
    super.key,
    required this.plugin,
    this.installed = false,
  });

  final ReelishPlugin plugin;
  final bool installed;

  @override
  Widget build(BuildContext context) {
    final badges = [
      if (installed)
        _Badge(
          icon: Symbols.check_circle_rounded,
          label: 'Installed',
          color: GlassTheme.primary,
        ),
      if (plugin.verified)
        const _Badge(
          icon: Symbols.verified_rounded,
          label: 'Verified',
          color: Color(0xFF4DA3FF),
        ),
      if (plugin.featured)
        const _Badge(
          icon: Symbols.star_rounded,
          label: 'Featured',
          color: Color(0xFFFFB547),
        ),
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: badges,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color, fill: 1),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

/// A small icon + label pill for provider metadata.
class PluginMetaPill extends StatelessWidget {
  const PluginMetaPill({
    super.key,
    required this.icon,
    required this.label,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? GlassTheme.primary : Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: accent
            ? GlassTheme.primary.withValues(alpha: .1)
            : Colors.white.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
