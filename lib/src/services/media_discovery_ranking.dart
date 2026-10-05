import 'dart:math' as math;

import '../models/media_item.dart';
import 'media_catalog_rules.dart';

/// Shared quality and recency rules for discovery collections.
class MediaDiscoveryRanking {
  static const ratingThreshold = 7.0;
  static const voteThreshold = 25;
  static const newReleaseWindow = Duration(days: 180);
  static const spotlightWindow = Duration(days: 730);
  static const spotlightFallbackWindow = Duration(days: 1825);

  /// How far back the New movies row looks.
  static const newMovieWindow = Duration(days: 365);

  /// A series must have aired an episode this recently to be queued.
  static const seriesActivityWindow = Duration(days: 730);

  /// Lowest rating for a New movies title before the row needs filling.
  static const newMovieRatingFloor = 6.0;

  /// Vote count needed before a title is used to fill a short row.
  static const relaxedVoteThreshold = 5;

  /// Rows are filled from relaxed rules until they have this many titles.
  static const minimumRowSize = 10;

  // Weighted rating: a Bayesian average that pulls a title's rating toward
  // [_priorRating] until it has enough votes to stand on its own. With 150
  // prior votes, 10.0 from 2 votes scores about 6.5, while 8.5 from 25,000
  // votes keeps about 8.49. 6.5 sits near the typical TMDB average, so an
  // unproven title is treated as ordinary rather than good or bad.
  static const _priorVotes = 150;
  static const _priorRating = 6.5;

  static DateTime? parsedReleaseDate(MediaItem item) =>
      MediaFreshnessRules.releaseDate(item);

  /// Vote-aware rating from 0 to 10. Unrated or malformed ratings score 0 so
  /// they always rank after rated titles.
  static double weightedRating(MediaItem item) {
    final rating = _rating(item);
    if (rating < 0 || rating > 10) return 0;
    final votes = math.max(item.voteCount, 0);
    return (votes * rating + _priorVotes * _priorRating) /
        (votes + _priorVotes);
  }

  /// Weighted rating plus small popularity and recency bonuses. Popularity
  /// adds at most 0.4 on a log scale, so it separates close titles without
  /// outweighing quality. [freshnessWindow] adds up to [freshnessWeight] for
  /// a title released today, falling to nothing at the edge of the window.
  static double score(
    MediaItem item, {
    Duration? freshnessWindow,
    double freshnessWeight = 0.6,
    DateTime? now,
  }) {
    final popularity = math.max(item.popularity, 0).toDouble();
    final popularityBonus = math.min(
      math.log(1 + popularity) / math.ln10 * 0.12,
      0.4,
    );
    final freshnessBonus = freshnessWindow == null
        ? 0.0
        : freshnessWeight *
              MediaFreshnessRules.freshness(
                item,
                window: freshnessWindow,
                now: now,
              );
    return weightedRating(item) + popularityBonus + freshnessBonus;
  }

  /// Recent movies for the New movies row, best first.
  ///
  /// Only movies released in the last [newMovieWindow] are eligible; a high
  /// rating never brings an older title back. Titles with [voteThreshold]
  /// votes and a [newMovieRatingFloor] rating come first; titles with fewer
  /// votes fill the row only when it would otherwise be short.
  static List<MediaItem> newMovies(Iterable<MediaItem> items, {DateTime? now}) {
    final recent = MediaCatalogFilter.dedupe(items).where(
      (item) =>
          MediaCatalogFilter.isMovie(item) &&
          MediaFreshnessRules.isRecentlyReleased(
            item,
            window: newMovieWindow,
            now: now,
          ),
    );
    return _rankedWithFallback(
      [
        recent.where(
          (item) =>
              item.voteCount >= voteThreshold &&
              _rating(item) >= newMovieRatingFloor,
        ),
        recent.where((item) => item.voteCount >= relaxedVoteThreshold),
      ],
      (item) => score(item, freshnessWindow: newMovieWindow, now: now),
    );
  }

  /// Narrative series for the Series worth the queue row, best first.
  ///
  /// The strict tier is high quality scripted series; the relaxed tier fills
  /// a short row with less proven or less clearly scripted shows. Talk, news
  /// and event programming, and anything that is not a series, never enter.
  static List<MediaItem> worthQueueSeries(Iterable<MediaItem> items) {
    final series = MediaCatalogFilter.dedupe(items).where(
      MediaCatalogFilter.isSeries,
    );
    return _rankedWithFallback([
      series.where(
        (item) =>
            MediaCatalogFilter.isSuitableSeries(item) && _isHighQuality(item),
      ),
      series.where(
        (item) =>
            MediaCatalogFilter.isSuitableSeries(item, strict: false) &&
            item.voteCount >= relaxedVoteThreshold,
      ),
    ], (item) => score(item));
  }

  /// Merges recommendation lists into one ranked, unique list.
  ///
  /// High quality titles from the last [MediaFreshnessRules.currentWindow]
  /// come first; older high quality titles, then titles with fewer votes,
  /// fill the row only when needed. Series must suit a series row, and
  /// titles in [excludedKeys] (`type:id`) are left out.
  static List<MediaItem> recommendations(
    Iterable<MediaItem> items, {
    Set<String> excludedKeys = const {},
    DateTime? now,
  }) {
    final candidates = MediaCatalogFilter.dedupe(items).where(
      (item) =>
          !excludedKeys.contains(MediaCatalogFilter.key(item)) &&
          (MediaCatalogFilter.isMovie(item) ||
              MediaCatalogFilter.isSuitableSeries(item, strict: false)),
    );
    return _rankedWithFallback(
      [
        candidates.where(
          (item) =>
              _isHighQuality(item) &&
              MediaFreshnessRules.isAcceptablyCurrent(item, now: now),
        ),
        candidates.where(_isHighQuality),
        candidates.where((item) => item.voteCount >= relaxedVoteThreshold),
      ],
      (item) => score(
        item,
        freshnessWindow: MediaFreshnessRules.currentWindow,
        freshnessWeight: 0.3,
        now: now,
      ),
    );
  }

  /// The title of [type] that recommendations are built from: the best
  /// scoring high quality title, else the best scoring title with some
  /// votes, else none.
  static MediaItem? recommendationSeed(
    Iterable<MediaItem> items,
    String type,
  ) {
    final candidates = items.where(
      (item) =>
          item.type == type &&
          (type != 'series' ||
              MediaCatalogFilter.isSuitableSeries(item, strict: false)),
    );
    final ranked = _rankedWithFallback(
      [
        candidates.where(_isHighQuality),
        candidates.where((item) => item.voteCount >= relaxedVoteThreshold),
      ],
      (item) => score(item),
      minimum: 1,
    );
    return ranked.isEmpty ? null : ranked.first;
  }

  /// Sorts [items] by [score], best first. Ties keep their input order.
  static List<MediaItem> rankByScore(Iterable<MediaItem> items) =>
      _sorted(items.toList(), (item) => score(item));

  static List<MediaItem> newReleases(
    Iterable<MediaItem> items, {
    DateTime? now,
  }) {
    final today = MediaFreshnessRules.dateOnly(now ?? DateTime.now());
    final cutoff = today.subtract(newReleaseWindow);
    final eligible = MediaCatalogFilter.dedupe(items).where((item) {
      final date = parsedReleaseDate(item);
      return _isHighQuality(item) &&
          _isListableType(item) &&
          (date == null || !date.isAfter(today)) &&
          (item.hasRecentEpisode || (date != null && !date.isBefore(cutoff)));
    }).toList();

    eligible.sort((a, b) {
      DateTime sortDate(MediaItem item) {
        final date = parsedReleaseDate(item);
        if (date == null) return cutoff;
        if (item.hasRecentEpisode && date.isBefore(cutoff)) return cutoff;
        return date;
      }

      final dateOrder = sortDate(b).compareTo(sortDate(a));
      if (dateOrder != 0) return dateOrder;
      final ratingOrder = weightedRating(b).compareTo(weightedRating(a));
      return ratingOrder != 0
          ? ratingOrder
          : b.popularity.compareTo(a.popularity);
    });
    return eligible;
  }

  /// Returns high quality candidates in relevance order.
  ///
  /// Titles inside two years rank first. If fewer than six qualify, titles up
  /// to five years old are added as a documented, high quality fallback.
  static List<MediaItem> spotlightCandidates(
    Iterable<MediaItem> items, {
    DateTime? now,
  }) {
    final today = MediaFreshnessRules.dateOnly(now ?? DateTime.now());
    final unique = MediaCatalogFilter.dedupe(items)
        .where(_isHighQuality)
        .where(_isListableType)
        .where((item) {
          final date = parsedReleaseDate(item);
          return (date == null || !date.isAfter(today)) &&
              (item.hasRecentEpisode || date != null);
        })
        .toList();

    unique.sort((a, b) {
      DateTime rankDate(MediaItem item) {
        final date = parsedReleaseDate(item);
        final cutoff = today.subtract(spotlightWindow);
        if (date == null || (item.hasRecentEpisode && date.isBefore(cutoff))) {
          return cutoff;
        }
        return date;
      }

      final dateA = rankDate(a);
      final dateB = rankDate(b);
      final recentA =
          a.hasRecentEpisode ||
          !dateA.isBefore(today.subtract(spotlightWindow));
      final recentB =
          b.hasRecentEpisode ||
          !dateB.isBefore(today.subtract(spotlightWindow));
      if (recentA != recentB) return recentA ? -1 : 1;

      // Vote-weighted rating anchors quality; date and TMDB popularity break
      // close ties.
      final ratingOrder = weightedRating(b).compareTo(weightedRating(a));
      if (ratingOrder != 0) return ratingOrder;
      final dateOrder = dateB.compareTo(dateA);
      return dateOrder != 0 ? dateOrder : b.popularity.compareTo(a.popularity);
    });

    final recent = unique.where((item) {
      final date = parsedReleaseDate(item);
      return item.hasRecentEpisode ||
          (date != null && !date.isBefore(today.subtract(spotlightWindow)));
    }).toList();
    if (recent.length >= 6) return recent;

    // Predictable fallback: fill a short carousel with high rated titles up
    // to five years old; never relax the rating or vote-count requirements.
    return unique.where((item) {
      final date = parsedReleaseDate(item);
      return item.hasRecentEpisode ||
          (date != null &&
              !date.isBefore(today.subtract(spotlightFallbackWindow)));
    }).toList();
  }

  /// Movies, and series that suit a series row. Talk shows, news and event
  /// broadcasts stay out of curated rows even when highly rated.
  static bool _isListableType(MediaItem item) =>
      MediaCatalogFilter.isMovie(item) ||
      MediaCatalogFilter.isSuitableSeries(item, strict: false);

  static bool _isHighQuality(MediaItem item) {
    final rating = _rating(item);
    return rating >= ratingThreshold &&
        rating <= 10 &&
        item.voteCount >= voteThreshold;
  }

  static double _rating(MediaItem item) =>
      double.tryParse(item.rating.trim()) ?? -1;

  /// Ranks each tier by [scoreOf] and appends tiers in order, skipping
  /// titles already taken, until the list has [minimum] titles. The first
  /// tier is always used in full; later tiers only fill a short list.
  static List<MediaItem> _rankedWithFallback(
    List<Iterable<MediaItem>> tiers,
    double Function(MediaItem) scoreOf, {
    int minimum = minimumRowSize,
  }) {
    final result = <MediaItem>[];
    final taken = <String>{};
    for (final tier in tiers) {
      if (result.isNotEmpty && result.length >= minimum) break;
      for (final item in _sorted(tier.toList(), scoreOf)) {
        if (taken.add(MediaCatalogFilter.key(item))) result.add(item);
      }
    }
    return result;
  }

  /// Stable sort by descending score; each score is computed once.
  static List<MediaItem> _sorted(
    List<MediaItem> items,
    double Function(MediaItem) scoreOf,
  ) {
    final scored = [
      for (var index = 0; index < items.length; index++)
        (item: items[index], score: scoreOf(items[index]), index: index),
    ];
    scored.sort((a, b) {
      final order = b.score.compareTo(a.score);
      return order != 0 ? order : a.index.compareTo(b.index);
    });
    return [for (final entry in scored) entry.item];
  }
}
