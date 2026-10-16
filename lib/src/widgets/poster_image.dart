import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/glass_theme.dart';

/// The neutral tile behind a poster: a soft top-lit surface with a film
/// glyph. Painted once per card and covered as soon as the poster arrives.
class PosterPlaceholder extends StatelessWidget {
  const PosterPlaceholder({super.key, this.iconSize = 36});

  final double iconSize;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF262630), GlassTheme.elevatedSurface],
      ),
    ),
    child: Center(
      child: Icon(Symbols.movie_rounded, size: iconSize, color: Colors.white24),
    ),
  );
}

/// A frame builder that fades a network image in once its first frame is
/// decoded, instead of popping in. Cached images (decoded synchronously)
/// appear at once, and reduced motion skips the fade.
ImageFrameBuilder posterFadeIn(BuildContext context) {
  final duration = MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 220);
  return (context, child, frame, synchronous) => synchronous
      ? child
      : AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: duration,
          curve: Curves.easeOut,
          child: child,
        );
}
