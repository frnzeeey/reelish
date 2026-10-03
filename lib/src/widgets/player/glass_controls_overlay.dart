import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/glass_theme.dart';
import '../liquid_glass.dart';

class GlassControlsOverlay extends StatelessWidget {
  const GlassControlsOverlay({
    super.key,
    required this.controller,
    required this.title,
    required this.sourceLabel,
    required this.subtitleEnabled,
    required this.onBack,
    required this.onToggle,
    required this.onSeek,
    required this.onStreams,
    required this.onSettings,
    required this.onSubtitles,
    required this.onPip,
  });

  final VideoPlayerController controller;
  final String title;
  final String sourceLabel;
  final bool subtitleEnabled;
  final VoidCallback onBack;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onStreams;
  final VoidCallback onSettings;
  final VoidCallback onSubtitles;
  final VoidCallback onPip;

  String _time(Duration duration) {
    if (duration.isNegative) duration = Duration.zero;
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Stack(
      fit: StackFit.expand,
      children: [
        const IgnorePointer(
          child: Column(
            children: [
              _Scrim(height: .27, top: true),
              Spacer(),
              _Scrim(height: .52, top: false),
            ],
          ),
        ),
        Positioned(
          top: 8,
          left: 14,
          right: 14,
          child: Row(
            children: [
              _RoundButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onPressed: onBack,
                surface: true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 12),
                        ],
                      ),
                    ),
                    if (sourceLabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        sourceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 8),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          bottom: 10,
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: controller,
            builder: (context, value, _) => _ControlDock(
              position: value.position,
              duration: value.duration,
              playing: value.isPlaying,
              buffering: value.isBuffering,
              subtitleEnabled: subtitleEnabled,
              playbackSpeed: value.playbackSpeed,
              controller: controller,
              time: _time,
              onToggle: onToggle,
              onSeek: onSeek,
              onStreams: onStreams,
              onSettings: onSettings,
              onSubtitles: onSubtitles,
              onPip: onPip,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ControlDock extends StatelessWidget {
  const _ControlDock({
    required this.position,
    required this.duration,
    required this.playing,
    required this.buffering,
    required this.subtitleEnabled,
    required this.playbackSpeed,
    required this.controller,
    required this.time,
    required this.onToggle,
    required this.onSeek,
    required this.onStreams,
    required this.onSettings,
    required this.onSubtitles,
    required this.onPip,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final bool subtitleEnabled;
  final double playbackSpeed;
  final VideoPlayerController controller;
  final String Function(Duration) time;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onStreams;
  final VoidCallback onSettings;
  final VoidCallback onSubtitles;
  final VoidCallback onPip;

  @override
  Widget build(BuildContext context) => LiquidGlass(
    quality: LiquidGlassQuality.balanced,
    blurSigma: 8,
    opacity: .94,
    borderRadius: 22,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(time(position), style: _timeStyle),
            const Spacer(),
            Text(
              duration > Duration.zero
                  ? '-${time(duration - position)}'
                  : '--:--',
              style: _timeStyle.copyWith(color: Colors.white70),
            ),
          ],
        ),
        VideoProgressIndicator(
          controller,
          allowScrubbing: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          colors: VideoProgressColors(
            playedColor: GlassTheme.primary,
            bufferedColor: Color(0x99FFFFFF),
            backgroundColor: Color(0x44FFFFFF),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final actions = _utilityButtons();
            final transport = _transportButtons();

            if (constraints.maxWidth < 420) {
              return Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: actions,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: transport,
                  ),
                ],
              );
            }

            return Row(
              children: [
                ...actions,
                if (constraints.maxWidth >= 480) ...[
                  const SizedBox(width: 8),
                  _SpeedBadge(speed: playbackSpeed),
                ],
                const Spacer(),
                ...transport,
              ],
            );
          },
        ),
      ],
    ),
  );

  List<Widget> _utilityButtons() => [
    _RoundButton(
      icon: Icons.closed_caption_rounded,
      tooltip: 'Subtitles',
      selected: subtitleEnabled,
      onPressed: onSubtitles,
      size: 38,
      iconSize: 20,
    ),
    _RoundButton(
      icon: Icons.audiotrack_rounded,
      tooltip: 'Choose audio or stream',
      onPressed: onStreams,
      size: 38,
      iconSize: 20,
    ),
    _RoundButton(
      icon: Icons.picture_in_picture_alt_rounded,
      tooltip: 'Picture in picture',
      onPressed: onPip,
      size: 38,
      iconSize: 19,
    ),
    _RoundButton(
      icon: Icons.tune_rounded,
      tooltip: 'Playback settings',
      onPressed: onSettings,
      size: 38,
      iconSize: 19,
    ),
  ];

  List<Widget> _transportButtons() => [
    _RoundButton(
      icon: Icons.replay_10_rounded,
      tooltip: 'Back 10 seconds',
      onPressed: () => onSeek(position - const Duration(seconds: 10)),
      size: 42,
      iconSize: 24,
    ),
    const SizedBox(width: 3),
    _PlayPauseButton(
      playing: playing,
      buffering: buffering,
      onPressed: onToggle,
    ),
    const SizedBox(width: 3),
    _RoundButton(
      icon: Icons.forward_10_rounded,
      tooltip: 'Forward 10 seconds',
      onPressed: () => onSeek(position + const Duration(seconds: 10)),
      size: 42,
      iconSize: 24,
    ),
  ];

  static const _timeStyle = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );
}

class _SpeedBadge extends StatelessWidget {
  const _SpeedBadge({required this.speed});

  final double speed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      '$speed×',
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.surface = false,
    this.size = 42,
    this.iconSize = 21,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;
  final bool surface;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: selected
          ? GlassTheme.primary.withValues(alpha: .16)
          : surface
          ? const Color(0x66101520)
          : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: iconSize,
            color: selected ? GlassTheme.primary : Colors.white,
          ),
        ),
      ),
    ),
  );
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.playing,
    required this.buffering,
    required this.onPressed,
  });

  final bool playing;
  final bool buffering;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: playing ? 'Pause' : 'Play',
    child: Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Ink(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: GlassTheme.gradient,
            boxShadow: [
              BoxShadow(
                color: GlassTheme.coralGlow,
                blurRadius: 20,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Center(
            child: buffering
                ? const SizedBox(
                    width: 21,
                    height: 21,
                    child: CircularProgressIndicator(
                      color: GlassTheme.background,
                      strokeWidth: 2.3,
                    ),
                  )
                : Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 30,
                    color: GlassTheme.background,
                  ),
          ),
        ),
      ),
    ),
  );
}

class _Scrim extends StatelessWidget {
  const _Scrim({required this.height, required this.top});

  final double height;
  final bool top;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: const [Color(0xA8000000), Colors.transparent],
        ),
      ),
    ),
  );
}
