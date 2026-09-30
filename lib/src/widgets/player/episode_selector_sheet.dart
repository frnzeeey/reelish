import 'package:flutter/material.dart';
import '../../theme/glass_theme.dart';
import '../glass_box.dart';

class EpisodeSelectorSheet extends StatefulWidget {
  const EpisodeSelectorSheet({
    super.key,
    required this.episodes,
    required this.title,
  });
  final List<Map<String, dynamic>> episodes;
  final String title;
  static Future<({int season, int episode})?> show(
    BuildContext context,
    String title,
    List<Map<String, dynamic>> episodes,
  ) => showModalBottomSheet<({int season, int episode})>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => EpisodeSelectorSheet(episodes: episodes, title: title),
  );
  @override
  State<EpisodeSelectorSheet> createState() => _EpisodeSelectorSheetState();
}

class _EpisodeSelectorSheetState extends State<EpisodeSelectorSheet> {
  int? _season;
  @override
  Widget build(BuildContext context) {
    final seasons =
        widget.episodes
            .map((e) => (e['season_number'] as num).toInt())
            .toSet()
            .toList()
          ..sort();
    _season ??= seasons.isEmpty ? null : seasons.first;
    final episodes =
        widget.episodes
            .where((e) => (e['season_number'] as num).toInt() == _season)
            .toList()
          ..sort(
            (a, b) => (a['episode_number'] as num).compareTo(
              b['episode_number'] as num,
            ),
          );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: GlassBox(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Choose an episode',
                style: TextStyle(color: GlassTheme.muted),
              ),
              if (seasons.isNotEmpty)
                DropdownButton<int>(
                  value: _season,
                  items: [
                    for (final s in seasons)
                      DropdownMenuItem(value: s, child: Text('Season $s')),
                  ],
                  onChanged: (s) => setState(() => _season = s),
                ),
              Flexible(
                child: episodes.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                          'No episode list is available for this title.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: episodes.length,
                        itemBuilder: (context, index) {
                          final episode = episodes[index];
                          return ListTile(
                            leading: const Icon(
                              Icons.play_circle_outline,
                              color: GlassTheme.primary,
                            ),
                            title: Text(
                              'E${(episode['episode_number'] as num).toInt().toString().padLeft(2, '0')}  ${episode['name']}',
                            ),
                            subtitle: Text('Season $_season'),
                            onTap: () => Navigator.pop(context, (
                              season: _season!,
                              episode: (episode['episode_number'] as num)
                                  .toInt(),
                            )),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
