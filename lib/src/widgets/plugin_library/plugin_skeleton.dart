import 'package:flutter/material.dart';

import '../../theme/glass_theme.dart';

/// One shimmer animation shared by every placeholder below it.
class PluginShimmer extends StatefulWidget {
  const PluginShimmer({super.key, required this.child});

  final Widget child;

  @override
  State<PluginShimmer> createState() => _PluginShimmerState();
}

class _PluginShimmerState extends State<PluginShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) => ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (bounds) {
        final dx = (_controller.value * 3 - 1) * bounds.width;
        return LinearGradient(
          colors: [
            Colors.white.withValues(alpha: .05),
            Colors.white.withValues(alpha: .12),
            Colors.white.withValues(alpha: .05),
          ],
          stops: const [.35, .5, .65],
          transform: _Slide(dx),
        ).createShader(bounds);
      },
      child: child,
    ),
  );
}

class _Slide extends GradientTransform {
  const _Slide(this.dx);
  final double dx;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(dx, 0, 0);
}

/// Placeholder shaped like a [PluginCard].
class PluginCardSkeleton extends StatelessWidget {
  const PluginCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: GlassTheme.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: GlassTheme.border),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _Block(width: 46, height: 46, radius: 15),
            SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Block(width: 120, height: 14),
                SizedBox(height: 8),
                _Block(width: 74, height: 10),
              ],
            ),
          ],
        ),
        SizedBox(height: 16),
        Row(
          children: [
            _Block(width: 110, height: 24),
            SizedBox(width: 8),
            _Block(width: 84, height: 24),
          ],
        ),
        SizedBox(height: 14),
        Row(
          children: [
            _Block(width: 70, height: 22),
            SizedBox(width: 6),
            _Block(width: 86, height: 22),
            SizedBox(width: 6),
            _Block(width: 60, height: 22),
          ],
        ),
        Spacer(),
        Row(
          children: [
            Expanded(child: _Block(height: 44, radius: 22)),
            SizedBox(width: 8),
            Expanded(child: _Block(height: 44, radius: 22)),
          ],
        ),
      ],
    ),
  );
}

class _Block extends StatelessWidget {
  const _Block({this.width, required this.height, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}
