import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/media_item.dart';
import '../../theme/glass_theme.dart';
import 'tv_focus.dart';

/// Poster sizes for the TV catalog. At 1080p a TV reports 960 × 540 dp, so a
/// row shows about six posters beside the navigation rail.
abstract final class TvPosterMetrics {
  static const width = 132.0;
  static const height = 198.0;
  static const gap = 18.0;

  /// Room above and below a row's posters for the focus scale and glow.
  static const focusPadding = 14.0;
}

/// A poster on the TV catalog. The poster is the whole card; its title and
/// details show in the browse hero while it has focus, so a row stays calm
/// to look at. Plain painting only: no blur, one decoded image per card.
class TvPosterCard extends StatelessWidget {
  const TvPosterCard({
    super.key,
    required this.item,
    required this.onSelect,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    this.progress = 0,
    this.isFavorite = false,
  });

  final MediaItem item;
  final VoidCallback onSelect;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Watched fraction, for Continue watching; 0 hides the bar.
  final double progress;
  final bool isFavorite;

  @override
  Widget build(BuildContext context) {
    final cacheWidth =
        (TvPosterMetrics.width * MediaQuery.devicePixelRatioOf(context))
            .round();
    return SizedBox(
      width: TvPosterMetrics.width,
      height: TvPosterMetrics.height,
      child: TvFocusable(
        focusNode: focusNode,
        autofocus: autofocus,
        onSelect: onSelect,
        onFocusChange: onFocusChange,
        semanticLabel: [
          item.name,
          if (item.year.isNotEmpty) item.year,
          item.type == 'series' ? 'Series' : 'Movie',
        ].join(', '),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: GlassTheme.elevatedSurface,
              child: item.poster.isEmpty
                  ? _TitleFallback(item: item)
                  : Image.network(
                      item.poster,
                      fit: BoxFit.cover,
                      cacheWidth: cacheWidth,
                      errorBuilder: (_, _, _) => _TitleFallback(item: item),
                    ),
            ),
            if (isFavorite)
              Positioned(
                top: 8,
                left: 8,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0xB3000000),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      Symbols.favorite_rounded,
                      fill: 1,
                      size: 14,
                      color: GlassTheme.primary,
                    ),
                  ),
                ),
              ),
            if (progress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress.clamp(0, 1),
                  minHeight: 4,
                  color: GlassTheme.primary,
                  backgroundColor: const Color(0x99000000),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TitleFallback extends StatelessWidget {
  const _TitleFallback({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Symbols.movie_rounded, color: GlassTheme.muted, size: 30),
        const SizedBox(height: 10),
        Text(
          item.name,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

/// A Top 10 position drawn beside its poster: an outlined numeral, as on
/// the mobile Top 10 row.
class TvRankedPoster extends StatelessWidget {
  const TvRankedPoster({super.key, required this.rank, required this.poster});

  final int rank;
  final Widget poster;

  static const numeralWidth = 54.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: numeralWidth + TvPosterMetrics.width,
    height: TvPosterMetrics.height,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          bottom: -6,
          child: ExcludeSemantics(
            child: Text(
              '$rank',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: 150,
                height: .82,
                letterSpacing: rank == 10 ? -20 : -6,
                fontWeight: FontWeight.w900,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 3
                  ..color = Colors.white.withValues(alpha: .72),
              ),
            ),
          ),
        ),
        Positioned(left: numeralWidth, top: 0, child: poster),
      ],
    ),
  );
}
