import 'package:flutter/material.dart';
import 'package:feather_icon_font/feather_icon_font.dart';

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
    (FeatherIcons.home, FeatherIcons.home, 'Home'),
    (FeatherIcons.grid, FeatherIcons.grid, 'Plugins'),
    (FeatherIcons.bookmark, FeatherIcons.bookmark, 'Library'),
    (FeatherIcons.settings, FeatherIcons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(22, 6, 22, 10),
    child: LiquidGlass(
      quality: LiquidGlassQuality.balanced,
      blurSigma: 9,
      opacity: .82,
      borderRadius: 26,
      showBorder: false,
      showTopHighlight: false,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SizedBox(
        height: 72,
        child: Row(
          children: [
            for (var i = 0; i < _destinations.length; i++)
              Expanded(
                child: _DockItem(
                  icon: _destinations[i].$1,
                  selectedIcon: _destinations[i].$2,
                  label: _destinations[i].$3,
                  selected: selectedIndex == i,
                  onTap: () => onSelected(i),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
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
                gradient: selected
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          GlassTheme.primary.withValues(alpha: .22),
                          GlassTheme.primary.withValues(alpha: .09),
                          Colors.white.withValues(alpha: .025),
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
                      size: 22,
                      color: selected ? GlassTheme.primary : Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 3),
                  AnimatedDefaultTextStyle(
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                      fontSize: 10,
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
                                color: GlassTheme.primary.withValues(alpha: .6),
                                blurRadius: 7,
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
