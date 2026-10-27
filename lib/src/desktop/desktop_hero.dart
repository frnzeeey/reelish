import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_item.dart';
import '../theme/glass_theme.dart';
import '../widgets/poster_image.dart';
import 'desktop_widgets.dart';
import '../widgets/brand_logo.dart';

/// The featured titles at the top of desktop Home: one full-bleed backdrop
/// with the title, synopsis and actions on its left, and every Spotlight
/// title in a rail along its foot, the one shown first and widest. Rotates
/// every 8 s while Home is shown and pauses while the pointer is over it or
/// the keyboard or gamepad focus is inside it; a card in the rail shows its
/// title at once.
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

  @override
  State<DesktopHero> createState() => _DesktopHeroState();
}

class _DesktopHeroState extends State<DesktopHero> {
  static const _interval = Duration(seconds: 8);

  /// The height the label, title, metadata, synopsis and actions need,
  /// with a margin above.
  static const _textRoom = 430.0;

  /// The shortest the rail's cards get; a narrower window scrolls the rail.
  static const _minCard = 96.0;
  int _index = 0;

  /// Steps moved in all, never wrapping; [_index] is it modulo the count.
  int _rotation = 0;
  bool _hovered = false;

  /// Focus is on one of the hero's controls or rail cards.
  bool _focusWithin = false;
  Timer? _timer;
  final _rail = ScrollController();

  /// Paused for a pointer over the hero, or for keyboard or gamepad focus
  /// inside it, so the title never changes under the control being used.
  /// A mouse click leaves focus where it was, so only a visible focus
  /// highlight counts.
  bool get _paused =>
      _hovered ||
      (_focusWithin &&
          FocusManager.instance.highlightMode ==
              FocusHighlightMode.traditional);

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
    if (widget.items.isNotEmpty && _rotation % widget.items.length != _index) {
      _rotation = _index;
    }
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
    _rail.dispose();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted || _paused || widget.items.length < 2) return;
      if (MediaQuery.disableAnimationsOf(context)) return;
      // Another page is shown: no rotating, and so no loading, unseen.
      if (!TickerMode.valuesOf(context).enabled) return;
      _select((_index + 1) % widget.items.length);
    });
  }

  void _show(int index) {
    _select(index);
    _schedule();
  }

  /// Shows [index]. The rail always starts at the shown title, so it
  /// scrolls back to its start.
  void _select(int index) {
    final n = widget.items.length;
    setState(() {
      // Forward only, so the strip always moves the same way.
      _rotation += (index - _index) % n;
      _index = index;
    });
    if (!_rail.hasClients || _rail.offset == 0) return;
    final duration = desktopMotion(context, 480);
    if (duration == Duration.zero) {
      _rail.jumpTo(0);
    } else {
      unawaited(
        _rail.animateTo(0, duration: duration, curve: DesktopSurfaces.curve),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final item = widget.items[_index];
    final rail = widget.items.length > 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = MediaQuery.sizeOf(context);
        final width = constraints.maxWidth;
        const pad = DesktopMetrics.pagePadding;
        // Posters and the shown title's backdrop share one height, as one
        // strip; the shown card is wide, the rest are posters. Sized so the
        // whole strip fits the width; only below [_minCard] does it scroll.
        final others = widget.items.length - 1;
        final fit =
            (width - pad * 2 - others * _SpotlightRail.gap) /
            (16 / 9 + others * 2 / 3);
        final cardHeight = fit.clamp(_minCard, 260.0);
        final posterWidth = cardHeight * 2 / 3;
        final railHeight = rail ? _SpotlightRail.heightFor(cardHeight) : 0.0;
        // Tall enough that the text never meets the rail, short enough
        // that the next row still begins near the fold.
        final height = rail
            ? math.max(
                (viewport.height * .86).clamp(600.0, 1100.0),
                // Never so short that the text would rise out of the top.
                railHeight + 28 + _textRoom,
              )
            : (viewport.height * .62).clamp(380.0, 720.0);
        // The text keeps to the left ~38%; the artwork leads.
        final textWidth = math.min(
          (width * .38).clamp(420.0, 640.0),
          width - pad * 2,
        );
        return MouseRegion(
          onEnter: (_) => _hovered = true,
          onExit: (_) => _hovered = false,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (value) => _focusWithin = value,
            child: SizedBox(
              height: height,
              width: width,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // One surface: the artwork runs under the rail and fades
                  // into the page there.
                  AnimatedSwitcher(
                    duration: desktopMotion(context, 700),
                    switchInCurve: DesktopSurfaces.curve,
                    child: _Backdrop(
                      key: ValueKey('${item.type}:${item.id}'),
                      item: item,
                      width: width,
                      railShare: railHeight / height,
                    ),
                  ),
                  Positioned(
                    left: pad,
                    bottom: rail ? railHeight + 28 : 48,
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
                  if (rail)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: railHeight,
                      child: _SpotlightRail(
                        items: widget.items,
                        index: _index,
                        rotation: _rotation,
                        controller: _rail,
                        posterWidth: posterWidth,
                        cardHeight: cardHeight,
                        onShow: _show,
                        onOpenShown: () => widget.onDetails(item),
                        onPlayShown: () => widget.onPlay(item),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({
    super.key,
    required this.item,
    required this.width,
    required this.railShare,
  });

  final MediaItem item;
  final double width;

  /// The share of the height the rail takes at the foot, where the artwork
  /// gives way to the page.
  final double railShare;

  @override
  Widget build(BuildContext context) {
    final image = item.background.isNotEmpty ? item.background : item.poster;
    final rail = railShare.clamp(0.0, .5);
    return Stack(
      fit: StackFit.expand,
      children: [
        // The artwork stops just short of the hero's foot, where the fade
        // is already solid: at a fractional height its last, antialiased
        // row would otherwise show through as a line.
        Positioned.fill(
          bottom: 2,
          child: Stack(
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
            ],
          ),
        ),
        // The text side darkened for contrast, eased off by the middle so
        // the artwork leads.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0xF20B0B0F),
                Color(0xC70B0B0F),
                Color(0x590B0B0F),
                Color(0x000B0B0F),
              ],
              stops: [0, .22, .44, .66],
            ),
          ),
        ),
        // The far edge darkened a little, so the eye stays on the picture.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerRight,
              end: Alignment.centerLeft,
              colors: [Color(0x660B0B0F), Color(0x000B0B0F)],
              stops: [0, .2],
            ),
          ),
        ),
        // The top softened; the foot fades through the rail into the page,
        // solid before the edge, so the next row continues the surface.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: const [
                Color(0x590B0B0F),
                Color(0x000B0B0F),
                Color(0x000B0B0F),
                Color(0xB30B0B0F),
                GlassTheme.background,
                GlassTheme.background,
              ],
              stops: [
                0,
                .16,
                math.max(.17, 1 - rail - .22),
                1 - rail * .7,
                1 - rail * .12,
                1,
              ],
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

  /// Every action's height.
  static const button = 52.0;

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
    // One height and shape for every action, so they read as a set.
    final shape = const StadiumBorder();
    WidgetStateProperty<BorderSide?> side(double rest) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? BorderSide(color: GlassTheme.coralBright, width: 2)
              : BorderSide(
                  color: Colors.white.withValues(
                    alpha: states.contains(WidgetState.hovered)
                        ? rest + .2
                        : rest,
                  ),
                ),
        );
    final secondary = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, _HeroText.button)),
      fixedSize: const WidgetStatePropertyAll(
        Size.fromHeight(_HeroText.button),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 22),
      ),
      shape: WidgetStatePropertyAll(shape),
      foregroundColor: const WidgetStatePropertyAll(Colors.white),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => Colors.white.withValues(
          alpha: states.contains(WidgetState.pressed)
              ? .2
              : states.contains(WidgetState.hovered)
              ? .16
              : .1,
        ),
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      side: side(.22),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The Reelish wordmark, then the section's name.
        Row(
          children: [
            const ReelishWordmark(height: 11),
            const SizedBox(width: 9),
            Text(
              'SPOTLIGHT',
              style: TextStyle(
                color: GlassTheme.coralBright,
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (logo.isEmpty) title else _logo(context, title),
        const SizedBox(height: 16),
        Row(
          children: [
            if (hasRating) ...[
              // The rating leads, in a quiet glass chip.
              Container(
                padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .14),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.star_rounded,
                      fill: 1,
                      size: 16,
                      color: GlassTheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.rating,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
            ],
            if (series && item.hasRecentEpisode) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: GlassTheme.primary.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: GlassTheme.primary.withValues(alpha: .4),
                  ),
                ),
                child: Text(
                  'NEW EPISODES',
                  style: TextStyle(
                    color: GlassTheme.coralBright,
                    fontSize: 10.5,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w800,
                  ),
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
          // A comfortable line length, whatever the window's width.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              item.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                height: 1.6,
                color: Color(0xCCFFFFFF),
                shadows: [Shadow(color: Color(0x80000000), blurRadius: 12)],
              ),
            ),
          ),
        ],
        const SizedBox(height: 26),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: onPlay,
              style: secondary.copyWith(
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 28),
                ),
                // Dark on the accent, as on phone and TV: white on coral
                // is 3.2:1, below the 4.5:1 text needs.
                foregroundColor: const WidgetStatePropertyAll(
                  GlassTheme.background,
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.pressed)
                      ? Color.alphaBlend(
                          Colors.black.withValues(alpha: .12),
                          GlassTheme.primary,
                        )
                      : states.contains(WidgetState.hovered)
                      ? Color.alphaBlend(
                          Colors.white.withValues(alpha: .1),
                          GlassTheme.primary,
                        )
                      : GlassTheme.primary,
                ),
                side: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.focused)
                      ? const BorderSide(color: Colors.white, width: 2)
                      : BorderSide.none,
                ),
                elevation: const WidgetStatePropertyAll(0),
              ),
              icon: Icon(
                series ? Symbols.view_list_rounded : Symbols.play_arrow_rounded,
                fill: 1,
                size: 24,
              ),
              label: Text(
                series ? 'Episodes' : 'Play',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onDetails,
              style: secondary,
              icon: const Icon(Symbols.info_rounded, size: 22),
              label: const Text(
                'More info',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton.outlined(
              tooltip: favorite ? 'Remove from My list' : 'Add to My list',
              onPressed: onToggleFavorite,
              style: secondary.copyWith(
                fixedSize: const WidgetStatePropertyAll(
                  Size.square(_HeroText.button),
                ),
                minimumSize: const WidgetStatePropertyAll(
                  Size.square(_HeroText.button),
                ),
                shape: const WidgetStatePropertyAll(CircleBorder()),
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              ),
              icon: AnimatedSwitcher(
                duration: desktopMotion(context, 200),
                child: Icon(
                  favorite ? Symbols.check_rounded : Symbols.add_rounded,
                  key: ValueKey(favorite),
                ),
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
        // The name until the logo's first frame; then the logo fades in.
        frameBuilder: (context, child, frame, synchronous) => synchronous
            ? child
            : frame == null
            ? ExcludeSemantics(child: title)
            : TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: desktopMotion(context, 360),
                curve: DesktopSurfaces.curve,
                builder: (context, opacity, child) =>
                    Opacity(opacity: opacity, child: child),
                child: child,
              ),
        errorBuilder: (_, _, _) => ExcludeSemantics(child: title),
      ),
    ),
  );
}

/// Every Spotlight title in order, along the hero's foot, as one strip of
/// equal height: the shown title first, as a wide backdrop card with its name,
/// details and a play button, then the titles after it as posters, round to
/// the first again. A counter shows where the rotation is.
class _SpotlightRail extends StatelessWidget {
  const _SpotlightRail({
    required this.items,
    required this.index,
    required this.rotation,
    required this.controller,
    required this.posterWidth,
    required this.cardHeight,
    required this.onShow,
    required this.onOpenShown,
    required this.onPlayShown,
  });

  static const gap = 12.0;
  static const _headerHeight = 36.0;

  /// Above and below the cards: room for a hovered card to lift unclipped,
  /// and the page's breathing space under the rail.
  static const _lift = 10.0, _foot = 24.0;

  static double heightFor(double cardHeight) =>
      _headerHeight + _lift + cardHeight + _foot;

  final List<MediaItem> items;
  final int index;

  /// Steps the Spotlight has moved in all, never wrapping; [index] is it
  /// modulo the count. It numbers the places in an endless strip.
  final int rotation;
  final ScrollController controller;
  final double posterWidth;
  final double cardHeight;
  final ValueChanged<int> onShow;
  final VoidCallback onOpenShown;
  final VoidCallback onPlayShown;

  /// How long the strip takes to move on, cards and widths together.
  static const moveMs = 460;

  double get _wide => cardHeight * 16 / 9;

  /// The card at [slot] (−1 for the one leaving). Each card is keyed by its
  /// place in the endless strip, which stays the same as it moves forward,
  /// so it slides to its new spot (and the newly shown one widens) instead
  /// of being redrawn there. A title that wraps round gets a new place at
  /// the end and fades in, rather than crossing the whole row.
  Widget _placed(BuildContext context, {required int slot}) {
    final n = items.length;
    final i = (index + slot) % n;
    final leaving = slot < 0;
    final duration = desktopMotion(context, moveMs);
    final left = switch (slot) {
      < 0 => -(posterWidth + gap),
      0 => 0.0,
      _ => _wide + gap + (slot - 1) * (posterWidth + gap),
    };
    return AnimatedPositioned(
      key: ValueKey(rotation + slot),
      duration: duration,
      curve: DesktopSurfaces.curve,
      left: left,
      bottom: 0,
      // One structure for every card, leaving or not, so a card keeps its
      // state (and animates) as it turns into the leaving one.
      child: IgnorePointer(
        ignoring: leaving,
        child: ExcludeFocus(
          excluding: leaving,
          child: ExcludeSemantics(
            excluding: leaving,
            child: AnimatedOpacity(
              opacity: leaving ? 0 : 1,
              duration: duration,
              curve: DesktopSurfaces.curve,
              child: _FadeInOnce(
                child: _SpotlightCard(
                  item: items[i],
                  shown: slot == 0,
                  leaving: leaving,
                  width: slot == 0 ? _wide : posterWidth,
                  height: cardHeight,
                  onTap: slot == 0 ? onOpenShown : () => onShow(i),
                  onPlay: onPlayShown,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const pad = DesktopMetrics.pagePadding;
    final wide = _wide;
    return FocusTraversalGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _headerHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: pad),
              child: Row(
                children: [
                  // The compact Reelish mark heads Reelish's own picks.
                  const ReelishMark(height: 15),
                  const SizedBox(width: 9),
                  const Text(
                    'In the Spotlight',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  // Where the rotation is, at a glance; the counter says it.
                  ExcludeSemantics(
                    child: Row(
                      children: [
                        for (var i = 0; i < items.length; i++)
                          AnimatedContainer(
                            duration: desktopMotion(context, 260),
                            curve: DesktopSurfaces.curve,
                            width: i == index ? 22 : 6,
                            height: 3,
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(
                              color: i == index
                                  ? GlassTheme.primary
                                  : Colors.white.withValues(alpha: .28),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${index + 1}'.padLeft(2, '0'),
                          style: const TextStyle(color: Colors.white),
                        ),
                        TextSpan(
                          text: '  /  ${'${items.length}'.padLeft(2, '0')}',
                        ),
                      ],
                    ),
                    style: const TextStyle(
                      fontSize: 12,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w800,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: _lift + cardHeight,
            child: SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: pad),
              child: SizedBox(
                width: wide + (items.length - 1) * (posterWidth + gap),
                height: _lift + cardHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // The title just shown slides out to the left,
                    // narrowing and fading, as the next one takes its place.
                    _placed(context, slot: -1),
                    for (var slot = 0; slot < items.length; slot++)
                      _placed(context, slot: slot),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpotlightCard extends StatefulWidget {
  const _SpotlightCard({
    required this.item,
    required this.shown,
    this.leaving = false,
    required this.width,
    required this.height,
    required this.onTap,
    required this.onPlay,
  });

  final MediaItem item;

  /// The title the hero shows: its backdrop, name, details and a play
  /// button; a click elsewhere on it opens its details.
  final bool shown;

  /// The card sliding out after its title was shown: no tooltip.
  final bool leaving;
  final double width;
  final double height;
  final VoidCallback onTap;

  /// The shown card's play button: Play, or Episodes for a series.
  final VoidCallback onPlay;

  @override
  State<_SpotlightCard> createState() => _SpotlightCardState();
}

class _SpotlightCardState extends State<_SpotlightCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final shown = widget.shown;
    final lifted = _hovered || _focused;
    final duration = desktopMotion(context, _SpotlightRail.moveMs);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // The shown card is landscape: the backdrop. The rest are posters.
    final image = shown
        ? (item.background.isNotEmpty ? item.background : item.poster)
        : (item.poster.isNotEmpty ? item.poster : item.background);
    final radius = BorderRadius.circular(14);
    // Below this the details line would be cut to a word or two.
    final compact = widget.height < 130;
    return Tooltip(
      message: widget.leaving
          ? ''
          : shown
          ? 'More about ${item.name}'
          : 'Show ${item.name}',
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
            selected: shown,
            label: shown ? 'Now showing, ${item.name}' : item.name,
            child: AnimatedSlide(
              // A small lift on hover: the cards stay second to the hero.
              offset: Offset(0, lifted ? -.03 : 0),
              duration: desktopMotion(context, 200),
              curve: DesktopSurfaces.curve,
              child: AnimatedContainer(
                duration: duration,
                curve: DesktopSurfaces.curve,
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: lifted ? .55 : .35),
                      blurRadius: lifted ? 20 : 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: _focused
                        ? GlassTheme.coralBright
                        : Colors.white.withValues(alpha: lifted ? .35 : .08),
                    width: _focused ? 2 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const PosterPlaceholder(iconSize: 22),
                      // Cross-fades as the card turns from poster to
                      // backdrop and back.
                      AnimatedSwitcher(
                        duration: duration,
                        child: image.isEmpty
                            ? const SizedBox.shrink()
                            : Image.network(
                                image,
                                key: ValueKey(image),
                                fit: BoxFit.cover,
                                width: double.infinity,
                                height: double.infinity,
                                // Decoded at the size drawn: the backdrop's
                                // width, or the poster's.
                                cacheWidth: posterDecodeWidth(
                                  (shown
                                          ? widget.height * 16 / 9
                                          : widget.height * 2 / 3) *
                                      dpr,
                                ),
                                frameBuilder: posterFadeIn(context),
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                      ),
                      if (shown)
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x00000000), Color(0xD9000000)],
                              stops: [.35, 1],
                            ),
                          ),
                        ),
                      if (shown)
                        Positioned(
                          left: compact ? 10 : 16,
                          right: compact ? 8 : 14,
                          bottom: compact ? 8 : 14,
                          child: _ShownDetails(
                            // Fades in again for each new title.
                            key: ValueKey('${item.type}:${item.id}'),
                            item: item,
                            onPlay: widget.onPlay,
                            compact: compact,
                          ),
                        )
                      // Without a poster, the name stands in for it.
                      else if (item.poster.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Align(
                            alignment: Alignment.bottomLeft,
                            child: Text(
                              item.name,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
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
    );
  }
}

/// The shown card's foot: its name, a details line (rating, year, type and
/// genres, whichever are known) and a round play button.
class _ShownDetails extends StatelessWidget {
  const _ShownDetails({
    super.key,
    required this.item,
    required this.onPlay,
    this.compact = false,
  });

  final MediaItem item;
  final VoidCallback onPlay;

  /// A short card (a small window): the name and button only, smaller.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final series = item.type == 'series';
    final hasRating = item.rating.isNotEmpty && item.rating != '0.0';
    final genres = [for (final id in item.genreIds) ?_genres[id]].take(2);
    final details = [
      if (item.year.isNotEmpty) item.year,
      series ? 'Series' : 'Movie',
      if (genres.isNotEmpty) genres.join(', '),
    ].join('  |  ');
    return _FadeInOnce(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 13.5 : 17,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        // The app's star, not a "★" the font may not have.
                        if (hasRating) ...[
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Symbols.star_rounded,
                                fill: 1,
                                size: 13,
                                color: GlassTheme.primary,
                              ),
                            ),
                          ),
                          TextSpan(text: '${item.rating}  |  '),
                        ],
                        TextSpan(text: details),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: compact ? 8 : 12),
          IconButton.filled(
            tooltip: series ? 'Episodes' : 'Play',
            onPressed: onPlay,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              hoverColor: Colors.black.withValues(alpha: .08),
              fixedSize: Size.square(compact ? 34 : 44),
              minimumSize: Size.square(compact ? 34 : 44),
              padding: EdgeInsets.zero,
            ),
            icon: Icon(
              series ? Symbols.view_list_rounded : Symbols.play_arrow_rounded,
              fill: 1,
              size: compact ? 21 : 26,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades its child in once, after the card has begun to widen, so the
/// details never show squeezed.
class _FadeInOnce extends StatelessWidget {
  const _FadeInOnce({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: desktopMotion(context, 420),
    curve: const Interval(.45, 1, curve: Curves.easeOut),
    builder: (context, opacity, child) =>
        Opacity(opacity: opacity, child: child),
    child: child,
  );
}
