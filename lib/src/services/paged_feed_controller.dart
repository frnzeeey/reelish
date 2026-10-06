import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'media_catalog_rules.dart';

/// One page of a home row, already filtered and ranked by the row's rules.
@immutable
class CatalogPage {
  const CatalogPage({
    required this.items,
    required this.page,
    required this.totalPages,
    this.sourceTotalPages = const [],
    this.fromCache = false,
  });

  final List<MediaItem> items;
  final int page;

  /// The last page TMDB reports for this list.
  final int totalPages;

  /// For a row merged from several TMDB lists, each list's `total_pages`
  /// in list order, so a later page can skip lists that have ended.
  final List<int> sourceTotalPages;

  /// Served from the TMDB response cache rather than the network.
  final bool fromCache;

  bool get hasMore => page < totalPages;
}

typedef CatalogPageFetcher =
    Future<CatalogPage> Function(
      int page, {
      CatalogPage? previous,
      required bool forceRefresh,
      void Function(CatalogPage)? onRevalidated,
    });

/// Where a row is in its first load.
enum PagedFeedStatus {
  /// Not requested yet.
  idle,

  /// The first load is running and nothing is shown yet.
  loading,

  /// Loaded at least once. Items may still be empty when every title was
  /// filtered out.
  ready,

  /// The first load failed and nothing is shown.
  failed,
}

@immutable
class PagedFeedState {
  const PagedFeedState({
    this.items = const [],
    this.currentPage = 0,
    this.hasMore = true,
    this.isInitialLoading = false,
    this.isLoadingMore = false,
    this.isRefreshing = false,
    this.error,
    this.lastLoadedAt,
    this.firstPageVersion = 0,
  });

  final List<MediaItem> items;

  /// The last TMDB page loaded; 0 before the first load.
  final int currentPage;
  final bool hasMore;
  final bool isInitialLoading;
  final bool isLoadingMore;

  /// Page 1 is being fetched again while the current items stay visible.
  final bool isRefreshing;

  /// The last failure. Items already loaded stay; while it is set the row
  /// does not ask for more pages on its own.
  final Object? error;

  /// When page 1 was last loaded.
  final DateTime? lastLoadedAt;

  /// Changes whenever page 1 is replaced (first load, refresh or
  /// revalidation), never when a later page is appended.
  final int firstPageVersion;

  PagedFeedStatus get status {
    if (currentPage > 0) return PagedFeedStatus.ready;
    if (isInitialLoading) return PagedFeedStatus.loading;
    if (error != null) return PagedFeedStatus.failed;
    return PagedFeedStatus.idle;
  }

  static const _keep = Object();

  PagedFeedState copyWith({
    List<MediaItem>? items,
    int? currentPage,
    bool? hasMore,
    bool? isInitialLoading,
    bool? isLoadingMore,
    bool? isRefreshing,
    Object? error = _keep,
    DateTime? lastLoadedAt,
    int? firstPageVersion,
  }) => PagedFeedState(
    items: items ?? this.items,
    currentPage: currentPage ?? this.currentPage,
    hasMore: hasMore ?? this.hasMore,
    isInitialLoading: isInitialLoading ?? this.isInitialLoading,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    error: identical(error, _keep) ? this.error : error,
    lastLoadedAt: lastLoadedAt ?? this.lastLoadedAt,
    firstPageVersion: firstPageVersion ?? this.firstPageVersion,
  );
}

/// The pages of one home row: what is loaded, whether more exist, and the
/// guards that keep requests for it from piling up.
///
/// Each row owns one controller, so loading, failing or paging one row
/// never touches another. Every operation runs under a generation number;
/// a refresh starts a new generation, and a response from an older one is
/// dropped, so a slow page 2 cannot land on a refreshed page 1.
///
/// With [targetCount] the row is a fixed-size list (Top 10): pages are
/// fetched only until [select] yields that many titles, then it stops.
class PagedFeedController extends ChangeNotifier {
  PagedFeedController({
    required this.label,
    required this.fetch,
    this.targetCount,
    this.select,
    this.maxExtraPages = 2,
    this.maxItems = 300,
    this.staleAfter = const Duration(minutes: 20),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Name used in debug logs, such as `NewMovies`.
  final String label;

  /// Loads one page of the row.
  final CatalogPageFetcher fetch;

  /// Fixed row size; null for a row that pages while it is scrolled.
  final int? targetCount;

  /// Chooses the shown titles from every unique title fetched so far, for
  /// rows ranked as a whole. Null shows them in the order they arrived.
  final List<MediaItem> Function(List<MediaItem> candidates)? select;

  /// How many further pages one load may fetch when a page adds nothing
  /// usable (or, with [targetCount], too little). Bounds filtered rows so
  /// they cannot loop through TMDB.
  final int maxExtraPages;

  /// The row stops paging at this many titles.
  final int maxItems;

  /// After this, [revalidateIfStale] fetches page 1 again.
  final Duration staleAfter;

  final DateTime Function() _clock;

  PagedFeedState _state = const PagedFeedState();
  PagedFeedState get state => _state;

  /// Every unique title fetched, in arrival order.
  List<MediaItem> _candidates = const [];
  List<MediaItem> _firstPageItems = const [];

  /// The titles page 1 added. Unlike [PagedFeedState.items] it does not
  /// grow as the row is scrolled, so views built from it stay put.
  List<MediaItem> get firstPageItems => _firstPageItems;

  CatalogPage? _lastPage;
  int _generation = 0;
  Future<void>? _pending;
  CatalogPage? _earlyRevalidation;
  bool _lastFailureWasRefresh = false;
  bool _disposed = false;

  bool get _busy =>
      _state.isInitialLoading || _state.isLoadingMore || _state.isRefreshing;

  bool get isStale {
    final loadedAt = _state.lastLoadedAt;
    return loadedAt != null && _clock().difference(loadedAt) >= staleAfter;
  }

  /// Starts the first load unless the row has loaded, is loading, or failed
  /// (a failed row waits for [retry]). Safe to call on every frame.
  Future<void> ensureLoaded() {
    if (_disposed || _busy || _state.status != PagedFeedStatus.idle) {
      return _pending ?? Future<void>.value();
    }
    return _run(_loadFirst(forceRefresh: false, quiet: false));
  }

  /// Appends the next page. Does nothing while any load runs, after the
  /// last page, or after a failure until [retry].
  Future<void> loadMore() {
    if (_disposed ||
        _busy ||
        !_state.hasMore ||
        _state.currentPage == 0 ||
        _state.error != null) {
      return _pending ?? Future<void>.value();
    }
    return _run(_loadNext());
  }

  /// Repeats whatever failed last: the first load, a refresh or a page.
  Future<void> retry() {
    if (_disposed || _busy) return _pending ?? Future<void>.value();
    if (_state.currentPage == 0) {
      return _run(_loadFirst(forceRefresh: false, quiet: false));
    }
    if (_state.error == null) return Future<void>.value();
    if (_lastFailureWasRefresh) return refresh();
    _set(_state.copyWith(error: null));
    return loadMore();
  }

  /// Fetches page 1 from TMDB again and replaces the row with it. Pages
  /// loaded before are dropped only once the new page 1 arrives; if it
  /// fails, they stay.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    return _run(_loadFirst(forceRefresh: true, quiet: false));
  }

  /// Quietly refreshes page 1 once it is older than [staleAfter], keeping
  /// what is shown meanwhile and on failure. A row already scrolled past
  /// page 1 is left alone so it does not jump back; pull-to-refresh still
  /// renews it.
  void revalidateIfStale() {
    if (_disposed || _busy || !isStale) return;
    if (targetCount == null && _state.currentPage != 1) return;
    _log('Revalidating stale page 1');
    unawaited(_run(_loadFirst(forceRefresh: true, quiet: true)));
  }

  Future<void> _run(Future<void> operation) {
    _pending = operation;
    return operation.whenComplete(() {
      if (identical(_pending, operation)) _pending = null;
    });
  }

  Future<void> _loadFirst({
    required bool forceRefresh,
    required bool quiet,
  }) async {
    final generation = ++_generation;
    _earlyRevalidation = null;
    final hasItems = _state.items.isNotEmpty;
    _set(
      _state.copyWith(
        isInitialLoading: !hasItems,
        isRefreshing: hasItems,
        isLoadingMore: false,
        error: quiet ? _state.error : null,
      ),
    );
    try {
      final batch = await _collect(
        generation,
        startPage: 1,
        previous: null,
        existing: const [],
        forceRefresh: forceRefresh,
      );
      if (batch == null) return;
      _replaceWith(batch);
      final early = _earlyRevalidation;
      _earlyRevalidation = null;
      if (early != null) _onFirstPageRevalidated(generation, early);
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _lastFailureWasRefresh = hasItems;
      _log('Page 1 failed');
      _set(
        _state.copyWith(
          isInitialLoading: false,
          isRefreshing: false,
          error: quiet ? _state.error : error,
        ),
      );
    }
  }

  Future<void> _loadNext() async {
    final generation = _generation;
    _set(_state.copyWith(isLoadingMore: true, error: null));
    try {
      final batch = await _collect(
        generation,
        startPage: _state.currentPage + 1,
        previous: _lastPage,
        existing: _candidates,
        forceRefresh: false,
      );
      if (batch == null) return;
      _candidates = List.unmodifiable([..._candidates, ...batch.added]);
      _lastPage = batch.last;
      final hasMore = _hasMoreAfter(batch);
      _set(
        _state.copyWith(
          items: _visible(_candidates),
          currentPage: batch.last.page,
          hasMore: hasMore,
          isLoadingMore: false,
        ),
      );
      _log('Loaded ${batch.added.length} unique items');
      if (!hasMore) _log('Pagination exhausted');
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _lastFailureWasRefresh = false;
      _log('Page ${_state.currentPage + 1} failed');
      _set(_state.copyWith(isLoadingMore: false, error: error));
    }
  }

  void _replaceWith(_Batch batch) {
    _candidates = List.unmodifiable(batch.added);
    _firstPageItems = List.unmodifiable(batch.firstPage);
    _lastPage = batch.last;
    final hasMore = _hasMoreAfter(batch);
    final items = _visible(_candidates);
    _set(
      PagedFeedState(
        items: items,
        currentPage: batch.last.page,
        hasMore: hasMore,
        lastLoadedAt: _clock(),
        firstPageVersion: _state.firstPageVersion + 1,
      ),
    );
    _log('Loaded ${items.length} unique items');
    if (targetCount != null) {
      _log('Stopped with ${items.length} of $targetCount titles');
    } else if (!hasMore) {
      _log('Pagination exhausted');
    }
  }

  /// A stale cached page 1 was shown and TMDB has now answered with a fresh
  /// one. It replaces the row only while the row still shows page 1 alone.
  void _onFirstPageRevalidated(int generation, CatalogPage fresh) {
    if (_disposed || generation != _generation) return;
    if (_state.currentPage == 0) {
      // The first load has not applied its own result yet.
      _earlyRevalidation = fresh;
      return;
    }
    if (_busy || (targetCount == null && _state.currentPage != 1)) return;
    _log('Revalidated page 1');
    final unique = MediaCatalogFilter.dedupe(fresh.items);
    _replaceWith(
      _Batch(added: unique, firstPage: unique, last: fresh, satisfied: true),
    );
  }

  /// Fetches from [startPage] until a page adds something usable, the list
  /// ends, or [maxExtraPages] further pages have been tried. Returns null
  /// when the result belongs to an older generation or the controller was
  /// disposed.
  Future<_Batch?> _collect(
    int generation, {
    required int startPage,
    required CatalogPage? previous,
    required List<MediaItem> existing,
    required bool forceRefresh,
  }) async {
    final seen = {for (final item in existing) MediaCatalogFilter.key(item)};
    final added = <MediaItem>[];
    List<MediaItem> firstPage = const [];
    var last = previous;
    for (var page = startPage, extra = 0; ; page++, extra++) {
      _log('Loading page $page');
      final CatalogPage result;
      try {
        result = await fetch(
          page,
          previous: last,
          forceRefresh: forceRefresh,
          onRevalidated: page == 1
              ? (fresh) => _onFirstPageRevalidated(generation, fresh)
              : null,
        );
      } catch (_) {
        if (_disposed || generation != _generation) return null;
        // Keep what earlier pages of this load found.
        if (added.isEmpty || last == null) rethrow;
        return _Batch(
          added: added,
          firstPage: firstPage,
          last: last,
          satisfied: true,
        );
      }
      if (_disposed || generation != _generation) {
        _log('Dropped page $page from an earlier load');
        return null;
      }
      if (result.fromCache) _log('Cache hit page $page');
      last = result;
      final fresh = [
        for (final item in result.items)
          if (seen.add(MediaCatalogFilter.key(item))) item,
      ];
      if (page == 1) firstPage = fresh;
      added.addAll(fresh);
      final target = targetCount;
      final satisfied = target == null
          ? fresh.isNotEmpty
          : _visible([...existing, ...added]).length >= target;
      if (satisfied ||
          !result.hasMore ||
          extra >= maxExtraPages ||
          existing.length + added.length >= maxItems) {
        return _Batch(
          added: added,
          firstPage: firstPage,
          last: result,
          satisfied: satisfied,
        );
      }
      _log(
        target == null
            ? 'Page $page added nothing new; trying page ${page + 1}'
            : 'Fewer than $target valid titles; fetching page ${page + 1}',
      );
    }
  }

  /// A fixed-size row never pages on scroll. Any other row continues while
  /// TMDB has pages, unless its last load came up empty after the bounded
  /// extra pages, or it reached [maxItems].
  bool _hasMoreAfter(_Batch batch) =>
      targetCount == null &&
      batch.satisfied &&
      batch.last.hasMore &&
      _candidates.length < maxItems;

  List<MediaItem> _visible(List<MediaItem> candidates) {
    final select = this.select;
    final target = targetCount;
    final chosen = select == null ? candidates : select(candidates);
    return List.unmodifiable(target == null ? chosen : chosen.take(target));
  }

  void _set(PagedFeedState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[HomeFeed][$label] $message');
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

class _Batch {
  const _Batch({
    required this.added,
    required this.firstPage,
    required this.last,
    required this.satisfied,
  });

  final List<MediaItem> added;
  final List<MediaItem> firstPage;
  final CatalogPage last;

  /// The load found what it needed: new titles, or enough for the target.
  final bool satisfied;
}
