// Everything personalised discovery keeps for one account: viewing activity,
// feedback on recommendations and the genres the viewer picked. JSON shapes
// here are persisted user data; keep old values readable.

import '../models/media_item.dart';
import 'viewing_activity.dart';

/// What the viewer said about a recommended title.
enum FeedbackKind {
  /// Hidden from recommendations; its genres count a little less for a
  /// while. Never excludes a genre outright.
  notInterested,

  /// Seen elsewhere: hidden, and counts as a mild positive signal.
  alreadyWatched,

  /// Recommendations like this one are wanted: a strong positive signal and
  /// a seed for its own row.
  moreLikeThis,
}

class TitleFeedback {
  const TitleFeedback({
    required this.kind,
    required this.type,
    required this.id,
    required this.name,
    required this.at,
    this.genreIds = const [],
  });

  factory TitleFeedback.of(FeedbackKind kind, MediaItem item, DateTime at) =>
      TitleFeedback(
        kind: kind,
        type: item.type,
        id: item.id,
        name: item.name,
        genreIds: item.genreIds,
        at: at,
      );

  final FeedbackKind kind;
  final String type, id, name;
  final List<int> genreIds;
  final DateTime at;

  String get key => '$type:$id';

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'type': type,
    'id': id,
    'name': name,
    if (genreIds.isNotEmpty) 'genres': genreIds,
    'at': at.toUtc().toIso8601String(),
  };

  static TitleFeedback? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = FeedbackKind.values.asNameMap()[json['kind']];
    final type = json['type'], id = json['id'];
    final at = DateTime.tryParse('${json['at'] ?? ''}');
    if (kind == null ||
        (type != 'movie' && type != 'series') ||
        id is! String ||
        id.isEmpty ||
        at == null) {
      return null;
    }
    final genres = json['genres'];
    return TitleFeedback(
      kind: kind,
      type: type as String,
      id: id,
      name: '${json['name'] ?? ''}',
      genreIds: genres is List
          ? List.unmodifiable(genres.whereType<num>().map((g) => g.toInt()))
          : const [],
      at: at,
    );
  }
}

/// One account's discovery data. Immutable; changes return a new value.
class DiscoveryData {
  const DiscoveryData({
    this.activity = const {},
    this.feedback = const {},
    this.favoriteGenres = const [],
    this.seededFromHistory = false,
  });

  static const empty = DiscoveryData();

  /// Titles kept; the least recently watched go first beyond it.
  static const maxActivity = 300;
  static const maxFeedback = 300;

  /// By `type:id`, least recently changed first.
  final Map<String, TitleActivity> activity;

  /// By `type:id`, least recently given first.
  final Map<String, TitleFeedback> feedback;

  /// TMDB genre ids the viewer picked in Settings.
  final List<int> favoriteGenres;

  /// The device's watch history was already read into [activity] once (or
  /// deliberately not, see `DiscoveryStore`); it is never read again, so a
  /// reset stays reset.
  final bool seededFromHistory;

  bool get hasSignals =>
      activity.isNotEmpty ||
      favoriteGenres.isNotEmpty ||
      feedback.values.any((entry) => entry.kind != FeedbackKind.notInterested);

  DiscoveryData withActivity(TitleActivity entry) {
    final next = Map<String, TitleActivity>.of(activity)
      ..remove(entry.key)
      ..[entry.key] = entry;
    while (next.length > maxActivity) {
      next.remove(next.keys.first);
    }
    return _copy(activity: next);
  }

  DiscoveryData withFeedback(TitleFeedback entry) {
    final next = Map<String, TitleFeedback>.of(feedback)
      ..remove(entry.key)
      ..[entry.key] = entry;
    while (next.length > maxFeedback) {
      next.remove(next.keys.first);
    }
    return _copy(feedback: next);
  }

  DiscoveryData withoutFeedback(String key) =>
      _copy(feedback: Map.of(feedback)..remove(key));

  DiscoveryData withoutFeedbackOf(FeedbackKind kind) => _copy(
    feedback: {
      for (final MapEntry(:key, :value) in feedback.entries)
        if (value.kind != kind) key: value,
    },
  );

  DiscoveryData withFavoriteGenres(List<int> genres) =>
      _copy(favoriteGenres: List.unmodifiable(genres.toSet()));

  DiscoveryData seeded() => _copy(seededFromHistory: true);

  /// Viewing activity and feedback forgotten; picked genres and the
  /// history-seeded mark stay.
  DiscoveryData reset() => DiscoveryData(
    favoriteGenres: favoriteGenres,
    seededFromHistory: seededFromHistory,
  );

  DiscoveryData _copy({
    Map<String, TitleActivity>? activity,
    Map<String, TitleFeedback>? feedback,
    List<int>? favoriteGenres,
    bool? seededFromHistory,
  }) => DiscoveryData(
    activity: activity ?? this.activity,
    feedback: feedback ?? this.feedback,
    favoriteGenres: favoriteGenres ?? this.favoriteGenres,
    seededFromHistory: seededFromHistory ?? this.seededFromHistory,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'activity': [for (final entry in activity.values) entry.toJson()],
    'feedback': [for (final entry in feedback.values) entry.toJson()],
    if (favoriteGenres.isNotEmpty) 'genres': favoriteGenres,
    if (seededFromHistory) 'seeded': true,
  };

  /// Unreadable entries are skipped; an unreadable whole is [empty].
  static DiscoveryData fromJson(Object? json) {
    if (json is! Map) return empty;
    final activity = <String, TitleActivity>{};
    final rawActivity = json['activity'];
    for (final raw in rawActivity is List ? rawActivity : const []) {
      final entry = TitleActivity.fromJson(raw);
      if (entry != null) activity[entry.key] = entry;
    }
    final feedback = <String, TitleFeedback>{};
    final rawFeedback = json['feedback'];
    for (final raw in rawFeedback is List ? rawFeedback : const []) {
      final entry = TitleFeedback.fromJson(raw);
      if (entry != null) feedback[entry.key] = entry;
    }
    final genres = json['genres'];
    return DiscoveryData(
      activity: activity,
      feedback: feedback,
      favoriteGenres: genres is List
          ? List.unmodifiable(genres.whereType<num>().map((g) => g.toInt()))
          : const [],
      seededFromHistory: json['seeded'] == true,
    );
  }
}
