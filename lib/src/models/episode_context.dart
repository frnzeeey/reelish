/// One episode of a series, as shown in the player and the episode panel.
class EpisodeRef {
  const EpisodeRef({
    required this.season,
    required this.episode,
    this.title = '',
    this.overview = '',
    this.stillPath = '',
    this.runtimeMinutes,
    this.airDate,
  });

  final int season;
  final int episode;
  final String title;

  /// What happens in this episode, from TMDB; empty when not provided.
  final String overview;

  /// TMDB still image path (`/abc.jpg`); empty when TMDB has none.
  final String stillPath;

  /// Listed runtime; null when TMDB does not know it.
  final int? runtimeMinutes;

  /// First air date; null when TMDB does not list one.
  final DateTime? airDate;

  /// Large still for the pause screen: 1280 px wide like the backdrops it
  /// stands in for, about a third smaller to download than the original.
  String get still =>
      stillPath.isEmpty ? '' : 'https://image.tmdb.org/t/p/w1280$stillPath';

  /// Small still (300 px wide), for episode lists.
  String get thumbnail =>
      stillPath.isEmpty ? '' : 'https://image.tmdb.org/t/p/w300$stillPath';

  String get code => 'S$season · E$episode';

  /// `S2 · E3 · The Path`, or just the code when TMDB has no title.
  String get label => title.isEmpty ? code : '$code · $title';

  /// Whether providers can have streams for it yet. An episode without an
  /// air date is assumed to have aired.
  bool airedBy(DateTime now) => airDate == null || !airDate!.isAfter(now);

  bool isSameEpisode(EpisodeRef other) =>
      season == other.season && episode == other.episode;

  /// Parses TMDB season episode lists (as returned by
  /// `TmdbService.allEpisodes`) into episodes ordered by season, then number.
  static List<EpisodeRef> listFromTmdb(List<Map<String, dynamic>> episodes) =>
      [
        for (final entry in episodes)
          if ((entry['season_number'] as num?)?.toInt() case final s?)
            if ((entry['episode_number'] as num?)?.toInt() case final e?)
              EpisodeRef(
                season: s,
                episode: e,
                title: '${entry['name'] ?? ''}'.trim(),
                overview: '${entry['overview'] ?? ''}'.trim(),
                stillPath: '${entry['still_path'] ?? ''}',
                runtimeMinutes: switch (entry['runtime']) {
                  final num minutes when minutes > 0 => minutes.toInt(),
                  _ => null,
                },
                airDate: DateTime.tryParse('${entry['air_date'] ?? ''}'),
              ),
      ]..sort((a, b) {
        final bySeason = a.season.compareTo(b.season);
        return bySeason != 0 ? bySeason : a.episode.compareTo(b.episode);
      });
}

/// The playing episode within its series: the single source of truth for
/// episode navigation (the episode panel, Previous/Next, and auto-play).
class EpisodeContext {
  const EpisodeContext({
    required this.current,
    this.next,
    this.previous,
    this.episodes = const [],
  });

  final EpisodeRef current;

  /// The following listed episode once it has aired. Null at the series
  /// finale, or when the next episode has not aired yet: providers cannot
  /// have streams for it.
  final EpisodeRef? next;

  /// The preceding listed episode; null for the first episode.
  final EpisodeRef? previous;

  /// Every listed episode, ordered by season, then number.
  final List<EpisodeRef> episodes;

  /// Season numbers in order.
  List<int> get seasons => [
    for (final (index, ref) in episodes.indexed)
      if (index == 0 || episodes[index - 1].season != ref.season) ref.season,
  ];

  List<EpisodeRef> episodesIn(int season) =>
      episodes.where((ref) => ref.season == season).toList();

  /// Builds the context from TMDB season episode lists. Returns null if the
  /// current episode is not listed. Next and previous cross season
  /// boundaries (S1 E10 → S2 E1).
  static EpisodeContext? fromTmdb(
    List<Map<String, dynamic>> episodes, {
    required int season,
    required int episode,
    DateTime? today,
  }) => fromEpisodes(
    EpisodeRef.listFromTmdb(episodes),
    season: season,
    episode: episode,
    today: today,
  );

  /// As [fromTmdb], for an already ordered list.
  static EpisodeContext? fromEpisodes(
    List<EpisodeRef> episodes, {
    required int season,
    required int episode,
    DateTime? today,
  }) {
    final index = episodes.indexWhere(
      (ref) => ref.season == season && ref.episode == episode,
    );
    if (index < 0) return null;
    final following = index + 1 < episodes.length ? episodes[index + 1] : null;
    return EpisodeContext(
      current: episodes[index],
      next: following != null && following.airedBy(today ?? DateTime.now())
          ? following
          : null,
      previous: index > 0 ? episodes[index - 1] : null,
      episodes: List.unmodifiable(episodes),
    );
  }
}
