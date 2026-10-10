import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/glass_theme.dart';
import '../tv/tv_focus.dart';
import 'tmdb_attribution.dart';

/// Shared measurements for every settings page, so sub-screens line up.
abstract final class SettingsMetrics {
  static const horizontal = 18.0;
  static const sectionRadius = 20.0;
  static const sectionGap = 22.0;

  /// Space the floating navigation dock covers at the bottom of a tab.
  static const dockClearance = 112.0;
}

/// A settings page: header, sectioned content, and the TMDB footer.
///
/// The footer is the last item of the single scroll view. On short pages it
/// rests at the bottom of the viewport; on long pages it follows the final
/// section. With [onBack] null the page is a tab root and shows a large,
/// scrolling title instead of the pinned back header.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.icon,
    this.onBack,
    this.controller,
    this.footer = const TmdbAttributionFooter(),
    this.bottomClearance = 20,
    this.applyBottomInset = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onBack;
  final List<Widget> children;
  final ScrollController? controller;
  final Widget? footer;

  /// Extra space below the footer, e.g. [SettingsMetrics.dockClearance].
  final double bottomClearance;

  /// Off when something below the page, such as a bottom bar, already
  /// handles the system gesture inset.
  final bool applyBottomInset;

  bool get _isRoot => onBack == null;

  @override
  Widget build(BuildContext context) {
    final bottom =
        bottomClearance +
        (applyBottomInset ? MediaQuery.paddingOf(context).bottom : 0);
    // On TV, the D-pad scrolls text that has nothing to focus, such as the
    // legal documents that must be read to the end, and phone-width
    // settings stay readable: centered, not stretched.
    return TvKeyScroll(
      controller: controller,
      builder: (context, controller) {
        final scroll = _scrollView(controller, bottom);
        if (_isRoot) return TvReadableWidth(child: scroll);
        return TvReadableWidth(
          child: Column(
            children: [
              SettingsHeader(
                title: title,
                subtitle: subtitle,
                icon: icon,
                onBack: onBack!,
              ),
              Expanded(child: scroll),
            ],
          ),
        );
      },
    );
  }

  Widget _scrollView(ScrollController? controller, double bottom) =>
      CustomScrollView(
      controller: controller,
      slivers: [
        if (_isRoot)
          SliverToBoxAdapter(
            child: _RootTitle(title: title, subtitle: subtitle),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            SettingsMetrics.horizontal,
            _isRoot ? 0 : 6,
            SettingsMetrics.horizontal,
            0,
          ),
          sliver: SliverList.list(children: children),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                SettingsMetrics.horizontal,
                0,
                SettingsMetrics.horizontal,
                bottom,
              ),
              child: footer ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
}

/// [SettingsPage] in its own scaffold, for pages pushed as routes.
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.icon,
    this.controller,
    this.footer = const TmdbAttributionFooter(),
    this.bottomBar,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> children;
  final ScrollController? controller;
  final Widget? footer;
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlassTheme.background,
    bottomNavigationBar: bottomBar,
    body: SettingsPage(
      title: title,
      subtitle: subtitle,
      icon: icon,
      controller: controller,
      footer: footer,
      applyBottomInset: bottomBar == null,
      onBack: () => Navigator.of(context).maybePop(),
      children: children,
    ),
  );
}

class _RootTitle extends StatelessWidget {
  const _RootTitle({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      SettingsMetrics.horizontal + 2,
      30,
      SettingsMetrics.horizontal + 2,
      24,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -.8,
            ),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: GlassTheme.muted,
              height: 1.4,
            ),
          ),
        ],
      ],
    ),
  );
}

/// Pinned header with a back button, used by every settings sub-screen.
class SettingsHeader extends StatelessWidget {
  const SettingsHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 16, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Symbols.arrow_back_rounded),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.3,
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: GlassTheme.muted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (icon != null) ...[
            const SizedBox(width: 10),
            SettingsIconBadge(icon: icon!, size: 40),
          ],
        ],
      ),
    ),
  );
}

/// The tinted rounded square behind a settings icon.
class SettingsIconBadge extends StatelessWidget {
  const SettingsIconBadge({super.key, required this.icon, this.size = 36});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: GlassTheme.primary.withValues(alpha: .13),
      borderRadius: BorderRadius.circular(size * .32),
      border: Border.all(color: GlassTheme.primary.withValues(alpha: .16)),
    ),
    child: Icon(icon, color: GlassTheme.primary, size: size * .52),
  );
}

/// A labeled group of settings rows on one shared glass surface.
///
/// One lightweight painted surface per section, no backdrop blur, so long
/// settings pages scroll without per-row compositing.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    this.label,
    this.description,
    required this.children,
  });

  final String? label;
  final String? description;
  final List<Widget> children;

  static const _surface = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF1A1A22), Color(0xFF14141B)],
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: SettingsMetrics.sectionGap),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) SettingsSectionHeader(label: label!),
        if (description != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              description!,
              style: const TextStyle(
                color: GlassTheme.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SettingsMetrics.sectionRadius),
            side: const BorderSide(color: GlassTheme.border),
          ),
          child: Ink(
            decoration: const BoxDecoration(gradient: _surface),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < children.length; index++) ...[
                  if (index > 0) const SettingsDivider(),
                  children[index],
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 0, 6, 9),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: const TextStyle(
          color: GlassTheme.muted,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    ),
  );
}

class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(
    height: 1,
    thickness: 1,
    indent: 16,
    endIndent: 16,
    color: GlassTheme.border,
  );
}

/// One settings row: optional icon, title, description and a current value,
/// with a trailing control or a chevron when it opens something.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.description,
    this.value,
    this.icon,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.showChevron,
    this.mergeSemantics = true,
  });

  final String title;
  final String? description;
  final String? value;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  /// Defaults to shown when the row is tappable and has no [trailing].
  final bool? showChevron;

  /// Off when [trailing] holds more than one action, so each stays
  /// separately reachable by screen readers.
  final bool mergeSemantics;

  @override
  Widget build(BuildContext context) {
    final chevron = showChevron ?? (onTap != null && trailing == null);
    final tile = AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1 : .45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                if (icon != null) ...[
                  SettingsIconBadge(icon: icon!),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.1,
                        ),
                      ),
                      if (description != null && description!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          description!,
                          style: const TextStyle(
                            color: GlassTheme.muted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                      if (value != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          value!,
                          style: TextStyle(
                            color: onTap != null
                                ? GlassTheme.coralBright
                                : Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 10),
                  trailing!,
                ] else if (chevron) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    Symbols.chevron_right_rounded,
                    color: GlassTheme.muted,
                    size: 22,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return mergeSemantics ? MergeSemantics(child: tile) : tile;
  }
}

/// Readable body copy inside a [SettingsSection], such as legal text.
class SettingsParagraph extends StatelessWidget {
  const SettingsParagraph({super.key, this.title, required this.text});

  final String? title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(
            title!,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -.1,
            ),
          ),
          const SizedBox(height: 7),
        ],
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: .78),
            fontSize: 13,
            height: 1.6,
          ),
        ),
      ],
    ),
  );
}

/// A row with a switch; tapping anywhere on the row toggles it.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.description,
    this.icon,
    this.enabled = true,
  });

  final String title;
  final String? description;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SettingsTile(
    title: title,
    description: description,
    icon: icon,
    enabled: enabled,
    onTap: () => onChanged(!value),
    trailing: Switch.adaptive(
      value: value,
      onChanged: enabled ? onChanged : null,
    ),
  );
}

/// A row with a labeled slider below its description.
class SettingsSliderTile extends StatelessWidget {
  const SettingsSliderTile({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final String title;
  final String description;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.1,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: GlassTheme.primary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                valueLabel,
                style: TextStyle(
                  color: GlassTheme.coralBright,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          description,
          style: const TextStyle(
            color: GlassTheme.muted,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        TvSliderNavigation(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );
}
