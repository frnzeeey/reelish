import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_item.dart';
import '../services/media_catalog_rules.dart';
import '../services/paged_feed_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/poster_image.dart';
import 'desktop_widgets.dart';

/// Top 10 on Windows: the shared Top 10 feed (the same seeds, ranking and
/// cache as Android and TV) drawn as ranked posters with the outlined
/// numerals of the mobile and TV rows.
///
/// All ten cards are built, so arrow keys and a controller's D-pad reach
/// every one, and the focused card is scrolled fully into view, numeral
/// included. The row scrolls with a trackpad, Shift+wheel, a mouse drag or
/// the arrows that appear on hover.
class DesktopTopTenRow extends StatelessWidget {
  const DesktopTopTenRow({
    super.key,
    required this.feed,
    required this.onOpen,
    this.isFavorite,
    this.loadWhenShown = true,
    this.title = 'Top 10 recommendations',
  });

  /// The shared Top 10 feed (`targetCount: 10`).
  final PagedFeedController feed;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item)? isFavorite;

  /// Top 10 is seeded from page 1 of the catalog rows, so Home holds it
  /// back until they have loaded.
  final bool loadWhenShown;
  final String title;

  static const maxItems = 10;

  /// The titles to show: the feed's ranked order, each title once, at most
  /// ten. The feed already guarantees this; it is enforced here too so a
  /// rank number can never repeat or exceed 10.
  static List<MediaItem> visibleItems(List<MediaItem> items) =>
      MediaCatalogFilter.dedupe(items).take(maxItems).toList();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: feed,
    builder: (context, _) {
      final state = feed.state;
      if (loadWhenShown && state.status == PagedFeedStatus.idle) {
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => unawaited(feed.ensureLoaded()),
        );
      }
      final items = visibleItems(state.items);
      if (items.isNotEmpty) {
        return _TopTenCarousel(
          title: title,
          items: items,
          onOpen: onOpen,
          isFavorite: isFavorite,
        );
      }
      return switch (state.status) {
        // Nothing to recommend (no seeds, or every title filtered out):
        // the row stays out of the way, as other empty rows do.
        PagedFeedStatus.ready => const SizedBox.shrink(),
        PagedFeedStatus.failed => DesktopRowNotice(
          title: title,
          message: 'Could not load recommendations.',
          onRetry: () => unawaited(feed.retry()),
        ),
        _ => _TopTenSkeleton(title: title),
      };
    },
  );
}

/// Sizes of a ranked card, from the poster width the other rows use, so
/// Top 10 lines up with them at every window size and display scale.
abstract final class _RankMetrics {
  /// The numeral's font size: about three quarters of the poster height.
  static double numeralSize(double posterWidth) => posterWidth * 1.5 * .74;

  /// Room left of the poster for the numeral; "10" needs more.
  static double numeralWidth(double posterWidth, int rank) =>
      posterWidth * (rank == 10 ? .78 : .46);

  /// Space between the numeral and its poster: none, so the two read as
  /// one card while the numeral is never hidden behind the poster.
  static double overlap(double posterWidth) => 0;
}

class _TopTenCarousel extends StatefulWidget {
  const _TopTenCarousel({
    required this.title,
    required this.items,
    required this.onOpen,
    this.isFavorite,
  });

  final String title;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item)? isFavorite;

  @override
  State<_TopTenCarousel> createState() => _TopTenCarouselState();
}

class _TopTenCarouselState extends State<_TopTenCarousel> {
  final _scroll = ScrollController();
  bool _hovered = false;
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateArrows);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final back = position.pixels > 4;
    final forward = position.extentAfter > 4;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _scroll.animateTo(
      (position.pixels + direction * position.viewportDimension * .85).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
      duration: desktopMotion(context, 420),
      curve: Curves.easeOutCubic,
    );
  }

  /// Scrolls the least needed for the ranked card at [context] (numeral and
  /// poster) to be fully visible, clear of the edge arrows. Runs after the
  /// focus system's own reveal, which only knows about the poster.
  void _reveal(BuildContext context) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !context.mounted || !_scroll.hasClients) return;
      final object = context.findRenderObject();
      if (object == null || !object.attached) return;
      final viewport = RenderAbstractViewport.maybeOf(object);
      if (viewport == null) return;
      final position = _scroll.position;
      const margin = DesktopMetrics.pagePadding;
      final atStart = viewport.getOffsetToReveal(object, 0).offset - margin;
      final atEnd = viewport.getOffsetToReveal(object, 1).offset + margin;
      // A card wider than the view keeps its start in view.
      final target =
          (atEnd > atStart ? atStart : position.pixels.clamp(atEnd, atStart))
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((target - position.pixels).abs() < 1) return;
      _scroll.animateTo(
        target,
        duration: desktopMotion(context, 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DesktopSectionTitle(widget.title),
      LayoutBuilder(
        builder: (context, constraints) {
          final available =
              constraints.maxWidth - DesktopMetrics.pagePadding * 2;
          final posterWidth = DesktopMetrics.posterWidth(available);
          // Room above and below for the hover lift and focus ring.
          final height = DesktopMetrics.cardHeight(posterWidth) + 24;
          return MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: SizedBox(
              height: height,
              child: Stack(
                children: [
                  NotificationListener<ScrollMetricsNotification>(
                    onNotification: (_) {
                      SchedulerBinding.instance.addPostFrameCallback(
                        (_) => _updateArrows(),
                      );
                      return false;
                    },
                    child: ScrollConfiguration(
                      // A mouse can drag the row too; taps still open.
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: {
                          ...ScrollConfiguration.of(context).dragDevices,
                          PointerDeviceKind.mouse,
                        },
                        scrollbars: false,
                      ),
                      child: FocusTraversalGroup(
                        // Left/Right move through the ranks in order.
                        policy: OrderedTraversalPolicy(),
                        child: SingleChildScrollView(
                          controller: _scroll,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                            horizontal: DesktopMetrics.pagePadding,
                            vertical: 12,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < widget.items.length; i++) ...[
                                if (i > 0)
                                  const SizedBox(width: DesktopMetrics.gap),
                                FocusTraversalOrder(
                                  order: NumericFocusOrder(i.toDouble()),
                                  child: _RankedCard(
                                    // Keyed by rank: when the list refreshes,
                                    // focus stays on the same position.
                                    key: ValueKey('top10:${i + 1}'),
                                    rank: i + 1,
                                    item: widget.items[i],
                                    posterWidth: posterWidth,
                                    onOpen: widget.onOpen,
                                    isFavorite:
                                        widget.isFavorite?.call(
                                          widget.items[i],
                                        ) ??
                                        false,
                                    onFocused: _reveal,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_hovered && _canBack)
                    DesktopRowArrow(
                      alignment: Alignment.centerLeft,
                      icon: Symbols.chevron_left_rounded,
                      label: 'Scroll ${widget.title} back',
                      onPressed: () => _page(-1),
                      height: posterWidth * 1.5,
                    ),
                  if (_hovered && _canForward)
                    DesktopRowArrow(
                      alignment: Alignment.centerRight,
                      icon: Symbols.chevron_right_rounded,
                      label: 'Scroll ${widget.title} forward',
                      onPressed: () => _page(1),
                      height: posterWidth * 1.5,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ],
  );
}

/// One ranked title: the outlined numeral, with the poster card over its
/// right edge. The numeral turns coral with the card's hover or focus.
class _RankedCard extends StatefulWidget {
  const _RankedCard({
    super.key,
    required this.rank,
    required this.item,
    required this.posterWidth,
    required this.onOpen,
    required this.isFavorite,
    required this.onFocused,
  });

  final int rank;
  final MediaItem item;
  final double posterWidth;
  final ValueChanged<MediaItem> onOpen;
  final bool isFavorite;
  final void Function(BuildContext context) onFocused;

  @override
  State<_RankedCard> createState() => _RankedCardState();
}

class _RankedCardState extends State<_RankedCard> {
  bool _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final posterWidth = widget.posterWidth;
    final numeralWidth = _RankMetrics.numeralWidth(posterWidth, widget.rank);
    final overlap = _RankMetrics.overlap(posterWidth);
    return SizedBox(
      width: numeralWidth - overlap + posterWidth,
      height: DesktopMetrics.cardHeight(posterWidth),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            width: numeralWidth,
            top: 0,
            height: posterWidth * 1.5,
            child: _Numeral(
              rank: widget.rank,
              size: _RankMetrics.numeralSize(posterWidth),
              highlighted: _highlighted,
            ),
          ),
          Positioned(
            left: numeralWidth - overlap,
            top: 0,
            child: DesktopPosterCard(
              item: widget.item,
              width: posterWidth,
              rank: widget.rank,
              onOpen: widget.onOpen,
              isFavorite: widget.isFavorite,
              onHighlightChanged: (value) {
                if (mounted) setState(() => _highlighted = value);
              },
              onFocusChange: (focused) {
                if (focused) widget.onFocused(context);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Numeral extends StatelessWidget {
  const _Numeral({
    required this.rank,
    required this.size,
    required this.highlighted,
  });

  final int rank;
  final double size;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Align(
      alignment: Alignment.bottomLeft,
      // The numeral's own box, so a wide "10" scales down instead of
      // spilling under the poster or out of the row.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.bottomLeft,
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(
            end: highlighted
                ? GlassTheme.coralBright
                : Colors.white.withValues(alpha: .7),
          ),
          duration: desktopMotion(context),
          builder: (context, color, _) => Text(
            '$rank',
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: size,
              height: .82,
              letterSpacing: rank == 10 ? -size * .14 : -size * .04,
              fontWeight: FontWeight.w900,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = (size / 50).clamp(2.5, 5)
                ..color = color ?? Colors.white,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The first load: dim ranked placeholders in the row's real layout, so
/// the page does not jump when the titles arrive. Static, no shimmer.
class _TopTenSkeleton extends StatelessWidget {
  const _TopTenSkeleton({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading $title',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DesktopSectionTitle(title),
        LayoutBuilder(
          builder: (context, constraints) {
            final available =
                constraints.maxWidth - DesktopMetrics.pagePadding * 2;
            final posterWidth = DesktopMetrics.posterWidth(available);
            return SizedBox(
              height: DesktopMetrics.cardHeight(posterWidth) + 24,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxWidth: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DesktopMetrics.pagePadding,
                      vertical: 12,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var rank = 1; rank <= 6; rank++) ...[
                          if (rank > 1)
                            const SizedBox(width: DesktopMetrics.gap),
                          ExcludeSemantics(
                            child: Opacity(
                              opacity: .45,
                              child: _SkeletonCard(
                                rank: rank,
                                posterWidth: posterWidth,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.rank, required this.posterWidth});

  final int rank;
  final double posterWidth;

  @override
  Widget build(BuildContext context) {
    final numeralWidth = _RankMetrics.numeralWidth(posterWidth, rank);
    final overlap = _RankMetrics.overlap(posterWidth);
    return SizedBox(
      width: numeralWidth - overlap + posterWidth,
      height: posterWidth * 1.5,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            width: numeralWidth,
            top: 0,
            bottom: 0,
            child: _Numeral(
              rank: rank,
              size: _RankMetrics.numeralSize(posterWidth),
              highlighted: false,
            ),
          ),
          Positioned(
            left: numeralWidth - overlap,
            top: 0,
            width: posterWidth,
            bottom: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: const PosterPlaceholder(iconSize: 34),
            ),
          ),
        ],
      ),
    );
  }
}
