// Reelish Wrapped's numbers: one calendar year of the account's own viewing,
// counted from the playback progress Reelish syncs across its devices
// (GET /progress) and the titles' TMDB details. Pure Dart, so every rule is
// tested without a device; the rules are the ones Profile > Viewing
// statistics uses, applied to the whole synced record instead of this
// device's recent history.
//
// What counts:
// - **Finished:** a movie or episode at 90% or more of a known length
//   (ViewingRules.completedShare), whose last change was in the year, in the
//   viewer's local time. A title is one row on the server, so it is counted
//   once however often it synced; a rewatch replaces its position rather
//   than adding a row, so rewatches are not counted.
// - **Watch time** is an estimate: the furthest point reached in each movie
//   and episode last played in the year (at least 90 seconds, never past its
//   length). It is labelled as one.
// - **Genres and actors** are counted per title (a series once, however many
//   episodes), from TMDB's genres and top-billed cast.
// - **Personality** comes from fixed rules over these numbers, each with its
//   reason shown; there is no model and nothing is sent anywhere.

import '../discovery/viewing_activity.dart';

/// One synced progress row, as `GET /progress` answers it.
class WrappedRow {
  const WrappedRow({
    required this.kind,
    required this.tmdbId,
    required this.positionMs,
    required this.durationMs,
    required this.at,
    this.season = 0,
    this.episode = 0,
    this.title = '',
    this.poster = '',
  });

  /// `movie`, `episode` or `series` (a series' Continue watching card).
  final String kind;
  final int tmdbId;
  final int season;
  final int episode;
  final int positionMs;
  final int durationMs;

  /// When the row last changed, in milliseconds since the epoch.
  final int at;
  final String title;
  final String poster;

  static final _key = RegExp(
    r'^(movie|series):([1-9]\d{0,9})$|^episode:([1-9]\d{0,9}):(\d{1,4}):(\d{1,5})$',
  );
  static final _artwork = RegExp(
    r'^https://image\.tmdb\.org/t/p/(w\d{2,4}|original)/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$',
  );

  /// A row from the API, or null when anything is malformed.
  static WrappedRow? fromJson(Map<String, dynamic> json) {
    final match = _key.firstMatch('${json['key']}');
    final position = json['positionMs'], duration = json['durationMs'];
    final at = json['at'];
    if (match == null || position is! int || duration is! int || at is! int) {
      return null;
    }
    final poster = json['poster'];
    final title = json['title'];
    final episode = match[3] != null;
    return WrappedRow(
      kind: episode ? 'episode' : match[1]!,
      tmdbId: int.parse(episode ? match[3]! : match[2]!),
      season: episode ? int.parse(match[4]!) : 0,
      episode: episode ? int.parse(match[5]!) : 0,
      positionMs: position,
      durationMs: duration,
      at: at,
      title: title is String ? title.trim() : '',
      poster: poster is String && _artwork.hasMatch(poster) ? poster : '',
    );
  }

  /// Longer than any real title: anything beyond is not a viewing.
  static const maxLength = Duration(hours: 24);

  /// A length and position that make sense.
  bool get valid =>
      durationMs > 0 &&
      durationMs <= maxLength.inMilliseconds &&
      positionMs >= 0 &&
      at > 0;

  bool get finished =>
      valid && positionMs >= durationMs * ViewingRules.completedShare;

  /// Time watched, as far as the row can tell: the furthest point, never
  /// past the length.
  int get watchedMs => positionMs > durationMs ? durationMs : positionMs;
}

/// What Wrapped needs of a title's TMDB details.
class TitleInfo {
  const TitleInfo({
    this.name = '',
    this.poster = '',
    this.genres = const [],
    this.cast = const [],
    this.seasons = const {},
  });

  final String name;
  final String poster;
  final List<String> genres;

  /// Top-billed cast, in billing order.
  final List<({int id, String name, String profile})> cast;

  /// Episodes per season (season 1 and up), for series.
  final Map<int, int> seasons;

  /// Billed this high or better counts as appearing in a title.
  static const castDepth = 10;

  static TitleInfo fromTmdb(Map<String, dynamic> json) {
    final credits = json['credits'];
    final rawCast = credits is Map && credits['cast'] is List
        ? credits['cast'] as List
        : const [];
    String image(Object? path, String size) =>
        path is String &&
            RegExp(
              r'^/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$',
            ).hasMatch(path)
        ? 'https://image.tmdb.org/t/p/$size$path'
        : '';
    final name = json['title'] ?? json['name'];
    return TitleInfo(
      name: name is String ? name.trim() : '',
      poster: image(json['poster_path'], 'w342'),
      genres: [
        for (final g in json['genres'] is List ? json['genres'] as List : [])
          if (g is Map &&
              g['name'] is String &&
              (g['name'] as String).isNotEmpty)
            g['name'] as String,
      ],
      cast: [
        for (final c in rawCast.take(castDepth))
          if (c is Map && c['id'] is int && c['name'] is String)
            (
              id: c['id'] as int,
              name: c['name'] as String,
              profile: image(c['profile_path'], 'w185'),
            ),
      ],
      seasons: {
        for (final s in json['seasons'] is List ? json['seasons'] as List : [])
          if (s is Map &&
              s['season_number'] is int &&
              (s['season_number'] as int) > 0 &&
              s['episode_count'] is int &&
              (s['episode_count'] as int) > 0)
            s['season_number'] as int: s['episode_count'] as int,
      },
    );
  }
}

/// A title as Wrapped shows it.
class WrappedTitle {
  const WrappedTitle({
    required this.type,
    required this.id,
    required this.name,
    this.poster = '',
    this.count = 1,
  });

  /// `movie` or `series`.
  final String type;
  final int id;
  final String name;
  final String poster;

  /// Episodes finished, for a series.
  final int count;

  Map<String, Object?> toJson() => {
    't': type,
    'i': id,
    'n': name,
    if (poster.isNotEmpty) 'p': poster,
    if (count != 1) 'c': count,
  };

  static WrappedTitle? fromJson(Object? json) {
    if (json is! Map || json['i'] is! int || json['n'] is! String) return null;
    final type = json['t'] == 'series' ? 'series' : 'movie';
    return WrappedTitle(
      type: type,
      id: json['i'] as int,
      name: json['n'] as String,
      poster: json['p'] is String ? json['p'] as String : '',
      count: json['c'] is int ? json['c'] as int : 1,
    );
  }
}

/// A personality, and why the viewer has it.
class WrappedPersona {
  const WrappedPersona(this.id, this.title, this.line, this.reason);

  final String id;

  /// "The Story Seeker".
  final String title;

  /// One playful line.
  final String line;

  /// The rule it came from, in plain words, with the viewer's numbers.
  final String reason;

  /// [line] in the sharer's own voice, for a share card ("I'm …").
  String get cardLine => switch (id) {
    'devotee' => 'I knew what I loved, and went back for more.',
    'binge' => 'One more episode was never just one.',
    'story' => 'I like a story with room to grow.',
    'cinephile' => 'Two hours at a time, I made the year a festival.',
    'explorer' => 'No shelf was off limits.',
    'night' => 'My best stories started after dark.',
    'weekend' => 'Saturdays and Sundays were for stories.',
    _ => 'Every title was a door, and I opened a few.',
  };

  Map<String, Object?> toJson() => {
    'id': id,
    't': title,
    'l': line,
    'r': reason,
  };

  static WrappedPersona? fromJson(Object? json) =>
      json is Map &&
          json['id'] is String &&
          json['t'] is String &&
          json['l'] is String &&
          json['r'] is String
      ? WrappedPersona(
          json['id'] as String,
          json['t'] as String,
          json['l'] as String,
          json['r'] as String,
        )
      : null;
}

/// One year of viewing, as computed once and kept.
class WrappedSummary {
  const WrappedSummary({
    required this.year,
    required this.computedAt,
    required this.movies,
    required this.episodes,
    required this.series,
    required this.movieMinutes,
    required this.seriesMinutes,
    required this.months,
    required this.weekdays,
    required this.genres,
    required this.genreTitles,
    required this.actors,
    required this.topSeries,
    required this.seasonsFinished,
    required this.milestones,
    required this.personas,
    this.coveredFrom = 0,
  });

  final int year;
  final int computedAt;

  /// Movies finished, earliest first.
  final List<WrappedTitle> movies;
  final int episodes;

  /// Series with an episode finished, most episodes first.
  final List<WrappedTitle> series;

  /// The watch-time estimate, in minutes.
  final int movieMinutes;
  final int seriesMinutes;

  /// Titles finished in each month (January first) and on each weekday
  /// (Monday first).
  final List<int> months;
  final List<int> weekdays;

  /// Genres by titles finished, most first, at most five.
  final List<({String name, int count})> genres;

  /// Titles that had any genre: the genre shares' whole.
  final int genreTitles;

  /// Actors by titles finished, at most five, each in two or more.
  final List<({int id, String name, String profile, int count})> actors;

  /// The series with the most episodes finished.
  final WrappedTitle? topSeries;
  final int seasonsFinished;

  /// "First movie of the year", "100th episode"…
  final List<({String label, String detail, int at})> milestones;

  /// The first is the main one.
  final List<WrappedPersona> personas;

  /// The earliest moment the recap can include, when later than 1 January:
  /// the server keeps progress for 400 days, so a recap computed long after
  /// its year misses the start. 0 when the whole year is covered.
  final int coveredFrom;

  bool get partial => coveredFrom > 0;

  int get finished => movies.length + episodes;
  bool get isEmpty => finished == 0;
  int get minutes => movieMinutes + seriesMinutes;

  /// The busiest month, 1–12, or 0 with nothing finished.
  int get topMonth => _peak(months);

  /// The busiest weekday, 1 (Monday)–7, or 0.
  int get topWeekday => _peak(weekdays);

  static int _peak(List<int> counts) {
    var best = 0, at = 0;
    for (var i = 0; i < counts.length; i++) {
      if (counts[i] > best) {
        best = counts[i];
        at = i + 1;
      }
    }
    return at;
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'year': year,
    'computedAt': computedAt,
    'movies': [for (final m in movies) m.toJson()],
    'episodes': episodes,
    'series': [for (final s in series) s.toJson()],
    'movieMinutes': movieMinutes,
    'seriesMinutes': seriesMinutes,
    'months': months,
    'weekdays': weekdays,
    'genres': [
      for (final g in genres) {'n': g.name, 'c': g.count},
    ],
    'genreTitles': genreTitles,
    'actors': [
      for (final a in actors)
        {'i': a.id, 'n': a.name, 'p': a.profile, 'c': a.count},
    ],
    'topSeries': topSeries?.toJson(),
    'seasonsFinished': seasonsFinished,
    'milestones': [
      for (final m in milestones) {'l': m.label, 'd': m.detail, 'at': m.at},
    ],
    'personas': [for (final p in personas) p.toJson()],
    if (coveredFrom > 0) 'coveredFrom': coveredFrom,
  };

  /// Read defensively: anything malformed gives null, and the recap is
  /// computed again.
  static WrappedSummary? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) return null;
    List<int> counts(Object? value, int length) {
      final list = value is List ? value : const [];
      if (list.length != length || !list.every((e) => e is int)) {
        return List.filled(length, 0);
      }
      return [for (final e in list) e as int];
    }

    int number(String key) => json[key] is int ? json[key] as int : 0;
    final year = json['year'];
    if (year is! int) return null;
    return WrappedSummary(
      year: year,
      computedAt: number('computedAt'),
      movies: [
        for (final m in json['movies'] is List ? json['movies'] as List : [])
          ?WrappedTitle.fromJson(m),
      ],
      episodes: number('episodes'),
      series: [
        for (final s in json['series'] is List ? json['series'] as List : [])
          ?WrappedTitle.fromJson(s),
      ],
      movieMinutes: number('movieMinutes'),
      seriesMinutes: number('seriesMinutes'),
      months: counts(json['months'], 12),
      weekdays: counts(json['weekdays'], 7),
      genres: [
        for (final g in json['genres'] is List ? json['genres'] as List : [])
          if (g is Map && g['n'] is String && g['c'] is int)
            (name: g['n'] as String, count: g['c'] as int),
      ],
      genreTitles: number('genreTitles'),
      actors: [
        for (final a in json['actors'] is List ? json['actors'] as List : [])
          if (a is Map && a['i'] is int && a['n'] is String && a['c'] is int)
            (
              id: a['i'] as int,
              name: a['n'] as String,
              profile: a['p'] is String ? a['p'] as String : '',
              count: a['c'] as int,
            ),
      ],
      topSeries: WrappedTitle.fromJson(json['topSeries']),
      seasonsFinished: number('seasonsFinished'),
      milestones: [
        for (final m
            in json['milestones'] is List ? json['milestones'] as List : [])
          if (m is Map &&
              m['l'] is String &&
              m['d'] is String &&
              m['at'] is int)
            (
              label: m['l'] as String,
              detail: m['d'] as String,
              at: m['at'] as int,
            ),
      ],
      personas: [
        for (final p
            in json['personas'] is List ? json['personas'] as List : [])
          ?WrappedPersona.fromJson(p),
      ],
      coveredFrom: number('coveredFrom'),
    );
  }
}

/// How long the server keeps a progress row that does not change
/// (progressRetentionMs in backend/src/progress.ts).
const progressRetention = Duration(days: 400);

const monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

abstract final class WrappedStats {
  /// Genres and actors shown.
  static const topGenres = 5;
  static const topActors = 5;

  /// Episodes of one series finished on one day that make a binge.
  static const bingeEpisodes = 4;

  /// The earliest moment a recap of [year] computed at [now] can include:
  /// 0 when the server still holds the whole year.
  static int coveredFrom(int year, DateTime now) {
    final horizon = now.subtract(progressRetention);
    return horizon.isAfter(DateTime(year)) ? horizon.millisecondsSinceEpoch : 0;
  }

  /// Computes [year] from [rows] and the titles' [info] (by `movie:<id>` or
  /// `series:<id>`; a title without info still counts, without genres or
  /// cast). Times are read in the device's local time zone.
  static WrappedSummary compute({
    required int year,
    required List<WrappedRow> rows,
    required Map<String, TitleInfo> info,
    required DateTime now,
  }) {
    DateTime local(int at) => DateTime.fromMillisecondsSinceEpoch(at);
    bool inYear(WrappedRow r) => r.valid && local(r.at).year == year;

    // Names and posters from the series' own Continue watching rows.
    final cards = <String, WrappedRow>{
      for (final r in rows)
        if (r.kind != 'episode') '${r.kind}:${r.tmdbId}': r,
    };
    String nameOf(String key) {
      final fromInfo = info[key]?.name ?? '';
      return fromInfo.isNotEmpty ? fromInfo : cards[key]?.title ?? '';
    }

    String posterOf(String key) {
      final card = cards[key]?.poster ?? '';
      return card.isNotEmpty ? card : info[key]?.poster ?? '';
    }

    // One row per title on the server; keyed again here so a malformed
    // answer with repeats still counts each once.
    final movieRows = <int, WrappedRow>{};
    final episodeRows = <String, WrappedRow>{};
    var movieMs = 0, seriesMs = 0;
    for (final r in rows) {
      if (!inYear(r)) continue;
      if (r.kind == 'movie') {
        movieRows[r.tmdbId] = r;
      } else if (r.kind == 'episode') {
        episodeRows['${r.tmdbId}:${r.season}:${r.episode}'] = r;
      }
    }
    final minimum = ViewingRules.minimumPosition.inMilliseconds;
    for (final r in movieRows.values) {
      if (r.watchedMs >= minimum) movieMs += r.watchedMs;
    }
    for (final r in episodeRows.values) {
      if (r.watchedMs >= minimum) seriesMs += r.watchedMs;
    }

    final finishedMovies = [
      for (final r in movieRows.values)
        if (r.finished) r,
    ]..sort((a, b) => a.at.compareTo(b.at));
    final finishedEpisodes = [
      for (final r in episodeRows.values)
        if (r.finished) r,
    ]..sort((a, b) => a.at.compareTo(b.at));
    final finishedAll = [...finishedMovies, ...finishedEpisodes]
      ..sort((a, b) => a.at.compareTo(b.at));

    final months = List.filled(12, 0);
    final weekdays = List.filled(7, 0);
    var night = 0, weekend = 0;
    for (final r in finishedAll) {
      final t = local(r.at);
      months[t.month - 1]++;
      weekdays[t.weekday - 1]++;
      if (t.hour >= 22 || t.hour < 5) night++;
      if (t.weekday >= DateTime.saturday) weekend++;
    }

    // Series: episodes finished, binge days and finished seasons.
    final perSeries = <int, List<WrappedRow>>{};
    for (final r in finishedEpisodes) {
      (perSeries[r.tmdbId] ??= []).add(r);
    }
    var bingeDays = 0;
    for (final list in perSeries.values) {
      final byDay = <String, int>{};
      for (final r in list) {
        final t = local(r.at);
        final day = '${t.year}-${t.month}-${t.day}';
        byDay[day] = (byDay[day] ?? 0) + 1;
      }
      bingeDays += byDay.values.where((n) => n >= bingeEpisodes).length;
    }
    // Every episode of a season finished, the last of them this year;
    // earlier episodes may have been finished before the year began.
    final allFinished = <String>{
      for (final r in rows)
        if (r.kind == 'episode' && r.finished)
          '${r.tmdbId}:${r.season}:${r.episode}',
    };
    var seasonsFinished = 0;
    ({int at, String name, int season})? firstSeason;
    for (final MapEntry(key: id, value: list) in perSeries.entries) {
      final seasons = info['series:$id']?.seasons ?? const {};
      for (final MapEntry(key: season, value: count) in seasons.entries) {
        final thisYear = list.where((r) => r.season == season).toList();
        if (thisYear.isEmpty) continue;
        final complete = [
          for (var e = 1; e <= count; e++)
            allFinished.contains('$id:$season:$e'),
        ].every((done) => done);
        if (!complete) continue;
        seasonsFinished++;
        final at = thisYear.map((r) => r.at).reduce((a, b) => a > b ? a : b);
        if (firstSeason == null || at < firstSeason.at) {
          firstSeason = (at: at, name: nameOf('series:$id'), season: season);
        }
      }
    }

    // Every finished title counts, named or not: a title whose details
    // could not be had is listed under a plain name rather than dropped.
    String named(String key, String fallback) {
      final name = nameOf(key);
      return name.isEmpty ? fallback : name;
    }

    final series = [
      for (final MapEntry(key: id, value: list) in perSeries.entries)
        WrappedTitle(
          type: 'series',
          id: id,
          name: named('series:$id', 'A series'),
          poster: posterOf('series:$id'),
          count: list.length,
        ),
    ]..sort((a, b) => b.count.compareTo(a.count));

    final movies = [
      for (final r in finishedMovies)
        WrappedTitle(
          type: 'movie',
          id: r.tmdbId,
          name: named('movie:${r.tmdbId}', 'A movie'),
          poster: posterOf('movie:${r.tmdbId}'),
        ),
    ];

    // Genres and actors, once per title.
    final titleKeys = <String>{
      for (final r in finishedMovies) 'movie:${r.tmdbId}',
      for (final id in perSeries.keys) 'series:$id',
    };
    final genreCounts = <String, int>{};
    final actorCounts = <int, int>{};
    final actorInfo = <int, ({String name, String profile})>{};
    var genreTitles = 0;
    for (final key in titleKeys) {
      final title = info[key];
      if (title == null) continue;
      final genres = title.genres.toSet();
      if (genres.isNotEmpty) genreTitles++;
      for (final g in genres) {
        genreCounts[g] = (genreCounts[g] ?? 0) + 1;
      }
      for (final c in {for (final c in title.cast) c.id: c}.values) {
        actorCounts[c.id] = (actorCounts[c.id] ?? 0) + 1;
        actorInfo[c.id] = (name: c.name, profile: c.profile);
      }
    }
    final genres =
        [for (final e in genreCounts.entries) (name: e.key, count: e.value)]
          ..sort(
            (a, b) => b.count != a.count
                ? b.count.compareTo(a.count)
                : a.name.compareTo(b.name),
          );
    final actors =
        [
          for (final e in actorCounts.entries)
            if (e.value >= 2)
              (
                id: e.key,
                name: actorInfo[e.key]!.name,
                profile: actorInfo[e.key]!.profile,
                count: e.value,
              ),
        ]..sort(
          (a, b) => b.count != a.count
              ? b.count.compareTo(a.count)
              : a.name.compareTo(b.name),
        );

    // Milestones, from the order things were finished in.
    final milestones = <({String label, String detail, int at})>[];
    if (movies.isNotEmpty) {
      milestones.add((
        label: 'Your first movie of $year',
        detail: movies.first.name,
        at: finishedMovies.first.at,
      ));
    }
    if (finishedEpisodes.isNotEmpty) {
      final first = finishedEpisodes.first;
      final name = nameOf('series:${first.tmdbId}');
      if (name.isNotEmpty) {
        milestones.add((
          label: 'Your first episode of $year',
          detail: '$name · S${first.season} E${first.episode}',
          at: first.at,
        ));
      }
    }
    for (final n in const [100, 250, 500, 1000]) {
      if (finishedEpisodes.length < n) break;
      final r = finishedEpisodes[n - 1];
      final name = nameOf('series:${r.tmdbId}');
      milestones.add((
        label: 'Your ${n}th episode',
        detail: name.isEmpty ? 'S${r.season} E${r.episode}' : name,
        at: r.at,
      ));
    }
    for (final n in const [25, 50, 100]) {
      if (finishedMovies.length < n || movies.length < n) break;
      milestones.add((
        label: 'Your ${n}th movie',
        detail: movies[n - 1].name,
        at: finishedMovies[n - 1].at,
      ));
    }
    if (firstSeason != null && firstSeason.name.isNotEmpty) {
      milestones.add((
        label: 'First season you finished',
        detail: '${firstSeason.name} · Season ${firstSeason.season}',
        at: firstSeason.at,
      ));
    }
    milestones.sort((a, b) => a.at.compareTo(b.at));

    final personas = _personas(
      movies: finishedMovies.length,
      episodes: finishedEpisodes.length,
      genres: genres,
      genreTitles: genreTitles,
      bingeDays: bingeDays,
      night: night,
      weekend: weekend,
      finished: finishedAll.length,
    );

    return WrappedSummary(
      year: year,
      computedAt: now.millisecondsSinceEpoch,
      movies: movies,
      episodes: finishedEpisodes.length,
      series: series,
      movieMinutes: movieMs ~/ 60000,
      seriesMinutes: seriesMs ~/ 60000,
      months: months,
      weekdays: weekdays,
      genres: genres.take(topGenres).toList(),
      genreTitles: genreTitles,
      actors: actors.take(topActors).toList(),
      topSeries: series.isEmpty ? null : series.first,
      seasonsFinished: seasonsFinished,
      milestones: milestones,
      personas: personas,
      coveredFrom: coveredFrom(year, now),
    );
  }

  /// The rules, in order: the first that holds is the main personality, the
  /// rest that hold are traits. Each says why, with the viewer's numbers.
  static List<WrappedPersona> _personas({
    required int movies,
    required int episodes,
    required List<({String name, int count})> genres,
    required int genreTitles,
    required int bingeDays,
    required int night,
    required int weekend,
    required int finished,
  }) {
    final out = <WrappedPersona>[];
    if (finished == 0) return out;
    final top = genres.isEmpty ? null : genres.first;
    final topShare = top == null || genreTitles == 0
        ? 0.0
        : top.count / genreTitles;
    int pct(double share) => (share * 100).round();

    if (top != null && genreTitles >= 5 && topShare >= .4) {
      out.add(
        WrappedPersona(
          'devotee',
          'The ${top.name} Devotee',
          'You knew what you loved, and you went back for more.',
          '${top.name} was in ${pct(topShare)}% of the titles you finished.',
        ),
      );
    }
    if (bingeDays >= 3) {
      out.add(
        WrappedPersona(
          'binge',
          'The Binge Master',
          'One more episode was never just one.',
          'On $bingeDays days you finished $bingeEpisodes or more episodes '
              'of one series.',
        ),
      );
    }
    if (episodes >= 20 && episodes >= movies * 3) {
      out.add(
        WrappedPersona(
          'story',
          'The Story Seeker',
          'You like a story with room to grow.',
          'You finished $episodes episodes and $movies movies.',
        ),
      );
    }
    if (movies >= 24) {
      out.add(
        WrappedPersona(
          'cinephile',
          'The Cinephile',
          'Two hours at a time, you made the year a festival.',
          'You finished $movies movies: about ${(movies / 12).toStringAsFixed(0)} '
              'a month.',
        ),
      );
    }
    if (genres.length >= 8 && genreTitles >= 8 && topShare < .35) {
      // [genres] is every genre seen, not only the top five.
      out.add(
        WrappedPersona(
          'explorer',
          'The Genre Explorer',
          'No shelf was off limits.',
          'Your titles spanned ${genres.length} genres, none above '
              '${pct(topShare)}%.',
        ),
      );
    }
    if (finished >= 10 && night / finished >= .4) {
      out.add(
        WrappedPersona(
          'night',
          'The Night Owl',
          'The best stories started after dark.',
          '${pct(night / finished)}% of what you finished ended between '
              '22:00 and 05:00.',
        ),
      );
    }
    if (finished >= 10 && weekend / finished >= .6) {
      out.add(
        WrappedPersona(
          'weekend',
          'The Weekend Watcher',
          'Saturdays and Sundays were for stories.',
          '${pct(weekend / finished)}% of what you finished was on a weekend.',
        ),
      );
    }
    if (out.isEmpty) {
      out.add(
        WrappedPersona(
          'curious',
          'The Curious Viewer',
          'Every title was a door, and you opened a few.',
          'You finished $finished '
              '${finished == 1 ? 'title' : 'movies and episodes'} this year.',
        ),
      );
    }
    return out;
  }
}
