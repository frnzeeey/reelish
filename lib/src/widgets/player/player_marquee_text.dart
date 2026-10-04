import 'package:flutter/material.dart';

/// Single-line text that slowly scrolls when it does not fit: a pause, a
/// scroll to the end, another pause, then it starts over. Text that fits, or
/// any text when the system asks to reduce motion, is shown with an ellipsis.
///
/// It animates only while it overflows, and its ticker follows [TickerMode],
/// so it stops while the player controls are hidden.
class PlayerMarqueeText extends StatefulWidget {
  const PlayerMarqueeText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  static const _speed = 32.0; // logical pixels per second
  static const _startPause = Duration(milliseconds: 1800);
  static const _endPause = Duration(milliseconds: 1400);

  @override
  State<PlayerMarqueeText> createState() => _PlayerMarqueeTextState();
}

class _PlayerMarqueeTextState extends State<PlayerMarqueeText>
    with SingleTickerProviderStateMixin {
  // Created eagerly: a lazy controller would first be created in dispose()
  // for text that never scrolled, which is not allowed while unmounting.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  /// Overflow the controller is currently configured for; 0 when idle.
  double _animatedOverflow = 0;

  /// Fraction of the cycle spent before and after scrolling.
  double _scrollStart = 0, _scrollEnd = 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _configure(double overflow) {
    if (!mounted || overflow == _animatedOverflow) return;
    _animatedOverflow = overflow;
    if (overflow <= 0) {
      _controller
        ..stop()
        ..value = 0;
      return;
    }
    final scroll = Duration(
      milliseconds: (overflow / PlayerMarqueeText._speed * 1000).round(),
    );
    final total =
        PlayerMarqueeText._startPause + scroll + PlayerMarqueeText._endPause;
    _scrollStart =
        PlayerMarqueeText._startPause.inMilliseconds / total.inMilliseconds;
    _scrollEnd =
        (PlayerMarqueeText._startPause + scroll).inMilliseconds /
        total.inMilliseconds;
    _controller
      ..duration = total
      ..repeat();
  }

  double _offsetFraction(double t) {
    if (t <= _scrollStart) return 0;
    if (t >= _scrollEnd) return 1;
    return Curves.easeInOut.transform(
      (t - _scrollStart) / (_scrollEnd - _scrollStart),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final overflow = reduceMotion || !constraints.hasBoundedWidth
            ? 0.0
            : painter.width - constraints.maxWidth;
        final height = painter.height;
        painter.dispose();
        // Configure after this frame: starting the controller during build
        // would notify listeners mid-build.
        if (overflow.clamp(0, double.infinity) != _animatedOverflow) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _configure(overflow.clamp(0, double.infinity).toDouble()),
          );
        }
        if (overflow <= 0) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        return Semantics(
          label: widget.text,
          excludeSemantics: true,
          child: ClipRect(
            child: SizedBox(
              height: height,
              width: constraints.maxWidth,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => Transform.translate(
                  offset: Offset(
                    -overflow * _offsetFraction(_controller.value),
                    0,
                  ),
                  child: child,
                ),
                child: OverflowBox(
                  alignment: AlignmentDirectional.centerStart,
                  maxWidth: double.infinity,
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    style: widget.style,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
