// The records behind custom collections: folders (one level), collections
// and the titles in them, with the save times and deletion marks that let
// them be merged with another device's copy later. CollectionLibrary is a
// read-only snapshot of the live records with the lookups the pages need.

import '../models/media_item.dart';

/// A folder of collections. Folders hold collections only, not folders.
class CollectionFolder {
  const CollectionFolder({
    required this.id,
    required this.name,
    required this.order,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
  });

  final String id;
  final String name;

  /// Position among the folders, smallest first.
  final double order;

  /// Milliseconds since the epoch, on this device's clock.
  final int createdAt, updatedAt;

  /// Deleted, kept so another copy of the library cannot bring it back.
  final bool deleted;

  CollectionFolder copyWith({
    String? name,
    double? order,
    int? updatedAt,
    bool? deleted,
  }) => CollectionFolder(
    id: id,
    name: name ?? this.name,
    order: order ?? this.order,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'order': order,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (deleted) 'deleted': true,
  };

  /// Null when [json] is not a readable folder.
  static CollectionFolder? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    return CollectionFolder(
      id: id,
      name: name,
      order: _double(json['order']),
      createdAt: _int(json['createdAt']),
      updatedAt: _int(json['updatedAt']),
      deleted: json['deleted'] == true,
    );
  }
}

/// A collection the viewer made.
class MediaCollection {
  const MediaCollection({
    required this.id,
    required this.name,
    required this.order,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.folderId,
    this.cover = '',
    this.shared = false,
    this.deleted = false,
  });

  final String id;
  final String name;
  final String description;

  /// Friends may see it (Friends must be on; the server decides who).
  /// Private unless the owner shares it; a copy saved before sharing
  /// existed reads as private.
  final bool shared;

  /// The folder it is in; null at the top of the library.
  final String? folderId;

  /// `type:id` of the title whose artwork heads the collection; empty for
  /// the newest titles' posters.
  final String cover;

  /// Position among its folder's collections, smallest first.
  final double order;
  final int createdAt, updatedAt;
  final bool deleted;

  MediaCollection copyWith({
    String? name,
    String? description,
    String? Function()? folderId,
    String? cover,
    bool? shared,
    double? order,
    int? updatedAt,
    bool? deleted,
  }) => MediaCollection(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    folderId: folderId == null ? this.folderId : folderId(),
    cover: cover ?? this.cover,
    shared: shared ?? this.shared,
    order: order ?? this.order,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deleted: deleted ?? this.deleted,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    if (folderId != null) 'folderId': folderId,
    if (cover.isNotEmpty) 'cover': cover,
    if (shared) 'visibility': 'friends',
    'order': order,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    if (deleted) 'deleted': true,
  };

  static MediaCollection? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final folderId = json['folderId'];
    return MediaCollection(
      id: id,
      name: name,
      description: '${json['description'] ?? ''}',
      folderId: folderId is String && folderId.isNotEmpty ? folderId : null,
      cover: '${json['cover'] ?? ''}',
      shared: json['visibility'] == 'friends',
      order: _double(json['order']),
      createdAt: _int(json['createdAt']),
      updatedAt: _int(json['updatedAt']),
      deleted: json['deleted'] == true,
    );
  }
}

/// A movie or series in a collection: its TMDB id and kind, and what its
/// card shows, so a collection opens without asking TMDB for each title.
class CollectionEntry {
  const CollectionEntry({
    required this.collectionId,
    required this.type,
    required this.id,
    required this.name,
    required this.addedAt,
    required this.updatedAt,
    this.poster = '',
    this.background = '',
    this.year = '',
    this.removed = false,
  });

  /// From the title as the app shows it.
  factory CollectionEntry.of(String collectionId, MediaItem item, int at) =>
      CollectionEntry(
        collectionId: collectionId,
        type: item.type,
        id: item.id,
        name: item.name,
        poster: item.poster,
        background: item.background,
        year: item.year,
        addedAt: at,
        updatedAt: at,
      );

  final String collectionId;

  /// `movie` or `series`, with [id] the TMDB id.
  final String type, id;
  final String name, poster, background, year;
  final int addedAt, updatedAt;

  /// Taken out of the collection, kept so another copy cannot put it back.
  final bool removed;

  /// The title, the same for every collection it is in.
  String get titleKey => '$type:$id';

  /// One record per title per collection, so a title is never in a
  /// collection twice, on any device.
  String get key => keyOf(collectionId, type, id);

  static String keyOf(String collectionId, String type, String id) =>
      '$collectionId|$type:$id';

  /// The card to show, opening the title's details page like any other.
  MediaItem get item => MediaItem(
    id: id,
    type: type,
    name: name,
    poster: poster,
    background: background,
    year: year,
  );

  CollectionEntry copyWith({int? addedAt, int? updatedAt, bool? removed}) =>
      CollectionEntry(
        collectionId: collectionId,
        type: type,
        id: id,
        name: name,
        poster: poster,
        background: background,
        year: year,
        addedAt: addedAt ?? this.addedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        removed: removed ?? this.removed,
      );

  Map<String, dynamic> toJson() => {
    'collectionId': collectionId,
    'type': type,
    'id': id,
    'name': name,
    if (poster.isNotEmpty) 'poster': poster,
    if (background.isNotEmpty) 'background': background,
    if (year.isNotEmpty) 'year': year,
    'addedAt': addedAt,
    'updatedAt': updatedAt,
    if (removed) 'removed': true,
  };

  static CollectionEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final collectionId = json['collectionId'], type = json['type'];
    final id = json['id'];
    if (collectionId is! String ||
        collectionId.isEmpty ||
        (type != 'movie' && type != 'series') ||
        id is! String ||
        id.isEmpty) {
      return null;
    }
    return CollectionEntry(
      collectionId: collectionId,
      type: type as String,
      id: id,
      name: '${json['name'] ?? ''}',
      poster: '${json['poster'] ?? ''}',
      background: '${json['background'] ?? ''}',
      year: '${json['year'] ?? ''}',
      addedAt: _int(json['addedAt']),
      updatedAt: _int(json['updatedAt']),
      removed: json['removed'] == true,
    );
  }
}

/// How a collection's titles are listed.
enum CollectionSort {
  newest('Recently added'),
  oldest('First added'),
  title('Title'),
  year('Release year');

  const CollectionSort(this.label);
  final String label;
}

/// The live (not deleted) folders, collections and titles of one account,
/// read-only, with the lookups the library pages need.
class CollectionLibrary {
  CollectionLibrary({
    Iterable<CollectionFolder> folders = const [],
    Iterable<MediaCollection> collections = const [],
    Iterable<CollectionEntry> entries = const [],
  }) {
    final liveFolders = [
      for (final folder in folders)
        if (!folder.deleted) folder,
    ]..sort(_byOrder((f) => f.order, (f) => f.createdAt));
    final folderIds = {for (final folder in liveFolders) folder.id};
    final liveCollections = [
      for (final collection in collections)
        if (!collection.deleted)
          // A collection whose folder is gone shows at the top level.
          collection.folderId == null || folderIds.contains(collection.folderId)
              ? collection
              : collection.copyWith(folderId: () => null),
    ]..sort(_byOrder((c) => c.order, (c) => c.createdAt));
    final collectionIds = {for (final c in liveCollections) c.id};
    final byCollection = <String, List<CollectionEntry>>{};
    final byTitle = <String, Set<String>>{};
    for (final entry in entries) {
      if (entry.removed || !collectionIds.contains(entry.collectionId)) {
        continue;
      }
      byCollection.putIfAbsent(entry.collectionId, () => []).add(entry);
      byTitle.putIfAbsent(entry.titleKey, () => {}).add(entry.collectionId);
    }
    for (final list in byCollection.values) {
      list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    this.folders = List.unmodifiable(liveFolders);
    this.collections = List.unmodifiable(liveCollections);
    _entries = byCollection;
    _membership = byTitle;
  }

  static final empty = CollectionLibrary();

  late final List<CollectionFolder> folders;

  /// Every collection, in or out of a folder.
  late final List<MediaCollection> collections;
  late final Map<String, List<CollectionEntry>> _entries;
  late final Map<String, Set<String>> _membership;

  bool get isEmpty => folders.isEmpty && collections.isEmpty;

  /// The collections in [folderId], or at the top level for null.
  List<MediaCollection> collectionsIn(String? folderId) => [
    for (final collection in collections)
      if (collection.folderId == folderId) collection,
  ];

  MediaCollection? collection(String id) {
    for (final collection in collections) {
      if (collection.id == id) return collection;
    }
    return null;
  }

  CollectionFolder? folder(String id) {
    for (final folder in folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  int countOf(String collectionId) => _entries[collectionId]?.length ?? 0;

  /// The titles in [collectionId], newest first unless [sort] says other.
  List<CollectionEntry> entriesOf(
    String collectionId, {
    CollectionSort sort = CollectionSort.newest,
  }) {
    final list = [...?_entries[collectionId]];
    switch (sort) {
      case CollectionSort.newest:
        break;
      case CollectionSort.oldest:
        list.sort((a, b) => a.addedAt.compareTo(b.addedAt));
      case CollectionSort.title:
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case CollectionSort.year:
        // Newest release first; titles without a year last.
        list.sort((a, b) {
          if (a.year.isEmpty != b.year.isEmpty) return a.year.isEmpty ? 1 : -1;
          return b.year.compareTo(a.year);
        });
    }
    return list;
  }

  /// Ids of the collections [item] is in.
  Set<String> collectionsWith(MediaItem item) =>
      Set.unmodifiable(_membership['${item.type}:${item.id}'] ?? const {});

  /// Every title in any collection, once each, the latest addition first.
  List<CollectionEntry> get allEntries {
    final latest = <String, CollectionEntry>{};
    for (final list in _entries.values) {
      for (final entry in list) {
        final seen = latest[entry.titleKey];
        if (seen == null || entry.addedAt > seen.addedAt) {
          latest[entry.titleKey] = entry;
        }
      }
    }
    return latest.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
  }

  /// Posters for a collection's cover: its chosen title first, then the
  /// newest, up to [count].
  List<String> coverArtOf(MediaCollection collection, {int count = 4}) {
    final entries = _entries[collection.id] ?? const <CollectionEntry>[];
    final chosen = [
      for (final entry in entries)
        if (entry.titleKey == collection.cover) entry,
    ];
    return <String>{
      for (final entry in [...chosen, ...entries])
        if (entry.poster.isNotEmpty) entry.poster,
    }.take(count).toList();
  }
}

int Function(T, T) _byOrder<T>(
  double Function(T) order,
  int Function(T) created,
) => (a, b) {
  final byOrder = order(a).compareTo(order(b));
  return byOrder != 0 ? byOrder : created(a).compareTo(created(b));
};

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

double _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

/// Kinds of synced record.
enum SyncedKind { folder, collection, entry }

/// A record from another device, checked, with its times on this device's
/// clock. [fields] holds the rest as the API sent it; the store reads only
/// what it knows, with the right types.
class SyncedRecord {
  const SyncedRecord({
    required this.kind,
    required this.key,
    required this.at,
    this.deleted = false,
    this.createdAt = 0,
    this.addedAt = 0,
    this.fields = const {},
  });

  final SyncedKind kind;

  /// The folder or collection id, or the entry's `collectionId|type:id`.
  final String key;

  /// When the record last changed.
  final int at;
  final bool deleted;

  /// Folders and collections: when made. Entries: when added.
  final int createdAt, addedAt;
  final Map<String, Object?> fields;
}
