import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/stream_source.dart';
import '../../models/subtitle_language.dart';
import '../../theme/glass_theme.dart';
import 'player_sheet.dart';

enum ExternalSubtitleStatus { idle, loading, ready, failed }

/// Everything the subtitle menu shows. The player publishes a new value as
/// embedded tracks appear or OpenSubtitles results arrive, and an open menu
/// updates in place; playback never waits for it.
@immutable
class SubtitleMenu {
  const SubtitleMenu({
    this.embedded = const [],
    this.provider = const [],
    this.addonSubtitles = const [],
    this.status = ExternalSubtitleStatus.idle,
    this.message,
    this.selectedKey,
    this.preferredLanguages = const [],
  });

  final List<SubtitleTrack> embedded;
  final List<SubtitleTrack> provider;
  final List<SubtitleTrack> addonSubtitles;
  final ExternalSubtitleStatus status;

  /// Short failure text for the OpenSubtitles section.
  final String? message;

  /// [SubtitleTrack.key] of the active subtitle; null when off.
  final String? selectedKey;

  /// Preferred languages, in order, for sorting.
  final List<String> preferredLanguages;

  SubtitleMenu copyWith({
    List<SubtitleTrack>? embedded,
    List<SubtitleTrack>? provider,
    List<SubtitleTrack>? addonSubtitles,
    ExternalSubtitleStatus? status,
    String? message,
    bool clearMessage = false,
    String? selectedKey,
    bool clearSelection = false,
    List<String>? preferredLanguages,
  }) => SubtitleMenu(
    embedded: embedded ?? this.embedded,
    provider: provider ?? this.provider,
    addonSubtitles: addonSubtitles ?? this.addonSubtitles,
    status: status ?? this.status,
    message: clearMessage ? null : (message ?? this.message),
    selectedKey: clearSelection ? null : (selectedKey ?? this.selectedKey),
    preferredLanguages: preferredLanguages ?? this.preferredLanguages,
  );

  /// Language order: preferred languages first (in preference
  /// order), then by language name, unknown last. Tracks of one language
  /// keep their source order.
  static List<SubtitleTrack> ordered(
    List<SubtitleTrack> tracks,
    List<String> preferredLanguages,
  ) {
    int preference(SubtitleTrack track) {
      for (final (index, language) in preferredLanguages.indexed) {
        if (language.isNotEmpty &&
            SubtitleLanguage.matches(track.lang, language)) {
          return index;
        }
      }
      return preferredLanguages.length;
    }

    final indexed =
        [
          for (final (index, track) in tracks.indexed)
            (
              track: track,
              index: index,
              preference: preference(track),
              code: SubtitleLanguage.normalize(track.lang),
            ),
        ]..sort((a, b) {
          final byPreference = a.preference.compareTo(b.preference);
          if (byPreference != 0) return byPreference;
          final aUnknown = a.code == SubtitleLanguage.unknown;
          final bUnknown = b.code == SubtitleLanguage.unknown;
          if (aUnknown != bUnknown) return aUnknown ? 1 : -1;
          final byName = SubtitleLanguage.name(
            a.code,
          ).compareTo(SubtitleLanguage.name(b.code));
          return byName != 0 ? byName : a.index.compareTo(b.index);
        });
    return [for (final entry in indexed) entry.track];
  }

  /// `English`, `English (SDH)`.
  static String titleOf(SubtitleTrack track) {
    final name = SubtitleLanguage.name(SubtitleLanguage.normalize(track.lang));
    final display = name == 'Unknown' && track.lang.trim().isNotEmpty
        ? track.lang.trim()
        : name;
    return track.hearingImpaired ? '$display (SDH)' : display;
  }
}

/// The subtitle menu: Off, then subtitles in the video, from the provider,
/// and from OpenSubtitles. Pops the chosen track, or a track with an empty
/// URL and no id for Off.
class SubtitlePickerSheet extends StatelessWidget {
  const SubtitlePickerSheet({
    super.key,
    required this.menu,
    required this.onRetry,
  });

  final ValueListenable<SubtitleMenu> menu;
  final VoidCallback onRetry;

  static const off = SubtitleTrack(url: '', lang: 'Off');

  static Future<SubtitleTrack?> show(
    BuildContext context, {
    required ValueListenable<SubtitleMenu> menu,
    required VoidCallback onRetry,
  }) => showModalBottomSheet<SubtitleTrack>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => SubtitlePickerSheet(menu: menu, onRetry: onRetry),
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SubtitleMenu>(
    valueListenable: menu,
    builder: (context, value, _) {
      List<Widget> section(String title, List<SubtitleTrack> tracks) => [
        if (tracks.isNotEmpty) ...[
          _SectionLabel(title),
          for (final track in SubtitleMenu.ordered(
            tracks,
            value.preferredLanguages,
          ))
            PlayerSheetOption(
              title: SubtitleMenu.titleOf(track),
              detail: track.detail,
              selected: value.selectedKey == track.key,
              trailing: 'On',
              onTap: () => Navigator.pop(context, track),
            ),
        ],
      ];
      return PlayerSheetFrame(
        icon: Symbols.closed_caption_rounded,
        title: 'Subtitles',
        children: [
          PlayerSheetOption(
            title: 'Off',
            selected: value.selectedKey == null,
            onTap: () => Navigator.pop(context, off),
          ),
          ...section('IN VIDEO', value.embedded),
          ...section('FROM PROVIDER', value.provider),
          // One section per addon, in the order addons answered.
          for (final addon in {
            for (final track in value.addonSubtitles) track.addonName,
          })
            ...section(
              addon.isEmpty ? 'SUBTITLE ADDONS' : addon.toUpperCase(),
              [
                for (final track in value.addonSubtitles)
                  if (track.addonName == addon) track,
              ],
            ),
          if (value.addonSubtitles.isEmpty) ...[
            const _SectionLabel('SUBTITLE ADDONS'),
            _AddonSearchStatus(value: value, onRetry: onRetry),
          ] else if (value.status == ExternalSubtitleStatus.loading)
            _AddonSearchStatus(value: value, onRetry: onRetry),
        ],
      );
    },
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
    child: Text(
      text,
      style: const TextStyle(
        color: GlassTheme.muted,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: .8,
      ),
    ),
  );
}

class _AddonSearchStatus extends StatelessWidget {
  const _AddonSearchStatus({required this.value, required this.onRetry});

  final SubtitleMenu value;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (text, retry) = switch (value.status) {
      ExternalSubtitleStatus.loading => ('Searching subtitle addons…', false),
      ExternalSubtitleStatus.failed => (
        value.message ?? 'Unable to load subtitles.',
        true,
      ),
      ExternalSubtitleStatus.ready => ('No external subtitles found', false),
      ExternalSubtitleStatus.idle => (
        value.message ?? 'Not available for this title',
        false,
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: [
          if (value.status == ExternalSubtitleStatus.loading) ...[
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: GlassTheme.primary,
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: GlassTheme.muted, fontSize: 13),
            ),
          ),
          if (retry)
            TextButton(
              onPressed: onRetry,
              child: Text(
                'Retry',
                style: TextStyle(
                  color: GlassTheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
