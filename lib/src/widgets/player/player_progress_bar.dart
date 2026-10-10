import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../platform/device_capabilities.dart';
import '../../theme/glass_theme.dart';

/// Formats a playback time as `m:ss` or `h:mm:ss`.
String formatPlaybackTime(Duration duration) {
  if (duration.isNegative) duration = Duration.zero;
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

/// Rebuilds [builder] only when [selector]'s result changes, instead of on
/// every controller notification (position updates arrive several times a
/// second). Records compare by value, so several fields can be selected.
class PlayerValueSelector<T> extends StatefulWidget {
  const PlayerValueSelector({
    super.key,
    required this.controller,
    required this.selector,
    required this.builder,
  });

  final VideoPlayerController controller;
  final T Function(VideoPlayerValue value) selector;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<PlayerValueSelector<T>> createState() => _PlayerValueSelectorState<T>();
}

class _PlayerValueSelectorState<T> extends State<PlayerValueSelector<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.selector(widget.controller.value);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant PlayerValueSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _value = widget.selector(widget.controller.value);
  }

  void _changed() {
    final next = widget.selector(widget.controller.value);
    if (next != _value) setState(() => _value = next);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// Reelish's seek bar: thin while idle, emphasized while scrubbing, with a
/// time bubble above the thumb. Position updates repaint the bar directly
/// from the controller; no widgets rebuild during normal playback.
class PlayerProgressBar extends StatefulWidget {
  const PlayerProgressBar({
    super.key,
    required this.controller,
    required this.onSeek,
    this.onScrubChanged,
  });

  final VideoPlayerController controller;
  final ValueChanged<Duration> onSeek;

  /// Called with true when scrubbing starts and false when it ends, so the
  /// player can keep its controls visible meanwhile.
  final ValueChanged<bool>? onScrubChanged;

  @override
  State<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends State<PlayerProgressBar> {
  /// Scrub position as a fraction of the duration while dragging.
  double? _drag;

  Duration get _duration => widget.controller.value.duration;

  double _fractionAt(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  Duration _at(double fraction) =>
      Duration(milliseconds: (_duration.inMilliseconds * fraction).round());

  void _start(double fraction) {
    if (_duration <= Duration.zero) return;
    widget.onScrubChanged?.call(true);
    setState(() => _drag = fraction);
  }

  void _update(double fraction) {
    if (_drag == null) return;
    setState(() => _drag = fraction);
  }

  void _end() {
    _keyCommit?.cancel();
    final drag = _drag;
    if (drag == null) return;
    widget.onSeek(_at(drag));
    setState(() => _drag = null);
    widget.onScrubChanged?.call(false);
  }

  /// Remote focus (TV only). Focused, the bar thickens and Left/Right scrub:
  /// each press previews 10 s further, a held key speeds up to 30 s and then
  /// 60 s steps, and the seek happens once the keys rest (or on Select), so a
  /// long scrub costs one seek instead of one per press.
  bool _focused = false;
  Timer? _keyCommit;
  int _keyRepeats = 0;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final forward = key == LogicalKeyboardKey.arrowRight;
    if (forward || key == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyUpEvent) return KeyEventResult.handled;
      final duration = _duration;
      if (duration <= Duration.zero) return KeyEventResult.ignored;
      _keyRepeats = event is KeyRepeatEvent ? _keyRepeats + 1 : 0;
      final seconds = _keyRepeats > 15
          ? 60
          : _keyRepeats > 5
          ? 30
          : 10;
      final position = widget.controller.value.position.inMilliseconds;
      final base = _drag ?? position / duration.inMilliseconds;
      final step = seconds * 1000 / duration.inMilliseconds;
      if (_drag == null) widget.onScrubChanged?.call(true);
      setState(() => _drag = (base + (forward ? step : -step)).clamp(0, 1));
      _keyCommit?.cancel();
      _keyCommit = Timer(const Duration(milliseconds: 700), _end);
      return KeyEventResult.handled;
    }
    final select =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (select && _drag != null) {
      if (event is KeyDownEvent) _end();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onFocusChange(bool focused) {
    // Leaving the bar mid-scrub seeks to the previewed time.
    if (!focused && _keyCommit?.isActive == true) _end();
    setState(() => _focused = focused);
  }

  @override
  void dispose() {
    _keyCommit?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final drag = _drag;
      return Semantics(
        slider: true,
        label: 'Playback position',
        value: formatPlaybackTime(
          drag == null ? widget.controller.value.position : _at(drag),
        ),
        child: Focus(
          canRequestFocus: DeviceCapabilities.isTv,
          skipTraversal: !DeviceCapabilities.isTv,
          onKeyEvent: _onKey,
          onFocusChange: _onFocusChange,
          child: _gestures(width, drag),
        ),
      );
    },
  );

  Widget _gestures(double width, double? drag) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onHorizontalDragStart: (details) =>
        _start(_fractionAt(details.localPosition.dx, width)),
    onHorizontalDragUpdate: (details) =>
        _update(_fractionAt(details.localPosition.dx, width)),
    onHorizontalDragEnd: (_) => _end(),
    onHorizontalDragCancel: () {
      setState(() => _drag = null);
      widget.onScrubChanged?.call(false);
    },
    onTapUp: (details) {
      if (_duration <= Duration.zero) return;
      widget.onSeek(_at(_fractionAt(details.localPosition.dx, width)));
    },
    child: SizedBox(
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: drag == null && !_focused ? 0 : 1),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              builder: (context, emphasis, _) => CustomPaint(
                painter: _ProgressPainter(
                  controller: widget.controller,
                  dragFraction: drag,
                  emphasis: emphasis,
                  accent: GlassTheme.primary,
                ),
              ),
            ),
          ),
          if (drag != null)
            Positioned(
              left: (drag * width - 36).clamp(0.0, math.max(0, width - 72)),
              bottom: 30,
              width: 72,
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xE6101015),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0x26FFFFFF)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        formatPlaybackTime(_at(drag)),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.controller,
    required this.dragFraction,
    required this.emphasis,
    required this.accent,
  }) : super(repaint: controller);

  final VideoPlayerController controller;
  final double? dragFraction;

  /// 0 when idle, 1 while scrubbing.
  final double emphasis;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final value = controller.value;
    final durationMs = value.duration.inMilliseconds;
    double fractionOf(Duration time) => durationMs <= 0
        ? 0
        : (time.inMilliseconds / durationMs).clamp(0.0, 1.0);

    final trackHeight = 3 + 2 * emphasis;
    final centerY = size.height / 2;
    final radius = Radius.circular(trackHeight / 2);
    RRect bar(double from, double to) => RRect.fromLTRBR(
      size.width * from,
      centerY - trackHeight / 2,
      size.width * to,
      centerY + trackHeight / 2,
      radius,
    );

    canvas.drawRRect(bar(0, 1), Paint()..color = const Color(0x33FFFFFF));
    final buffered = Paint()..color = const Color(0x59FFFFFF);
    for (final range in value.buffered) {
      final start = fractionOf(range.start);
      final end = fractionOf(range.end);
      if (end > start) canvas.drawRRect(bar(start, end), buffered);
    }
    final played = dragFraction ?? fractionOf(value.position);
    if (played > 0) canvas.drawRRect(bar(0, played), Paint()..color = accent);
    if (durationMs > 0) {
      final thumbRadius = 6 + 2.5 * emphasis;
      final center = Offset(size.width * played, centerY);
      if (emphasis > 0) {
        canvas.drawCircle(
          center,
          thumbRadius + 7 * emphasis,
          Paint()..color = accent.withValues(alpha: .22 * emphasis),
        );
      }
      canvas.drawCircle(center, thumbRadius, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressPainter old) =>
      old.dragFraction != dragFraction ||
      old.emphasis != emphasis ||
      old.accent != accent ||
      !identical(old.controller, controller);
}
