import 'package:flutter/foundation.dart';

import '../models/episode_progress.dart';
import '../models/media_item.dart';
import '../models/resume_summary.dart';
import '../services/media_catalog_rules.dart';
import '../services/media_discovery_ranking.dart';
import '../services/paged_feed_controller.dart';
import '../services/storage_service.dart';
import '../services/tmdb_response_cache.dart';
import '../services/tmdb_service.dart';

/// Home's data, shared by the phone, TV and Windows layouts: the catalog
/// rows, Top 10 and how it is seeded, the Continue watching row, and My
/// list. The layouts decide when rows load (as they near the screen) and how
/// they look; this decides what the rows hold.
///
/// Each row is its own [PagedFeedController]: loading one never reloads
/// another. Page 1 of New movies and Series worth the queue is the source
/// for the spotlight, the Movies and Series tabs and the Top 10 seeds, so
/// those two start with Home. New releases and Top 10 wait until they
/// approach the screen.
class HomeViewModel extends ChangeNotifier {
  HomeViewModel({required this._tmdb, required this._storage}) {
    movies = PagedFeedController(
      label: 'NewMovies',
      staleAfter: TmdbCacheTtl.catalog,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) =>
          _tmdb.newMoviesPage(
            page: page,
            forceRefresh: forceRefresh,
            onRevalidated: onRevalidated,
          ),
    );
    series = PagedFeedController(
      label: 'SeriesWorthTheQueue',
      staleAfter: TmdbCacheTtl.catalog,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) =>
          _tmdb.streamingSeriesPage(
            page: page,
            forceRefresh: forceRefresh,
            onRevalidated: onRevalidated,
          ),
    );
    releases = PagedFeedController(
      label: 'NewReleases',
      staleAfter: TmdbCacheTtl.newReleases,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) =>
          _tmdb.newReleasesPage(
            page: page,
            previous: previous,
            forceRefresh: forceRefresh,
            onRevalidated: onRevalidated,
          ),
    );
    top10 = PagedFeedController(
      label: 'Top10',
      targetCount: 10,
      staleAfter: TmdbCacheTtl.recommendations,
      select: (candidates) => MediaDiscoveryRanking.recommendations(
        candidates,
        excludedKeys: _top10SeedKeys,
      ),
      fetch: _fetchTop10Page,
    );
  }

  final TmdbService _tmdb;
  final StorageService _storage;

  late final PagedFeedController movies;
  late final PagedFeedController series;
  late final PagedFeedController releases;
  late final PagedFeedController top10;

  /// Every catalog row.
  List<PagedFeedController> get catalogFeeds => [
    movies,
    series,
    releases,
    top10,
  ];

  /// The titles Top 10 was built from, chosen when its page 1 loads.
  List<MediaItem> _top10Seeds = const [];
  Set<String> _top10SeedKeys = const {};

  List<MediaItem> _continueWatching = const [];
  Map<String, SeriesProgress> _seriesProgress = const {};
  Set<String> _favoriteKeys = {};
  bool _disposed = false;

  /// Started titles from the watch history, most recent first.
  List<MediaItem> get continueWatching => _continueWatching;

  /// The watch history has been read at least once, so an empty
  /// [continueWatching] means nothing is started, not "not loaded yet".
  bool get historyLoaded => _historyLoaded;
  bool _historyLoaded = false;

  /// `type:id` of the titles on My list.
  Set<String> get favoriteKeys => _favoriteKeys;

  static String keyOf(MediaItem item) => '${item.type}:${item.id}';

  bool isFavorite(MediaItem item) => _favoriteKeys.contains(keyOf(item));

  /// Page 1 of Movies and Series has loaded (or failed) and holds titles:
  /// Top 10 and New releases may load.
  bool get catalogSettled =>
      [movies, series].every(
        (feed) =>
            feed.state.status == PagedFeedStatus.ready ||
            feed.state.status == PagedFeedStatus.failed,
      ) &&
      (movies.state.items.isNotEmpty || series.state.items.isNotEmpty);

  /// Quietly renews rows whose page 1 has outlived its cache lifetime.
  void revalidateStaleFeeds() {
    for (final feed in catalogFeeds) {
      feed.revalidateIfStale();
    }
  }

  /// Top 10 comes from the recommendations of the best movie and the best
  /// series on page 1 of the catalog, ranked with vote-weighted scores.
  /// The seeds are chosen again whenever page 1 of Top 10 is loaded.
  Future<CatalogPage> _fetchTop10Page(
    int page, {
    CatalogPage? previous,
    required bool forceRefresh,
    void Function(CatalogPage)? onRevalidated,
  }) {
    if (page == 1) {
      final catalog = [...movies.firstPageItems, ...series.firstPageItems];
      _top10Seeds = [
        for (final type in const ['movie', 'series'])
          MediaDiscoveryRanking.recommendationSeed(catalog, type),
      ].whereType<MediaItem>().toList();
      _top10SeedKeys = _top10Seeds.map(MediaCatalogFilter.key).toSet();
    }
    if (_top10Seeds.isEmpty) {
      return Future.value(const CatalogPage(items: [], page: 1, totalPages: 1));
    }
    return _tmdb.recommendationCandidatesPage(
      _top10Seeds,
      page: page,
      previous: previous,
      forceRefresh: forceRefresh,
      onRevalidated: onRevalidated,
    );
  }

  /// Where [item] was left: for a series, the episode watched last.
  ResumeSummary resumeSummary(MediaItem item) =>
      ResumeSummary.of(item, series: _seriesProgress[keyOf(item)]);

  /// The newest history and My list reads. Loads overlap (Home and the
  /// Library both ask, and a history read waits on each series' progress),
  /// so a read that finishes after a newer one is dropped: a read started
  /// before a removal must not bring the removed title back.
  int _historyRead = 0, _favoritesRead = 0;

  Future<void> loadHistory() async {
    final read = ++_historyRead;
    final value = await _storage.history();
    // Series cards follow the episode watched last, so load each series'
    // per-episode progress with the history.
    final progress = <String, SeriesProgress>{};
    for (final item in value) {
      if (item.type != 'series' || item.resumeMs <= 0) continue;
      try {
        progress[keyOf(item)] = await _storage.seriesProgress(item);
      } catch (_) {}
    }
    if (_disposed || read != _historyRead) return;
    _continueWatching = value.where((item) => item.resumeMs > 0).toList();
    _historyLoaded = true;
    _seriesProgress = progress;
    notifyListeners();
  }

  Future<void> loadFavorites() async {
    final read = ++_favoritesRead;
    final value = await _storage.favorites();
    if (_disposed || read != _favoritesRead) return;
    _favoriteKeys = value.map(keyOf).toSet();
    notifyListeners();
  }

  /// Adds [item] to My list or removes it; completes with whether it is on
  /// the list afterwards.
  Future<bool> toggleFavorite(MediaItem item) async {
    await _storage.toggleFavorite(item);
    final read = ++_favoritesRead;
    final favorites = await _storage.favorites();
    final keys = favorites.map(keyOf).toSet();
    if (_disposed) return false;
    // A newer read already published; this toggle's answer stands either way.
    if (read == _favoritesRead) {
      _favoriteKeys = keys;
      notifyListeners();
    }
    return keys.contains(keyOf(item));
  }

  @override
  void dispose() {
    _disposed = true;
    // Requests still running for these rows finish without touching them.
    for (final feed in catalogFeeds) {
      feed.dispose();
    }
    super.dispose();
  }
}
