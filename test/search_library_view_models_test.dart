import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/viewmodels/library_view_model.dart';

MediaItem _item(String id, {String type = 'movie', int resumeMs = 0}) =>
    MediaItem(id: id, type: type, name: id, resumeMs: resumeMs);

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
