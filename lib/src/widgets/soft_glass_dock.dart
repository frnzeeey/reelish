import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/glass_theme.dart';
import 'liquid_glass.dart';

class SoftGlassDock extends StatelessWidget {
  const SoftGlassDock({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _destinations = [
    (Symbols.home_rounded, Symbols.home_rounded, 'Home'),
    (Symbols.grid_view_rounded, Symbols.grid_view_rounded, 'Plugins'),
    (Symbols.bookmark_rounded, Symbols.bookmark_rounded, 'Library'),
    (Symbols.settings_rounded, Symbols.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final metrics = DockMetrics.forSize(size);
    final dock = LiquidGlass(
      quality: LiquidGlassQuality.balanced,
      blurSigma: 9,
      opacity: .82,
      borderRadius: metrics.radius,
      elevation: 1.2,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.innerPadding,
        vertical: 6,
      ),
      child: SizedBox(
        height: metrics.height,
        child: Row(
          children: [
            for (var i = 0; i < _destinations.length; i++)
              Expanded(
                child: _DockItem(
                  icon: _destinations[i].$1,
                  selectedIcon: _destinations[i].$2,
                  label: _destinations[i].$3,
                  selected: selectedIndex == i,
                  iconSize: metrics.iconSize,
                  labelSize: metrics.labelSize,
                  onTap: () => onSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
    final width = metrics.width;
    return SafeArea(
      top: false,
      minimum: metrics.margin,
      child: width == null
          ? dock
          : Center(
              heightFactor: 1,
              child: SizedBox(width: width, child: dock),
            ),
    );
  }
}

/// Dock proportions for the device class. Phones keep the original
/// full-width dock; tablets (shortest side of at least 600 dp, in either
/// orientation) get a compact, centered dock that never stretches across
/// the screen.
@immutable
class DockMetrics {
  const DockMetrics._({
    required this.width,
    required this.height,
    required this.iconSize,
    required this.labelSize,
    required this.radius,
    required this.innerPadding,
    required this.margin,
  });

  static const tabletBreakpoint = 600.0;
  static const minTabletWidth = 380.0;
  static const maxTabletWidth = 440.0;

  static const phone = DockMetrics._(
    width: null,
    height: 72,
    iconSize: 22,
    labelSize: 10,
    radius: 26,
    innerPadding: 8,
    margin: EdgeInsets.fromLTRB(22, 6, 22, 10),
  );

  factory DockMetrics.forSize(Size size) {
    if (size.shortestSide < tabletBreakpoint) return phone;
    return DockMetrics._(
      // Half the screen, kept between 380 and 440 dp: 400 dp on an 800 dp
      // portrait tablet, 440 dp on anything wider.
      width: (size.width * .5).clamp(minTabletWidth, maxTabletWidth),
      height: 64,
      iconSize: 24,
      labelSize: 11,
      radius: 24,
      innerPadding: 10,
      margin: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    );
  }

  /// Fixed dock width, or null to fill the space between [margin]s.
  final double? width;

  /// Height of the item row, inside the glass's 6 dp vertical padding.
  final double height;
  final double iconSize;
  final double labelSize;
  final double radius;
  final double innerPadding;

  /// Minimum space around the dock; the system inset wins when larger.
  final EdgeInsets margin;
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.iconSize,
    required this.labelSize,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final double iconSize;
  final double labelSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              decoration: BoxDecoration(
                // Coral light pooled in the active tab, brightest at the top
                // where the dock catches the light.
                gradient: selected
                    ? LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          GlassTheme.primary.withValues(alpha: .24),
                          GlassTheme.primary.withValues(alpha: .10),
                          GlassTheme.primary.withValues(alpha: .05),
                        ],
                      )
                    : null,
                borderRadius: BorderRadius.circular(18),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: GlassTheme.primary.withValues(alpha: .12),
                          blurRadius: 14,
                          spreadRadius: -5,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedScale(
                    scale: selected ? 1.08 : 1,
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      selected ? selectedIcon : icon,
                      size: iconSize,
                      color: selected ? GlassTheme.primary : Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 3),
                  AnimatedDefaultTextStyle(
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                      fontSize: labelSize,
                      height: 1,
                      color: selected ? GlassTheme.primary : GlassTheme.muted,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                    child: Text(label),
                  ),
                  const SizedBox(height: 5),
                  AnimatedContainer(
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    width: selected ? 12 : 3,
                    height: 3,
                    decoration: BoxDecoration(
                      color: selected
                          ? GlassTheme.primary
                          : Colors.white.withValues(alpha: .16),
                      borderRadius: BorderRadius.circular(3),
                      boxShadow: selected
                          ? [
                              BoxShadow(
                                color: GlassTheme.primary.withValues(alpha: .4),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
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
