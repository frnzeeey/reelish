// Intro and outro timestamps for one TV episode, read from IntroDB's
// `GET /segments`, and the rules that decide whether they may be used for the
// stream that is playing. External data: every field is checked, and a
// segment that does not fit the stream is dropped rather than guessed at.
// docs/player/INTRO_OUTRO_IMPLEMENTATION.md.

/// Which part of an episode a segment covers.
enum SkipKind { intro, outro }

/// The episode IntroDB is asked about: IMDb series id, season, episode.
class EpisodeKey {
  const EpisodeKey(this.imdbId, this.season, this.episode);

  /// Null unless [imdbId] is an IMDb title id and season/episode are ≥ 1,
  /// the shape IntroDB accepts.
  static EpisodeKey? of(String? imdbId, int? season, int? episode) {
    final id = imdbId?.trim() ?? '';
    if (!_imdb.hasMatch(id) ||
        season == null ||
        episode == null ||
        season < 1 ||
        episode < 1 ||
        season > 9999 ||
        episode > 99999) {
      return null;
    }
    return EpisodeKey(id, season, episode);
  }

  static final _imdb = RegExp(r'^tt[0-9]{7,8}$');

  final String imdbId;
  final int season, episode;

  String get id => '$imdbId:$season:$episode';

  @override
  bool operator ==(Object other) =>
      other is EpisodeKey &&
      other.imdbId == imdbId &&
      other.season == season &&
      other.episode == episode;

  @override
  int get hashCode => Object.hash(imdbId, season, episode);

  @override
  String toString() => 'EpisodeKey($id)';
}

/// One timed segment as IntroDB aggregates it.
class SkipSegment {
  const SkipSegment({
    required this.kind,
    required this.start,
    required this.end,
    required this.confidence,
    required this.submissions,
  });

  final SkipKind kind;
  final Duration start, end;

  /// IntroDB's agreement score, 0–1.
  final double confidence;

  /// How many submissions the aggregate is built from.
  final int submissions;

  Duration get length => end - start;

  /// Strong enough to seek without asking.
  static const autoMinConfidence = .7;
  static const autoMinSubmissions = 2;

  /// Strong enough to offer a Skip button.
  static const offerMinConfidence = .5;
  static const offerMinSubmissions = 1;

  bool get canAutoSkip =>
      confidence >= autoMinConfidence && submissions >= autoMinSubmissions;

  bool get canOffer =>
      confidence >= offerMinConfidence && submissions >= offerMinSubmissions;

  /// Lengths a real segment can have. Outside them the data is wrong.
  static const minLength = Duration(seconds: 5);
  static Duration maxLength(SkipKind kind) => kind == SkipKind.intro
      ? const Duration(minutes: 5)
      : const Duration(minutes: 15);

  Map<String, Object> toJson() => {
    'start_ms': start.inMilliseconds,
    'end_ms': end.inMilliseconds,
    'confidence': confidence,
    'submission_count': submissions,
  };

  /// A segment from IntroDB's JSON, or null when any field is missing,
  /// malformed or out of range.
  static SkipSegment? fromJson(SkipKind kind, Object? json) {
    if (json is! Map) return null;
    final start = json['start_ms'], end = json['end_ms'];
    final confidence = json['confidence'], count = json['submission_count'];
    if (start is! int || end is! int || count is! int || confidence is! num) {
      return null;
    }
    final score = confidence.toDouble();
    if (start < 0 ||
        end <= start ||
        end > const Duration(hours: 6).inMilliseconds ||
        count < 0 ||
        !score.isFinite ||
        score < 0 ||
        score > 1) {
      return null;
    }
    final segment = SkipSegment(
      kind: kind,
      start: Duration(milliseconds: start),
      end: Duration(milliseconds: end),
      confidence: score,
      submissions: count,
    );
    final length = segment.length;
    if (length < minLength || length > maxLength(kind)) return null;
    return segment;
  }

  @override
  bool operator ==(Object other) =>
      other is SkipSegment &&
      other.kind == kind &&
      other.start == start &&
      other.end == end &&
      other.confidence == confidence &&
      other.submissions == submissions;

  @override
  int get hashCode => Object.hash(kind, start, end, confidence, submissions);
}

/// What IntroDB knows about one episode: its intro and outro, either of
/// which may be missing.
class EpisodeSegments {
  const EpisodeSegments({required this.key, this.intro, this.outro});

  /// Nothing known: playback stays as it is.
  const EpisodeSegments.none(this.key) : intro = null, outro = null;

  final EpisodeKey key;
  final SkipSegment? intro, outro;

  bool get isEmpty => intro == null && outro == null;

  /// Streams shorter than this are not episodes IntroDB could have timed
  /// (trailers, broken files): nothing is skipped in them.
  static const minStreamLength = Duration(minutes: 3);

  /// The segments that fit a stream [duration] long; none when the
  /// duration is unknown. IntroDB does not say which release it timed, so
  /// this is the check that a segment belongs to *this* stream: the intro
  /// ends in the first half, the outro starts in the second half and ends
  /// inside it, and the two do not overlap (overlapping data is
  /// contradictory, so neither is used).
  EpisodeSegments forStream(Duration duration) {
    if (duration < minStreamLength) return EpisodeSegments.none(key);
    final half = duration ~/ 2;
    const slack = Duration(seconds: 5);
    var intro = this.intro;
    var outro = this.outro;
    if (intro != null && (intro.end > half || intro.end >= duration)) {
      intro = null;
    }
    if (outro != null && (outro.start < half || outro.end > duration + slack)) {
      outro = null;
    }
    if (intro != null && outro != null && outro.start < intro.end) {
      intro = outro = null;
    }
    return EpisodeSegments(key: key, intro: intro, outro: outro);
  }

  Map<String, Object?> toJson() => {
    'imdb_id': key.imdbId,
    'season': key.season,
    'episode': key.episode,
    'intro': intro?.toJson(),
    'outro': outro?.toJson(),
  };

  /// Reads IntroDB's `/segments` response for [key]. Null when the response
  /// is not about that exact episode (another series, season or episode, or
  /// a movie): such data must never be applied. Segments that fail their
  /// checks are left out; the others are kept.
  static EpisodeSegments? fromIntroDb(EpisodeKey key, Object? json) {
    if (json is! Map) return null;
    if (json['imdb_id'] != key.imdbId ||
        json['season'] != key.season ||
        json['episode'] != key.episode ||
        json['is_movie'] == true ||
        (json['media_type'] != null && json['media_type'] != 'tv')) {
      return null;
    }
    return EpisodeSegments(
      key: key,
      intro: json['no_intro'] == true
          ? null
          : SkipSegment.fromJson(SkipKind.intro, json['intro']),
      outro: json['no_outro'] == true
          ? null
          : SkipSegment.fromJson(SkipKind.outro, json['outro']),
    );
  }
}
