import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import '../services/media_catalog_rules.dart';
import '../services/tmdb_service.dart';

/// TMDB search for the TV and Windows search pages: debounced typing, page
/// 1 then more pages on demand (each title once), and a stale answer for an
/// older query never replaces a newer one.
///
/// The pages differ only in the options below; each keeps its own text
/// field, layout and wording.
class SearchViewModel extends ChangeNotifier {
  SearchViewModel({
    required this._tmdb,
    this.debounce = const Duration(milliseconds: 400),
    this.keepsResultsWhileSearching = false,
    this.clearsResultsOnError = false,
    this.maxPages = 10,
  });

  final TmdbService _tmdb;

  /// How long typing must pause before a search starts.
  final Duration debounce;

  /// Shows the previous results, rather than a spinner, while a new query
  /// loads (TV).
  final bool keepsResultsWhileSearching;

  /// Clears the results when a search fails (TV); Windows keeps them.
  final bool clearsResultsOnError;

  /// TMDB pages hold 20 results; more pages than this are never requested.
  final int maxPages;

  String _query = '';
  List<MediaItem> _results = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  bool _failed = false;
  int _request = 0;
  int _firstPageVersion = 0;
  Timer? _debounce;
  bool _disposed = false;

  /// The query the results are for, trimmed.
  String get query => _query;
  List<MediaItem> get results => _results;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  bool get failed => _failed;

  /// Changes when a new query's results arrive or the search is cleared;
  /// not when more pages are appended, nor when a search fails.
  int get firstPageVersion => _firstPageVersion;

  /// Text typed: searches once typing pauses for [debounce].
  void queryChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(search(text)));
  }

  /// Searches for [text] now.
  Future<void> search(String text) async {
    _debounce?.cancel();
    final query = text.trim();
    final request = ++_request;
    if (query.isEmpty) {
      clear();
      return;
    }
    _update(() {
      _query = query;
      _loading = keepsResultsWhileSearching ? _results.isEmpty : true;
      _failed = false;
    });
    try {
      final items = await _tmdb.search(query);
      if (_disposed || request != _request) return;
      _update(() {
        _results = items;
        _page = 1;
        _hasMore = items.isNotEmpty;
        _loading = false;
        _firstPageVersion++;
      });
    } catch (_) {
      if (_disposed || request != _request) return;
      _update(() {
        if (clearsResultsOnError) _results = const [];
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Back to an empty search; anything still loading is ignored.
  void clear() {
    _debounce?.cancel();
    _request++;
    _update(() {
      _query = '';
      _results = const [];
      _loading = false;
      _loadingMore = false;
      _hasMore = false;
      _failed = false;
      _firstPageVersion++;
    });
  }

  /// The next page of the current query, each title once.
  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore || _page >= maxPages || _query.isEmpty) {
      return;
    }
    final request = _request;
    _update(() => _loadingMore = true);
    try {
      final items = await _tmdb.search(_query, page: _page + 1);
      if (_disposed || request != _request) return;
      final seen = _results.map(MediaCatalogFilter.key).toSet();
      _update(() {
        _page++;
        _results = [
          ..._results,
          for (final item in items)
            if (seen.add(MediaCatalogFilter.key(item))) item,
        ];
        _hasMore = items.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (_disposed || request != _request) return;
      _update(() => _loadingMore = false);
    }
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
