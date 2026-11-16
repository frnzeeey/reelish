// The Spotlight's animation presets: what each one is called, whether it is a
// supporter perk (SupporterPerk.spotlightMotion), and how it moves. A style is
// a pure function of where a card is (its distance from the centre, in
// pages), so the phone carousel, the settings preview and the tests share one
// definition, and nothing runs a timer or controller per card. Adding a
// preset: a value in [SpotlightMotion] and a [SpotlightMotionStyle].
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Every Spotlight animation. Ids are stored settings: keep them.
enum SpotlightMotion {
  cinematicDepth(
    'cinematic_depth',
    'Cinematic Depth',
    'Cards in 3D depth: the shown one in front, its neighbours turned '
        'slightly away, the artwork easing in as the title rises.',
    exclusive: false,
  ),
  minimal(
    'minimal',
    'Minimal Motion',
    'A plain slide with a soft fade. No depth or zoom.',
    exclusive: false,
  ),
  coverFlow(
    'cover_flow',
    'Classic Cover Flow',
    'Neighbours turn to face the shown card, as in a record shelf, and '
        'swing round as they arrive.',
    exclusive: true,
  ),
  reveal(
    'spotlight_reveal',
    'Spotlight Reveal',
    'Each title opens full width over the last, its artwork settling in '
        'and its details appearing one by one.',
    exclusive: true,
  ),
  floating(
    'floating_atmosphere',
    'Floating Atmosphere',
    'Cards drift gently, the shown one lifted on a soft shadow.',
    exclusive: true,
  ),
  stacked(
    'stacked_motion',
    'Stacked Motion',
    'Titles are laid on a pile: each new card lands on top, and the last '
        'sinks back into the stack, slightly turned.',
    exclusive: true,
  );

  const SpotlightMotion(
    this.id,
    this.label,
    this.description, {
    required this.exclusive,
  });

  final String id;
  final String label;
  final String description;

  /// A supporter perk; the others are free for everyone.
  final bool exclusive;

  /// What every account starts with, and falls back to.
  static const fallback = SpotlightMotion.cinematicDepth;

  /// The preset stored as [id], or null for an unknown or missing one.
  static SpotlightMotion? byId(String? id) {
    for (final motion in values) {
      if (motion.id == id) return motion;
    }
    return null;
  }

  SpotlightMotionStyle get style => switch (this) {
    cinematicDepth => const _CinematicDepth(),
    minimal => const _Minimal(),
    coverFlow => const _CoverFlow(),
    reveal => const _Reveal(),
    floating => const _Floating(),
    stacked => const _Stacked(),
  };
}

/// Where one card is drawn, as a function of its distance from the centre.
@immutable
class SpotlightCardFrame {
  const SpotlightCardFrame({
    required this.transform,
    this.opacity = 1,
    this.emphasis = 0,
    this.imageScale = 1,
    this.reveal = 1,
  });

  /// Applied around the card's centre.
  final Matrix4 transform;

  /// The whole card's opacity.
  final double opacity;

  /// 0–1: how strongly the card's shadow and glow show.
  final double emphasis;

  /// The backdrop's scale inside the card (1 = as laid out).
  final double imageScale;

  /// 0–1: how far the title and details have appeared.
  final double reveal;
}

/// How a preset moves the Spotlight.
abstract class SpotlightMotionStyle {
  const SpotlightMotionStyle();

  /// The share of the carousel's width one card takes: under 1, the
  /// neighbours show at the sides.
  double get viewportFraction;

  /// The shown card bobs gently ([SpotlightCardFrame] gets a phase).
  bool get floats => false;

  /// The title and details appear one after another rather than together.
  bool get staggered => false;

  /// The shown card has a shadow and, faintly, the accent's glow.
  bool get lifted => true;

  /// The card [delta] pages from the centre (negative: to the left), on a
  /// card [extent] wide; [float] is 0–1 through the bob's cycle.
  SpotlightCardFrame frame(double delta, double extent, {double float = 0});

  /// A detail line's reveal, [order] 0 first: with [staggered], later lines
  /// follow a little behind.
  double lineReveal(double reveal, int order) {
    if (!staggered) return reveal;
    final lag = order * .14;
    return ((reveal - lag) / (1 - lag)).clamp(0.0, 1.0);
  }

  /// Windows: how the backdrop changes. [animation] runs 0→1 for the
  /// incoming backdrop and 1→0 for the outgoing one ([incoming] says which).
  Widget backdropTransition(
    Widget child,
    Animation<double> animation, {
    required bool incoming,
  }) => FadeTransition(opacity: animation, child: child);

  /// Windows: how far (as a share of its height) the title block rises in.
  double get textRise => .04;
}

/// The distance clamped to the near neighbours: further cards are drawn
/// like the nearest neighbour.
double _near(double delta) => delta.clamp(-1.0, 1.0);

Matrix4 _perspective() => Matrix4.identity()..setEntry(3, 2, .0012);

/// A zoom from [from] to 1 on the incoming backdrop, with a fade.
Widget _zoomIn(Widget child, Animation<double> animation, double from) =>
    FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: from, end: 1).animate(animation),
        child: child,
      ),
    );

class _CinematicDepth extends SpotlightMotionStyle {
  const _CinematicDepth();

  @override
  double get viewportFraction => .86;

  @override
  SpotlightCardFrame frame(double delta, double extent, {double float = 0}) {
    final near = _near(delta);
    final away = near.abs();
    return SpotlightCardFrame(
      transform: _perspective()
        ..rotateY(-near * .22)
        ..scaleByDouble(1 - .1 * away, 1 - .1 * away, 1, 1),
      opacity: 1 - .35 * away,
      emphasis: 1 - away,
      imageScale: 1 + .06 * away,
      reveal: 1 - math.min(away * 1.6, 1),
    );
  }

  @override
  Widget backdropTransition(
    Widget child,
    Animation<double> animation, {
    required bool incoming,
  }) => _zoomIn(child, animation, 1.06);
}

class _Minimal extends SpotlightMotionStyle {
  const _Minimal();

  @override
  double get viewportFraction => 1;

  @override
  bool get lifted => false;

  @override
  SpotlightCardFrame frame(double delta, double extent, {double float = 0}) {
    final away = _near(delta).abs();
    final scale = 1 - .03 * away;
    return SpotlightCardFrame(
      transform: Matrix4.identity()..scaleByDouble(scale, scale, 1, 1),
      opacity: 1 - .4 * away,
      reveal: 1 - math.min(away * 2, 1),
    );
  }

  @override
  double get textRise => .02;
}

class _CoverFlow extends SpotlightMotionStyle {
  const _CoverFlow();

  @override
  double get viewportFraction => .72;

  @override
  SpotlightCardFrame frame(double delta, double extent, {double float = 0}) {
    final near = _near(delta);
    final away = near.abs();
    return SpotlightCardFrame(
      // Turned to face the centre, and drawn in a little towards it.
      transform: _perspective()
        ..translateByDouble(-near * extent * .12, 0, 0, 1)
        ..rotateY(-near * .85)
        ..scaleByDouble(1 - .12 * away, 1 - .12 * away, 1, 1),
      opacity: 1 - .2 * away,
      emphasis: 1 - away,
      // Only the card facing forward carries its words.
      reveal: 1 - math.min(away * 2.5, 1),
    );
  }

  @override
  Widget backdropTransition(
    Widget child,
    Animation<double> animation, {
    required bool incoming,
  }) => FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: Offset(incoming ? .06 : -.06, 0),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    ),
  );
}

class _Reveal extends SpotlightMotionStyle {
  const _Reveal();

  @override
  double get viewportFraction => 1;

  @override
  bool get staggered => true;

  @override
  SpotlightCardFrame frame(double delta, double extent, {double float = 0}) {
    final near = _near(delta);
    final away = near.abs();
    final Matrix4 transform;
    if (near < 0) {
      // Leaving: it stays behind, shrinking a little, while the next card
      // opens over it.
      final scale = 1 - .08 * away;
      transform = Matrix4.identity()
        ..translateByDouble(-near * extent * .6, 0, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    } else {
      // Arriving: it opens into focus.
      final scale = 1 - .08 * away;
      transform = Matrix4.identity()..scaleByDouble(scale, scale, 1, 1);
    }
    return SpotlightCardFrame(
      transform: transform,
      opacity: near < 0 ? 1 - .5 * away : 1,
      emphasis: 1 - away,
      imageScale: 1 + .1 * away,
      reveal: 1 - math.min(away * 1.4, 1),
    );
  }

  @override
  Widget backdropTransition(
    Widget child,
    Animation<double> animation, {
    required bool incoming,
  }) => _zoomIn(child, animation, 1.1);

  @override
  double get textRise => .08;
}

class _Floating extends SpotlightMotionStyle {
  const _Floating();

  @override
  double get viewportFraction => .88;

  @override
  bool get floats => true;

  @override
  SpotlightCardFrame frame(double delta, double extent, {double float = 0}) {
    final near = _near(delta);
    final away = near.abs();
    // Each card on its own phase, so neighbours never move in step.
    final bob = math.sin((float + delta * .25) * 2 * math.pi) * 5;
    final scale = 1 - .08 * away;
    return SpotlightCardFrame(
      transform: Matrix4.identity()
        ..translateByDouble(0, bob + 14 * away, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1),
      opacity: 1 - .3 * away,
      emphasis: 1 - away,
      imageScale: 1 + .03 * away,
      reveal: 1 - math.min(away * 1.6, 1),
    );
  }

  @override
  Widget backdropTransition(
    Widget child,
    Animation<double> animation, {
    required bool incoming,
  }) => FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, .025),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    ),
  );
}

class _Stacked extends SpotlightMotionStyle {
  const _Stacked();

  @override
  double get viewportFraction => .9;

  @override
  SpotlightCardFrame frame(double delta, double extent, {double float = 0}) {
    final away = delta.abs().clamp(0.0, 2.0);
    final Matrix4 transform;
    if (delta < 0) {
      // Behind the shown card: slid under it, smaller and turned a little,
      // the pile peeking out on the left.
      final scale = 1 - .07 * away;
      transform = Matrix4.identity()
        ..translateByDouble(-delta * extent * .85, 0, 0, 1)
        ..rotateZ(delta * .045)
        ..scaleByDouble(scale, scale, 1, 1);
    } else {
      // Arriving: laid on top, straightening as it lands.
      final near = math.min(delta, 1.0);
      final scale = 1 - .04 * near;
      transform = Matrix4.identity()
        ..rotateZ(near * .035)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    final near = math.min(away, 1.0);
    return SpotlightCardFrame(
      transform: transform,
      opacity: delta < 0 ? (1 - .35 * away).clamp(0.0, 1.0) : 1,
      emphasis: 1 - near,
      imageScale: 1 + .04 * near,
      reveal: 1 - math.min(near * 1.8, 1),
    );
  }

  @override
  Widget backdropTransition(
    Widget child,
    Animation<double> animation, {
    required bool incoming,
  }) => incoming
      // The new backdrop slides in over the old one, which sinks back.
      ? SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(.12, 0),
            end: Offset.zero,
          ).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        )
      : ScaleTransition(
          scale: Tween<double>(begin: .94, end: 1).animate(animation),
          child: child,
        );
}
