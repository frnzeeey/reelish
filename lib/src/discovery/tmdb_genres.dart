// TMDB's movie and TV genre ids with display names, for the favourite-genre
// picker and the names of genre rows. TMDB's genre list changes rarely;
// an id missing here is simply never named or offered.

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
