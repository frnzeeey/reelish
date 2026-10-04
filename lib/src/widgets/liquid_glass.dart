import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';

enum LiquidGlassQuality { low, balanced, high }

/// A bounded, reusable glass surface.
///
/// [low] uses only painted gradients and edge highlights. The other qualities
/// add one clipped backdrop blur, capped to keep the affected area predictable.
/// Gradients and highlights provide depth without a distortion shader.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.quality = LiquidGlassQuality.balanced,
    this.blurSigma = 10,
    this.opacity = .72,
    this.borderRadius = 20,
    this.padding = EdgeInsets.zero,
    this.tintColor = const Color(0xFF111722),
    this.accentColor,
    this.showShadow = true,
    this.showBorder = true,
    this.showTopHighlight = true,
    this.groupBackdrop = false,
  }) : assert(blurSigma >= 0),
       assert(opacity >= 0 && opacity <= 1);

  final Widget child;
  final LiquidGlassQuality quality;
  final double blurSigma;
  final double opacity;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color tintColor;
  final Color? accentColor;
  final bool showShadow;
  final bool showBorder;
  final bool showTopHighlight;

  /// Shares one backdrop capture with other grouped glass under the nearest
  /// [BackdropGroup]. Only for surfaces that never overlap each other, such
  /// as the panels on cards in one row; without a group it has no effect.
  final bool groupBackdrop;

  double get _effectiveBlur => switch (quality) {
    LiquidGlassQuality.low => 0,
    LiquidGlassQuality.balanced => blurSigma.clamp(0.0, 12.0).toDouble(),
    LiquidGlassQuality.high => blurSigma.clamp(0.0, 20.0).toDouble(),
  };

  @override
  Widget build(BuildContext context) {
    final blur = _effectiveBlur;
    final radius = BorderRadius.circular(borderRadius);
    final accent = accentColor ?? GlassTheme.primary;
    final shadow = BoxDecoration(
      borderRadius: radius,
      boxShadow: showShadow
          ? [
              BoxShadow(
                color: Colors.black.withValues(alpha: .24 * opacity),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ]
          : null,
    );

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: .17 * opacity),
            accent.withValues(alpha: .055 * opacity),
            tintColor.withValues(alpha: .68 * opacity),
          ],
          stops: const [0, .38, 1],
        ),
        borderRadius: radius,
        border: showBorder
            ? Border.all(color: Colors.white.withValues(alpha: .22 * opacity))
            : null,
      ),
      child: Padding(
        padding: padding,
        child: Stack(
          children: [
            child,
            if (showTopHighlight)
              Positioned(
                top: 0,
                left: 12,
                right: 12,
                height: 1,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0),
                          Colors.white.withValues(alpha: .48 * opacity),
                          Colors.white.withValues(alpha: .08 * opacity),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final filter = ImageFilter.blur(
      sigmaX: blur,
      sigmaY: blur,
      tileMode: TileMode.clamp,
    );
    return DecoratedBox(
      decoration: shadow,
      child: ClipRRect(
        borderRadius: radius,
        child: blur == 0
            ? surface
            : groupBackdrop
            ? BackdropFilter.grouped(filter: filter, child: surface)
            : BackdropFilter(filter: filter, child: surface),
      ),
    );
  }
}
