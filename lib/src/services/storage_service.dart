import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueNotifier,
        defaultTargetPlatform,
        visibleForTesting;
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart'
    show FlutterTorrentStreamer;
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

  /// Starts a fresh queue of writes. For tests: a write left unfinished by
  /// an earlier test (real file I/O cannot complete in a widget test's fake
  /// time) would otherwise hold every later write.
  @visibleForTesting
  static void debugResetWrites() => _updates = Future.value();

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

  // Watch history per account ---------------------------------------------

  /// The account whose watch history and episode progress are read and
  /// written, set by [useAccount]. Null (signed out, and tests) keeps the
  /// device-wide keys used before accounts were separated.
  static String? _account;

  /// The one-time move of the device-wide history into the account that
  /// owns it, while it runs; reads wait for it, so Home never shows a
  /// half-moved history. Null otherwise: a finished future kept here would
  /// resume its awaiters in the zone that created it (an ended test's).
  static Future<void>? _adopting;

  static Future<void> _adoptionDone() async {
    final adopting = _adopting;
    if (adopting != null) await adopting;
  }

  static String get _historyKey =>
      _account == null ? _history : '$_history.u.$_account';
  static String get _episodesKey => _account == null
      ? _episodeProgressKey
      : '$_episodeProgressKey.u.$_account';

  /// Reads and writes [userId]'s watch history from now on; null when no
  /// one is signed in. When [ownsDeviceHistory] resolves true, the history
  /// this device kept before accounts were separated becomes this
  /// account's (merged under what it already has), and the device-wide
  /// copy is removed so no other account can read it.
  static void useAccount(String? userId, {Future<bool>? ownsDeviceHistory}) {
    if (userId == _account) return;
    _account = userId;
    if (userId == null || ownsDeviceHistory == null) return;
    final historyKey = _historyKey, episodesKey = _episodesKey;
    late final Future<void> move;
    move = _serialized(() async {
      try {
        if (!await ownsDeviceHistory) return;
        await StorageService()._adoptDeviceHistory(historyKey, episodesKey);
      } catch (_) {
        // Left for the next launch; the account's own history still works.
      } finally {
        if (identical(_adopting, move)) _adopting = null;
      }
    });
    _adopting = move;
  }

  @visibleForTesting
  static void debugResetAccount() {
    _account = null;
    _adopting = null;
  }

  /// Inside the write queue. Safe to repeat: entries already in the
  /// account win, and the device-wide keys are removed only after the
  /// account's copy is written.
  Future<void> _adoptDeviceHistory(
    String historyKey,
    String episodesKey,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final hasHistory = preferences.containsKey(_history);
    final hasEpisodes = preferences.containsKey(_episodeProgressKey);
    if (!hasHistory && !hasEpisodes) return;
    if (hasHistory) {
      final own = await _items(historyKey);
      final present = {for (final e in own) '${e.type}:${e.id}'};
      final merged = [
        ...own,
        for (final e in await _items(_history))
          if (present.add('${e.type}:${e.id}')) e,
      ];
      await _saveItems(historyKey, merged.take(50).toList());
    }
    if (hasEpisodes) {
      final device = await _episodeProgressStore(_episodeProgressKey);
      final own = await _episodeProgressStore(episodesKey);
      // The account's own entries last: the map runs oldest to newest.
      final merged = <String, dynamic>{
        for (final MapEntry(:key, :value) in device.entries)
          if (!own.containsKey(key)) key: value,
        ...own,
      };
      while (merged.length > _maxSeriesWithProgress) {
        merged.remove(merged.keys.first);
      }
      await preferences.setString(episodesKey, jsonEncode(merged));
    }
    await preferences.remove(_history);
    await preferences.remove(_episodeProgressKey);
  }

  Future<List<MediaItem>> history() async {
    final key = _historyKey;
    await _adoptionDone();
    return _items(key);
  }

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
  }) {
    // The account at the time of the save, whenever the queue reaches it.
    final key = _historyKey, account = _account;
    return _serialized(() async {
      final at = clock();
      final all = await _items(key);
      all.removeWhere((e) => e.id == item.id && e.type == item.type);
      all.insert(
        0,
        item.copyWith(
          resumeMs: positionMs,
          durationMs: durationMs,
          progressAt: at,
        ),
      );
      await _saveItems(key, all.take(50).toList());
      _tellProgressSaved(item, positionMs, durationMs, null);
      _tellChanged(account, '${item.type}:${item.id}', at);
    });
  }

  /// The time saves are stamped with ([MediaItem.progressAt],
  /// [EpisodeProgress.at]); progress sync measures its clock offset with
  /// the same clock. Replaced in tests.
  static int Function() clock = () => DateTime.now().millisecondsSinceEpoch;

  /// Told the account and key (`movie:<id>`, `series:<id>`,
  /// `episode:<id>:<season>:<episode>`) of each change made on this device
  /// to history or progress, with its time, for cross-device sync. Changes
  /// applied from sync are not told. Null unless sync runs; signed out,
  /// nothing is told. It must not wait on anything.
  static void Function(String account, String key, int at)? onProgressChanged;

  static void _tellChanged(String? account, String key, int at) {
    final listener = onProgressChanged;
    if (listener == null || account == null) return;
    try {
      listener(account, key, at);
    } catch (_) {
      // Sync must never fail a save.
    }
  }

  /// Told about each watch position [saveProgress] and [saveEpisodeProgress]
  /// wrote (an episode's with its number), for personalised discovery. Null,
  /// so nothing is told, unless Home's discovery is running. It must not
  /// wait on anything: it runs inside the queue of writes.
  static void Function(SavedProgress saved)? onProgressSaved;

  static void _tellProgressSaved(
    MediaItem item,
    int positionMs,
    int durationMs,
    ({int season, int episode})? episode,
  ) {
    final listener = onProgressSaved;
    if (listener == null) return;
    try {
      listener((
        item: item,
        positionMs: positionMs,
        durationMs: durationMs,
        episode: episode,
      ));
    } catch (_) {
      // Discovery must never fail a progress save.
    }
  }

  static const _episodeProgressKey = 'onfeed.history.episodes.v1';

  /// Series kept in the per-episode store; the oldest is dropped beyond it.
  static const _maxSeriesWithProgress = 100;

  /// Per-episode progress for [series]. The series' history entry keeps a
  /// single `resumeMs` for continue-watching rows; this keeps each episode's
  /// own position, so one episode never resumes at another's.
  Future<SeriesProgress> seriesProgress(MediaItem series) async {
    final key = _episodesKey;
    await _adoptionDone();
    final all = await _episodeProgressStore(key);
    return _seriesProgressOf(all[_mediaKey(series)]) ?? SeriesProgress.empty;
  }

  static SeriesProgress? _seriesProgressOf(Object? entry) {
    if (entry is! Map) return null;
    final episodes = <String, EpisodeProgress>{};
    final raw = entry['episodes'];
    if (raw is Map) {
      for (final MapEntry(:key, :value) in raw.entries) {
        final progress = EpisodeProgress.fromJson(value);
        if (progress != null) episodes['$key'] = progress;
      }
    }
    ({int season, int episode})? pair(Object? value) =>
        value is List && value.length == 2 && value[0] is int && value[1] is int
        ? (season: value[0] as int, episode: value[1] as int)
        : null;
    return SeriesProgress(
      episodes: episodes,
      last: pair(entry['last']),
      next: pair(entry['next']),
    );
  }

  /// Records [positionMs] of [durationMs] for one episode of [series] and
  /// marks it as the episode watched last. [next] is the episode after it,
  /// given once this one is watched and the episode list names it; it is
  /// what Continue watching offers next.
  Future<void> saveEpisodeProgress(
    MediaItem series, {
    required int season,
    required int episode,
    required int positionMs,
    required int durationMs,
    ({int season, int episode})? next,
  }) {
    final storeKey = _episodesKey, account = _account;
    return _serialized(() async {
      final at = clock();
      final all = await _episodeProgressStore(storeKey);
      final key = _mediaKey(series);
      final entry = all.remove(key);
      final episodes = entry is Map && entry['episodes'] is Map
          ? Map<String, dynamic>.from(entry['episodes'] as Map)
          : <String, dynamic>{};
      episodes[SeriesProgress.key(season, episode)] = EpisodeProgress(
        positionMs: positionMs,
        durationMs: durationMs,
        at: at,
      ).toJson();
      // Re-inserted last, so map order is least to most recently watched.
      all[key] = {
        'last': [season, episode],
        'next': ?(next == null ? null : [next.season, next.episode]),
        'episodes': episodes,
      };
      while (all.length > _maxSeriesWithProgress) {
        all.remove(all.keys.first);
      }
      await (await SharedPreferences.getInstance()).setString(
        storeKey,
        jsonEncode(all),
      );
      _tellProgressSaved(series, positionMs, durationMs, (
        season: season,
        episode: episode,
      ));
      _tellChanged(account, 'episode:${series.id}:$season:$episode', at);
    });
  }

  /// Every series' per-episode progress, by `series:<id>`, for sync.
  Future<Map<String, SeriesProgress>> allSeriesProgress() async {
    final key = _episodesKey;
    await _adoptionDone();
    final all = await _episodeProgressStore(key);
    return {
      for (final id in all.keys)
        if (id.startsWith('series:'))
          id: _seriesProgressOf(all[id]) ?? SeriesProgress.empty,
    };
  }

  /// Applies progress pulled from the account's other devices, inside the
  /// write queue: each change only where it is newer than what this device
  /// holds. Returns whether anything changed. Nothing here is told to
  /// [onProgressChanged] or [onProgressSaved]: it came from elsewhere.
  Future<bool> applySynced(List<SyncedProgress> changes) {
    final historyKey = _historyKey, episodesKey = _episodesKey;
    return _serialized(() async {
      final history = await _items(historyKey);
      final store = await _episodeProgressStore(episodesKey);
      var historyChanged = false, episodesChanged = false;
      for (final change in changes) {
        final parts = change.key.split(':');
        final kind = parts.first, id = parts.length > 1 ? parts[1] : '';
        if ((kind == 'movie' || kind == 'series') && parts.length == 2) {
          historyChanged |= _applyTitle(history, kind, id, change);
        } else if (kind == 'episode' && parts.length == 4) {
          final season = int.tryParse(parts[2]);
          final episode = int.tryParse(parts[3]);
          if (season == null || episode == null) continue;
          episodesChanged |= _applyEpisode(store, id, season, episode, change);
        }
      }
      if (historyChanged) {
        await _saveItems(historyKey, history.take(50).toList());
      }
      if (episodesChanged) {
        while (store.length > _maxSeriesWithProgress) {
          store.remove(store.keys.first);
        }
        await (await SharedPreferences.getInstance()).setString(
          episodesKey,
          jsonEncode(store),
        );
      }
      return historyChanged || episodesChanged;
    });
  }

  static bool _applyTitle(
    List<MediaItem> history,
    String type,
    String id,
    SyncedProgress change,
  ) {
    final index = history.indexWhere((e) => e.type == type && e.id == id);
    final current = index < 0 ? null : history[index];
    if (current != null && current.progressAt >= change.at) return false;
    if (change.removed) {
      if (current == null) return false;
      history.removeAt(index);
      return true;
    }
    final base = current ?? change.card(type, id);
    if (base == null) return false;
    if (index >= 0) history.removeAt(index);
    // Newest first: before the first entry saved earlier.
    final at = history.indexWhere((e) => e.progressAt < change.at);
    history.insert(
      at < 0 ? history.length : at,
      base.copyWith(
        resumeMs: change.positionMs,
        durationMs: change.durationMs,
        progressAt: change.at,
      ),
    );
    return true;
  }

  static bool _applyEpisode(
    Map<String, dynamic> store,
    String seriesId,
    int season,
    int episode,
    SyncedProgress change,
  ) {
    final key = 'series:$seriesId';
    final entry = store[key];
    final episodes = entry is Map && entry['episodes'] is Map
        ? Map<String, dynamic>.from(entry['episodes'] as Map)
        : <String, dynamic>{};
    final episodeKey = SeriesProgress.key(season, episode);
    final current = EpisodeProgress.fromJson(episodes[episodeKey]);
    if (current != null && current.at >= change.at) return false;
    episodes[episodeKey] = EpisodeProgress(
      positionMs: change.positionMs,
      durationMs: change.durationMs,
      at: change.at,
    ).toJson();
    final progress = _seriesProgressOf(entry) ?? SeriesProgress.empty;
    final last = progress.last;
    final lastAt = last == null
        ? 0
        : progress.of(last.season, last.episode)?.at ?? 0;
    final next = change.next;
    if (last == null ||
        change.at >= lastAt ||
        last == (season: season, episode: episode)) {
      // The episode watched last anywhere; re-inserted as most recent.
      store.remove(key);
      store[key] = {
        'last': [season, episode],
        'next': ?(next == null ? null : [next.season, next.episode]),
        'episodes': episodes,
      };
    } else {
      store[key] = {
        ...Map<String, dynamic>.from(entry as Map),
        'episodes': episodes,
      };
    }
    return true;
  }

  Future<Map<String, dynamic>> _episodeProgressStore(String key) async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  /// Changes whenever My list is written, so screens and Trakt sync can
  /// follow edits made elsewhere.
  static final favoritesRevision = ValueNotifier<int>(0);

  Future<void> toggleFavorite(MediaItem item) => _serialized(() async {
    final all = await favorites();
    if (all.any((e) => e.id == item.id && e.type == item.type)) {
      all.removeWhere((e) => e.id == item.id && e.type == item.type);
    } else {
      all.insert(0, item.copyWith(savedAt: clock()));
    }
    await _saveItems(_favorites, all);
    favoritesRevision.value++;
  });

  /// Adds [items] not already on My list at its end, and removes those
  /// whose `type:id` is in [remove], in one write (used by Trakt sync).
  Future<void> updateFavorites({
    List<MediaItem> add = const [],
    Set<String> remove = const {},
  }) => _serialized(() async {
    if (add.isEmpty && remove.isEmpty) return;
    final all = await favorites()
      ..removeWhere((e) => remove.contains('${e.type}:${e.id}'));
    final present = {for (final e in all) '${e.type}:${e.id}'};
    for (final item in add) {
      // Not dated: a first sync brings the whole Trakt watchlist at once,
      // which would fill Recently added.
      if (present.add('${item.type}:${item.id}')) all.add(item);
    }
    await _saveItems(_favorites, all);
    favoritesRevision.value++;
  });

  Future<void> removeHistory(MediaItem item) {
    final key = _historyKey, account = _account;
    return _serialized(() async {
      final all = await _items(key)
        ..removeWhere((e) => e.id == item.id && e.type == item.type);
      await _saveItems(key, all);
      _tellChanged(account, '${item.type}:${item.id}', clock());
    });
  }

  /// Puts back a title [removeHistory] took out, at [index] as it was then.
  /// It counts as a new change, so it outranks the removal on other devices.
  Future<void> restoreHistory(MediaItem item, int index) {
    final key = _historyKey, account = _account;
    return _serialized(() async {
      final at = clock();
      final all = await _items(key)
        ..removeWhere((e) => e.id == item.id && e.type == item.type);
      all.insert(index.clamp(0, all.length), item.copyWith(progressAt: at));
      await _saveItems(key, all.take(50).toList());
      _tellChanged(account, '${item.type}:${item.id}', at);
    });
  }

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

  /// Moves links saved by older versions out of backed-up preferences the
  /// first time they are read, rather than at the next save, which may
  /// never come.
  Future<void> _migrateLegacyLastStreams() async {
    final preferences = await SharedPreferences.getInstance();
    if (!preferences.containsKey(_legacyLastStreamsKey)) return;
    await _serialized(() async {
      if (!preferences.containsKey(_legacyLastStreamsKey)) return;
      await _writeLastStreams(await _readLastStreams());
    });
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
      await _migrateLegacyLastStreams();
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
  /// to the session file it is initialised with (the documents directory;
  /// on Windows its own folder in local app data).
  static Future<Directory> _torrentEngineDataDirectory() async {
    if (_windows) {
      final engine = await FlutterTorrentStreamer.engineDirectory();
      return Directory('${engine.path}\\flutter_torrent_streamer_global');
    }
    final documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}/flutter_torrent_streamer_global');
  }

  static bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

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
      if (_windows) {
        // The engine restores the sessions in this file when it starts and
        // resumes their torrents in the background. Reelish starts every
        // session itself, so one left by a closed app is removed. (The
        // Android-only folder below would be the user's own Documents here.)
        final engine = await FlutterTorrentStreamer.engineDirectory();
        final sessions = File('${engine.path}\\sessions.json');
        if (await sessions.exists()) await sessions.delete();
      } else {
        final documents = await getApplicationDocumentsDirectory();
        final unused = Directory('${documents.path}/torrent_cache');
        if (await unused.exists()) await unused.delete(recursive: true);
      }
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
    if (_windows && Platform.isWindows) return _fileLengthsBytes(directory);
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

  /// Windows has no `du`. The engine writes pieces at their offsets in
  /// ordinary (not sparse) NTFS files, which allocates the file up to the
  /// furthest piece, so file lengths are what the data occupies, or a little
  /// more: never less, so the cap cannot be missed.
  static Future<int?> _fileLengthsBytes(Directory directory) async {
    try {
      var total = 0;
      await for (final entity
          in directory
              .list(recursive: true, followLinks: false)
              .timeout(const Duration(seconds: 10))) {
        if (entity is File) total += await entity.length();
      }
      return total;
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

/// A watch position as [StorageService] saved it.
typedef SavedProgress = ({
  MediaItem item,
  int positionMs,
  int durationMs,
  ({int season, int episode})? episode,
});

/// A title's progress as another device of the account last saved it, read
/// from the Reelish API (see `ProgressSync`). [at] is already on this
/// device's clock. Remote data: [card] admits only TMDB artwork.
class SyncedProgress {
  const SyncedProgress({
    required this.key,
    required this.positionMs,
    required this.durationMs,
    required this.at,
    this.next,
    this.removed = false,
    this.title,
    this.year,
    this.poster,
    this.backdrop,
  });

  final String key;
  final int positionMs, durationMs, at;
  final ({int season, int episode})? next;
  final bool removed;
  final String? title, year, poster, backdrop;

  static final _artwork = RegExp(
    r'^https://image\.tmdb\.org/t/p/(w\d{2,4}|original)/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$',
  );

  /// Artwork from TMDB's image host, or nothing.
  static String artwork(String? url) =>
      url != null && _artwork.hasMatch(url) ? url : '';

  /// A history entry for a title this device has not played; null without
  /// a title to show.
  MediaItem? card(String type, String id) {
    final name = title?.trim() ?? '';
    if (name.isEmpty) return null;
    final poster = artwork(this.poster);
    final backdrop = artwork(this.backdrop);
    return MediaItem(
      id: id,
      type: type,
      name: name.length > 300 ? name.substring(0, 300) : name,
      year: RegExp(r'^\d{4}$').hasMatch(year ?? '') ? year! : '',
      poster: poster,
      background: backdrop.isNotEmpty ? backdrop : poster,
    );
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
