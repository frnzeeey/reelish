class MediaDetails {
  const MediaDetails({
    this.overview = '',
    this.tagline = '',
    this.rating = '',
    this.voteCount = 0,
    this.status = '',
    this.runtimeMinutes,
    this.genres = const [],
    this.cast = const [],
  });

  final String overview;
  final String tagline;
  final String rating;
  final int voteCount;
  final String status;
  final int? runtimeMinutes;
  final List<String> genres;
  final List<CastMember> cast;

  factory MediaDetails.fromTmdb(Map<String, dynamic> json) {
    final credits = json['credits'] is Map
        ? Map<String, dynamic>.from(json['credits'] as Map)
        : <String, dynamic>{};
    final episodeRuntime =
        (json['episode_run_time'] as List?)?.whereType<num>().toList() ??
        const <num>[];
    final runtime =
        json['runtime'] as num? ??
        (episodeRuntime.isEmpty ? null : episodeRuntime.first);
    final rating = json['vote_average'] as num?;
    final rawCast = (credits['cast'] as List?) ?? const [];

    return MediaDetails(
      overview: '${json['overview'] ?? ''}',
      tagline: '${json['tagline'] ?? ''}',
      rating: rating == null ? '' : rating.toStringAsFixed(1),
      voteCount: (json['vote_count'] as num?)?.toInt() ?? 0,
      status: '${json['status'] ?? ''}',
      runtimeMinutes: runtime?.toInt(),
      genres: ((json['genres'] as List?) ?? const [])
          .whereType<Map>()
          .map((genre) => '${genre['name'] ?? ''}')
          .where((name) => name.isNotEmpty)
          .toList(),
      cast: rawCast
          .whereType<Map>()
          .take(20)
          .map(
            (person) => CastMember.fromTmdb(Map<String, dynamic>.from(person)),
          )
          .toList(),
    );
  }
}

class CastMember {
  const CastMember({
    required this.name,
    required this.character,
    required this.profile,
  });

  final String name;
  final String character;
  final String profile;

  factory CastMember.fromTmdb(Map<String, dynamic> json) {
    final profilePath = '${json['profile_path'] ?? ''}';
    return CastMember(
      name: '${json['name'] ?? 'Unknown'}',
      character: '${json['character'] ?? ''}',
      profile: profilePath.isEmpty
          ? ''
          : 'https://image.tmdb.org/t/p/w185$profilePath',
    );
  }
}
