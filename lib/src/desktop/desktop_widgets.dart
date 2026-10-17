import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_item.dart';
import '../services/paged_feed_controller.dart';
import '../theme/glass_theme.dart';
import '../widgets/poster_image.dart';

/// Sizes for the Windows interface, derived from the space available rather
/// than the screen, so every window size from 960 px to 4K fills cleanly.
abstract final class DesktopMetrics {
  static const gap = 16.0;
  static const pagePadding = 40.0;

  /// Text under a poster: title and one line of metadata.
  static const captionHeight = 54.0;

  /// Poster width that fills [available] with whole cards, 150–230 px.
  static double posterWidth(double available) {
    final count = (available / 205).floor().clamp(4, 12);
    return ((available - gap * (count - 1)) / count).clamp(150.0, 230.0);
  }

  /// Columns of [posterWidth]-sized cards that fit [available].
  static int columns(double available) {
    final width = posterWidth(available);
    return ((available + gap) / (width + gap)).floor().clamp(2, 14);
  }

  static double cardHeight(double posterWidth) =>
      posterWidth * 1.5 + captionHeight;
}

/// Decode width for a poster [pixels] wide, rounded up to 64 px steps so a
/// window resize that changes card widths slightly reuses decoded images
/// instead of reloading every poster.
int posterDecodeWidth(double pixels) => ((pixels / 64).ceil() * 64).toInt();

Duration desktopMotion(BuildContext context, [int milliseconds = 180]) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

/// A movie or series poster for mouse and keyboard: lifts and outlines on
/// hover, shows a coral ring when focused, opens on click or Enter.
class DesktopPosterCard extends StatefulWidget {
  const DesktopPosterCard({
    super.key,
    required this.item,
    required this.width,
    required this.onOpen,
    this.progress = 0,
    this.isFavorite = false,
    this.rank,
    this.onHighlightChanged,
    this.onFocusChange,
  });

  final MediaItem item;
  final double width;
  final ValueChanged<MediaItem> onOpen;
  final double progress;
  final bool isFavorite;

  /// The position in a ranked row (Top 10), read out first. The row draws
  /// the numeral itself, beside the poster.
  final int? rank;

  /// Whether the card is hovered or shows its focus ring, so a ranked row
  /// can highlight the numeral with it.
  final ValueChanged<bool>? onHighlightChanged;

  final ValueChanged<bool>? onFocusChange;

  @override
  State<DesktopPosterCard> createState() => _DesktopPosterCardState();
}

class _DesktopPosterCardState extends State<DesktopPosterCard> {
  bool _hovered = false;
  bool _focused = false;

  void _setHighlight({bool? hovered, bool? focused}) {
    final was = _hovered || _focused;
    setState(() {
      _hovered = hovered ?? _hovered;
      _focused = focused ?? _focused;
    });
    final now = _hovered || _focused;
    if (now != was) widget.onHighlightChanged?.call(now);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final width = widget.width;
    final lifted = _hovered || _focused;
    final duration = desktopMotion(context);
    final radius = BorderRadius.circular(14);
    final meta = [
      if (item.year.isNotEmpty) item.year,
      item.type == 'series' ? 'Series' : 'Movie',
    ].join(' · ');
    return SizedBox(
      width: width,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => _setHighlight(hovered: value),
        onShowFocusHighlight: (value) => _setHighlight(focused: value),
        onFocusChange: widget.onFocusChange,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onOpen(item);
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: () => widget.onOpen(item),
          child: Semantics(
            button: true,
            label: [
              if (widget.rank case final rank?) 'Number $rank',
              item.name,
              meta,
            ].join(', '),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedScale(
                  scale: lifted ? 1.04 : 1,
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    width: width,
                    height: width * 1.5,
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      boxShadow: lifted
                          ? [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .55),
                                blurRadius: 24,
                                offset: const Offset(0, 10),
                              ),
                            ]
                          : const [],
                    ),
                    foregroundDecoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: _focused
                            ? GlassTheme.coralBright
                            : _hovered
                            ? Colors.white.withValues(alpha: .4)
                            : Colors.white.withValues(alpha: .06),
                        width: _focused ? 3 : 1.5,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: radius,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const PosterPlaceholder(iconSize: 34),
                          if (item.poster.isNotEmpty)
                            Image.network(
                              item.poster,
                              fit: BoxFit.cover,
                              cacheWidth: posterDecodeWidth(
                                width * MediaQuery.devicePixelRatioOf(context),
                              ),
                              frameBuilder: posterFadeIn(context),
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                          // Hover: a quiet shade with the rating and a play
                          // glyph, so the card reads as clickable.
                          AnimatedOpacity(
                            opacity: lifted ? 1 : 0,
                            duration: duration,
                            child: _HoverShade(item: item),
                          ),
                          if (widget.isFavorite)
                            const Positioned(
                              top: 8,
                              left: 8,
                              child: _Badge(
                                child: Icon(
                                  Symbols.favorite_rounded,
                                  fill: 1,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          if (widget.progress > 0)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: widget.progress.clamp(0, 1),
                                minHeight: 4,
                                color: GlassTheme.primary,
                                backgroundColor: Colors.black54,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: lifted ? Colors.white : GlassTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: GlassTheme.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverShade extends StatelessWidget {
  const _HoverShade({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00000000), Color(0x22000000), Color(0xCC000000)],
        stops: [0, .5, 1],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (item.rating.isNotEmpty && item.rating != '0.0') ...[
            Icon(
              Symbols.star_rounded,
              fill: 1,
              size: 15,
              color: GlassTheme.primary,
            ),
            const SizedBox(width: 4),
            Text(
              item.rating,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
          const Spacer(),
          DecoratedBox(
            decoration: BoxDecoration(
              color: GlassTheme.primary,
              shape: BoxShape.circle,
            ),
            child: const Padding(
              padding: EdgeInsets.all(7),
              child: Icon(
                Symbols.play_arrow_rounded,
                fill: 1,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .62),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: .14)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: child,
    ),
  );
}

/// A row heading in the desktop interface.
class DesktopSectionTitle extends StatelessWidget {
  const DesktopSectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      DesktopMetrics.pagePadding,
      28,
      DesktopMetrics.pagePadding,
      12,
    ),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            letterSpacing: -.3,
          ),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// A horizontal row of posters. Scrolls with a trackpad or Shift+wheel, and
/// with arrow buttons that appear on hover; asks for more near its end.
class DesktopMediaRow extends StatefulWidget {
  const DesktopMediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.onOpen,
    this.progressOf,
    this.isFavorite,
    this.onNearEnd,
    this.loadingMore = false,
  });

  final String title;
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  final double Function(MediaItem item)? progressOf;
  final bool Function(MediaItem item)? isFavorite;
  final VoidCallback? onNearEnd;
  final bool loadingMore;

  @override
  State<DesktopMediaRow> createState() => _DesktopMediaRowState();
}

class _DesktopMediaRowState extends State<DesktopMediaRow> {
  final _scroll = ScrollController();
  bool _hovered = false;
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Arrows only where there is more to scroll to.
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

  void _onScroll() {
    _updateArrows();
    final position = _scroll.position;
    if (position.extentAfter < position.viewportDimension) {
      widget.onNearEnd?.call();
    }
  }

  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target =
        (position.pixels + direction * position.viewportDimension * .85).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    _scroll.animateTo(
      target,
      duration: desktopMotion(context, 420),
      curve: Curves.easeOutCubic,
    );
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
          final count = widget.items.length + (widget.loadingMore ? 1 : 0);
          return MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: SizedBox(
              height: height,
              child: Stack(
                children: [
                  // Window resizes and new items change what can scroll.
                  NotificationListener<ScrollMetricsNotification>(
                    onNotification: (_) {
                      SchedulerBinding.instance.addPostFrameCallback(
                        (_) => _updateArrows(),
                      );
                      return false;
                    },
                    child: ListView.separated(
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: DesktopMetrics.pagePadding,
                        vertical: 12,
                      ),
                      itemCount: count,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: DesktopMetrics.gap),
                      itemBuilder: (context, index) {
                        if (index >= widget.items.length) {
                          return SizedBox(
                            width: posterWidth * .6,
                            child: const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        }
                        final item = widget.items[index];
                        return DesktopPosterCard(
                          item: item,
                          width: posterWidth,
                          onOpen: widget.onOpen,
                          progress: widget.progressOf?.call(item) ?? 0,
                          isFavorite: widget.isFavorite?.call(item) ?? false,
                        );
                      },
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

class DesktopRowArrow extends StatelessWidget {
  const DesktopRowArrow({
    super.key,
    required this.alignment,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.height,
  });

  final Alignment alignment;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final double height;

  @override
  Widget build(BuildContext context) => Align(
    alignment: alignment,
    child: Padding(
      padding: const EdgeInsets.only(bottom: DesktopMetrics.captionHeight),
      child: SizedBox(
        width: DesktopMetrics.pagePadding + 8,
        height: height,
        child: Tooltip(
          message: label,
          child: Material(
            color: Colors.black.withValues(alpha: .55),
            child: InkWell(
              // Mouse only: keyboard users move through the cards.
              canRequestFocus: false,
              onTap: onPressed,
              child: Icon(icon, size: 34),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A row backed by a paged TMDB feed: loads when first built, pages as it
/// nears its end, and shows loading and retry states in place.
class DesktopPagedRow extends StatelessWidget {
  const DesktopPagedRow({
    super.key,
    required this.title,
    required this.feed,
    required this.onOpen,
    this.isFavorite,
    this.loadWhenShown = true,
  });

  final String title;
  final PagedFeedController feed;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item)? isFavorite;
  final bool loadWhenShown;

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
      if (state.items.isEmpty) {
        return switch (state.status) {
          PagedFeedStatus.ready => const SizedBox.shrink(),
          PagedFeedStatus.failed => DesktopRowNotice(
            title: title,
            message: 'Could not load this row.',
            onRetry: () => unawaited(feed.retry()),
          ),
          _ => DesktopRowNotice(title: title, loading: true),
        };
      }
      return DesktopMediaRow(
        title: title,
        items: state.items,
        onOpen: onOpen,
        isFavorite: isFavorite,
        loadingMore: state.isLoadingMore,
        onNearEnd: state.hasMore ? () => unawaited(feed.loadMore()) : null,
      );
    },
  );
}

class DesktopRowNotice extends StatelessWidget {
  const DesktopRowNotice({
    super.key,
    required this.title,
    this.message,
    this.loading = false,
    this.onRetry,
  });

  final String title;
  final String? message;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DesktopSectionTitle(title),
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: DesktopMetrics.pagePadding,
          vertical: 24,
        ),
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                children: [
                  Text(
                    message ?? '',
                    style: const TextStyle(color: GlassTheme.muted),
                  ),
                  const SizedBox(width: 12),
                  if (onRetry != null)
                    TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Symbols.refresh_rounded, size: 18),
                      label: const Text('Retry'),
                    ),
                ],
              ),
      ),
    ],
  );
}

/// A responsive grid of posters for catalog, search and library pages.
class DesktopPosterGrid extends StatelessWidget {
  const DesktopPosterGrid({
    super.key,
    required this.items,
    required this.onOpen,
    this.isFavorite,
    this.progressOf,
    this.footer,
  });

  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item)? isFavorite;
  final double Function(MediaItem item)? progressOf;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final available =
          constraints.crossAxisExtent - DesktopMetrics.pagePadding * 2;
      final columns = DesktopMetrics.columns(available);
      final width = (available - DesktopMetrics.gap * (columns - 1)) / columns;
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          DesktopMetrics.pagePadding,
          8,
          DesktopMetrics.pagePadding,
          40,
        ),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: DesktopMetrics.gap,
            mainAxisSpacing: 26,
            childAspectRatio: width / DesktopMetrics.cardHeight(width),
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) => DesktopPosterCard(
              item: items[index],
              width: width,
              onOpen: onOpen,
              isFavorite: isFavorite?.call(items[index]) ?? false,
              progress: progressOf?.call(items[index]) ?? 0,
            ),
            childCount: items.length,
          ),
        ),
      );
    },
  );
}

/// A page title with optional actions, at the top of desktop pages.
class DesktopPageHeader extends StatelessWidget {
  const DesktopPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      DesktopMetrics.pagePadding,
      32,
      DesktopMetrics.pagePadding,
      12,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.8,
                ),
              ),
              if (subtitle case final subtitle?) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: GlassTheme.muted, fontSize: 14),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// An empty, loading or error state that fills a desktop page.
class DesktopMessage extends StatelessWidget {
  const DesktopMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: GlassTheme.primary.withValues(alpha: .14),
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Icon(icon, size: 34, color: GlassTheme.primary),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: GlassTheme.muted, height: 1.45),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    ),
  );
}
