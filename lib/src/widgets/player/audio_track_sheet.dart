import 'package:flutter/material.dart';
import '../../models/subtitle_language.dart';
import '../../theme/reelish_icons.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart'
    show MpvAudioTrackInfo;

import 'player_sheet.dart';

/// Picks an audio track. Returns the chosen track id, or null if dismissed.
abstract final class AudioTrackSheet {
  static const title = 'Audio & language';

  /// [info] is libmpv's extra metadata by track id (empty on Media3).
  static Future<String?> show(
    BuildContext context,
    List<VideoAudioTrack> tracks, {
    Map<String, MpvAudioTrackInfo> info = const {},
  }) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => PlayerSheetFrame(
      icon: ReelishIcons.audioWave,
      title: title,
      children: [
        for (final (index, track) in tracks.indexed)
          PlayerSheetOption(
            title: AudioTrackLabel.title(track, index, info),
            detail: AudioTrackLabel.detail(tracks, index, info),
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
/// stream's own title when it adds something ("Commentary"), its codec and
/// channels when it gives neither ("DTS · 5.1"), and "Audio track N" only
/// when the stream says nothing at all.
///
/// The optional `info` map is libmpv's extra metadata
/// ([MpvAudioTrackInfo]: flags, channel layout, HLS variant); Media3 has
/// none, and every rule works without it.
abstract final class AudioTrackLabel {
  /// The track's language code (`ja`, `pt-BR`), or null when unknown.
  static String? language(VideoAudioTrack track) {
    for (final value in [track.language, track.label]) {
      final code = SubtitleLanguage.normalize(value);
      if (code != SubtitleLanguage.unknown) return code;
    }
    return null;
  }

  /// The row's title, such as `Japanese`, `English Commentary` or
  /// `DTS · 5.1`.
  static String title(
    VideoAudioTrack track,
    int index, [
    Map<String, MpvAudioTrackInfo> info = const {},
  ]) {
    final label = _label(track, info[track.id]);
    final code = language(track);
    if (label != null && (code == null || _namesLanguage(label, code))) {
      // A bare code ("eng") reads better as its name; a longer title that
      // names the language ("English Commentary") is kept as it is.
      return _isBareLanguage(label, code)
          ? SubtitleLanguage.name(code!)
          : label;
    }
    if (code != null) return SubtitleLanguage.name(code);
    final technical = _technical(track, info[track.id]);
    if (technical.isNotEmpty) return technical;
    return 'Audio track ${index + 1}';
  }

  /// What sets [tracks]`[index]` apart: the stream's title when the row is
  /// named after the language, the track's role (audio description,
  /// forced), then channels and codec. Rows that would still read the same
  /// get their position, so no two look identical.
  static String detail(
    List<VideoAudioTrack> tracks,
    int index, [
    Map<String, MpvAudioTrackInfo> info = const {},
  ]) {
    // "Default" says something only when the file marks some tracks and
    // not others (HLS and DASH mark every track default).
    final defaults = tracks.where((t) => info[t.id]?.isDefault == true).length;
    final showDefault = defaults > 0 && defaults < tracks.length;
    String plain(int i) => _detail(tracks[i], i, info, showDefault);
    final own = plain(index);
    final ownTitle = title(tracks[index], index, info);
    final duplicate = [
      for (var i = 0; i < tracks.length; i++)
        if (i != index &&
            title(tracks[i], i, info) == ownTitle &&
            plain(i) == own)
          i,
    ].isNotEmpty;
    return [
      if (own.isNotEmpty) own,
      if (duplicate) 'Track ${index + 1}',
    ].join(' · ');
  }

  /// The tracks worth offering: [tracks] without the copies of the playing
  /// audio that an HLS stream carries in each of its other variants.
  ///
  /// FFmpeg's HLS demuxer lists the audio inside every variant (quality) as
  /// its own track. Variants are encodings of the same content, so those
  /// rows say nothing new, and choosing one would make libmpv download a
  /// second variant. A row is hidden only when libmpv places it in another
  /// variant (`program-id`, with an `hls-bitrate`) and a row that reads the
  /// same exists in the playing track's variant. Separate renditions, files
  /// without variants and engines without this data keep every row.
  static List<VideoAudioTrack> choices(
    List<VideoAudioTrack> tracks,
    Map<String, MpvAudioTrackInfo> info,
  ) {
    final playing = tracks.where((track) => track.isSelected).firstOrNull;
    final program = playing == null ? null : info[playing.id]?.programId;
    if (program == null) return tracks;
    String sameness(VideoAudioTrack track) => [
      track.label ?? '',
      language(track) ?? '',
      track.codec ?? '',
      _channels(track, info[track.id]) ?? '',
      track.sampleRate ?? '',
      info[track.id]?.visualImpaired,
      info[track.id]?.hearingImpaired,
    ].join('|');
    final inPlayingVariant = {
      for (final track in tracks)
        if (info[track.id]?.programId == program) sameness(track),
    };
    return [
      for (final track in tracks)
        if (!_isVariantCopy(
          track,
          info[track.id],
          program,
          inPlayingVariant,
          sameness,
        ))
          track,
    ];
  }

  static bool _isVariantCopy(
    VideoAudioTrack track,
    MpvAudioTrackInfo? info,
    int program,
    Set<String> inPlayingVariant,
    String Function(VideoAudioTrack) sameness,
  ) =>
      !track.isSelected &&
      info != null &&
      info.hlsBitrate != null &&
      info.programId != null &&
      info.programId != program &&
      inPlayingVariant.contains(sameness(track));

  /// A codec's usual name (`eac3`, `ec-3` → `E-AC-3`; `mp4a.40.2` →
  /// `AAC`). Codecs not in the table keep the engine's name in capitals.
  static String codecName(String codec) {
    final value = codec.trim().toLowerCase();
    if (value.startsWith('pcm_') || value == 'lpcm') return 'PCM';
    if (value.startsWith('mp4a.40.')) return 'AAC';
    return switch (value) {
      'aac' || 'aac_latm' || 'mp4a' => 'AAC',
      'ac3' || 'ac-3' || 'mp4a.a5' => 'AC-3',
      'eac3' || 'ec-3' || 'ec+3' || 'mp4a.a6' => 'E-AC-3',
      'ac4' || 'ac-4' => 'AC-4',
      'dts' || 'dtsc' => 'DTS',
      'dtsh' => 'DTS-HD',
      'dtsl' => 'DTS-HD MA',
      'dtse' => 'DTS Express',
      'dtsx' => 'DTS:X',
      'truehd' => 'TrueHD',
      'mlp' => 'MLP',
      'flac' => 'FLAC',
      'alac' => 'ALAC',
      'opus' => 'Opus',
      'vorbis' => 'Vorbis',
      'mp3' || 'mp4a.6b' || 'mp4a.69' => 'MP3',
      'mp2' => 'MP2',
      'wmav1' || 'wmav2' => 'WMA',
      'wmapro' => 'WMA Pro',
      'mpegh_3d_audio' || 'mhm1' || 'mha1' => 'MPEG-H',
      _ => codec.trim().toUpperCase(),
    };
  }

  /// The channel layout as people say it: libmpv's layout name when it has
  /// one (`5.1(side)` → `5.1`, `quad` → `4.0`), else from the count (6 and
  /// 8 channels are FFmpeg's default 5.1 and 7.1 layouts).
  static String? _channels(VideoAudioTrack track, MpvAudioTrackInfo? info) {
    final layout = info?.channelLayout;
    if (layout != null) {
      final base = layout.replaceFirst(RegExp(r'\(.*\)$'), '').trim();
      return switch (base) {
        'mono' => 'Mono',
        'stereo' => 'Stereo',
        'quad' => '4.0',
        'hexagonal' => '6.0',
        'octagonal' => '8.0',
        '' => null,
        _ when RegExp(r'^\d').hasMatch(base) => base,
        _ => base[0].toUpperCase() + base.substring(1),
      };
    }
    return switch (track.channelCount) {
      null || 0 => null,
      1 => 'Mono',
      2 => 'Stereo',
      6 => '5.1',
      8 => '7.1',
      final count => '$count channels',
    };
  }

  /// Codec and channels, as a name for a track with nothing else.
  static String _technical(VideoAudioTrack track, MpvAudioTrackInfo? info) => [
    if (track.codec?.trim().isNotEmpty == true) codecName(track.codec!),
    ?_channels(track, info),
  ].join(' · ');

  static String _detail(
    VideoAudioTrack track,
    int index,
    Map<String, MpvAudioTrackInfo> all,
    bool showDefault,
  ) {
    final info = all[track.id];
    final label = _label(track, info);
    final code = language(track);
    final labelShownAsTitle =
        label != null && (code == null || _namesLanguage(label, code));
    // A track named by its codec and channels does not repeat them.
    final technicalTitle = label == null && code == null;
    return [
      if (label != null && !labelShownAsTitle) label,
      if (info?.visualImpaired == true) 'Audio description',
      if (info?.hearingImpaired == true) 'Hearing impaired',
      if (info?.isForced == true) 'Forced',
      if (!technicalTitle) ...[
        ?_channels(track, info),
        if (track.codec?.trim().isNotEmpty == true) codecName(track.codec!),
      ],
      if (showDefault && info?.isDefault == true) 'Default',
    ].join(' · ');
  }

  /// The stream's own title. libmpv titles a flagged track it found
  /// untitled ("visual impaired"); that is the flag, shown as such.
  static String? _label(VideoAudioTrack track, MpvAudioTrackInfo? info) {
    final label = track.label?.trim();
    if (label == null || label.isEmpty) return null;
    if (info != null &&
        ((info.visualImpaired && label == 'visual impaired') ||
            (info.hearingImpaired && label == 'hearing impaired'))) {
      return null;
    }
    return label;
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
