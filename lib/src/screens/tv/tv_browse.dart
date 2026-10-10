import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/media_item.dart';
import '../../services/paged_feed_controller.dart';
import '../../theme/glass_theme.dart';
import '../../widgets/tv/tv_focus.dart';
import '../../widgets/tv/tv_poster_card.dart';

/// The title the browse hero describes: the focused poster, a moment after
/// focus settles, so a held D-pad does not decode a backdrop per poster.
class TvFeaturedController extends ValueNotifier<MediaItem?> {
  TvFeaturedController([super.value]);

  static const settle = Duration(milliseconds: 260);
  Timer? _timer;

  void feature(MediaItem item) {
    _timer?.cancel();
    if (value == null) {
      value = item;
      return;
    }
    _timer = Timer(settle, () => value = item);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// A browse page: the featured title's backdrop fills the upper right,
/// fading into the background; its details sit at the top left; [child]
/// (rows or a grid) fills the rest.
class TvBrowseFrame extends StatelessWidget {
  const TvBrowseFrame({
    super.key,
    required this.featured,
    required this.child,
    this.heroFraction = .46,
    this.header,
  });

  final ValueListenable<MediaItem?> featured;
  final Widget child;

  /// Share of the screen height the hero takes above [child].
  final double heroFraction;

  /// Shown above the featured title, such as a page heading.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final heroHeight = size.height * heroFraction;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          right: 0,
          width: size.width * .74,
          height: size.height * .78,
          child: RepaintBoundary(child: _Backdrop(featured: featured)),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: heroHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  12,
                  TvSafeArea.vertical,
                  TvSafeArea.horizontal,
                  8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ?header,
                    Expanded(child: _HeroDetails(featured: featured)),
                  ],
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ],
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.featured});

  final ValueListenable<MediaItem?> featured;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width * .74;
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: featured,
      builder: (context, item, _) {
        final url = item?.background ?? '';
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 420),
              child: url.isEmpty
                  ? const SizedBox.expand(key: ValueKey(''))
                  : Image.network(
                      url,
                      key: ValueKey(url),
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      cacheWidth: cacheWidth,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.expand(),
                    ),
            ),
            // Painted fades into the background, left and bottom.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    GlassTheme.background,
                    Color(0xCC0B0B0F),
                    Color(0x330B0B0F),
                    Color(0x000B0B0F),
                  ],
                  stops: [0, .25, .6, 1],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    GlassTheme.background,
                    Color(0x990B0B0F),
                    Color(0x000B0B0F),
                  ],
                  stops: [0, .35, .7],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HeroDetails extends StatelessWidget {
  const _HeroDetails({required this.featured});

  final ValueListenable<MediaItem?> featured;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width * .5;
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: featured,
      builder: (context, item, _) {
        if (item == null) return const SizedBox.shrink();
        final meta = [
          if (item.year.isNotEmpty) item.year,
          item.type == 'series' ? 'Series' : 'Movie',
          if (item.rating.isNotEmpty) '★ ${item.rating}',
        ].join('   ·   ');
        return AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 240),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.bottomLeft,
            children: [...previous, ?current],
          ),
          // Anchored to the bottom; on a short hero the top is clipped
          // rather than overflowing.
          child: SingleChildScrollView(
            key: ValueKey('${item.type}:${item.id}'),
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            child: SizedBox(
              width: width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 36,
                      height: 1.05,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 12)],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    meta,
                    style: const TextStyle(
                      color: Color(0xDDFFFFFF),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (item.description.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      item.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xC7FFFFFF),
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Directional traversal for rows and grids, which scroll themselves to keep
/// focus in a fixed place; the default would first nudge the newly focused
/// poster into view, and the two scrolls would fight.
final tvSelfScrollingTraversal = ReadingOrderTraversalPolicy(
  requestFocusCallback: (node, {alignment, alignmentPolicy, curve, duration}) =>
      node.requestFocus(),
);

/// A row heading on the TV catalog.
class TvRowTitle extends StatelessWidget {
  const TvRowTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 12, bottom: 2),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -.3,
      ),
    ),
  );
}

/// How a row or grid presents each title.
class TvCardOptions {
  const TvCardOptions({
    required this.onOpen,
    this.onFocusItem,
    this.progressOf,
    this.isFavorite,
  });

  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem>? onFocusItem;
  final double Function(MediaItem item)? progressOf;
  final bool Function(MediaItem item)? isFavorite;
}

/// A horizontal row of posters for the remote.
///
/// The focused poster stays at the row's start while the D-pad moves along
/// it, and the row itself scrolls to the top of the list, so focus is always
/// in the same place on screen. Coming back to a row (Up or Down from
/// another one) returns to the poster focused there last, not whichever
/// happens to be nearest.
class TvMediaRow extends StatefulWidget {
  const TvMediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.cards,
    this.ranked = false,
    this.onNearEnd,
    this.trailing,
    this.autofocus = false,
  });

  final String title;
  final List<MediaItem> items;
  final TvCardOptions cards;
  final bool ranked;

  /// Called as focus nears the end, to load another page.
  final VoidCallback? onNearEnd;

  /// Shown after the last poster: a loading ring or a Retry button.
  final Widget? trailing;

  /// Focuses the first poster when nothing else on the page has focus.
  final bool autofocus;

  static double get height =>
      34 + TvPosterMetrics.height + TvPosterMetrics.focusPadding * 2;

  @override
  State<TvMediaRow> createState() => _TvMediaRowState();
}

class _TvMediaRowState extends State<TvMediaRow> {
  final _scroll = ScrollController();
  final Map<int, FocusNode> _nodes = {};
  int _lastFocused = 0;
  bool _rowFocused = false;

  double get _extent =>
      (widget.ranked ? TvRankedPoster.numeralWidth : 0) +
      TvPosterMetrics.width +
      TvPosterMetrics.gap;

  FocusNode _node(int index) =>
      _nodes[index] ??= FocusNode(debugLabel: '${widget.title} $index');

  @override
  void didUpdateWidget(covariant TvMediaRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refreshed list starts again at its first title.
    if (widget.items.length < oldWidget.items.length) _lastFocused = 0;
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _onRowFocusChange(bool focused) {
    if (focused && !_rowFocused) {
      _rowFocused = true;
      // Arriving from another row: return to the poster focused here last.
      final remembered = _nodes[_lastFocused];
      if (remembered != null &&
          remembered.context != null &&
          !remembered.hasPrimaryFocus) {
        remembered.requestFocus();
      }
      Scrollable.ensureVisible(
        context,
        duration: _motion,
        curve: Curves.easeOutCubic,
      );
    } else if (!focused) {
      _rowFocused = false;
    }
  }

  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 220);

  void _onCardFocus(int index, bool focused) {
    if (!focused) return;
    if (_rowFocused) _lastFocused = index;
    widget.cards.onFocusItem?.call(widget.items[index]);
    if (_scroll.hasClients) {
      final target = math.min(
        index * _extent,
        _scroll.position.maxScrollExtent,
      );
      _scroll.animateTo(target, duration: _motion, curve: Curves.easeOutCubic);
    }
    final onNearEnd = widget.onNearEnd;
    if (onNearEnd != null && index >= widget.items.length - 6) {
      // Focus changes are applied mid-frame; load after it.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) onNearEnd();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final cards = widget.cards;
    final trailing = widget.trailing;
    return SizedBox(
      height: TvMediaRow.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvRowTitle(widget.title),
          Expanded(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: _onRowFocusChange,
              child: FocusTraversalGroup(
                policy: tvSelfScrollingTraversal,
                child: ListView.builder(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: TvPosterMetrics.focusPadding,
                  ),
                  itemCount: items.length + (trailing == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (index == items.length) return trailing!;
                    final item = items[index];
                    final card = TvPosterCard(
                      item: item,
                      focusNode: _node(index),
                      autofocus: widget.autofocus && index == 0,
                      progress: cards.progressOf?.call(item) ?? 0,
                      isFavorite: cards.isFavorite?.call(item) ?? false,
                      onSelect: () => cards.onOpen(item),
                      onFocusChange: (focused) => _onCardFocus(index, focused),
                    );
                    return Padding(
                      padding: const EdgeInsets.only(
                        right: TvPosterMetrics.gap,
                      ),
                      child: widget.ranked
                          ? TvRankedPoster(rank: index + 1, poster: card)
                          : card,
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A [TvMediaRow] fed by a paging catalog row. Before its first titles it
/// shows a loading ring or a Retry button in the row's place; a row that
/// loaded empty disappears.
class TvPagedRow extends StatelessWidget {
  const TvPagedRow({
    super.key,
    required this.title,
    required this.feed,
    required this.cards,
    this.ranked = false,
    this.autofocus = false,
    this.loadWhenShown = true,
  });

  final String title;
  final PagedFeedController feed;
  final TvCardOptions cards;
  final bool ranked;
  final bool autofocus;

  /// Starts the row's first load once it is built (rows are built as the
  /// list nears them). Off while what it depends on is still loading.
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
          PagedFeedStatus.failed => TvRowMessage(
            title: title,
            message: 'Could not load this row.',
            onRetry: () => unawaited(feed.retry()),
          ),
          _ => TvRowMessage(title: title, loading: true),
        };
      }
      return TvMediaRow(
        title: title,
        items: state.items,
        cards: cards,
        ranked: ranked,
        autofocus: autofocus,
        onNearEnd: state.hasMore ? () => unawaited(feed.loadMore()) : null,
        trailing: state.isLoadingMore
            ? const _TrailingProgress()
            : state.error != null
            ? _TrailingRetry(onRetry: () => unawaited(feed.retry()))
            : null,
      );
    },
  );
}

/// A row's place while it loads or after it failed.
class TvRowMessage extends StatelessWidget {
  const TvRowMessage({
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
  Widget build(BuildContext context) => SizedBox(
    height: TvMediaRow.height,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvRowTitle(title),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: loading
                  ? SizedBox.square(
                      dimension: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: GlassTheme.primary,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message != null)
                          Text(
                            message!,
                            style: const TextStyle(color: GlassTheme.muted),
                          ),
                        if (onRetry != null) ...[
                          const SizedBox(width: 16),
                          OutlinedButton.icon(
                            onPressed: onRetry,
                            icon: const Icon(Symbols.refresh_rounded),
                            label: const Text('Retry'),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _TrailingProgress extends StatelessWidget {
  const _TrailingProgress();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 64,
    child: Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: GlassTheme.primary,
        ),
      ),
    ),
  );
}

class _TrailingRetry extends StatelessWidget {
  const _TrailingRetry({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 88,
    child: Center(
      child: IconButton.filledTonal(
        tooltip: 'Retry',
        onPressed: onRetry,
        icon: const Icon(Symbols.refresh_rounded),
      ),
    ),
  );
}

/// A poster grid for the remote. The focused grid row scrolls to the top
/// of the grid, and focus nearing the last rows asks for another page.
class TvMediaGrid extends StatefulWidget {
  const TvMediaGrid({
    super.key,
    required this.items,
    required this.cards,
    this.onNearEnd,
    this.footer,
    this.autofocus = false,
  });

  final List<MediaItem> items;
  final TvCardOptions cards;
  final VoidCallback? onNearEnd;

  /// Below the last grid row: a loading ring while another page loads.
  final Widget? footer;
  final bool autofocus;

  @override
  State<TvMediaGrid> createState() => _TvMediaGridState();
}

class _TvMediaGridState extends State<TvMediaGrid> {
  final _scroll = ScrollController();

  static const _rowExtent =
      TvPosterMetrics.height + TvPosterMetrics.gap + 6; // + main-axis gap

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _columns(double width) => math.max(
    1,
    ((width - 24 + TvPosterMetrics.gap) /
            (TvPosterMetrics.width + TvPosterMetrics.gap))
        .floor(),
  );

  void _onCardFocus(int index, int columns, bool focused) {
    if (!focused) return;
    widget.cards.onFocusItem?.call(widget.items[index]);
    if (_scroll.hasClients) {
      final target = math.min(
        (index ~/ columns) * _rowExtent,
        _scroll.position.maxScrollExtent,
      );
      _scroll.animateTo(
        target,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    final onNearEnd = widget.onNearEnd;
    if (onNearEnd != null && index >= widget.items.length - columns * 2) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) onNearEnd();
      });
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = _columns(constraints.maxWidth);
      final cards = widget.cards;
      return FocusTraversalGroup(
        policy: tvSelfScrollingTraversal,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                12,
                TvPosterMetrics.focusPadding,
                12,
                0,
              ),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: TvPosterMetrics.height,
                  crossAxisSpacing: TvPosterMetrics.gap,
                  mainAxisSpacing: TvPosterMetrics.gap + 6,
                ),
                itemCount: widget.items.length,
                itemBuilder: (context, index) {
                  final item = widget.items[index];
                  return Align(
                    alignment: Alignment.topLeft,
                    child: TvPosterCard(
                      item: item,
                      autofocus: widget.autofocus && index == 0,
                      progress: cards.progressOf?.call(item) ?? 0,
                      isFavorite: cards.isFavorite?.call(item) ?? false,
                      onSelect: () => cards.onOpen(item),
                      onFocusChange: (focused) =>
                          _onCardFocus(index, columns, focused),
                    ),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
                child: widget.footer ?? const SizedBox.shrink(),
              ),
            ),
            // Lets the last grid row scroll up to the top like the others.
            SliverToBoxAdapter(
              child: SizedBox(
                height: math.max(0, constraints.maxHeight - _rowExtent - 20),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// A centered notice with an optional action, for empty and failed pages.
class TvMessage extends StatelessWidget {
  const TvMessage({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: GlassTheme.muted),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: GlassTheme.muted, height: 1.4),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 18),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}
