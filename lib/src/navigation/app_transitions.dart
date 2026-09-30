import 'package:flutter/material.dart';

/// Shared transitions for standard pushed pages and media detail pages.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool details = false,
  }) : _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false,
       _details = details,
       super(
         settings: settings,
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionDuration: Duration(
           milliseconds:
               (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
               ? 1
               : (details ? 300 : 280),
         ),
         reverseTransitionDuration: Duration(
           milliseconds:
               (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
               ? 1
               : (details ? 250 : 240),
         ),
       );

  final bool _reducedMotion;
  final bool _details;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final scaleStart = _reducedMotion ? 1.0 : 0.985;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, transitionedChild) {
        final isExiting = animation.status == AnimationStatus.reverse;
        final shouldSlide = !_reducedMotion && (_details || !isExiting);
        final verticalDistance = _details ? 0.025 : 0.018;
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: shouldSlide ? Offset(0, verticalDistance) : Offset.zero,
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: scaleStart, end: 1).animate(curved),
              child: transitionedChild,
            ),
          ),
        );
      },
    );
  }
}

/// Enters a retained bottom-navigation tab with a short fade and lift.
class TabPageTransition extends StatefulWidget {
  const TabPageTransition({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<TabPageTransition> createState() => _TabPageTransitionState();
}

class _TabPageTransitionState extends State<TabPageTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _position;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: widget.active ? 1 : 0,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _position = Tween<Offset>(
      begin: const Offset(0, .018),
      end: Offset.zero,
    ).animate(_opacity);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _controller.duration = Duration(milliseconds: _reducedMotion ? 1 : 200);
  }

  @override
  void didUpdateWidget(covariant TabPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _controller.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final position = _reducedMotion
        ? const AlwaysStoppedAnimation<Offset>(Offset.zero)
        : _position;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: position, child: widget.child),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
