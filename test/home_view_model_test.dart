import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/media_discovery_ranking.dart';
import 'package:onfeed/src/services/paged_feed_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/viewmodels/home_view_model.dart';

MediaItem _movie(String id, {double rating = 8, int votes = 900}) => MediaItem(
  id: id,
  type: 'movie',
  name: 'Movie $id',
  rating: rating.toStringAsFixed(1),
  voteCount: votes,
  popularity: 50,
  releaseDate: '2024-01-01',
  genreIds: const [28],
);

class _FakeTmdb extends TmdbService {
  List<MediaItem> movies = const [];
  List<MediaItem> candidates = const [];
  final seedsAsked = <List<String>>[];

  CatalogPage _page(List<MediaItem> items, int page) =>
      CatalogPage(items: items, page: page, totalPages: 1);

  @override
  Future<CatalogPage> newMoviesPage({
    int page = 1,
    bool forceRefresh = false,
    void Function(CatalogPage)? onRevalidated,
  }) async => _page(movies, page);

  @override
  Future<CatalogPage> streamingSeriesPage({
    int page = 1,
    bool forceRefresh = false,
    void Function(CatalogPage)? onRevalidated,
  }) async => _page(const [], page);

  @override
  Future<CatalogPage> recommendationCandidatesPage(
    List<MediaItem> seeds, {
    int page = 1,
    CatalogPage? previous,
    bool forceRefresh = false,
    void Function(CatalogPage)? onRevalidated,
  }) async {
    seedsAsked.add([for (final seed in seeds) seed.id]);
    return _page(candidates, page);
  }
}

class _FakeStorage extends StorageService {
  final history_ = <MediaItem>[];
  final favorites_ = <MediaItem>[];

  @override
  Future<List<MediaItem>> history() async => [...history_];

  @override
  Future<List<MediaItem>> favorites() async => [...favorites_];

  @override
  Future<SeriesProgress> seriesProgress(MediaItem series) async =>
      SeriesProgress.empty;

  @override
  Future<void> toggleFavorite(MediaItem item) async {
    final had = favorites_.any((i) => i.id == item.id);
    if (had) {
      favorites_.removeWhere((i) => i.id == item.id);
    } else {
      favorites_.add(item);
    }
  }
}

void main() {
  late _FakeTmdb tmdb;
  late _FakeStorage storage;
  late HomeViewModel model;

  setUp(() {
    tmdb = _FakeTmdb();
    storage = _FakeStorage();
    model = HomeViewModel(tmdb: tmdb, storage: storage);
  });

  test('the catalog settles once page 1 of Movies and Series is in', () async {
    tmdb.movies = [_movie('a')];
    expect(model.catalogSettled, isFalse);
    await model.movies.ensureLoaded();
    expect(model.catalogSettled, isFalse, reason: 'Series not loaded yet');
    await model.series.ensureLoaded();
    expect(model.catalogSettled, isTrue);
    model.dispose();
  });

  test('Top 10 is seeded from page 1 and never lists its seeds', () async {
    tmdb
      ..movies = [_movie('best', rating: 9), _movie('good')]
      ..candidates = [
        _movie('best', rating: 9),
        for (var i = 0; i < 12; i++) _movie('rec$i', rating: 8 - i * .1),
      ];
    await model.movies.ensureLoaded();
    await model.series.ensureLoaded();
    await model.top10.ensureLoaded();

    final seed = MediaDiscoveryRanking.recommendationSeed(tmdb.movies, 'movie');
    expect(tmdb.seedsAsked, [
      [seed!.id],
    ]);
    final keys = model.top10.state.items.map(MediaCatalogFilter.key);
    expect(keys, isNotEmpty);
    expect(keys, isNot(contains(MediaCatalogFilter.key(seed))));
    expect(model.top10.state.items.length, lessThanOrEqualTo(10));
    model.dispose();
  });

  test('without a seed, Top 10 is empty and asks TMDB nothing', () async {
    await model.top10.ensureLoaded();
    expect(model.top10.state.items, isEmpty);
    expect(model.top10.state.status, PagedFeedStatus.ready);
    expect(tmdb.seedsAsked, isEmpty);
    model.dispose();
  });

  test('Continue watching holds started titles only', () async {
    storage.history_.addAll([
      const MediaItem(id: '1', type: 'movie', name: 'Started', resumeMs: 5),
      const MediaItem(id: '2', type: 'movie', name: 'Finished'),
    ]);
    var notified = 0;
    model.addListener(() => notified++);
    await model.loadHistory();
    expect(model.continueWatching.map((i) => i.id), ['1']);
    expect(notified, 1);
    model.dispose();
  });

  test('My list toggles and reports the result', () async {
    const item = MediaItem(id: '9', type: 'series', name: 'Show');
    await model.loadFavorites();
    expect(model.isFavorite(item), isFalse);
    expect(await model.toggleFavorite(item), isTrue);
    expect(model.favoriteKeys, {'series:9'});
    expect(await model.toggleFavorite(item), isFalse);
    expect(model.isFavorite(item), isFalse);
    model.dispose();
  });

  test('dispose ends the rows and ignores late answers', () async {
    final pending = model.loadFavorites();
    model.dispose();
    await pending;
    expect(model.favoriteKeys, isEmpty);
    // The rows were disposed with it.
    expect(() => model.movies.addListener(() {}), throwsFlutterError);
  });
}
