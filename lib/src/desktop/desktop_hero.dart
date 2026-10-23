import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_item.dart';
import '../theme/glass_theme.dart';
import '../widgets/poster_image.dart';
import 'desktop_widgets.dart';

/// The featured titles at the top of desktop Home: a wide backdrop with the
/// title, synopsis and actions, and the next titles as preview cards in its
/// lower right corner. Rotates every 8 s while Home is shown, pauses while
/// the pointer is over it, and a preview shows its title at once.
class DesktopHero extends StatefulWidget {
  const DesktopHero({
    super.key,
    required this.items,
    required this.onPlay,
    required this.onDetails,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.logoOf,
  });

  final List<MediaItem> items;

  /// A title's logo artwork URL, or '' for none; the name is drawn as text
  /// until a logo has loaded, and instead of one that fails.
  final Future<String> Function(MediaItem item)? logoOf;

  /// Movies start playback; series open their episodes.
  final ValueChanged<MediaItem> onPlay;
  final ValueChanged<MediaItem> onDetails;
  final bool Function(MediaItem item) isFavorite;
  final Future<bool> Function(MediaItem item) onToggleFavorite;

  /// Preview cards at most; fewer when the window is narrow.
  static const maxPreviews = 3;

  @override
  State<DesktopHero> createState() => _DesktopHeroState();
}

class _DesktopHeroState extends State<DesktopHero> {
  static const _interval = Duration(seconds: 8);
  int _index = 0;
  bool _hovered = false;
  Timer? _timer;

  /// Logo URLs by title, '' for none; asked once per title.
  final Map<String, String> _logos = {};

  static String _key(MediaItem item) => '${item.type}:${item.id}';

  @override
  void initState() {
    super.initState();
    _schedule();
    _loadLogos();
  }

  @override
  void didUpdateWidget(covariant DesktopHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.items.length) _index = 0;
    _loadLogos();
  }

  void _loadLogos() {
    final logoOf = widget.logoOf;
    if (logoOf == null) return;
    for (final item in widget.items) {
      final key = _key(item);
      if (_logos.containsKey(key)) continue;
      _logos[key] = '';
      unawaited(
        logoOf(item).then(
          (url) {
            if (mounted && url.isNotEmpty) setState(() => _logos[key] = url);
          },
          // Decoration: the name stays as text.
          onError: (Object _) {},
        ),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted || _hovered || widget.items.length < 2) return;
      if (MediaQuery.disableAnimationsOf(context)) return;
      // Another page is shown: no rotating, and so no loading, unseen.
      if (!TickerMode.valuesOf(context).enabled) return;
      setState(() => _index = (_index + 1) % widget.items.length);
    });
  }

  void _show(int index) {
    setState(() => _index = index);
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final item = widget.items[_index];
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = MediaQuery.sizeOf(context);
        final height = (viewport.height * .62).clamp(380.0, 720.0);
        final width = constraints.maxWidth;
        const pad = DesktopMetrics.pagePadding;
        final textWidth = math.min(
          (width * .46).clamp(400.0, 680.0),
          width - pad * 2,
        );
        // Previews fill the room right of the text, never under it.
        final cardWidth = (width * .12).clamp(168.0, 220.0);
        final room = width - pad - textWidth - 48 - pad;
        final previews = widget.items.length < 2
            ? 0
            : [
                DesktopHero.maxPreviews,
                widget.items.length - 1,
                ((room + _PreviewCard.gap) / (cardWidth + _PreviewCard.gap))
                    .floor(),
              ].reduce(math.min).clamp(0, DesktopHero.maxPreviews);
        return MouseRegion(
          onEnter: (_) => _hovered = true,
          onExit: (_) => _hovered = false,
          child: SizedBox(
            height: height,
            width: width,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedSwitcher(
                  duration: desktopMotion(context, 700),
                  switchInCurve: DesktopSurfaces.curve,
                  child: _Backdrop(
                    key: ValueKey('${item.type}:${item.id}'),
                    item: item,
                    width: width,
                  ),
                ),
                Positioned(
                  left: pad,
                  bottom: 48,
                  width: textWidth,
                  child: AnimatedSwitcher(
                    duration: desktopMotion(context, 480),
                    // Old text fades out before the new one rises in, so
                    // the two titles never overlap.
                    switchInCurve: const Interval(
                      .45,
                      1,
                      curve: Curves.easeOutCubic,
                    ),
                    switchOutCurve: const Interval(.5, 1),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, .04),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.bottomLeft,
                      children: [...previous, ?current],
                    ),
                    child: _HeroText(
                      key: ValueKey('text:${item.type}:${item.id}'),
                      item: item,
                      logo: _logos[_key(item)] ?? '',
                      favorite: widget.isFavorite(item),
                      onPlay: () => widget.onPlay(item),
                      onDetails: () => widget.onDetails(item),
                      onToggleFavorite: () async {
                        await widget.onToggleFavorite(item);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
                if (previews > 0)
                  Positioned(
                    right: pad,
                    bottom: 48,
                    child: _Previews(
                      items: widget.items,
                      index: _index,
                      count: previews,
                      cardWidth: cardWidth,
                      onShow: _show,
                    ),
                  )
                else if (widget.items.length > 1)
                  // Too narrow for previews: the dots still step through.
                  Positioned(
                    right: pad,
                    bottom: 56,
                    child: Row(
                      children: [
                        for (var i = 0; i < widget.items.length; i++)
                          _Dot(
                            active: i == _index,
                            label: 'Show ${widget.items[i].name}',
                            onTap: () => _show(i),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({super.key, required this.item, required this.width});

  final MediaItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    final image = item.background.isNotEmpty ? item.background : item.poster;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: GlassTheme.surface),
        if (image.isNotEmpty)
          Image.network(
            image,
            fit: BoxFit.cover,
            alignment: const Alignment(0, -.3),
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .round(),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        // Text side darkened for contrast; the bottom fades into the page.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xF00B0B0F), Color(0x8C0B0B0F), Color(0x000B0B0F)],
              stops: [0, .4, .75],
            ),
          ),
        ),
        // A soft light behind the previews' corner, so they sit in the
        // picture rather than on it.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(1, 1),
              radius: 1.1,
              colors: [Color(0x990B0B0F), Color(0x000B0B0F)],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // Solid before the edge, so the image's last pixel row never
              // shows as a line.
              colors: [
                Color(0x400B0B0F),
                Color(0x000B0B0F),
                Color(0x000B0B0F),
                GlassTheme.background,
                GlassTheme.background,
              ],
              stops: [0, .18, .58, .95, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// TMDB's genre names by id, movie and TV lists together, for the hero's
/// metadata line. The ids are TMDB's stable public list.
const _genres = {
  28: 'Action',
  12: 'Adventure',
  16: 'Animation',
  35: 'Comedy',
  80: 'Crime',
  99: 'Documentary',
  18: 'Drama',
  10751: 'Family',
  14: 'Fantasy',
  36: 'History',
  27: 'Horror',
  10402: 'Music',
  9648: 'Mystery',
  10749: 'Romance',
  878: 'Sci-Fi',
  10770: 'TV Movie',
  53: 'Thriller',
  10752: 'War',
  37: 'Western',
  10759: 'Action & Adventure',
  10762: 'Kids',
  10763: 'News',
  10764: 'Reality',
  10765: 'Sci-Fi & Fantasy',
  10766: 'Soap',
  10767: 'Talk',
  10768: 'War & Politics',
};

class _HeroText extends StatelessWidget {
  const _HeroText({
    super.key,
    required this.item,
    required this.favorite,
    required this.onPlay,
    required this.onDetails,
    required this.onToggleFavorite,
    this.logo = '',
  });

  final MediaItem item;
  final String logo;
  final bool favorite;
  final VoidCallback onPlay;
  final VoidCallback onDetails;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final series = item.type == 'series';
    final genres = [for (final id in item.genreIds) ?_genres[id]].take(2);
    final hasRating = item.rating.isNotEmpty && item.rating != '0.0';
    final title = Text(
      item.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 50,
        height: 1.02,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.4,
        shadows: [Shadow(color: Color(0x66000000), blurRadius: 24)],
      ),
    );
    final meta = [
      if (item.year.isNotEmpty) item.year,
      series ? 'Series' : 'Movie',
      ...genres,
    ].join('  ·  ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 18,
              height: 2,
              margin: const EdgeInsets.only(right: 10),
              color: GlassTheme.primary,
            ),
            Text(
              'REELISH SPOTLIGHT',
              style: TextStyle(
                color: GlassTheme.coralBright,
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (logo.isEmpty) title else _logo(context, title),
        const SizedBox(height: 12),
        Row(
          children: [
            if (hasRating) ...[
              Icon(
                Symbols.star_rounded,
                fill: 1,
                size: 17,
                color: GlassTheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                item.rating,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 14),
            ],
            Flexible(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                ),
              ),
            ),
          ],
        ),
        if (item.description.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            item.description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              height: 1.55,
              color: Color(0xD9FFFFFF),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: onPlay,
              style: FilledButton.styleFrom(
                backgroundColor: GlassTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 18,
                ),
              ),
              icon: Icon(
                series ? Symbols.view_list_rounded : Symbols.play_arrow_rounded,
                fill: 1,
              ),
              label: Text(
                series ? 'Episodes' : 'Play',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onDetails,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: .1),
                side: BorderSide(color: Colors.white.withValues(alpha: .28)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 18,
                ),
              ),
              icon: const Icon(Symbols.info_rounded),
              label: const Text(
                'More info',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton.outlined(
              tooltip: favorite ? 'Remove from My list' : 'Add to My list',
              onPressed: onToggleFavorite,
              style: IconButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: .1),
                side: BorderSide(color: Colors.white.withValues(alpha: .28)),
                padding: const EdgeInsets.all(14),
              ),
              icon: Icon(
                favorite ? Symbols.check_rounded : Symbols.add_rounded,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

extension on _HeroText {
  /// The logo artwork, read out as the title; [title] (not read a second
  /// time) until it has loaded and in place of one that fails.
  Widget _logo(BuildContext context, Widget title) => Semantics(
    // Its own node, so only the logo is the heading.
    container: true,
    header: true,
    label: item.name,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460, maxHeight: 128),
      child: Image.network(
        logo,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        excludeFromSemantics: true,
        cacheWidth: posterDecodeWidth(
          460 * MediaQuery.devicePixelRatioOf(context),
        ),
        frameBuilder: (context, child, frame, synchronous) =>
            frame == null && !synchronous
            ? ExcludeSemantics(child: title)
            : child,
        errorBuilder: (_, _, _) => ExcludeSemantics(child: title),
      ),
    ),
  );
}

/// The next [count] titles after [index], as cards; the first is labelled
/// Up next. A counter above shows where the rotation is.
class _Previews extends StatelessWidget {
  const _Previews({
    required this.items,
    required this.index,
    required this.count,
    required this.cardWidth,
    required this.onShow,
  });

  final List<MediaItem> items;
  final int index;
  final int count;
  final double cardWidth;
  final ValueChanged<int> onShow;

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${index + 1}'.padLeft(2, '0'),
                style: const TextStyle(color: Colors.white),
              ),
              TextSpan(text: '  /  ${'${items.length}'.padLeft(2, '0')}'),
            ],
          ),
          style: const TextStyle(
            fontSize: 12,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w800,
            color: Colors.white54,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var k = 1; k <= count; k++) ...[
              if (k > 1) const SizedBox(width: _PreviewCard.gap),
              _PreviewCard(
                // Keyed by slot: a card cross-fades to its new title.
                key: ValueKey('preview:$k'),
                item: items[(index + k) % items.length],
                upNext: k == 1,
                width: cardWidth,
                onTap: () => onShow((index + k) % items.length),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

class _PreviewCard extends StatefulWidget {
  const _PreviewCard({
    super.key,
    required this.item,
    required this.upNext,
    required this.width,
    required this.onTap,
  });

  static const gap = 12.0;

  final MediaItem item;
  final bool upNext;
  final double width;
  final VoidCallback onTap;

  @override
  State<_PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<_PreviewCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final lifted = _hovered || _focused;
    final duration = desktopMotion(context);
    final image = item.background.isNotEmpty ? item.background : item.poster;
    final radius = BorderRadius.circular(12);
    return Tooltip(
      message: 'Show ${item.name}',
      waitDuration: const Duration(milliseconds: 600),
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Semantics(
            button: true,
            label: '${widget.upNext ? 'Up next' : 'Coming up'}, ${item.name}',
            excludeSemantics: true,
            child: AnimatedScale(
              scale: lifted ? 1.04 : 1,
              duration: duration,
              curve: DesktopSurfaces.curve,
              child: AnimatedContainer(
                duration: duration,
                width: widget.width,
                height: widget.width * 9 / 16,
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: lifted ? .6 : .4),
                      blurRadius: lifted ? 22 : 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: _focused
                        ? GlassTheme.coralBright
                        : widget.upNext
                        ? GlassTheme.primary.withValues(alpha: .7)
                        : Colors.white.withValues(alpha: lifted ? .45 : .16),
                    width: _focused ? 2.5 : 1.2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: AnimatedSwitcher(
                    duration: desktopMotion(context, 420),
                    child: Stack(
                      key: ValueKey('${item.type}:${item.id}'),
                      fit: StackFit.expand,
                      children: [
                        const PosterPlaceholder(iconSize: 22),
                        if (image.isNotEmpty)
                          Image.network(
                            image,
                            fit: BoxFit.cover,
                            cacheWidth: posterDecodeWidth(
                              widget.width *
                                  MediaQuery.devicePixelRatioOf(context),
                            ),
                            frameBuilder: posterFadeIn(context),
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x00000000), Color(0xE6000000)],
                              stops: [.35, 1],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 8,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.upNext)
                                Text(
                                  'UP NEXT',
                                  style: TextStyle(
                                    color: GlassTheme.coralBright,
                                    fontSize: 9.5,
                                    letterSpacing: 1.4,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active, required this.label, required this.onTap});

  final bool active;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: InkWell(
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: AnimatedContainer(
          duration: desktopMotion(context, 220),
          width: active ? 26 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active
                ? GlassTheme.primary
                : Colors.white.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    ),
  );
}
