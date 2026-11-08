// Chooses an app theme. Each theme is a card drawn from its own colours (a
// small page: backdrop, a card, the accent), and choosing one opens a preview
// built from real components in that theme before it applies. Classic, the
// look without a theme, applies directly. Accounts without the perk can
// preview every theme; applying one explains the perk instead. Works by
// touch, remote, mouse, keyboard and game controller (each card is a
// TvFocusable; the preview's actions are ordinary buttons).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../theme/supporter_themes.dart';
import '../theme/theme_tokens.dart';
import 'tv/tv_focus.dart';

class SupporterThemePicker extends StatelessWidget {
  const SupporterThemePicker({
    super.key,
    required this.savedId,
    required this.onSelect,
    this.locked = false,
    this.onLocked,
    this.classicAccent,
  });

  /// The accent Classic returns to, for its card; the current accent when
  /// null. Under a theme the current accent is the theme's, so the
  /// Appearance page passes the one the user picked.
  final AccentPalette? classicAccent;

  /// The theme in use, or null for Classic.
  final String? savedId;

  /// Called with a theme id once its preview is confirmed, or with
  /// [SupporterTheme.classicId].
  final ValueChanged<String> onSelect;

  /// For accounts without the perk: themes open their preview with a way to
  /// learn about the perk ([onLocked]) instead of applying.
  final bool locked;
  final VoidCallback? onLocked;

  @override
  Widget build(BuildContext context) {
    final current =
        SupporterTheme.byId(savedId)?.id ?? SupporterTheme.classicId;
    const spacing = AppSpace.md;
    final narrowest = DeviceCapabilities.isTv
        ? 220.0
        : DeviceCapabilities.isDesktop
        ? 200.0
        : 150.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth;
        final columns = [4, 3, 2].firstWhere(
          (count) => (room - spacing * (count - 1)) / count >= narrowest,
          orElse: () => 2,
        );
        final width = math.min(
          280.0,
          (room - spacing * (columns - 1)) / columns,
        );
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            _ThemeCard(
              width: width,
              name: 'Classic',
              description: 'Your accent on Reelish black',
              surfaces: ThemeSurfaces.classic,
              accent: classicAccent ?? GlassTheme.accent,
              selected: current == SupporterTheme.classicId,
              onSelect: () => onSelect(SupporterTheme.classicId),
            ),
            for (final theme in SupporterTheme.all)
              _ThemeCard(
                width: width,
                name: theme.name,
                description: theme.description,
                surfaces: theme.surfaces,
                accent: theme.accent,
                theme: theme,
                selected: !locked && current == theme.id,
                locked: locked,
                onSelect: () => _preview(context, theme, current),
              ),
          ],
        );
      },
    );
  }

  Future<void> _preview(
    BuildContext context,
    SupporterTheme theme,
    String current,
  ) async {
    final result = await showThemePreview(
      context,
      theme: theme,
      locked: locked,
      inUse: current == theme.id,
    );
    if (!context.mounted) return;
    switch (result) {
      case ThemePreviewResult.apply:
        onSelect(theme.id);
      case ThemePreviewResult.learnMore:
        onLocked?.call();
      case null:
        break;
    }
  }
}

/// What the person chose in a theme preview.
enum ThemePreviewResult { apply, learnMore }

/// Shows [theme] in real components, in its own Material theme, and returns
/// what the person chose (null when they closed it).
Future<ThemePreviewResult?> showThemePreview(
  BuildContext context, {
  required SupporterTheme theme,
  required bool locked,
  bool inUse = false,
}) {
  final data = DeviceCapabilities.isTv
      ? GlassTheme.buildTv(theme.accent, theme.surfaces)
      : GlassTheme.build(theme.accent, theme.surfaces);
  return showDialog<ThemePreviewResult>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .6),
    builder: (context) => Theme(
      data: data,
      child: ThemePreview(theme: theme, locked: locked, inUse: inUse),
    ),
  );
}

/// The preview dialog: the theme's name and story, a small Reelish screen in
/// the theme, and the way to apply it (or, without the perk, to learn
/// about it).
class ThemePreview extends StatelessWidget {
  const ThemePreview({
    super.key,
    required this.theme,
    required this.locked,
    this.inUse = false,
  });

  final SupporterTheme theme;
  final bool locked;
  final bool inUse;

  @override
  Widget build(BuildContext context) {
    final s = theme.surfaces;
    final tv = DeviceCapabilities.isTv;
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: tv ? 640 : 520),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: s.textPrimary),
          child: IconTheme.merge(
            data: IconThemeData(color: s.textPrimary),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          theme.name,
                          style: TextStyle(
                            fontSize: tv ? 26 : 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const _SupportersBadge(),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xxs),
                  Text(
                    theme.description,
                    style: TextStyle(
                      color: s.textSecondary,
                      fontSize: tv ? AppTextSize.body : AppTextSize.bodySmall,
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  // Shown, not used: the remote and keyboard skip it.
                  ExcludeFocus(
                    child: IgnorePointer(
                      child: ExcludeSemantics(child: _PreviewScreen(theme)),
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  if (locked)
                    Text(
                      'Themes are a thank-you to Reelish Supporters.',
                      style: TextStyle(
                        color: s.textSecondary,
                        fontSize: AppTextSize.bodySmall,
                      ),
                    ),
                  if (locked) const SizedBox(height: AppSpace.sm),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.sm,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      if (locked)
                        FilledButton(
                          autofocus: true,
                          onPressed: () => Navigator.pop(
                            context,
                            ThemePreviewResult.learnMore,
                          ),
                          child: const Text('Learn more'),
                        )
                      else
                        FilledButton.icon(
                          autofocus: true,
                          onPressed: inUse
                              ? null
                              : () => Navigator.pop(
                                  context,
                                  ThemePreviewResult.apply,
                                ),
                          icon: Icon(
                            inUse ? ReelishIcons.check : ReelishIcons.palette,
                            size: 18,
                          ),
                          label: Text(inUse ? 'In use' : 'Apply theme'),
                        ),
                    ],
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

/// A small Reelish screen in [theme]: the dock, search, chips, posters with
/// progress, the primary and secondary buttons, and a floating surface.
/// Real Material components in the theme's own ThemeData.
class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen(this.theme);

  final SupporterTheme theme;

  @override
  Widget build(BuildContext context) {
    final s = theme.surfaces;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: s.background,
          gradient: _ambient(theme.glow, s.background),
          border: Border.all(color: s.border),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _Mark(color: theme.primary),
                  const SizedBox(width: AppSpace.xs),
                  const Text(
                    'Reelish',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  SizedBox.square(
                    dimension: 30,
                    child: SupporterAvatarRing(
                      theme: theme,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.primary,
                        ),
                        child: Center(
                          child: Text(
                            'R',
                            style: TextStyle(
                              color: s.background,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              const TextField(
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(ReelishIcons.search, size: 18),
                  hintText: 'Search movies and series',
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.xs,
                children: [
                  for (final (label, on) in const [
                    ('Trending', true),
                    ('Movies', false),
                    ('Series', false),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: on,
                      onSelected: (_) {},
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                'Continue watching',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: AppTextSize.bodySmall,
                  color: s.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, title) in const [
                    'Night Harbor',
                    'Silver Line',
                    'Low Tide',
                  ].indexed) ...[
                    if (i > 0) const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: _Poster(index: i, title: title, s: s),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpace.md),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {},
                      icon: const Icon(ReelishIcons.play, size: 18),
                      label: const Text('Play'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(ReelishIcons.info, size: 18),
                      label: const Text('Details'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              _FloatingSurface(s: s),
              const SizedBox(height: AppSpace.sm),
              NavigationBar(
                height: 56,
                selectedIndex: 0,
                labelBehavior:
                    NavigationDestinationLabelBehavior.onlyShowSelected,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(ReelishIcons.home),
                    label: 'Home',
                  ),
                  NavigationDestination(
                    icon: Icon(ReelishIcons.search),
                    label: 'Search',
                  ),
                  NavigationDestination(
                    icon: Icon(ReelishIcons.bookmark),
                    label: 'My list',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.index, required this.title, required this.s});

  final int index;
  final String title;
  final ThemeSurfaces s;

  /// Stand-in artwork: the same three films in every theme, so the theme,
  /// not the art, is what changes between previews.
  static const _art = [
    [Color(0xFF2B3A67), Color(0xFF0F1626)],
    [Color(0xFF6B4E3D), Color(0xFF1E1410)],
    [Color(0xFF2F5D50), Color(0xFF0E1C18)],
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AspectRatio(
        aspectRatio: 2 / 3,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: s.border),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _art[index % _art.length],
            ),
          ),
        ),
      ),
      if (index == 0) ...[
        const SizedBox(height: 4),
        const ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(2)),
          child: LinearProgressIndicator(value: .62, minHeight: 3),
        ),
      ],
      const SizedBox(height: 4),
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: s.textSecondary, fontSize: 11),
      ),
    ],
  );
}

/// A dialog-like surface, as confirmations and sheets draw in the theme.
class _FloatingSurface extends StatelessWidget {
  const _FloatingSurface({required this.s});

  final ThemeSurfaces s;

  @override
  Widget build(BuildContext context) => Material(
    color: s.raised,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      side: BorderSide(color: s.border),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.sm,
        AppSpace.xs,
        AppSpace.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Remove from history?',
            style: TextStyle(color: s.textPrimary, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            'Your progress for this title will be cleared.',
            style: TextStyle(color: s.textSecondary, fontSize: 12),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () {}, child: const Text('Remove')),
          ),
        ],
      ),
    ),
  );
}

/// The theme's soft light from the upper left, over its page.
LinearGradient _ambient(Color light, Color page) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color.alphaBlend(light.withValues(alpha: .14), page), page, page],
  stops: const [0, .55, 1],
);

class _Mark extends StatelessWidget {
  const _Mark({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// One card in the collection: a small page in the theme's own colours.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.width,
    required this.name,
    required this.description,
    required this.surfaces,
    required this.accent,
    required this.selected,
    required this.onSelect,
    this.theme,
    this.locked = false,
  });

  final double width;
  final String name;
  final String description;
  final ThemeSurfaces surfaces;
  final AccentPalette accent;

  /// Null for Classic.
  final SupporterTheme? theme;
  final bool selected;
  final bool locked;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final s = surfaces;
    final duration = AppMotion.resolve(context, AppMotion.standard);
    final tv = DeviceCapabilities.isTv;
    return TvFocusable(
      onSelect: onSelect,
      borderRadius: AppRadius.lg,
      focusScale: 1.03,
      semanticLabel: [
        '$name theme',
        description,
        if (selected) 'selected',
        if (locked) 'for Reelish Supporters, opens a preview',
      ].join(', '),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: duration,
              curve: AppMotion.enter,
              height: width * .62,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: s.background,
                gradient: _ambient(theme?.glow ?? accent.primary, s.background),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(
                  color: selected
                      ? accent.primary
                      : GlassTheme.textPrimary.withValues(alpha: .12),
                  width: selected ? 2 : 1,
                ),
                boxShadow: [
                  if (selected)
                    BoxShadow(
                      color: accent.primary.withValues(alpha: .28),
                      blurRadius: 18,
                    ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _MiniPage(s: s, accent: accent),
                  if (theme != null)
                    const Positioned(
                      right: AppSpace.xs,
                      bottom: AppSpace.xs,
                      child: _SupportersBadge(compact: true),
                    ),
                  Positioned(
                    right: AppSpace.xs,
                    top: AppSpace.xs,
                    child: AnimatedScale(
                      scale: selected ? 1 : 0,
                      duration: duration,
                      curve: AppMotion.enter,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: accent.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            ReelishIcons.check,
                            size: 14,
                            color: s.background,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Inset from the card's rounded corners, which the focus
            // highlight shares.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xxs,
                AppSpace.xs,
                AppSpace.xxs,
                AppSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? GlassTheme.textPrimary
                          : GlassTheme.muted,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      fontSize: tv ? AppTextSize.body : AppTextSize.label,
                    ),
                  ),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GlassTheme.muted,
                      fontSize: tv ? AppTextSize.label : AppTextSize.caption,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card's page: a poster row, a surface card with text, and the accent
/// button, all in the theme's own colours.
class _MiniPage extends StatelessWidget {
  const _MiniPage({required this.s, required this.accent});

  final ThemeSurfaces s;
  final AccentPalette accent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpace.sm),
    child: LayoutBuilder(
      builder: (context, box) {
        final line = box.maxHeight * .07;
        Widget bar(double width, Color color) => Container(
          width: width,
          height: line,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(line),
          ),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A poster.
            AspectRatio(
              aspectRatio: 2 / 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        accent.primary.withValues(alpha: .35),
                        s.raised,
                      ),
                      s.surface,
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: box.maxWidth * .06),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  bar(box.maxWidth * .4, s.textPrimary),
                  SizedBox(height: line * .9),
                  bar(box.maxWidth * .3, s.textSecondary),
                  SizedBox(height: line * 1.6),
                  // The primary button.
                  Container(
                    width: box.maxWidth * .3,
                    height: line * 2.6,
                    decoration: BoxDecoration(
                      color: accent.primary,
                      borderRadius: BorderRadius.circular(line * 2),
                    ),
                  ),
                  SizedBox(height: line * 1.2),
                  // A surface card.
                  Container(
                    width: box.maxWidth * .44,
                    height: line * 2.6,
                    decoration: BoxDecoration(
                      color: s.surface,
                      border: Border.all(color: s.border),
                      borderRadius: BorderRadius.circular(line),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// The Supporters mark: a small gold capsule, never a prompt.
class _SupportersBadge extends StatelessWidget {
  const _SupportersBadge({this.compact = false});

  final bool compact;

  static const _gold = Color(0xFFFFD98A);

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 5 : AppSpace.xs,
      vertical: compact ? 2 : 3,
    ),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      border: Border.all(color: const Color(0x66F5B942)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(ReelishIcons.star, size: compact ? 9 : 12, color: _gold),
        if (!compact) ...[
          const SizedBox(width: 4),
          const Text(
            'Supporters',
            style: TextStyle(
              color: _gold,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    ),
  );
}
