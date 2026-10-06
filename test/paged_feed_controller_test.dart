import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/paged_feed_controller.dart';

MediaItem _movie(int id) =>
    MediaItem(id: '$id', type: 'movie', name: 'Movie $id');

MediaItem _series(int id) =>
    MediaItem(id: '$id', type: 'series', name: 'Series $id');

/// A scripted fetcher: page N answers with [pages][N], or throws when that
/// entry is an error. Records every call, and can hold a page open.
class _FakeSource {
  _FakeSource(this.pages, {this.totalPages});

  final Map<int, Object> pages;
  final int? totalPages;
  final calls = <({int page, bool forceRefresh})>[];
  final held = <int, Completer<void>>{};
  final revalidations = <int, void Function(CatalogPage)>{};

  int callsFor(int page) => calls.where((call) => call.page == page).length;

  /// The next request for [page] waits until [release] is called.
  void hold(int page) => held[page] = Completer<void>();

  void release(int page) => held.remove(page)?.complete();

  Future<CatalogPage> fetch(
    int page, {
    CatalogPage? previous,
    required bool forceRefresh,
    void Function(CatalogPage)? onRevalidated,
  }) async {
    calls.add((page: page, forceRefresh: forceRefresh));
    if (onRevalidated != null) revalidations[page] = onRevalidated;
    final gate = held[page];
    if (gate != null) await gate.future;
    final entry = pages[page];
    if (entry is! List<MediaItem>) throw entry ?? StateError('no page $page');
    return CatalogPage(
      items: entry,
      page: page,
      totalPages: totalPages ?? pages.length,
    );
  }
}

List<String> _names(PagedFeedController feed) =>
    feed.state.items.map((item) => item.name).toList();

void main() {
  test('loads page 1 on first use and only once', () async {
    final source = _FakeSource({
      1: [_movie(1), _movie(2)],
      2: [_movie(3)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);

    expect(feed.state.status, PagedFeedStatus.idle);
    final first = feed.ensureLoaded();
    expect(feed.state.status, PagedFeedStatus.loading);
    expect(feed.state.isInitialLoading, isTrue);
    await Future.wait([first, feed.ensureLoaded(), feed.ensureLoaded()]);
    await feed.ensureLoaded();

    expect(source.callsFor(1), 1);
    expect(_names(feed), ['Movie 1', 'Movie 2']);
    expect(feed.state.currentPage, 1);
    expect(feed.state.hasMore, isTrue);
    expect(feed.state.lastLoadedAt, isNotNull);
    expect(feed.firstPageItems, hasLength(2));
  });

  test('appends page 2 after page 1, keeping order', () async {
    final source = _FakeSource({
      1: [_movie(1), _movie(2)],
      2: [_movie(3), _movie(4)],
      3: [_movie(5)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();
    final version = feed.state.firstPageVersion;

    await feed.loadMore();

    expect(_names(feed), ['Movie 1', 'Movie 2', 'Movie 3', 'Movie 4']);
    expect(feed.state.currentPage, 2);
    // Appending is not a page 1 change, so Home is not rebuilt for it.
    expect(feed.state.firstPageVersion, version);
    expect(feed.firstPageItems, hasLength(2));
  });

  test('paging one row never fetches or notifies another', () async {
    final movies = _FakeSource({
      1: [_movie(1)],
      2: [_movie(2)],
    });
    final series = _FakeSource({
      1: [_series(1)],
      2: [_series(2)],
    });
    final movieFeed = PagedFeedController(label: 'M', fetch: movies.fetch);
    final seriesFeed = PagedFeedController(label: 'S', fetch: series.fetch);
    addTearDown(movieFeed.dispose);
    addTearDown(seriesFeed.dispose);
    await Future.wait([movieFeed.ensureLoaded(), seriesFeed.ensureLoaded()]);
    var seriesNotifications = 0;
    seriesFeed.addListener(() => seriesNotifications++);

    await movieFeed.loadMore();

    expect(movieFeed.state.currentPage, 2);
    expect(seriesFeed.state.currentPage, 1);
    expect(series.calls, hasLength(1));
    expect(seriesNotifications, 0);
  });

  test('rapid loadMore calls send one request per page', () async {
    final source = _FakeSource({
      1: [_movie(1)],
      2: [_movie(2)],
      3: [_movie(3)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();
    source.hold(2);

    final calls = [for (var i = 0; i < 6; i++) feed.loadMore()];
    expect(feed.state.isLoadingMore, isTrue);
    source.release(2);
    await Future.wait(calls);

    expect(source.callsFor(2), 1);
    expect(source.callsFor(3), 0);
    expect(_names(feed), ['Movie 1', 'Movie 2']);
  });

  test('dedupes by media type and TMDB id, not by title', () async {
    final source = _FakeSource({
      1: [_movie(1), _movie(2), _movie(1)],
      // Movie 2 repeats from page 1; series 2 shares the id but is
      // another title; a different movie reuses the name "Movie 1".
      2: [
        _movie(2),
        _series(2),
        const MediaItem(id: '9', type: 'movie', name: 'Movie 1'),
      ],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();
    await feed.loadMore();

    expect(feed.state.items.map((item) => '${item.type}:${item.id}').toList(), [
      'movie:1',
      'movie:2',
      'series:2',
      'movie:9',
    ]);
  });

  test('stops at the last page and never asks again', () async {
    final source = _FakeSource({
      1: [_movie(1)],
      2: [_movie(2)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();
    await feed.loadMore();
    expect(feed.state.hasMore, isFalse);

    await feed.loadMore();
    await feed.loadMore();

    expect(source.calls, hasLength(2));
  });

  test('a failed first load waits for retry, then loads', () async {
    final source = _FakeSource({1: Exception('TMDB request failed (503).')});
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);

    await feed.ensureLoaded();
    expect(feed.state.status, PagedFeedStatus.failed);
    expect(feed.state.error, isNotNull);

    // Being on screen again does not retry on its own.
    await feed.ensureLoaded();
    await feed.loadMore();
    expect(source.calls, hasLength(1));

    source.pages[1] = [_movie(1)];
    await feed.retry();
    expect(feed.state.status, PagedFeedStatus.ready);
    expect(feed.state.error, isNull);
    expect(_names(feed), ['Movie 1']);
  });

  test('a failed page 3 keeps pages 1 and 2 and can be retried', () async {
    final source = _FakeSource({
      1: [_movie(1)],
      2: [_movie(2)],
      3: Exception('offline'),
      4: [_movie(4)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();
    await feed.loadMore();

    await feed.loadMore();
    expect(_names(feed), ['Movie 1', 'Movie 2']);
    expect(feed.state.currentPage, 2);
    expect(feed.state.error, isNotNull);
    expect(feed.state.isLoadingMore, isFalse);

    // Scrolling at the end does not hammer the failing page.
    await feed.loadMore();
    expect(source.callsFor(3), 1);

    source.pages[3] = [_movie(3)];
    await feed.retry();
    expect(_names(feed), ['Movie 1', 'Movie 2', 'Movie 3']);
    expect(feed.state.error, isNull);
    expect(source.callsFor(3), 2);
  });

  test('refresh replaces later pages with a fresh page 1', () async {
    final source = _FakeSource({
      1: [_movie(1), _movie(2)],
      2: [_movie(3)],
      3: [_movie(4)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();
    await feed.loadMore();
    await feed.loadMore();
    final version = feed.state.firstPageVersion;

    source.pages[1] = [_movie(10), _movie(1)];
    final refreshing = feed.refresh();
    // The old titles stay up while the new page 1 loads.
    expect(feed.state.isRefreshing, isTrue);
    expect(feed.state.items, hasLength(4));
    await refreshing;

    expect(_names(feed), ['Movie 10', 'Movie 1']);
    expect(feed.state.currentPage, 1);
    expect(feed.state.hasMore, isTrue);
    expect(feed.state.firstPageVersion, version + 1);
    expect(source.calls.last, (page: 1, forceRefresh: true));

    // Paging starts over from page 2 of the refreshed list.
    await feed.loadMore();
    expect(source.calls.last.page, 2);
  });

  test('a failed refresh keeps the titles already shown', () async {
    final source = _FakeSource({
      1: [_movie(1)],
      2: [_movie(2)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();
    await feed.loadMore();

    source.pages[1] = Exception('offline');
    await feed.refresh();

    expect(_names(feed), ['Movie 1', 'Movie 2']);
    expect(feed.state.error, isNotNull);
    expect(feed.state.status, PagedFeedStatus.ready);

    source.pages[1] = [_movie(5)];
    await feed.retry();
    expect(_names(feed), ['Movie 5']);
  });

  test('a page 2 that lands after a refresh is dropped', () async {
    final source = _FakeSource({
      1: [_movie(1)],
      2: [_movie(2)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);
    await feed.ensureLoaded();

    source.hold(2);
    final stalePage = feed.loadMore();
    source.pages[1] = [_movie(7)];
    await feed.refresh();
    expect(_names(feed), ['Movie 7']);

    source.release(2);
    await stalePage;

    expect(_names(feed), ['Movie 7']);
    expect(feed.state.currentPage, 1);
    expect(feed.state.isLoadingMore, isFalse);
  });

  test('disposing during a request drops its result safely', () async {
    final source = _FakeSource({
      1: [_movie(1)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    source.hold(1);
    final loading = feed.ensureLoaded();
    var notifications = 0;
    feed.addListener(() => notifications++);

    feed.dispose();
    source.release(1);
    await loading;

    expect(notifications, 0);
  });

  test(
    'a filtered page with no titles tries a bounded number of pages',
    () async {
      final source = _FakeSource({
        1: [_movie(1)],
        for (var page = 2; page <= 20; page++) page: <MediaItem>[],
      }, totalPages: 20);
      final feed = PagedFeedController(
        label: 'Test',
        fetch: source.fetch,
        maxExtraPages: 2,
      );
      addTearDown(feed.dispose);
      await feed.ensureLoaded();

      await feed.loadMore();

      // Page 2 and at most two more, then the row stops for good.
      expect(source.calls.map((call) => call.page), [1, 2, 3, 4]);
      expect(feed.state.hasMore, isFalse);
      expect(_names(feed), ['Movie 1']);
      await feed.loadMore();
      expect(source.calls, hasLength(4));
    },
  );

  test('a first page filtered to nothing continues to the next page', () async {
    final source = _FakeSource({
      1: <MediaItem>[],
      2: [_movie(2)],
      3: [_movie(3)],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);

    await feed.ensureLoaded();

    expect(_names(feed), ['Movie 2']);
    expect(feed.state.currentPage, 2);
    expect(feed.state.hasMore, isTrue);
  });

  test('a row with no titles at all ends empty without looping', () async {
    final source = _FakeSource({
      for (var page = 1; page <= 50; page++) page: <MediaItem>[],
    });
    final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
    addTearDown(feed.dispose);

    await feed.ensureLoaded();

    expect(source.calls, hasLength(3));
    expect(feed.state.status, PagedFeedStatus.ready);
    expect(feed.state.items, isEmpty);
    expect(feed.state.hasMore, isFalse);
  });

  group('Top 10', () {
    PagedFeedController top10(_FakeSource source) => PagedFeedController(
      label: 'Top10',
      fetch: source.fetch,
      targetCount: 10,
      // Stand-in for the ranking filter: odd ids are not valid picks.
      select: (candidates) => [
        for (final item in candidates)
          if (int.parse(item.id).isEven) item,
      ],
    );

    test('fetches more pages only until 10 valid titles exist', () async {
      final source = _FakeSource({
        // 7 valid of 14.
        1: [for (var id = 1; id <= 14; id++) _movie(id)],
        // 10 more valid; together well past 10.
        2: [for (var id = 15; id <= 34; id++) _movie(id)],
        3: [for (var id = 35; id <= 54; id++) _movie(id)],
      }, totalPages: 50);
      final feed = top10(source);
      addTearDown(feed.dispose);

      await feed.ensureLoaded();

      expect(source.calls.map((call) => call.page), [1, 2]);
      expect(feed.state.items, hasLength(10));
      expect(
        feed.state.items.every((item) => int.parse(item.id).isEven),
        isTrue,
      );
      expect(feed.state.hasMore, isFalse);
      await feed.loadMore();
      expect(source.calls, hasLength(2));
    });

    test('stops after page 1 when it already has 10', () async {
      final source = _FakeSource({
        1: [for (var id = 1; id <= 20; id++) _movie(id)],
        2: [for (var id = 21; id <= 40; id++) _movie(id)],
      }, totalPages: 50);
      final feed = top10(source);
      addTearDown(feed.dispose);

      await feed.ensureLoaded();

      expect(source.calls, hasLength(1));
      expect(feed.state.items, hasLength(10));
    });

    test('a short list stops within the page bound', () async {
      final source = _FakeSource({
        for (var page = 1; page <= 50; page++)
          page: [_movie(page * 100), _movie(page * 100 + 1)],
      });
      final feed = top10(source);
      addTearDown(feed.dispose);

      await feed.ensureLoaded();

      expect(source.calls, hasLength(3));
      expect(feed.state.items, hasLength(3));
    });
  });

  group('stale-while-revalidate', () {
    test('a fresh page 1 replaces a cached one shown alone', () async {
      final source = _FakeSource({
        1: [_movie(1)],
        2: [_movie(2)],
      });
      final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
      addTearDown(feed.dispose);
      await feed.ensureLoaded();

      source.revalidations[1]!(
        CatalogPage(items: [_movie(8), _movie(1)], page: 1, totalPages: 2),
      );

      expect(_names(feed), ['Movie 8', 'Movie 1']);
    });

    test('is ignored once later pages were appended', () async {
      final source = _FakeSource({
        1: [_movie(1)],
        2: [_movie(2)],
      });
      final feed = PagedFeedController(label: 'Test', fetch: source.fetch);
      addTearDown(feed.dispose);
      await feed.ensureLoaded();
      await feed.loadMore();

      source.revalidations[1]!(
        CatalogPage(items: [_movie(8)], page: 1, totalPages: 2),
      );

      expect(_names(feed), ['Movie 1', 'Movie 2']);
    });

    test('revalidates page 1 only after it expires', () async {
      var now = DateTime(2026, 10, 6, 12);
      final source = _FakeSource({
        1: [_movie(1)],
        2: [_movie(2)],
      });
      final feed = PagedFeedController(
        label: 'Test',
        fetch: source.fetch,
        staleAfter: const Duration(minutes: 20),
        clock: () => now,
      );
      addTearDown(feed.dispose);
      await feed.ensureLoaded();

      now = now.add(const Duration(minutes: 19));
      feed.revalidateIfStale();
      expect(source.calls, hasLength(1));

      now = now.add(const Duration(minutes: 2));
      expect(feed.isStale, isTrue);
      source.pages[1] = [_movie(3)];
      feed.revalidateIfStale();
      // Quiet: the cached titles stay up meanwhile.
      expect(_names(feed), ['Movie 1']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(source.calls.last, (page: 1, forceRefresh: true));
      expect(_names(feed), ['Movie 3']);
      expect(feed.isStale, isFalse);
    });

    test(
      'a failed quiet revalidation keeps titles and shows no error',
      () async {
        var now = DateTime(2026, 10, 6, 12);
        final source = _FakeSource({
          1: [_movie(1)],
        });
        final feed = PagedFeedController(
          label: 'Test',
          fetch: source.fetch,
          clock: () => now,
        );
        addTearDown(feed.dispose);
        await feed.ensureLoaded();

        now = now.add(const Duration(hours: 1));
        source.pages[1] = Exception('offline');
        feed.revalidateIfStale();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(_names(feed), ['Movie 1']);
        expect(feed.state.error, isNull);
        expect(feed.state.isRefreshing, isFalse);
      },
    );
  });
}
