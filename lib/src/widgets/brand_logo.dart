// Reelish's brand images: their asset paths, and the wordmark and mark drawn
// without their canvases' transparent margins.
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../platform/app_icon.dart';
import '../theme/glass_theme.dart';
import '../theme/supporter_themes.dart';

/// Reelish's brand images, in one place. Each is an 846 × 846 PNG in
/// `assets/icons/`; the platform icons, the Android splash and TV banner,
/// and the Windows icon are generated from them by
/// `tool/branding/generate_brand_assets.ps1`.
abstract final class BrandAssets {
  /// The app icon: the emblem on a warm charcoal tile.
  static const appIcon = 'assets/icons/reelish_emblem_icon.png';

  /// The emblem over the wordmark, on transparency: the splash logo.
  static const primaryLogo = 'assets/icons/reelish_primary_logo.png';

  /// The emblem alone, on transparency: the logo since v1.39.
  static const logoIcon = 'assets/icons/reelish_app_emblem.png';

  /// The wordmark alone ("REEL" white, "ISH" terracotta), on transparency.
  static const wordLogo = 'assets/icons/reelish_wordmark.png';

  /// The emblem in white with its soft shadows, on transparency: the mark on
  /// colour tiles (the icon presets, custom accent tiles).
  static const whiteEmblem = 'assets/icons/reelish_emblem_white.png';
  static const whiteEmblemBounds = Rect.fromLTRB(.212, .260, .790, .749);

  /// Where the artwork sits inside its square canvas, as fractions of the
  /// canvas, measured from the images' alpha (soft shadows included) by
  /// tool/branding/generate_emblem_sources.ps1. Update these if the images
  /// are redrawn.
  static const logoIconBounds = Rect.fromLTRB(.080, .150, .920, .862);
  static const wordLogoBounds = Rect.fromLTRB(.219, .468, .783, .531);
  static const primaryLogoBounds = Rect.fromLTRB(.206, .208, .793, .785);
}

/// The app icon for the look in effect: under a theme, the theme's own icon
/// (the emblem for Living Room, a Signature icon for a supporter theme, the
/// Sovereign Crest for Sovereign Edition); for a built-in accent, the App
/// icon preset of that colour; for a custom colour, the white emblem on a
/// tile of that colour, as the colour presets are drawn.
/// Read out as "Reelish".
class AccentAppIcon extends StatelessWidget {
  const AccentAppIcon({super.key, required this.size, this.radius = 13});

  final double size;
  final double radius;

  /// The icon artwork for [accentId], or null for a custom colour.
  static String? assetFor(String accentId) {
    const themePrefix = 'theme:';
    if (accentId.startsWith(themePrefix)) {
      final theme = SupporterTheme.byId(accentId.substring(themePrefix.length));
      if (theme == null || theme.collection == ThemeCollection.reelish) {
        return BrandAssets.appIcon;
      }
      if (theme.collection == ThemeCollection.founder) {
        return AppIconPreset.byId('sovereign_crest').preview;
      }
      // Each supporter theme has its Signature icon, named after it.
      for (final preset in AppIconPreset.all) {
        if (preset.label == theme.name) return preset.preview;
      }
      return BrandAssets.appIcon;
    }
    for (final preset in AppIconPreset.all) {
      if (preset.id == accentId) return preset.preview;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final accent = GlassTheme.accent;
    final asset = assetFor(accent.id);
    return Semantics(
      label: 'Reelish',
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox.square(
          dimension: size,
          child: asset != null
              ? Image.asset(
                  asset,
                  fit: BoxFit.cover,
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                      .ceil(),
                  excludeFromSemantics: true,
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [accent.bright, accent.dark],
                    ),
                  ),
                  child: Center(
                    child: ExcludeSemantics(
                      child: _BrandArtwork(
                        asset: BrandAssets.whiteEmblem,
                        bounds: BrandAssets.whiteEmblemBounds,
                        height: size * .42,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The Reelish wordmark at [height], without its canvas's transparent
/// margins. Read out as "Reelish".
class ReelishWordmark extends StatelessWidget {
  const ReelishWordmark({super.key, required this.height, this.lifted = false});

  final double height;

  /// Whether a soft shadow in the letters' shape sits under it, so it stands
  /// off bright artwork instead of lying flat on it.
  final bool lifted;

  /// Takes 84% of the green channel from every channel: white becomes a
  /// near-black ink, and the brand coral a deep crimson.
  static const _onLight = ColorFilter.matrix(<double>[
    1, -.84, 0, 0, 0, //
    0, .16, 0, 0, 0, //
    0, -.84, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    Widget artwork = _BrandArtwork(
      asset: BrandAssets.wordLogo,
      bounds: BrandAssets.wordLogoBounds,
      height: height,
    );
    // On a light theme's pages the white letters turn to dark ink and the
    // coral deepens to crimson, so the wordmark keeps its two tones. A
    // shadow is for lifting it off artwork, never needed on a light page.
    if (GlassTheme.surfaces.brightness == Brightness.light) {
      return ColorFiltered(colorFilter: _onLight, child: artwork);
    }
    if (!lifted) return artwork;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The same image, darkened and blurred, a little below.
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(0, height * .1),
            child: ExcludeSemantics(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: height * .16,
                  sigmaY: height * .16,
                ),
                child: ColorFiltered(
                  colorFilter: const ColorFilter.mode(
                    Color(0x99000000),
                    BlendMode.srcIn,
                  ),
                  child: artwork,
                ),
              ),
            ),
          ),
        ),
        artwork,
      ],
    );
  }
}

/// The primary logo (the mark over the wordmark) at [height], without its
/// canvas's transparent margins. Read out as "Reelish".
class ReelishPrimaryLogo extends StatelessWidget {
  const ReelishPrimaryLogo({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => _BrandArtwork(
    asset: BrandAssets.primaryLogo,
    bounds: BrandAssets.primaryLogoBounds,
    height: height,
  );
}

/// The Reelish mark at [height], without its canvas's transparent margins.
/// Read out as "Reelish".
class ReelishMark extends StatelessWidget {
  const ReelishMark({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => _BrandArtwork(
    asset: BrandAssets.logoIcon,
    bounds: BrandAssets.logoIconBounds,
    height: height,
  );
}

/// Shows the [bounds] part of a square brand image at [height], keeping its
/// proportions. The whole canvas is laid out at its own size, whatever the
/// parent's constraints, and clipped to the artwork, so the file needs no
/// trimmed copy.
class _BrandArtwork extends StatelessWidget {
  const _BrandArtwork({
    required this.asset,
    required this.bounds,
    required this.height,
  });

  final String asset;
  final Rect bounds;
  final double height;

  @override
  Widget build(BuildContext context) {
    final canvas = height / bounds.height;
    // Where the canvas sits so that [bounds] fills the box: an alignment
    // places a larger child at (box − child) × (a + 1) / 2.
    double align(double start, double extent) =>
        extent >= 1 ? 0 : 2 * start / (1 - extent) - 1;
    return Semantics(
      label: 'Reelish',
      image: true,
      child: SizedBox(
        width: canvas * bounds.width,
        height: height,
        child: ClipRect(
          child: OverflowBox(
            minWidth: canvas,
            maxWidth: canvas,
            minHeight: canvas,
            maxHeight: canvas,
            alignment: Alignment(
              align(bounds.left, bounds.width),
              align(bounds.top, bounds.height),
            ),
            child: Image.asset(
              asset,
              width: canvas,
              height: canvas,
              // Decoded once, at the size drawn.
              cacheWidth: (canvas * MediaQuery.devicePixelRatioOf(context))
                  .ceil(),
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
            ),
          ),
        ),
      ),
    );
  }
}
