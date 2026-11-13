// Everything personalised discovery keeps for one account: viewing activity,
// feedback on recommendations and the genres the viewer picked. JSON shapes
// here are persisted user data; keep old values readable.

import '../models/media_item.dart';
import 'discovery_preferences.dart';
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
    this.onboarding,
    this.personalization = true,
    this.preferencesChangedAt,
    this.preferencesUnsent = false,
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

  /// How the genre step was answered; null if it never was.
  final OnboardingState? onboarding;

  /// Personalised rows wanted on Home.
  final bool personalization;

  /// When the genres, [onboarding] or [personalization] last changed on
  /// this device; null if they never did.
  final DateTime? preferencesChangedAt;

  /// That change has not reached the Reelish API yet.
  final bool preferencesUnsent;

  /// What is synced across the account's devices.
  DiscoveryPreferences get preferences => DiscoveryPreferences(
    onboarding: onboarding,
    genres: favoriteGenres,
    personalization: personalization,
  );

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

  /// [preferences] as changed on this device at [at], waiting to be sent.
  DiscoveryData withPreferences(
    DiscoveryPreferences preferences,
    DateTime at,
  ) => _copy(
    favoriteGenres: List.unmodifiable(preferences.genres.toSet()),
    onboarding: () => preferences.onboarding,
    personalization: preferences.personalization,
    preferencesChangedAt: () => at,
    preferencesUnsent: true,
  );

  /// [preferences] as the Reelish API holds them: nothing left to send.
  DiscoveryData withSyncedPreferences(DiscoveryPreferences preferences) =>
      _copy(
        favoriteGenres: List.unmodifiable(preferences.genres.toSet()),
        onboarding: () => preferences.onboarding,
        personalization: preferences.personalization,
        preferencesUnsent: false,
      );

  DiscoveryData seeded() => _copy(seededFromHistory: true);

  /// Viewing activity and feedback forgotten; the preferences and the
  /// history-seeded mark stay.
  DiscoveryData reset() => DiscoveryData(
    favoriteGenres: favoriteGenres,
    seededFromHistory: seededFromHistory,
    onboarding: onboarding,
    personalization: personalization,
    preferencesChangedAt: preferencesChangedAt,
    preferencesUnsent: preferencesUnsent,
  );

  DiscoveryData _copy({
    Map<String, TitleActivity>? activity,
    Map<String, TitleFeedback>? feedback,
    List<int>? favoriteGenres,
    bool? seededFromHistory,
    OnboardingState? Function()? onboarding,
    bool? personalization,
    DateTime? Function()? preferencesChangedAt,
    bool? preferencesUnsent,
  }) => DiscoveryData(
    activity: activity ?? this.activity,
    feedback: feedback ?? this.feedback,
    favoriteGenres: favoriteGenres ?? this.favoriteGenres,
    seededFromHistory: seededFromHistory ?? this.seededFromHistory,
    onboarding: onboarding == null ? this.onboarding : onboarding(),
    personalization: personalization ?? this.personalization,
    preferencesChangedAt: preferencesChangedAt == null
        ? this.preferencesChangedAt
        : preferencesChangedAt(),
    preferencesUnsent: preferencesUnsent ?? this.preferencesUnsent,
  );

  // Fields added after version 1 are optional and omitted at their
  // defaults, so data written before them reads as it always did.
  Map<String, Object?> toJson() => {
    'v': 1,
    'activity': [for (final entry in activity.values) entry.toJson()],
    'feedback': [for (final entry in feedback.values) entry.toJson()],
    if (favoriteGenres.isNotEmpty) 'genres': favoriteGenres,
    if (seededFromHistory) 'seeded': true,
    if (onboarding != null) 'onboarding': onboarding!.name,
    if (!personalization) 'personalization': false,
    if (preferencesChangedAt != null)
      'prefsAt': preferencesChangedAt!.toUtc().toIso8601String(),
    if (preferencesUnsent) 'prefsUnsent': true,
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
      onboarding: OnboardingState.values.asNameMap()[json['onboarding']],
      personalization: json['personalization'] != false,
      preferencesChangedAt: DateTime.tryParse('${json['prefsAt'] ?? ''}'),
      preferencesUnsent: json['prefsUnsent'] == true,
    );
  }
}
