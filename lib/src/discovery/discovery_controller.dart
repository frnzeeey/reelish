// Runs personalised discovery for the signed-in account: records viewing
// from saved watch positions, keeps feedback and picked genres, and builds
// Home's personalised rows, showing the last rows at once and refreshing
// them in the background at most every few hours or when tastes change.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../services/media_catalog_rules.dart';
import '../services/storage_service.dart';
import 'discovery_data.dart';
import 'discovery_engine.dart';
import 'discovery_store.dart';
import 'taste_profile.dart';
import 'viewing_activity.dart';

class DiscoveryController extends ChangeNotifier {
  DiscoveryController({
    required this.recommendationsFor,
    StorageService? storage,
    DiscoveryStore? store,
    this.weights = DiscoveryWeights.standard,
    DateTime Function()? clock,
    this.refreshInterval = const Duration(hours: 6),
  }) : _storage = storage ?? StorageService(),
       _store = store ?? DiscoveryStore(),
       _clock = clock ?? DateTime.now;

  /// The controller Home is running, for Settings > Recommendations; null
  /// while Home is not.
  static DiscoveryController? active;

  /// TMDB's recommendations for a seed title (the app passes
  /// `TmdbService.recommendations`, which is cached and rate limited).
  final Future<List<MediaItem>> Function(MediaItem seed) recommendationsFor;
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
    _notify();
    if (userId == null) return _loading = Future.value();
    return _loading = _load(userId);
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
      final fingerprint = _fingerprintOf(profile);
      final computedAt = _computedAt;
      final fresh =
          computedAt != null &&
          now.difference(computedAt) < refreshInterval &&
          fingerprint == _fingerprint;
      if (!force && !_refreshAgain && fresh) return;
      _refreshAgain = false;
      if (profile.isEmpty) {
        await _apply(userId, const [], now, fingerprint);
        return;
      }
      // One request per seed (at most DiscoveryWeights.maxSeeds), side by
      // side; TmdbService caches them and bounds concurrency. A failed seed
      // only loses its own candidates.
      final lists = await Future.wait([
        for (final seed in profile.seeds)
          recommendationsFor(seed.item).then(
            (items) => SeedCandidates(seed, items),
            onError: (Object _) => SeedCandidates(seed, const []),
          ),
      ]);
      if (_userId != userId || _disposed) return;
      final sections = DiscoveryEngine.build(
        profile,
        seedLists: [
          for (final list in lists)
            if (list.items.isNotEmpty) list,
        ],
        pool: pool,
        weights: weights,
        now: now,
      );
      // Nothing came back (offline, TMDB down): keep the rows already shown.
      final noCandidates =
          pool.isEmpty && lists.every((list) => list.items.isEmpty);
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

  /// What the rows depend on: the seeds, the leading genres and every
  /// title that must not be recommended.
  static String _fingerprintOf(TasteProfile profile) {
    final excluded = profile.excludedKeys.toList()..sort();
    return [
      profile.seeds.map((seed) => seed.key).join(','),
      profile.topGenres.take(5).join(','),
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
    if (userId == null || !_loaded || _disposed) return;
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

  Future<void> setFavoriteGenres(List<int> genres) =>
      _change((data) => data.withFavoriteGenres(genres));

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
    stopRecording();
    if (active == this) active = null;
    super.dispose();
  }
}
