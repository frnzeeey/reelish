import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/viewmodels/library_view_model.dart';
import 'package:onfeed/src/viewmodels/search_view_model.dart';

MediaItem _item(String id, {String type = 'movie', int resumeMs = 0}) =>
    MediaItem(id: id, type: type, name: id, resumeMs: resumeMs);

class _FakeTmdb extends TmdbService {
  final calls = <String>[];
  final gates = <String, Completer<List<MediaItem>>>{};
  final pages = <String, List<MediaItem>>{};
  final failing = <String>{};

  @override
  Future<List<MediaItem>> search(
    String query, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    int page = 1,
  }) {
    final key = '$query#$page';
    calls.add(key);
    if (failing.contains(key)) return Future.error(Exception('offline'));
    final gate = gates[key];
    if (gate != null) return gate.future;
    return Future.value(pages[key] ?? [_item('$query-$page')]);
  }
}

class _FakeStorage extends StorageService {
  final history_ = <MediaItem>[];
  final favorites_ = <MediaItem>[];
  final removed = <String>[];
  final toggled = <String>[];

  @override
  Future<List<MediaItem>> history() async => [...history_];

  @override
  Future<List<MediaItem>> favorites() async => [...favorites_];

  @override
  Future<SeriesProgress> seriesProgress(MediaItem series) async =>
      series.id == 'broken' ? throw Exception('corrupt') : SeriesProgress.empty;

  @override
  Future<void> removeHistory(MediaItem item) async {
    removed.add(item.id);
    history_.removeWhere((i) => i.id == item.id);
  }

  @override
  Future<void> toggleFavorite(MediaItem item) async {
    toggled.add(item.id);
    favorites_.add(item);
  }
}

void main() {
  group('SearchViewModel', () {
    test('debounces typing and searches the trimmed text', () async {
      final tmdb = _FakeTmdb();
      final model = SearchViewModel(
        tmdb: tmdb,
        debounce: const Duration(milliseconds: 60),
      );
      model.queryChanged('du');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      model.queryChanged(' dune ');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(tmdb.calls, isEmpty, reason: 'typing restarted the wait');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(tmdb.calls, ['dune#1']);
      expect(model.query, 'dune');
      expect(model.results.single.id, 'dune-1');
      model.dispose();
    });

    test('a stale answer never replaces a newer query', () async {
      final tmdb = _FakeTmdb()..gates['old#1'] = Completer();
      final model = SearchViewModel(tmdb: tmdb);
      final old = model.search('old');
      await model.search('new');
      tmdb.gates['old#1']!.complete([_item('old-1')]);
      await old;
      expect(model.results.single.id, 'new-1');
      model.dispose();
    });

    test('pages in order, each title once, never past maxPages', () async {
      final tmdb = _FakeTmdb()
        ..pages['q#1'] = [_item('a'), _item('b')]
        ..pages['q#2'] = [_item('b'), _item('c')]
        ..pages['q#3'] = [_item('d')];
      final model = SearchViewModel(tmdb: tmdb, maxPages: 2);
      await model.search('q');
      await model.loadMore();
      await model.loadMore(); // page 3 is past maxPages
      expect(model.results.map((i) => i.id), ['a', 'b', 'c']);
      expect(tmdb.calls, ['q#1', 'q#2']);
      model.dispose();
    });

    test('loading keeps or hides the old results, per page', () async {
      for (final keeps in [true, false]) {
        final tmdb = _FakeTmdb()..gates['second#1'] = Completer();
        final model = SearchViewModel(
          tmdb: tmdb,
          keepsResultsWhileSearching: keeps,
        );
        await model.search('first');
        unawaited(model.search('second'));
        expect(model.loading, !keeps, reason: 'keeps: $keeps');
        tmdb.gates['second#1']!.complete(const []);
        model.dispose();
      }
    });

    test('a failure clears or keeps the results, per page', () async {
      for (final clears in [true, false]) {
        final tmdb = _FakeTmdb()..failing.add('bad#1');
        final model = SearchViewModel(tmdb: tmdb, clearsResultsOnError: clears);
        await model.search('good');
        final version = model.firstPageVersion;
        await model.search('bad');
        expect(model.failed, isTrue);
        expect(model.results, clears ? isEmpty : hasLength(1));
        // A failure does not count as new results (TV keeps its preview).
        expect(model.firstPageVersion, version);
        model.dispose();
      }
    });

    test(
      'clearing during a load-more lets the next query page again',
      () async {
        // Fixes the Windows page, which could stay "loading more" forever.
        final tmdb = _FakeTmdb()..gates['a#2'] = Completer();
        final model = SearchViewModel(tmdb: tmdb);
        await model.search('a');
        final more = model.loadMore();
        expect(model.loadingMore, isTrue);
        model.clear();
        expect(model.loadingMore, isFalse);
        tmdb.gates['a#2']!.complete([_item('late')]);
        await more;
        await model.search('b');
        await model.loadMore();
        expect(tmdb.calls, ['a#1', 'a#2', 'b#1', 'b#2']);
        expect(model.results.map((i) => i.id), ['b-1', 'b-2']);
        model.dispose();
      },
    );

    test('empty text clears; answers after dispose are ignored', () async {
      final tmdb = _FakeTmdb()..gates['x#1'] = Completer();
      final model = SearchViewModel(tmdb: tmdb);
      await model.search('y');
      await model.search('   ');
      expect(model.results, isEmpty);
      expect(model.query, '');
      unawaited(model.search('x'));
      model.dispose();
      tmdb.gates['x#1']!.complete([_item('x')]);
      await Future<void>.delayed(Duration.zero);
      expect(model.results, isEmpty);
    });
  });

  group('LibraryViewModel', () {
    test('loads history, My list and where each series was left', () async {
      final storage = _FakeStorage()
        ..history_.addAll([
          _item('film', resumeMs: 10),
          _item('show', type: 'series', resumeMs: 10),
          _item('broken', type: 'series', resumeMs: 10),
          _item('unstarted', type: 'series'),
        ])
        ..favorites_.add(_item('saved'));
      final model = LibraryViewModel(storage: storage);
      expect(model.loading, isTrue);
      await model.load();
      expect(model.loading, isFalse);
      expect(model.history, hasLength(4));
      expect(model.favorites.single.id, 'saved');
      // Only started series are looked up; a broken one is skipped.
      expect(model.seriesProgress.keys, ['series:show']);
      model.dispose();
    });

    test('removing and saving update the library', () async {
      final storage = _FakeStorage()..history_.add(_item('film'));
      final model = LibraryViewModel(storage: storage);
      await model.load();
      await model.removeFromHistory(model.history.single);
      await model.toggleFavorite(_item('new'));
      expect(storage.removed, ['film']);
      expect(model.history, isEmpty);
      expect(model.favorites.single.id, 'new');
      model.dispose();
    });
  });
}
