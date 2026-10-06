import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/episode_progress.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import 'playback_source_policy.dart';

class StorageService {
  StorageService({Future<Directory> Function()? filesDirectory})
    : _filesDirectory = filesDirectory ?? getApplicationSupportDirectory;

  /// App-private files outside Android backup (only SharedPreferences are
  /// backed up; see `android/app/src/main/res/xml/backup_rules.xml`).
  final Future<Directory> Function() _filesDirectory;

  /// Read-modify-write updates (history, favourites, progress, subtitle
  /// choices, stream links) run one at a time across every instance, so two
  /// saves landing together cannot each write back a list missing the
  /// other's change.
  static Future<void> _updates = Future.value();

  static Future<T> _serialized<T>(Future<T> Function() update) {
    final result = _updates.then((_) => update());
    _updates = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static const _providerRepositoriesKey = 'onfeed.nuvio.plugin.repositories',
      _history = 'onfeed.history',
      _favorites = 'onfeed.favorites';
  Future<List<String>> providerRepositoryUrls() async =>
      (await SharedPreferences.getInstance()).getStringList(
        _providerRepositoriesKey,
      ) ??
      [];
  Future<void> saveProviderRepositoryUrls(List<String> urls) async =>
      (await SharedPreferences.getInstance()).setStringList(
        _providerRepositoriesKey,
        urls,
      );
  Future<Map<String, bool>> providerEnabledOverrides() async {
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

  Future<void> saveProviderEnabledOverrides(Map<String, bool> values) async =>
      (await SharedPreferences.getInstance()).setString(
        'onfeed.nuvio.plugin.enabled',
        jsonEncode(values),
      );
  static const _providerScriptHashesKey = 'onfeed.plugin.scriptHashes.v1';

  /// SHA-256 of each provider script the viewer has allowed to run, by
  /// script URL.
  Future<Map<String, String>> providerScriptHashes() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _providerScriptHashesKey,
    );
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? {
              for (final MapEntry(:key, :value) in decoded.entries)
                if (value is String) '$key': value,
            }
          : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> saveProviderScriptHashes(Map<String, String> hashes) async =>
      (await SharedPreferences.getInstance()).setString(
        _providerScriptHashesKey,
        jsonEncode(hashes),
      );

  static const _providerManifestsFileName = 'provider_manifests.v1.json';

  /// Manifests larger than this are not kept; they are downloaded each time.
  static const maxCachedManifestBytes = 1024 * 1024;

  Future<File> _providerManifestsFile() async =>
      File('${(await _filesDirectory()).path}/$_providerManifestsFileName');

  Future<Map<String, dynamic>> _readProviderManifests() async {
    try {
      final file = await _providerManifestsFile();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  /// The last downloaded copy of the provider manifest at [url] with the
  /// validators its host sent, for a conditional request; null when none.
  Future<CachedManifest?> cachedProviderManifest(String url) async {
    final entry = (await _readProviderManifests())[url];
    if (entry is! Map || entry['body'] is! String) return null;
    final etag = entry['etag'], lastModified = entry['lastModified'];
    return CachedManifest(
      body: entry['body'] as String,
      etag: etag is String ? etag : null,
      lastModified: lastModified is String ? lastModified : null,
    );
  }

  /// Keeps [manifest] for [url], or forgets it when [manifest] is null. Kept
  /// in a private file outside backup, like other downloaded data.
  Future<void> saveProviderManifest(String url, CachedManifest? manifest) =>
      _serialized(() async {
        final values = await _readProviderManifests();
        values.remove(url);
        if (manifest != null &&
            manifest.body.length <= maxCachedManifestBytes) {
          values[url] = {
            'body': manifest.body,
            'etag': ?manifest.etag,
            'lastModified': ?manifest.lastModified,
          };
        }
        final file = await _providerManifestsFile();
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(jsonEncode(values), flush: true);
        await temporary.rename(file.path);
      });

  static const _providerKnownScriptsKey = 'onfeed.plugin.knownScripts.v1';

  /// Script URLs each repository listed when it was installed (or approved
  /// later), by repository URL. A script URL outside this set was added by a
  /// manifest update and needs the viewer's approval before it runs.
  Future<Map<String, Set<String>>> providerKnownScripts() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _providerKnownScriptsKey,
    );
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? {
              for (final MapEntry(:key, :value) in decoded.entries)
                if (value is List) '$key': value.whereType<String>().toSet(),
            }
          : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> saveProviderKnownScripts(Map<String, Set<String>> known) async =>
      (await SharedPreferences.getInstance()).setString(
        _providerKnownScriptsKey,
        jsonEncode({
          for (final MapEntry(:key, :value) in known.entries)
            key: value.toList(),
        }),
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

  /// Saves where [item] was left, with its length when known, as the
  /// title's watch-history entry (most recent first).
  Future<void> saveProgress(
    MediaItem item,
    int positionMs, {
    int durationMs = 0,
  }) => _serialized(() async {
    final all = await history();
    all.removeWhere((e) => e.id == item.id && e.type == item.type);
    all.insert(0, item.copyWith(resumeMs: positionMs, durationMs: durationMs));
    await _saveItems(_history, all.take(50).toList());
  });

  static const _episodeProgressKey = 'onfeed.history.episodes.v1';

  /// Series kept in the per-episode store; the oldest is dropped beyond it.
  static const _maxSeriesWithProgress = 100;

  /// Per-episode progress for [series]. The series' history entry keeps a
  /// single `resumeMs` for continue-watching rows; this keeps each episode's
  /// own position, so one episode never resumes at another's.
  Future<SeriesProgress> seriesProgress(MediaItem series) async {
    final all = await _episodeProgressStore();
    final entry = all[_mediaKey(series)];
    if (entry is! Map) return SeriesProgress.empty;
    final episodes = <String, EpisodeProgress>{};
    final raw = entry['episodes'];
    if (raw is Map) {
      for (final MapEntry(:key, :value) in raw.entries) {
        final progress = EpisodeProgress.fromJson(value);
        if (progress != null) episodes['$key'] = progress;
      }
    }
    final last = entry['last'];
    return SeriesProgress(
      episodes: episodes,
      last: last is List && last.length == 2 && last[0] is int && last[1] is int
          ? (season: last[0] as int, episode: last[1] as int)
          : null,
    );
  }

  /// Records [positionMs] of [durationMs] for one episode of [series] and
  /// marks it as the episode watched last.
  Future<void> saveEpisodeProgress(
    MediaItem series, {
    required int season,
    required int episode,
    required int positionMs,
    required int durationMs,
  }) => _serialized(() async {
    final all = await _episodeProgressStore();
    final key = _mediaKey(series);
    final entry = all.remove(key);
    final episodes = entry is Map && entry['episodes'] is Map
        ? Map<String, dynamic>.from(entry['episodes'] as Map)
        : <String, dynamic>{};
    episodes[SeriesProgress.key(season, episode)] = EpisodeProgress(
      positionMs: positionMs,
      durationMs: durationMs,
    ).toJson();
    // Re-inserted last, so map order is least to most recently watched.
    all[key] = {
      'last': [season, episode],
      'episodes': episodes,
    };
    while (all.length > _maxSeriesWithProgress) {
      all.remove(all.keys.first);
    }
    await (await SharedPreferences.getInstance()).setString(
      _episodeProgressKey,
      jsonEncode(all),
    );
  });

  Future<Map<String, dynamic>> _episodeProgressStore() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _episodeProgressKey,
    );
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> toggleFavorite(MediaItem item) => _serialized(() async {
    final all = await favorites();
    if (all.any((e) => e.id == item.id && e.type == item.type)) {
      all.removeWhere((e) => e.id == item.id && e.type == item.type);
    } else {
      all.insert(0, item);
    }
    await _saveItems(_favorites, all);
  });

  Future<void> removeHistory(MediaItem item) => _serialized(() async {
    final all = await history()
      ..removeWhere((e) => e.id == item.id && e.type == item.type);
    await _saveItems(_history, all);
  });

  Future<bool> isFavorite(MediaItem item) async =>
      (await favorites()).any((e) => e.id == item.id && e.type == item.type);

  static const _subtitlePreferencesKey = 'onfeed.player.subtitleChoice.v1';

  /// The viewer's last subtitle choice for a title (a movie or a whole
  /// series), remembered per show: Off, or a language with its
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

  Future<void> rememberSubtitle(String titleKey, RememberedSubtitle choice) =>
      _serialized(() async {
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
        await preferences.setString(
          _subtitlePreferencesKey,
          jsonEncode(values),
        );
      });

  Future<String?> readSetting(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  Future<void> saveSetting(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);

  /// Where cached stream links lived before they moved to [_lastStreamsFile];
  /// read once, then removed.
  static const _legacyLastStreamsKey = 'onfeed.playback.lastStreams.v1';
  static const _lastStreamsFileName = 'last_streams.v1.json';

  /// Cached stream links hold signed URLs and provider headers, so they are
  /// kept in a private file that Android backup does not include.
  Future<File> _lastStreamsFile() async =>
      File('${(await _filesDirectory()).path}/$_lastStreamsFileName');

  Future<Map<String, dynamic>> _readLastStreams() async {
    String? raw;
    final file = await _lastStreamsFile();
    if (await file.exists()) {
      raw = await file.readAsString();
    } else {
      raw = (await SharedPreferences.getInstance()).getString(
        _legacyLastStreamsKey,
      );
    }
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeLastStreams(Map<String, dynamic> values) async {
    final file = await _lastStreamsFile();
    await file.parent.create(recursive: true);
    // Write then rename, so an interrupted write never leaves a corrupt file.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(values), flush: true);
    await temporary.rename(file.path);
    final preferences = await SharedPreferences.getInstance();
    if (preferences.containsKey(_legacyLastStreamsKey)) {
      await preferences.remove(_legacyLastStreamsKey);
    }
  }

  Future<StreamSource?> lastStream(
    MediaItem item, {
    required Duration maxAge,
    required bool allowTorrents,
    Set<String>? allowedProviderIds,
    String? cacheKey,
  }) async {
    try {
      final value = await _readLastStreams();
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
    await _serialized(() async {
      final values = await _readLastStreams();
      final key = cacheKey ?? _mediaKey(item);
      // Re-inserted last, so the oldest entry is first when trimming.
      values
        ..remove(key)
        ..[key] = {
          'savedAt': DateTime.now().toUtc().toIso8601String(),
          'source': source.toJson(),
        };
      while (values.length > 100) {
        values.remove(values.keys.first);
      }
      await _writeLastStreams(values);
    });
  }

  String _mediaKey(MediaItem item) => '${item.type}:${item.id}';

  /// The save path handed to the torrent streamer. Calling this marks the
  /// torrent engine as started for this process (see [clearTorrentCache]).
  ///
  /// flutter_go_torrent_streamer ignores this path: its Go client keeps all
  /// torrent data in [_torrentEngineDataDirectory], which is where the space
  /// is actually used.
  Future<Directory> torrentCacheDirectory({bool create = true}) async {
    await (_torrentStartupCleanup ??= _cleanTorrentDataAtStartup());
    _torrentEngineStarted = true;
    final cache = await getTemporaryDirectory();
    final directory = Directory('${cache.path}/torrent_cache');
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Where the torrent engine stores downloaded pieces: a fixed folder next
  /// to the session file it is initialised with (the documents directory).
  static Future<Directory> _torrentEngineDataDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/flutter_torrent_streamer_global');
  }

  static const _torrentClearPendingKey = 'onfeed.torrent.clearPending';

  /// Whether the native torrent client may be running in this process. Its
  /// data can only be deleted safely before it starts: it keeps files and a
  /// piece-completion database open, and deleting them underneath it would
  /// make it serve pieces it no longer has.
  static bool _torrentEngineStarted = false;
  static Future<void>? _torrentStartupCleanup;

  /// Torrent data using more disk space than this is deleted at launch.
  static const maxTorrentDataBytes = 5 * 1024 * 1024 * 1024;

  /// Deletes torrent data before the engine first starts when a clear was
  /// requested while it was running, or when it uses more than
  /// [maxTorrentDataBytes] of disk. Also removes the folder earlier versions
  /// created but never used. Never throws.
  ///
  /// The whole folder goes or none of it: deleting only some files would
  /// leave the engine's piece-completion database describing pieces that no
  /// longer exist.
  Future<void> cleanTorrentDataAtStartup() =>
      _torrentStartupCleanup ??= _cleanTorrentDataAtStartup();

  Future<void> _cleanTorrentDataAtStartup() async {
    if (_torrentEngineStarted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final documents = await getApplicationDocumentsDirectory();
      final unused = Directory('${documents.path}/torrent_cache');
      if (await unused.exists()) await unused.delete(recursive: true);
      final data = await _torrentEngineDataDirectory();
      if (!await data.exists()) return;
      final pending = preferences.getBool(_torrentClearPendingKey) ?? false;
      if (pending || (await _diskUsageBytes(data) ?? 0) > maxTorrentDataBytes) {
        await data.delete(recursive: true);
      }
      await preferences.remove(_torrentClearPendingKey);
    } catch (_) {
      // Leaves the data for the next launch.
    }
  }

  /// Disk space used by [directory], or null when it cannot be measured.
  ///
  /// Torrent files are sparse: their length is the full download size even
  /// when only a few pieces exist, so summing lengths would wildly
  /// overestimate. `du` reports allocated blocks; Android ships it (toybox).
  static Future<int?> _diskUsageBytes(Directory directory) async {
    if (!Platform.isAndroid && !Platform.isLinux && !Platform.isMacOS) {
      return null;
    }
    try {
      final result = await Process.run('du', [
        '-sk',
        directory.path,
      ]).timeout(const Duration(seconds: 10));
      if (result.exitCode != 0) return null;
      final kilobytes = int.tryParse(
        '${result.stdout}'.trim().split(RegExp(r'\s+')).first,
      );
      return kilobytes == null ? null : kilobytes * 1024;
    } catch (_) {
      return null;
    }
  }

  /// Deletes downloaded torrent data now when the engine has not started in
  /// this process; otherwise schedules it for the next launch. Returns
  /// whether the data was deleted now.
  Future<bool> clearTorrentCache() async {
    if (!_torrentEngineStarted) {
      final data = await _torrentEngineDataDirectory();
      if (await data.exists()) await data.delete(recursive: true);
      return true;
    }
    await (await SharedPreferences.getInstance()).setBool(
      _torrentClearPendingKey,
      true,
    );
    return false;
  }
}

/// A provider manifest as last downloaded, with its HTTP validators.
class CachedManifest {
  const CachedManifest({required this.body, this.etag, this.lastModified});

  final String body;
  final String? etag;
  final String? lastModified;
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
