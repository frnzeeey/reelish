import '../models/media_item.dart';

/// Shared quality and recency rules for discovery collections.
class MediaDiscoveryRanking {
  static const ratingThreshold = 7.0;
  static const voteThreshold = 25;
  static const newReleaseWindow = Duration(days: 180);
  static const spotlightWindow = Duration(days: 730);
  static const spotlightFallbackWindow = Duration(days: 1825);

  static DateTime? parsedReleaseDate(MediaItem item) {
    final releaseDate = _parseDate(item.releaseDate);
    if (item.type != 'series') return releaseDate;

    // A new episode makes an older, still relevant series current again.
    final lastAirDate = _parseDate(item.lastAirDate);
    if (lastAirDate != null &&
        (releaseDate == null || lastAirDate.isAfter(releaseDate))) {
      return lastAirDate;
    }
    return releaseDate;
  }

  static List<MediaItem> newReleases(
    Iterable<MediaItem> items, {
    DateTime? now,
  }) {
    final today = _dateOnly(now ?? DateTime.now());
    final cutoff = today.subtract(newReleaseWindow);
    final eligible = _deduplicate(items).where((item) {
      final date = parsedReleaseDate(item);
      return _isHighQuality(item) &&
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
      final ratingOrder = _rating(b).compareTo(_rating(a));
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
    final today = _dateOnly(now ?? DateTime.now());
    final unique = _deduplicate(items).where(_isHighQuality).where((item) {
      final date = parsedReleaseDate(item);
      return (date == null || !date.isAfter(today)) &&
          (item.hasRecentEpisode || date != null);
    }).toList();

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

      // Rating anchors quality; date and TMDB popularity break close ties.
      final ratingOrder = _rating(b).compareTo(_rating(a));
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

  static bool _isHighQuality(MediaItem item) {
    final rating = _rating(item);
    return rating >= ratingThreshold &&
        rating <= 10 &&
        item.voteCount >= voteThreshold;
  }

  static double _rating(MediaItem item) =>
      double.tryParse(item.rating.trim()) ?? -1;

  static List<MediaItem> _deduplicate(Iterable<MediaItem> items) {
    final unique = <String, MediaItem>{};
    for (final item in items) {
      final id = item.id.trim();
      final titleKey = item.name.trim().toLowerCase();
      final key = id.isNotEmpty ? '${item.type}:$id' : '${item.type}:$titleKey';
      unique.putIfAbsent(key, () => item);
    }
    return unique.values.toList();
  }

  static DateTime? _parseDate(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    final parsed = DateTime.tryParse(normalized);
    if (parsed == null) return null;
    return _dateOnly(parsed.toUtc());
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
}
