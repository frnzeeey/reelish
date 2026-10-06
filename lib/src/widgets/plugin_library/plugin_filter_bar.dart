import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/plugin_library_query.dart';
import '../../theme/glass_theme.dart';
import '../category_chip.dart';

/// Language and content-type chips plus the sort menu. Options come from
/// [PluginLibraryFacets], so only filters with results are offered.
class PluginFilterBar extends StatelessWidget {
  const PluginFilterBar({
    super.key,
    required this.query,
    required this.facets,
    required this.onChanged,
  });

  final PluginLibraryQuery query;
  final PluginLibraryFacets facets;
  final ValueChanged<PluginLibraryQuery> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            CategoryChip(
              label: 'All languages',
              selected: query.language == null,
              onTap: () => onChanged(query.copyWith(language: () => null)),
            ),
            for (final language in facets.languages)
              CategoryChip(
                label: language,
                selected: query.language == language,
                onTap: () => onChanged(
                  query.copyWith(
                    language: () =>
                        query.language == language ? null : language,
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  if (facets.contentTypes.isNotEmpty)
                    CategoryChip(
                      label: 'All types',
                      selected: query.contentType == null,
                      onTap: () =>
                          onChanged(query.copyWith(contentType: () => null)),
                    ),
                  for (final type in facets.contentTypes)
                    CategoryChip(
                      label: type.label,
                      selected: query.contentType == type,
                      onTap: () => onChanged(
                        query.copyWith(
                          contentType: () =>
                              query.contentType == type ? null : type,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          _SortMenu(
            sort: query.sort,
            onSelected: (sort) => onChanged(query.copyWith(sort: sort)),
          ),
        ],
      ),
    ],
  );
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onSelected});

  final PluginSort sort;
  final ValueChanged<PluginSort> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<PluginSort>(
    tooltip: 'Sort plugins, currently ${sort.label}',
    initialValue: sort,
    onSelected: onSelected,
    color: GlassTheme.elevatedSurface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    itemBuilder: (context) => [
      for (final option in PluginSort.values)
        PopupMenuItem(
          value: option,
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: option == sort
                    ? Icon(
                        Symbols.check_rounded,
                        size: 18,
                        color: GlassTheme.primary,
                      )
                    : null,
              ),
              Text(option.label),
            ],
          ),
        ),
    ],
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: GlassTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Symbols.swap_vert_rounded,
            size: 18,
            color: GlassTheme.muted,
          ),
          const SizedBox(width: 6),
          Text(
            sort.label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );
}
