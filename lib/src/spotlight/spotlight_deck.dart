// The phone Spotlight's carousel: a PageView whose cards a
// [SpotlightMotionStyle] places by their distance from the centre. Motion
// follows the scroll position itself, so a swipe, an automatic turn and a
// fling all drive the same frames, and nothing can run two transitions at
// once. Each card works its frame out once per tick; inside the card only
// [SpotlightZoom] and [SpotlightReveal] rebuild, never the card's content.
//
// A card has two layers. The body (artwork, scrim) turns, scales and lifts
// with the style. The foreground (title, details, buttons) only follows the
// body's corner, never scaled or turned: text drawn under a changing scale
// or perspective is redrawn glyph by glyph every frame, which measured at
// about twice the old carousel's cost on a device. Its lines appear by a
// wipe (a clip), not a fade, for the same reason: a fading line is drawn
// off-screen first.
// The one ticker of its own is the gentle float of a style that [floats],
// running only while that style is shown.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';
import 'spotlight_motion.dart';

class SpotlightDeck extends StatefulWidget {
  const SpotlightDeck({
    super.key,
    required this.controller,
    required this.style,
    required this.itemCount,
    required this.itemBuilder,
    this.foregroundBuilder,
    this.onPageChanged,
    this.onUserScroll,
    this.borderRadius = 24,
  });

  /// Its `viewportFraction` must be [style]'s ([controllerFor]).
  final PageController controller;
  final SpotlightMotionStyle style;

  /// Null for an endless carousel.
  final int? itemCount;

  /// The card's body: artwork and scrim, moved with the style.
  final IndexedWidgetBuilder itemBuilder;

  /// The card's words and controls, drawn flat over the body and filling
  /// it; they follow the body's bottom-left corner but never scale or turn.
  final IndexedWidgetBuilder? foregroundBuilder;
  final ValueChanged<int>? onPageChanged;

  /// The person started dragging the cards.
  final VoidCallback? onUserScroll;

  /// The cards' corners, for their shadow.
  final double borderRadius;

  /// The style to show for [motion]: Minimal Motion when the system asks for
  /// reduced motion.
  static SpotlightMotionStyle styleFor(
    BuildContext context,
    SpotlightMotion motion,
  ) => MediaQuery.disableAnimationsOf(context)
      ? SpotlightMotion.minimal.style
      : motion.style;

  /// A controller for [style], starting at [page].
  static PageController controllerFor(
    SpotlightMotionStyle style, {
    int page = 0,
  }) => PageController(
    initialPage: page,
    viewportFraction: style.viewportFraction,
  );

  @override
  State<SpotlightDeck> createState() => _SpotlightDeckState();
}

class _SpotlightDeckState extends State<SpotlightDeck>
    with SingleTickerProviderStateMixin {
  AnimationController? _float;
  late Listenable _ticks;

  @override
  void initState() {
    super.initState();
    _syncFloat();
  }

  @override
  void didUpdateWidget(covariant SpotlightDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style.floats != widget.style.floats ||
        oldWidget.controller != widget.controller) {
      _syncFloat();
    }
  }

  /// A float ticker only for a style that floats.
  void _syncFloat() {
    if (widget.style.floats) {
      _float ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 6),
      )..repeat();
    } else {
      _float?.dispose();
      _float = null;
    }
    final float = _float;
    _ticks = float == null
        ? widget.controller
        : Listenable.merge([widget.controller, float]);
  }

  @override
  void dispose() {
    _float?.dispose();
    super.dispose();
  }

  double _page() {
    final controller = widget.controller;
    if (controller.hasClients &&
        controller.positions.length == 1 &&
        controller.position.hasContentDimensions) {
      return controller.page ?? controller.initialPage.toDouble();
    }
    return controller.initialPage.toDouble();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final extent = constraints.maxWidth * widget.style.viewportFraction;
      final gap = widget.style.viewportFraction < 1 ? 6.0 : 0.0;
      return NotificationListener<ScrollStartNotification>(
        onNotification: (notification) {
          if (notification.dragDetails != null) widget.onUserScroll?.call();
          return false;
        },
        child: PageView.builder(
          controller: widget.controller,
          itemCount: widget.itemCount,
          onPageChanged: widget.onPageChanged,
          // Neighbours turned or lifted out of the strip stay whole.
          clipBehavior: Clip.none,
          itemBuilder: (context, index) => Padding(
            padding: EdgeInsets.symmetric(horizontal: gap),
            child: _SpotlightCard(
              index: index,
              ticks: _ticks,
              page: _page,
              float: () => _float?.value ?? 0,
              style: widget.style,
              extent: extent,
              borderRadius: widget.borderRadius,
              onBringForward: () => unawaited(
                widget.controller.animateToPage(
                  index,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? const Duration(milliseconds: 1)
                      : const Duration(milliseconds: 650),
                  curve: Curves.easeInOutCubic,
                ),
              ),
              foreground: widget.foregroundBuilder?.call(context, index),
              child: widget.itemBuilder(context, index),
            ),
          ),
        ),
      );
    },
  );
}

class _SpotlightCard extends StatefulWidget {
  const _SpotlightCard({
    required this.index,
    required this.ticks,
    required this.page,
    required this.float,
    required this.style,
    required this.extent,
    required this.borderRadius,
    required this.onBringForward,
    required this.child,
    this.foreground,
  });

  final int index;
  final Listenable ticks;
  final double Function() page;
  final double Function() float;
  final SpotlightMotionStyle style;
  final double extent;
  final double borderRadius;

  /// A tap on a neighbour: it becomes the shown card.
  final VoidCallback onBringForward;
  final Widget child;
  final Widget? foreground;

  @override
  State<_SpotlightCard> createState() => _SpotlightCardState();
}

class _SpotlightCardState extends State<_SpotlightCard> {
  late final ValueNotifier<SpotlightCardFrame> _frame = ValueNotifier(
    _compute(),
  );

  /// The card is the shown one (more than half in the centre): only it
  /// takes taps on its own controls, and only its words are read out.
  late final ValueNotifier<bool> _shown = ValueNotifier(_isShown());

  bool _isShown() => (widget.index - widget.page()).abs() < .5;

  SpotlightCardFrame _compute() => widget.style.frame(
    widget.index - widget.page(),
    widget.extent,
    float: widget.float(),
  );

  void _tick() {
    _frame.value = _compute();
    _shown.value = _isShown();
  }

  @override
  void initState() {
    super.initState();
    widget.ticks.addListener(_tick);
  }

  @override
  void didUpdateWidget(covariant _SpotlightCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticks != widget.ticks) {
      oldWidget.ticks.removeListener(_tick);
      widget.ticks.addListener(_tick);
    }
    _tick();
  }

  @override
  void dispose() {
    widget.ticks.removeListener(_tick);
    _frame.dispose();
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    // Always the same widgets around the card, only their values changing:
    // a widget added or dropped mid-swipe would rebuild the whole card
    // (artwork, text, buttons) each time.
    final body = ValueListenableBuilder<SpotlightCardFrame>(
      valueListenable: _frame,
      child: widget.child,
      builder: (context, frame, card) {
        final emphasis = frame.emphasis.clamp(0.0, 1.0);
        final lifted = widget.style.lifted && emphasis > .01;
        // Faded toward the page colour by an overlay, not made see-through:
        // transparency draws the card off-screen first, every frame. On the
        // page's solid colour the two look the same.
        final dim = 1 - frame.opacity.clamp(0.0, 1.0);
        return Transform(
          transform: frame.transform,
          alignment: Alignment.center,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: lifted
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .42 * emphasis),
                        blurRadius: 28,
                        offset: Offset(0, 14 * emphasis),
                      ),
                      // A restrained glow in the accent around the shown
                      // card.
                      BoxShadow(
                        color: GlassTheme.primary.withValues(
                          alpha: .16 * emphasis,
                        ),
                        blurRadius: 24,
                        spreadRadius: -6,
                      ),
                    ]
                  : null,
            ),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: radius,
                color: dim > .005
                    ? GlassTheme.background.withValues(alpha: dim)
                    : null,
              ),
              child: card,
            ),
          ),
        );
      },
    );
    final foreground = widget.foreground;
    final card = foreground == null
        ? body
        : LayoutBuilder(
            builder: (context, constraints) => Stack(
              fit: StackFit.expand,
              children: [
                body,
                ValueListenableBuilder<SpotlightCardFrame>(
                  valueListenable: _frame,
                  child: foreground,
                  builder: (context, frame, words) => Transform.translate(
                    offset: _cornerShift(frame.transform, constraints.biggest),
                    child: words,
                  ),
                ),
              ],
            ),
          );
    // A neighbour's controls take no taps and its words are not read out;
    // a tap anywhere on it brings it forward.
    return _SpotlightCardScope(
      frame: _frame,
      style: widget.style,
      child: ValueListenableBuilder<bool>(
        valueListenable: _shown,
        child: card,
        builder: (context, shown, child) => GestureDetector(
          behavior: shown
              ? HitTestBehavior.deferToChild
              : HitTestBehavior.opaque,
          onTap: shown ? null : widget.onBringForward,
          child: IgnorePointer(
            ignoring: !shown,
            child: ExcludeSemantics(excluding: !shown, child: child),
          ),
        ),
      ),
    );
  }

  /// How far the body's bottom-left corner has moved under [transform]
  /// (applied about the centre of a card of [size]), so the flat foreground
  /// can follow it.
  static Offset _cornerShift(Matrix4 transform, Size size) {
    final centre = size.center(Offset.zero);
    final corner = Offset(0, size.height);
    final moved = MatrixUtils.transformPoint(transform, corner - centre);
    return moved + centre - corner;
  }
}

class _SpotlightCardScope extends InheritedWidget {
  const _SpotlightCardScope({
    required this.frame,
    required this.style,
    required super.child,
  });

  final ValueListenable<SpotlightCardFrame> frame;
  final SpotlightMotionStyle style;

  static _SpotlightCardScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SpotlightCardScope>();

  @override
  bool updateShouldNotify(_SpotlightCardScope oldWidget) =>
      frame != oldWidget.frame || style != oldWidget.style;
}

/// A card's backdrop: zoomed by its style as it moves in and out of focus.
/// Always under the same transform, so the image is never rebuilt. Outside
/// a [SpotlightDeck] it is shown as it is.
class SpotlightZoom extends StatelessWidget {
  const SpotlightZoom({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = _SpotlightCardScope.of(context);
    if (scope == null) return child;
    return ValueListenableBuilder<SpotlightCardFrame>(
      valueListenable: scope.frame,
      child: child,
      builder: (context, frame, child) =>
          Transform.scale(scale: frame.imageScale, child: child),
    );
  }
}

/// A line of a card's words, appearing as the card comes into focus: it
/// rises into view from behind its own lower edge (a wipe), after the lines
/// before it when the style staggers them ([order] 0 first). A clip, not a
/// fade, because a fading line is drawn off-screen first, every frame; at
/// rest nothing is clipped. Outside a [SpotlightDeck] it is shown as it is.
class SpotlightReveal extends StatelessWidget {
  const SpotlightReveal({super.key, required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = _SpotlightCardScope.of(context);
    if (scope == null) return child;
    return ValueListenableBuilder<SpotlightCardFrame>(
      valueListenable: scope.frame,
      child: child,
      builder: (context, frame, child) {
        final shown = Curves.easeOutCubic.transform(
          scope.style.lineReveal(frame.reveal, order).clamp(0.0, 1.0),
        );
        // The same two widgets whatever the value, so the line is never
        // rebuilt.
        return ClipRect(
          clipBehavior: shown >= 1 ? Clip.none : Clip.hardEdge,
          child: FractionalTranslation(
            translation: Offset(0, 1 - shown),
            child: child,
          ),
        );
      },
    );
  }
}
