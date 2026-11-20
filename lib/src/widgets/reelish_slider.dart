// Reelish's slider: Material's Slider, less its OverlayPortal.
//
// Flutter 3.44's SemanticsOwner keeps every OverlayPortal it has seen as a
// key of `_traversalChildNodes` after the portal is gone, and Material's
// Slider shows one (its value indicator) as soon as it is built. With
// accessibility on (a screen reader, or any UI Automation client on
// Windows), every page with a Slider stayed in memory after it closed: the
// player's volume slider kept each closed player, about 1.5 MB per open
// (docs/playback/memory.md). Use this instead of Slider everywhere. It keeps
// what the app used: tap and drag, divisions, arrow keys (Left and Right
// only in directional navigation, as on TV), the focus and hover ring,
// slider semantics, and an optional gradient track. It has no value bubble:
// every Reelish slider shows its value beside it.
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ReelishSlider extends StatefulWidget {
  const ReelishSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.onChangeStart,
    this.onChangeEnd,
    this.focusNode,
    this.semanticFormatterCallback,
    this.thumbRadius = 10,
    this.overlayRadius = 20,
    this.trackColors,
    this.label,
  });

  final double value;
  final double min;
  final double max;

  /// Discrete steps between [min] and [max]; arrow keys move one step.
  final int? divisions;

  /// Null disables the slider.
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final FocusNode? focusNode;
  final String Function(double value)? semanticFormatterCallback;
  final double thumbRadius;

  /// The focus, hover and drag ring around the thumb; also the slider's
  /// height and the inset of the track at either end.
  final double overlayRadius;

  /// A gradient across the whole track (a colour or hue picker) instead of
  /// the active and inactive colours.
  final List<Color>? trackColors;

  /// What screen readers call the slider ("Subtitle size"); without it
  /// they announce only "slider" and the value.
  final String? label;

  @override
  State<ReelishSlider> createState() => _ReelishSliderState();
}

class _ReelishSliderState extends State<ReelishSlider> {
  FocusNode? _ownFocus;
  bool _focused = false;
  bool _hovered = false;
  bool _dragging = false;

  /// The value this gesture last reported, which the parent may not have
  /// rebuilt with yet when the gesture ends.
  double? _latest;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  bool get _enabled => widget.onChanged != null;

  double get _span => widget.max - widget.min;

  /// One arrow-key step: a division, else a twentieth.
  double get _step => _span / (widget.divisions ?? 20);

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  double _snap(double value) {
    var result = value.clamp(widget.min, widget.max);
    final divisions = widget.divisions;
    if (divisions != null && divisions > 0 && _span > 0) {
      final steps = ((result - widget.min) / _span * divisions).round();
      result = widget.min + steps * _span / divisions;
    }
    return result.toDouble();
  }

  double _valueAt(double dx, double width) {
    final inset = widget.overlayRadius;
    final track = (width - 2 * inset).clamp(1, double.infinity);
    final fraction = ((dx - inset) / track).clamp(0.0, 1.0);
    return _snap(widget.min + fraction * _span);
  }

  void _change(double value) {
    if (value == (_latest ?? widget.value)) return;
    _latest = value;
    widget.onChanged?.call(value);
  }

  void _start(double value) {
    _latest = null;
    setState(() => _dragging = true);
    widget.onChangeStart?.call(value);
    _change(value);
  }

  void _end() {
    // A tap that wins over the drag also cancels the drag; only a gesture
    // that started ends.
    if (!_dragging) return;
    final value = _latest ?? widget.value;
    _latest = null;
    setState(() => _dragging = false);
    widget.onChangeEnd?.call(value);
  }

  /// A step from the keyboard or an accessibility action: a whole change,
  /// with its start and end, as Material's slider reports it.
  void _nudge(int direction) {
    if (!_enabled) return;
    final next = _snap(widget.value + direction * _step);
    _start(widget.value);
    _change(next);
    _end();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabled || event is KeyUpEvent) return KeyEventResult.ignored;
    final directional =
        MediaQuery.maybeNavigationModeOf(context) == NavigationMode.directional;
    final key = event.logicalKey;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    if (key == LogicalKeyboardKey.arrowRight) {
      _nudge(rtl ? -1 : 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _nudge(rtl ? 1 : -1);
    } else if (!directional && key == LogicalKeyboardKey.arrowUp) {
      _nudge(1);
    } else if (!directional && key == LogicalKeyboardKey.arrowDown) {
      _nudge(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  String _describe(double value) =>
      widget.semanticFormatterCallback?.call(value) ??
      '${((value - widget.min) / (_span == 0 ? 1 : _span) * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final theme = SliderTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active = theme.activeTrackColor ?? scheme.primary;
    final colors = _SliderColors(
      active: _enabled ? active : active.withValues(alpha: .38),
      inactive: theme.inactiveTrackColor ?? active.withValues(alpha: .24),
      thumb: _enabled
          ? (theme.thumbColor ?? active)
          : (theme.thumbColor ?? active).withValues(alpha: .38),
      overlay: theme.overlayColor ?? active.withValues(alpha: .12),
    );
    final fraction = _span == 0
        ? 0.0
        : ((widget.value - widget.min) / _span).clamp(0.0, 1.0);
    final next = _snap(widget.value + _step);
    final previous = _snap(widget.value - _step);
    return Semantics(
      slider: true,
      label: widget.label,
      enabled: _enabled,
      focusable: _enabled,
      focused: _focused,
      value: _describe(widget.value),
      increasedValue: next == widget.value ? null : _describe(next),
      decreasedValue: previous == widget.value ? null : _describe(previous),
      onIncrease: _enabled && next != widget.value ? () => _nudge(1) : null,
      onDecrease: _enabled && previous != widget.value
          ? () => _nudge(-1)
          : null,
      child: Focus(
        focusNode: _focus,
        canRequestFocus: _enabled,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Screen readers only raise and lower the value (the
                // Semantics above); the gestures never add actions of
                // their own.
                excludeFromSemantics: true,
                // A tap counts on release, so a drag never first commits
                // the point it started from.
                onTapUp: _enabled
                    ? (details) {
                        _start(widget.value);
                        _change(_valueAt(details.localPosition.dx, width));
                        _end();
                      }
                    : null,
                onHorizontalDragStart: _enabled
                    ? (details) {
                        _start(widget.value);
                        _change(_valueAt(details.localPosition.dx, width));
                      }
                    : null,
                onHorizontalDragUpdate: _enabled
                    ? (details) =>
                          _change(_valueAt(details.localPosition.dx, width))
                    : null,
                onHorizontalDragEnd: _enabled ? (_) => _end() : null,
                onHorizontalDragCancel: _enabled ? _end : null,
                child: SizedBox(
                  width: width,
                  height: widget.overlayRadius * 2,
                  child: CustomPaint(
                    painter: _SliderPainter(
                      fraction: fraction,
                      colors: colors,
                      trackHeight: theme.trackHeight ?? 4,
                      gradient: widget.trackColors,
                      thumbRadius: widget.thumbRadius,
                      overlayRadius: widget.overlayRadius,
                      ring: _enabled && (_focused || _hovered || _dragging),
                      rtl: Directionality.of(context) == TextDirection.rtl,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

@immutable
class _SliderColors {
  const _SliderColors({
    required this.active,
    required this.inactive,
    required this.thumb,
    required this.overlay,
  });

  final Color active;
  final Color inactive;
  final Color thumb;
  final Color overlay;

  @override
  bool operator ==(Object other) =>
      other is _SliderColors &&
      other.active == active &&
      other.inactive == inactive &&
      other.thumb == thumb &&
      other.overlay == overlay;

  @override
  int get hashCode => Object.hash(active, inactive, thumb, overlay);
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({
    required this.fraction,
    required this.colors,
    required this.trackHeight,
    required this.thumbRadius,
    required this.overlayRadius,
    required this.ring,
    required this.rtl,
    this.gradient,
  });

  final double fraction;
  final List<Color>? gradient;
  final _SliderColors colors;
  final double trackHeight;
  final double thumbRadius;
  final double overlayRadius;
  final bool ring;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final start = overlayRadius;
    final end = size.width - overlayRadius;
    final along = start + (end - start) * (rtl ? 1 - fraction : fraction);
    final radius = Radius.circular(trackHeight / 2);
    final track = Rect.fromLTRB(
      start,
      y - trackHeight / 2,
      end,
      y + trackHeight / 2,
    );
    final gradient = this.gradient;
    if (gradient != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(track, radius),
        Paint()..shader = LinearGradient(colors: gradient).createShader(track),
      );
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(track, radius),
        Paint()..color = colors.inactive,
      );
    }
    final filled = rtl
        ? Rect.fromLTRB(along, track.top, end, track.bottom)
        : Rect.fromLTRB(start, track.top, along, track.bottom);
    if (gradient == null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(filled, radius),
        Paint()..color = colors.active,
      );
    }
    if (ring) {
      canvas.drawCircle(
        Offset(along, y),
        overlayRadius,
        Paint()..color = colors.overlay,
      );
    }
    canvas.drawCircle(
      Offset(along, y),
      thumbRadius,
      Paint()..color = colors.thumb,
    );
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.fraction != fraction ||
      old.colors != colors ||
      old.trackHeight != trackHeight ||
      old.thumbRadius != thumbRadius ||
      old.overlayRadius != overlayRadius ||
      old.ring != ring ||
      old.rtl != rtl ||
      !listEquals(old.gradient, gradient);
}
