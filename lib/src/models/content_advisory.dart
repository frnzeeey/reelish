import 'package:flutter/foundation.dart';

/// A kind of content a rating board named, in Reelish's own words.
enum ContentDescriptor {
  violence('Violence'),
  sexualContent('Sexual Content'),
  nudity('Nudity'),
  language('Language'),
  drugUse('Drug Use'),
  frighteningScenes('Frightening Scenes'),
  matureThemes('Mature Themes');

  const ContentDescriptor(this.label);

  final String label;
}

/// What the player's advisory says about a title, from TMDB's age ratings.
///
/// An age rating and a content descriptor are different facts and are kept
/// apart. Every title's rating comes from one country. Descriptors are only
/// ever what a rating board attached to its own rating, and TMDB has none
/// for the US or UK, so they usually come from another country's board and
/// say which ([descriptorSource]). Nothing is worked out from genres,
/// keywords or the rating itself, and a title with no data has no advisory.
/// TMDB rates series, not episodes, so an episode shows its series' rating.
@immutable
class ContentAdvisory {
  const ContentAdvisory({
    required this.rating,
    required this.ratingCountry,
    this.showCountry = false,
    this.descriptors = const [],
    this.descriptorSource = '',
  });

  /// `R`, `TV-MA`, `15`.
  final String rating;

  /// The ISO country whose board gave [rating].
  final String ratingCountry;

  /// Whether [rating] comes from outside the viewer's own country, where
  /// `16` alone would not say whose scale it is on.
  final bool showCountry;

  final List<ContentDescriptor> descriptors;

  /// Where [descriptors] came from when that is not [ratingCountry]'s board,
  /// such as `From the rating in Germany (12)`.
  final String descriptorSource;

  String get heading => descriptors.isEmpty ? 'AGE RATING' : 'CONTENT ADVISORY';

  String get ratingLabel => showCountry ? '$rating · $ratingCountry' : rating;

  String get descriptorLine =>
      descriptors.map((descriptor) => descriptor.label).join(' · ');

  /// The whole advisory as a screen reader says it.
  String get spokenLabel => [
    'Age rating $rating${showCountry ? ', $ratingCountry' : ''}',
    if (descriptors.isNotEmpty)
      'Content advisory: '
          '${descriptors.map((descriptor) => descriptor.label).join(', ')}',
    if (descriptorSource.isNotEmpty) descriptorSource,
  ].join('. ');

  /// Reads `/movie/{id}/release_dates`; null when nothing reliable is there.
  /// [region] is the viewer's country.
  static ContentAdvisory? fromMovie(Object? json, {String? region}) {
    final byCountry = <String, List<_Rated>>{};
    for (final country in _results(json)) {
      final code = country['iso_3166_1'];
      final releases = country['release_dates'];
      if (code is! String || releases is! List) continue;
      final rated = releases.whereType<Map>().map(_Rated.ofRelease).nonNulls;
      byCountry[code] = rated.toList()..sort(_Rated.compare);
    }
    return _build(byCountry, region);
  }

  /// Reads `/tv/{id}/content_ratings`; null when nothing reliable is there.
  /// [region] is the viewer's country.
  static ContentAdvisory? fromSeries(Object? json, {String? region}) {
    final byCountry = <String, List<_Rated>>{};
    for (final country in _results(json)) {
      final code = country['iso_3166_1'];
      final rated = _Rated.ofSeries(country);
      if (code is String && rated != null) {
        (byCountry[code] ??= []).add(rated);
      }
    }
    return _build(byCountry, region);
  }

  static Iterable<Map<dynamic, dynamic>> _results(Object? json) =>
      json is Map && json['results'] is List
      ? (json['results'] as List).whereType<Map>()
      : const [];

  /// Boards tried for descriptors after the rating's own, in order of how
  /// clearly defined their descriptors are.
  static const _boards = <String, String>{
    'NL': 'the Netherlands',
    'DE': 'Germany',
    'BR': 'Brazil',
    'ZA': 'South Africa',
    'CA': 'Canada',
    'FI': 'Finland',
    'TR': 'Turkey',
  };

  static ContentAdvisory? _build(
    Map<String, List<_Rated>> byCountry,
    String? region,
  ) {
    final viewer = region?.toUpperCase();
    final rated = <String>[?viewer, 'US', 'GB'].firstWhere(
      (code) => byCountry[code]?.isNotEmpty ?? false,
      orElse: () => '',
    );

    for (final code in [if (rated.isNotEmpty) rated, ..._boards.keys]) {
      final entries = byCountry[code] ?? const <_Rated>[];
      if (entries.isEmpty) continue;
      // A country can hold several releases; the fullest one speaks for it.
      final best = entries.reduce(
        (a, b) =>
            b.descriptorsIn(code).length > a.descriptorsIn(code).length ? b : a,
      );
      final descriptors = best.descriptorsIn(code);
      if (descriptors.isEmpty) continue;
      // No rating at home or in the US or UK: the board's own rating is the
      // only one to show, with the descriptors it came with.
      final ratedBy = rated.isEmpty ? code : rated;
      return ContentAdvisory(
        rating: rated.isEmpty ? best.rating : byCountry[rated]!.first.rating,
        ratingCountry: ratedBy,
        showCountry: ratedBy != viewer,
        descriptors: descriptors,
        descriptorSource: code == ratedBy
            ? ''
            : 'From the rating in ${_boards[code] ?? code} (${best.rating})',
      );
    }
    if (rated.isEmpty) return null;
    return ContentAdvisory(
      rating: byCountry[rated]!.first.rating,
      ratingCountry: rated,
      showCountry: rated != viewer,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContentAdvisory &&
      other.rating == rating &&
      other.ratingCountry == ratingCountry &&
      other.showCountry == showCountry &&
      listEquals(other.descriptors, descriptors) &&
      other.descriptorSource == descriptorSource;

  @override
  int get hashCode => Object.hash(
    rating,
    ratingCountry,
    showCountry,
    Object.hashAll(descriptors),
    descriptorSource,
  );
}

/// One rating with the descriptors TMDB holds for it.
class _Rated {
  const _Rated(this.rating, this.descriptors, {this.type = 0, this.note = ''});

  final String rating;
  final List<String> descriptors;
  final int type;
  final String note;

  static _Rated? ofRelease(Map<dynamic, dynamic> release) {
    final rating = _rating(release['certification']);
    if (rating == null) return null;
    final type = release['type'];
    final note = release['note'];
    return _Rated(
      rating,
      _strings(release['descriptors']),
      type: type is int ? type : 0,
      note: note is String ? note.trim() : '',
    );
  }

  static _Rated? ofSeries(Map<dynamic, dynamic> entry) {
    final rating = _rating(entry['rating']);
    return rating == null
        ? null
        : _Rated(rating, _strings(entry['descriptors']));
  }

  /// A plain theatrical release first: a re-release or a festival cut can
  /// carry another rating (Fight Club is 18 in the UK, its 2024 reissue 15).
  static int compare(_Rated a, _Rated b) {
    if (a.note.isEmpty != b.note.isEmpty) return a.note.isEmpty ? -1 : 1;
    return _typeOrder(a.type).compareTo(_typeOrder(b.type));
  }

  static int _typeOrder(int type) {
    final index = const [3, 2, 4, 5, 6, 1].indexOf(type);
    return index < 0 ? 99 : index;
  }

  /// Short, printable and not a way of saying "unrated".
  static String? _rating(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty ||
        text.length > 10 ||
        const {
          'NR',
          'N/R',
          'UR',
          'NOT RATED',
          'UNRATED',
        }.contains(text.toUpperCase()) ||
        !RegExp(r'^[\p{L}\p{N} +\-/]+$', unicode: true).hasMatch(text)) {
      return null;
    }
    return text;
  }

  static List<String> _strings(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];

  /// What TMDB's text means, for values seen in its data. Anything else is
  /// left out rather than guessed at: `Negative examples`, `Criminal Acts`
  /// and `Injury` name no category here.
  static const _words = <String, ContentDescriptor>{
    'violence': ContentDescriptor.violence,
    'extreme violence': ContentDescriptor.violence,
    'contains violence': ContentDescriptor.violence,
    'violence / horror': ContentDescriptor.violence,
    'sexuality': ContentDescriptor.sexualContent,
    'sexual content': ContentDescriptor.sexualContent,
    'sex': ContentDescriptor.sexualContent,
    'nudity': ContentDescriptor.nudity,
    'language': ContentDescriptor.language,
    'coarse language': ContentDescriptor.language,
    'inappropriate language': ContentDescriptor.language,
    'drugs': ContentDescriptor.drugUse,
    'threat': ContentDescriptor.frighteningScenes,
    'fear': ContentDescriptor.frighteningScenes,
    'stressful scenes': ContentDescriptor.frighteningScenes,
    'may cause anxiety': ContentDescriptor.frighteningScenes,
    'sensitive themes': ContentDescriptor.matureThemes,
  };

  /// Single letters mean nothing without their board's scheme.
  static const _letters = <String, Map<String, ContentDescriptor>>{
    'ZA': {
      'V': ContentDescriptor.violence,
      'L': ContentDescriptor.language,
      'S': ContentDescriptor.sexualContent,
      'N': ContentDescriptor.nudity,
      'D': ContentDescriptor.drugUse,
      'H': ContentDescriptor.frighteningScenes,
    },
    'US': {
      'V': ContentDescriptor.violence,
      'FV': ContentDescriptor.violence,
      'L': ContentDescriptor.language,
      'S': ContentDescriptor.sexualContent,
      'D': ContentDescriptor.matureThemes,
    },
  };

  /// Each category once, in the enum's order.
  List<ContentDescriptor> descriptorsIn(String country) {
    final found = <ContentDescriptor>{
      for (final text in descriptors)
        ?_words[text.trim().toLowerCase()] ??
            _letters[country]?[text.trim().toUpperCase()],
    };
    return ContentDescriptor.values.where(found.contains).toList();
  }
}
