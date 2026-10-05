import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/playback_settings.dart';

/// A compact panel at the top of the player for moving subtitles while they
/// stay in view. Changes apply live through [onChanged]; [onCommit] is called
/// when a change is final and should be saved.
class SubtitlePositionPanel extends StatelessWidget {
  const SubtitlePositionPanel({
    super.key,
    required this.position,
    required this.onChanged,
    required this.onCommit,
    required this.onDone,
  });

  final ValueListenable<double> position;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onDone;

  static const _step = .02;

  void _set(double value) {
    // Snap to the slider's steps so repeated taps cannot drift off them.
    final clamped = ((value / _step).round() * _step)
        .clamp(
          PlaybackSettings.subtitlePositionMin,
          PlaybackSettings.subtitlePositionMax,
        )
        .toDouble();
    onChanged(clamped);
    onCommit(clamped);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    minimum: const EdgeInsets.all(12),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xE6101015),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0x2EFFFFFF)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: ValueListenableBuilder<double>(
              valueListenable: position,
              builder: (context, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Subtitle position',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        subtitlePositionLabel(value),
                        style: const TextStyle(color: Colors.white70),
                      ),
                      TextButton(
                        onPressed: value == 0 ? null : () => _set(0),
                        child: const Text('Reset'),
                      ),
                      TextButton(onPressed: onDone, child: const Text('Done')),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Lower',
                        onPressed: value <= PlaybackSettings.subtitlePositionMin
                            ? null
                            : () => _set(value - _step),
                        icon: const Icon(Symbols.arrow_downward_rounded),
                      ),
                      Expanded(
                        child: Slider(
                          value: value,
                          min: PlaybackSettings.subtitlePositionMin,
                          max: PlaybackSettings.subtitlePositionMax,
                          divisions: 25,
                          onChanged: onChanged,
                          onChangeEnd: onCommit,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Higher',
                        onPressed: value >= PlaybackSettings.subtitlePositionMax
                            ? null
                            : () => _set(value + _step),
                        icon: const Icon(Symbols.arrow_upward_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
