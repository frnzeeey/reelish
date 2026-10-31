// Reelish's brand images: their asset paths, and the wordmark and mark drawn
// without their canvases' transparent margins.
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../platform/app_icon.dart';
import '../theme/glass_theme.dart';

/// Reelish's brand images, in one place. Each is an 846 × 846 PNG in
/// `assets/icons/`; the platform icons, the Android splash and TV banner,
/// and the Windows icon are generated from them by
/// `tool/branding/generate_brand_assets.ps1`.
abstract final class BrandAssets {
  /// The app icon: the white mark on the coral tile.
  static const appIcon = 'assets/icons/reelish_icon.png';

  /// The mark over the wordmark, white, on transparency: the splash logo.
  static const primaryLogo = 'assets/icons/Primary_logo.png';

  /// The mark alone, white, on transparency.
  static const logoIcon = 'assets/icons/logo_icon.png';

  /// The wordmark alone ("REEL" white, "ISH" coral), on transparency.
  static const wordLogo = 'assets/icons/word_logo.png';

  /// Where the artwork sits inside its square canvas, as fractions of the
  /// canvas, measured from the images' alpha with a little room for their
  /// soft shadows. Update these if the images are redrawn.
  static const logoIconBounds = Rect.fromLTRB(.194, .281, .809, .745);
  static const wordLogoBounds = Rect.fromLTRB(.217, .466, .785, .535);
  static const primaryLogoBounds = Rect.fromLTRB(.195, .208, .806, .809);
}

/// The app icon in the chosen accent colour: the App icon preset of the
/// same colour (each built-in accent has one; coral is the default icon),
/// or for a custom colour the white mark on a tile of that colour. Read out
/// as "Reelish".
class AccentAppIcon extends StatelessWidget {
  const AccentAppIcon({super.key, required this.size, this.radius = 13});

  final double size;
  final double radius;

  /// The icon artwork for [accentId], or null for a custom colour.
  static String? assetFor(String accentId) {
    if (accentId == GlassTheme.coral.id) return BrandAssets.appIcon;
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
                      child: ReelishMark(height: size * .42),
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

  @override
  Widget build(BuildContext context) {
    final artwork = _BrandArtwork(
      asset: BrandAssets.wordLogo,
      bounds: BrandAssets.wordLogoBounds,
      height: height,
    );
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
