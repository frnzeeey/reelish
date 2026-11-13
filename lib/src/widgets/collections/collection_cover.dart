// The artwork of a collection, folder or smart collection: up to four of
// its posters in a grid, or its icon when it has none. Drawn the size of a
// poster, so collection tiles line up with title cards.

import 'package:flutter/material.dart';

import '../../theme/glass_theme.dart';
import '../artwork_image.dart';

class CollectionCover extends StatelessWidget {
  const CollectionCover({
    super.key,
    required this.posters,
    required this.icon,
    required this.width,
    this.radius = 14,
  });

  final List<String> posters;
  final IconData icon;
  final double width;
  final double radius;

  /// Poster shape: 2:3.
  static double heightFor(double width) => width * 1.5;

  @override
  Widget build(BuildContext context) {
    final height = heightFor(width);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final grid = posters.length >= 4;
    final cacheWidth = ((grid ? width / 2 : width) * ratio).round();
    Widget poster(String url) => ArtworkImage.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => ColoredBox(color: GlassTheme.surface),
    );
    final Widget art;
    if (posters.isEmpty) {
      art = ColoredBox(
        color: GlassTheme.surface,
        child: Center(
          child: Icon(icon, size: width * .28, color: GlassTheme.primary),
        ),
      );
    } else if (!grid) {
      art = poster(posters.first);
    } else {
      // Two by two, with a hairline of the page between the posters.
      art = ColoredBox(
        color: GlassTheme.background,
        child: Column(
          children: [
            for (final row in [0, 2])
              Expanded(
                child: Row(
                  children: [
                    for (final column in [0, 1])
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: column == 1 ? 1 : 0,
                            top: row == 2 ? 1 : 0,
                          ),
                          child: SizedBox.expand(
                            child: poster(posters[row + column]),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: GlassTheme.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: art,
        ),
      ),
    );
  }
}
