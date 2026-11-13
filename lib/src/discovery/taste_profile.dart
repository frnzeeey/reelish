// The viewer's tastes as numbers: how much each genre and each kind of
// title counts, which titles to build "Because you watched" rows from, and
// which titles not to recommend. Pure and deterministic; the weights live
// in DiscoveryWeights so they can be tuned without touching the rules.

import 'dart:math' as math;

import '../models/media_item.dart';
import 'discovery_data.dart';
import 'tmdb_genres.dart';
import 'viewing_activity.dart';

/// Every tunable number in personalised discovery, in one place. The
/// defaults are a starting point documented in
/// `docs/personalized-discovery/RECOMMENDATION_SCORING_MODEL.md`.
class DiscoveryWeights {
  const DiscoveryWeights({
    this.rewatched = 1.6,
    this.completed = 1.0,
    this.mostlyWatched = 0.75,
    this.inProgress = 0.4,
    this.abandoned = -0.35,
    this.seriesPerEpisode = 0.15,
    this.seriesEpisodeCap = 1.6,
    this.myList = 0.6,
    this.moreLikeThis = 1.3,
    this.alreadyWatched = 0.35,
    this.notInterestedGenrePenalty = 0.25,
    this.pickedGenreBoost = 0.5,
    this.recencyHalfLife = const Duration(days: 75),
    this.recencyFloor = 0.4,
    this.genreAffinity = 0.40,
    this.seedRelevance = 0.30,
    this.quality = 0.18,
    this.popularity = 0.05,
    this.typeFit = 0.07,
    this.exploreShare = 0.25,
    this.maxGenreShare = 0.4,
    this.maxSeeds = 4,
  });

  static const standard = DiscoveryWeights();

  // How much one title counts, by what the viewer did with it.
  final double rewatched, completed, mostlyWatched, inProgress, abandoned;

  /// Series: added per finished episode, up to [seriesEpisodeCap].
  final double seriesPerEpisode, seriesEpisodeCap;

  /// A title on My list (synced with the Trakt watchlist when on).
  final double myList;
  final double moreLikeThis, alreadyWatched;

  /// Taken from each genre of a title marked Not interested, before
  /// normalising. Affinity never goes below [minGenreAffinity], so a genre is
  /// never excluded by feedback alone.
  final double notInterestedGenrePenalty;

  /// Added to a genre the viewer picked in Settings.
  final double pickedGenreBoost;

  /// Older activity counts less, halving every [recencyHalfLife] down to
  /// [recencyFloor], so long-standing tastes are never forgotten and one
  /// recent title cannot outweigh them.
  final Duration recencyHalfLife;
  final double recencyFloor;

  // A candidate's score is the weighted sum of these 0–1 terms.
  final double genreAffinity, seedRelevance, quality, popularity, typeFit;

  /// Share of "Recommended for you" kept for titles outside the viewer's
  /// strongest genres.
  final double exploreShare;

  /// Most of a row one leading genre may take.
  final double maxGenreShare;

  /// Titles whose TMDB recommendations are fetched per refresh.
  final int maxSeeds;

  static const minGenreAffinity = -0.5;
}

/// Where a seed title's weight came from; names its row.
enum SeedOrigin { watched, saved, asked }

/// A title recommendations are built from.
class TasteSeed {
  const TasteSeed({
    required this.item,
    required this.weight,
    required this.origin,
  });

  final MediaItem item;

  /// 0–1, relative to the strongest seed.
  final double weight;
  final SeedOrigin origin;

  String get key => '${item.type}:${item.id}';
}

class TasteProfile {
  const TasteProfile({
    required this.genreAffinity,
    required this.seriesShare,
    required this.seeds,
    required this.excludedKeys,
    required this.signalCount,
  });

  static const none = TasteProfile(
    genreAffinity: {},
    seriesShare: .5,
    seeds: [],
    excludedKeys: {},
    signalCount: 0,
  );

  /// From [DiscoveryWeights.minGenreAffinity] to 1, by TMDB genre id. A
  /// genre not listed is neutral (0).
  final Map<int, double> genreAffinity;

  /// Share of the viewer's weight on series rather than movies, 0–1.
  final double seriesShare;

  /// Strongest first; at most [DiscoveryWeights.maxSeeds].
  final List<TasteSeed> seeds;

  /// Titles never recommended: started or finished, on My list, or given
  /// feedback that hides them.
  final Set<String> excludedKeys;

  /// Titles and picked genres the profile was built from. Zero means cold
  /// start: no personalised rows.
  final int signalCount;

  bool get isEmpty => signalCount == 0;

  /// Genres with a positive affinity, strongest first.
  List<int> get topGenres {
    final entries =
        genreAffinity.entries.where((entry) => entry.value > 0).toList()
          ..sort((a, b) {
            final order = b.value.compareTo(a.value);
            return order != 0 ? order : a.key.compareTo(b.key);
          });
    return [for (final entry in entries) entry.key];
  }

  static TasteProfile build(
    DiscoveryData data, {
    List<MediaItem> myList = const [],
    DiscoveryWeights weights = DiscoveryWeights.standard,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    double recency(DateTime at) {
      final days = math.max(today.difference(at).inHours / 24, 0);
      final decay = math.pow(.5, days / weights.recencyHalfLife.inDays);
      return weights.recencyFloor + (1 - weights.recencyFloor) * decay;
    }

    final genres = <int, double>{};
    void addGenres(Iterable<int> ids, double weight) {
      final expanded = TmdbGenres.expand(ids);
      if (expanded.isEmpty) return;
      // Spread over the title's genres, so a title tagged with six genres
      // does not count six times as much as one tagged with two.
      final each = weight / math.sqrt(expanded.length);
      for (final id in expanded) {
        genres[id] = (genres[id] ?? 0) + each;
      }
    }

    var movieWeight = 0.0, seriesWeight = 0.0;
    final seedWeights = <String, ({MediaItem item, double w, SeedOrigin o})>{};
    void addSeed(MediaItem item, double weight, SeedOrigin origin) {
      if (weight <= 0 || int.tryParse(item.id) == null) return;
      final key = '${item.type}:${item.id}';
      final existing = seedWeights[key];
      if (existing == null || existing.w < weight) {
        seedWeights[key] = (item: item, w: weight, o: origin);
      }
    }

    final excluded = <String>{};
    var signals = 0;

    for (final entry in data.activity.values) {
      final weight =
          _activityWeight(entry, weights, today) * recency(entry.lastWatched);
      signals++;
      // Anything started is in Continue watching or finished: either way
      // not a discovery.
      excluded.add(entry.key);
      addGenres(entry.genreIds, weight);
      if (weight > 0) {
        if (entry.isSeries) {
          seriesWeight += weight;
        } else {
          movieWeight += weight;
        }
      }
      addSeed(
        MediaItem(
          id: entry.id,
          type: entry.type,
          name: entry.name,
          poster: entry.poster,
          genreIds: entry.genreIds,
        ),
        weight,
        SeedOrigin.watched,
      );
    }

    for (final item in myList) {
      final key = '${item.type}:${item.id}';
      excluded.add(key);
      if (data.activity.containsKey(key)) continue;
      signals++;
      addGenres(item.genreIds, weights.myList);
      if (item.type == 'series') {
        seriesWeight += weights.myList;
      } else {
        movieWeight += weights.myList;
      }
      addSeed(item, weights.myList, SeedOrigin.saved);
    }

    for (final entry in data.feedback.values) {
      excluded.add(entry.key);
      final fade = recency(entry.at);
      switch (entry.kind) {
        case FeedbackKind.notInterested:
          addGenres(entry.genreIds, -weights.notInterestedGenrePenalty * fade);
        case FeedbackKind.alreadyWatched:
          signals++;
          addGenres(entry.genreIds, weights.alreadyWatched * fade);
        case FeedbackKind.moreLikeThis:
          signals++;
          final weight = weights.moreLikeThis * fade;
          addGenres(entry.genreIds, weight);
          addSeed(
            MediaItem(
              id: entry.id,
              type: entry.type,
              name: entry.name,
              genreIds: entry.genreIds,
            ),
            weight,
            SeedOrigin.asked,
          );
      }
    }

    // Normalise inferred affinity to the strongest genre, then add picked
    // genres on top so they count from the first day.
    final strongest = genres.values.fold(0.0, math.max);
    final affinity = <int, double>{
      for (final MapEntry(:key, :value) in genres.entries)
        key: strongest > 0 ? value / strongest : math.min(value, 0),
    };
    for (final id in TmdbGenres.expand(data.favoriteGenres)) {
      affinity[id] = (affinity[id] ?? 0) + weights.pickedGenreBoost;
    }
    signals += data.favoriteGenres.length;
    for (final key in affinity.keys.toList()) {
      affinity[key] = affinity[key]!.clamp(
        DiscoveryWeights.minGenreAffinity,
        1.0,
      );
    }

    return TasteProfile(
      genreAffinity: affinity,
      seriesShare: movieWeight + seriesWeight > 0
          ? seriesWeight / (movieWeight + seriesWeight)
          : .5,
      seeds: _pickSeeds(seedWeights.values, weights.maxSeeds),
      excludedKeys: excluded,
      signalCount: signals,
    );
  }

  static double _activityWeight(
    TitleActivity entry,
    DiscoveryWeights weights,
    DateTime now,
  ) {
    final status = entry.status(now: now);
    if (entry.isSeries) {
      if (status == ViewingStatus.abandoned) return weights.abandoned;
      return math.min(
        weights.inProgress + weights.seriesPerEpisode * entry.completedEpisodes,
        weights.seriesEpisodeCap,
      );
    }
    return switch (status) {
      ViewingStatus.rewatched => weights.rewatched,
      ViewingStatus.completed => weights.completed,
      ViewingStatus.mostlyWatched => weights.mostlyWatched,
      ViewingStatus.inProgress => weights.inProgress,
      ViewingStatus.abandoned => weights.abandoned,
    };
  }

  /// The strongest seeds, with both kinds of title when the viewer watches
  /// both: at most all but one seed may be of one kind while the other kind
  /// has a candidate.
  static List<TasteSeed> _pickSeeds(
    Iterable<({MediaItem item, double w, SeedOrigin o})> all,
    int count,
  ) {
    int strongestFirst(
      ({MediaItem item, double w, SeedOrigin o}) a,
      ({MediaItem item, double w, SeedOrigin o}) b,
    ) {
      final order = b.w.compareTo(a.w);
      return order != 0
          ? order
          : '${a.item.type}:${a.item.id}'.compareTo(
              '${b.item.type}:${b.item.id}',
            );
    }

    final ranked = all.toList()..sort(strongestFirst);
    if (ranked.isEmpty || count <= 0) return const [];
    final picked = <({MediaItem item, double w, SeedOrigin o})>[];
    final types = ranked.map((seed) => seed.item.type).toSet();
    for (final seed in ranked) {
      if (picked.length >= count) break;
      final sameType = picked.where((p) => p.item.type == seed.item.type);
      if (types.length > 1 && count > 1 && sameType.length >= count - 1) {
        continue;
      }
      picked.add(seed);
    }
    // Fill from what was skipped when the other kind ran out.
    for (final seed in ranked) {
      if (picked.length >= count) break;
      if (!picked.contains(seed)) picked.add(seed);
    }
    picked.sort(strongestFirst);
    final top = picked.first.w;
    return [
      for (final seed in picked)
        TasteSeed(item: seed.item, weight: seed.w / top, origin: seed.o),
    ];
  }
}
