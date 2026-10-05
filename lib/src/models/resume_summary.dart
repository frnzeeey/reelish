import 'episode_progress.dart';
import 'media_item.dart';

/// What a Continue Watching card shows for a watch-history entry: real
/// progress, never an estimate. Unknown progress shows no bar.
class ResumeSummary {
  const ResumeSummary({this.fraction = 0, this.label = ''});

  static const unknown = ResumeSummary();

  /// Watched share, 0–1. Zero hides the progress bar.
  final double fraction;

  /// Such as `S2 E1 · 27 min left`, `1h 12m left` or `Paused at 34 min`;
  /// empty when nothing reliable is known.
  final String label;

  /// For a series, [series] is its per-episode progress: the card follows
  /// the episode watched last. A series entry saved before episodes were
  /// tracked has no known episode, so it shows nothing rather than guess.
  static ResumeSummary of(MediaItem item, {SeriesProgress? series}) {
    if (item.type == 'series') {
      final last = series?.last;
      final progress = last == null
          ? null
          : series!.of(last.season, last.episode);
      if (last == null || progress == null) return unknown;
      final code = 'S${last.season} E${last.episode}';
      if (progress.isWatched) {
        return ResumeSummary(fraction: 1, label: '$code · Watched');
      }
      final left = progress.isInProgress ? progress.timeLeft : '';
      return ResumeSummary(
        fraction: progress.isInProgress ? progress.fraction : 0,
        label: left.isEmpty ? code : '$code · $left',
      );
    }
    final progress = EpisodeProgress(
      positionMs: item.resumeMs,
      durationMs: item.durationMs,
    );
    if (item.durationMs <= 0) {
      // Saved before lengths were recorded: the position is all there is.
      return progress.positionMs >= EpisodeProgress.shownAfter.inMilliseconds
          ? ResumeSummary(label: 'Paused at ${_clock(item.resumeMs)}')
          : unknown;
    }
    if (progress.isWatched) {
      return const ResumeSummary(fraction: 1, label: 'Watched');
    }
    if (!progress.isInProgress) return unknown;
    return ResumeSummary(fraction: progress.fraction, label: progress.timeLeft);
  }

  static String _clock(int positionMs) {
    final minutes = positionMs ~/ 60000;
    return minutes >= 60
        ? '${minutes ~/ 60}h ${minutes % 60}m'
        : '$minutes min';
  }
}
