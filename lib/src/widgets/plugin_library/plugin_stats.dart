import 'package:flutter/material.dart';

import '../../services/plugin_library_query.dart';
import '../../theme/glass_theme.dart';

/// Provider, source and language totals computed from the catalog.
class PluginStats extends StatelessWidget {
  const PluginStats({super.key, required this.stats});

  final PluginLibraryStats stats;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [GlassTheme.primary.withValues(alpha: .16), GlassTheme.surface],
      ),
      border: Border.all(color: GlassTheme.primary.withValues(alpha: .16)),
    ),
    child: IntrinsicHeight(
      child: Row(
        children: [
          _Stat(value: stats.providerCount, label: 'Providers'),
          const _Divider(),
          _Stat(value: stats.sourceCount, label: 'Sources'),
          const _Divider(),
          _Stat(value: stats.languageCount, label: 'Languages'),
        ],
      ),
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      label: '$value $label',
      excludeSemantics: true,
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(end: value.toDouble()),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (context, animated, _) => Text(
              '${animated.round()}',
              style: TextStyle(
                color: GlassTheme.coralBright,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -.6,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: GlassTheme.muted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    margin: const EdgeInsets.symmetric(vertical: 4),
    color: GlassTheme.border,
  );
}
