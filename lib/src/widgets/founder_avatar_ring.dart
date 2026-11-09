// The Founder's profile accent: a champagne-gold ring around the avatar, with
// a violet undertone beneath it and the Sovereign Crest's diadem set at its
// upper right. On the profile card it lives: a soft halo breathes and one
// glint of reflected light travels the ring, both from one controller, slow
// and faint, so the avatar stays the focal point. It stops when the system asks
// for reduced motion, when the app is in the background, when the page is
// covered, and when the card is scrolled out of view; a still ring shows
// instead. Small avatars (Home, the sidebar, the rail) take FounderAvatarRim,
// the same gold without movement or size of its own.
//
// Callers decide who gets it: FounderPerk.profileAccent, the Founder only.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../account/supporter_controller.dart';

/// The ring's colours: the Sovereign Crest's metal over a midnight-violet
/// undertone. Fixed, like a badge, so the Founder's identity reads the same
/// under every theme.
abstract final class FounderRingColors {
  static const platinum = Color(0xFFF3DCA7);
  static const champagne = Color(0xFFD6B779);
  static const bronze = Color(0xFFB08D50);
  static const violet = Color(0xFFA78BFA);
  static const obsidian = Color(0xFF120F20);
}

/// Frames [child], an avatar [size] across, in the Founder's ring. Adds
/// [paddingFor] on every side; the halo paints a little beyond that without
/// taking room.
class FounderAnimatedAvatarRing extends StatefulWidget {
  const FounderAnimatedAvatarRing({
    super.key,
    required this.size,
    required this.child,
    this.animate = true,
  });

  /// The avatar's diameter, which sets the ring's weight and its crown.
  final double size;
  final Widget child;

  /// False for a still ring wherever it is.
  final bool animate;

  /// One cycle: one revolution of the glint and one breath of the halo.
  static const period = Duration(seconds: 6);

  static double _weight(double size) => (size * .028).clamp(1.5, 3.5);
  static double _gap(double size) => (size * .04).clamp(1.5, 4.0);

  /// The room the ring takes on each side of the avatar.
  static double paddingFor(double size) => _weight(size) + _gap(size);

  @override
  State<FounderAnimatedAvatarRing> createState() =>
      _FounderAnimatedAvatarRingState();
}

class _FounderAnimatedAvatarRingState extends State<FounderAnimatedAvatarRing>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FounderAnimatedAvatarRing.period,
  );
  ScrollableState? _scrollable;
  bool _foreground = true;
  bool _onScreen = true;

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
  void didUpdateWidget(FounderAnimatedAvatarRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  bool _checkPending = false;

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

  /// Whether any of the ring is inside the scrolling page's viewport.
  void _measure() {
    final box = context.findRenderObject();
    final viewport = _scrollable?.context.findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return;
    if (!box.attached || !viewport.attached || !box.hasSize) return;
    final ring = box.localToGlobal(Offset.zero) & box.size;
    final view = viewport.localToGlobal(Offset.zero) & viewport.size;
    final visible = ring.overlaps(view);
    if (visible != _onScreen) {
      _onScreen = visible;
      _update();
    }
  }

  bool get _moving =>
      widget.animate &&
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
    final size = widget.size;
    final weight = FounderAnimatedAvatarRing._weight(size);
    final pad = FounderAnimatedAvatarRing.paddingFor(size);
    // Still: the glint rests at the upper left, where the light comes from.
    final light = _moving ? _controller : const AlwaysStoppedAnimation(.375);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Painted once: the undertone and the ring, behind the avatar.
        Positioned.fill(
          child: CustomPaint(
            painter: _RingPainter(size: size, weight: weight),
          ),
        ),
        Padding(padding: EdgeInsets.all(pad), child: widget.child),
        // Repainted each frame, alone in its own layer, so neither the
        // avatar nor the ring repaints with it: the halo and the glint.
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _LightPainter(light, size: size, weight: weight),
                willChange: _moving,
              ),
            ),
          ),
        ),
        // Painted once, around the ring: the laurel and the crown.
        if (size >= 48)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _LaurelPainter(size: size, weight: weight),
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

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.size, required this.weight});

  final double size;
  final double weight;

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    // The violet undertone, a little below centre, beneath the gold.
    final under = radius * 1.32;
    final underCenter = center + Offset(0, radius * .1);
    canvas.drawCircle(
      underCenter,
      under,
      Paint()
        ..shader = RadialGradient(
          colors: [
            FounderRingColors.violet.withValues(alpha: 0),
            FounderRingColors.violet.withValues(alpha: .16),
            FounderRingColors.violet.withValues(alpha: 0),
          ],
          stops: [radius * .8 / under, radius / under, 1],
        ).createShader(Rect.fromCircle(center: underCenter, radius: under)),
    );
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = weight
        ..isAntiAlias = true
        ..shader = const SweepGradient(
          colors: [
            FounderRingColors.champagne,
            FounderRingColors.bronze,
            FounderRingColors.champagne,
            FounderRingColors.platinum,
            FounderRingColors.champagne,
          ],
          stops: [0, .25, .5, .7, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.size != size || old.weight != weight;
}

/// The Founder's frame around the ring: two champagne laurel branches rising
/// from the bottom, either side, toward the crown set on top of the ring, the
/// Founder Collection's crown (tool/branding/sovereign_shared.mjs). The gap
/// where the branches meet at the foot holds the edit button. Painted once,
/// beyond the widget's bounds, so it takes no room.
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

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    final bounds = Rect.fromCircle(center: center, radius: radius * 1.5);
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
      ).createShader(bounds);

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
    final line = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.2, size * .014)
      ..shader = metal.shader;
    for (final (from, to) in [(112.0, 228.0), (68.0, -48.0)]) {
      final sign = (to - from).sign;
      final path = Path()..moveTo(on(from).dx, on(from).dy);
      for (var i = 1; i <= 24; i++) {
        final point = on(from + (to - from) * i / 24);
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, line);
      const pairs = 6;
      for (var i = 0; i < pairs; i++) {
        final t = (i + .5) / pairs;
        final at = from + (to - from) * t;
        final forward = at * math.pi / 180 + sign * math.pi / 2;
        final grow = 1 - t * .35;
        // Outward (away from the avatar), then inward and shorter.
        canvas.drawPath(
          _leaf(
            on(at),
            forward - sign * .62,
            size * .17 * grow,
            size * .05 * grow,
          ),
          metal,
        );
        canvas.drawPath(
          _leaf(
            on(at),
            forward + sign * .5,
            size * .11 * grow,
            size * .035 * grow,
          ),
          metal,
        );
      }
      canvas.drawPath(
        _leaf(
          on(to),
          to * math.pi / 180 + sign * math.pi / 2,
          size * .12,
          size * .036,
        ),
        metal,
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
    canvas.drawPath(
      crown.shift(Offset(0, 6 * k)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * k),
    );
    canvas.drawPath(
      crown,
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
        ).createShader(Rect.fromLTWH(left, top, width, _crownH * k)),
    );
    final jewel = Paint()
      ..isAntiAlias = true
      ..color = FounderRingColors.obsidian;
    for (final x in _jewels) {
      canvas.drawCircle(c(Offset(x, 134)), 7 * k, jewel);
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

class _LightPainter extends CustomPainter {
  _LightPainter(this.light, {required this.size, required this.weight})
    : super(repaint: light);

  /// 0 to 1 over one cycle.
  final Animation<double> light;
  final double size;
  final double weight;

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    final t = light.value;
    // The halo: a soft champagne light just outside the ring, breathing
    // between faint and a little less faint.
    final breath = .5 - .5 * math.cos(2 * math.pi * t);
    final outer = radius + (size * .12).clamp(4.0, 16.0);
    canvas.drawCircle(
      center,
      outer,
      Paint()
        ..shader = RadialGradient(
          colors: [
            FounderRingColors.champagne.withValues(alpha: 0),
            FounderRingColors.champagne.withValues(alpha: .09 + .07 * breath),
            FounderRingColors.champagne.withValues(alpha: 0),
          ],
          stops: [(radius - weight) / outer, radius / outer, 1],
        ).createShader(Rect.fromCircle(center: center, radius: outer)),
    );
    // The glint: a short arc of brighter metal with a fading tail, like
    // light moving across a polished rim rather than a spinner.
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = weight
        ..isAntiAlias = true
        ..shader = SweepGradient(
          colors: [
            FounderRingColors.platinum.withValues(alpha: 0),
            FounderRingColors.platinum.withValues(alpha: 0),
            const Color(0xFFFFF6DE).withValues(alpha: .85),
            FounderRingColors.platinum.withValues(alpha: 0),
          ],
          stops: const [0, .76, .9, .96],
          transform: GradientRotation(2 * math.pi * t),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_LightPainter old) =>
      old.light != light || old.size != size || old.weight != weight;
}

/// The Founder's gold for a small avatar: a fine champagne rim drawn over
/// its edge, still, taking no room, so the layouts around it do not move.
/// Only for the signed-in account, while it has FounderPerk.profileAccent;
/// anyone else's avatar is [child] unchanged.
class FounderAvatarRim extends StatelessWidget {
  const FounderAvatarRim({super.key, required this.child, this.supporters});

  final Widget child;

  /// Whose entitlement decides; [SupporterController.instance] when null.
  final SupporterController? supporters;

  @override
  Widget build(BuildContext context) {
    final supporters = this.supporters ?? SupporterController.instance;
    return ListenableBuilder(
      listenable: supporters,
      builder: (context, child) =>
          supporters.hasFounderPerk(FounderPerk.profileAccent)
          ? _rim(child!)
          : child!,
      child: child,
    );
  }

  static Widget _rim(Widget child) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      border: Border.fromBorderSide(
        BorderSide(color: FounderRingColors.champagne, width: 1.5),
      ),
    ),
    child: child,
  );
}
