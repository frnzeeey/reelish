// Universal Search orchestration: what was typed, the chosen category and
// filters, and the results organised by kind. TMDB (through TmdbService and
// its caches) answers; this decides which requests to make, drops answers
// to older queries, ranks, filters, pages and remembers recent searches.
// Playback discovery is separate (playback_availability.dart): nothing here
// waits for a provider.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../analytics/analytics_events.dart';
import '../analytics/analytics_service.dart';
import '../discovery/tmdb_genres.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import 'search_models.dart';
import 'search_ranking.dart';

/// The TMDB requests search makes; [TmdbSearchCatalog] in the app.
abstract interface class SearchCatalog {
  Future<Map<String, dynamic>> multi(String query, {int page = 1});
  Future<Map<String, dynamic>> category(
    String kind,
    String query, {
    int page = 1,
    int? year,
  });
  Future<Map<String, dynamic>> discover(
    String type,
    Map<String, String> params, {
    int page = 1,
  });
  Future<Map<String, dynamic>> person(int id);
  Future<Map<String, dynamic>> collection(int id);
  Future<GenreCatalog> genres();
}

class TmdbSearchCatalog implements SearchCatalog {
  TmdbSearchCatalog(this._tmdb);

  final TmdbService _tmdb;
  Future<GenreCatalog>? _genres;

  @override
  Future<Map<String, dynamic>> multi(String query, {int page = 1}) =>
      _tmdb.searchMultiJson(query, page: page);

  @override
  Future<Map<String, dynamic>> category(
    String kind,
    String query, {
    int page = 1,
    int? year,
  }) => _tmdb.searchCategoryJson(kind, query, page: page, year: year);

  @override
  Future<Map<String, dynamic>> discover(
    String type,
    Map<String, String> params, {
    int page = 1,
  }) => _tmdb.discoverJson(type, params, page: page);

  @override
  Future<Map<String, dynamic>> person(int id) => _tmdb.personJson(id);

  @override
  Future<Map<String, dynamic>> collection(int id) => _tmdb.collectionJson(id);

  @override
  Future<GenreCatalog> genres() =>
      _genres ??= _tmdb.genreCatalog().catchError((Object _) {
        _genres = null;
        return GenreCatalog.fallback;
      });
}

enum SearchStatus {
  /// Nothing typed and no filter: recent searches and suggestions.
  landing,
  loading,
  ready,
  failed,
}

/// The All view: the best match and a few of each kind.
class SearchOverview {
  const SearchOverview({
    this.top,
    this.movies = const [],
    this.series = const [],
    this.people = const [],
    this.collections = const [],
    this.yearFromQuery,
  });

  /// A [MediaItem], [PersonHit] or [CollectionHit] that matches what was
  /// typed exactly or at its start; null when nothing stands out.
  final Object? top;
  final List<MediaItem> movies;
  final List<MediaItem> series;
  final List<PersonHit> people;
  final List<CollectionHit> collections;

  /// Set when nothing matched the whole query and its trailing year was
  /// used as a year instead ("dune 2021").
  final int? yearFromQuery;

  bool get isEmpty =>
      top == null &&
      movies.isEmpty &&
      series.isEmpty &&
      people.isEmpty &&
      collections.isEmpty;
}

/// Raw TMDB results with what search needs beyond a [MediaItem].
typedef _Titles = ({List<MediaItem> items, Map<String, String> originals});

class UniversalSearchController extends ChangeNotifier {
  UniversalSearchController({
    required this._catalog,
    this.debounce = const Duration(milliseconds: 400),
    this.maxPages = 10,
    this.filterPages = 3,
    this._readSetting,
    this._saveSetting,
    @visibleForTesting int Function()? currentYear,
  }) : _currentYear = currentYear ?? (() => DateTime.now().year);

  final SearchCatalog _catalog;
  final Future<String?> Function(String key)? _readSetting;
  final Future<void> Function(String key, String value)? _saveSetting;
  final int Function() _currentYear;

  /// How long typing must pause before a search starts.
  final Duration debounce;

  /// A category is paged this far at most (TMDB pages hold 20).
  final int maxPages;

  /// With genre or rating filters, a category reads up to this many pages
  /// for its first screen, since those filters are applied here.
  final int filterPages;

  /// Shared with the Windows search page before Universal Search.
  static const recentSearchesKey = 'onfeed.search.recent.v1';
  static const maxRecentSearches = 8;

  String _query = '';
  SearchCategory _category = SearchCategory.all;
  SearchFilters _filters = const SearchFilters();
  SearchStatus _status = SearchStatus.landing;
  SearchOverview _overview = const SearchOverview();
  List<Object> _items = const [];
  int _page = 0;
  bool _hasMore = false;
  bool _loadingMore = false;
  int _request = 0;
  Timer? _debounce;
  bool _disposed = false;
  List<String> _recent = const [];
  GenreCatalog _genres = GenreCatalog.fallback;

  String get query => _query;
  SearchCategory get category => _category;
  SearchFilters get filters => _filters;
  SearchStatus get status => _status;
  SearchOverview get overview => _overview;

  /// The chosen category's results ([MediaItem], [PersonHit] or
  /// [CollectionHit]); empty in the All view.
  List<Object> get items => _items;
  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;
  List<String> get recent => _recent;
  GenreCatalog get genres => _genres;

  /// Whether the current results are filtered (and so may leave out
  /// people and collections in the All view).
  bool get filtering => !_filters.isEmpty && _category.filterable;

  /// Reads recent searches and TMDB's genre lists; call once.
  Future<void> start() async {
    unawaited(
      _catalog.genres().then((value) {
        if (!_disposed) _update(() => _genres = value);
      }),
    );
    final read = _readSetting;
    if (read == null) return;
    try {
      final raw = await read(recentSearchesKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is List && !_disposed) {
        _update(
          () => _recent = decoded
              .whereType<String>()
              .map((q) => q.trim())
              .where((q) => q.isNotEmpty && q.length <= 100)
              .take(maxRecentSearches)
              .toList(),
        );
      }
    } catch (_) {
      // Unreadable history is simply not shown.
    }
  }

  // ---- Input ----

  /// Text typed: searches once typing pauses for [debounce].
  void queryChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(search(text)));
  }

  /// Searches for [text] now (the keyboard's search key, a recent search).
  Future<void> search(String text) {
    _debounce?.cancel();
    // A query TMDB would refuse is cut, not sent whole.
    final query = text.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
    _query = query.length > 100 ? query.substring(0, 100) : query;
    return _run();
  }

  void setCategory(SearchCategory category) {
    if (category == _category) return;
    _category = category;
    unawaited(_run());
  }

  void setFilters(SearchFilters filters) {
    if (filters == _filters) return;
    _filters = filters;
    unawaited(_run());
  }

  void clearFilters() => setFilters(const SearchFilters());

  /// Back to the landing state; anything still loading is ignored.
  void clear() {
    _debounce?.cancel();
    _query = '';
    unawaited(_run());
  }

  Future<void> retry() => _run();

  // ---- Running a search ----

  Future<void> _run() async {
    final request = ++_request;
    final query = _query;
    final browsing = query.isEmpty && !_filters.isEmpty;
    if (query.isEmpty && !browsing) {
      _update(() {
        _status = SearchStatus.landing;
        _overview = const SearchOverview();
        _items = const [];
        _hasMore = false;
        _loadingMore = false;
      });
      return;
    }
    _update(() {
      _status = SearchStatus.loading;
      _loadingMore = false;
    });
    try {
      if (_category == SearchCategory.all) {
        final overview = browsing
            ? await _browseOverview()
            : filtering
            ? await _filteredOverview(query)
            : await _overviewFor(query);
        if (!_current(request)) return;
        _update(() {
          _overview = overview;
          _items = const [];
          _hasMore = false;
          _status = SearchStatus.ready;
        });
        _settled(overview.isEmpty ? 0 : 1);
      } else {
        final page = await _categoryPage(query, 1);
        if (!_current(request)) return;
        _update(() {
          _items = page.items;
          _page = page.lastPage;
          _hasMore = page.hasMore;
          _overview = const SearchOverview();
          _status = SearchStatus.ready;
        });
        _settled(page.items.length);
      }
      if (query.isNotEmpty) unawaited(_remember(query));
    } catch (_) {
      if (!_current(request)) return;
      _update(() => _status = SearchStatus.failed);
      AnalyticsService.instance.log(
        AnalyticsEvent.search(SearchOutcome.failed, results: 0),
      );
    }
  }

  bool _current(int request) => !_disposed && request == _request;

  /// How a search settled, for usage statistics; never the query.
  void _settled(int results) => AnalyticsService.instance.log(
    AnalyticsEvent.search(
      results == 0 ? SearchOutcome.noResults : SearchOutcome.results,
      results: results,
    ),
  );

  /// Words and no filters: one mixed search (titles and people, in TMDB's
  /// order of relevance) and one for collections. Two requests.
  Future<SearchOverview> _overviewFor(String query) async {
    final results = await Future.wait([
      _catalog.multi(query),
      // Collections are a bonus: their failure never fails the search.
      _catalog
          .category('collection', query)
          .catchError((Object _) => <String, dynamic>{}),
    ]);
    final multi = results[0]['results'];
    final titles = _titles(multi);
    var movies = _ranked(query, titles, 'movie');
    var series = _ranked(query, titles, 'series');
    final people = rankByMatch(query, _people(multi), (p) => p.name);
    final collections = rankByMatch(
      query,
      _collections(results[1]['results']),
      (c) => c.name,
    );
    int? yearFromQuery;
    if (movies.isEmpty && series.isEmpty && people.isEmpty) {
      // "dune 2021": nothing is called that, so try "dune" from 2021.
      final split = trailingYear(query, now: _currentYear());
      if (split != null) {
        final retry = await Future.wait([
          _catalog.category('movie', split.words, year: split.year),
          _catalog.category('tv', split.words, year: split.year),
        ]);
        movies = _ranked(
          split.words,
          _titles(retry[0]['results'], type: 'movie'),
          'movie',
        );
        series = _ranked(
          split.words,
          _titles(retry[1]['results'], type: 'tv'),
          'series',
        );
        if (movies.isNotEmpty || series.isNotEmpty) yearFromQuery = split.year;
      }
    }
    // The best match across kinds: exact first, then a leading match, with
    // TMDB's mixed order deciding between kinds.
    final order = {
      for (final (index, entry) in (multi is List ? multi : const []).indexed)
        if (entry is Map) '${entry['media_type']}:${entry['id']}': index,
    };
    final words = yearFromQuery == null
        ? query
        : trailingYear(query, now: _currentYear())!.words;
    final candidates = <(Object, int, int)>[
      if (movies.firstOrNull case final movie?)
        (
          movie,
          matchScore(words, movie.name),
          order['movie:${movie.id}'] ?? 500,
        ),
      if (series.firstOrNull case final show?)
        (show, matchScore(words, show.name), order['tv:${show.id}'] ?? 500),
      if (people.firstOrNull case final person?)
        (
          person,
          matchScore(words, person.name),
          order['person:${person.id}'] ?? 500,
        ),
      if (collections.firstOrNull case final collection?)
        (collection, matchScore(words, collection.name), 900),
    ]..sort((a, b) => b.$2 != a.$2 ? b.$2 - a.$2 : a.$3 - b.$3);
    final top = candidates.firstOrNull;
    return SearchOverview(
      top: top != null && top.$2 >= 2 ? top.$1 : null,
      movies: movies,
      series: series,
      people: people,
      collections: collections,
      yearFromQuery: yearFromQuery,
    );
  }

  /// Words and filters: movies and series only (filters mean nothing for
  /// people or collections).
  Future<SearchOverview> _filteredOverview(String query) async {
    final pages = await Future.wait([
      _filteredTitles(query, 'movie', 1),
      _filteredTitles(query, 'tv', 1),
    ]);
    return SearchOverview(movies: pages[0].items, series: pages[1].items);
  }

  /// Filters and no words: the most popular titles that fit them.
  Future<SearchOverview> _browseOverview() async {
    final pages = await Future.wait([
      _catalog.discover('movie', _filters.discoverParams('movie', _genres)),
      _catalog.discover('tv', _filters.discoverParams('tv', _genres)),
    ]);
    return SearchOverview(
      movies: _filtered(_titles(pages[0]['results'], type: 'movie').items),
      series: _filtered(_titles(pages[1]['results'], type: 'tv').items),
    );
  }

  // ---- One category ----

  Future<({List<Object> items, int lastPage, bool hasMore})> _categoryPage(
    String query,
    int page,
  ) async {
    final browsing = query.isEmpty;
    switch (_category) {
      case SearchCategory.movies || SearchCategory.series:
        final type = _category == SearchCategory.movies ? 'movie' : 'tv';
        if (browsing) {
          final data = await _catalog.discover(
            type,
            _filters.discoverParams(type, _genres),
            page: page,
          );
          return (
            items: <Object>[
              ..._filtered(_titles(data['results'], type: type).items),
            ],
            lastPage: page,
            hasMore: _morePages(data, page),
          );
        }
        final result = await _filteredTitles(query, type, page);
        return (
          items: <Object>[...result.items],
          lastPage: result.lastPage,
          hasMore: result.hasMore,
        );
      case SearchCategory.people:
        if (browsing) return (items: <Object>[], lastPage: 1, hasMore: false);
        final data = await _catalog.category('person', query, page: page);
        return (
          items: <Object>[
            ...rankByMatch<PersonHit>(
              query,
              _people(data['results'], declared: false),
              (p) => p.name,
            ),
          ],
          lastPage: page,
          hasMore: _morePages(data, page),
        );
      case SearchCategory.collections:
        if (browsing) return (items: <Object>[], lastPage: 1, hasMore: false);
        final data = await _catalog.category('collection', query, page: page);
        return (
          items: <Object>[
            ...rankByMatch<CollectionHit>(
              query,
              _collections(data['results']),
              (c) => c.name,
            ),
          ],
          lastPage: page,
          hasMore: _morePages(data, page),
        );
      case SearchCategory.all:
        return (items: <Object>[], lastPage: 1, hasMore: false);
    }
  }

  /// A search of one title type from [page], with the filters applied.
  /// TMDB's search takes only a single year, so genres, a rating or a year
  /// range are applied here; when they leave little, the next pages are
  /// read too ([filterPages] at most).
  Future<({List<MediaItem> items, int lastPage, bool hasMore})> _filteredTitles(
    String query,
    String type,
    int page,
  ) async {
    final kind = type == 'movie' ? 'movie' : 'series';
    final found = <MediaItem>[];
    var current = page;
    var more = false;
    final limit = _filters.isEmpty ? page : page + filterPages - 1;
    while (true) {
      final data = await _catalog.category(
        type,
        query,
        page: current,
        year: _filters.singleYear,
      );
      found.addAll(
        _filtered(_ranked(query, _titles(data['results'], type: type), kind)),
      );
      more = _morePages(data, current);
      if (!more || found.length >= 12 || current >= limit) break;
      current++;
    }
    return (items: found, lastPage: current, hasMore: more);
  }

  /// The next page of the chosen category, each result once.
  Future<void> loadMore() async {
    if (_loadingMore ||
        !_hasMore ||
        _page >= maxPages ||
        _category == SearchCategory.all ||
        _status != SearchStatus.ready) {
      return;
    }
    final request = _request;
    _update(() => _loadingMore = true);
    try {
      final page = await _categoryPage(_query, _page + 1);
      if (!_current(request)) return;
      String key(Object item) => switch (item) {
        MediaItem() => 't:${item.type}:${item.id}',
        PersonHit() => 'p:${item.id}',
        CollectionHit() => 'c:${item.id}',
        _ => '$item',
      };
      final seen = _items.map(key).toSet();
      _update(() {
        _items = [
          ..._items,
          for (final item in page.items)
            if (seen.add(key(item))) item,
        ];
        _page = page.lastPage;
        _hasMore = page.hasMore && _page < maxPages;
        _loadingMore = false;
      });
    } catch (_) {
      if (_current(request)) _update(() => _loadingMore = false);
    }
  }

  // ---- Parsing ----

  _Titles _titles(Object? results, {String? type}) {
    final originals = <String, String>{};
    for (final entry in results is List ? results : const []) {
      if (entry is! Map) continue;
      final original = entry['original_title'] ?? entry['original_name'];
      final mediaType = entry['media_type'] ?? type;
      if (original is String && entry['id'] is int) {
        final kind = mediaType == 'tv' ? 'series' : 'movie';
        originals['$kind:${entry['id']}'] = original;
      }
    }
    return (
      items: TmdbService.titlesFrom(results, type: type),
      originals: originals,
    );
  }

  List<MediaItem> _ranked(String query, _Titles titles, String kind) =>
      rankByMatch(
        query,
        titles.items.where((item) => item.type == kind).toList(),
        (item) => item.name,
        original: (item) => titles.originals['${item.type}:${item.id}'] ?? '',
      );

  List<MediaItem> _filtered(List<MediaItem> items) => _filters.isEmpty
      ? items
      : items.where((item) => _filters.matches(item)).toList();

  /// People in a results list; [declared] when it is a mixed list whose
  /// entries carry `media_type`.
  static List<PersonHit> _people(Object? results, {bool declared = true}) => [
    for (final entry in results is List ? results : const [])
      if (entry is Map && (!declared || entry['media_type'] == 'person'))
        ?PersonHit.fromJson(entry),
  ];

  static List<CollectionHit> _collections(Object? results) => [
    for (final entry in results is List ? results : const [])
      ?CollectionHit.fromJson(entry),
  ];

  static bool _morePages(Map<String, dynamic> data, int page) {
    final total = data['total_pages'];
    return total is int && page < total;
  }

  // ---- Recent searches ----

  Future<void> _remember(String query) async {
    final lower = query.toLowerCase();
    final next = [
      query,
      ..._recent.where((q) => q.toLowerCase() != lower),
    ].take(maxRecentSearches).toList();
    if (listEquals(next, _recent)) return;
    _update(() => _recent = next);
    await _saveRecent();
  }

  /// Forgets recent searches on this device.
  Future<void> clearRecent() async {
    _update(() => _recent = const []);
    await _saveRecent();
  }

  Future<void> _saveRecent() async {
    try {
      await _saveSetting?.call(recentSearchesKey, jsonEncode(_recent));
    } catch (_) {
      // Not remembered this time.
    }
  }

  // ---- Pages behind a result ----

  Future<PersonDetails> person(int id) async {
    final details = PersonDetails.fromJson(await _catalog.person(id));
    if (details == null) throw StateError('No such person.');
    return details;
  }

  Future<CollectionDetails> collection(int id) async {
    final details = CollectionDetails.fromJson(await _catalog.collection(id));
    if (details == null) throw StateError('No such collection.');
    return details;
  }

  void _update(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }
}
