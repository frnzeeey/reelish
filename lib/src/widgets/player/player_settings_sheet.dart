import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:video_player/video_player.dart';
import '../../models/stream_source.dart';
import '../glass_box.dart';

class PlayerSettings {
  const PlayerSettings({
    this.speed = 1,
    this.fit = BoxFit.contain,
    this.ratio = 0,
    this.subtitle,
    this.subtitleDelay = 0,
    this.videoTrack,
    this.audioTrackId,
    this.adjustSubtitlePosition = false,
  });
  final double speed;
  final BoxFit fit;
  final double ratio;
  final SubtitleTrack? subtitle;
  final double subtitleDelay;
  final VideoTrack? videoTrack;
  final String? audioTrackId;

  /// Set when the viewer asked to move subtitles; the player then shows its
  /// position panel, where the subtitles stay visible.
  final bool adjustSubtitlePosition;
  PlayerSettings copyWith({
    double? speed,
    BoxFit? fit,
    double? ratio,
    SubtitleTrack? subtitle,
    bool clearSubtitle = false,
    double? subtitleDelay,
    VideoTrack? videoTrack,
    bool clearVideoTrack = false,
    String? audioTrackId,
    bool? adjustSubtitlePosition,
  }) => PlayerSettings(
    speed: speed ?? this.speed,
    fit: fit ?? this.fit,
    ratio: ratio ?? this.ratio,
    subtitle: clearSubtitle ? null : (subtitle ?? this.subtitle),
    subtitleDelay: subtitleDelay ?? this.subtitleDelay,
    videoTrack: clearVideoTrack ? null : (videoTrack ?? this.videoTrack),
    audioTrackId: audioTrackId ?? this.audioTrackId,
    adjustSubtitlePosition:
        adjustSubtitlePosition ?? this.adjustSubtitlePosition,
  );
}

class PlayerSettingsSheet extends StatelessWidget {
  const PlayerSettingsSheet({
    super.key,
    required this.value,
    required this.subtitles,
    this.videoTracks = const [],
    this.audioTracks = const [],
  });
  final PlayerSettings value;
  final List<SubtitleTrack> subtitles;
  final List<VideoTrack> videoTracks;
  final List<VideoAudioTrack> audioTracks;
  static Future<PlayerSettings?> show(
    BuildContext context,
    PlayerSettings value,
    List<SubtitleTrack> subtitles, [
    List<VideoTrack> videoTracks = const [],
    List<VideoAudioTrack> audioTracks = const [],
  ]) => showModalBottomSheet<PlayerSettings>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => PlayerSettingsSheet(
      value: value,
      subtitles: subtitles,
      videoTracks: videoTracks,
      audioTracks: audioTracks,
    ),
  );
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: GlassBox(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Playback settings',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text('Speed'),
              Wrap(
                spacing: 6,
                children: [
                  for (final s in [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0])
                    ChoiceChip(
                      label: Text('${s}×'),
                      selected: value.speed == s,
                      onSelected: (_) =>
                          Navigator.pop(context, value.copyWith(speed: s)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (videoTracks.isNotEmpty) ...[
                const Text('Video quality'),
                Wrap(
                  spacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('Auto'),
                      selected: value.videoTrack == null,
                      onSelected: (_) => Navigator.pop(
                        context,
                        value.copyWith(clearVideoTrack: true),
                      ),
                    ),
                    for (final track in videoTracks)
                      ChoiceChip(
                        label: Text(
                          track.label ??
                              (track.height == null
                                  ? 'Track'
                                  : '${track.height}p'),
                        ),
                        selected: value.videoTrack == track,
                        onSelected: (_) => Navigator.pop(
                          context,
                          value.copyWith(videoTrack: track),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (audioTracks.length > 1) ...[
                const Text('Audio track'),
                for (final track in audioTracks)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      track.id == value.audioTrackId ||
                              (value.audioTrackId == null && track.isSelected)
                          ? Symbols.radio_button_checked_rounded
                          : Symbols.radio_button_unchecked_rounded,
                    ),
                    title: Text(track.label ?? track.language ?? 'Audio track'),
                    subtitle: Text(
                      [
                        if (track.language?.isNotEmpty == true) track.language!,
                        if (track.codec?.isNotEmpty == true) track.codec!,
                        if (track.channelCount != null)
                          '${track.channelCount} ch',
                      ].join(' · '),
                    ),
                    onTap: () => Navigator.pop(
                      context,
                      value.copyWith(audioTrackId: track.id),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
              const Text('Aspect ratio'),
              Wrap(
                spacing: 6,
                children: [
                  for (final item in [
                    (0.0, 'Auto'),
                    (16 / 9, '16:9'),
                    (4 / 3, '4:3'),
                  ])
                    ChoiceChip(
                      label: Text(item.$2),
                      selected: value.ratio == item.$1,
                      onSelected: (_) => Navigator.pop(
                        context,
                        value.copyWith(ratio: item.$1),
                      ),
                    ),
                ],
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final item in [
                    (BoxFit.contain, 'Fit'),
                    (BoxFit.cover, 'Fill'),
                    (BoxFit.fill, 'Stretch'),
                  ])
                    ChoiceChip(
                      label: Text(item.$2),
                      selected: value.fit == item.$1,
                      onSelected: (_) =>
                          Navigator.pop(context, value.copyWith(fit: item.$1)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('Subtitles'),
              Row(
                children: [
                  const Expanded(child: Text('Subtitle delay')),
                  IconButton(
                    tooltip: 'Earlier',
                    onPressed: () => Navigator.pop(
                      context,
                      value.copyWith(
                        subtitleDelay: (value.subtitleDelay - .25).clamp(-5, 5),
                      ),
                    ),
                    icon: const Icon(Symbols.do_not_disturb_on_rounded),
                  ),
                  Text('${value.subtitleDelay.toStringAsFixed(2)}s'),
                  IconButton(
                    tooltip: 'Later',
                    onPressed: () => Navigator.pop(
                      context,
                      value.copyWith(
                        subtitleDelay: (value.subtitleDelay + .25).clamp(-5, 5),
                      ),
                    ),
                    icon: const Icon(Symbols.add_circle_rounded),
                  ),
                ],
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Symbols.vertical_align_center_rounded),
                title: const Text('Subtitle position'),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.pop(
                  context,
                  value.copyWith(adjustSubtitlePosition: true),
                ),
              ),
              ListTile(
                title: const Text('Off'),
                onTap: () =>
                    Navigator.pop(context, value.copyWith(clearSubtitle: true)),
              ),
              for (final track in subtitles)
                ListTile(
                  title: Text(track.lang),
                  subtitle: Text(
                    track.format.isEmpty
                        ? track.url.split('/').last
                        : track.format,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () =>
                      Navigator.pop(context, value.copyWith(subtitle: track)),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
