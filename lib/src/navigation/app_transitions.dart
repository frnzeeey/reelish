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
               : (details ? 280 : 240),
         ),
         reverseTransitionDuration: Duration(
           milliseconds:
               (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
               ? 1
               : (details ? 240 : 220),
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
    // The same ease-out curve runs backward on pop, which gives the exit a
    // gentle start and a quicker finish without allocating a curve listener
    // on every route animation frame.
    final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    final slide = _reducedMotion
        ? const AlwaysStoppedAnimation<Offset>(Offset.zero)
        : Tween<Offset>(
            begin: Offset(0, _details ? .02 : .012),
            end: Offset.zero,
          ).animate(curved);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(position: slide, child: child),
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
  late final CurvedAnimation _opacity;
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
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }
}
