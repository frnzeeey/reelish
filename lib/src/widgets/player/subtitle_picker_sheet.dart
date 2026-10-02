import 'package:flutter/material.dart';

import '../../models/stream_source.dart';
import '../../theme/glass_theme.dart';
import '../glass_box.dart';

class SubtitlePickerSheet extends StatelessWidget {
  const SubtitlePickerSheet({
    super.key,
    required this.tracks,
    required this.selected,
    this.onOpenSubtitles = false,
  });

  final List<SubtitleTrack> tracks;
  final SubtitleTrack? selected;
  final bool onOpenSubtitles;

  static Future<SubtitleTrack?> show(
    BuildContext context,
    List<SubtitleTrack> tracks,
    SubtitleTrack? selected, {
    bool onOpenSubtitles = false,
  }) => showModalBottomSheet<SubtitleTrack>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SubtitlePickerSheet(
      tracks: tracks,
      selected: selected,
      onOpenSubtitles: onOpenSubtitles,
    ),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: GlassBox(
      radius: 28,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white38,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Icon(Icons.closed_caption_rounded, color: GlassTheme.primary),
              SizedBox(width: 10),
              Text(
                'Subtitles',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _SubtitleTile(
                  label: 'Off',
                  icon: Icons.subtitles_off_rounded,
                  selected: selected == null,
                  onTap: () => Navigator.pop(
                    context,
                    const SubtitleTrack(url: '', lang: 'Off'),
                  ),
                ),
                if (onOpenSubtitles)
                  _SubtitleTile(
                    label: 'Search OpenSubtitles v3',
                    detail: 'Find and load an online subtitle',
                    icon: Icons.search_rounded,
                    selected: false,
                    onTap: () => Navigator.pop(
                      context,
                      const SubtitleTrack(url: 'opensubtitles://search'),
                    ),
                  ),
                for (final track in tracks)
                  _SubtitleTile(
                    label: track.lang,
                    detail: track.format.isNotEmpty
                        ? track.format
                        : Uri.tryParse(track.url)?.pathSegments.lastOrNull ??
                              'Subtitle track',
                    icon: Icons.subtitles_rounded,
                    selected: selected?.url == track.url,
                    onTap: () => Navigator.pop(context, track),
                  ),
                if (tracks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: Text(
                      'No subtitle tracks were provided. Search OpenSubtitles v3 to find one.',
                      style: TextStyle(color: GlassTheme.muted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SubtitleTile extends StatelessWidget {
  const _SubtitleTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: selected
          ? GlassTheme.primary.withValues(alpha: .11)
          : Colors.white.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Icon(
          icon,
          color: selected ? GlassTheme.primary : Colors.white70,
        ),
        title: Text(label),
        subtitle: detail == null
            ? null
            : Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: GlassTheme.muted, fontSize: 12),
              ),
        trailing: selected
            ? Icon(Icons.check_circle_rounded, color: GlassTheme.primary)
            : null,
        onTap: onTap,
      ),
    ),
  );
}
