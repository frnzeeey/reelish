// What Universal Search finds besides titles (people and movie collections),
// a person's and a collection's page, and the filters. Everything is parsed
// from TMDB answers that are treated as untrusted: wrong types are dropped,
// lengths capped, and only TMDB image paths become URLs.

import '../discovery/tmdb_genres.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';

String _text(Object? value, [int max = 200]) {
  if (value is! String) return '';
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length <= max ? text : text.substring(0, max);
}

int _id(Object? value) => value is int && value > 0 ? value : 0;

double _number(Object? value) => value is num ? value.toDouble() : 0;

/// A TMDB image path (`/abc.jpg`) as a URL at [size]; empty otherwise.
String tmdbImage(Object? path, {String size = 'w342'}) =>
    path is String && RegExp(r'^/[A-Za-z0-9._-]{1,120}$').hasMatch(path)
    ? 'https://image.tmdb.org/t/p/$size$path'
    : '';

/// The sections of Universal Search.
enum SearchCategory {
  all('All'),
  movies('Movies'),
  series('Series'),
  people('People'),
  collections('Collections');

  const SearchCategory(this.label);
  final String label;

  /// Whether genre, year and rating filters mean anything here. People and
  /// collections have none of those.
  bool get filterable => this == all || this == movies || this == series;
}

/// Someone found by name: an actor, a director, a writer… TMDB's
/// `known_for_department` says what they are best known for, not all they do.
class PersonHit {
  const PersonHit({
    required this.id,
    required this.name,
    this.department = '',
    this.profileUrl = '',
    this.knownFor = const [],
    this.popularity = 0,
  });

  static PersonHit? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _id(json['id']);
    final name = _text(json['name'], 120);
    if (id == 0 || name.isEmpty) return null;
    final knownFor = json['known_for'];
    return PersonHit(
      id: id,
      name: name,
      department: _text(json['known_for_department'], 40),
      profileUrl: tmdbImage(json['profile_path'], size: 'w185'),
      knownFor: [
        for (final title in TmdbService.titlesFrom(knownFor).take(3))
          title.name,
      ],
      popularity: _number(json['popularity']),
    );
  }

  final int id;
  final String name;

  /// TMDB's "known for" department (`Acting`, `Directing`…); may be empty.
  final String department;
  final String profileUrl;

  /// Up to three titles TMDB says they are known for.
  final List<String> knownFor;
  final double popularity;

  /// "Actor", "Director"… from [department], for a label.
  String get role => switch (department) {
    'Acting' => 'Acting',
    'Directing' => 'Directing',
    'Writing' => 'Writing',
    'Production' => 'Production',
    '' => 'Film and TV',
    _ => department,
  };
}

/// A movie collection on TMDB (a franchise such as "Dune Collection").
/// Not the viewer's own Reelish collections.
class CollectionHit {
  const CollectionHit({
    required this.id,
    required this.name,
    this.overview = '',
    this.posterUrl = '',
    this.backdropUrl = '',
  });

  static CollectionHit? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _id(json['id']);
    final name = _text(json['name'], 120);
    if (id == 0 || name.isEmpty) return null;
    return CollectionHit(
      id: id,
      name: name,
      overview: _text(json['overview'], 600),
      posterUrl: tmdbImage(json['poster_path']),
      backdropUrl: tmdbImage(json['backdrop_path'], size: 'w780'),
    );
  }

  final int id;
  final String name;
  final String overview;
  final String posterUrl;
  final String backdropUrl;
}

/// One credit on a person's page: the title and what they did on it.
class PersonCredit {
  const PersonCredit({required this.item, required this.role});

  final MediaItem item;

  /// The character they played, or their job ("Director").
  final String role;
}

/// A person's page: who they are and everything they are credited on,
/// acting and crew kept apart (many people do both).
class PersonDetails {
  const PersonDetails({
    required this.id,
    required this.name,
    this.department = '',
    this.biography = '',
    this.profileUrl = '',
    this.birthday = '',
    this.placeOfBirth = '',
    this.acting = const [],
    this.directing = const [],
    this.otherCrew = const [],
  });

  static PersonDetails? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _id(json['id']);
    final name = _text(json['name'], 120);
    if (id == 0 || name.isEmpty) return null;
    final credits = json['combined_credits'];
    List<PersonCredit> parse(Object? list, String roleKey, {String? job}) {
      final out = <PersonCredit>[];
      final seen = <String>{};
      for (final entry in list is List ? list : const []) {
        if (entry is! Map) continue;
        if (job != null && entry['job'] != job) continue;
        if (job == null && roleKey == 'job' && entry['job'] == 'Director') {
          continue;
        }
        final title = TmdbService.titlesFrom([entry]).firstOrNull;
        if (title == null) continue;
        final key = '${title.type}:${title.id}';
        final role = _text(entry[roleKey], 80);
        if (!seen.add(key)) continue;
        out.add(PersonCredit(item: title, role: role));
      }
      // Best-known first, so the page opens on what people look for.
      out.sort((a, b) {
        final byVotes = b.item.voteCount.compareTo(a.item.voteCount);
        return byVotes != 0 ? byVotes : b.item.year.compareTo(a.item.year);
      });
      return out.take(80).toList();
    }

    final cast = credits is Map ? credits['cast'] : null;
    final crew = credits is Map ? credits['crew'] : null;
    return PersonDetails(
      id: id,
      name: name,
      department: _text(json['known_for_department'], 40),
      biography: _text(json['biography'], 2000),
      profileUrl: tmdbImage(json['profile_path'], size: 'h632'),
      birthday: _text(json['birthday'], 10),
      placeOfBirth: _text(json['place_of_birth'], 120),
      acting: parse(cast, 'character'),
      directing: parse(crew, 'job', job: 'Director'),
      otherCrew: parse(crew, 'job'),
    );
  }

  final int id;
  final String name;
  final String department;
  final String biography;
  final String profileUrl;

  /// `YYYY-MM-DD`, or empty.
  final String birthday;
  final String placeOfBirth;
  final List<PersonCredit> acting;
  final List<PersonCredit> directing;

  /// Writing, producing and other jobs (directing excluded).
  final List<PersonCredit> otherCrew;
}

/// A collection's page: its films in release order.
class CollectionDetails {
  const CollectionDetails({
    required this.id,
    required this.name,
    this.overview = '',
    this.posterUrl = '',
    this.backdropUrl = '',
    this.parts = const [],
  });

  static CollectionDetails? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _id(json['id']);
    final name = _text(json['name'], 120);
    if (id == 0 || name.isEmpty) return null;
    final parts = TmdbService.titlesFrom(
      json['parts'],
      type: 'movie',
    ).where((part) => part.type == 'movie').toList();
    // Released films by date; films without a date (announced) at the end.
    parts.sort((a, b) {
      if (a.releaseDate.isEmpty != b.releaseDate.isEmpty) {
        return a.releaseDate.isEmpty ? 1 : -1;
      }
      return a.releaseDate.compareTo(b.releaseDate);
    });
    return CollectionDetails(
      id: id,
      name: name,
      overview: _text(json['overview'], 1200),
      posterUrl: tmdbImage(json['poster_path']),
      backdropUrl: tmdbImage(json['backdrop_path'], size: 'w1280'),
      parts: parts,
    );
  }

  final int id;
  final String name;
  final String overview;
  final String posterUrl;
  final String backdropUrl;
  final List<MediaItem> parts;
}

/// Genre, year and rating filters. They apply to movies and series only.
class SearchFilters {
  const SearchFilters({
    this.genres = const {},
    this.yearFrom,
    this.yearTo,
    this.minRating,
  });

  /// Picked genres (ids from [TmdbGenres.pickable]); a title matches any.
  final Set<int> genres;

  /// Inclusive; either may be null.
  final int? yearFrom;
  final int? yearTo;

  /// TMDB user score, 0–10.
  final double? minRating;

  /// Fewer votes than this make a TMDB score too noisy to filter by.
  static const minVotesForRating = 20;

  bool get isEmpty =>
      genres.isEmpty && yearFrom == null && yearTo == null && minRating == null;
  bool get hasYear => yearFrom != null || yearTo != null;

  /// One year exactly, which TMDB's search can narrow by itself.
  int? get singleYear =>
      yearFrom != null && yearFrom == yearTo ? yearFrom : null;

  SearchFilters copyWith({
    Set<int>? genres,
    (int?, int?)? years,
    double? Function()? minRating,
  }) => SearchFilters(
    genres: genres ?? this.genres,
    yearFrom: years == null ? yearFrom : years.$1,
    yearTo: years == null ? yearTo : years.$2,
    minRating: minRating == null ? this.minRating : minRating(),
  );

  /// Whether [item] passes. Titles without a date are left out while a year
  /// is set; titles without enough votes while a rating is set.
  bool matches(MediaItem item, {GenreCatalog? catalog}) {
    if (genres.isNotEmpty) {
      final mine = TmdbGenres.expand(item.genreIds);
      if (!genres.any(mine.contains)) return false;
    }
    if (hasYear) {
      final year = int.tryParse(item.year);
      if (year == null) return false;
      if (yearFrom != null && year < yearFrom!) return false;
      if (yearTo != null && year > yearTo!) return false;
    }
    final rating = minRating;
    if (rating != null) {
      final score = double.tryParse(item.rating);
      if (score == null || score < rating) return false;
      if (item.voteCount < minVotesForRating) return false;
    }
    return true;
  }

  /// `/discover` parameters for browsing by these filters with no words.
  Map<String, String> discoverParams(String type, GenreCatalog catalog) {
    final ids = <int>{
      for (final id in genres)
        ?(type == 'movie' ? catalog.movieQueryId(id) : catalog.tvQueryId(id)),
    };
    final from = yearFrom;
    final to = yearTo;
    final dateKey = type == 'movie' ? 'primary_release_date' : 'first_air_date';
    return {
      if (ids.isNotEmpty) 'with_genres': ids.join('|'),
      if (from != null) '$dateKey.gte': '$from-01-01',
      if (to != null) '$dateKey.lte': '$to-12-31',
      if (minRating != null) ...{
        'vote_average.gte': minRating!.toStringAsFixed(1),
        'vote_count.gte': '$minVotesForRating',
      },
    };
  }

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.yearFrom == yearFrom &&
      other.yearTo == yearTo &&
      other.minRating == minRating &&
      other.genres.length == genres.length &&
      other.genres.containsAll(genres);

  @override
  int get hashCode =>
      Object.hash(yearFrom, yearTo, minRating, Object.hashAllUnordered(genres));
}
