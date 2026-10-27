import 'package:flutter/material.dart';

import '../../services/plugin_library_query.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import 'plugin_formatting.dart';

/// Provider, source and language totals computed from the catalog, and
/// when it was updated, as one quiet line under the library's title.
class PluginStats extends StatelessWidget {
  const PluginStats({super.key, required this.stats, this.updatedAt});

  final PluginLibraryStats stats;
  final DateTime? updatedAt;

  static String _count(int value, String one, String many) =>
      '$value ${value == 1 ? one : many}';

  @override
  Widget build(BuildContext context) {
    final parts = [
      _count(stats.providerCount, 'provider', 'providers'),
      _count(stats.sourceCount, 'source', 'sources'),
      _count(stats.languageCount, 'language', 'languages'),
    ];
    final updated = updatedAt == null
        ? null
        : 'Updated ${formatPluginDate(updatedAt!)}';
    return Semantics(
      label: [...parts, ?updated].join(', '),
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            for (final (index, part) in parts.indexed) ...[
              if (index > 0) const TextSpan(text: '  ·  '),
              TextSpan(
                text: part.split(' ').first,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextSpan(text: ' ${part.split(' ').last}'),
            ],
            if (updated != null) TextSpan(text: '  ·  $updated'),
          ],
        ),
        style: const TextStyle(
          color: GlassTheme.muted,
          fontSize: AppTextSize.bodySmall,
          fontFeatures: [FontFeature.tabularFigures()],
          height: 1.5,
        ),
      ),
    );
  }
}
