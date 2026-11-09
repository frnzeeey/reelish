import 'package:flutter/material.dart';
import '../../models/subtitle_language.dart';
import '../../theme/reelish_icons.dart';
import 'package:video_player/video_player.dart';

import 'player_sheet.dart';

/// Picks an audio track. Returns the chosen track id, or null if dismissed.
abstract final class AudioTrackSheet {
  static const title = 'Audio & language';

  static Future<String?> show(
    BuildContext context,
    List<VideoAudioTrack> tracks,
  ) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => PlayerSheetFrame(
      icon: ReelishIcons.audioWave,
      title: title,
      children: [
        for (final (index, track) in tracks.indexed)
          PlayerSheetOption(
            title: AudioTrackLabel.title(track, index),
            detail: AudioTrackLabel.detail(tracks, index),
            selected: track.isSelected,
            trailing: 'Playing',
            onTap: () => Navigator.pop(context, track.id),
          ),
      ],
    ),
  );
}

/// How an audio track is named, from what the stream says about it and
/// nothing else: a language name when the stream gives a language, the
/// stream's own title when it adds something ("Commentary"), and
/// "Audio track N" when the stream gives neither.
abstract final class AudioTrackLabel {
  /// The track's language code (`ja`, `pt-BR`), or null when unknown.
  static String? language(VideoAudioTrack track) {
    for (final value in [track.language, track.label]) {
      final code = SubtitleLanguage.normalize(value);
      if (code != SubtitleLanguage.unknown) return code;
    }
    return null;
  }

  /// The row's title, such as `Japanese` or `English Commentary`.
  static String title(VideoAudioTrack track, int index) {
    final label = _label(track);
    final code = language(track);
    if (label != null && (code == null || _namesLanguage(label, code))) {
      // A bare code ("eng") reads better as its name; a longer title that
      // names the language ("English Commentary") is kept as it is.
      return _isBareLanguage(label, code)
          ? SubtitleLanguage.name(code!)
          : label;
    }
    if (code != null) return SubtitleLanguage.name(code);
    return 'Audio track ${index + 1}';
  }

  /// What sets [tracks]`[index]` apart: the stream's title when the row is
  /// named after the language, then channels and codec. Rows that would
  /// still read the same get their position, so no two look identical.
  static String detail(List<VideoAudioTrack> tracks, int index) {
    String plain(int i) => _detail(tracks[i], i);
    final own = plain(index);
    final ownTitle = title(tracks[index], index);
    final duplicate = [
      for (var i = 0; i < tracks.length; i++)
        if (i != index && title(tracks[i], i) == ownTitle && plain(i) == own) i,
    ].isNotEmpty;
    return [
      if (own.isNotEmpty) own,
      if (duplicate) 'Track ${index + 1}',
    ].join(' · ');
  }

  static String _detail(VideoAudioTrack track, int index) {
    final label = _label(track);
    final code = language(track);
    final labelShownAsTitle =
        label != null && (code == null || _namesLanguage(label, code));
    final channels = switch (track.channelCount) {
      null || 0 => null,
      1 => 'Mono',
      2 => 'Stereo',
      6 => '5.1',
      8 => '7.1',
      final count => '$count channels',
    };
    return [
      if (label != null && !labelShownAsTitle) label,
      ?channels,
      if (track.codec?.trim().isNotEmpty == true)
        track.codec!.trim().toUpperCase(),
    ].join(' · ');
  }

  static String? _label(VideoAudioTrack track) {
    final label = track.label?.trim();
    return label == null || label.isEmpty ? null : label;
  }

  /// Whether [label] is about language [code] ("English", "eng",
  /// "English Commentary"), as opposed to "stream_5" or "Surround".
  static bool _namesLanguage(String label, String code) =>
      SubtitleLanguage.normalize(label) == code;

  /// Whether [label] is only a language code or name, with nothing else.
  static bool _isBareLanguage(String label, String? code) {
    if (code == null || !_namesLanguage(label, code)) return false;
    final value = label.toLowerCase();
    return RegExp(r'^[a-z]{2,3}([-_][a-z0-9]{2,4})?$').hasMatch(value) ||
        value == SubtitleLanguage.name(code).toLowerCase();
  }
}
