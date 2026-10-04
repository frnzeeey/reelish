import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'player_sheet.dart';

/// Picks an audio track. Returns the chosen track id, or null if dismissed.
abstract final class AudioTrackSheet {
  static Future<String?> show(
    BuildContext context,
    List<VideoAudioTrack> tracks,
  ) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => PlayerSheetFrame(
      icon: Icons.graphic_eq_rounded,
      title: 'Audio',
      children: [
        for (final (index, track) in tracks.indexed)
          PlayerSheetOption(
            title: track.label?.trim().isNotEmpty == true
                ? track.label!.trim()
                : (track.language?.toUpperCase() ?? 'Track ${index + 1}'),
            detail: _detail(track),
            selected: track.isSelected,
            trailing: 'Playing',
            onTap: () => Navigator.pop(context, track.id),
          ),
      ],
    ),
  );

  /// Distinguishes tracks that share a language: channels, codec, language.
  static String _detail(VideoAudioTrack track) {
    final channels = switch (track.channelCount) {
      null || 0 => null,
      1 => 'Mono',
      2 => 'Stereo',
      6 => '5.1',
      8 => '7.1',
      final count => '$count channels',
    };
    return [
      if (track.language?.isNotEmpty == true &&
          track.label?.toLowerCase().contains(track.language!.toLowerCase()) !=
              true)
        track.language!.toUpperCase(),
      ?channels,
      if (track.codec?.isNotEmpty == true) track.codec!.toUpperCase(),
    ].join(' · ');
  }
}
