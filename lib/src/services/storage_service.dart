import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_item.dart';

class StorageService {
  static const _nuvioPlugins = 'onfeed.nuvio.plugin.repositories',
      _history = 'onfeed.history',
      _favorites = 'onfeed.favorites';
  Future<List<String>> nuvioPluginRepositoryUrls() async =>
      (await SharedPreferences.getInstance()).getStringList(_nuvioPlugins) ??
      [];
  Future<void> saveNuvioPluginRepositoryUrls(List<String> urls) async =>
      (await SharedPreferences.getInstance()).setStringList(
        _nuvioPlugins,
        urls,
      );
  Future<Map<String, bool>> nuvioPluginEnabledOverrides() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'onfeed.nuvio.plugin.enabled',
    );
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map(
        (key, value) => MapEntry('$key', value == true),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> saveNuvioPluginEnabledOverrides(
    Map<String, bool> values,
  ) async => (await SharedPreferences.getInstance()).setString(
    'onfeed.nuvio.plugin.enabled',
    jsonEncode(values),
  );
  Future<List<MediaItem>> _items(String key) async {
    final raw =
        (await SharedPreferences.getInstance()).getStringList(key) ?? [];
    return raw
        .map(
          (v) =>
              MediaItem.fromStorage(Map<String, dynamic>.from(jsonDecode(v))),
        )
        .toList();
  }

  Future<List<MediaItem>> history() => _items(_history);
  Future<List<MediaItem>> favorites() => _items(_favorites);
  Future<void> _saveItems(String key, List<MediaItem> items) async =>
      (await SharedPreferences.getInstance()).setStringList(
        key,
        items.map((e) => jsonEncode(e.toJson())).toList(),
      );
  Future<void> saveProgress(MediaItem item, int positionMs) async {
    final all = await history();
    all.removeWhere((e) => e.id == item.id && e.type == item.type);
    all.insert(0, item.copyWith(resumeMs: positionMs));
    await _saveItems(_history, all.take(50).toList());
  }

  Future<void> toggleFavorite(MediaItem item) async {
    final all = await favorites();
    if (all.any((e) => e.id == item.id && e.type == item.type)) {
      all.removeWhere((e) => e.id == item.id && e.type == item.type);
    } else {
      all.insert(0, item);
    }
    await _saveItems(_favorites, all);
  }

  Future<void> removeHistory(MediaItem item) async {
    final all = await history()
      ..removeWhere((e) => e.id == item.id && e.type == item.type);
    await _saveItems(_history, all);
  }

  Future<bool> isFavorite(MediaItem item) async =>
      (await favorites()).any((e) => e.id == item.id && e.type == item.type);
}
