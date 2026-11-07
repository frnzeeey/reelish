// Chooses an app theme: a swatch per theme, each a small copy of the card it
// gives, plus Classic for the accent the user picked. Locked for accounts
// without the perk: the themes still show, and a tap explains. Works by touch,
// remote, mouse, keyboard and game controller (each swatch is a TvFocusable).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/device_capabilities.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import '../theme/reelish_icons.dart';
import '../theme/supporter_themes.dart';
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

  /// The accent Classic returns to, for its swatch; the current accent when
  /// null. Under a theme the current accent is the theme's, so the
  /// Appearance page passes the one the user picked.
  final AccentPalette? classicAccent;

  /// The theme in use, or null for Classic.
  final String? savedId;

  /// Called with a theme id, or [SupporterTheme.classicId].
  final ValueChanged<String> onSelect;

  /// For accounts without the perk: each theme shows with a lock and calls
  /// [onLocked] instead, and Classic is left out.
  final bool locked;
  final VoidCallback? onLocked;

  @override
  Widget build(BuildContext context) {
    final current = locked
        ? null
        : SupporterTheme.byId(savedId)?.id ?? SupporterTheme.classicId;
    // Even columns: all six in a row where they fit, else three, else two.
    const spacing = AppSpace.md;
    final narrowest = DeviceCapabilities.isTv
        ? 104.0
        : DeviceCapabilities.isDesktop
        ? 100.0
        : 84.0;
    // On a wide window the swatches stop growing and keep to the left.
    const widest = 168.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth;
        final columns = [6, 3, 2].firstWhere(
          (count) => (room - spacing * (count - 1)) / count >= narrowest,
          orElse: () => 2,
        );
        final width = math.min(
          widest,
          (room - spacing * (columns - 1)) / columns,
        );
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final theme in SupporterTheme.all)
              _Swatch(
                width: width,
                name: theme.name,
                theme: theme,
                selected: current == theme.id,
                locked: locked,
                onSelect: locked
                    ? () => onLocked?.call()
                    : () => onSelect(theme.id),
              ),
            if (!locked)
              _Swatch(
                width: width,
                name: 'Classic',
                theme: null,
                classicAccent: classicAccent,
                selected: current == SupporterTheme.classicId,
                onSelect: () => onSelect(SupporterTheme.classicId),
              ),
          ],
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.width,
    required this.name,
    required this.theme,
    required this.selected,
    required this.onSelect,
    this.locked = false,
    this.classicAccent,
  });

  final double width;
  final String name;
  final bool locked;
  final AccentPalette? classicAccent;

  /// Null for Classic: the usual card, in the app's accent.
  final SupporterTheme? theme;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = this.theme;
    final classic = classicAccent;
    final accent = classic?.primary ?? GlassTheme.primary;
    final ink = theme?.ink ?? classic?.bright ?? GlassTheme.coralBright;
    final duration = AppMotion.resolve(context, AppMotion.standard);
    final ringSize = width * .26;
    return TvFocusable(
      onSelect: onSelect,
      borderRadius: AppRadius.md,
      focusScale: 1.04,
      semanticLabel: locked
          ? '$name theme, for Reelish Supporters'
          : selected
          ? '$name theme, selected'
          : '$name theme',
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
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: selected ? ink : Colors.white.withValues(alpha: .1),
                  width: selected ? 2 : 1,
                ),
                boxShadow: [
                  if (selected && theme != null)
                    BoxShadow(
                      color: theme.glow.withValues(alpha: .3),
                      blurRadius: 16,
                    ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (theme != null)
                    SupporterThemeBackdrop(theme: theme)
                  else
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(-.8, -.85),
                          radius: 1.1,
                          colors: [
                            accent.withValues(alpha: .24),
                            const Color(0xFF17171E),
                            const Color(0xFF121218),
                          ],
                          stops: const [0, .5, 1],
                        ),
                      ),
                    ),
                  // A small avatar in the theme's frame.
                  Positioned(
                    left: AppSpace.sm,
                    top: AppSpace.sm,
                    child: SizedBox.square(
                      dimension: ringSize,
                      child: theme != null
                          ? SupporterAvatarRing(
                              theme: theme,
                              child: const _Face(),
                            )
                          : DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: accent.withValues(alpha: .7),
                                  width: 1.5,
                                ),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: _Face(),
                              ),
                            ),
                    ),
                  ),
                  if (locked)
                    const Positioned(
                      right: AppSpace.xs,
                      bottom: AppSpace.xs,
                      child: _Lock(),
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
                          color: ink,
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            ReelishIcons.check,
                            size: 14,
                            color: Color(0xFF101015),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? ink : GlassTheme.muted,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: DeviceCapabilities.isTv
                    ? AppTextSize.body
                    : AppTextSize.label,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain stand-in for the person's avatar inside a swatch.
class _Face extends StatelessWidget {
  const _Face();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white.withValues(alpha: .16),
    ),
    child: const SizedBox.expand(),
  );
}

/// The small lock on a theme someone cannot use yet, in the Supporter gold.
class _Lock extends StatelessWidget {
  const _Lock();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: GlassTheme.surface,
      border: Border.all(color: const Color(0x66F5B942)),
    ),
    child: const Icon(ReelishIcons.lock, size: 11, color: Color(0xFFFFD98A)),
  );
}
