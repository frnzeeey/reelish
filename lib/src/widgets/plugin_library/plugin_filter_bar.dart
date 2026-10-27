import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../platform/device_capabilities.dart';
import '../../services/plugin_library_query.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../category_chip.dart';

/// Availability, content-type chips, and the language and sort menus.
/// Options come from [PluginLibraryFacets], so only filters with results
/// are offered. Wide layouts keep everything on one line; narrow ones put
/// availability first and scroll the rest.
class PluginFilterBar extends StatelessWidget {
  const PluginFilterBar({
    super.key,
    required this.query,
    required this.facets,
    required this.onChanged,
    this.availability = PluginAvailability.all,
    this.installedCount = 0,
    this.onAvailabilityChanged,
  });

  final PluginLibraryQuery query;
  final PluginLibraryFacets facets;
  final ValueChanged<PluginLibraryQuery> onChanged;
  final PluginAvailability availability;
  final int installedCount;

  /// Null hides the availability chips.
  final ValueChanged<PluginAvailability>? onAvailabilityChanged;

  @override
  Widget build(BuildContext context) {
    final status = [
      if (onAvailabilityChanged case final onStatus?)
        for (final option in PluginAvailability.values)
          CategoryChip(
            label: option == PluginAvailability.installed
                ? '${option.label} · $installedCount'
                : option.label,
            selected: availability == option,
            onTap: () => onStatus(option),
          ),
    ];
    final types = [
      if (facets.contentTypes.isNotEmpty)
        CategoryChip(
          label: 'All types',
          selected: query.contentType == null,
          onTap: () => onChanged(query.copyWith(contentType: () => null)),
        ),
      for (final type in facets.contentTypes)
        CategoryChip(
          label: type.label,
          selected: query.contentType == type,
          onTap: () => onChanged(
            query.copyWith(
              contentType: () => query.contentType == type ? null : type,
            ),
          ),
        ),
    ];
    final menus = [
      if (facets.languages.isNotEmpty)
        _LanguageMenu(
          language: query.language,
          languages: facets.languages,
          onSelected: (language) =>
              onChanged(query.copyWith(language: () => language)),
        ),
      const SizedBox(width: AppSpace.xs),
      _SortMenu(
        sort: query.sort,
        onSelected: (sort) => onChanged(query.copyWith(sort: sort)),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 760) {
          // The chips scroll and the menus stay put, so no width or text
          // size can push the row past its edge.
          return Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ...status,
                      if (status.isNotEmpty && types.isNotEmpty)
                        const _Separator(),
                      ...types,
                    ],
                  ),
                ),
              ),
              ...menus,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (status.isNotEmpty) ...[
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: status,
                ),
              ),
              const SizedBox(height: AppSpace.xxs),
            ],
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: AppSpace.md),
                // Menus first, so a narrow screen never hides them behind
                // the chips.
                children: [
                  ...menus,
                  const SizedBox(width: AppSpace.xs),
                  if (types.isNotEmpty) const _Separator(),
                  ...types,
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 22,
    margin: const EdgeInsets.only(right: AppSpace.xs, left: AppSpace.xxs),
    color: GlassTheme.border,
  );
}

/// A pill that opens a menu: 40 px drawn, inside a 48 dp hit area on touch
/// and TV so it is as easy to reach as the chips beside it.
class _MenuPill extends StatelessWidget {
  const _MenuPill({
    required this.icon,
    required this.label,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: DeviceCapabilities.isDesktop ? 40 : 48,
    child: Center(
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
        decoration: BoxDecoration(
          color: active
              ? GlassTheme.primary.withValues(alpha: .14)
              : GlassTheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: active
                ? GlassTheme.primary.withValues(alpha: .5)
                : GlassTheme.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: AppIcon.sm,
              color: active ? GlassTheme.coralBright : GlassTheme.muted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? GlassTheme.coralBright : Colors.white,
                fontSize: AppTextSize.label,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Symbols.arrow_drop_down_rounded,
              size: AppIcon.sm,
              color: GlassTheme.muted,
            ),
          ],
        ),
      ),
    ),
  );
}

PopupMenuItem<T> _menuItem<T>(T value, String label, {required bool checked}) =>
    PopupMenuItem(
      value: value,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: checked
                ? Icon(
                    Symbols.check_rounded,
                    size: AppIcon.sm,
                    color: GlassTheme.primary,
                  )
                : null,
          ),
          Text(label),
        ],
      ),
    );

class _LanguageMenu extends StatelessWidget {
  const _LanguageMenu({
    required this.language,
    required this.languages,
    required this.onSelected,
  });

  final String? language;
  final List<String> languages;
  final ValueChanged<String?> onSelected;

  // A menu cannot return null for "every language", so it uses a marker.
  static const _all = '\u0000all';

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: language == null
        ? 'Filter by language'
        : 'Language: $language. Change the language filter',
    initialValue: language ?? _all,
    onSelected: (value) => onSelected(value == _all ? null : value),
    color: GlassTheme.elevatedSurface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.lg),
    ),
    constraints: const BoxConstraints(maxHeight: 420, minWidth: 200),
    itemBuilder: (context) => [
      _menuItem(_all, 'All languages', checked: language == null),
      for (final option in languages)
        _menuItem(option, option, checked: option == language),
    ],
    child: _MenuPill(
      icon: Symbols.translate_rounded,
      label: language ?? 'Language',
      active: language != null,
    ),
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
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.lg),
    ),
    itemBuilder: (context) => [
      for (final option in PluginSort.values)
        _menuItem(option, option.label, checked: option == sort),
    ],
    child: _MenuPill(icon: Symbols.swap_vert_rounded, label: sort.label),
  );
}
