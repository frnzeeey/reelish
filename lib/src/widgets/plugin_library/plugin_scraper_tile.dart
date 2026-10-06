import 'package:flutter/material.dart';

import '../../models/plugin_catalog.dart';
import '../../services/plugin_library_query.dart';
import '../../theme/glass_theme.dart';
import 'plugin_logo.dart';

/// One source in a provider's details, as its manifest describes it.
class PluginScraperTile extends StatelessWidget {
  const PluginScraperTile({super.key, required this.scraper});

  final PluginScraper scraper;

  @override
  Widget build(BuildContext context) {
    final types = [
      for (final type in PluginContentType.values)
        if (scraper.contentTypes.contains(type.name)) type.label,
    ];
    final languages = {
      for (final code in scraper.contentLanguages) PluginLanguages.label(code),
    }.toList();
    final tags = [
      ...types,
      ...languages,
      ...scraper.formats.map((f) => f.toUpperCase()),
    ];
    return Semantics(
      container: true,
      label: [
        scraper.name,
        if (scraper.description != null) scraper.description!,
        if (types.isNotEmpty) types.join(', '),
        if (languages.isNotEmpty) 'Languages: ${languages.join(', ')}',
      ].join('. '),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: GlassTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: GlassTheme.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PluginLogo(
              name: scraper.name,
              url: scraper.logoUrl,
              size: 38,
              radius: 11,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    scraper.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (scraper.description case final description?) ...[
                    const SizedBox(height: 3),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        for (final tag in tags)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .05),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
