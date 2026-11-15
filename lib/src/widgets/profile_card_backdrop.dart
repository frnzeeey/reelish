// Draws the profile card's chosen background and its animated accent
// (lib/src/theme/profile_styles.dart), all in code: no images, nothing to
// download or cache. A background is one CustomPainter inside a
// RepaintBoundary, painted once. An effect is a separate layer in its own
// RepaintBoundary over the background, with one slow controller that stops
// under reduced motion, on TV hardware, in the background, on a covered page
// (TickerMode) and when the card is scrolled out of view; the background
// alone shows instead.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/device_capabilities.dart';
import '../theme/profile_styles.dart';
import 'sovereign_laurel.dart';

/// [style] filling its box. [glow], the card's colour, lights it softly from
/// behind the avatar so a chosen colour shows on any background.
class ProfileCardBackdrop extends StatelessWidget {
  const ProfileCardBackdrop({super.key, required this.style, this.glow});

  final ProfileBackdropStyle style;
  final Color? glow;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _BackdropPainter(style, glow),
      size: Size.infinite,
    ),
  );
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.style, this.glow);

  final ProfileBackdropStyle style;
  final Color? glow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final colors = style.colors;
    final longest = math.max(size.width, size.height);
    canvas.drawRect(rect, Paint()..color = style.base);
    switch (style.pattern) {
      case ProfilePattern.solid:
        _light(
          canvas,
          rect,
          const Alignment(0, -1.2),
          longest * .9,
          colors[1].withValues(alpha: .9),
        );
      case ProfilePattern.gradient:
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.bottomRight,
              end: Alignment.topLeft,
              colors: colors,
            ).createShader(rect),
        );
      case ProfilePattern.spotlight:
        // A cone from above the avatar, widening to a pool of light.
        final top = Offset(size.width / 2, -size.height * .1);
        final cone = Path()
          ..moveTo(top.dx - size.width * .05, top.dy)
          ..lineTo(top.dx + size.width * .05, top.dy)
          ..lineTo(size.width * .5 + size.width * .38, size.height)
          ..lineTo(size.width * .5 - size.width * .38, size.height)
          ..close();
        canvas.drawPath(
          cone,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                colors[1].withValues(alpha: .16),
                colors[1].withValues(alpha: .03),
              ],
            ).createShader(rect),
        );
        _light(
          canvas,
          rect,
          const Alignment(0, 1.1),
          longest * .45,
          colors[1].withValues(alpha: .1),
        );
      case ProfilePattern.neon:
        _light(
          canvas,
          rect,
          const Alignment(-1.1, -1),
          longest * .7,
          colors[1].withValues(alpha: .26),
        );
        _light(
          canvas,
          rect,
          const Alignment(1.1, 1.05),
          longest * .7,
          colors[2].withValues(alpha: .22),
        );
      case ProfilePattern.stars:
        _light(
          canvas,
          rect,
          const Alignment(.6, -1.1),
          longest * .9,
          colors[1].withValues(alpha: .7),
        );
        final star = Paint()..color = Colors.white;
        // Fixed positions, so the sky is the same on every paint.
        final random = math.Random(7);
        for (var i = 0; i < 46; i++) {
          final x = random.nextDouble() * size.width;
          final y = random.nextDouble() * size.height;
          final r = .5 + random.nextDouble() * 1.1;
          star.color = Colors.white.withValues(
            alpha: .18 + random.nextDouble() * .4,
          );
          canvas.drawCircle(Offset(x, y), r, star);
        }
      case ProfilePattern.rays:
        final origin = Offset(-size.width * .05, -size.height * .15);
        for (var i = 0; i < 5; i++) {
          final spread = .16 + i * .2;
          final ray = Path()
            ..moveTo(origin.dx, origin.dy)
            ..lineTo(size.width * 1.2, size.height * (spread - .06))
            ..lineTo(size.width * 1.2, size.height * (spread + .07))
            ..close();
          canvas.drawPath(
            ray,
            Paint()
              ..shader = RadialGradient(
                center: Alignment.topLeft,
                radius: 1.3,
                colors: [
                  colors[1].withValues(alpha: .13),
                  colors[1].withValues(alpha: 0),
                ],
              ).createShader(rect),
          );
        }
      case ProfilePattern.film:
        _light(
          canvas,
          rect,
          const Alignment(-.4, -1.2),
          longest * .8,
          colors[1].withValues(alpha: .2),
        );
        final strip = math.min(28.0, size.height * .14);
        final band = Rect.fromLTWH(0, size.height - strip, size.width, strip);
        canvas.drawRect(
          band,
          Paint()..color = Colors.black.withValues(alpha: .35),
        );
        final hole = Paint()..color = colors[1].withValues(alpha: .16);
        final w = strip * .42, h = strip * .32;
        for (var x = w * .6; x < size.width; x += w * 2) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, band.top + (strip - h) / 2, w, h),
              const Radius.circular(2),
            ),
            hole,
          );
        }
      case ProfilePattern.mesh:
        _light(
          canvas,
          rect,
          const Alignment(-.9, -.8),
          longest * .7,
          colors[1].withValues(alpha: .2),
        );
        _light(
          canvas,
          rect,
          const Alignment(.9, -.4),
          longest * .65,
          colors[2].withValues(alpha: .22),
        );
        _light(
          canvas,
          rect,
          const Alignment(.1, 1.2),
          longest * .6,
          colors[3].withValues(alpha: .18),
        );
      case ProfilePattern.sovereign:
        _sovereign(canvas, rect, longest);
    }
    final glow = this.glow;
    if (glow != null) {
      _light(
        canvas,
        rect,
        const Alignment(0, -.75),
        longest * .55,
        glow.withValues(alpha: .18),
      );
    }
  }

  /// Sovereign Edition: deep wine rising from charcoal, a soft royal-wine
  /// light behind the avatar, the engraved laurel seal to the right, a
  /// champagne light along the top and a champagne hairline frame inset from
  /// the edge, like a membership card's border. Restraint is the point: the
  /// gold is in fine lines, never in fills.
  static void _sovereign(Canvas canvas, Rect rect, double longest) {
    final size = rect.size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [
            SovereignColors.charcoal,
            SovereignColors.ink,
            SovereignColors.wine,
          ],
          stops: [.2, .62, 1],
        ).createShader(rect),
    );
    _light(
      canvas,
      rect,
      const Alignment(-.1, -1.1),
      longest * .7,
      SovereignColors.royalWine.withValues(alpha: .4),
    );
    // Deeper at the foot, where the counts sit.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            SovereignColors.charcoal.withValues(alpha: 0),
            SovereignColors.charcoal.withValues(alpha: .55),
          ],
          stops: const [.55, 1],
        ).createShader(rect),
    );
    final shortest = math.min(size.width, size.height);
    paintSovereignSeal(
      canvas,
      Offset(size.width - shortest * .2, size.height * .56),
      shortest * .44,
    );
    // The champagne light along the top edge.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, math.max(1.0, shortest * .006)),
      Paint()
        ..shader = LinearGradient(
          colors: [
            SovereignColors.highlight.withValues(alpha: 0),
            SovereignColors.highlight.withValues(alpha: .7),
            SovereignColors.highlight.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    // The hairline frame, inset from the card's edge.
    final inset = (shortest * .045).clamp(5.0, 12.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(inset),
        Radius.circular(math.max(4, 16 - inset)),
      ),
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            SovereignColors.highlight.withValues(alpha: .42),
            SovereignColors.antique.withValues(alpha: .18),
            SovereignColors.champagne.withValues(alpha: .34),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.style != style || old.glow != glow;
}

void _light(
  Canvas canvas,
  Rect rect,
  Alignment at,
  double radius,
  Color color,
) {
  final center = at.withinRect(rect);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius)),
  );
}

/// [effect] over the card, in [color]. Nothing for [ProfileEffect.none].
class ProfileCardEffect extends StatefulWidget {
  const ProfileCardEffect({
    super.key,
    required this.effect,
    required this.color,
  });

  final ProfileEffect effect;
  final Color color;

  static Duration periodOf(ProfileEffect effect) => switch (effect) {
    ProfileEffect.drift => const Duration(seconds: 24),
    _ => const Duration(seconds: 9),
  };

  @override
  State<ProfileCardEffect> createState() => _ProfileCardEffectState();
}

class _ProfileCardEffectState extends State<ProfileCardEffect>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ProfileCardEffect.periodOf(widget.effect),
  );
  ScrollableState? _scrollable;
  bool _foreground = true;
  bool _onScreen = true;
  bool _checkPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable != _scrollable) {
      _scrollable?.position.removeListener(_checkOnScreen);
      _scrollable = scrollable?..position.addListener(_checkOnScreen);
    }
    _update();
  }

  @override
  void didUpdateWidget(ProfileCardEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effect != widget.effect) {
      _controller.duration = ProfileCardEffect.periodOf(widget.effect);
      if (_controller.isAnimating) _controller.repeat();
    }
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  /// Measures after layout: a scroll notifies before the page moves.
  void _checkOnScreen() {
    if (_checkPending) return;
    _checkPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPending = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      final viewport = _scrollable?.context.findRenderObject();
      if (box is! RenderBox || viewport is! RenderBox) return;
      if (!box.attached || !viewport.attached || !box.hasSize) return;
      final card = box.localToGlobal(Offset.zero) & box.size;
      final view = viewport.localToGlobal(Offset.zero) & viewport.size;
      final visible = card.overlaps(view);
      if (visible != _onScreen) {
        _onScreen = visible;
        _update();
      }
    });
  }

  /// Low-powered TV hardware keeps a still card.
  bool get _moving =>
      widget.effect != ProfileEffect.none &&
      !DeviceCapabilities.isTv &&
      _foreground &&
      _onScreen &&
      !MediaQuery.disableAnimationsOf(context);

  /// Runs or stops the controller. A covered page also stops it: its ticker
  /// is muted by TickerMode.
  void _update() {
    if (_moving) {
      if (!_controller.isAnimating) _controller.repeat();
    } else if (_controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollable?.position.removeListener(_checkOnScreen);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.effect == ProfileEffect.none) return const SizedBox.shrink();
    final moving = _moving;
    // Still, Drift rests where it starts; Sheen shows nothing.
    if (!moving && widget.effect == ProfileEffect.sheen) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          willChange: moving,
          painter: _EffectPainter(
            widget.effect,
            widget.color,
            moving ? _controller : const AlwaysStoppedAnimation(0),
          ),
        ),
      ),
    );
  }
}

class _EffectPainter extends CustomPainter {
  _EffectPainter(this.effect, this.color, this.time) : super(repaint: time);

  final ProfileEffect effect;
  final Color color;
  final Animation<double> time;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final t = time.value;
    final longest = math.max(size.width, size.height);
    switch (effect) {
      case ProfileEffect.none:
        return;
      case ProfileEffect.drift:
        // Two lights on slow, different loops, so the pattern rarely repeats.
        final a = 2 * math.pi * t;
        _light(
          canvas,
          rect,
          Alignment(-.55 + .45 * math.sin(a), -.5 + .35 * math.cos(a)),
          longest * .5,
          color.withValues(alpha: .16),
        );
        _light(
          canvas,
          rect,
          Alignment(.6 + .35 * math.cos(2 * a), .55 + .3 * math.sin(a)),
          longest * .45,
          color.withValues(alpha: .1),
        );
      case ProfileEffect.sheen:
        // A diagonal band crosses during the first fifth of the cycle; the
        // rest is still.
        const pass = .22;
        if (t > pass) return;
        final x = -.4 + (t / pass) * 1.8;
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment(-1 + x * 2 - .5, -1),
              end: Alignment(-1 + x * 2 + .5, 1),
              colors: [
                Colors.white.withValues(alpha: 0),
                Colors.white.withValues(alpha: .07),
                Colors.white.withValues(alpha: 0),
              ],
            ).createShader(rect),
        );
    }
  }

  @override
  bool shouldRepaint(_EffectPainter old) =>
      old.effect != effect || old.color != color || old.time != time;
}
