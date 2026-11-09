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
        // Painted once, over the ring and the avatar's edge: the crown.
        if (size >= 48)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CrownPainter(size: size, weight: weight),
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

/// The Sovereign Crest's diadem on a small obsidian disc at the ring's upper
/// right, set into it. The edit button keeps the lower right.
class _CrownPainter extends CustomPainter {
  const _CrownPainter({required this.size, required this.weight});

  final double size;
  final double weight;

  @override
  void paint(Canvas canvas, Size box) {
    final (:center, :radius) = _circle(box, size, weight);
    final disc = (size * .1).clamp(8.0, 14.0);
    const angle = -math.pi / 4;
    final at = center + Offset(math.cos(angle), math.sin(angle)) * radius;
    canvas.drawCircle(
      at,
      disc,
      Paint()
        ..color = FounderRingColors.obsidian
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      at,
      disc - weight * .35,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = weight * .7
        ..isAntiAlias = true
        ..color = FounderRingColors.champagne,
    );
    // Three points, the middle tallest, on a band: the crest's diadem.
    final w = disc * 1.12;
    final h = disc * .82;
    final left = at.dx - w / 2;
    final top = at.dy - h / 2;
    Offset p(double x, double y) => Offset(left + w * x, top + h * y);
    final diadem = Path()
      ..moveTo(p(0, 1).dx, p(0, 1).dy)
      ..lineTo(p(0, .3).dx, p(0, .3).dy)
      ..lineTo(p(.25, .58).dx, p(.25, .58).dy)
      ..lineTo(p(.5, 0).dx, p(.5, 0).dy)
      ..lineTo(p(.75, .58).dx, p(.75, .58).dy)
      ..lineTo(p(1, .3).dx, p(1, .3).dy)
      ..lineTo(p(1, 1).dx, p(1, 1).dy)
      ..close();
    canvas.drawPath(
      diadem,
      Paint()
        ..isAntiAlias = true
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [FounderRingColors.platinum, FounderRingColors.bronze],
        ).createShader(Rect.fromLTWH(left, top, w, h)),
    );
  }

  @override
  bool shouldRepaint(_CrownPainter old) =>
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
