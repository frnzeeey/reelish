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
    this.releaseDate = '',
    this.lastAirDate = '',
    this.voteCount = 0,
    this.popularity = 0,
    this.isOngoing = false,
    this.hasRecentEpisode = false,
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
  final String releaseDate, lastAirDate;
  final int voteCount;
  final double popularity;
  final bool isOngoing;
  final bool hasRecentEpisode;
  factory MediaItem.fromJson(Map<String, dynamic> j, {String type = 'movie'}) =>
      MediaItem(
        id: '${j['id'] ?? ''}',
        type: '${j['type'] ?? type}',
        name: '${j['name'] ?? j['title'] ?? 'Untitled'}',
        poster: '${j['poster'] ?? ''}',
        background: '${j['background'] ?? j['poster'] ?? ''}',
        description: '${j['description'] ?? ''}',
        year: '${j['year'] ?? ''}',
        rating: '${j['rating'] ?? j['imdbRating'] ?? ''}',
        externalId: '${j['imdb_id'] ?? ''}',
        subtitleQuery: '${j['subtitleQuery'] ?? ''}',
        releaseDate: '${j['releaseDate'] ?? ''}',
        lastAirDate: '${j['lastAirDate'] ?? ''}',
        voteCount: int.tryParse('${j['voteCount'] ?? 0}') ?? 0,
        popularity: double.tryParse('${j['popularity'] ?? 0}') ?? 0,
        isOngoing: j['isOngoing'] == true,
        hasRecentEpisode: j['hasRecentEpisode'] == true,
      );
  factory MediaItem.fromStorage(Map<String, dynamic> j) => MediaItem.fromJson(
    j,
  ).copyWith(resumeMs: int.tryParse('${j['resumeMs']}') ?? 0);
  factory MediaItem.fromTmdb(Map<String, dynamic> json, {String? mediaType}) {
    final rawType = '${mediaType ?? json['media_type'] ?? 'movie'}';
    final type = rawType == 'tv' || rawType == 'series' ? 'series' : 'movie';
    final date =
        '${json[type == 'series' ? 'first_air_date' : 'release_date'] ?? ''}';
    final lastEpisode = json['last_episode_to_air'];
    final lastAirDate = lastEpisode is Map
        ? '${lastEpisode['air_date'] ?? ''}'
        : '${json['last_air_date'] ?? ''}';
    final rawRating = json['vote_average'];
    final rating = rawRating is num ? rawRating.toStringAsFixed(1) : '';
    final rawVoteCount = json['vote_count'];
    final rawPopularity = json['popularity'];
    final status = '${json['status'] ?? ''}';
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
      rating: rating,
      externalId: '${json['imdb_id'] ?? ''}',
      releaseDate: date,
      lastAirDate: lastAirDate,
      voteCount: rawVoteCount is num ? rawVoteCount.toInt() : 0,
      popularity: rawPopularity is num ? rawPopularity.toDouble() : 0,
      isOngoing:
          type == 'series' &&
          (json['in_production'] == true || status == 'Returning Series'),
      hasRecentEpisode: json['hasRecentEpisode'] == true,
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
    'releaseDate': releaseDate,
    'lastAirDate': lastAirDate,
    'voteCount': voteCount,
    'popularity': popularity,
    'isOngoing': isOngoing,
    'hasRecentEpisode': hasRecentEpisode,
  };
  MediaItem copyWith({
    int? resumeMs,
    String? externalId,
    String? id,
    String? subtitleQuery,
    String? releaseDate,
    String? lastAirDate,
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
    releaseDate: releaseDate ?? this.releaseDate,
    lastAirDate: lastAirDate ?? this.lastAirDate,
    voteCount: voteCount,
    popularity: popularity,
    isOngoing: isOngoing,
    hasRecentEpisode: hasRecentEpisode,
  );
}
