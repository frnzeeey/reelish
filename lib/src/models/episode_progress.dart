/// Where the viewer stopped in one episode.
class EpisodeProgress {
  const EpisodeProgress({required this.positionMs, required this.durationMs});

  /// From this share of the runtime on, an episode counts as watched (the
  /// end credits are often all that is left).
  static const watchedFraction = .9;

  final int positionMs;

  /// Zero when the length is unknown (a live stream, or not yet loaded).
  final int durationMs;

  /// Watched share, 0–1; zero when the length is unknown.
  double get fraction =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  /// Below this an episode is shown as not started: a few seconds of
  /// playback are not worth a progress bar or "58 min left".
  static const shownAfter = Duration(minutes: 1);

  bool get isWatched => fraction >= watchedFraction;

  /// Started (for at least [shownAfter]) but not finished.
  bool get isInProgress =>
      positionMs >= shownAfter.inMilliseconds && !isWatched;

  /// Where playback should start: its own position, or the beginning once
  /// watched (a rewatch, not the credits).
  int get resumeMs => isWatched ? 0 : positionMs;

  /// `27 min left` or `1h 12m left`; empty when the length is unknown.
  String get timeLeft {
    if (durationMs <= 0) return '';
    final minutes = ((durationMs - positionMs) / 60000).ceil().clamp(1, 99999);
    if (minutes < 60) return '$minutes min left';
    final hours = minutes ~/ 60, rest = minutes % 60;
    return rest == 0 ? '${hours}h left' : '${hours}h ${rest}m left';
  }

  List<int> toJson() => [positionMs, durationMs];

  static EpisodeProgress? fromJson(Object? json) =>
      json is List &&
          json.length >= 2 &&
          json[0] is int &&
          json[1] is int &&
          (json[0] as int) >= 0
      ? EpisodeProgress(positionMs: json[0] as int, durationMs: json[1] as int)
      : null;
}

/// Per-episode progress for one series, plus the episode watched last.
class SeriesProgress {
  const SeriesProgress({this.episodes = const {}, this.last});

  static const empty = SeriesProgress();

  /// Keyed by [key].
  final Map<String, EpisodeProgress> episodes;

  /// The most recently watched episode, as (season, episode).
  final ({int season, int episode})? last;

  static String key(int season, int episode) => '$season:$episode';

  EpisodeProgress? of(int season, int episode) =>
      episodes[key(season, episode)];
}
