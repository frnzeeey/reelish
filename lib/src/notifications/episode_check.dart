// Finds newly aired episodes of the series the user follows, for alerts.
// Shared by the app and its background task: reads the user's settings and
// My list/history from local storage, asks the Reelish API for each
// series' latest episode, and decides what is new since the last check.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../services/storage_service.dart';

/// Which series alert, per Trakt account on this device.
class EpisodeAlertSettings {
  const EpisodeAlertSettings({
    this.enabled = false,
    this.myList = true,
    this.watching = true,
    this.popular = false,
  });

  final bool enabled;
  final bool myList;
  final bool watching;

  /// Today's most popular series with a new episode; one summary a day.
  final bool popular;

  EpisodeAlertSettings copyWith({
    bool? enabled,
    bool? myList,
    bool? watching,
    bool? popular,
  }) => EpisodeAlertSettings(
    enabled: enabled ?? this.enabled,
    myList: myList ?? this.myList,
    watching: watching ?? this.watching,
    popular: popular ?? this.popular,
  );
}

/// One episode to tell the user about.
class NewEpisode {
  const NewEpisode({
    required this.tmdbId,
    required this.seriesName,
    required this.season,
    required this.episode,
    required this.episodeName,
  });

  final int tmdbId;
  final String seriesName;
  final int season;
  final int episode;
  final String episodeName;
}

/// Shows alerts; system notifications in the app, a fake in tests.
abstract class EpisodeNotifier {
  Future<void> showNew(List<NewEpisode> episodes);
  Future<void> showPopular(List<NewEpisode> episodes);
}

/// What the alerts remember per Trakt account: settings, the last episode
/// seen of each series, and the day of the last popular summary. Read
/// fresh each time, since the app and its background task both write it.
class EpisodeAlertStore {
  static const key = 'onfeed.episodeAlerts.v1';

  /// The signed-in account's id, for the background task.
  static const activeUserKey = 'onfeed.episodeAlerts.user';

  static Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }

  static Future<Map<String, Object?>> _all(SharedPreferences prefs) async {
    try {
      final decoded = jsonDecode(prefs.getString(key) ?? '{}');
      return decoded is Map ? Map<String, Object?>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  static Future<Map<String, Object?>> entry(String userId) async {
    final value = (await _all(await _prefs()))[userId];
    return value is Map ? Map<String, Object?>.from(value) : {};
  }

  static Future<void> update(
    String userId,
    void Function(Map<String, Object?> entry) change,
  ) async {
    final prefs = await _prefs();
    final all = await _all(prefs);
    final current = all[userId];
    final entry = current is Map
        ? Map<String, Object?>.from(current)
        : <String, Object?>{};
    change(entry);
    all[userId] = entry;
    await prefs.setString(key, jsonEncode(all));
  }

  static EpisodeAlertSettings settingsOf(Map<String, Object?> entry) {
    final s = entry['settings'];
    if (s is! Map) return const EpisodeAlertSettings();
    bool flag(String name, bool fallback) =>
        s[name] is bool ? s[name] as bool : fallback;
    return EpisodeAlertSettings(
      enabled: flag('enabled', false),
      myList: flag('myList', true),
      watching: flag('watching', true),
      popular: flag('popular', false),
    );
  }

  static Map<String, Object> settingsJson(EpisodeAlertSettings s) => {
    'enabled': s.enabled,
    'myList': s.myList,
    'watching': s.watching,
    'popular': s.popular,
  };

  static Future<String?> activeUser() async =>
      (await _prefs()).getString(activeUserKey);

  static Future<void> setActiveUser(String? userId) async {
    final prefs = await _prefs();
    if (userId == null) {
      await prefs.remove(activeUserKey);
    } else {
      await prefs.setString(activeUserKey, userId);
    }
  }
}

/// The outcome of one check.
class EpisodeCheckResult {
  const EpisodeCheckResult(this.found, this.popular);
  final List<NewEpisode> found;
  final List<NewEpisode> popular;
}

abstract final class EpisodeCheck {
  /// Episodes aired this many days ago or less count as new.
  static const recentDays = 3;

  /// Series asked about per check (the API's limit).
  static const maxSeries = 150;

  /// Runs one check for [userId] with [alertToken]. The first time a series
  /// is seen only records its latest episode, so turning alerts on, or
  /// adding a series, never alerts about episodes from before.
  static Future<EpisodeCheckResult> run({
    required String userId,
    required String alertToken,
    required AccountApi api,
    required StorageService storage,
    required EpisodeNotifier notifier,
    DateTime? now,
  }) async {
    final entry = await EpisodeAlertStore.entry(userId);
    final settings = EpisodeAlertStore.settingsOf(entry);
    if (!settings.enabled) return const EpisodeCheckResult([], []);

    final followed = <int>{};
    if (settings.myList) {
      for (final item in await storage.favorites()) {
        final id = int.tryParse(item.id);
        if (item.type == 'series' && id != null && id > 0) followed.add(id);
      }
    }
    if (settings.watching) {
      for (final item in await storage.history()) {
        final id = int.tryParse(item.id);
        if (item.type == 'series' && id != null && id > 0) followed.add(id);
      }
    }
    if (followed.isEmpty && !settings.popular) {
      await _markChecked(userId, now);
      return const EpisodeCheckResult([], []);
    }

    final answer = await api.checkEpisodes(
      alertToken,
      followed.take(maxSeries).toList(),
      popular: settings.popular,
    );

    final today = _day(now ?? DateTime.now());
    final seenRaw = entry['seen'];
    final seen = <String, String>{
      if (seenRaw is Map)
        for (final e in seenRaw.entries)
          if (e.value is String) '${e.key}': e.value as String,
    };
    final found = <NewEpisode>[];
    for (final series in answer.series) {
      final episode = _episodeOf(series);
      if (episode == null) continue;
      final id = '${episode.tmdbId}';
      final mark = 'S${episode.season}E${episode.episode}';
      final previous = seen[id];
      seen[id] = mark;
      if (previous == null || previous == mark) continue;
      if (_isRecent(series, today)) found.add(episode);
    }

    final popular = <NewEpisode>[];
    final popularDay = entry['popularDay'];
    final todayText = _dayText(today);
    if (settings.popular && popularDay != todayText) {
      for (final series in answer.popular) {
        final episode = _episodeOf(series);
        if (episode == null || followed.contains(episode.tmdbId)) continue;
        final aired = _airDate(series);
        // Aired today or yesterday: "new" for a series the user does not
        // follow episode by episode.
        if (aired != null &&
            today.difference(aired).inDays <= 1 &&
            !aired.isAfter(today)) {
          popular.add(episode);
        }
      }
    }

    if (found.isNotEmpty) await notifier.showNew(found);
    if (popular.isNotEmpty) await notifier.showPopular(popular);

    await EpisodeAlertStore.update(userId, (e) {
      // Keep only series still followed, so the map does not grow forever.
      e['seen'] = {
        for (final entry in seen.entries)
          if (followed.contains(int.tryParse(entry.key)))
            entry.key: entry.value,
      };
      if (popular.isNotEmpty) e['popularDay'] = todayText;
      e['lastChecked'] = (now ?? DateTime.now()).millisecondsSinceEpoch;
    });
    return EpisodeCheckResult(found, popular);
  }

  /// A check with nothing to ask about: no series are followed any more,
  /// so none are remembered either.
  static Future<void> _markChecked(String userId, DateTime? now) =>
      EpisodeAlertStore.update(userId, (e) {
        e['seen'] = <String, String>{};
        e['lastChecked'] = (now ?? DateTime.now()).millisecondsSinceEpoch;
      });

  static NewEpisode? _episodeOf(Map<String, dynamic> series) {
    final id = series['tmdbId'];
    final last = series['lastEpisode'];
    if (id is! int || last is! Map) return null;
    final season = last['season'];
    final episode = last['episode'];
    if (season is! int || episode is! int) return null;
    return NewEpisode(
      tmdbId: id,
      seriesName: '${series['name'] ?? ''}'.trim(),
      season: season,
      episode: episode,
      episodeName: '${last['name'] ?? ''}'.trim(),
    );
  }

  static DateTime? _airDate(Map<String, dynamic> series) {
    final last = series['lastEpisode'];
    final text = last is Map ? last['airDate'] : null;
    if (text is! String) return null;
    final parsed = DateTime.tryParse(text);
    return parsed == null ? null : _day(parsed);
  }

  static bool _isRecent(Map<String, dynamic> series, DateTime today) {
    final aired = _airDate(series);
    if (aired == null || aired.isAfter(today)) return false;
    return today.difference(aired).inDays <= recentDays;
  }

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  static String _dayText(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
