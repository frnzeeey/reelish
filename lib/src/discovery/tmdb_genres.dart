// TMDB's movie and TV genre ids with display names, for the favourite-genre
// picker and the names of genre rows. TMDB's genre list changes rarely;
// an id missing here is simply never named or offered. The picker checks
// these against TMDB's own lists (`GenreCatalog`) when it can read them.

abstract final class TmdbGenres {
  static const names = <int, String>{
    28: 'Action',
    12: 'Adventure',
    16: 'Animation',
    35: 'Comedy',
    80: 'Crime',
    99: 'Documentary',
    18: 'Drama',
    10751: 'Family',
    14: 'Fantasy',
    36: 'History',
    27: 'Horror',
    10402: 'Music',
    9648: 'Mystery',
    10749: 'Romance',
    878: 'Science fiction',
    53: 'Thriller',
    10752: 'War',
    37: 'Western',
    10759: 'Action & adventure',
    10762: 'Kids',
    10765: 'Sci-fi & fantasy',
    10768: 'War & politics',
  };

  /// Genres offered in the picker, in display order. TV-only duplicates of
  /// movie genres are folded in through [equivalents].
  static const pickable = <int>[
    28, 12, 16, 35, 80, 99, 18, 10751, 14, 36, //
    27, 10402, 9648, 10749, 878, 53, 10752, 37, 10762,
  ];

  /// TV genres that combine movie genres: a match on either side counts.
  /// TMDB publishes the two lists but not how they relate, so this one
  /// mapping is Reelish's own.
  static const equivalents = <int, List<int>>{
    10759: [28, 12],
    10765: [878, 14],
    10768: [10752],
  };

  /// [ids] with each combined TV genre expanded to its movie genres, so a
  /// liking for Sci-Fi shows on series tagged Sci-Fi & Fantasy and back.
  static Set<int> expand(Iterable<int> ids) => {
    for (final id in ids) ...[id, ...?equivalents[id]],
  };

  static String? nameOf(int id) => names[id];
}

/// TMDB's movie and TV genre lists (`/genre/movie/list`, `/genre/tv/list`),
/// and how a picked genre is asked for on each side.
class GenreCatalog {
  const GenreCatalog({required this.movie, required this.tv});

  /// TMDB's lists as of 2026; used until (or when) TMDB's own cannot be read.
  static const fallback = GenreCatalog(
    movie: {
      28: 'Action', 12: 'Adventure', 16: 'Animation', 35: 'Comedy', //
      80: 'Crime', 99: 'Documentary', 18: 'Drama', 10751: 'Family',
      14: 'Fantasy', 36: 'History', 27: 'Horror', 10402: 'Music',
      9648: 'Mystery', 10749: 'Romance', 878: 'Science Fiction',
      10770: 'TV Movie', 53: 'Thriller', 10752: 'War', 37: 'Western',
    },
    tv: {
      10759: 'Action & Adventure', 16: 'Animation', 35: 'Comedy', //
      80: 'Crime', 99: 'Documentary', 18: 'Drama', 10751: 'Family',
      10762: 'Kids', 9648: 'Mystery', 10763: 'News', 10764: 'Reality',
      10765: 'Sci-Fi & Fantasy', 10766: 'Soap', 10767: 'Talk',
      10768: 'War & Politics', 37: 'Western',
    },
  );

  /// Genre id → TMDB's name.
  final Map<int, String> movie, tv;

  /// The picker's genres that TMDB still lists on either side.
  List<int> get pickable => [
    for (final id in TmdbGenres.pickable)
      if (movieQueryId(id) != null || tvQueryId(id) != null) id,
  ];

  /// [ids] without anything TMDB does not list.
  List<int> valid(Iterable<int> ids) => [
    for (final id in {...ids})
      if (movieQueryId(id) != null || tvQueryId(id) != null) id,
  ];

  /// The movie genre to ask TMDB for when [id] was picked, if any.
  int? movieQueryId(int id) => movie.containsKey(id) ? id : null;

  /// The TV genre to ask TMDB for when [id] was picked, if any: the same id,
  /// or the combined TV genre that holds it (Science fiction → Sci-Fi &
  /// Fantasy). Documentaries are left out: the series rows keep to scripted
  /// shows, which documentary series are not.
  int? tvQueryId(int id) {
    if (id == 99) return null;
    if (tv.containsKey(id)) return id;
    for (final MapEntry(:key, :value) in TmdbGenres.equivalents.entries) {
      if (value.contains(id) && tv.containsKey(key)) return key;
    }
    return null;
  }

  /// A picked genre's name: Reelish's wording, else TMDB's.
  String? nameOf(int id) => TmdbGenres.nameOf(id) ?? movie[id] ?? tv[id];

  /// Reads a `/genre/*/list` response; null when it holds no genres.
  static Map<int, String>? parseList(Object? json) {
    if (json is! Map) return null;
    final genres = json['genres'];
    if (genres is! List) return null;
    final parsed = <int, String>{
      for (final entry in genres)
        if (entry is Map &&
            entry['id'] is int &&
            (entry['id'] as int) > 0 &&
            entry['name'] is String &&
            (entry['name'] as String).trim().isNotEmpty)
          entry['id'] as int: (entry['name'] as String).trim(),
    };
    return parsed.isEmpty ? null : parsed;
  }
}
