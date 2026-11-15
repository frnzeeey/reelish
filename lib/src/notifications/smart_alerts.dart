// The rules behind Reelish's alerts beyond the new-episode check itself:
// what counts as news (watchlist updates, unfinished-series reminders, work
// by people followed, films in collections followed), the stable key each
// piece of news has so it is never shown twice, and when it is shown
// (instantly, or held for quiet hours or a daily or weekly digest). Pure
// Dart over the check's answer and the state EpisodeAlertStore keeps, so the
// app and its background task decide the same way and tests need no device.
//
// A first sight only records: following a person, adding a title to My list
// or turning a category on never alerts about what was already known.
// Release dates are TMDB's metadata, not playable availability, and the
// wording says so.

import '../models/episode_progress.dart';

/// What an alert is about; each has its own switch in Settings.
enum AlertCategory {
  episode,
  popular,
  watchlist,
  reminder,
  person,
  franchise,

  /// Last year's Reelish Wrapped is out (January).
  wrapped;

  static AlertCategory? byName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// How alerts arrive: each as it is found, or gathered into one summary.
enum AlertFrequency {
  instant('As they happen'),
  daily('Daily summary'),
  weekly('Weekly summary');

  const AlertFrequency(this.label);
  final String label;

  static AlertFrequency byName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return instant;
  }

  /// The least time between two summaries. Checks run every few hours, so
  /// a day is a little under 24 hours, or the summary would slip later each
  /// day.
  Duration get period => switch (this) {
    instant => Duration.zero,
    daily => const Duration(hours: 20),
    weekly => const Duration(days: 6, hours: 20),
  };
}

/// Hours in which nothing is shown: what is found waits for the first check
/// after them. Whole hours, local time; [start] may be after [end] (over
/// midnight).
class QuietHours {
  const QuietHours(this.start, this.end);

  final int start;
  final int end;

  static const presets = [
    QuietHours(22, 7),
    QuietHours(23, 8),
    QuietHours(21, 9),
  ];

  bool contains(DateTime time) {
    final h = time.hour;
    if (start == end) return false;
    return start < end ? h >= start && h < end : h >= start || h < end;
  }

  String get label => '${_hour(start)} – ${_hour(end)}';
  static String _hour(int h) => '${h.toString().padLeft(2, '0')}:00';

  static QuietHours? fromJson(Object? start, Object? end) =>
      start is int &&
          end is int &&
          start >= 0 &&
          start < 24 &&
          end >= 0 &&
          end < 24 &&
          start != end
      ? QuietHours(start, end)
      : null;

  @override
  bool operator ==(Object other) =>
      other is QuietHours && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// One piece of news. [key] is stable for the same news however often the
/// check runs (`category:content:event`), and is remembered once shown.
class AlertEvent {
  const AlertEvent({
    required this.key,
    required this.category,
    required this.title,
    required this.body,
    required this.target,
    required this.name,
    required this.at,
    this.season,
    this.episode,
    this.episodeName = '',
  });

  final String key;
  final AlertCategory category;
  final String title;
  final String body;

  /// What a tap opens: `series:<id>`, `movie:<id>`, `person:<id>` or
  /// `collection:<id>` (TMDB ids).
  final String target;

  /// The title's, person's or collection's name, for the page a tap opens.
  final String name;

  /// When it was found, in milliseconds since the epoch.
  final int at;

  /// For a new episode: which one.
  final int? season;
  final int? episode;
  final String episodeName;

  Map<String, Object?> toJson() => {
    'k': key,
    'c': category.name,
    't': title,
    'b': body,
    'to': target,
    'n': name,
    'at': at,
    if (season != null) 's': season,
    if (episode != null) 'e': episode,
    if (episodeName.isNotEmpty) 'en': episodeName,
  };

  static final _target = RegExp(
    r'^(series|movie|person|collection|wrapped):[1-9]\d{0,9}$',
  );

  /// Read defensively: a malformed entry is dropped, never a crash.
  static AlertEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['k'], title = json['t'], body = json['b'];
    final target = json['to'], at = json['at'];
    final category = AlertCategory.byName(json['c']);
    if (key is! String || title is! String || body is! String) return null;
    if (target is! String || !_target.hasMatch(target)) return null;
    if (at is! int || category == null) return null;
    final name = json['n'], s = json['s'], e = json['e'], en = json['en'];
    return AlertEvent(
      key: key,
      category: category,
      title: title,
      body: body,
      target: target,
      name: name is String ? name : '',
      at: at,
      season: s is int ? s : null,
      episode: e is int ? e : null,
      episodeName: en is String ? en : '',
    );
  }
}

/// What a check shows now, and what waits for later.
class AlertPlan {
  const AlertPlan({
    required this.now,
    required this.pending,
    required this.digest,
  });

  final List<AlertEvent> now;
  final List<AlertEvent> pending;

  /// [now] is one summary rather than separate alerts.
  final bool digest;
}

abstract final class AlertPlanner {
  /// News waiting longer than this is no longer news.
  static const maxAge = Duration(days: 8);

  /// At most this much waits; the oldest goes first.
  static const maxPending = 60;

  /// Decides what to show of [found] and what was [pending]: news already
  /// [delivered] (by key) is dropped, and so is news too old to matter.
  static AlertPlan plan({
    required List<AlertEvent> found,
    required List<AlertEvent> pending,
    required Set<String> delivered,
    required AlertFrequency frequency,
    required QuietHours? quiet,
    required DateTime now,
    DateTime? lastDigest,
  }) {
    final oldest = now.subtract(maxAge).millisecondsSinceEpoch;
    final keys = <String>{};
    final all = <AlertEvent>[
      for (final event in [...pending, ...found])
        if (!delivered.contains(event.key) &&
            event.at >= oldest &&
            keys.add(event.key))
          event,
    ];
    final kept = all.length > maxPending
        ? all.sublist(all.length - maxPending)
        : all;
    if (kept.isEmpty || (quiet?.contains(now) ?? false)) {
      return AlertPlan(now: const [], pending: kept, digest: false);
    }
    if (frequency == AlertFrequency.instant) {
      return AlertPlan(now: kept, pending: const [], digest: false);
    }
    final due =
        lastDigest == null || now.difference(lastDigest) >= frequency.period;
    return due
        ? AlertPlan(now: kept, pending: const [], digest: true)
        : AlertPlan(now: const [], pending: kept, digest: false);
  }
}

String _day(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _parse(String text) {
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  return parsed == null
      ? null
      : DateTime(parsed.year, parsed.month, parsed.day);
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `12 Mar 2027`, or '' for no date.
String alertDate(String text) {
  final d = _parse(text);
  return d == null ? '' : '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// What a detector found, and the state to keep for the next check.
typedef Detected = ({List<AlertEvent> events, Map<String, Object?> state});

/// Watchlist updates for series and movies on My list: a new season
/// announced or given a premiere date, a movie given a release date, and a
/// movie released. Nothing else: a refreshed poster or overview is not news.
abstract final class WatchlistUpdates {
  /// [series] and [movies] are the check's answers; [state] what the last
  /// check kept (`s:<id>` and `m:<id>`).
  static Detected detect({
    required List<Map<String, dynamic>> series,
    required List<Map<String, dynamic>> movies,
    required Set<int> seriesOnList,
    required Map<String, Object?> state,
    required DateTime now,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final at = now.millisecondsSinceEpoch;
    final events = <AlertEvent>[];
    final next = <String, Object?>{};
    for (final s in series) {
      final id = s['tmdbId'];
      if (id is! int || !seriesOnList.contains(id)) continue;
      final seasons = s['seasons'];
      if (seasons is! int || seasons <= 0) continue;
      final name = '${s['name'] ?? ''}'.trim();
      final last = s['lastEpisode'];
      final aired = last is Map && last['season'] is int
          ? last['season'] as int
          : 0;
      final upcoming = s['nextEpisode'];
      // A premiere: the first episode of a season after the last aired one.
      String premiere = '';
      int premiereSeason = 0;
      if (upcoming is Map &&
          upcoming['episode'] == 1 &&
          upcoming['season'] is int &&
          (upcoming['season'] as int) > aired) {
        final date = _parse('${upcoming['airDate'] ?? ''}');
        if (date != null && !date.isBefore(today)) {
          premiere = _day(date);
          premiereSeason = upcoming['season'] as int;
        }
      }
      final key = 's:$id';
      final before = state[key];
      next[key] = {
        'n': seasons,
        if (premiere.isNotEmpty) 'p': '$premiereSeason:$premiere',
      };
      // First sight: only noted.
      if (before is! Map || name.isEmpty) continue;
      final seen = before['n'] is int ? before['n'] as int : seasons;
      if (premiere.isNotEmpty && before['p'] != '$premiereSeason:$premiere') {
        events.add(
          AlertEvent(
            key: 'watchlist:series:$id:premiere:$premiereSeason:$premiere',
            category: AlertCategory.watchlist,
            title:
                '$name: season $premiereSeason premieres ${alertDate(premiere)}',
            body:
                'The premiere date is set. When it can play depends on your sources.',
            target: 'series:$id',
            name: name,
            at: at,
          ),
        );
      } else if (seasons > seen) {
        events.add(
          AlertEvent(
            key: 'watchlist:series:$id:season:$seasons',
            category: AlertCategory.watchlist,
            title: '$name: season $seasons announced',
            body:
                'No premiere date yet. Reelish will tell you when there is one.',
            target: 'series:$id',
            name: name,
            at: at,
          ),
        );
      }
    }
    for (final m in movies) {
      final id = m['tmdbId'];
      if (id is! int) continue;
      final title = '${m['title'] ?? ''}'.trim();
      final status = '${m['status'] ?? ''}';
      final date = _parse('${m['releaseDate'] ?? ''}');
      final released =
          status == 'Released' && date != null && !date.isAfter(today);
      final key = 'm:$id';
      final before = state[key];
      next[key] = {'r': released, 'd': date == null ? '' : _day(date)};
      if (before is! Map || title.isEmpty) continue;
      if (released && before['r'] != true) {
        // Only news while it is fresh: a release from long ago that TMDB
        // just corrected is not.
        if (today.difference(date).inDays <= 30) {
          events.add(
            AlertEvent(
              key: 'watchlist:movie:$id:released',
              category: AlertCategory.watchlist,
              title: '$title is released',
              body:
                  'Released ${alertDate(_day(date))}. When it can play depends on your sources.',
              target: 'movie:$id',
              name: title,
              at: at,
            ),
          );
        }
      } else if (!released &&
          date != null &&
          date.isAfter(today) &&
          before['d'] == '') {
        events.add(
          AlertEvent(
            key: 'watchlist:movie:$id:date',
            category: AlertCategory.watchlist,
            title: '$title has a release date',
            body:
                'Set for ${alertDate(_day(date))}, in cinemas or elsewhere first.',
            target: 'movie:$id',
            name: title,
            at: at,
          ),
        );
      }
    }
    return (events: events, state: next);
  }
}

/// Work by people followed and films in collections followed. A credit
/// first seen with no date, or a future one, is an announcement; it is
/// released once its date has come. Each is told once of each.
abstract final class FollowedWork {
  /// A release this recent is news; older ones are only noted.
  static const freshDays = 21;

  static Detected detect({
    required List<Map<String, dynamic>> people,
    required List<Map<String, dynamic>> collections,
    required Map<String, Object?> state,
    required DateTime now,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final at = now.millisecondsSinceEpoch;
    final events = <AlertEvent>[];
    final next = <String, Object?>{};

    // [items] as (kind, id, title, date, role); the person's or collection's
    // own seen map is kept with 'u' (upcoming) or 'r' (released).
    void follow({
      required String key,
      required AlertCategory category,
      required List<(String, int, String, String, String)> items,
      required String Function(String title, String role) announced,
      required String Function(String title, String role) released,
    }) {
      final before = state[key];
      final firstSight = before is! Map;
      final seen = <String, String>{
        if (before is Map)
          for (final e in before.entries)
            if (e.value is String) '${e.key}': e.value as String,
      };
      final kept = <String, String>{};
      for (final (kind, id, title, dateText, role) in items) {
        if (title.isEmpty) continue;
        final date = _parse(dateText);
        final out = date != null && !date.isAfter(today);
        final mark = out ? 'r' : 'u';
        final itemKey = '$kind:$id';
        final previous = seen[itemKey];
        kept[itemKey] = mark;
        if (firstSight || previous == mark || previous == 'r') continue;
        final target = '$kind:$id';
        if (out) {
          if (today.difference(date).inDays > freshDays) continue;
          events.add(
            AlertEvent(
              key: '${category.name}:$key:$itemKey:released',
              category: category,
              title: released(title, role),
              body:
                  'Out ${alertDate(_day(date))}. When it can play depends on your sources.',
              target: target,
              name: title,
              at: at,
            ),
          );
        } else if (previous == null) {
          events.add(
            AlertEvent(
              key: '${category.name}:$key:$itemKey:announced',
              category: category,
              title: announced(title, role),
              body: date == null
                  ? 'Announced; no release date yet.'
                  : 'Announced for ${alertDate(_day(date))}.',
              target: target,
              name: title,
              at: at,
            ),
          );
        }
      }
      next[key] = kept;
    }

    for (final p in people) {
      final id = p['tmdbId'];
      final name = '${p['name'] ?? ''}'.trim();
      final credits = p['credits'];
      if (id is! int || name.isEmpty || credits is! List) continue;
      follow(
        key: 'p:$id',
        category: AlertCategory.person,
        items: [
          for (final c in credits)
            if (c is Map && c['tmdbId'] is int)
              (
                c['type'] == 'series' ? 'series' : 'movie',
                c['tmdbId'] as int,
                '${c['title'] ?? ''}'.trim(),
                '${c['date'] ?? ''}',
                '${c['role'] ?? ''}',
              ),
        ],
        announced: (title, role) => role == 'director'
            ? 'New project: $name directs $title'
            : 'New project: $name stars in $title',
        released: (title, role) => role == 'director'
            ? '$title is out, directed by $name'
            : '$title is out, with $name',
      );
    }
    for (final c in collections) {
      final id = c['tmdbId'];
      final name = '${c['name'] ?? ''}'.trim();
      final parts = c['parts'];
      if (id is! int || name.isEmpty || parts is! List) continue;
      follow(
        key: 'c:$id',
        category: AlertCategory.franchise,
        items: [
          for (final part in parts)
            if (part is Map && part['tmdbId'] is int)
              (
                'movie',
                part['tmdbId'] as int,
                '${part['title'] ?? ''}'.trim(),
                '${part['releaseDate'] ?? ''}',
                '',
              ),
        ],
        announced: (title, _) => '$name: $title announced',
        released: (title, _) => '$name: $title is released',
      );
    }
    return (events: events, state: next);
  }
}

/// Reminders about series started and left. Worked out on the device from
/// its own progress: no request, and nothing leaves the device.
abstract final class UnfinishedReminders {
  /// The choices offered; 0 is off.
  static const choices = [0, 3, 7, 14];

  /// A series left this long is let go: no reminder about it.
  static const giveUpAfter = Duration(days: 45);

  /// At most one reminder a day, about one series.
  static const spacing = Duration(hours: 20);

  /// The series to remind about, if any: one with an episode to go on with
  /// (unfinished, or the next one known), last watched [days] or more ago
  /// but not [giveUpAfter], still in Continue watching ([names] by id). Its
  /// key holds the last watch time, so watching again starts a new
  /// stretch and one stretch is reminded about once.
  static List<AlertEvent> detect({
    required int days,
    required Map<String, SeriesProgress> progress,
    required Map<String, String> names,
    required DateTime now,
    DateTime? lastReminder,
  }) {
    if (days <= 0) return const [];
    if (lastReminder != null && now.difference(lastReminder) < spacing) {
      return const [];
    }
    AlertEvent? best;
    var bestAt = 0;
    for (final MapEntry(:key, :value) in progress.entries) {
      final id = key.startsWith('series:') ? key.substring(7) : key;
      final name = names[id];
      final next = value.continueAt;
      if (name == null || name.isEmpty || next == null) continue;
      if (!RegExp(r'^[1-9]\d{0,9}$').hasMatch(id)) continue;
      var lastAt = 0;
      for (final p in value.episodes.values) {
        if (p.at > lastAt) lastAt = p.at;
      }
      if (lastAt <= 0) continue;
      final idle = now.difference(DateTime.fromMillisecondsSinceEpoch(lastAt));
      if (idle < Duration(days: days) || idle > giveUpAfter) continue;
      // The most recently watched of those due.
      if (lastAt <= bestAt) continue;
      bestAt = lastAt;
      final unfinished =
          value.of(next.season, next.episode)?.isInProgress ?? false;
      best = AlertEvent(
        key: 'reminder:series:$id:$lastAt',
        category: AlertCategory.reminder,
        title: 'Pick up $name',
        body: unfinished
            ? 'S${next.season} E${next.episode} is waiting where you left it.'
            : 'S${next.season} E${next.episode} is next.',
        target: 'series:$id',
        name: name,
        at: now.millisecondsSinceEpoch,
      );
    }
    return best == null ? const [] : [best];
  }
}

/// Reelish Wrapped is out: once, in January, about the year just ended,
/// for an account that watched something in it on this device. The key
/// holds the year, so the planner never tells it twice.
abstract final class WrappedAnnouncement {
  static List<AlertEvent> detect({
    required DateTime now,
    required bool watchedLastYear,
  }) {
    if (now.month != DateTime.january || !watchedLastYear) return const [];
    final year = now.year - 1;
    return [
      AlertEvent(
        key: 'wrapped:$year',
        category: AlertCategory.wrapped,
        title: 'Your $year Reelish Wrapped is here',
        body: 'Your year in movies and series, to look back on and share.',
        target: 'wrapped:$year',
        name: 'Wrapped $year',
        at: now.millisecondsSinceEpoch,
      ),
    ];
  }
}
