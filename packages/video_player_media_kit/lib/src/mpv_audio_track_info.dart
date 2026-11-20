import 'dart:convert';

/// What libmpv says about one audio track beyond package:video_player's
/// `VideoAudioTrack`: the flags and the channel layout from libmpv's
/// `track-list`, which media_kit's own track model leaves out.
///
/// Every field comes from libmpv as it is; a field libmpv does not report
/// is null or false, never guessed.
class MpvAudioTrackInfo {
  const MpvAudioTrackInfo({
    required this.id,
    this.channelLayout,
    this.isDefault = false,
    this.isForced = false,
    this.visualImpaired = false,
    this.hearingImpaired = false,
    this.programId,
    this.hlsBitrate,
  });

  /// libmpv's track id (`aid`), the same id as the `VideoAudioTrack`.
  final String id;

  /// libmpv's channel layout name (`demux-channels`), such as `5.1(side)`
  /// or `stereo`; null when libmpv knows only the count (`unknown6`).
  final String? channelLayout;

  /// The file marks the track as default.
  final bool isDefault;

  /// The file marks the track as forced.
  final bool isForced;

  /// Audio description for blind and partially sighted viewers (Matroska's
  /// flag, HLS `public.accessibility.describes-video`).
  final bool visualImpaired;

  /// Audio for deaf and hard-of-hearing viewers.
  final bool hearingImpaired;

  /// The HLS variant (FFmpeg program) the track belongs to, when the
  /// stream has programs.
  final int? programId;

  /// The bandwidth of the HLS variant the track comes from; set only for
  /// tracks FFmpeg's HLS demuxer took from a variant.
  final int? hlsBitrate;

  /// The audio tracks in libmpv's `track-list` value, as JSON text (libmpv
  /// formats node properties as JSON when they are observed as strings).
  /// Empty for anything that is not a list of tracks.
  static Map<String, MpvAudioTrackInfo> parseTrackList(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const {};
    }
    if (decoded is! List) return const {};
    return {
      for (final entry in decoded)
        if (entry is Map && entry['type'] == 'audio' && entry['id'] is int)
          '${entry['id']}': MpvAudioTrackInfo(
            id: '${entry['id']}',
            channelLayout: _layout(entry['demux-channels']),
            isDefault: entry['default'] == true,
            isForced: entry['forced'] == true,
            visualImpaired: entry['visual-impaired'] == true,
            hearingImpaired: entry['hearing-impaired'] == true,
            programId:
                entry['program-id'] is int ? entry['program-id'] as int : null,
            hlsBitrate: entry['hls-bitrate'] is int
                ? entry['hls-bitrate'] as int
                : null,
          ),
    };
  }

  /// libmpv writes `unknownN` when the container gives only a count.
  static String? _layout(Object? value) {
    if (value is! String) return null;
    final layout = value.trim();
    if (layout.isEmpty || layout.startsWith('unknown')) return null;
    return layout;
  }
}
