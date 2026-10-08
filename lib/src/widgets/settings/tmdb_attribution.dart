import 'package:flutter/material.dart';

import '../../theme/glass_theme.dart';

/// TMDB attribution wording and assets, per
/// https://developer.themoviedb.org/docs/faq and
/// https://www.themoviedb.org/about/logos-attribution.
abstract final class TmdbAttribution {
  /// The exact notice TMDB requires; do not reword.
  static const disclaimer =
      'This product uses the TMDB API but is not endorsed or certified by TMDB.';

  static final website = Uri.https('www.themoviedb.org', '/');

  /// TMDB's official "alt short" logo, rasterized unmodified from the SVG
  /// on the logos page (kept beside it for reference). TMDB forbids
  /// changing its color, aspect ratio or orientation.
  static const logoAsset = 'assets/images/tmdb/tmdb_logo_alt_short.png';

  /// Width / height of the source artwork (273.42 × 35.52).
  static const logoAspectRatio = 273.42 / 35.52;
}

/// The official TMDB logo at a given height, never stretched.
class TmdbLogo extends StatelessWidget {
  const TmdbLogo({super.key, this.height = 16});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: height * TmdbAttribution.logoAspectRatio,
    child: Image.asset(
      TmdbAttribution.logoAsset,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'TMDB logo',
      excludeFromSemantics: false,
    ),
  );
}

/// The TMDB notice at the end of every settings page.
///
/// Static and const, so a parent rebuild never rebuilds it. Set [showLogo]
/// to false on pages that already show the full TMDB attribution.
class TmdbAttributionFooter extends StatelessWidget {
  const TmdbAttributionFooter({super.key, this.showLogo = true});

  final bool showLogo;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 36, height: 1, color: GlassTheme.border),
        const SizedBox(height: 16),
        if (showLogo) ...[
          const TmdbLogo(height: 11),
          const SizedBox(height: 10),
        ],
        const Text(
          TmdbAttribution.disclaimer,
          textAlign: TextAlign.center,
          style: TextStyle(color: GlassTheme.muted, fontSize: 11, height: 1.45),
        ),
      ],
    ),
  );
}
