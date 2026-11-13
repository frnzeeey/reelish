/// Where the viewer stopped in one episode.
class EpisodeProgress {
  const EpisodeProgress({
    required this.positionMs,
    required this.durationMs,
    this.at = 0,
  });

  /// When this position was saved, in milliseconds since the epoch on this
  /// device's clock (a position from another device is converted to it).
  /// Zero when unknown: saved before sync existed. Sync keeps the newer of
  /// two positions by it.
  final int at;

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

  /// `[positionMs, durationMs]`, then the save time when known. Versions
  /// before sync read the first two and ignore the rest.
  List<int> toJson() => [positionMs, durationMs, if (at > 0) at];

  static EpisodeProgress? fromJson(Object? json) =>
      json is List &&
          json.length >= 2 &&
          json[0] is int &&
          json[1] is int &&
          (json[0] as int) >= 0
      ? EpisodeProgress(
          positionMs: json[0] as int,
          durationMs: json[1] as int,
          at: json.length >= 3 && json[2] is int ? json[2] as int : 0,
        )
      : null;
}

/// Per-episode progress for one series, plus the episode watched last.
class SeriesProgress {
  const SeriesProgress({this.episodes = const {}, this.last, this.next});

  static const empty = SeriesProgress();

  /// Keyed by [key].
  final Map<String, EpisodeProgress> episodes;

  /// The most recently watched episode, as (season, episode).
  final ({int season, int episode})? last;

  /// The episode after [last], recorded once [last] was watched and the
  /// episode list named an aired one. Null at the finale, before the next
  /// episode airs, and for progress saved before it was recorded.
  final ({int season, int episode})? next;

  static String key(int season, int episode) => '$season:$episode';

  EpisodeProgress? of(int season, int episode) =>
      episodes[key(season, episode)];

  /// The episode Continue watching plays: [last] while unfinished, then
  /// [next]. Null when there is nothing to continue: nothing watched yet,
  /// or the last episode finished with no known next one.
  ({int season, int episode})? get continueAt {
    final last = this.last;
    if (last == null) return null;
    if (of(last.season, last.episode)?.isWatched != true) return last;
    return next;
  }
}
