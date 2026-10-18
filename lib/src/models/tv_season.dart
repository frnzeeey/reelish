/// A season of a series, as TMDB lists it on the series' details.
class TvSeason {
  const TvSeason({required this.number, this.name});

  /// Read from TMDB's `seasons` entry. Throws when `season_number` is
  /// missing, as the screens did before these models existed, so a broken
  /// response is still reported as a failed load.
  factory TvSeason.fromJson(Map<String, dynamic> json) => TvSeason(
    number: (json['season_number'] as num).toInt(),
    name: json['name']?.toString(),
  );

  final int number;

  /// TMDB's name for the season ("Specials", "Season 1"), when it has one.
  final String? name;
}

/// An episode of a season, as TMDB's season details list it.
class TvEpisode {
  const TvEpisode({
    this.number,
    this.name,
    this.overview = '',
    this.rating = 0,
    this.stillPath = '',
    this.runtime,
    this.airDate = '',
  });

  factory TvEpisode.fromJson(Map<String, dynamic> json) => TvEpisode(
    number: (json['episode_number'] as num?)?.toInt(),
    name: json['name']?.toString(),
    overview: json['overview']?.toString() ?? '',
    rating: (json['vote_average'] as num?) ?? 0,
    stillPath: json['still_path']?.toString() ?? '',
    runtime: (json['runtime'] as num?)?.toInt(),
    airDate: json['air_date']?.toString() ?? '',
  );

  /// Null when TMDB gives none; each screen picks its own fallback.
  final int? number;
  final String? name;
  final String overview;

  /// `vote_average`, 0 when missing.
  final num rating;

  /// TMDB image path of the episode still, empty when it has none.
  final String stillPath;

  /// Minutes, when known.
  final int? runtime;

  /// `YYYY-MM-DD`, empty when unknown.
  final String airDate;

  /// Whether it has been broadcast by [now]. An unknown date counts as aired,
  /// so a series with incomplete data stays playable.
  bool airedBy(DateTime now) {
    final date = DateTime.tryParse(airDate);
    return date == null || !date.isAfter(now);
  }

  /// Episodes in broadcast order; an episode without a number sorts first.
  static int byNumber(TvEpisode a, TvEpisode b) =>
      (a.number ?? 0).compareTo(b.number ?? 0);
}
