// Finds what to alert about, for the series, titles, people and collections
// the user follows. Shared by the app and its background task: reads the
// user's settings, My list, history and progress from local storage, asks
// the Reelish API once for the public facts (each series' latest episode,
// movies' release status, people's and collections' new work), decides what
// is new since the last check (lib/src/notifications/smart_alerts.dart),
// and shows it now or holds it for quiet hours or a summary.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_api.dart';
import '../services/storage_service.dart';
import 'smart_alerts.dart';

const _keep = Object();

/// Which series alert, per Trakt account on this device. Fields added after
/// the first version read their defaults from older saved settings.
class EpisodeAlertSettings {
  const EpisodeAlertSettings({
    this.enabled = false,
    this.myList = true,
    this.watching = true,
    this.popular = false,
    this.messages = true,
    this.watchlist = true,
    this.reminderDays = 0,
    this.people = true,
    this.franchises = true,
    this.frequency = AlertFrequency.instant,
    this.quiet,
    this.wrapped = true,
  });

  /// All alerts, on this device.
  final bool enabled;
  final bool myList;
  final bool watching;

  /// Today's most popular series with a new episode; one summary a day.
  final bool popular;

  /// Messages from friends waiting for this device: who, never what.
  final bool messages;

  /// Titles on My list: a season announced or dated, a movie dated or
  /// released.
  final bool watchlist;

  /// Remind about a series left this many days; 0 is off.
  final int reminderDays;

  /// New work by people followed.
  final bool people;

  /// New films in collections followed.
  final bool franchises;

  final AlertFrequency frequency;

  /// Hours with no alerts; null for none.
  final QuietHours? quiet;

  /// Reelish Wrapped is out, in January.
  final bool wrapped;

  EpisodeAlertSettings copyWith({
    bool? enabled,
    bool? myList,
    bool? watching,
    bool? popular,
    bool? messages,
    bool? watchlist,
    int? reminderDays,
    bool? people,
    bool? franchises,
    AlertFrequency? frequency,
    Object? quiet = _keep,
    bool? wrapped,
  }) => EpisodeAlertSettings(
    enabled: enabled ?? this.enabled,
    myList: myList ?? this.myList,
    watching: watching ?? this.watching,
    popular: popular ?? this.popular,
    messages: messages ?? this.messages,
    watchlist: watchlist ?? this.watchlist,
    reminderDays: reminderDays ?? this.reminderDays,
    people: people ?? this.people,
    franchises: franchises ?? this.franchises,
    frequency: frequency ?? this.frequency,
    quiet: identical(quiet, _keep) ? this.quiet : quiet as QuietHours?,
    wrapped: wrapped ?? this.wrapped,
  );
}

/// People and collections followed for alerts, by TMDB id, with their names.
typedef Follows = ({Map<int, String> people, Map<int, String> collections});

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

  /// [count] messages wait, the latest from [from] (handles, newest first).
  Future<void> showMessages(int count, List<String> from);

  /// News of one [category] beyond new episodes: one alert, or one
  /// summary of several.
  Future<void> showUpdates(AlertCategory category, List<AlertEvent> events);

  /// The daily or weekly summary of everything held for it.
  Future<void> showDigest(List<AlertEvent> events);
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
    final days = s['reminderDays'];
    return EpisodeAlertSettings(
      enabled: flag('enabled', false),
      myList: flag('myList', true),
      watching: flag('watching', true),
      popular: flag('popular', false),
      messages: flag('messages', true),
      watchlist: flag('watchlist', true),
      reminderDays: days is int && UnfinishedReminders.choices.contains(days)
          ? days
          : 0,
      people: flag('people', true),
      franchises: flag('franchises', true),
      frequency: AlertFrequency.byName(s['frequency']),
      quiet: QuietHours.fromJson(s['quietStart'], s['quietEnd']),
      wrapped: flag('wrapped', true),
    );
  }

  static Map<String, Object> settingsJson(EpisodeAlertSettings s) => {
    'enabled': s.enabled,
    'myList': s.myList,
    'watching': s.watching,
    'popular': s.popular,
    'messages': s.messages,
    'watchlist': s.watchlist,
    'reminderDays': s.reminderDays,
    'people': s.people,
    'franchises': s.franchises,
    'frequency': s.frequency.name,
    if (s.quiet != null) 'quietStart': s.quiet!.start,
    if (s.quiet != null) 'quietEnd': s.quiet!.end,
    'wrapped': s.wrapped,
  };

  /// At most this many people and collections each (the API's limits).
  static const maxFollows = 15;

  static Follows followsOf(Map<String, Object?> entry) {
    final raw = entry['follows'];
    Map<int, String> read(Object? value) => {
      if (value is Map)
        for (final e in value.entries)
          if (int.tryParse('${e.key}') case final id?
              when id > 0 && e.value is String)
            id: e.value as String,
    };
    return raw is Map
        ? (people: read(raw['people']), collections: read(raw['collections']))
        : (people: <int, String>{}, collections: <int, String>{});
  }

  static Map<String, Object> followsJson(Follows f) => {
    'people': {for (final e in f.people.entries) '${e.key}': e.value},
    'collections': {for (final e in f.collections.entries) '${e.key}': e.value},
  };

  /// The alerts shown lately, newest first, and whether each was seen in
  /// Settings > Notifications.
  static List<({AlertEvent event, bool read})> recentOf(
    Map<String, Object?> entry,
  ) {
    final raw = entry['recent'];
    return [
      if (raw is List)
        for (final item in raw)
          if (item is Map)
            if (AlertEvent.fromJson(item) case final event?)
              (event: event, read: item['read'] == true),
    ];
  }

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
  const EpisodeCheckResult(this.found, this.popular, [this.shown = const []]);

  /// New episodes of followed series, whether shown now or held.
  final List<NewEpisode> found;
  final List<NewEpisode> popular;

  /// Everything shown by this check (alerts and summaries alike).
  final List<AlertEvent> shown;
}

abstract final class EpisodeCheck {
  /// Episodes aired this many days ago or less count as new.
  static const recentDays = 3;

  /// Series asked about per check (the API's limit).
  static const maxSeries = 150;

  /// Movies on My list asked about per check (the API's limit).
  static const maxMovies = 30;

  /// Alerts listed in Settings > Notifications.
  static const recentCount = 30;

  /// Shown alerts are remembered this long, so none repeats.
  static const deliveredFor = Duration(days: 120);

  /// Runs one check for [userId] with [alertToken]. The first time a series
  /// (or a movie, person or collection) is seen only records it, so turning
  /// alerts on, or adding one, never alerts about what came before.
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
    final time = now ?? DateTime.now();

    final favorites = await storage.favorites();
    final history = await storage.history();
    int? idOf(String id) {
      final value = int.tryParse(id);
      return value != null && value > 0 ? value : null;
    }

    // Series whose new episodes alert.
    final followed = <int>{};
    if (settings.myList) {
      for (final item in favorites) {
        final id = idOf(item.id);
        if (item.type == 'series' && id != null) followed.add(id);
      }
    }
    if (settings.watching) {
      for (final item in history) {
        final id = idOf(item.id);
        if (item.type == 'series' && id != null) followed.add(id);
      }
    }
    // My list, for watchlist updates.
    final seriesOnList = <int>{};
    final moviesOnList = <int>[];
    if (settings.watchlist) {
      for (final item in favorites) {
        final id = idOf(item.id);
        if (id == null) continue;
        if (item.type == 'series') seriesOnList.add(id);
        if (item.type == 'movie' && moviesOnList.length < maxMovies) {
          moviesOnList.add(id);
        }
      }
    }
    final follows = EpisodeAlertStore.followsOf(entry);
    final people = settings.people
        ? follows.people.keys.take(EpisodeAlertStore.maxFollows).toList()
        : const <int>[];
    final collections = settings.franchises
        ? follows.collections.keys.take(EpisodeAlertStore.maxFollows).toList()
        : const <int>[];

    final asked = [
      ...followed,
      ...seriesOnList.where((id) => !followed.contains(id)),
    ].take(maxSeries).toList();
    final needsNetwork =
        asked.isNotEmpty ||
        moviesOnList.isNotEmpty ||
        people.isNotEmpty ||
        collections.isNotEmpty ||
        settings.popular ||
        settings.messages;

    final answer = needsNetwork
        ? await api.checkEpisodes(
            alertToken,
            asked,
            popular: settings.popular,
            messages: settings.messages,
            movies: moviesOnList.isEmpty ? null : moviesOnList,
            people: people.isEmpty ? null : people,
            collections: collections.isEmpty ? null : collections,
          )
        : null;
    final quietNow = settings.quiet?.contains(time) ?? false;

    // Messages: alert once per new arrival, not again for the same ones
    // while they wait (they leave the count once a Messages screen opens).
    // During quiet hours they wait for the next check.
    final waiting = answer?.messages;
    final notified = entry['messagesNotified'];
    final before = notified is int ? notified : 0;
    final showMessages =
        settings.messages && waiting != null && waiting.count > before;
    if (showMessages && !quietNow) {
      await notifier.showMessages(waiting.count, waiting.from);
    }

    final today = _day(time);
    final at = time.millisecondsSinceEpoch;
    final seenRaw = entry['seen'];
    final seen = <String, String>{
      if (seenRaw is Map)
        for (final e in seenRaw.entries)
          if (e.value is String) '${e.key}': e.value as String,
    };
    final progress = await storage.allSeriesProgress();
    final found = <NewEpisode>[];
    for (final series in answer?.series ?? const <Map<String, dynamic>>[]) {
      final episode = _episodeOf(series);
      if (episode == null || !followed.contains(episode.tmdbId)) continue;
      final id = '${episode.tmdbId}';
      final mark = 'S${episode.season}E${episode.episode}';
      final previous = seen[id];
      seen[id] = mark;
      if (previous == null || previous == mark) continue;
      // Already watched (on another device, say): not news.
      final watched = progress['series:$id']
          ?.of(episode.season, episode.episode)
          ?.isWatched;
      if (watched == true) continue;
      if (_isRecent(series, today)) found.add(episode);
    }

    final popular = <NewEpisode>[];
    final popularDay = entry['popularDay'];
    final todayText = _dayText(today);
    if (settings.popular && popularDay != todayText) {
      for (final series in answer?.popular ?? const <Map<String, dynamic>>[]) {
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

    // The other news.
    Map<String, Object?> stateOf(String name) {
      final raw = entry[name];
      return raw is Map ? Map<String, Object?>.from(raw) : {};
    }

    final events = <AlertEvent>[
      for (final e in found) _episodeEvent(e, AlertCategory.episode, at),
      for (final e in popular) _episodeEvent(e, AlertCategory.popular, at),
    ];
    final watchState = stateOf('watch');
    var nextWatch = <String, Object?>{};
    if (answer != null &&
        (seriesOnList.isNotEmpty || moviesOnList.isNotEmpty)) {
      final detected = WatchlistUpdates.detect(
        series: answer.series,
        movies: answer.movies,
        seriesOnList: seriesOnList,
        state: watchState,
        now: time,
      );
      events.addAll(detected.events);
      // A title missing from this answer (unavailable for now) keeps its
      // state, so it is not seen for the first time again.
      nextWatch = {
        for (final id in seriesOnList)
          if (watchState['s:$id'] case final Object kept) 's:$id': kept,
        for (final id in moviesOnList)
          if (watchState['m:$id'] case final Object kept) 'm:$id': kept,
        ...detected.state,
      };
    }
    final followState = stateOf('follow');
    var nextFollow = <String, Object?>{};
    if (answer != null && (people.isNotEmpty || collections.isNotEmpty)) {
      final detected = FollowedWork.detect(
        people: answer.people,
        collections: answer.collections,
        state: followState,
        now: time,
      );
      events.addAll(detected.events);
      nextFollow = {
        for (final id in people)
          if (followState['p:$id'] case final Object kept) 'p:$id': kept,
        for (final id in collections)
          if (followState['c:$id'] case final Object kept) 'c:$id': kept,
        ...detected.state,
      };
    }
    final lastReminderAt = entry['lastReminder'];
    final reminders = UnfinishedReminders.detect(
      days: settings.reminderDays,
      progress: progress,
      names: {
        for (final item in history)
          if (item.type == 'series') item.id: item.name,
      },
      now: time,
      lastReminder: lastReminderAt is int
          ? DateTime.fromMillisecondsSinceEpoch(lastReminderAt)
          : null,
    );
    events.addAll(reminders);
    if (settings.wrapped) {
      // Evidence on this device of viewing last year: a history entry or an
      // episode saved in it.
      bool lastYear(int at) =>
          at > 0 &&
          DateTime.fromMillisecondsSinceEpoch(at).year == time.year - 1;
      events.addAll(
        WrappedAnnouncement.detect(
          now: time,
          watchedLastYear:
              history.any((item) => lastYear(item.progressAt)) ||
              progress.values.any(
                (series) => series.episodes.values.any((e) => lastYear(e.at)),
              ),
        ),
      );
    }

    // What to show now, and what waits.
    final deliveredRaw = entry['delivered'];
    final keepFrom = time.subtract(deliveredFor).millisecondsSinceEpoch;
    final delivered = <String, int>{
      if (deliveredRaw is Map)
        for (final e in deliveredRaw.entries)
          if (e.value is int && (e.value as int) >= keepFrom)
            '${e.key}': e.value as int,
    };
    final pendingRaw = entry['pending'];
    final lastDigestAt = entry['lastDigest'];
    final plan = AlertPlanner.plan(
      found: events,
      pending: [
        if (pendingRaw is List)
          for (final item in pendingRaw) ?AlertEvent.fromJson(item),
      ],
      delivered: delivered.keys.toSet(),
      frequency: settings.frequency,
      quiet: settings.quiet,
      now: time,
      lastDigest: lastDigestAt is int
          ? DateTime.fromMillisecondsSinceEpoch(lastDigestAt)
          : null,
    );
    await _show(plan, notifier);

    await EpisodeAlertStore.update(userId, (e) {
      // Keep only series still followed, so the map does not grow forever.
      e['seen'] = {
        for (final entry in seen.entries)
          if (followed.contains(int.tryParse(entry.key)))
            entry.key: entry.value,
      };
      if (popular.isNotEmpty) e['popularDay'] = todayText;
      if (!(showMessages && quietNow)) {
        e['messagesNotified'] = waiting?.count ?? 0;
      }
      e['watch'] = nextWatch;
      e['follow'] = nextFollow;
      if (reminders.isNotEmpty) e['lastReminder'] = at;
      for (final event in plan.now) {
        delivered[event.key] = at;
      }
      e['delivered'] = delivered;
      e['pending'] = [for (final event in plan.pending) event.toJson()];
      if (plan.digest) e['lastDigest'] = at;
      final previous = e['recent'];
      e['recent'] = [
        for (final event in plan.now.reversed)
          {...event.toJson(), 'read': false},
        if (previous is List) ...previous,
      ].take(recentCount).toList();
      e['lastChecked'] = at;
    });
    return EpisodeCheckResult(found, popular, plan.now);
  }

  /// Shows [plan]'s alerts: one summary, or each category as before (new
  /// episodes one by one up to three, popular series as one summary, the
  /// rest one alert or summary per category).
  static Future<void> _show(AlertPlan plan, EpisodeNotifier notifier) async {
    if (plan.now.isEmpty) return;
    if (plan.digest) return notifier.showDigest(plan.now);
    final byCategory = <AlertCategory, List<AlertEvent>>{};
    for (final event in plan.now) {
      (byCategory[event.category] ??= []).add(event);
    }
    for (final MapEntry(:key, :value) in byCategory.entries) {
      switch (key) {
        case AlertCategory.episode:
          await notifier.showNew([for (final e in value) _newEpisodeOf(e)]);
        case AlertCategory.popular:
          await notifier.showPopular([for (final e in value) _newEpisodeOf(e)]);
        default:
          await notifier.showUpdates(key, value);
      }
    }
  }

  static AlertEvent _episodeEvent(
    NewEpisode e,
    AlertCategory category,
    int at,
  ) => AlertEvent(
    key: '${category.name}:series:${e.tmdbId}:S${e.season}E${e.episode}',
    category: category,
    title: category == AlertCategory.popular
        ? 'New on ${e.seriesName}'
        : 'New episode of ${e.seriesName}',
    body:
        'S${e.season} E${e.episode}'
        '${e.episodeName.isEmpty ? '' : ' · ${e.episodeName}'} has aired.',
    target: 'series:${e.tmdbId}',
    name: e.seriesName,
    at: at,
    season: e.season,
    episode: e.episode,
    episodeName: e.episodeName,
  );

  static NewEpisode _newEpisodeOf(AlertEvent e) => NewEpisode(
    tmdbId: int.parse(e.target.split(':').last),
    seriesName: e.name,
    season: e.season ?? 0,
    episode: e.episode ?? 0,
    episodeName: e.episodeName,
  );

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
