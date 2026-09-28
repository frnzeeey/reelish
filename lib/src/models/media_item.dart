class MediaItem {
  const MediaItem({
    required this.id,
    required this.type,
    required this.name,
    this.poster = '',
    this.background = '',
    this.description = '',
    this.year = '',
    this.rating = '',
    this.externalId = '',
    this.resumeMs = 0,
    this.subtitleQuery = '',
  });
  final String id,
      type,
      name,
      poster,
      background,
      description,
      year,
      rating,
      externalId;
  final int resumeMs;
  final String subtitleQuery;
  factory MediaItem.fromJson(Map<String, dynamic> j, {String type = 'movie'}) =>
      MediaItem(
        id: '${j['id'] ?? ''}',
        type: '${j['type'] ?? type}',
        name: '${j['name'] ?? j['title'] ?? 'Untitled'}',
        poster: '${j['poster'] ?? ''}',
        background: '${j['background'] ?? j['poster'] ?? ''}',
        description: '${j['description'] ?? ''}',
        year: '${j['year'] ?? ''}',
        rating: '${j['imdbRating'] ?? ''}',
        externalId: '${j['imdb_id'] ?? ''}',
        subtitleQuery: '${j['subtitleQuery'] ?? ''}',
      );
  factory MediaItem.fromStorage(Map<String, dynamic> j) => MediaItem.fromJson(
    j,
  ).copyWith(resumeMs: int.tryParse('${j['resumeMs']}') ?? 0);
  factory MediaItem.fromTmdb(Map<String, dynamic> json, {String? mediaType}) {
    final rawType = '${mediaType ?? json['media_type'] ?? 'movie'}';
    final type = rawType == 'tv' || rawType == 'series' ? 'series' : 'movie';
    final date =
        '${json[type == 'series' ? 'first_air_date' : 'release_date'] ?? ''}';
    final posterPath = '${json['poster_path'] ?? ''}';
    final backdropPath = '${json['backdrop_path'] ?? ''}';
    return MediaItem(
      id: '${json['id'] ?? ''}',
      type: type,
      name: '${json[type == 'series' ? 'name' : 'title'] ?? 'Untitled'}',
      poster: posterPath.isEmpty
          ? ''
          : 'https://image.tmdb.org/t/p/w500$posterPath',
      background: backdropPath.isEmpty
          ? (posterPath.isEmpty
                ? ''
                : 'https://image.tmdb.org/t/p/w1280$posterPath')
          : 'https://image.tmdb.org/t/p/w1280$backdropPath',
      description: '${json['overview'] ?? ''}',
      year: date.length >= 4 ? date.substring(0, 4) : '',
      rating: json['vote_average'] == null
          ? ''
          : (json['vote_average'] as num).toStringAsFixed(1),
      externalId: '${json['imdb_id'] ?? ''}',
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'name': name,
    'poster': poster,
    'background': background,
    'description': description,
    'year': year,
    'rating': rating,
    'externalId': externalId,
    'resumeMs': resumeMs,
    'subtitleQuery': subtitleQuery,
  };
  MediaItem copyWith({
    int? resumeMs,
    String? externalId,
    String? id,
    String? subtitleQuery,
  }) => MediaItem(
    id: id ?? this.id,
    type: type,
    name: name,
    poster: poster,
    background: background,
    description: description,
    year: year,
    rating: rating,
    externalId: externalId ?? this.externalId,
    resumeMs: resumeMs ?? this.resumeMs,
    subtitleQuery: subtitleQuery ?? this.subtitleQuery,
  );
}
