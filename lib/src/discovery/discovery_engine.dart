// Turns a taste profile and candidate titles into Home's personalised rows.
// Pure and deterministic: no network, storage or clock beyond `now`, so the
// same inputs always give the same rows and every ranking can be explained.

import 'dart:math' as math;

import '../models/media_item.dart';
import '../services/media_catalog_rules.dart';
import '../services/media_discovery_ranking.dart';
import 'taste_profile.dart';
import 'tmdb_genres.dart';

/// The kinds of personalised row, in the order they are preferred.
enum DiscoverySectionKind {
  forYou,
  becauseYouWatched,
  favoriteGenre,
  somethingDifferent,
}

/// One personalised Home row.
class DiscoverySection {
  const DiscoverySection({
    required this.kind,
    required this.title,
    required this.items,
    this.reasons = const {},
    this.seedKey,
  });

  final DiscoverySectionKind kind;
  final String title;
  final List<MediaItem> items;

  /// Why each title is here, by `type:id`, in words a viewer can read.
  final Map<String, String> reasons;

  /// The title a Because-you-watched row is built from.
  final String? seedKey;

  /// Stable across refreshes, for widget keys and row memory.
  String get id => seedKey == null ? kind.name : '${kind.name}:$seedKey';

  String reasonFor(MediaItem item) =>
      reasons['${item.type}:${item.id}'] ?? title;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'title': title,
    'seed': ?seedKey,
    'items': [for (final item in items) item.toJson()],
    'reasons': reasons,
  };

  static DiscoverySection? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = DiscoverySectionKind.values.asNameMap()[json['kind']];
    final title = json['title'], items = json['items'];
    if (kind == null || title is! String || items is! List) return null;
    final reasons = json['reasons'];
    final seed = json['seed'];
    final parsed = <MediaItem>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      try {
        parsed.add(MediaItem.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {}
    }
    if (parsed.isEmpty) return null;
    return DiscoverySection(
      kind: kind,
      title: title,
      items: List.unmodifiable(parsed),
      seedKey: seed is String ? seed : null,
      reasons: reasons is Map
          ? {
              for (final MapEntry(:key, :value) in reasons.entries)
                if (value is String) '$key': value,
            }
          : const {},
    );
  }
}

/// TMDB's recommendations for one seed title, in TMDB's order.
class SeedCandidates {
  const SeedCandidates(this.seed, this.items);

  final TasteSeed seed;
  final List<MediaItem> items;
}

/// A candidate with its score terms, kept for explanations and tests.
class ScoredCandidate {
  ScoredCandidate._(this.item);

  final MediaItem item;

  /// (seed index, position in that seed's list).
  final sources = <(int, int)>[];
  double genreMatch = 0, seedRelevance = 0, quality = 0, popularity = 0;
  double typeFit = 0, score = 0;

  String get key => MediaCatalogFilter.key(item);
}

abstract final class DiscoveryEngine {
  /// Fewer titles than this and a row is not shown.
  static const minRowSize = 6;
  static const forYouSize = 15;
  static const rowSize = 12;

  /// Personalised rows shown at most, so Home is not crowded.
  static const maxSections = 4;

  /// A title must score at least this well on genre to be counted as
  /// matching, and at most [exploreMaxMatch] to count as different.
  static const strongMatch = 0.5;
  static const exploreMaxMatch = 0.25;

  /// Candidates are rated at least this, with [MediaDiscoveryRanking
  /// .relaxedVoteThreshold] votes.
  static const minRating = 5.0;

  /// Rows for [profile] from [seedLists] and the titles Home already loaded
  /// ([pool]). Empty when the profile is empty: Home's ordinary rows are the
  /// cold start.
  static List<DiscoverySection> build(
    TasteProfile profile, {
    List<SeedCandidates> seedLists = const [],
    List<MediaItem> pool = const [],
    DiscoveryWeights weights = DiscoveryWeights.standard,
    DateTime? now,
  }) {
    if (profile.isEmpty) return const [];
    final candidates = score(
      profile,
      seedLists: seedLists,
      pool: pool,
      weights: weights,
      now: now,
    );
    if (candidates.isEmpty) return const [];
    final byKey = {for (final c in candidates) c.key: c};
    final used = <String>{};
    final seeds = [for (final list in seedLists) list.seed];

    final forYou = _forYou(profile, candidates, seeds, weights, used);
    final because = <DiscoverySection>[];
    for (
      var index = 0;
      index < seedLists.length && because.length < 2;
      index++
    ) {
      final row = _becauseRow(seedLists[index], byKey, used);
      if (row != null) because.add(row);
    }
    final genre = _genreRow(profile, candidates, used);
    final different = profile.signalCount >= 3
        ? _differentRow(candidates, used)
        : null;

    return [
      forYou,
      because.firstOrNull,
      genre,
      because.length > 1 ? because[1] : null,
      different,
    ].nonNulls.take(maxSections).toList();
  }

  /// Every eligible candidate, scored, best first.
  static List<ScoredCandidate> score(
    TasteProfile profile, {
    List<SeedCandidates> seedLists = const [],
    List<MediaItem> pool = const [],
    DiscoveryWeights weights = DiscoveryWeights.standard,
    DateTime? now,
  }) {
    final today = MediaFreshnessRules.dateOnly(now ?? DateTime.now());
    final byKey = <String, ScoredCandidate>{};
    ScoredCandidate? admit(MediaItem item) {
      if (!_eligible(item, profile, today)) return null;
      final key = MediaCatalogFilter.key(item);
      final existing = byKey[key];
      // Keep whichever copy knows the title's genres.
      if (existing != null &&
          existing.item.genreIds.isEmpty &&
          item.genreIds.isNotEmpty) {
        return byKey[key] = ScoredCandidate._(item)
          ..sources.addAll(existing.sources);
      }
      return byKey[key] ??= ScoredCandidate._(item);
    }

    for (var seed = 0; seed < seedLists.length; seed++) {
      final seedKey = seedLists[seed].seed.key;
      final items = seedLists[seed].items;
      for (var rank = 0; rank < items.length; rank++) {
        if (MediaCatalogFilter.key(items[rank]) == seedKey) continue;
        admit(items[rank])?.sources.add((seed, rank));
      }
    }
    for (final item in pool) {
      admit(item);
    }

    for (final candidate in byKey.values) {
      final item = candidate.item;
      candidate
        ..genreMatch = genreMatch(profile, item.genreIds)
        ..seedRelevance = _seedRelevance(candidate, seedLists)
        ..quality = ((MediaDiscoveryRanking.weightedRating(item) - 5.5) / 3)
            .clamp(0.0, 1.0)
        ..popularity =
            (math.log(1 + math.max(item.popularity, 0)) / math.ln10 / 3).clamp(
              0.0,
              1.0,
            )
        ..typeFit = item.type == 'series'
            ? profile.seriesShare
            : 1 - profile.seriesShare;
      candidate.score =
          weights.genreAffinity * candidate.genreMatch +
          weights.seedRelevance * candidate.seedRelevance +
          weights.quality * candidate.quality +
          weights.popularity * candidate.popularity +
          weights.typeFit * candidate.typeFit;
    }
    return byKey.values.toList()..sort(_bestFirst);
  }

  static int _bestFirst(ScoredCandidate a, ScoredCandidate b) {
    final order = b.score.compareTo(a.score);
    return order != 0 ? order : a.key.compareTo(b.key);
  }

  static bool _eligible(MediaItem item, TasteProfile profile, DateTime today) {
    if (!MediaCatalogFilter.hasValidTmdbId(item)) return false;
    if (profile.excludedKeys.contains(MediaCatalogFilter.key(item))) {
      return false;
    }
    if (!MediaCatalogFilter.isMovie(item) &&
        !MediaCatalogFilter.isSuitableSeries(item, strict: false)) {
      return false;
    }
    final rating = double.tryParse(item.rating.trim());
    if (rating == null || rating < minRating || rating > 10) return false;
    if (item.voteCount < MediaDiscoveryRanking.relaxedVoteThreshold) {
      return false;
    }
    // Not out yet: nothing to watch.
    final released = MediaFreshnessRules.releaseDate(item);
    return released == null || !released.isAfter(today);
  }

  /// How well [genreIds] match the profile, from -1 to 1: mostly the best
  /// matching genre, partly the second, pulled down by a disliked one.
  static double genreMatch(TasteProfile profile, List<int> genreIds) {
    final values = [
      for (final id in TmdbGenres.expand(genreIds))
        profile.genreAffinity[id] ?? 0.0,
    ]..sort((a, b) => b.compareTo(a));
    if (values.isEmpty) return 0;
    final positive = values.where((value) => value > 0).toList();
    final best = positive.isEmpty
        ? 0.0
        : positive.length == 1
        ? .8 * positive[0]
        : .65 * positive[0] + .35 * positive[1];
    final worst = math.min(values.last, 0.0);
    return (best + .5 * worst).clamp(-1.0, 1.0);
  }

  static double _seedRelevance(
    ScoredCandidate candidate,
    List<SeedCandidates> seedLists,
  ) {
    if (candidate.sources.isEmpty) return 0;
    var best = 0.0;
    final seeds = <int>{};
    for (final (seed, rank) in candidate.sources) {
      seeds.add(seed);
      best = math.max(best, seedLists[seed].seed.weight / (1 + rank / 8));
    }
    // Recommended from several of the viewer's titles: a stronger match.
    return (best + .1 * (seeds.length - 1)).clamp(0.0, 1.0);
  }

  static bool _isExplore(ScoredCandidate c) =>
      c.genreMatch <= exploreMaxMatch && c.genreMatch >= -.1 && c.quality >= .5;

  static double _exploreRank(ScoredCandidate c) =>
      .5 * c.quality + .3 * c.seedRelevance + .2 * c.popularity;

  static DiscoverySection? _forYou(
    TasteProfile profile,
    List<ScoredCandidate> candidates,
    List<TasteSeed> seeds,
    DiscoveryWeights weights,
    Set<String> used,
  ) {
    final explore = candidates.where(_isExplore).toList()
      ..sort((a, b) {
        final order = _exploreRank(b).compareTo(_exploreRank(a));
        return order != 0 ? order : a.key.compareTo(b.key);
      });
    final exploreEvery = weights.exploreShare <= 0
        ? 0
        : math.max((1 / weights.exploreShare).round(), 2);
    final genreCap = math.max(2, (forYouSize * weights.maxGenreShare).ceil());
    final picked = <ScoredCandidate>[];
    final exploreKeys = <String>{};
    final perGenre = <int, int>{};
    final taken = <String>{};

    bool take(ScoredCandidate c) {
      if (!taken.add(c.key)) return false;
      picked.add(c);
      final primary = c.item.genreIds.firstOrNull;
      if (primary != null) perGenre[primary] = (perGenre[primary] ?? 0) + 1;
      return true;
    }

    var mainIndex = 0;
    while (picked.length < forYouSize) {
      final slot = picked.length + 1;
      if (exploreEvery > 0 && slot % exploreEvery == 0) {
        final next = explore.where((c) => !taken.contains(c.key)).firstOrNull;
        if (next != null && take(next)) {
          exploreKeys.add(next.key);
          continue;
        }
      }
      // The best title whose leading genre still has room in the row; a
      // genre over its share waits until nothing else is left.
      ScoredCandidate? next;
      for (var i = mainIndex; i < candidates.length; i++) {
        final c = candidates[i];
        if (taken.contains(c.key)) continue;
        final primary = c.item.genreIds.firstOrNull;
        if (primary == null || (perGenre[primary] ?? 0) < genreCap) {
          next = c;
          break;
        }
      }
      next ??= candidates.where((c) => !taken.contains(c.key)).firstOrNull;
      if (next == null) break;
      take(next);
      while (mainIndex < candidates.length &&
          taken.contains(candidates[mainIndex].key)) {
        mainIndex++;
      }
    }
    if (picked.length < minRowSize) return null;
    used.addAll(taken);
    final hasSeeds = seeds.isNotEmpty;
    return DiscoverySection(
      kind: DiscoverySectionKind.forYou,
      title: hasSeeds ? 'Recommended for you' : 'Picked for your genres',
      items: [for (final c in picked) c.item],
      reasons: {
        for (final c in picked)
          c.key: exploreKeys.contains(c.key)
              ? 'Something a little different'
              : _reason(profile, c, seeds),
      },
    );
  }

  /// The plainest true reason a title is recommended.
  static String _reason(
    TasteProfile profile,
    ScoredCandidate c,
    List<TasteSeed> seeds,
  ) {
    if (c.sources.isNotEmpty) {
      final (seed, _) = c.sources.reduce(
        (a, b) =>
            seeds[a.$1].weight / (1 + a.$2 / 8) >=
                seeds[b.$1].weight / (1 + b.$2 / 8)
            ? a
            : b,
      );
      return seedTitle(seeds[seed]);
    }
    final genre = _bestGenre(profile, c.item.genreIds);
    // Any clear match names the genre: a picked genre alone matches at
    // about 0.4, and that is exactly why the title is here.
    if (genre != null && c.genreMatch > exploreMaxMatch) {
      return 'Matches your taste for ${genre.toLowerCase()}';
    }
    return 'Well rated and popular right now';
  }

  static String? _bestGenre(TasteProfile profile, List<int> genreIds) {
    String? name;
    var best = 0.0;
    for (final id in genreIds) {
      final value = TmdbGenres.expand([
        id,
      ]).map((g) => profile.genreAffinity[g] ?? 0.0).fold(0.0, math.max);
      final label = TmdbGenres.nameOf(id);
      if (label != null && value > best) {
        best = value;
        name = label;
      }
    }
    return name;
  }

  /// A Because-you-watched row's title for [seed].
  static String seedTitle(TasteSeed seed) => switch (seed.origin) {
    SeedOrigin.watched => 'Because you watched ${seed.item.name}',
    SeedOrigin.saved => 'Because you saved ${seed.item.name}',
    SeedOrigin.asked => 'More like ${seed.item.name}',
  };

  static DiscoverySection? _becauseRow(
    SeedCandidates list,
    Map<String, ScoredCandidate> byKey,
    Set<String> used,
  ) {
    if (list.seed.item.name.trim().isEmpty) return null;
    final rows = <({ScoredCandidate c, double rank})>[];
    for (var rank = 0; rank < list.items.length; rank++) {
      final c = byKey[MediaCatalogFilter.key(list.items[rank])];
      if (c == null || used.contains(c.key)) continue;
      // Closeness to this title first, the viewer's tastes second.
      rows.add((c: c, rank: .55 / (1 + rank / 8) + .45 * c.score));
    }
    rows.sort((a, b) {
      final order = b.rank.compareTo(a.rank);
      return order != 0 ? order : a.c.key.compareTo(b.c.key);
    });
    final items = rows.take(rowSize).toList();
    if (items.length < minRowSize) return null;
    used.addAll(items.map((row) => row.c.key));
    final title = seedTitle(list.seed);
    return DiscoverySection(
      kind: DiscoverySectionKind.becauseYouWatched,
      title: title,
      seedKey: list.seed.key,
      items: [for (final row in items) row.c.item],
      reasons: {for (final row in items) row.c.key: title},
    );
  }

  static DiscoverySection? _genreRow(
    TasteProfile profile,
    List<ScoredCandidate> candidates,
    Set<String> used,
  ) {
    for (final genre in profile.topGenres.take(3)) {
      final name = TmdbGenres.nameOf(genre);
      if (name == null || (profile.genreAffinity[genre] ?? 0) < strongMatch) {
        continue;
      }
      final items = candidates
          .where(
            (c) =>
                !used.contains(c.key) &&
                TmdbGenres.expand(c.item.genreIds).contains(genre),
          )
          .take(rowSize)
          .toList();
      if (items.length < minRowSize) continue;
      used.addAll(items.map((c) => c.key));
      final title = 'Top picks in ${name.toLowerCase()}';
      return DiscoverySection(
        kind: DiscoverySectionKind.favoriteGenre,
        title: title,
        items: [for (final c in items) c.item],
        reasons: {
          for (final c in items)
            c.key: 'Matches your taste for ${name.toLowerCase()}',
        },
      );
    }
    return null;
  }

  static DiscoverySection? _differentRow(
    List<ScoredCandidate> candidates,
    Set<String> used,
  ) {
    final items =
        candidates.where((c) => !used.contains(c.key) && _isExplore(c)).toList()
          ..sort((a, b) {
            final order = _exploreRank(b).compareTo(_exploreRank(a));
            return order != 0 ? order : a.key.compareTo(b.key);
          });
    final row = items.take(rowSize).toList();
    if (row.length < minRowSize) return null;
    used.addAll(row.map((c) => c.key));
    return DiscoverySection(
      kind: DiscoverySectionKind.somethingDifferent,
      title: 'Something different',
      items: [for (final c in row) c.item],
      reasons: {for (final c in row) c.key: 'Something a little different'},
    );
  }
}
