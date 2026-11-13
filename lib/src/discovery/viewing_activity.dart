// What the viewer did with each title, for personalised discovery: how far
// they got, how often they finished it, and when. Built from the watch
// positions the player already saves; pure rules, no storage or network.

import 'dart:math' as math;

import '../models/media_item.dart';

/// How a title's viewing stands, as the recommendation weights see it.
enum ViewingStatus {
  /// Started but not far enough to say more, and watched recently.
  inProgress,

  /// Most of a movie watched ([ViewingRules.mostlyWatchedShare]), or a
  /// series with episodes started but none finished yet.
  mostlyWatched,

  /// A movie finished once, or a series with a finished episode.
  completed,

  /// A movie finished more than once, or a series with several finished
  /// episodes ([ViewingRules.engagedSeriesEpisodes]).
  rewatched,

  /// Left early and not returned to for [ViewingRules.abandonAfter].
  abandoned,
}

/// Thresholds that turn watch positions into a [ViewingStatus]. A failed or
/// sampled playback stays under [minimumPosition] and never counts.
abstract final class ViewingRules {
  /// Less than this watched is a sample or a failed start, not a viewing.
  static const minimumPosition = Duration(seconds: 90);

  /// Share of the runtime that counts as finished: end credits are skipped.
  static const completedShare = 0.9;

  static const mostlyWatchedShare = 0.6;

  /// Below this share a title left alone for [abandonAfter] is abandoned.
  static const abandonedShare = 0.25;
  static const abandonAfter = Duration(days: 10);

  /// A completed title started again from before this share is a rewatch.
  static const restartShare = 0.3;

  /// Finished episodes after which a series counts as strongly watched.
  static const engagedSeriesEpisodes = 3;

  /// Episodes remembered per series.
  static const maxEpisodes = 200;
}

/// One title's viewing history on this account.
class TitleActivity {
  const TitleActivity({
    required this.type,
    required this.id,
    required this.name,
    required this.firstWatched,
    required this.lastWatched,
    this.poster = '',
    this.genreIds = const [],
    this.share = 0,
    this.completions = 0,
    this.episodes = const {},
  });

  final String type, id, name, poster;
  final List<int> genreIds;
  final DateTime firstWatched, lastWatched;

  /// Movies: the furthest point of the current (or last) viewing, 0 to 1.
  /// Series: the furthest point of the episode watched last.
  final double share;

  /// Movies: times watched to the end.
  final int completions;

  /// Series: the furthest share reached in each episode, by `season:episode`.
  final Map<String, double> episodes;

  String get key => '$type:$id';
  bool get isSeries => type == 'series';

  int get completedEpisodes => episodes.values
      .where((share) => share >= ViewingRules.completedShare)
      .length;

  ViewingStatus status({DateTime? now}) {
    final idle = (now ?? DateTime.now()).difference(lastWatched);
    if (isSeries) {
      final finished = completedEpisodes;
      if (finished >= ViewingRules.engagedSeriesEpisodes) {
        return ViewingStatus.rewatched;
      }
      if (finished > 0) return ViewingStatus.completed;
      final furthest = episodes.values.fold(share, math.max);
      if (furthest < ViewingRules.abandonedShare &&
          idle > ViewingRules.abandonAfter) {
        return ViewingStatus.abandoned;
      }
      return episodes.length > 1
          ? ViewingStatus.mostlyWatched
          : ViewingStatus.inProgress;
    }
    if (completions >= 2) return ViewingStatus.rewatched;
    if (completions == 1) return ViewingStatus.completed;
    if (share >= ViewingRules.mostlyWatchedShare) {
      return ViewingStatus.mostlyWatched;
    }
    if (share < ViewingRules.abandonedShare &&
        idle > ViewingRules.abandonAfter) {
      return ViewingStatus.abandoned;
    }
    return ViewingStatus.inProgress;
  }

  /// Whether the viewer has seen this through: a finished movie. Such
  /// titles are not recommended again.
  bool get finished => !isSeries && completions > 0;

  /// This activity after a saved watch position, or null when the position
  /// is too short to count (see [ViewingRules.minimumPosition]). [previous]
  /// is the title's activity so far, if any.
  static TitleActivity? record(
    TitleActivity? previous,
    MediaItem item, {
    required int positionMs,
    required int durationMs,
    ({int season, int episode})? episode,
    required DateTime at,
  }) {
    if (positionMs < ViewingRules.minimumPosition.inMilliseconds) {
      return null;
    }
    // An unknown length cannot say how much was watched: a long viewing
    // counts as started, never as finished.
    final share = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    final base =
        previous ??
        TitleActivity(
          type: item.type,
          id: item.id,
          name: item.name,
          firstWatched: at,
          lastWatched: at,
        );
    // Keep the newest artwork and genres; older history may have none.
    final genres = item.genreIds.isNotEmpty ? item.genreIds : base.genreIds;
    final poster = item.poster.isNotEmpty ? item.poster : base.poster;
    if (item.type == 'series') {
      if (episode == null) return null;
      final episodes = Map<String, double>.of(base.episodes);
      final key = '${episode.season}:${episode.episode}';
      episodes[key] = math.max(episodes.remove(key) ?? 0, share);
      while (episodes.length > ViewingRules.maxEpisodes) {
        episodes.remove(episodes.keys.first);
      }
      return base._copy(
        name: item.name,
        poster: poster,
        genreIds: genres,
        lastWatched: at,
        share: share,
        episodes: episodes,
      );
    }
    var current = base.share, completions = base.completions;
    final viewingFinished = current >= ViewingRules.completedShare;
    if (viewingFinished && share < ViewingRules.restartShare) {
      // Watched to the end before and started again: a new viewing.
      current = share;
    } else {
      current = math.max(current, share);
    }
    if (!viewingFinished && current >= ViewingRules.completedShare) {
      completions++;
    }
    return base._copy(
      name: item.name,
      poster: poster,
      genreIds: genres,
      lastWatched: at,
      share: current,
      completions: completions,
    );
  }

  /// Whether [next] differs from this enough to be worth saving: a new
  /// status, episode, finish or genre list. Position ticks inside the same
  /// band are not saved one by one.
  bool meaningfullyDifferent(TitleActivity next, {DateTime? now}) =>
      next.completions != completions ||
      next.episodes.length != episodes.length ||
      next.completedEpisodes != completedEpisodes ||
      next.status(now: now) != status(now: now) ||
      _band(next.share) != _band(share) ||
      next.genreIds.length != genreIds.length ||
      next.lastWatched.difference(lastWatched) > const Duration(hours: 6);

  static int _band(double share) => (share * 10).floor();

  TitleActivity _copy({
    String? name,
    String? poster,
    List<int>? genreIds,
    DateTime? lastWatched,
    double? share,
    int? completions,
    Map<String, double>? episodes,
  }) => TitleActivity(
    type: type,
    id: id,
    name: name ?? this.name,
    poster: poster ?? this.poster,
    genreIds: genreIds ?? this.genreIds,
    firstWatched: firstWatched,
    lastWatched: lastWatched ?? this.lastWatched,
    share: share ?? this.share,
    completions: completions ?? this.completions,
    episodes: episodes ?? this.episodes,
  );

  Map<String, Object?> toJson() => {
    'type': type,
    'id': id,
    'name': name,
    if (poster.isNotEmpty) 'poster': poster,
    if (genreIds.isNotEmpty) 'genres': genreIds,
    'first': firstWatched.toUtc().toIso8601String(),
    'last': lastWatched.toUtc().toIso8601String(),
    'share': double.parse(share.toStringAsFixed(3)),
    if (completions > 0) 'done': completions,
    if (episodes.isNotEmpty)
      'episodes': {
        for (final MapEntry(:key, :value) in episodes.entries)
          key: double.parse(value.toStringAsFixed(3)),
      },
  };

  /// Null for an unreadable entry, which is skipped rather than failing
  /// the whole store.
  static TitleActivity? fromJson(Object? json) {
    if (json is! Map) return null;
    final type = json['type'], id = json['id'];
    final first = DateTime.tryParse('${json['first'] ?? ''}');
    final last = DateTime.tryParse('${json['last'] ?? ''}');
    if ((type != 'movie' && type != 'series') ||
        id is! String ||
        id.isEmpty ||
        first == null ||
        last == null) {
      return null;
    }
    final genres = json['genres'];
    final episodes = json['episodes'];
    final share = json['share'], done = json['done'];
    return TitleActivity(
      type: type as String,
      id: id,
      name: '${json['name'] ?? ''}',
      poster: '${json['poster'] ?? ''}',
      genreIds: genres is List
          ? List.unmodifiable(genres.whereType<num>().map((g) => g.toInt()))
          : const [],
      firstWatched: first,
      lastWatched: last,
      share: share is num ? share.toDouble().clamp(0.0, 1.0) : 0,
      completions: done is num ? math.max(done.toInt(), 0) : 0,
      episodes: episodes is Map
          ? {
              for (final MapEntry(:key, :value) in episodes.entries)
                if (value is num) '$key': value.toDouble().clamp(0.0, 1.0),
            }
          : const {},
    );
  }
}
