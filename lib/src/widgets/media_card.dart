import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../models/media_item.dart';
import '../theme/design_tokens.dart';
import '../theme/glass_theme.dart';
import 'poster_image.dart';

/// A movie or series poster on the phone and tablet interface: the artwork
/// at its true 2:3 shape, with the title and one line of details beneath
/// it, so nothing covers the poster but the My list heart and, on Continue
/// watching, a thin progress line along its foot. TV and Windows have their
/// own cards (`TvPosterCard`, `DesktopPosterCard`).
class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.progress = 0,
    this.progressLabel = '',
    this.onFavorite,
    this.isFavorite = false,
    this.showTypeBadge = true,
    this.width = defaultWidth,
  });

  /// A card's width in a phone row.
  static const double defaultWidth = 146;

  /// Height at [defaultWidth] and the default text size: the 2:3 poster
  /// (219) and the caption ([captionHeight], 58). Rows and grids size
  /// themselves with [heightFor], which follows the text size.
  static const double defaultHeight = 277;

  static const _titleSize = AppTextSize.bodySmall;
  static const _metaSize = AppTextSize.caption;

  /// Large text grows the caption up to this much, so rows stay a
  /// predictable height; past it the title shortens with an ellipsis.
  static const _maxTextScale = 1.3;

  /// The title (two lines) and details line under the poster.
  static double captionHeight(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: _maxTextScale);
    return (8 +
            scaler.scale(_titleSize) * 1.25 * 2 +
            2 +
            scaler.scale(_metaSize) * 1.35)
        .ceilToDouble();
  }

  /// A card [width] wide: its 2:3 poster and the caption.
  static double heightFor(BuildContext context, double width) =>
      width * 1.5 + captionHeight(context);

  /// A row card's width: a little wider on a tablet, where the phone size
  /// left rows of small posters.
  static double rowWidthFor(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide >= 600 ? 168 : defaultWidth;

  final MediaItem item;
  final FutureOr<void> Function() onTap;
  final double progress;

  /// Replaces the year and rating on Continue Watching cards, such as
  /// `S2 E1 · 27 min left`.
  final String progressLabel;
  final VoidCallback? onFavorite;
  final bool isFavorite;

  /// Whether the details line says Movie or Series. Rows of one kind (and
  /// callers that say it elsewhere) can leave it out.
  final bool showTypeBadge;

  /// Wider in a grid that fills the screen; the height follows.
  final double width;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _navigating = false;
  late bool _isFavorite;
  DateTime? _lastActivationAt;
  final ValueNotifier<bool> _pressed = ValueNotifier(false);
  final ValueNotifier<int> _heartPressCount = ValueNotifier(0);

  static const _radius = AppRadius.md;

  @override
  void initState() {
    super.initState();
    _isFavorite = widget.isFavorite;
  }

  @override
  void didUpdateWidget(covariant MediaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isFavorite != widget.isFavorite) {
      _isFavorite = widget.isFavorite;
    }
  }

  void _onFavoritePressed() {
    setState(() => _isFavorite = !_isFavorite);
    if (!MediaQuery.disableAnimationsOf(context)) {
      _heartPressCount.value++;
    }
    widget.onFavorite?.call();
  }

  Future<void> _activate() async {
    final now = DateTime.now();
    if (_navigating ||
        (_lastActivationAt != null &&
            now.difference(_lastActivationAt!) <
                const Duration(milliseconds: 350))) {
      return;
    }
    _lastActivationAt = now;
    _navigating = true;
    try {
      await widget.onTap();
    } finally {
      if (mounted) {
        _pressed.value = false;
        _navigating = false;
      }
    }
  }

  @override
  void dispose() {
    _pressed.dispose();
    _heartPressCount.dispose();
    super.dispose();
  }

  /// What a screen reader says for the card: the title and its details.
  /// Set on the card itself, so a card cut off at a row's edge (its
  /// caption out of view) is still named.
  String _semanticLabel() {
    final item = widget.item;
    return [
      item.name,
      if (widget.progressLabel.isNotEmpty)
        widget.progressLabel
      else ...[
        if (item.year.isNotEmpty) item.year,
        if (widget.showTypeBadge) item.type == 'series' ? 'Series' : 'Movie',
        if (item.rating.isNotEmpty) 'rated ${item.rating}',
      ],
    ].join(', ');
  }

  /// Year, kind and rating, or the time left on Continue Watching.
  InlineSpan _details() {
    final item = widget.item;
    if (widget.progressLabel.isNotEmpty) {
      return TextSpan(text: widget.progressLabel);
    }
    final facts = [
      if (item.year.isNotEmpty) item.year,
      if (widget.showTypeBadge) item.type == 'series' ? 'Series' : 'Movie',
    ];
    return TextSpan(
      children: [
        TextSpan(text: facts.join('  ·  ')),
        if (item.rating.isNotEmpty) ...[
          if (facts.isNotEmpty) const TextSpan(text: '  ·  '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(
                Symbols.star_rounded,
                fill: 1,
                size: 12,
                color: GlassTheme.primary,
              ),
            ),
          ),
          TextSpan(text: item.rating, semanticsLabel: 'rated ${item.rating}'),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final progress = widget.progress;
    final width = widget.width;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final radius = BorderRadius.circular(_radius);
    // The poster is drawn once; only a press rebuilds its scale and shade.
    final poster = ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Shown while the poster loads, when it fails, and when there is
          // none, so a card is never an empty slab or a broken image.
          const PosterPlaceholder(iconSize: 30),
          if (item.poster.isNotEmpty)
            Image.network(
              item.poster,
              fit: BoxFit.cover,
              cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              frameBuilder: posterFadeIn(context),
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          if (progress > 0) ...[
            // A short fade so the progress line reads on light posters.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 36,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xB3000000)],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 3,
                color: GlassTheme.primary,
                backgroundColor: Colors.white24,
              ),
            ),
          ],
          // A hairline edge, so dark posters keep their shape on the dark
          // page.
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: Colors.white.withValues(alpha: .07)),
              ),
            ),
          ),
        ],
      ),
    );
    return SizedBox(
      width: width,
      height: MediaCard.heightFor(context, width),
      child: Material(
        type: MaterialType.transparency,
        child: Semantics(
          label: _semanticLabel(),
          child: InkWell(
            onTap: _activate,
            onTapDown: (_) => _pressed.value = true,
            onTapCancel: () {
              if (_pressed.value && !_navigating) _pressed.value = false;
            },
            borderRadius: radius,
            // The poster dims and settles instead of a ripple over artwork.
            splashFactory: NoSplash.splashFactory,
            highlightColor: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: _pressed,
                        builder: (context, pressed, child) => AnimatedScale(
                          scale: pressed ? .97 : 1,
                          duration: AppMotion.resolve(
                            context,
                            pressed ? AppMotion.press : AppMotion.hover,
                          ),
                          curve: AppMotion.enter,
                          child: AnimatedOpacity(
                            opacity: pressed ? .82 : 1,
                            duration: AppMotion.resolve(
                              context,
                              AppMotion.press,
                            ),
                            child: child,
                          ),
                        ),
                        child: poster,
                      ),
                      if (widget.onFavorite != null)
                        // A 33 dp circle in a 47 dp hit area that reaches the
                        // poster's corner: easy to tap, small on the artwork.
                        Positioned(
                          top: 0,
                          right: 0,
                          child: SizedBox.square(
                            dimension: 47,
                            child: IconButton(
                              padding: const EdgeInsets.all(7),
                              tooltip: _isFavorite
                                  ? 'Remove from My list'
                                  : 'Add to My list',
                              isSelected: _isFavorite,
                              onPressed: _onFavoritePressed,
                              icon: DecoratedBox(
                                decoration: const BoxDecoration(
                                  color: Color(0x80000000),
                                  shape: BoxShape.circle,
                                ),
                                child: SizedBox.square(
                                  dimension: 33,
                                  child: ValueListenableBuilder<int>(
                                    valueListenable: _heartPressCount,
                                    builder: (context, pressCount, child) {
                                      if (pressCount == 0 || reduceMotion) {
                                        return child!;
                                      }
                                      return TweenAnimationBuilder<double>(
                                        key: ValueKey(pressCount),
                                        tween: Tween(begin: .75, end: 1),
                                        duration: AppMotion.page,
                                        curve: Curves.easeOutBack,
                                        builder: (context, scale, child) =>
                                            Transform.scale(
                                              scale: scale,
                                              child: child,
                                            ),
                                        child: child,
                                      );
                                    },
                                    child: Icon(
                                      Symbols.favorite_rounded,
                                      fill: _isFavorite ? 1 : 0,
                                      size: 17,
                                      color: _isFavorite
                                          ? GlassTheme.primary
                                          : Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Read once, in the card's own label.
                ExcludeSemantics(
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: MediaCard._maxTextScale,
                    child: SizedBox(
                      height: MediaCard.captionHeight(context),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, right: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: MediaCard._titleSize,
                                height: 1.25,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -.1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text.rich(
                              _details(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: widget.progressLabel.isNotEmpty
                                    ? GlassTheme.coralBright
                                    : GlassTheme.muted,
                                fontSize: MediaCard._metaSize,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A poster-shaped stand-in while a row's first page loads: the card's
/// exact size, so nothing moves when the posters arrive. Still, not
/// shimmering, to keep loading cheap.
class MediaCardSkeleton extends StatelessWidget {
  const MediaCardSkeleton({super.key, this.width = MediaCard.defaultWidth});

  final double width;

  @override
  Widget build(BuildContext context) {
    final bar = BorderRadius.circular(AppRadius.xs);
    return ExcludeSemantics(
      child: SizedBox(
        width: width,
        height: MediaCard.heightFor(context, width),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: const ColoredBox(color: GlassTheme.surface),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: width * .8,
              height: 10,
              decoration: BoxDecoration(
                color: GlassTheme.elevatedSurface,
                borderRadius: bar,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: width * .45,
              height: 8,
              decoration: BoxDecoration(
                color: GlassTheme.surface,
                borderRadius: bar,
              ),
            ),
            SizedBox(height: MediaCard.captionHeight(context) - 36),
          ],
        ),
      ),
    );
  }
}
