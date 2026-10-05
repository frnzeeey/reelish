/// One episode of a series, as shown in the player.
class EpisodeRef {
  const EpisodeRef({
    required this.season,
    required this.episode,
    this.title = '',
    this.overview = '',
    this.still = '',
    this.runtimeMinutes,
  });

  final int season;
  final int episode;
  final String title;

  /// What happens in this episode, from TMDB; empty when not provided.
  final String overview;

  /// Full-size still image URL for this episode; empty when TMDB has none.
  final String still;

  /// Listed runtime; null when TMDB does not know it.
  final int? runtimeMinutes;

  String get code => 'S$season · E$episode';

  /// `S2 · E3 · The Path`, or just the code when TMDB has no title.
  String get label => title.isEmpty ? code : '$code · $title';
}

/// The playing episode and the next one that can actually be watched.
class EpisodeContext {
  const EpisodeContext({required this.current, this.next});

  final EpisodeRef current;

  /// Null at the series finale, or when the next episode has not aired yet.
  final EpisodeRef? next;

  /// Builds the context from TMDB season episode lists (as returned by
  /// `TmdbService.allEpisodes`). Returns null if the current episode is not
  /// listed. Episodes with an air date after [today] are not offered as next:
  /// providers cannot have streams for them yet.
  static EpisodeContext? fromTmdb(
    List<Map<String, dynamic>> episodes, {
    required int season,
    required int episode,
    DateTime? today,
  }) {
    final now = today ?? DateTime.now();
    final refs =
        [
          for (final entry in episodes)
            if ((entry['season_number'] as num?)?.toInt() case final s?)
              if ((entry['episode_number'] as num?)?.toInt() case final e?)
                (
                  ref: EpisodeRef(
                    season: s,
                    episode: e,
                    title: '${entry['name'] ?? ''}'.trim(),
                    overview: '${entry['overview'] ?? ''}'.trim(),
                    still: switch ('${entry['still_path'] ?? ''}') {
                      '' => '',
                      final path => 'https://image.tmdb.org/t/p/original$path',
                    },
                    runtimeMinutes: switch (entry['runtime']) {
                      final num minutes when minutes > 0 => minutes.toInt(),
                      _ => null,
                    },
                  ),
                  airDate: DateTime.tryParse('${entry['air_date'] ?? ''}'),
                ),
        ]..sort((a, b) {
          final bySeason = a.ref.season.compareTo(b.ref.season);
          return bySeason != 0
              ? bySeason
              : a.ref.episode.compareTo(b.ref.episode);
        });
    final index = refs.indexWhere(
      (entry) => entry.ref.season == season && entry.ref.episode == episode,
    );
    if (index < 0) return null;
    final following = index + 1 < refs.length ? refs[index + 1] : null;
    final aired =
        following != null &&
        (following.airDate == null || !following.airDate!.isAfter(now));
    return EpisodeContext(
      current: refs[index].ref,
      next: aired ? following.ref : null,
    );
  }
}
