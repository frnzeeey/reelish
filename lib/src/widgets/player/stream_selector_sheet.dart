import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/stream_source.dart';
import 'player_sheet.dart';

/// Lists playable sources. Quality leads each row; provider and stream name
/// follow quietly. Opening it does not interrupt playback.
///
/// Given [updates], the list keeps growing while providers are still
/// searching: a slower provider's sources are added at the end (so a focused
/// row never moves) instead of being left out because the sheet opened first.
class StreamSelectorSheet extends StatefulWidget {
  const StreamSelectorSheet({
    super.key,
    required this.streams,
    required this.selected,
    this.status,
    this.updates,
    this.finished,
  });

  final List<StreamSource> streams;
  final StreamSource selected;
  final String? status;

  /// Sources found while the sheet is open; repeats of listed ones are
  /// ignored.
  final Stream<StreamSource>? updates;

  /// Completes when no more [updates] will come.
  final Future<void>? finished;

  static Future<StreamSource?> show(
    BuildContext context,
    List<StreamSource> streams,
    StreamSource selected, {
    String? status,
    Stream<StreamSource>? updates,
    Future<void>? finished,
  }) => showModalBottomSheet<StreamSource>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => StreamSelectorSheet(
      streams: streams,
      selected: selected,
      status: status,
      updates: updates,
      finished: finished,
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

  @override
  State<StreamSelectorSheet> createState() => _StreamSelectorSheetState();
}

class _StreamSelectorSheetState extends State<StreamSelectorSheet> {
  late final List<StreamSource> _streams = List.of(widget.streams);
  StreamSubscription<StreamSource>? _updates;
  late bool _searching = widget.updates != null;

  @override
  void initState() {
    super.initState();
    _updates = widget.updates?.listen((source) {
      if (!mounted || _streams.any((s) => _same(s, source))) return;
      setState(() => _streams.add(source));
    });
    widget.finished?.whenComplete(() {
      if (mounted) setState(() => _searching = false);
    });
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    super.dispose();
  }

  static bool _same(StreamSource a, StreamSource b) =>
      identical(a, b) ||
      (a.url == b.url && a.providerId == b.providerId && a.name == b.name);

  bool _isCurrent(StreamSource source) =>
      identical(source, widget.selected) ||
      (source.url == widget.selected.url &&
          source.providerName == widget.selected.providerName);

  String? get _subtitle {
    if (!_searching) return widget.status;
    final searching = 'Still searching providers…';
    return widget.status == null ? searching : '${widget.status} · $searching';
  }

  @override
  Widget build(BuildContext context) => PlayerSheetFrame(
    icon: Symbols.video_library_rounded,
    title: 'Playback source',
    subtitle: _subtitle,
    children: [
      for (final source in _streams)
        PlayerSheetOption(
          title: [
            if (StreamSelectorSheet.qualityOf(source).isNotEmpty)
              StreamSelectorSheet.qualityOf(source),
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
