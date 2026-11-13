// Runs personalised discovery for the signed-in account: records viewing
// from saved watch positions, keeps feedback and picked genres, and builds
// Home's personalised rows, showing the last rows at once and refreshing
// them in the background at most every few hours or when tastes change. The
// preferences (picked genres, the genre step, personalisation on or off) are
// synced with the account's other devices through [DiscoveryPreferencesRemote].

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../services/media_catalog_rules.dart';
import '../services/storage_service.dart';
import 'discovery_data.dart';
import 'discovery_engine.dart';
import 'discovery_preferences.dart';
import 'discovery_store.dart';
import 'taste_profile.dart';
import 'tmdb_genres.dart';
import 'viewing_activity.dart';

class DiscoveryController extends ChangeNotifier {
  DiscoveryController({
    required this.recommendationsFor,
    this.genreTitles,
    this.genreCatalog,
    this.remote,
    StorageService? storage,
    DiscoveryStore? store,
    this.weights = DiscoveryWeights.standard,
    DateTime Function()? clock,
    this.refreshInterval = const Duration(hours: 6),
    this.pushDelay = const Duration(seconds: 3),
    this.pullInterval = const Duration(minutes: 2),
  }) : _storage = storage ?? StorageService(),
       _store = store ?? DiscoveryStore(),
       _clock = clock ?? DateTime.now;

  /// Picked genres asked about per refresh: the strongest always, and one
  /// more that changes day by day, so every picked genre gets its turn.
  static const maxGenreRows = 2;

  /// The controller Home is running, for Settings > Recommendations; null
  /// while Home is not.
  static DiscoveryController? active;

  /// TMDB's recommendations for a seed title (the app passes
  /// `TmdbService.recommendations`, which is cached and rate limited).
  final Future<List<MediaItem>> Function(MediaItem seed) recommendationsFor;

  /// TMDB's titles of one genre (`movie` or `series`, a TMDB genre id of
  /// that side); the app passes `TmdbService.genreTitles`. Without it, picked
  /// genres only weigh the titles Home already has.
  final Future<List<MediaItem>> Function(String type, int genreId)? genreTitles;

  /// TMDB's genre lists (`TmdbService.genreCatalog`); the built-in copy
  /// when absent.
  final Future<GenreCatalog> Function()? genreCatalog;

  /// The Reelish API's copy of the preferences; none in tests of other
  /// things, and then preferences stay on this device.
  final DiscoveryPreferencesRemote? remote;

  /// A preference change is sent this long after the last one, so a few
  /// genre taps in a row make one request.
  final Duration pushDelay;

  /// Returning to the app asks for other devices' changes at most this
  /// often.
  final Duration pullInterval;
  final DiscoveryWeights weights;

  /// Rows older than this are rebuilt on the next refresh even when the
  /// viewer's tastes have not changed, as the catalog moves on.
  final Duration refreshInterval;

  final StorageService _storage;
  final DiscoveryStore _store;
  final DateTime Function() _clock;

  String? _userId;
  DiscoveryData _data = DiscoveryData.empty;
  Future<void>? _loading;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  bool _disposed = false;

  List<DiscoverySection> _computed = const [];
  List<DiscoverySection> _sections = const [];
  DateTime? _computedAt;
  String _fingerprint = '';
  bool _loaded = false;

  /// The account whose data is in use; null when nobody is signed in, and
  /// then discovery does nothing.
  String? get userId => _userId;

  /// Personalised rows to show, without titles the viewer has since
  /// started or hidden. Empty on a cold start.
  List<DiscoverySection> get sections => _sections;

  /// The account's data has been read (rows may still be empty).
  bool get loaded => _loaded;
  bool get refreshing => _refreshing != null;
  DateTime? get computedAt => _computedAt;
  DiscoveryData get data => _data;
  List<int> get favoriteGenres => _data.favoriteGenres;

  /// Personalised rows are wanted (Settings > Recommendations).
  bool get personalization => _data.personalization;

  /// The Reelish API has answered for this account since it was bound, so
  /// the preferences are the account's, not only this device's.
  bool get remoteChecked => _remoteChecked;
  bool _remoteChecked = false;

  Timer? _pushTimer;
  Future<void>? _syncing;
  bool _syncAgain = false;
  DateTime? _lastPull;
  Future<void> _preferencesSettled = Future.value();

  /// Completes once the first preferences sync after [bindUser] has ended,
  /// answered or not. Home waits for it before deciding on the genre step.
  Future<void> get preferencesSettled => _preferencesSettled;

  /// Uses [userId]'s data from now on. Another account's rows and data are
  /// dropped from memory first, so nothing of theirs is ever shown.
  Future<void> bindUser(String? userId) {
    if (userId == _userId && _loading != null) return _loading!;
    _userId = userId;
    _data = DiscoveryData.empty;
    _computed = const [];
    _sections = const [];
    _computedAt = null;
    _fingerprint = '';
    _loaded = false;
    _remoteChecked = false;
    _lastPull = null;
    _pushTimer?.cancel();
    _pushTimer = null;
    _notify();
    if (userId == null) {
      _preferencesSettled = Future.value();
      return _loading = Future.value();
    }
    final loading = _loading = _load(userId);
    _preferencesSettled = loading.then((_) => syncPreferences());
    return loading;
  }

  Future<void> _load(String userId) async {
    try {
      var data = await _store.load(userId);
      if (!data.seededFromHistory) {
        data = await _seedFromHistory(userId, data);
      }
      final cached = await _store.cachedSections(userId);
      if (_userId != userId || _disposed) return;
      _data = data;
      if (cached != null) {
        _computed = cached.sections;
        _computedAt = cached.computedAt;
        _fingerprint = cached.fingerprint;
      }
    } catch (_) {
      // Unreadable data starts empty; Home's other rows are unaffected.
    }
    if (_userId != userId || _disposed) return;
    _loaded = true;
    _publish();
  }

  /// Reads the watch history kept before discovery existed into the first
  /// account's activity, once. Other accounts on the device start empty.
  Future<DiscoveryData> _seedFromHistory(
    String userId,
    DiscoveryData data,
  ) async {
    if (!await _store.claimDeviceHistory(userId)) {
      return _store.update(userId, (current) => current.seeded());
    }
    final history = await _storage.history();
    final now = _clock();
    final entries = <TitleActivity>[];
    for (var index = history.length - 1; index >= 0; index--) {
      final item = history[index];
      // History is newest first with no dates: space entries an hour apart
      // so their order survives.
      final at = now.subtract(Duration(hours: index));
      if (item.type == 'series') {
        final progress = await _storage.seriesProgress(item);
        TitleActivity? entry;
        for (final MapEntry(:key, :value) in progress.episodes.entries) {
          final parts = key.split(':');
          final season = int.tryParse(parts.first);
          final episode = int.tryParse(parts.last);
          if (parts.length != 2 || season == null || episode == null) continue;
          entry =
              TitleActivity.record(
                entry,
                item,
                positionMs: value.positionMs,
                durationMs: value.durationMs,
                episode: (season: season, episode: episode),
                at: at,
              ) ??
              entry;
        }
        if (entry != null) entries.add(entry);
      } else {
        final entry = TitleActivity.record(
          null,
          item,
          positionMs: item.resumeMs,
          durationMs: item.durationMs,
          at: at,
        );
        if (entry != null) entries.add(entry);
      }
    }
    return _store.update(userId, (current) {
      var next = current;
      for (final entry in entries) {
        if (!next.activity.containsKey(entry.key)) {
          next = next.withActivity(entry);
        }
      }
      return next.seeded();
    });
  }

  /// Rebuilds the rows in the background when they are out of date: older
  /// than [refreshInterval], or built from different tastes. [pool] is the
  /// titles Home already has (catalog rows, Trending), scored alongside the
  /// seeds' recommendations at no extra request. Callers at the same time
  /// share one refresh; never throws.
  Future<void> refresh({
    List<MediaItem> pool = const [],
    bool force = false,
  }) async {
    final userId = _userId;
    if (userId == null || _disposed) return;
    await _loading;
    if (_userId != userId || _disposed) return;
    if (_refreshing != null) {
      _refreshAgain = force || _refreshAgain;
      return _refreshing;
    }
    // Starting and ending a refresh is not announced: Home rebuilds only
    // when the rows change (see _publish).
    _refreshing = _rebuild(
      userId,
      pool,
      force,
    ).whenComplete(() => _refreshing = null);
    return _refreshing;
  }

  Future<void> _rebuild(String userId, List<MediaItem> pool, bool force) async {
    try {
      final myList = await _storage.favorites();
      final now = _clock();
      final profile = TasteProfile.build(
        _data,
        myList: myList,
        weights: weights,
        now: now,
      );
      final genres = genresToQuery(profile, _data.favoriteGenres, now);
      final fingerprint = _fingerprintOf(profile, genres);
      final computedAt = _computedAt;
      final fresh =
          computedAt != null &&
          now.difference(computedAt) < refreshInterval &&
          fingerprint == _fingerprint;
      if (!force && !_refreshAgain && fresh) return;
      _refreshAgain = false;
      // Personalisation off: no request, no rows.
      if (profile.isEmpty || !_data.personalization) {
        await _apply(userId, const [], now, fingerprint);
        return;
      }
      // One request per seed (at most DiscoveryWeights.maxSeeds) and two per
      // queried genre (movies, series), side by side; TmdbService caches
      // them and bounds concurrency. A failed request only loses its own
      // candidates.
      final seedLists = Future.wait([
        for (final seed in profile.seeds)
          recommendationsFor(seed.item).then(
            (items) => SeedCandidates(seed, items),
            onError: (Object _) => SeedCandidates(seed, const []),
          ),
      ]);
      final genreLists = _genreCandidates(genres);
      final lists = await seedLists;
      final byGenre = await genreLists;
      if (_userId != userId || _disposed) return;
      final sections = DiscoveryEngine.build(
        profile,
        seedLists: [
          for (final list in lists)
            if (list.items.isNotEmpty) list,
        ],
        genreLists: [
          for (final list in byGenre)
            if (list.items.isNotEmpty) list,
        ],
        pool: pool,
        weights: weights,
        now: now,
      );
      // Nothing came back (offline, TMDB down): keep the rows already shown.
      final noCandidates =
          pool.isEmpty &&
          lists.every((list) => list.items.isEmpty) &&
          byGenre.every((list) => list.items.isEmpty);
      // They still lose anything watched or hidden since.
      if (noCandidates && _computed.isNotEmpty) {
        _publish();
        return;
      }
      await _apply(userId, sections, now, fingerprint);
    } catch (_) {
      // The last rows stay; Home works without them.
    }
  }

  Future<void> _apply(
    String userId,
    List<DiscoverySection> sections,
    DateTime at,
    String fingerprint,
  ) async {
    if (_userId != userId || _disposed) return;
    _computed = sections;
    _computedAt = at;
    _fingerprint = fingerprint;
    _publish();
    await _store.saveSections(
      userId,
      CachedDiscovery(
        sections: sections,
        computedAt: at,
        fingerprint: fingerprint,
      ),
    );
  }

  /// The picked genres to ask TMDB about: the one the viewer leans to most
  /// (by the profile's affinity, which counts viewing as well as picks)
  /// and, from the rest, one that changes with the day. Empty with nothing
  /// picked: genres only inferred from viewing use the rows Home has.
  @visibleForTesting
  static List<int> genresToQuery(
    TasteProfile profile,
    List<int> picked,
    DateTime now,
  ) {
    if (picked.isEmpty) return const [];
    double affinity(int id) => TmdbGenres.expand([
      id,
    ]).map((g) => profile.genreAffinity[g] ?? 0.0).fold(0.0, math.max);
    final ranked = [...picked.toSet()]
      ..sort((a, b) {
        final order = affinity(b).compareTo(affinity(a));
        return order != 0 ? order : a.compareTo(b);
      });
    final rest = ranked.skip(1).toList();
    if (rest.isEmpty || maxGenreRows < 2) return [ranked.first];
    final day = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(2026)).inDays;
    return [ranked.first, rest[day % rest.length]];
  }

  /// TMDB's titles for each of [genres], movies and series together. A
  /// genre with no TMDB equivalent on one side asks only the other.
  Future<List<GenreCandidates>> _genreCandidates(List<int> genres) async {
    final fetch = genreTitles;
    if (fetch == null || genres.isEmpty) return const [];
    GenreCatalog catalog;
    try {
      catalog =
          await (genreCatalog?.call() ?? Future.value(GenreCatalog.fallback));
    } catch (_) {
      catalog = GenreCatalog.fallback;
    }
    Future<List<MediaItem>> titles(String type, int? id) => id == null
        ? Future.value(const <MediaItem>[])
        : fetch(type, id).catchError((Object _) => const <MediaItem>[]);
    return Future.wait([
      for (final genre in genres)
        Future.wait([
          titles('movie', catalog.movieQueryId(genre)),
          titles('series', catalog.tvQueryId(genre)),
        ]).then((lists) => GenreCandidates(genre, [...lists[0], ...lists[1]])),
    ]);
  }

  /// What the rows depend on: the seeds, the leading genres, the genres
  /// asked about and every title that must not be recommended.
  static String _fingerprintOf(TasteProfile profile, List<int> genres) {
    final excluded = profile.excludedKeys.toList()..sort();
    return [
      profile.seeds.map((seed) => seed.key).join(','),
      profile.topGenres.take(5).join(','),
      genres.join(','),
      excluded.length,
      _fnv1a(excluded.join(',')),
    ].join('|');
  }

  /// A hash that is the same on every launch (String.hashCode need not be),
  /// since fingerprints are saved with the rows.
  static String _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16);
  }

  /// [_computed] without titles started or hidden since it was built, so a
  /// title never stays recommended after the viewer acted on it.
  void _publish() {
    final hidden = {..._data.activity.keys, ..._data.feedback.keys};
    if (!_data.personalization) {
      _sections = const [];
      _notify();
      return;
    }
    _sections = [
      for (final section in _computed)
        if (section.items.any(
          (item) => !hidden.contains(MediaCatalogFilter.key(item)),
        ))
          DiscoverySection(
            kind: section.kind,
            title: section.title,
            seedKey: section.seedKey,
            reasons: section.reasons,
            items: [
              for (final item in section.items)
                if (!hidden.contains(MediaCatalogFilter.key(item))) item,
            ],
          ),
    ];
    _notify();
  }

  // Recording ---------------------------------------------------------------

  /// Starts recording saved watch positions for the bound account.
  void startRecording() => StorageService.onProgressSaved = _recordProgress;

  void stopRecording() {
    if (StorageService.onProgressSaved == _recordProgress) {
      StorageService.onProgressSaved = null;
    }
  }

  /// Positions arrive every few seconds; only changes that matter (a new
  /// title or episode, a finish, a new share band) are written.
  void _recordProgress(SavedProgress saved) {
    final userId = _userId;
    // Personalisation off: nothing is learned from viewing meanwhile.
    if (userId == null || !_loaded || _disposed || !_data.personalization) {
      return;
    }
    final item = saved.item;
    if (!MediaCatalogFilter.hasValidTmdbId(item)) return;
    final key = '${item.type}:${item.id}';
    final previous = _data.activity[key];
    final now = _clock();
    final next = TitleActivity.record(
      previous,
      item,
      positionMs: saved.positionMs,
      durationMs: saved.durationMs,
      episode: saved.episode,
      at: now,
    );
    if (next == null) return;
    _data = _data.withActivity(next);
    if (previous == null || previous.meaningfullyDifferent(next, now: now)) {
      unawaited(
        _store
            .update(userId, (current) => current.withActivity(next))
            .then<void>((_) {}, onError: (Object _) {}),
      );
      // Rows are not rebuilt here, under the player: Home refreshes them
      // when the viewer comes back, which drops this title from them.
    }
  }

  // Feedback and settings ---------------------------------------------------

  Future<void> giveFeedback(FeedbackKind kind, MediaItem item) => _change(
    (data) => data.withFeedback(TitleFeedback.of(kind, item, _clock())),
  );

  Future<void> undoFeedback(MediaItem item) =>
      _change((data) => data.withoutFeedback(MediaCatalogFilter.key(item)));

  /// Forgets every Not interested, so those titles may be recommended again.
  Future<void> showHiddenAgain() =>
      _change((data) => data.withoutFeedbackOf(FeedbackKind.notInterested));

  Future<void> setFavoriteGenres(List<int> genres) => _changePreferences(
    (current) => DiscoveryPreferences(
      onboarding: current.onboarding,
      genres: genres,
      personalization: current.personalization,
    ),
  );

  /// The genre step answered with [genres] (already checked against TMDB's
  /// lists by the picker).
  Future<void> completeOnboarding(List<int> genres) => _changePreferences(
    (current) => DiscoveryPreferences(
      onboarding: OnboardingState.completed,
      genres: genres,
      personalization: current.personalization,
    ),
  );

  /// The genre step skipped, or the Home card dismissed: it is not offered
  /// again on any of the account's devices. Settings still has the genres.
  Future<void> skipOnboarding() => _changePreferences(
    (current) => DiscoveryPreferences(
      onboarding: current.onboarding ?? OnboardingState.skipped,
      genres: current.genres,
      personalization: current.personalization,
    ),
  );

  /// Personalised rows on or off. Off, Home shows its general rows and
  /// nothing is learned from viewing; what was learned is kept.
  Future<void> setPersonalization(bool enabled) async {
    await _changePreferences(
      (current) => DiscoveryPreferences(
        onboarding: current.onboarding,
        genres: current.genres,
        personalization: enabled,
      ),
    );
  }

  /// What Home does about the genre step for this account now.
  /// [accountCreatedAt] comes from the Reelish API (`GET /me`).
  OnboardingNeed onboardingNeed({DateTime? accountCreatedAt}) {
    if (_userId == null || !_loaded) return OnboardingNeed.none;
    return OnboardingPolicy.decide(
      preferences: _data.preferences,
      hasActivity: _data.activity.isNotEmpty,
      remoteChecked: _remoteChecked,
      accountCreatedAt: accountCreatedAt,
      now: _clock(),
    );
  }

  Future<void> _changePreferences(
    DiscoveryPreferences Function(DiscoveryPreferences current) change,
  ) async {
    final userId = _userId;
    if (userId == null) return;
    await _loading;
    if (_userId != userId) return;
    final next = change(_data.preferences);
    if (next == _data.preferences) return;
    final at = _clock();
    // Rows are rebuilt for the new tastes on the next refresh: the
    // fingerprint changes with the genres, and turning personalisation back
    // on must not show rows built before it was turned off.
    if (next.personalization != _data.personalization) _computedAt = null;
    await _change((data) => data.withPreferences(next, at));
    _schedulePush();
  }

  // Preferences sync ----------------------------------------------------------

  void _schedulePush() {
    if (remote == null) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(pushDelay, () {
      _pushTimer = null;
      unawaited(syncPreferences());
    });
  }

  /// Sends a change still waiting, then takes the server's copy where it is
  /// the newer one. On return to the app ([pull] false) it asks only if
  /// [pullInterval] has passed. Never throws; a failure is tried again at
  /// the next change, launch or return to the app.
  Future<void> syncPreferences({bool pull = true}) async {
    final userId = _userId;
    if (remote == null || userId == null || _disposed) return;
    await _loading;
    if (_userId != userId || _disposed) return;
    if (!pull && !_data.preferencesUnsent) {
      final last = _lastPull;
      if (last != null && _clock().difference(last) < pullInterval) return;
    }
    if (_syncing != null) {
      _syncAgain = true;
      return _syncing;
    }
    _syncing = _syncOnce(userId).whenComplete(() => _syncing = null);
    await _syncing;
    // Asked again meanwhile, perhaps for another account bound since: one
    // more pass for whoever is bound now.
    if (_syncAgain && !_disposed) {
      _syncAgain = false;
      await syncPreferences();
    }
  }

  Future<void> _syncOnce(String userId) async {
    final remote = this.remote!;
    try {
      _pushTimer?.cancel();
      _pushTimer = null;
      final sent = _data.preferences;
      final DiscoveryPreferences? stored;
      if (_data.preferencesUnsent) {
        stored = await remote.push(
          userId,
          sent,
          _data.preferencesChangedAt ?? _clock(),
        );
      } else {
        final fetched = await remote.fetch(userId);
        // Nothing on the server yet, but genres picked here before sync
        // existed: they become the account's.
        stored = fetched == null && !sent.isDefault
            ? await remote.push(
                userId,
                sent,
                _data.preferencesChangedAt ??
                    DateTime.fromMillisecondsSinceEpoch(0),
              )
            : fetched;
      }
      if (_userId != userId || _disposed) return;
      _remoteChecked = true;
      _lastPull = _clock();
      // Changed here again while the request was out: that change goes next.
      if (_data.preferences != sent) {
        _schedulePush();
        _notify();
        return;
      }
      if (stored == null) {
        if (_data.preferencesUnsent) {
          await _change((data) => data.withSyncedPreferences(data.preferences));
        } else {
          _notify();
        }
        return;
      }
      final winner = stored;
      if (winner.personalization && !_data.personalization) _computedAt = null;
      await _change((data) => data.withSyncedPreferences(winner));
    } catch (_) {
      // Offline or the service is down: the device's copy stands, and a
      // change waiting stays marked to send.
    }
  }

  /// Forgets this account's viewing activity, feedback and rows. Picked
  /// genres stay (they are changed in Settings), and the device's old
  /// watch history is not read in again.
  Future<void> reset() async {
    final userId = _userId;
    if (userId == null) return;
    await _change((data) => data.reset());
    _computed = const [];
    _computedAt = null;
    _fingerprint = '';
    _publish();
    await _store.clearSections(userId);
  }

  Future<void> _change(DiscoveryData Function(DiscoveryData) change) async {
    final userId = _userId;
    if (userId == null) return;
    await _loading;
    if (_userId != userId) return;
    _data = change(_data);
    _publish();
    await _store.update(userId, change);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pushTimer?.cancel();
    stopRecording();
    if (active == this) active = null;
    super.dispose();
  }
}
