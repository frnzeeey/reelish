import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../theme/glass_theme.dart';

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
  Widget build(BuildContext context) =>
      ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) => SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const IgnorePointer(
                child: Column(
                  children: [
                    _Scrim(height: .31, top: true),
                    Spacer(),
                    _Scrim(height: .4, top: false),
                  ],
                ),
              ),
              Positioned(
                top: 8,
                left: 14,
                right: 14,
                child: _GlassPanel(
                  radius: 24,
                  padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
                  child: Row(
                    children: [
                      _RoundButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: onBack,
                      ),
                      const SizedBox(width: 5),
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
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (sourceLabel.isNotEmpty)
                              Text(
                                sourceLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      _RoundButton(
                        icon: Icons.closed_caption_rounded,
                        tooltip: 'Subtitles',
                        selected: subtitleEnabled,
                        onPressed: onSubtitles,
                      ),
                      _RoundButton(
                        icon: Icons.playlist_play_rounded,
                        tooltip: 'Choose stream',
                        onPressed: onStreams,
                      ),
                      _RoundButton(
                        icon: Icons.picture_in_picture_alt_rounded,
                        tooltip: 'Picture in picture',
                        onPressed: onPip,
                      ),
                      _RoundButton(
                        icon: Icons.tune_rounded,
                        tooltip: 'Playback settings',
                        onPressed: onSettings,
                      ),
                    ],
                  ),
                ),
              ),
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundButton(
                      icon: Icons.replay_10_rounded,
                      tooltip: 'Back 10 seconds',
                      size: 54,
                      iconSize: 30,
                      onPressed: () =>
                          onSeek(value.position - const Duration(seconds: 10)),
                    ),
                    const SizedBox(width: 28),
                    _PlayPauseButton(
                      playing: value.isPlaying,
                      buffering: value.isBuffering,
                      onPressed: onToggle,
                    ),
                    const SizedBox(width: 28),
                    _RoundButton(
                      icon: Icons.forward_10_rounded,
                      tooltip: 'Forward 10 seconds',
                      size: 54,
                      iconSize: 30,
                      onPressed: () =>
                          onSeek(value.position + const Duration(seconds: 10)),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: _GlassPanel(
                  radius: 23,
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 11),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            _time(value.position),
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            value.duration > Duration.zero
                                ? '-${_time(value.duration - value.position)}'
                                : '--:--',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontFeatures: [FontFeature.tabularFigures()],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        colors: const VideoProgressColors(
                          playedColor: GlassTheme.cyan,
                          bufferedColor: Color(0x88FFFFFF),
                          backgroundColor: Color(0x44FFFFFF),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(
                            value.isBuffering
                                ? Icons.downloading_rounded
                                : Icons.play_circle_outline_rounded,
                            size: 16,
                            color: value.isBuffering
                                ? GlassTheme.cyan
                                : Colors.white70,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            value.isBuffering ? 'Buffering' : 'Now playing',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const Spacer(),
                          _InfoPill(
                            icon: Icons.speed_rounded,
                            label: '${value.playbackSpeed}×',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    required this.padding,
    this.radius = 20,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: const Color(0xCC141A26),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withValues(alpha: .14)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .24),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: child,
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.size = 42,
    this.iconSize = 21,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: selected
          ? GlassTheme.cyan.withValues(alpha: .16)
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
            color: selected ? GlassTheme.cyan : Colors.white,
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
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: GlassTheme.gradient,
            boxShadow: [
              BoxShadow(
                color: GlassTheme.cyan.withValues(alpha: .36),
                blurRadius: 30,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Center(
            child: buffering
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      color: Color(0xFF07100F),
                      strokeWidth: 2.5,
                    ),
                  )
                : Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 42,
                    color: const Color(0xFF07100F),
                  ),
          ),
        ),
      ),
    ),
  );
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: GlassTheme.cyan),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
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
