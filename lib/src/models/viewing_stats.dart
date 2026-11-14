// The viewer's own statistics for Profile > Viewing statistics, counted from
// what the app already keeps for the account: the watch history (the last 50
// titles) and per-episode progress (the last 100 series), which sync between
// the account's devices. Nothing new is recorded and nothing is sent. Pure
// rules: the same positions always give the same numbers.
//
// What it can and cannot say:
// - Finished and started use the thresholds discovery uses (ViewingRules):
//   90 seconds to count at all, 90% of a known length to count as finished.
//   An unknown length can be started, never finished.
// - Each movie and each episode is one entry in storage, however many devices
//   played it, so nothing is counted twice. A series' own history entry (its
//   place in Continue watching) only lends its genres: its episodes count.
// - Watch time is an estimate: the furthest point reached in each title,
//   added up. Skipping ahead adds to it; rewatching does not.
// - A finished movie started again counts as in progress until it is
//   finished again, as only the latest position is kept.

import '../discovery/viewing_activity.dart';
import 'episode_progress.dart';
import 'media_item.dart';

/// Finished movies and episodes in one calendar month.
typedef MonthActivity = ({DateTime month, int finished});

/// How many counted titles carry [genreId].
typedef GenreShare = ({int genreId, int titles});

class ViewingStats {
  const ViewingStats({
    required this.moviesFinished,
    required this.moviesInProgress,
    required this.episodesFinished,
    required this.episodesInProgress,
    required this.seriesWatched,
    required this.estimatedWatchMs,
    required this.genres,
    required this.titlesWithGenres,
    required this.months,
  });

  static const empty = ViewingStats(
    moviesFinished: 0,
    moviesInProgress: 0,
    episodesFinished: 0,
    episodesInProgress: 0,
    seriesWatched: 0,
    estimatedWatchMs: 0,
    genres: [],
    titlesWithGenres: 0,
    months: [],
  );

  /// Movies watched to at least 90% of a known length.
  final int moviesFinished;

  /// Movies started (90 seconds or more) but not finished.
  final int moviesInProgress;
  final int episodesFinished;
  final int episodesInProgress;

  /// Series with at least one finished episode.
  final int seriesWatched;

  /// The furthest point reached in every counted movie and episode, added
  /// up: an estimate, not time measured.
  final int estimatedWatchMs;

  /// The most common genres among counted titles, most first, at most
  /// [topGenres].
  final List<GenreShare> genres;

  /// Counted titles whose genres are known: the base the genre shares are
  /// of.
  final int titlesWithGenres;

  /// The last [monthsShown] calendar months, oldest first, ending with the
  /// current one. Entries saved before times were kept are not in any month.
  final List<MonthActivity> months;

  static const topGenres = 5;
  static const monthsShown = 6;

  bool get isEmpty =>
      moviesFinished == 0 &&
      moviesInProgress == 0 &&
      episodesFinished == 0 &&
      episodesInProgress == 0;

  /// Counts [history] (movies and series, newest first) and [series]
  /// (per-episode progress by `series:<id>`), as of [now].
  factory ViewingStats.from({
    required List<MediaItem> history,
    required Map<String, SeriesProgress> series,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final minimum = ViewingRules.minimumPosition.inMilliseconds;
    bool finished(int position, int duration) =>
        duration > 0 && position / duration >= ViewingRules.completedShare;

    var moviesFinished = 0, moviesInProgress = 0;
    var episodesFinished = 0, episodesInProgress = 0, seriesWatched = 0;
    var watchMs = 0;
    final genreCounts = <int, int>{};
    var titlesWithGenres = 0;
    final firstMonth = DateTime(today.year, today.month - (monthsShown - 1));
    final perMonth = <DateTime, int>{
      for (var i = 0; i < monthsShown; i++)
        DateTime(firstMonth.year, firstMonth.month + i): 0,
    };
    void finishedAt(int at) {
      if (at <= 0) return;
      final time = DateTime.fromMillisecondsSinceEpoch(at);
      final month = DateTime(time.year, time.month);
      if (perMonth.containsKey(month)) perMonth[month] = perMonth[month]! + 1;
    }

    void addGenres(List<int> ids) {
      if (ids.isEmpty) return;
      titlesWithGenres++;
      for (final id in ids.toSet()) {
        genreCounts[id] = (genreCounts[id] ?? 0) + 1;
      }
    }

    // One entry per title: the history is keyed by type and id.
    final seen = <String>{};
    final seriesGenres = <String, List<int>>{};
    for (final item in history) {
      if (!seen.add('${item.type}:${item.id}')) continue;
      if (item.type == 'series') {
        seriesGenres[item.id] = item.genreIds;
        continue;
      }
      if (item.type != 'movie' || item.resumeMs < minimum) continue;
      // A position past a known end (a longer source) counts to the end.
      final position = item.durationMs > 0
          ? item.resumeMs.clamp(0, item.durationMs)
          : item.resumeMs;
      watchMs += position;
      if (finished(position, item.durationMs)) {
        moviesFinished++;
        finishedAt(item.progressAt);
      } else {
        moviesInProgress++;
      }
      addGenres(item.genreIds);
    }

    for (final MapEntry(:key, :value) in series.entries) {
      if (!key.startsWith('series:')) continue;
      var counted = false, anyFinished = false;
      for (final EpisodeProgress episode in value.episodes.values) {
        if (episode.positionMs < minimum) continue;
        counted = true;
        final position = episode.durationMs > 0
            ? episode.positionMs.clamp(0, episode.durationMs)
            : episode.positionMs;
        watchMs += position;
        if (finished(position, episode.durationMs)) {
          episodesFinished++;
          anyFinished = true;
          finishedAt(episode.at);
        } else {
          episodesInProgress++;
        }
      }
      if (anyFinished) seriesWatched++;
      if (counted) {
        addGenres(seriesGenres[key.substring('series:'.length)] ?? const []);
      }
    }

    final ranked = genreCounts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return ViewingStats(
      moviesFinished: moviesFinished,
      moviesInProgress: moviesInProgress,
      episodesFinished: episodesFinished,
      episodesInProgress: episodesInProgress,
      seriesWatched: seriesWatched,
      estimatedWatchMs: watchMs,
      genres: [
        for (final entry in ranked.take(topGenres))
          (genreId: entry.key, titles: entry.value),
      ],
      titlesWithGenres: titlesWithGenres,
      months: [
        for (final MapEntry(:key, :value) in perMonth.entries)
          (month: key, finished: value),
      ],
    );
  }

  /// `About 12 h`, `About 40 min`, or `Under a minute`.
  static String formatHours(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 1) return 'Under a minute';
    if (minutes < 60) return 'About $minutes min';
    final hours = (minutes / 60).round();
    return 'About $hours h';
  }
}
