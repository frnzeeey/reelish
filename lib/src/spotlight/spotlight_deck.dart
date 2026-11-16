// The phone Spotlight's carousel: a PageView whose cards a
// [SpotlightMotionStyle] places by their distance from the centre. Motion
// follows the scroll position itself, so a swipe, an automatic turn and a
// fling all drive the same frames, and nothing can run two transitions at
// once. Each card works its frame out once per tick; inside the card only
// [SpotlightZoom] and [SpotlightReveal] rebuild, never the card's content.
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
    this.onPageChanged,
    this.onUserScroll,
    this.borderRadius = 24,
  });

  /// Its `viewportFraction` must be [style]'s ([controllerFor]).
  final PageController controller;
  final SpotlightMotionStyle style;

  /// Null for an endless carousel.
  final int? itemCount;
  final IndexedWidgetBuilder itemBuilder;
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
    // The same widgets whether shown or not, so the card's content is never
    // rebuilt as it comes and goes.
    final content = ValueListenableBuilder<bool>(
      valueListenable: _shown,
      // Laid out and painted once; moved as a whole.
      child: RepaintBoundary(child: widget.child),
      builder: (context, shown, child) => GestureDetector(
        // A neighbour's content ignores taps, so the card itself takes
        // them; the shown card leaves them to its content.
        behavior: shown ? HitTestBehavior.deferToChild : HitTestBehavior.opaque,
        onTap: shown ? null : widget.onBringForward,
        child: IgnorePointer(
          ignoring: !shown,
          child: ExcludeSemantics(excluding: !shown, child: child),
        ),
      ),
    );
    return _SpotlightCardScope(
      frame: _frame,
      style: widget.style,
      child: ValueListenableBuilder<SpotlightCardFrame>(
        valueListenable: _frame,
        child: content,
        builder: (context, frame, child) {
          var card = child!;
          final emphasis = frame.emphasis.clamp(0.0, 1.0);
          if (widget.style.lifted && emphasis > .01) {
            card = DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .42 * emphasis),
                    blurRadius: 28,
                    offset: Offset(0, 14 * emphasis),
                  ),
                  // A restrained glow in the accent around the shown card.
                  BoxShadow(
                    color: GlassTheme.primary.withValues(alpha: .16 * emphasis),
                    blurRadius: 24,
                    spreadRadius: -6,
                  ),
                ],
              ),
              child: card,
            );
          }
          card = Transform(
            transform: frame.transform,
            alignment: Alignment.center,
            child: card,
          );
          final opacity = frame.opacity.clamp(0.0, 1.0);
          return opacity >= 1 ? card : Opacity(opacity: opacity, child: card);
        },
      ),
    );
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
/// Outside a [SpotlightDeck] it is shown as it is.
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
      builder: (context, frame, child) => frame.imageScale == 1
          ? child!
          : Transform.scale(scale: frame.imageScale, child: child),
    );
  }
}

/// A line of a card's title and details, appearing as the card comes into
/// focus: fading in and rising [rise] pixels, after the lines before it when
/// the style staggers them ([order] 0 first). Outside a [SpotlightDeck] it
/// is shown as it is.
class SpotlightReveal extends StatelessWidget {
  const SpotlightReveal({
    super.key,
    required this.order,
    required this.child,
    this.rise = 14,
  });

  final int order;
  final double rise;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = _SpotlightCardScope.of(context);
    if (scope == null) return child;
    return ValueListenableBuilder<SpotlightCardFrame>(
      valueListenable: scope.frame,
      child: child,
      builder: (context, frame, child) {
        final shown = scope.style.lineReveal(frame.reveal, order);
        if (shown >= 1) return child!;
        return Opacity(
          opacity: Curves.easeOut.transform(shown),
          child: Transform.translate(
            offset: Offset(0, (1 - shown) * rise),
            child: child,
          ),
        );
      },
    );
  }
}
