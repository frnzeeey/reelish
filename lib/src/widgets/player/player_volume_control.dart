import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import 'player_controls.dart';

/// The Windows player's volume: a speaker button that mutes and unmutes,
/// and a slider with the level that slides out while the pointer is over
/// the control or keyboard focus is inside it.
///
/// [volume] is the player's level (0–1, where 0 is muted). The slider
/// reports every drag step with `commit: false` and the release with
/// `commit: true`; the owner decides how often the engine hears about it.
class PlayerVolumeControl extends StatefulWidget {
  const PlayerVolumeControl({
    super.key,
    required this.volume,
    required this.onChanged,
    required this.onToggleMute,
  });

  final ValueListenable<double> volume;
  final void Function(double value, {required bool commit}) onChanged;
  final VoidCallback onToggleMute;

  /// The speaker for [volume]: crossed out at 0, then one to three waves.
  static IconData iconFor(double volume) => volume <= 0
      ? Symbols.volume_off_rounded
      : volume < .34
      ? Symbols.volume_mute_rounded
      : volume < .67
      ? Symbols.volume_down_rounded
      : Symbols.volume_up_rounded;

  @override
  State<PlayerVolumeControl> createState() => _PlayerVolumeControlState();
}

class _PlayerVolumeControlState extends State<PlayerVolumeControl> {
  bool _hovered = false;
  bool _focused = false;
  bool _dragging = false;

  static const _sliderWidth = 112.0;
  static const _labelWidth = 44.0;

  void _set(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) {
    final open = _hovered || _focused || _dragging;
    return MouseRegion(
      onEnter: (_) => _set(() => _hovered = true),
      onExit: (_) => _set(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (value) => _set(() => _focused = value),
        child: ValueListenableBuilder<double>(
          valueListenable: widget.volume,
          builder: (context, volume, _) {
            final percent = (volume * 100).round();
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Collapsed to nothing at rest; still reachable with Tab,
                // which opens it. It opens to the speaker's left: the bar's
                // trailing buttons are right-aligned, so opening to the
                // right would slide the speaker out from under the pointer.
                ClipRect(
                  child: AnimatedContainer(
                    duration: AppMotion.resolve(context, AppMotion.standard),
                    curve: AppMotion.move,
                    width: open ? _sliderWidth + _labelWidth : 0,
                    // The speaker's height: the overflow box needs a bound.
                    height: 48,
                    child: OverflowBox(
                      alignment: Alignment.centerRight,
                      minWidth: _sliderWidth + _labelWidth,
                      maxWidth: _sliderWidth + _labelWidth,
                      child: Row(
                        children: [
                          SizedBox(
                            width: _labelWidth,
                            child: ExcludeSemantics(
                              child: Text(
                                '$percent%',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: AppTextSize.label,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                  shadows: [
                                    Shadow(
                                      color: Colors.black45,
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: _sliderWidth,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                activeTrackColor: GlassTheme.primary,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                                overlayColor: GlassTheme.primary.withValues(
                                  alpha: .22,
                                ),
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 14,
                                ),
                              ),
                              // Its own node: merged, the label would join the
                              // speaker button's.
                              child: Semantics(
                                container: true,
                                label: 'Volume',
                                child: Slider(
                                  value: volume.clamp(0, 1),
                                  divisions: 20,
                                  semanticFormatterCallback: (value) =>
                                      '${(value * 100).round()}%',
                                  onChangeStart: (_) =>
                                      _set(() => _dragging = true),
                                  onChanged: (value) =>
                                      widget.onChanged(value, commit: false),
                                  onChangeEnd: (value) {
                                    _set(() => _dragging = false);
                                    widget.onChanged(value, commit: true);
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                PlayerIconButton(
                  icon: PlayerVolumeControl.iconFor(volume),
                  label: volume <= 0 ? 'Unmute (M)' : 'Mute (M)',
                  selected: volume <= 0,
                  onPressed: widget.onToggleMute,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
