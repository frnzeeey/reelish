import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import 'playback_source_policy.dart';

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
    final items = <MediaItem>[];
    for (final value in raw) {
      // One corrupt entry must not make the whole list (and the Library
      // screen, and every progress save) fail; skip it instead.
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          items.add(MediaItem.fromStorage(Map<String, dynamic>.from(decoded)));
        }
      } catch (_) {}
    }
    return items;
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

  static const _subtitlePreferencesKey = 'onfeed.player.subtitleChoice.v1';

  /// The viewer's last subtitle choice for a title (a movie or a whole
  /// series), as Nuvio remembers it per show: Off, or a language with its
  /// source. Null when nothing is remembered or the entry is unreadable.
  Future<RememberedSubtitle?> rememberedSubtitle(String titleKey) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _subtitlePreferencesKey,
    );
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? RememberedSubtitle.fromJson(decoded[titleKey])
          : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> rememberSubtitle(
    String titleKey,
    RememberedSubtitle choice,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    var values = <String, dynamic>{};
    try {
      final decoded = jsonDecode(
        preferences.getString(_subtitlePreferencesKey) ?? '{}',
      );
      if (decoded is Map) values = Map<String, dynamic>.from(decoded);
    } on FormatException {
      // Start over from an unreadable value.
    }
    values
      ..remove(titleKey)
      ..[titleKey] = choice.toJson();
    while (values.length > 200) {
      values.remove(values.keys.first);
    }
    await preferences.setString(_subtitlePreferencesKey, jsonEncode(values));
  }

  Future<String?> readSetting(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  Future<void> saveSetting(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);

  static const _lastStreamsKey = 'onfeed.playback.lastStreams.v1';

  Future<StreamSource?> lastStream(
    MediaItem item, {
    required Duration maxAge,
    required bool allowTorrents,
    Set<String>? allowedProviderIds,
    String? cacheKey,
  }) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _lastStreamsKey,
    );
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final key = cacheKey ?? _mediaKey(item);
      final entry = value[key];
      if (entry is! Map) return null;
      final savedAt = DateTime.tryParse('${entry['savedAt'] ?? ''}');
      if (savedAt == null || DateTime.now().difference(savedAt) > maxAge) {
        return null;
      }
      final sourceJson = entry['source'];
      if (sourceJson is! Map) return null;
      final source = StreamSource.fromJson(
        Map<String, dynamic>.from(sourceJson),
        providerName: '${sourceJson['providerName'] ?? ''}',
      );
      if (!source.isPlayable ||
          !isPlaybackSourceAllowed(
            source,
            allowedProviderIds: allowedProviderIds,
            allowTorrents: allowTorrents,
          )) {
        return null;
      }
      return source;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLastStream(
    MediaItem item,
    StreamSource source, {
    String? cacheKey,
  }) async {
    if (!source.isPlayable) return;
    final preferences = await SharedPreferences.getInstance();
    Map<String, dynamic> values = {};
    final raw = preferences.getString(_lastStreamsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) values = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    values[cacheKey ?? _mediaKey(item)] = {
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'source': source.toJson(),
    };
    if (values.length > 100) {
      values.remove(values.keys.first);
    }
    await preferences.setString(_lastStreamsKey, jsonEncode(values));
  }

  String _mediaKey(MediaItem item) => '${item.type}:${item.id}';

  Future<Directory> torrentCacheDirectory({bool create = true}) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory('${documents.path}/torrent_cache');
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> clearTorrentCache() async {
    final directory = await torrentCacheDirectory(create: false);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// A remembered subtitle choice for one title.
class RememberedSubtitle {
  const RememberedSubtitle.off()
    : off = true,
      language = '',
      source = SubtitleSource.provider,
      addonName = '',
      hearingImpaired = false;

  RememberedSubtitle.of(SubtitleTrack track)
    : off = false,
      language = track.lang,
      source = track.source,
      addonName = track.addonName,
      hearingImpaired = track.hearingImpaired;

  const RememberedSubtitle._(
    this.off,
    this.language,
    this.source,
    this.addonName,
    this.hearingImpaired,
  );

  final bool off;
  final String language;
  final SubtitleSource source;
  final String addonName;
  final bool hearingImpaired;

  Map<String, Object?> toJson() => {
    'off': off,
    'language': language,
    'source': source.name,
    'addonName': addonName,
    'hearingImpaired': hearingImpaired,
  };

  static RememberedSubtitle? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['off'] == true) return const RememberedSubtitle.off();
    final language = json['language'];
    if (language is! String || language.isEmpty) return null;
    return RememberedSubtitle._(
      false,
      language,
      SubtitleSource.values.asNameMap()[json['source']] ??
          SubtitleSource.provider,
      '${json['addonName'] ?? ''}',
      json['hearingImpaired'] == true,
    );
  }
}
