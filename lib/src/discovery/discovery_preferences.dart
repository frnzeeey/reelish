// The discovery preferences an account keeps on every device: whether the
// genre step was answered, the genres picked and whether personalised rows
// are wanted. Also the rule that decides whether Home asks for genres, and
// the interface the Reelish API sync implements.

/// How the viewer answered the genre step; null when it never came up.
enum OnboardingState { completed, skipped }

class DiscoveryPreferences {
  const DiscoveryPreferences({
    this.onboarding,
    this.genres = const [],
    this.personalization = true,
  });

  final OnboardingState? onboarding;

  /// TMDB genre ids, as picked (see `TmdbGenres`).
  final List<int> genres;

  /// Personalised rows on Home. Off: Home shows its general rows only.
  final bool personalization;

  /// Nothing was ever chosen: what an account without a record has.
  bool get isDefault => onboarding == null && genres.isEmpty && personalization;

  /// The shape the Reelish API stores (`backend/src/discovery-preferences.ts`).
  Map<String, Object?> toJson() => {
    'onboarding': onboarding?.name,
    'genres': genres,
    'personalization': personalization,
  };

  /// Null when [json] is not a preferences object; unknown values are
  /// dropped, not guessed.
  static DiscoveryPreferences? fromJson(Object? json) {
    if (json is! Map) return null;
    final genres = json['genres'];
    return DiscoveryPreferences(
      onboarding: OnboardingState.values.asNameMap()[json['onboarding']],
      genres: genres is List
          ? List.unmodifiable({
              for (final id in genres)
                if (id is int && id > 0 && id < 100000) id,
            })
          : const [],
      personalization: json['personalization'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveryPreferences &&
      other.onboarding == onboarding &&
      other.personalization == personalization &&
      other.genres.length == genres.length &&
      other.genres.toSet().containsAll(genres);

  @override
  int get hashCode =>
      Object.hash(onboarding, personalization, Object.hashAllUnordered(genres));
}

/// The account's preferences on the Reelish API. Implemented by
/// `DiscoveryPreferencesSync`; tests use fakes.
abstract interface class DiscoveryPreferencesRemote {
  /// What the server holds for [userId]: null when the account never saved
  /// any. Throws when the server cannot be asked.
  Future<DiscoveryPreferences?> fetch(String userId);

  /// Offers [preferences], changed at [changedAt] (this device's clock).
  /// Completes with what the server holds afterwards, which is another
  /// device's newer change when this one lost. Throws when not sent.
  Future<DiscoveryPreferences?> push(
    String userId,
    DiscoveryPreferences preferences,
    DateTime changedAt,
  );
}

/// What Home does about the genre step.
enum OnboardingNeed {
  /// Nothing: answered, genres already picked, or personalisation off.
  none,

  /// The full-screen genre step: a brand-new account.
  fullScreen,

  /// A dismissible card on Home: an existing account without preferences.
  prompt,
}

abstract final class OnboardingPolicy {
  /// An account this young, with nothing watched, is a first sign-in.
  static const newAccountAge = Duration(hours: 24);

  /// [remoteChecked]: the Reelish API answered, so another device has not
  /// already answered the step. Without that answer Home never takes over
  /// the screen; it offers the card instead.
  static OnboardingNeed decide({
    required DiscoveryPreferences preferences,
    required bool hasActivity,
    required bool remoteChecked,
    required DateTime? accountCreatedAt,
    required DateTime now,
  }) {
    if (preferences.onboarding != null ||
        preferences.genres.isNotEmpty ||
        !preferences.personalization) {
      return OnboardingNeed.none;
    }
    final created = accountCreatedAt;
    final isNew =
        created != null &&
        now.difference(created) < newAccountAge &&
        !hasActivity;
    return remoteChecked && isNew
        ? OnboardingNeed.fullScreen
        : OnboardingNeed.prompt;
  }
}
