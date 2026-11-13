// Collections the library fills by itself, from what is already saved: My
// list, the custom collections and the watch history. Nothing is copied;
// each list is worked out again from those when they change.

import '../models/episode_progress.dart';
import '../models/media_item.dart';
import '../models/resume_summary.dart';
import 'collection_models.dart';

enum SmartCollection {
  recentlyAdded(
    'Recently added',
    'Saved to My list or a collection in the last 30 days',
  ),
  myList('My list', 'Everything on My list'),
  unwatched('Not started', 'Saved titles you have not started'),
  finished('Finished', 'Titles you watched to the end');

  const SmartCollection(this.label, this.description);

  final String label;
  final String description;
}

/// What the smart collections are made from.
class SmartCollectionSources {
  SmartCollectionSources({
    this.favorites = const [],
    this.history = const [],
    this.seriesProgress = const {},
    CollectionLibrary? collections,
  }) : collections = collections ?? CollectionLibrary.empty;

  /// My list, newest first.
  final List<MediaItem> favorites;

  /// The watch history, most recent first.
  final List<MediaItem> history;

  /// Episode progress of the series in [history], by `type:id`.
  final Map<String, SeriesProgress> seriesProgress;

  /// The custom collections.
  final CollectionLibrary collections;
}

abstract final class SmartCollections {
  /// How far back Recently added looks.
  static const recentWindow = Duration(days: 30);

  /// The most Recently added lists.
  static const recentLimit = 60;

  /// Playback shorter than this does not count as starting a title, so a
  /// failed or abandoned start leaves it Not started.
  static const startedAfter = Duration(seconds: 90);

  /// The titles in [kind], in the order the page lists them.
  static List<MediaItem> of(
    SmartCollection kind,
    SmartCollectionSources sources, {
    required int now,
  }) => switch (kind) {
    SmartCollection.recentlyAdded => _recentlyAdded(sources, now),
    SmartCollection.myList => sources.favorites,
    SmartCollection.unwatched => _unwatched(sources),
    SmartCollection.finished => _finished(sources),
  };

  /// Every saved title once, with when it was saved (0 when unknown): My
  /// list and the collections, the latest save first.
  static List<({MediaItem item, int at})> _saved(
    SmartCollectionSources sources,
  ) {
    final saved = <String, ({MediaItem item, int at})>{};
    void offer(MediaItem item, int at) {
      final key = '${item.type}:${item.id}';
      final seen = saved[key];
      if (seen == null || at > seen.at) saved[key] = (item: item, at: at);
    }

    for (final item in sources.favorites) {
      offer(item, item.savedAt);
    }
    for (final entry in sources.collections.allEntries) {
      offer(entry.item, entry.addedAt);
    }
    // Ties (undated My list titles) keep the order they were offered in.
    final list = saved.values.toList();
    final position = {for (final (i, s) in list.indexed) s.item: i};
    return list..sort((a, b) {
      final byTime = b.at.compareTo(a.at);
      return byTime != 0
          ? byTime
          : position[a.item]!.compareTo(position[b.item]!);
    });
  }

  static List<MediaItem> _recentlyAdded(
    SmartCollectionSources sources,
    int now,
  ) {
    final since = now - recentWindow.inMilliseconds;
    return [
      for (final saved in _saved(sources))
        if (saved.at > 0 && saved.at >= since) saved.item,
    ].take(recentLimit).toList();
  }

  /// Titles the history shows real viewing of, not a failed start: a
  /// position past [startedAfter], or a series episode watched that far.
  static Set<String> _started(SmartCollectionSources sources) {
    final threshold = startedAfter.inMilliseconds;
    return {
      for (final item in sources.history)
        if (item.resumeMs >= threshold ||
            (sources.seriesProgress['${item.type}:${item.id}']?.episodes.values
                    .any((episode) => episode.positionMs >= threshold) ??
                false))
          '${item.type}:${item.id}',
    };
  }

  static List<MediaItem> _unwatched(SmartCollectionSources sources) {
    final started = _started(sources);
    return [
      for (final saved in _saved(sources))
        if (!started.contains('${saved.item.type}:${saved.item.id}'))
          saved.item,
    ];
  }

  static List<MediaItem> _finished(SmartCollectionSources sources) => [
    for (final item in sources.history)
      if (item.resumeMs > 0 &&
          !ResumeSummary.continues(
            item,
            series: sources.seriesProgress['${item.type}:${item.id}'],
          ))
        item,
  ];
}

/// What a collections page shows: a smart collection, one of the viewer's
/// collections, or a folder of them.
sealed class CollectionTarget {
  const CollectionTarget();
}

class SmartTarget extends CollectionTarget {
  const SmartTarget(this.kind);
  final SmartCollection kind;
}

class CustomTarget extends CollectionTarget {
  const CustomTarget(this.id);
  final String id;
}

class FolderTarget extends CollectionTarget {
  const FolderTarget(this.id);
  final String id;
}
