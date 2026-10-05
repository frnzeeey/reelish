import '../models/media_item.dart';

/// TMDB genre ids used by the catalog rules.
abstract final class TmdbGenre {
  // TV-only genres for programming that is not a narrative series.
  static const talk = 10767;
  static const news = 10763;
  static const reality = 10764;
  static const soap = 10766;
  static const documentary = 99;

  /// Story-driven genres. A show tagged with one of these is a scripted
  /// series even when it also carries a documentary or reality tag.
  /// Comedy is left out on purpose: TMDB tags most talk shows as comedy.
  static const narrativeTv = {
    18, // Drama
    80, // Crime
    9648, // Mystery
    10759, // Action & Adventure
    10765, // Sci-Fi & Fantasy
    10768, // War & Politics
    37, // Western
    16, // Animation
  };
}

/// Media-type and suitability checks shared by every home list.
abstract final class MediaCatalogFilter {
  /// TMDB `with_type` values for the series rows: Miniseries | Scripted.
  /// Excludes the Documentary, News, Reality, Talk Show and Video types.
  static const tmdbScriptedTvTypes = '2|4';

  /// TMDB `without_genres` for the series rows: Talk, News, Reality, Soap.
  static final tmdbExcludedTvGenres = [
    TmdbGenre.talk,
    TmdbGenre.news,
    TmdbGenre.reality,
    TmdbGenre.soap,
  ].join('|');

  /// Event programming that TMDB files as TV but is not a series to queue.
  static final _eventTitle = RegExp(
    r'\b(awards?|ceremony|pageant|telethon)\b',
    caseSensitive: false,
  );

  static bool isMovie(MediaItem item) => item.type == 'movie';

  static bool isSeries(MediaItem item) => item.type == 'series';

  /// TMDB ids are positive integers; parsed TMDB records without one are
  /// skipped before they reach any list.
  static bool hasValidTmdbId(MediaItem item) =>
      (int.tryParse(item.id.trim()) ?? 0) > 0;

  /// Whether [item] fits a curated series row.
  ///
  /// Talk shows, news and award/event broadcasts never qualify. With
  /// [strict], reality and soap programming, documentaries without a story
  /// genre, and shows without any genre data are left out as well. The
  /// relaxed check only drops reality programming that has no story genre,
  /// so a short row can be filled without admitting talk or news shows.
  static bool isSuitableSeries(MediaItem item, {bool strict = true}) {
    if (!isSeries(item)) return false;
    final genres = item.genreIds;
    if (genres.contains(TmdbGenre.talk) || genres.contains(TmdbGenre.news)) {
      return false;
    }
    if (_eventTitle.hasMatch(item.name)) return false;
    final narrative = genres.any(TmdbGenre.narrativeTv.contains);
    if (!strict) return narrative || !genres.contains(TmdbGenre.reality);
    if (genres.isEmpty) return false;
    if (genres.contains(TmdbGenre.reality) || genres.contains(TmdbGenre.soap)) {
      return false;
    }
    return narrative || !genres.contains(TmdbGenre.documentary);
  }

  /// `type:id`, the identity used to keep lists unique.
  static String key(MediaItem item) => '${item.type}:${item.id.trim()}';

  /// Removes repeated titles, keeping the first occurrence and its order.
  static List<MediaItem> dedupe(Iterable<MediaItem> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(
          item.id.trim().isNotEmpty
              ? key(item)
              : '${item.type}:${item.name.trim().toLowerCase()}',
        ))
          item,
    ];
  }
}

/// Date rules for discovery rows. Search and details never use these, so old
/// titles stay reachable when someone asks for them.
abstract final class MediaFreshnessRules {
  /// Recommendations older than this are only used to fill a short row.
  static const currentWindow = Duration(days: 365 * 10);

  /// Release date for ranking. For a series, a newer episode air date makes
  /// an older, still running series current again.
  static DateTime? releaseDate(MediaItem item) {
    final released = parseDate(item.releaseDate);
    if (item.type != 'series') return released;
    final lastAired = parseDate(item.lastAirDate);
    if (lastAired != null && (released == null || lastAired.isAfter(released))) {
      return lastAired;
    }
    return released;
  }

  /// Released on or before today and no older than [window]. Missing,
  /// malformed and future dates are not recent.
  static bool isRecentlyReleased(
    MediaItem item, {
    required Duration window,
    DateTime? now,
  }) {
    final date = releaseDate(item);
    if (date == null) return false;
    final today = dateOnly(now ?? DateTime.now());
    return !date.isAfter(today) && !date.isBefore(today.subtract(window));
  }

  /// Recent enough for a modern discovery row: inside [currentWindow], or a
  /// series known to have aired a recent episode.
  static bool isAcceptablyCurrent(MediaItem item, {DateTime? now}) =>
      item.hasRecentEpisode ||
      isRecentlyReleased(item, window: currentWindow, now: now);

  /// 1.0 for a title released today, falling linearly to 0.0 at the edge of
  /// [window]. 0.0 for missing, future or older dates.
  static double freshness(
    MediaItem item, {
    required Duration window,
    DateTime? now,
  }) {
    final date = releaseDate(item);
    if (date == null || window.inDays <= 0) return 0;
    final age = dateOnly(now ?? DateTime.now()).difference(date).inDays;
    if (age < 0 || age > window.inDays) return 0;
    return 1 - age / window.inDays;
  }

  /// Reads a TMDB `yyyy-mm-dd` date as that calendar day. It is not
  /// converted from local time, which would move it to the previous day in
  /// time zones ahead of UTC.
  static DateTime? parseDate(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    final parsed = DateTime.tryParse(normalized);
    return parsed == null ? null : dateOnly(parsed);
  }

  static DateTime dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  /// `yyyy-mm-dd`, the date format TMDB filters expect.
  static String tmdbDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
