import 'package:flutter/foundation.dart';

import '../models/episode_progress.dart';
import '../models/media_item.dart';
import '../models/resume_summary.dart';
import '../services/storage_service.dart';

/// The viewer's library for the mobile, TV and Windows library pages: watch
/// history, My list, and where each series in the history was left.
class LibraryViewModel extends ChangeNotifier {
  LibraryViewModel({required this._storage});

  final StorageService _storage;

  List<MediaItem> _history = const [];
  List<MediaItem> _favorites = const [];
  Map<String, SeriesProgress> _seriesProgress = const {};
  bool _loading = true;
  bool _disposed = false;

  List<MediaItem> get history => _history;
  List<MediaItem> get favorites => _favorites;
  bool get loading => _loading;

  /// Per-episode progress of the series in the history, by `type:id`.
  Map<String, SeriesProgress> get seriesProgress => _seriesProgress;

  /// Where [item] was left: for a series, the episode watched last.
  ResumeSummary resumeSummary(MediaItem item) => ResumeSummary.of(
    item,
    series: _seriesProgress['${item.type}:${item.id}'],
  );

  /// Reads history and My list again.
  Future<void> load() async {
    final values = await Future.wait([
      _storage.history(),
      _storage.favorites(),
    ]);
    // Series cards follow the episode watched last.
    final progress = <String, SeriesProgress>{};
    for (final item in values[0]) {
      if (item.type != 'series' || item.resumeMs <= 0) continue;
      try {
        progress['${item.type}:${item.id}'] = await _storage.seriesProgress(
          item,
        );
      } catch (_) {}
    }
    if (_disposed) return;
    _history = values[0];
    _favorites = values[1];
    _seriesProgress = progress;
    _loading = false;
    notifyListeners();
  }

  Future<void> removeFromHistory(MediaItem item) async {
    await _storage.removeHistory(item);
    await load();
  }

  Future<void> toggleFavorite(MediaItem item) async {
    await _storage.toggleFavorite(item);
    await load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
