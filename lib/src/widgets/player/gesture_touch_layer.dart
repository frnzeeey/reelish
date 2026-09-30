import 'package:flutter/material.dart';

class GestureTouchLayer extends StatefulWidget {
  const GestureTouchLayer({
    super.key,
    required this.child,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSwipe,
    this.onLongPressStart,
    this.onLongPressEnd,
  });
  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onDoubleTap;
  final void Function(bool right, double amount) onSwipe;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;
  @override
  State<GestureTouchLayer> createState() => _GestureTouchLayerState();
}

class _GestureTouchLayerState extends State<GestureTouchLayer> {
  double? _start;
  bool _right = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: widget.onTap,
    onDoubleTapDown: (d) {
      final width = MediaQuery.sizeOf(context).width;
      widget.onDoubleTap(d.localPosition.dx > width / 2);
    },
    onLongPressStart: widget.onLongPressStart == null
        ? null
        : (_) => widget.onLongPressStart!(),
    onLongPressEnd: widget.onLongPressEnd == null
        ? null
        : (_) => widget.onLongPressEnd!(),
    onVerticalDragStart: (d) {
      _start = d.localPosition.dy;
      _right = d.localPosition.dx > MediaQuery.sizeOf(context).width / 2;
    },
    onVerticalDragUpdate: (d) {
      final start = _start;
      if (start != null)
        widget.onSwipe(
          _right,
          (start - d.localPosition.dy) / MediaQuery.sizeOf(context).height,
        );
      _start = d.localPosition.dy;
    },
    child: widget.child,
  );
}
