import 'package:flutter/material.dart';

/// Touch handling for the video area. A single tap always toggles the
/// controls; double-tap seeking, swipes and long-press speed are optional so
/// they can follow the viewer's gesture settings.
class GestureTouchLayer extends StatefulWidget {
  const GestureTouchLayer({
    super.key,
    required this.child,
    required this.onTap,
    this.onDoubleTap,
    this.onSwipe,
    this.onLongPressStart,
    this.onLongPressEnd,
  });
  final Widget child;
  final VoidCallback onTap;

  /// Called with true for the right half. Null disables double taps, so
  /// single taps are not delayed waiting for a possible second tap.
  final ValueChanged<bool>? onDoubleTap;
  final void Function(bool right, double amount)? onSwipe;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;
  @override
  State<GestureTouchLayer> createState() => _GestureTouchLayerState();
}

class _GestureTouchLayerState extends State<GestureTouchLayer> {
  double? _start;
  bool _right = false;
  @override
  Widget build(BuildContext context) {
    final onDoubleTap = widget.onDoubleTap;
    final onSwipe = widget.onSwipe;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      onDoubleTapDown: onDoubleTap == null
          ? null
          : (d) => onDoubleTap(
              d.localPosition.dx > MediaQuery.sizeOf(context).width / 2,
            ),
      // Required for onDoubleTapDown to be recognized.
      onDoubleTap: onDoubleTap == null ? null : () {},
      onLongPressStart: widget.onLongPressStart == null
          ? null
          : (_) => widget.onLongPressStart!(),
      onLongPressEnd: widget.onLongPressEnd == null
          ? null
          : (_) => widget.onLongPressEnd!(),
      onVerticalDragStart: onSwipe == null
          ? null
          : (d) {
              _start = d.localPosition.dy;
              _right =
                  d.localPosition.dx > MediaQuery.sizeOf(context).width / 2;
            },
      onVerticalDragUpdate: onSwipe == null
          ? null
          : (d) {
              final start = _start;
              if (start != null) {
                onSwipe(
                  _right,
                  (start - d.localPosition.dy) /
                      MediaQuery.sizeOf(context).height,
                );
              }
              _start = d.localPosition.dy;
            },
      child: widget.child,
    );
  }
}
