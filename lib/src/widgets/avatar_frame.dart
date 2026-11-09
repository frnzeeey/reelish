// Draws an avatar frame (lib/src/theme/avatar_frames.dart) around any avatar:
// a Trakt picture, a photo, a preset or the initial, at any size, all in code.
// Three layers: what is painted once behind the avatar (the ring and most
// ornaments), what moves (alone in its own RepaintBoundary, so neither the
// avatar nor the ring repaints with it) and what is painted once in front
// (the Founder's laurel and crown, the Supporter star, the Royal jewel).
//
// Most frames are still. A moving one runs one controller, slow and faint,
// and stops under reduced motion, in the background, on a covered page and
// when scrolled out of view; a still frame shows instead. Below 48 px only
// the ring is drawn. Small avatars that cannot grow (Home, the sidebar, the
// rail) take AvatarFrameRim, a fine rim in the frame's colour.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../account/avatar_frames.dart';
import '../theme/avatar_frames.dart';

/// The Sovereign frame's colours: the Sovereign Crest's metal over a
/// midnight-violet undertone.
abstract final class FounderRingColors {
  static const platinum = Color(0xFFF3DCA7);
  static const champagne = Color(0xFFD6B779);
  static const bronze = Color(0xFFB08D50);
  static const violet = Color(0xFFA78BFA);
  static const obsidian = Color(0xFF120F20);
}

/// Frames [child], an avatar [size] across, in [style]. Adds [paddingFor] on
/// every side; glows and ornaments paint beyond that without taking room.
class AvatarFrame extends StatefulWidget {
  const AvatarFrame({
    super.key,
    required this.style,
    required this.size,
    required this.child,
    this.animate = true,
  });

  final AvatarFrameStyle style;

  /// The avatar's diameter, which sets the ring's weight and its ornaments.
  final double size;
  final Widget child;

  /// False for a still frame wherever it is.
  final bool animate;

  /// Ornaments need room to read; smaller frames draw only the ring.
  static const ornamentSize = 48.0;

  /// A frame is a band; the Founder's is a fine ring, as its laurel and
  /// crown carry it.
  static double _weight(double size, [AvatarFrameStyle? style]) =>
      style == null || style.ornament == FrameOrnament.laurel
      ? (size * .028).clamp(1.5, 3.5)
      : (size * .05).clamp(2.0, 6.0);
  static double _gap(double size) => (size * .04).clamp(1.5, 4.0);

  /// The room the ring takes on each side of the avatar.
  static double paddingFor(double size, [AvatarFrameStyle? style]) =>
      _weight(size, style) + _gap(size);

  /// One cycle of a frame's motion.
  static Duration periodOf(AvatarFrameStyle style) => switch (style.motion) {
    FrameMotion.turn => const Duration(seconds: 16),
    FrameMotion.sheen => const Duration(seconds: 7),
    _ => const Duration(seconds: 6),
  };

  @override
  State<AvatarFrame> createState() => _AvatarFrameState();
}

class _AvatarFrameState extends State<AvatarFrame>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AvatarFrame.periodOf(widget.style),
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
  void didUpdateWidget(AvatarFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) {
      _controller.duration = AvatarFrame.periodOf(widget.style);
      if (_controller.isAnimating) _controller.repeat();
    }
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  /// Measures once the scroll has been laid out: a scroll notifies before
  /// the page moves, so measuring at once would see the old place.
  void _checkOnScreen() {
    if (_checkPending) return;
    _checkPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPending = false;
      if (mounted) _measure();
    });
  }

  /// Whether any of the frame is inside the scrolling page's viewport.
  void _measure() {
    final box = context.findRenderObject();
    final viewport = _scrollable?.context.findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return;
    if (!box.attached || !viewport.attached || !box.hasSize) return;
    final frame = box.localToGlobal(Offset.zero) & box.size;
    final view = viewport.localToGlobal(Offset.zero) & viewport.size;
    final visible = frame.overlaps(view);
    if (visible != _onScreen) {
      _onScreen = visible;
      _update();
    }
  }

  bool get _moving =>
      widget.animate &&
      widget.style.motion != FrameMotion.none &&
      widget.size >= AvatarFrame.ornamentSize &&
      _foreground &&
      _onScreen &&
      !MediaQuery.disableAnimationsOf(context);

  /// Runs or stops the controller. A covered page also stops it: its
  /// ticker is muted by TickerMode.
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
    final style = widget.style;
    final size = widget.size;
    final weight = AvatarFrame._weight(size, style);
    final pad = AvatarFrame.paddingFor(size, style);
    final ornate = size >= AvatarFrame.ornamentSize;
    // Still: a glint rests at the upper left, where the light comes from.
    final light = _moving ? _controller : const AlwaysStoppedAnimation(.375);
    final moves = style.motion != FrameMotion.none && ornate;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _BackPainter(
              style,
              size: size,
              weight: weight,
              ornate: ornate,
            ),
          ),
        ),
        Padding(padding: EdgeInsets.all(pad), child: widget.child),
        if (moves)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _LightPainter(
                    style,
                    light,
                    size: size,
                    weight: weight,
                  ),
                  willChange: _moving,
                ),
              ),
            ),
          ),
        if (ornate && _FrontPainter.draws(style))
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _FrontPainter(style, size: size, weight: weight),
              ),
            ),
          ),
        // The Sovereign sheen lights the laurel and crown, so it sits over
        // them. Only while moving: the still frame has no sheen.
        if (style.motion == FrameMotion.sheen && ornate && _moving)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _SheenPainter(
                    _controller,
                    size: size,
                    weight: weight,
                  ),
                  willChange: true,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The ring's centre line and the circle it is drawn on.
({Offset center, double radius}) _circle(Size box, double size, double weight) {
  final center = box.center(Offset.zero);
  return (
    center: center,
    radius: size / 2 + (box.width - size) / 2 - weight / 2,
  );
}

/// The ring's sweep of colours, turned by [turn] (0 to 1).
Shader _ringShader(AvatarFrameStyle style, Rect rect, [double turn = 0]) {
  final colors = style.colors;
  return SweepGradient(
    colors: colors,
    stops: [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)],
    transform: GradientRotation(2 * math.pi * turn),
  ).createShader(rect);
}

Paint _stroke(double width) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..isAntiAlias = true;

Offset _onCircle(Offset center, double radius, double degrees) =>
    center +
    Offset(
          math.cos(degrees * math.pi / 180),
          math.sin(degrees * math.pi / 180),
        ) *
        radius;

/// Painted once, behind the avatar: a soft glow of the frame's colour, the
/// ring (unless it turns, when the light layer draws it) and the ornaments
/// that sit around or on it.
class _BackPainter extends CustomPainter {
  const _BackPainter(
    this.style, {
    required this.size,
    required this.weight,
    required this.ornate,
  });

  final AvatarFrameStyle style;
  final double size;
  final double weight;
  final bool ornate;

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    final founder = style.ornament == FrameOrnament.laurel;
    // A soft undertone beneath the ring: violet for the Founder, otherwise
    // the frame's own colour.
    final glow = founder ? FounderRingColors.violet : style.rim;
    final under = radius * 1.32;
    final underCenter = center + Offset(0, radius * .1);
    canvas.drawCircle(
      underCenter,
      under,
      Paint()
        ..shader = RadialGradient(
          colors: [
            glow.withValues(alpha: 0),
            glow.withValues(alpha: founder ? .16 : .12),
            glow.withValues(alpha: 0),
          ],
          stops: [radius * .8 / under, radius / under, 1],
        ).createShader(Rect.fromCircle(center: underCenter, radius: under)),
    );
    final rect = Rect.fromCircle(center: center, radius: radius);
    final turns = style.motion == FrameMotion.turn && ornate;
    if (!turns) {
      canvas.drawCircle(
        center,
        radius,
        _stroke(weight)..shader = _ringShader(style, rect),
      );
    }
    // A fine bezel round the band, so every frame reads as a finished
    // piece, the dark ones too. The Founder's laurel needs none.
    if (!founder) {
      final edge = Color.lerp(style.rim, Colors.white, .55)!;
      canvas.drawCircle(
        center,
        radius + weight / 2 + .9,
        _stroke(1)..color = edge.withValues(alpha: .45),
      );
      canvas.drawCircle(
        center,
        radius - weight / 2 - .6,
        _stroke(.8)..color = edge.withValues(alpha: .18),
      );
    }
    if (!ornate) return;
    final accent = style.accent ?? Colors.white;
    switch (style.ornament) {
      case FrameOrnament.stars:
        // Fixed places, so the sky is the same on every paint.
        final random = math.Random(11);
        final dot = Paint()..isAntiAlias = true;
        for (var i = 0; i < 14; i++) {
          final angle = random.nextDouble() * 360;
          final out =
              radius + weight + size * (.03 + random.nextDouble() * .07);
          final bright = random.nextDouble();
          dot.color = accent.withValues(alpha: .35 + bright * .5);
          canvas.drawCircle(
            _onCircle(center, out, angle),
            size * (.006 + bright * .01),
            dot,
          );
        }
        for (final (angle, scale) in [(-60.0, 1.0), (150.0, .7)]) {
          _glint(
            canvas,
            _onCircle(center, radius + weight + size * .06, angle),
            size * .04 * scale,
            accent,
          );
        }
      case FrameOrnament.particles:
        final random = math.Random(5);
        for (var i = 0; i < 10; i++) {
          final angle = random.nextDouble() * 360;
          final out = radius + (random.nextDouble() - .3) * size * .1;
          canvas.drawCircle(
            _onCircle(center, out, angle),
            size * (.008 + random.nextDouble() * .014),
            Paint()
              ..color = accent.withValues(alpha: .25 + random.nextDouble() * .4)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * .006),
          );
        }
      case FrameOrnament.corona:
        // A crescent of light round the upper right, fading at both ends.
        canvas.drawArc(
          rect.inflate(weight * .6),
          -math.pi * .55,
          math.pi * .75,
          false,
          _stroke(weight * 1.4)
            ..shader = SweepGradient(
              colors: [
                accent.withValues(alpha: 0),
                accent.withValues(alpha: .9),
                accent.withValues(alpha: 0),
              ],
              stops: const [.73, .86, .98],
            ).createShader(rect),
        );
      case FrameOrnament.glass:
        canvas.drawArc(
          rect.deflate(weight * .15),
          math.pi * 1.05,
          math.pi * .5,
          false,
          _stroke(weight * .5)..color = accent.withValues(alpha: .55),
        );
        canvas.drawCircle(
          center,
          radius - weight / 2,
          _stroke(.8)..color = accent.withValues(alpha: .08),
        );
      case FrameOrnament.filmStrip:
        // Sprockets punched evenly round the ring.
        final hole = Paint()
          ..isAntiAlias = true
          ..color = accent;
        final count = (size / 6).round().clamp(12, 28);
        for (var i = 0; i < count; i++) {
          final angle = 360 * i / count;
          canvas.save();
          final at = _onCircle(center, radius, angle);
          canvas.translate(at.dx, at.dy);
          canvas.rotate(angle * math.pi / 180);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset.zero,
                width: weight * .55,
                height: weight * .9,
              ),
              Radius.circular(weight * .15),
            ),
            hole,
          );
          canvas.restore();
        }
      case FrameOrnament.crownJewel:
        canvas.drawCircle(
          center,
          radius - weight * .9,
          _stroke(math.max(.8, weight * .3))
            ..color = accent.withValues(alpha: .8),
        );
      case FrameOrnament.none:
      case FrameOrnament.supporterStar:
      case FrameOrnament.laurel:
        break;
    }
  }

  /// A four-pointed glint.
  static void _glint(Canvas canvas, Offset at, double r, Color color) {
    final w = r * .22;
    canvas.drawPath(
      Path()
        ..moveTo(at.dx, at.dy - r)
        ..quadraticBezierTo(at.dx + w, at.dy - w, at.dx + r, at.dy)
        ..quadraticBezierTo(at.dx + w, at.dy + w, at.dx, at.dy + r)
        ..quadraticBezierTo(at.dx - w, at.dy + w, at.dx - r, at.dy)
        ..quadraticBezierTo(at.dx - w, at.dy - w, at.dx, at.dy - r)
        ..close(),
      Paint()
        ..isAntiAlias = true
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_BackPainter old) =>
      old.style != style ||
      old.size != size ||
      old.weight != weight ||
      old.ornate != ornate;
}

/// Repainted while it moves: a glint, a turning ring, or the Sovereign
/// frame's breathing undertone (its sheen is _SheenPainter, over the laurel).
class _LightPainter extends CustomPainter {
  _LightPainter(
    this.style,
    this.light, {
    required this.size,
    required this.weight,
  }) : super(repaint: light);

  final AvatarFrameStyle style;

  /// 0 to 1 over one cycle.
  final Animation<double> light;
  final double size;
  final double weight;

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    final t = light.value;
    final rect = Rect.fromCircle(center: center, radius: radius);
    switch (style.motion) {
      case FrameMotion.turn:
        canvas.drawCircle(
          center,
          radius,
          _stroke(weight)..shader = _ringShader(style, rect, t),
        );
      case FrameMotion.sheen:
        // The violet undertone behind the laurel, breathing once a cycle,
        // the same violet that is painted still beneath the ring.
        final breath = .5 - .5 * math.cos(2 * math.pi * t);
        final outer = radius + (size * .14).clamp(5.0, 18.0);
        const violet = FounderRingColors.violet;
        canvas.drawCircle(
          center,
          outer,
          Paint()
            ..shader = RadialGradient(
              colors: [
                violet.withValues(alpha: 0),
                violet.withValues(alpha: .06 + .12 * breath),
                violet.withValues(alpha: 0),
              ],
              stops: [(radius - weight) / outer, radius / outer, 1],
            ).createShader(Rect.fromCircle(center: center, radius: outer)),
        );
      case FrameMotion.glint:
        _glint(canvas, center, radius, rect, t);
      case FrameMotion.none:
        break;
    }
  }

  /// A short arc of brighter metal with a fading tail, like light moving
  /// across a polished rim rather than a spinner.
  void _glint(
    Canvas canvas,
    Offset center,
    double radius,
    Rect rect,
    double t,
  ) {
    canvas.drawCircle(
      center,
      radius,
      _stroke(weight)
        ..shader = SweepGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0),
            const Color(0xFFFFF6DE).withValues(alpha: .85),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, .76, .9, .96],
          transform: GradientRotation(2 * math.pi * t),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_LightPainter old) =>
      old.style != style ||
      old.light != light ||
      old.size != size ||
      old.weight != weight;
}

/// Painted once, in front of the avatar's edge: the Founder's laurel and
/// crown, the Supporter star, the Royal jewel.
class _FrontPainter extends CustomPainter {
  const _FrontPainter(this.style, {required this.size, required this.weight});

  final AvatarFrameStyle style;
  final double size;
  final double weight;

  static bool draws(AvatarFrameStyle style) => switch (style.ornament) {
    FrameOrnament.laurel ||
    FrameOrnament.supporterStar ||
    FrameOrnament.crownJewel => true,
    _ => false,
  };

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    final top = Offset(center.dx, center.dy - radius);
    final accent = style.accent ?? Colors.white;
    switch (style.ornament) {
      case FrameOrnament.laurel:
        _LaurelPainter(size: size, weight: weight).paint(canvas, box);
      case FrameOrnament.supporterStar:
        final disc = (size * .1).clamp(8.0, 14.0);
        canvas.drawCircle(
          top,
          disc,
          Paint()
            ..isAntiAlias = true
            ..color = const Color(0xFF1A1408),
        );
        canvas.drawCircle(
          top,
          disc - weight * .35,
          _stroke(weight * .7)..color = style.rim,
        );
        canvas.drawPath(
          _star(top, disc * .62, disc * .26),
          Paint()
            ..isAntiAlias = true
            ..color = accent,
        );
      case FrameOrnament.crownJewel:
        final r = (size * .07).clamp(5.0, 10.0);
        final diamond = Path()
          ..moveTo(top.dx, top.dy - r)
          ..lineTo(top.dx + r * .75, top.dy)
          ..lineTo(top.dx, top.dy + r)
          ..lineTo(top.dx - r * .75, top.dy)
          ..close();
        canvas.drawPath(
          diamond.shift(Offset(0, r * .15)),
          Paint()
            ..color = const Color(0x55000000)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .3),
        );
        canvas.drawPath(
          diamond,
          Paint()
            ..isAntiAlias = true
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(accent, Colors.white, .5)!, accent],
            ).createShader(Rect.fromCircle(center: top, radius: r)),
        );
      default:
        break;
    }
  }

  /// A five-pointed star centred on [at].
  static Path _star(Offset at, double outer, double inner) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? outer : inner;
      final angle = -math.pi / 2 + i * math.pi / 5;
      final point = at + Offset(math.cos(angle), math.sin(angle)) * r;
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_FrontPainter old) =>
      old.style != style || old.size != size || old.weight != weight;
}

/// A frame for a small avatar that cannot grow: a fine rim in the frame's
/// colour drawn over its edge, still, taking no room, so the layouts around
/// it do not move. It shows the signed-in account's equipped frame.
class AvatarFrameRim extends StatelessWidget {
  const AvatarFrameRim({super.key, required this.child, this.frames});

  final Widget child;

  /// Whose frame; [AvatarFrames.instance] when null.
  final AvatarFrames? frames;

  @override
  Widget build(BuildContext context) {
    final frames = this.frames ?? AvatarFrames.instance;
    return ListenableBuilder(
      listenable: frames,
      builder: (context, child) {
        final style = AvatarFrameStyle.byId(frames.equipped);
        if (style == null) return child!;
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: style.rim, width: 1.5),
          ),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// The Sovereign frame's laurel and crown as shapes, so the frame and its
/// sheen draw exactly the same metal.
typedef _LaurelShape = ({
  Path stems,
  double stemWidth,
  Path leaves,
  Path crown,
  Rect crownRect,
  Rect bounds,
});

/// The Founder's frame, Sovereign, around the ring: two champagne laurel
/// branches rising from the bottom, either side, toward the crown set on top
/// of the ring, the Founder Collection's crown
/// (tool/branding/sovereign_shared.mjs). The gap where the branches meet at
/// the foot holds the edit button. Painted once, beyond the widget's bounds,
/// so it takes no room.
class _LaurelPainter extends CustomPainter {
  const _LaurelPainter({required this.size, required this.weight});

  final double size;
  final double weight;

  // The crown, as designed in a 292 x 149 box (sovereign_shared.mjs).
  static const _crownW = 292.0;
  static const _crownH = 149.0;
  static const _body = [
    Offset(23, 145),
    Offset(15, 43),
    Offset(87, 97),
    Offset(146, 23),
    Offset(205, 97),
    Offset(277, 43),
    Offset(269, 145),
  ];
  static const _pearls = [Offset(15, 37), Offset(146, 15), Offset(277, 37)];
  static const _jewels = [68.0, 146.0, 224.0];

  /// The laurel and crown for a ring of [radius] round [center].
  static _LaurelShape shape(
    Offset center,
    double radius,
    double size,
    double weight,
  ) {
    // The branches: a stem on a circle just outside the ring, with pairs of
    // leaves leaning toward the tip, the inner ones shorter so they stay
    // clear of the ring.
    final stem = radius + weight / 2 + size * .07;
    Offset on(double degrees) =>
        center +
        Offset(
              math.cos(degrees * math.pi / 180),
              math.sin(degrees * math.pi / 180),
            ) *
            stem;
    final stems = Path();
    final leaves = Path();
    for (final (from, to) in [(112.0, 228.0), (68.0, -48.0)]) {
      final sign = (to - from).sign;
      stems.moveTo(on(from).dx, on(from).dy);
      for (var i = 1; i <= 24; i++) {
        final point = on(from + (to - from) * i / 24);
        stems.lineTo(point.dx, point.dy);
      }
      const pairs = 6;
      for (var i = 0; i < pairs; i++) {
        final t = (i + .5) / pairs;
        final at = from + (to - from) * t;
        final forward = at * math.pi / 180 + sign * math.pi / 2;
        final grow = 1 - t * .35;
        // Outward (away from the avatar), then inward and shorter.
        leaves.addPath(
          _leaf(
            on(at),
            forward - sign * .62,
            size * .17 * grow,
            size * .05 * grow,
          ),
          Offset.zero,
        );
        leaves.addPath(
          _leaf(
            on(at),
            forward + sign * .5,
            size * .11 * grow,
            size * .035 * grow,
          ),
          Offset.zero,
        );
      }
      leaves.addPath(
        _leaf(
          on(to),
          to * math.pi / 180 + sign * math.pi / 2,
          size * .12,
          size * .036,
        ),
        Offset.zero,
      );
    }

    // The crown, resting on the top of the ring.
    final width = size * .42;
    final k = width / _crownW;
    final left = center.dx - width / 2;
    final top = center.dy - radius - _crownH * k + size * .045;
    Offset c(Offset p) => Offset(left + p.dx * k, top + p.dy * k);
    final crown = Path()..addPolygon(_body.map(c).toList(), true);
    crown.addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left + 19 * k, top + 119 * k, 254 * k, 30 * k),
        Radius.circular(12 * k),
      ),
    );
    for (final pearl in _pearls) {
      crown.addOval(Rect.fromCircle(center: c(pearl), radius: 15 * k));
    }
    return (
      stems: stems,
      stemWidth: math.max(1.2, size * .014),
      leaves: leaves,
      crown: crown,
      crownRect: Rect.fromLTWH(left, top, width, _crownH * k),
      bounds: Rect.fromCircle(center: center, radius: radius * 1.5),
    );
  }

  /// The centre of the crown's tallest pearl, where the sheen sparkles.
  static Offset crownPearl(Rect crownRect) {
    final k = crownRect.width / _crownW;
    return crownRect.topLeft + _pearls[1] * k;
  }

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    final laurel = shape(center, radius, size, weight);
    final metal = Paint()
      ..isAntiAlias = true
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          FounderRingColors.platinum,
          FounderRingColors.champagne,
          FounderRingColors.bronze,
          FounderRingColors.champagne,
        ],
        stops: [0, .4, .7, 1],
      ).createShader(laurel.bounds);
    canvas.drawPath(
      laurel.stems,
      _stroke(laurel.stemWidth)
        ..strokeCap = StrokeCap.round
        ..shader = metal.shader,
    );
    canvas.drawPath(laurel.leaves, metal);

    final crownRect = laurel.crownRect;
    final k = crownRect.width / _crownW;
    canvas.drawPath(
      laurel.crown.shift(Offset(0, 6 * k)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * k),
    );
    canvas.drawPath(
      laurel.crown,
      Paint()
        ..isAntiAlias = true
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            FounderRingColors.platinum,
            FounderRingColors.champagne,
            FounderRingColors.bronze,
          ],
        ).createShader(crownRect),
    );
    final jewel = Paint()
      ..isAntiAlias = true
      ..color = FounderRingColors.obsidian;
    for (final x in _jewels) {
      canvas.drawCircle(
        crownRect.topLeft + Offset(x * k, 134 * k),
        7 * k,
        jewel,
      );
    }
  }

  /// A laurel leaf: a pointed oval from [base] along [direction] (radians).
  static Path _leaf(
    Offset base,
    double direction,
    double length,
    double width,
  ) {
    final d = Offset(math.cos(direction), math.sin(direction));
    final n = Offset(-d.dy, d.dx);
    final mid = base + d * (length / 2);
    final tip = base + d * length;
    return Path()
      ..moveTo(base.dx, base.dy)
      ..quadraticBezierTo(
        (mid + n * width).dx,
        (mid + n * width).dy,
        tip.dx,
        tip.dy,
      )
      ..quadraticBezierTo(
        (mid - n * width).dx,
        (mid - n * width).dy,
        base.dx,
        base.dy,
      )
      ..close();
  }

  @override
  bool shouldRepaint(_LaurelPainter old) =>
      old.size != size || old.weight != weight;
}

/// The Sovereign sheen, over the laurel and crown: once a cycle a band of
/// pale light crosses the metal from the upper left, where the Sovereign
/// Crest is lit from, and a sparkle flares on the crown's tallest pearl as
/// it passes. The rest of the cycle paints nothing.
class _SheenPainter extends CustomPainter {
  _SheenPainter(this.light, {required this.size, required this.weight})
    : super(repaint: light);

  /// 0 to 1 over one cycle.
  final Animation<double> light;
  final double size;
  final double weight;

  /// The part of the cycle the sweep takes (about 1.6 s of 7).
  static const sweep = .23;

  static const _light = Color(0xFFFFF6DE);

  @override
  void paint(Canvas canvas, Size box) {
    final t = light.value;
    if (t >= sweep) return;
    final (:center, :radius) = _circle(box, size, weight);
    final laurel = _LaurelPainter.shape(center, radius, size, weight);
    final bounds = laurel.bounds.expandToInclude(laurel.crownRect);
    // The band's place along the diagonal, eased, from just before the
    // metal to just past it.
    final along = -.2 + 1.4 * Curves.easeInOutSine.transform(t / sweep);
    const half = .11;
    final band = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        _light.withValues(alpha: 0),
        _light.withValues(alpha: 0),
        _light.withValues(alpha: .95),
        _light.withValues(alpha: 0),
        _light.withValues(alpha: 0),
      ],
      stops: [
        0,
        (along - half).clamp(0.0, 1.0),
        along.clamp(0.0, 1.0),
        (along + half).clamp(0.0, 1.0),
        1,
      ],
    ).createShader(bounds);
    final sheen = Paint()
      ..isAntiAlias = true
      ..shader = band;
    canvas.drawPath(laurel.leaves, sheen);
    canvas.drawPath(laurel.crown, sheen);
    canvas.drawPath(
      laurel.stems,
      _stroke(laurel.stemWidth)
        ..strokeCap = StrokeCap.round
        ..shader = band,
    );
    canvas.drawCircle(center, radius, _stroke(weight)..shader = band);

    // The sparkle, as the band crosses the pearl: the pearl's place along
    // the same diagonal the band travels.
    final pearl = _LaurelPainter.crownPearl(laurel.crownRect);
    final diagonal = bounds.bottomRight - bounds.topLeft;
    final offset = pearl - bounds.topLeft;
    final pearlAlong =
        (offset.dx * diagonal.dx + offset.dy * diagonal.dy) /
        diagonal.distanceSquared;
    final flare = (1 - (along - pearlAlong).abs() / .14).clamp(0.0, 1.0);
    if (flare <= 0) return;
    final eased = Curves.easeOut.transform(flare);
    final r = size * .11 * eased;
    canvas.drawCircle(
      pearl,
      r * .9,
      Paint()
        ..color = _light.withValues(alpha: .45 * eased)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .5),
    );
    // A four-pointed star, turned a little as it flares.
    canvas.save();
    canvas.translate(pearl.dx, pearl.dy);
    canvas.rotate(math.pi / 8 * (1 - flare));
    _BackPainter._glint(
      canvas,
      Offset.zero,
      r,
      _light.withValues(alpha: eased),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SheenPainter old) =>
      old.light != light || old.size != size || old.weight != weight;
}
