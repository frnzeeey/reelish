// Universal Search's filters for movies and series: genres, release years
// and a minimum TMDB user rating. Each is a chip showing its value, with
// its own clear, and Clear all. The pickers are dialogs, so a remote, a
// mouse and a finger all work them.

import 'package:flutter/material.dart';

import '../../discovery/tmdb_genres.dart';
import '../../search/search_models.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';

class SearchFilterBar extends StatelessWidget {
  const SearchFilterBar({
    super.key,
    required this.filters,
    required this.genres,
    required this.onChanged,
  });

  final SearchFilters filters;
  final GenreCatalog genres;
  final ValueChanged<SearchFilters> onChanged;

  String get _genreLabel {
    if (filters.genres.isEmpty) return 'Genre';
    final names = [for (final id in filters.genres) genres.nameOf(id) ?? '?'];
    return names.length == 1
        ? names.single
        : '${names.first} +${names.length - 1}';
  }

  String get _yearLabel {
    final from = filters.yearFrom;
    final to = filters.yearTo;
    if (from == null && to == null) return 'Year';
    if (from != null && from == to) return '$from';
    if (from == null) return 'Before ${to! + 1}';
    if (to == null) return '$from and later';
    return '$from–$to';
  }

  String get _ratingLabel => filters.minRating == null
      ? 'Rating'
      : 'TMDB ${filters.minRating!.toStringAsFixed(0)}+';

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        Icon(ReelishIcons.filter, size: 18, color: GlassTheme.muted),
        const SizedBox(width: AppSpace.xs),
        _chip(
          label: _genreLabel,
          active: filters.genres.isNotEmpty,
          onPressed: () async {
            final picked = await _pickGenres(context);
            if (picked != null) onChanged(filters.copyWith(genres: picked));
          },
          onClear: () => onChanged(filters.copyWith(genres: const {})),
          what: 'genre',
        ),
        _chip(
          label: _yearLabel,
          active: filters.hasYear,
          onPressed: () async {
            final picked = await _pickYears(context);
            if (picked != null) onChanged(filters.copyWith(years: picked));
          },
          onClear: () => onChanged(filters.copyWith(years: (null, null))),
          what: 'year',
        ),
        _chip(
          label: _ratingLabel,
          active: filters.minRating != null,
          onPressed: () async {
            final picked = await _pickRating(context);
            if (picked != null) {
              onChanged(
                filters.copyWith(minRating: () => picked < 0 ? null : picked),
              );
            }
          },
          onClear: () => onChanged(filters.copyWith(minRating: () => null)),
          what: 'rating',
        ),
        if (!filters.isEmpty)
          TextButton(
            onPressed: () => onChanged(const SearchFilters()),
            child: const Text('Clear all'),
          ),
      ],
    ),
  );

  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onPressed,
    required VoidCallback onClear,
    required String what,
  }) => Padding(
    padding: const EdgeInsets.only(right: AppSpace.xs),
    child: InputChip(
      label: Text(label),
      selected: active,
      showCheckmark: false,
      onPressed: onPressed,
      onDeleted: active ? onClear : null,
      deleteButtonTooltipMessage: 'Clear $what filter',
      avatar: active ? null : const Icon(ReelishIcons.chevronDown, size: 16),
    ),
  );

  Future<Set<int>?> _pickGenres(BuildContext context) => showDialog<Set<int>>(
    context: context,
    builder: (context) {
      var picked = {...filters.genres};
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Genres'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Titles with any of these. Series use TMDB’s combined '
                  'genres (Science fiction finds Sci-Fi & Fantasy).',
                  style: TextStyle(
                    color: GlassTheme.muted,
                    fontSize: AppTextSize.label,
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.xs,
                  runSpacing: AppSpace.xs,
                  children: [
                    for (final id in genres.pickable)
                      FilterChip(
                        label: Text(genres.nameOf(id) ?? '$id'),
                        selected: picked.contains(id),
                        onSelected: (on) => setState(() {
                          picked = {...picked};
                          on ? picked.add(id) : picked.remove(id);
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, <int>{}),
              child: const Text('Any genre'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, picked),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    },
  );

  Future<(int?, int?)?> _pickYears(BuildContext context) {
    final now = DateTime.now().year;
    final decade = now - now % 10;
    final options = <(String, int?, int?)>[
      ('Any year', null, null),
      ('This year', now, now),
      ('Last year', now - 1, now - 1),
      ('${decade}s', decade, decade + 9),
      for (var d = decade - 10; d >= 1980; d -= 10) ('${d}s', d, d + 9),
      ('Before 1980', null, 1979),
      for (var y = now - 2; y >= now - 10; y--) ('$y', y, y),
    ];
    return showDialog<(int?, int?)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Release year'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'First air year for series. Titles without a date are left '
              'out while a year is set.',
              style: TextStyle(
                color: GlassTheme.muted,
                fontSize: AppTextSize.label,
              ),
            ),
          ),
          for (final (label, from, to) in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, (from, to)),
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: from == filters.yearFrom && to == filters.yearTo
                      ? FontWeight.w800
                      : FontWeight.w400,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The chosen minimum, or -1 for any.
  Future<double?> _pickRating(BuildContext context) => showDialog<double>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('TMDB rating'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'TMDB’s user score out of 10, counted only for titles with '
            'at least ${SearchFilters.minVotesForRating} votes.',
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: AppTextSize.label,
            ),
          ),
        ),
        for (final (label, value) in const [
          ('Any rating', -1.0),
          ('5 and up', 5.0),
          ('6 and up', 6.0),
          ('7 and up', 7.0),
          ('8 and up', 8.0),
        ])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, value),
            child: Text(label),
          ),
      ],
    ),
  );
}
