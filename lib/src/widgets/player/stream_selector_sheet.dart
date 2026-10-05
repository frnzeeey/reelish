import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/stream_source.dart';
import 'player_sheet.dart';

/// Lists playable sources. Quality leads each row; provider and stream name
/// follow quietly. Opening it does not interrupt playback.
class StreamSelectorSheet extends StatelessWidget {
  const StreamSelectorSheet({
    super.key,
    required this.streams,
    required this.selected,
    this.status,
  });

  final List<StreamSource> streams;
  final StreamSource selected;
  final String? status;

  static Future<StreamSource?> show(
    BuildContext context,
    List<StreamSource> streams,
    StreamSource selected, {
    String? status,
  }) => showModalBottomSheet<StreamSource>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => StreamSelectorSheet(
      streams: streams,
      selected: selected,
      status: status,
    ),
  );

  static final _height = RegExp(r'(?<!\d)(2160|1440|1080|720|576|480|360)p?\b');

  /// A short quality label, from the provider's quality field or the name.
  static String qualityOf(StreamSource source) {
    final quality = source.quality.trim();
    if (quality.isNotEmpty) return quality;
    final match = _height.firstMatch('${source.name} ${source.description}');
    if (match != null) return '${match.group(1)}p';
    final upper = '${source.name} ${source.description}'.toUpperCase();
    if (upper.contains('4K') || upper.contains('UHD')) return '4K';
    return '';
  }

  bool _isCurrent(StreamSource source) =>
      identical(source, selected) ||
      (source.url == selected.url &&
          source.providerName == selected.providerName);

  @override
  Widget build(BuildContext context) => PlayerSheetFrame(
    icon: Symbols.video_library_rounded,
    title: 'Playback source',
    subtitle: status,
    children: [
      for (final source in streams)
        PlayerSheetOption(
          title: [
            if (qualityOf(source).isNotEmpty) qualityOf(source),
            if (source.isTorrent) 'Torrent',
          ].join(' · ').ifEmpty(source.name),
          detail: {
            if (source.providerName.isNotEmpty) source.providerName,
            if (source.name.isNotEmpty) source.name,
          }.join(' · '),
          selected: _isCurrent(source),
          trailing: 'Playing',
          onTap: () => Navigator.pop(context, source),
        ),
    ],
  );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
