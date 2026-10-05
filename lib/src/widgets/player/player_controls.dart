import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/glass_theme.dart';
import 'player_marquee_text.dart';
import 'player_progress_bar.dart';

/// Shared timing for player motion; controls should feel responsive rather
/// than decorative.
const playerFade = Duration(milliseconds: 220);

/// Translucent surface used instead of a blur: a backdrop filter over playing
/// video would be re-rendered every video frame.
const _glassFill = Color(0x6B000000);
const _glassBorder = Color(0x2EFFFFFF);

/// The playback controls drawn over the video. It never contains the video
/// itself, so showing, hiding or updating controls leaves the surface alone.
class PlayerControlsOverlay extends StatelessWidget {
  const PlayerControlsOverlay({
    super.key,
    required this.controller,
    required this.title,
    required this.subtitle,
    required this.sourceLabel,
    required this.subtitleEnabled,
    required this.showAudio,
    required this.showSources,
    required this.landscapeLocked,
    required this.onBack,
    required this.onTogglePlay,
    required this.onSeekBy,
    required this.onSeekTo,
    required this.onScrubChanged,
    required this.onSubtitles,
    required this.onAudio,
    required this.onSources,
    required this.onSettings,
    required this.onPip,
    required this.onRotate,
    this.onNextEpisode,
    this.nextEpisodeCountdown,
    this.onSpeedReset,
    this.pauseScreen,
  });

  final VideoPlayerController controller;
  final String title;

  /// Episode label (`S2 · E3`) or provider, under the title.
  final String subtitle;

  /// Current source, such as `1080p · Provider`.
  final String sourceLabel;
  final bool subtitleEnabled;
  final bool showAudio;
  final bool showSources;
  final bool landscapeLocked;
  final VoidCallback onBack;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeekBy;
  final ValueChanged<Duration> onSeekTo;
  final ValueChanged<bool> onScrubChanged;
  final VoidCallback onSubtitles;
  final VoidCallback onAudio;
  final VoidCallback onSources;
  final VoidCallback onSettings;
  final VoidCallback onPip;
  final VoidCallback onRotate;

  /// Set while the next episode is offered; shown as a bottom-row pill.
  final VoidCallback? onNextEpisode;
  final int? nextEpisodeCountdown;

  /// Returns playback to 1x from the speed pill; null opens settings.
  final VoidCallback? onSpeedReset;

  /// True while the pause screen shows its own play button and title; the
  /// center controls and the top-bar title then step aside for it.
  final ValueListenable<bool>? pauseScreen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth > constraints.maxHeight;
      return Stack(
        fit: StackFit.expand,
        children: [
          // Edge gradients keep text readable without darkening the middle.
          const IgnorePointer(
            child: Column(
              children: [
                _EdgeGradient(height: 132, top: true),
                Spacer(),
                _EdgeGradient(height: 190, top: false),
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  top: 4,
                  left: wide ? 12 : 4,
                  right: wide ? 12 : 4,
                  child: _TopBar(
                    title: title,
                    subtitle: subtitle,
                    subtitleEnabled: subtitleEnabled,
                    pauseScreen: pauseScreen,
                    onBack: onBack,
                    onSubtitles: onSubtitles,
                    onSettings: onSettings,
                  ),
                ),
                Center(
                  child: _HiddenDuringPauseScreen(
                    pauseScreen: pauseScreen,
                    child: _CenterControls(
                      controller: controller,
                      gap: wide ? 56 : 32,
                      playSize: wide ? 76 : 68,
                      onTogglePlay: onTogglePlay,
                      onSeekBy: onSeekBy,
                    ),
                  ),
                ),
                Positioned(
                  left: wide ? 20 : 12,
                  right: wide ? 20 : 12,
                  bottom: 6,
                  child: _BottomBar(
                    controller: controller,
                    sourceLabel: sourceLabel,
                    showAudio: showAudio,
                    showSources: showSources,
                    landscapeLocked: landscapeLocked,
                    onSeekTo: onSeekTo,
                    onScrubChanged: onScrubChanged,
                    onAudio: onAudio,
                    onSources: onSources,
                    onSettings: onSettings,
                    onPip: onPip,
                    onRotate: onRotate,
                    onNextEpisode: onNextEpisode,
                    nextEpisodeCountdown: nextEpisodeCountdown,
                    onSpeedReset: onSpeedReset,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// Fades [child] out, and makes it untappable, while the pause screen shows.
/// Hidden, it runs no animations (a scrolling title would otherwise keep
/// drawing frames for the whole pause).
class _HiddenDuringPauseScreen extends StatelessWidget {
  const _HiddenDuringPauseScreen({
    required this.pauseScreen,
    required this.child,
  });

  final ValueListenable<bool>? pauseScreen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final listenable = pauseScreen;
    if (listenable == null) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (context, hidden, child) => IgnorePointer(
        ignoring: hidden,
        child: AnimatedOpacity(
          opacity: hidden ? 0 : 1,
          duration: playerFade,
          curve: Curves.easeOutCubic,
          child: TickerMode(enabled: !hidden, child: child!),
        ),
      ),
      child: child,
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.subtitleEnabled,
    required this.onBack,
    required this.onSubtitles,
    required this.onSettings,
    this.pauseScreen,
  });

  final String title;
  final String subtitle;
  final bool subtitleEnabled;
  final ValueListenable<bool>? pauseScreen;
  final VoidCallback onBack;
  final VoidCallback onSubtitles;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      PlayerIconButton(
        icon: Icons.arrow_back_rounded,
        label: 'Back',
        onPressed: onBack,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: _HiddenDuringPauseScreen(
          pauseScreen: pauseScreen,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlayerMarqueeText(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.2,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 10)],
                ),
              ),
              if (subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      PlayerIconButton(
        icon: subtitleEnabled
            ? Icons.closed_caption_rounded
            : Icons.closed_caption_off_outlined,
        label: subtitleEnabled ? 'Subtitles on' : 'Subtitles',
        selected: subtitleEnabled,
        onPressed: onSubtitles,
      ),
      PlayerIconButton(
        icon: Icons.settings_outlined,
        label: 'Playback settings',
        onPressed: onSettings,
      ),
    ],
  );
}

class _CenterControls extends StatelessWidget {
  const _CenterControls({
    required this.controller,
    required this.gap,
    required this.playSize,
    required this.onTogglePlay,
    required this.onSeekBy,
  });

  final VideoPlayerController controller;
  final double gap;
  final double playSize;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeekBy;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _SeekButton(forward: false, onPressed: onSeekBy),
      SizedBox(width: gap),
      // Only playing/buffering/completed changes rebuild the play button.
      PlayerValueSelector<({bool playing, bool buffering, bool completed})>(
        controller: controller,
        selector: (value) => (
          playing: value.isPlaying,
          buffering: value.isBuffering,
          completed: value.isCompleted,
        ),
        builder: (context, state) => _PlayButton(
          size: playSize,
          playing: state.playing,
          buffering: state.buffering && state.playing,
          completed: state.completed && !state.playing,
          onPressed: onTogglePlay,
        ),
      ),
      SizedBox(width: gap),
      _SeekButton(forward: true, onPressed: onSeekBy),
    ],
  );
}

class _SeekButton extends StatelessWidget {
  const _SeekButton({required this.forward, required this.onPressed});

  final bool forward;
  final ValueChanged<Duration> onPressed;

  @override
  Widget build(BuildContext context) => PlayerIconButton(
    icon: forward ? Icons.forward_10_rounded : Icons.replay_10_rounded,
    label: forward ? 'Forward 10 seconds' : 'Back 10 seconds',
    size: 56,
    iconSize: 32,
    onPressed: () => onPressed(Duration(seconds: forward ? 10 : -10)),
  );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.size,
    required this.playing,
    required this.buffering,
    required this.completed,
    required this.onPressed,
  });

  final double size;
  final bool playing;
  final bool buffering;
  final bool completed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = completed ? 'Replay' : (playing ? 'Pause' : 'Play');
    final icon = completed
        ? Icons.replay_rounded
        : (playing ? Icons.pause_rounded : Icons.play_arrow_rounded);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: _glassFill,
        shape: const CircleBorder(side: BorderSide(color: _glassBorder)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (buffering)
                  SizedBox.square(
                    dimension: size - 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: GlassTheme.primary,
                    ),
                  ),
                // The icon follows player state; playback never waits on it.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutBack,
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: Tween(begin: .6, end: 1.0).animate(animation),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Icon(
                    icon,
                    key: ValueKey(icon),
                    size: size * .5,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.controller,
    required this.sourceLabel,
    required this.showAudio,
    required this.showSources,
    required this.landscapeLocked,
    required this.onSeekTo,
    required this.onScrubChanged,
    required this.onAudio,
    required this.onSources,
    required this.onSettings,
    required this.onPip,
    required this.onRotate,
    this.onNextEpisode,
    this.nextEpisodeCountdown,
    this.onSpeedReset,
  });

  final VideoPlayerController controller;
  final String sourceLabel;
  final bool showAudio;
  final bool showSources;
  final bool landscapeLocked;
  final ValueChanged<Duration> onSeekTo;
  final ValueChanged<bool> onScrubChanged;
  final VoidCallback onAudio;
  final VoidCallback onSources;
  final VoidCallback onSettings;
  final VoidCallback onPip;
  final VoidCallback onRotate;

  /// Set while the next episode is offered; shown as a bottom-row pill.
  final VoidCallback? onNextEpisode;
  final int? nextEpisodeCountdown;

  /// Returns playback to 1x from the speed pill; null opens settings.
  final VoidCallback? onSpeedReset;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          _TimeLabel(controller: controller, remaining: false),
          const SizedBox(width: 12),
          Expanded(
            child: PlayerProgressBar(
              controller: controller,
              onSeek: onSeekTo,
              onScrubChanged: onScrubChanged,
            ),
          ),
          const SizedBox(width: 12),
          _TimeLabel(controller: controller, remaining: true),
        ],
      ),
      Row(
        children: [
          // The pills take whatever width the trailing icons leave, so the
          // source label only truncates when space really runs out.
          Expanded(
            child: Row(
              children: [
                if (showSources)
                  Flexible(
                    child: _PillButton(
                      icon: Icons.video_library_outlined,
                      label: sourceLabel.isEmpty ? 'Source' : sourceLabel,
                      semanticLabel: 'Choose source. Current: $sourceLabel',
                      onPressed: onSources,
                    ),
                  ),
                if (showAudio) ...[
                  const SizedBox(width: 6),
                  _PillButton(
                    icon: Icons.graphic_eq_rounded,
                    label: 'Audio',
                    semanticLabel: 'Choose audio track',
                    onPressed: onAudio,
                  ),
                ],
                PlayerValueSelector<double>(
                  controller: controller,
                  selector: (value) => value.playbackSpeed,
                  builder: (context, speed) => speed == 1
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: _PillButton(
                            icon: Icons.speed_rounded,
                            label: '${_speedLabel(speed)}×',
                            semanticLabel: onSpeedReset == null
                                ? 'Playback speed ${_speedLabel(speed)}'
                                : 'Playback speed ${_speedLabel(speed)}. '
                                      'Reset to normal speed',
                            onPressed: onSpeedReset ?? onSettings,
                            trailingIcon: onSpeedReset == null
                                ? null
                                : Icons.close_rounded,
                            selected: true,
                          ),
                        ),
                ),
              ],
            ),
          ),
          if (onNextEpisode case final onNext?)
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 2),
              child: _PillButton(
                icon: Icons.skip_next_rounded,
                label: nextEpisodeCountdown == null
                    ? 'Next episode'
                    : 'Next episode · $nextEpisodeCountdown',
                semanticLabel: nextEpisodeCountdown == null
                    ? 'Play next episode'
                    : 'Next episode starts in $nextEpisodeCountdown seconds',
                onPressed: onNext,
                selected: true,
              ),
            ),
          PlayerIconButton(
            icon: Icons.picture_in_picture_alt_outlined,
            label: 'Picture in picture',
            onPressed: onPip,
          ),
          PlayerIconButton(
            icon: landscapeLocked
                ? Icons.screen_rotation_alt_rounded
                : Icons.stay_current_landscape_rounded,
            label: landscapeLocked ? 'Allow rotation' : 'Lock to landscape',
            onPressed: onRotate,
          ),
        ],
      ),
    ],
  );

  static String _speedLabel(double speed) =>
      speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : '$speed';
}

class _TimeLabel extends StatefulWidget {
  const _TimeLabel({required this.controller, required this.remaining});

  final VideoPlayerController controller;
  final bool remaining;

  @override
  State<_TimeLabel> createState() => _TimeLabelState();
}

class _TimeLabelState extends State<_TimeLabel> {
  /// The right label can show the total or the time left; tap to switch.
  bool _showRemaining = true;

  @override
  Widget build(BuildContext context) {
    // Rebuilds once per second of position, not on every update.
    final label = PlayerValueSelector<(int, int)>(
      controller: widget.controller,
      selector: (value) => (value.position.inSeconds, value.duration.inSeconds),
      builder: (context, time) {
        final position = Duration(seconds: time.$1);
        final duration = Duration(seconds: time.$2);
        final text = !widget.remaining
            ? formatPlaybackTime(position)
            : duration <= Duration.zero
            ? 'LIVE'
            : _showRemaining
            ? '-${formatPlaybackTime(duration - position)}'
            : formatPlaybackTime(duration);
        return Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: widget.remaining ? Colors.white70 : Colors.white,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
    if (!widget.remaining) return label;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _showRemaining = !_showRemaining),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: label,
      ),
    );
  }
}

/// A round, touch-friendly (48 dp) icon control.
class PlayerIconButton extends StatelessWidget {
  const PlayerIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.size = 48,
    this.iconSize = 24,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Semantics(
      button: true,
      label: label,
      selected: selected,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  icon,
                  size: iconSize,
                  color: Colors.white,
                  shadows: const [Shadow(color: Colors.black45, blurRadius: 8)],
                ),
                // Active state: a coral dot under the icon, so selection is
                // shown by shape as well as color.
                if (selected)
                  Positioned(
                    bottom: size / 2 - iconSize / 2 - 7,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: GlassTheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    this.selected = false,
    this.trailingIcon,
  });

  final IconData icon;
  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;
  final bool selected;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticLabel,
    excludeSemantics: true,
    child: Material(
      color: selected
          ? GlassTheme.primary.withValues(alpha: .16)
          : const Color(0x1FFFFFFF),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? GlassTheme.primary : Colors.white,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? GlassTheme.primary : Colors.white,
                    ),
                  ),
                ),
                if (trailingIcon case final trailing?) ...[
                  const SizedBox(width: 6),
                  Icon(
                    trailing,
                    size: 15,
                    color: selected ? GlassTheme.primary : Colors.white70,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _EdgeGradient extends StatelessWidget {
  const _EdgeGradient({required this.height, required this.top});

  final double height;
  final bool top;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: top
              ? const [Color(0x99000000), Color(0x00000000)]
              : const [Color(0xC7000000), Color(0x00000000)],
        ),
      ),
    ),
  );
}

/// One double-tap seek, shown briefly on the tapped side.
class SeekFlash {
  const SeekFlash({
    required this.forward,
    required this.seconds,
    required this.id,
  });

  final bool forward;
  final int seconds;

  /// Changes on every tap so repeated taps restart the animation.
  final int id;
}

/// Double-tap seek feedback: a soft translucent region on the tapped side
/// with the accumulated seconds. Lightweight: no blur, short fades.
class PlayerSeekFeedback extends StatefulWidget {
  const PlayerSeekFeedback({super.key, required this.flashes});

  final ValueListenable<SeekFlash?> flashes;

  @override
  State<PlayerSeekFeedback> createState() => _PlayerSeekFeedbackState();
}

class _PlayerSeekFeedbackState extends State<PlayerSeekFeedback> {
  SeekFlash? _flash;
  bool _visible = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.flashes.addListener(_changed);
  }

  @override
  void dispose() {
    widget.flashes.removeListener(_changed);
    _hide?.cancel();
    super.dispose();
  }

  void _changed() {
    final flash = widget.flashes.value;
    if (flash == null) return;
    setState(() {
      _flash = flash;
      _visible = true;
    });
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final flash = _flash;
    if (flash == null) return const SizedBox.shrink();
    final forward = flash.forward;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Align(
          alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: .36,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: forward
                      ? const Alignment(.9, 0)
                      : const Alignment(-.9, 0),
                  radius: .9,
                  colors: const [Color(0x2EFFFFFF), Color(0x00FFFFFF)],
                ),
              ),
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(flash.id),
                  tween: Tween(begin: .7, end: 1),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  builder: (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        forward
                            ? Icons.fast_forward_rounded
                            : Icons.fast_rewind_rounded,
                        size: 34,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${flash.seconds} seconds',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 8),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small ring shown while playback stalls. It waits [delay] before
/// appearing so brief buffering does not flicker, and stays out of the way
/// while the controls (whose play button shows its own ring) are visible.
class PlayerBufferingIndicator extends StatefulWidget {
  const PlayerBufferingIndicator({
    super.key,
    required this.controller,
    required this.controlsVisible,
    this.delay = const Duration(milliseconds: 450),
  });

  final VideoPlayerController controller;
  final ValueListenable<bool> controlsVisible;
  final Duration delay;

  @override
  State<PlayerBufferingIndicator> createState() =>
      _PlayerBufferingIndicatorState();
}

class _PlayerBufferingIndicatorState extends State<PlayerBufferingIndicator> {
  Timer? _delay;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _delay?.cancel();
    super.dispose();
  }

  void _changed() {
    final buffering = widget.controller.value.isBuffering;
    if (!buffering) {
      _delay?.cancel();
      _delay = null;
      if (_show) setState(() => _show = false);
    } else if (!_show && _delay == null) {
      _delay = Timer(widget.delay, () {
        _delay = null;
        if (mounted && widget.controller.value.isBuffering) {
          setState(() => _show = true);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ValueListenableBuilder<bool>(
      valueListenable: widget.controlsVisible,
      builder: (context, controlsVisible, _) => AnimatedOpacity(
        opacity: _show && !controlsVisible ? 1 : 0,
        duration: playerFade,
        child: Center(
          child: SizedBox.square(
            dimension: 44,
            child: CircularProgressIndicator(
              strokeWidth: 2.6,
              color: GlassTheme.primary,
              backgroundColor: const Color(0x26FFFFFF),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Shown while no video frame is available yet: a back button plus either a
/// quiet progress state or a recoverable error.
class PlayerStatusView extends StatelessWidget {
  const PlayerStatusView({
    super.key,
    required this.onBack,
    this.status,
    this.showSpinner = true,
    this.error,
  });

  final VoidCallback onBack;

  /// Progress text such as `Starting playback…`; null hides it.
  final String? status;
  final bool showSpinner;
  final Widget? error;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Center(
        child:
            error ??
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSpinner)
                  SizedBox.square(
                    dimension: 44,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: GlassTheme.primary,
                      backgroundColor: const Color(0x1FFFFFFF),
                    ),
                  ),
                if (status != null) ...[
                  const SizedBox(height: 18),
                  AnimatedSwitcher(
                    duration: playerFade,
                    child: Text(
                      status!,
                      key: ValueKey(status),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
      ),
      SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: PlayerIconButton(
              icon: Icons.arrow_back_rounded,
              label: 'Back',
              onPressed: onBack,
            ),
          ),
        ),
      ),
    ],
  );
}

/// The error state: a plain-language title, a short reason and the recovery
/// actions that make sense. Technical detail stays in development logs.
class PlayerErrorPanel extends StatelessWidget {
  const PlayerErrorPanel({
    super.key,
    required this.canTryAnother,
    required this.message,
    required this.sourceDetails,
    required this.onRetry,
    required this.onTryAnother,
  });

  final bool canTryAnother;
  final String message;
  final String sourceDetails;
  final VoidCallback onRetry;
  final VoidCallback onTryAnother;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: GlassTheme.primary.withValues(alpha: .14),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.error_outline_rounded,
              color: GlassTheme.primary,
              size: 28,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            canTryAnother
                ? 'Unable to play this source'
                : 'Unable to play this title right now',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
          ],
          if (sourceDetails.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              sourceDetails,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
          const SizedBox(height: 22),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              if (canTryAnother)
                FilledButton.icon(
                  onPressed: onTryAnother,
                  icon: const Icon(Icons.video_library_outlined, size: 18),
                  label: const Text('Try another source'),
                  style: _buttonStyle(filled: true),
                ),
              canTryAnother
                  ? OutlinedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Retry'),
                      style: _buttonStyle(filled: false),
                    )
                  : FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Retry'),
                      style: _buttonStyle(filled: true),
                    ),
            ],
          ),
        ],
      ),
    ),
  );

  static ButtonStyle _buttonStyle({required bool filled}) =>
      (filled ? FilledButton.styleFrom : OutlinedButton.styleFrom)(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: const StadiumBorder(),
        foregroundColor: filled ? null : Colors.white,
        side: filled ? null : const BorderSide(color: Color(0x4DFFFFFF)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      );
}

/// Near the end of an episode: offers the next one, with a cancellable
/// countdown when auto-play is enabled.
class NextEpisodeCard extends StatelessWidget {
  const NextEpisodeCard({
    super.key,
    required this.seriesName,
    this.nextLabel,
    required this.countdown,
    required this.onPlay,
    required this.onDismiss,
  });

  final String seriesName;

  /// The next episode, such as `S2 · E4 · The Crossing`, when known.
  final String? nextLabel;

  /// Seconds until auto-play, or null when waiting for the viewer.
  final int? countdown;
  final VoidCallback onPlay;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          countdown == null ? 'UP NEXT' : 'NEXT EPISODE IN $countdown',
          maxLines: 1,
          style: TextStyle(
            color: GlassTheme.primary,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: .8,
          ),
        ),
        const SizedBox(height: 4),
        PlayerMarqueeText(
          nextLabel ?? 'Next episode of $seriesName',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ],
    );
    final play = FilledButton.icon(
      onPressed: onPlay,
      icon: const Icon(Icons.play_arrow_rounded, size: 20),
      label: Text(countdown == null ? 'Play next' : 'Play now'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
    final dismiss = PlayerIconButton(
      icon: Icons.close_rounded,
      label: countdown == null ? 'Dismiss' : 'Cancel auto-play',
      onPressed: onDismiss,
    );
    return Material(
      color: const Color(0xE6141419),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _glassBorder),
      ),
      child: LayoutBuilder(
        // Narrow screens (portrait phones) stack the title above the
        // actions so neither gets squeezed.
        builder: (context, constraints) => constraints.maxWidth < 440
            ? Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: details,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: play),
                        dismiss,
                      ],
                    ),
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: details),
                    const SizedBox(width: 14),
                    play,
                    dismiss,
                  ],
                ),
              ),
      ),
    );
  }
}
