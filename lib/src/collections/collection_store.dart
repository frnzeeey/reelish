// Custom collections and their folders for the signed-in account, kept in
// SharedPreferences under the account's own key and changed only through
// one write queue. Works offline; every record carries its save time, and
// deletions are kept as marks, so a later sync can merge copies safely.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../services/storage_service.dart';
import 'collection_models.dart';

/// A name or description the library cannot save.
class CollectionInputError implements Exception {
  const CollectionInputError(this.message);
  final String message;

  @override
  String toString() => message;
}

class CollectionStore extends ChangeNotifier {
  CollectionStore({int Function()? clock, Random? random})
    : _clock = clock ?? StorageService.clock,
      _random = random ?? Random.secure();

  /// The app's library, following the account [useAccount] names.
  static CollectionStore instance = CollectionStore();

  /// SharedPreferences key for [userId]'s library.
  static String storageKey(String userId) => 'onfeed.collections.v1.u.$userId';

  static const maxNameLength = 80;
  static const maxDescriptionLength = 300;

  /// Deletion marks older than this are dropped when the library is saved.
  static const tombstoneLifetime = Duration(days: 400);

  final int Function() _clock;
  final Random _random;

  String? _account;
  bool _loaded = false;
  Future<void>? _loading;
  Future<void>? _writes;

  Map<String, CollectionFolder> _folders = {};
  Map<String, MediaCollection> _collections = {};
  Map<String, CollectionEntry> _entries = {};
  CollectionLibrary _library = CollectionLibrary.empty;

  /// The live library; empty while signed out or before [ready].
  CollectionLibrary get library => _library;

  /// Whether the signed-in account's library has been read.
  bool get loaded => _loaded;

  /// The account whose library this is; null when signed out.
  String? get account => _account;

  /// Completes once the current account's library has been read.
  // The read is kept only while it runs: a completed future kept for ever
  // would be awaited from zones that did not create it (widget tests).
  Future<void> get ready => _loading ?? Future.value();

  /// Points the library at [userId], or empties it when signed out.
  void useAccount(String? userId) {
    if (userId == _account) return;
    _account = userId;
    _loaded = false;
    _folders = {};
    _collections = {};
    _entries = {};
    _library = CollectionLibrary.empty;
    notifyListeners();
    if (userId == null) {
      _loading = null;
      return;
    }
    final loading = _read(userId);
    _loading = loading;
    unawaited(
      loading.whenComplete(() {
        if (identical(_loading, loading)) _loading = null;
      }),
    );
  }

  Future<void> _read(String userId) async {
    Map<String, dynamic> decoded = const {};
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        storageKey(userId),
      );
      final value = raw == null ? null : jsonDecode(raw);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } on FormatException {
      // An unreadable library is left in place and treated as empty.
    }
    if (_account != userId) return;
    // Records that cannot be read are skipped; the rest still load.
    _folders = {
      for (final folder in _list(
        decoded['folders'],
      ).map(CollectionFolder.fromJson).whereType<CollectionFolder>())
        folder.id: folder,
    };
    _collections = {
      for (final collection in _list(
        decoded['collections'],
      ).map(MediaCollection.fromJson).whereType<MediaCollection>())
        collection.id: collection,
    };
    _entries = {
      for (final entry in _list(
        decoded['entries'],
      ).map(CollectionEntry.fromJson).whereType<CollectionEntry>())
        entry.key: entry,
    };
    _loaded = true;
    _publish();
  }

  static List<Object?> _list(Object? value) => value is List ? value : const [];

  void _publish() {
    _library = CollectionLibrary(
      folders: _folders.values,
      collections: _collections.values,
      entries: _entries.values,
    );
    notifyListeners();
  }

  /// Runs [change] after earlier changes and the library read, then saves
  /// the library of the account it was made for.
  Future<T> _change<T>(T Function(int now) change) {
    final account = _account;
    if (account == null) {
      return Future.error(
        const CollectionInputError('Sign in to use collections.'),
      );
    }
    final loading = ready;
    final result = (_writes ?? Future<void>.value()).then((_) async {
      await loading;
      if (_account != account) {
        throw const CollectionInputError('The account changed. Try again.');
      }
      final before = _records();
      final value = change(_clock());
      _publish();
      await _save(account);
      _tellChanged(account, before);
      return value;
    });
    // Kept only while changes are queued, like [ready].
    final queued = result.then<void>((_) {}, onError: (Object _) {});
    _writes = queued;
    unawaited(
      queued.whenComplete(() {
        if (identical(_writes, queued)) _writes = null;
      }),
    );
    return result;
  }

  Future<void> _save(String account) async {
    final cutoff = _clock() - tombstoneLifetime.inMilliseconds;
    _folders.removeWhere((_, f) => f.deleted && f.updatedAt < cutoff);
    _collections.removeWhere((_, c) => c.deleted && c.updatedAt < cutoff);
    _entries.removeWhere(
      (_, e) =>
          (e.removed && e.updatedAt < cutoff) ||
          // A deleted collection's titles go with it. A title whose
          // collection is not here yet (synced in another page) is kept.
          _collections[e.collectionId]?.deleted == true,
    );
    await (await SharedPreferences.getInstance()).setString(
      storageKey(account),
      jsonEncode({
        'v': 1,
        'folders': [for (final f in _folders.values) f.toJson()],
        'collections': [for (final c in _collections.values) c.toJson()],
        'entries': [for (final e in _entries.values) e.toJson()],
      }),
    );
  }

  // Sync

  /// Told after each change made on this device is saved: the records it
  /// changed, by [recordKey], with their save times. Set by the sync.
  static void Function(String account, Map<String, int> changed)?
  onRecordsChanged;

  /// One key per record, across kinds: `folder:<id>`, `collection:<id>`,
  /// `entry:<collectionId>|<type>:<id>`.
  static String folderKey(String id) => 'folder:$id';
  static String collectionKey(String id) => 'collection:$id';
  static String entryKey(String key) => 'entry:$key';

  /// Every record held, deletion marks included, by [recordKey].
  Map<String, Object> _records() => {
    for (final f in _folders.values) folderKey(f.id): f,
    for (final c in _collections.values) collectionKey(c.id): c,
    for (final e in _entries.values) entryKey(e.key): e,
  };

  static int _updatedAt(Object record) => switch (record) {
    CollectionFolder(:final updatedAt) => updatedAt,
    MediaCollection(:final updatedAt) => updatedAt,
    CollectionEntry(:final updatedAt) => updatedAt,
    _ => 0,
  };

  void _tellChanged(String account, Map<String, Object> before) {
    final hook = onRecordsChanged;
    if (hook == null) return;
    final changed = <String, int>{
      for (final MapEntry(:key, :value) in _records().entries)
        // Records are replaced, never edited, so a changed one is new.
        if (!identical(before[key], value)) key: _updatedAt(value),
    };
    if (changed.isNotEmpty) hook(account, changed);
  }

  /// Save times of every record of [account] held now, for a device's first
  /// sync. Empty when [account] is not the library's account.
  Future<Map<String, int>> recordTimes(String account) async {
    await ready;
    if (_account != account) return const {};
    return {
      for (final MapEntry(:key, :value) in _records().entries)
        key: _updatedAt(value),
    };
  }

  /// The record [key] of [account] as held now; null when it is not held.
  Object? record(String account, String key) =>
      _account == account ? _records()[key] : null;

  /// Applies records from other devices where they are newer than the copy
  /// held here, in one save; true when anything changed. Not reported to
  /// [onRecordsChanged]: they are not this device's changes.
  Future<bool> applySynced(String account, List<SyncedRecord> records) {
    if (_account != account || records.isEmpty) return Future.value(false);
    final loading = ready;
    final result = (_writes ?? Future<void>.value()).then((_) async {
      await loading;
      if (_account != account) return false;
      var changed = false;
      for (final record in records) {
        changed |= _apply(record);
      }
      if (!changed) return false;
      _publish();
      await _save(account);
      return true;
    });
    final queued = result.then<void>((_) {}, onError: (Object _) {});
    _writes = queued;
    unawaited(
      queued.whenComplete(() {
        if (identical(_writes, queued)) _writes = null;
      }),
    );
    return result;
  }

  bool _apply(SyncedRecord record) {
    final fields = record.fields;
    String text(String name) {
      final value = fields[name];
      return value is String ? value : '';
    }

    double number(String name) {
      final value = fields[name];
      return value is num && value.isFinite ? value.toDouble() : 0;
    }

    switch (record.kind) {
      case SyncedKind.folder:
        final held = _folders[record.key];
        if (held != null && held.updatedAt >= record.at) return false;
        _folders[record.key] = record.deleted
            ? (held ??
                      CollectionFolder(
                        id: record.key,
                        name: '',
                        order: 0,
                        createdAt: 0,
                        updatedAt: record.at,
                      ))
                  .copyWith(deleted: true, updatedAt: record.at)
            : CollectionFolder(
                id: record.key,
                name: text('name'),
                order: number('order'),
                createdAt: record.createdAt,
                updatedAt: record.at,
              );
      case SyncedKind.collection:
        final held = _collections[record.key];
        if (held != null && held.updatedAt >= record.at) return false;
        final folderId = text('folderId');
        _collections[record.key] = record.deleted
            ? (held ??
                      MediaCollection(
                        id: record.key,
                        name: '',
                        order: 0,
                        createdAt: 0,
                        updatedAt: record.at,
                      ))
                  .copyWith(deleted: true, updatedAt: record.at)
            : MediaCollection(
                id: record.key,
                name: text('name'),
                description: text('description'),
                folderId: folderId.isEmpty ? null : folderId,
                cover: text('cover'),
                shared: text('visibility') == 'friends',
                order: number('order'),
                createdAt: record.createdAt,
                updatedAt: record.at,
              );
      case SyncedKind.entry:
        final held = _entries[record.key];
        if (held != null && held.updatedAt >= record.at) return false;
        final split = record.key.indexOf('|');
        final title = record.key.substring(split + 1).split(':');
        _entries[record.key] = record.deleted
            ? (held ??
                      CollectionEntry(
                        collectionId: record.key.substring(0, split),
                        type: title[0],
                        id: title[1],
                        name: '',
                        addedAt: 0,
                        updatedAt: record.at,
                      ))
                  .copyWith(removed: true, updatedAt: record.at)
            : CollectionEntry(
                collectionId: record.key.substring(0, split),
                type: title[0],
                id: title[1],
                name: text('name'),
                poster: SyncedProgress.artwork(text('poster')),
                background: SyncedProgress.artwork(text('background')),
                year: text('year'),
                addedAt: record.addedAt,
                updatedAt: record.at,
              );
    }
    return true;
  }

  String _newId() => List.generate(
    12,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static String _name(String value) {
    final name = value.trim();
    if (name.isEmpty) throw const CollectionInputError('Enter a name.');
    if (name.length > maxNameLength) {
      throw const CollectionInputError(
        'Use a name of $maxNameLength characters or fewer.',
      );
    }
    return name;
  }

  static String _description(String value) {
    final description = value.trim();
    if (description.length > maxDescriptionLength) {
      throw const CollectionInputError(
        'Use a description of $maxDescriptionLength characters or fewer.',
      );
    }
    return description;
  }

  MediaCollection _liveCollection(String id) {
    final collection = _collections[id];
    if (collection == null || collection.deleted) {
      throw const CollectionInputError('That collection no longer exists.');
    }
    return collection;
  }

  CollectionFolder _liveFolder(String id) {
    final folder = _folders[id];
    if (folder == null || folder.deleted) {
      throw const CollectionInputError('That folder no longer exists.');
    }
    return folder;
  }

  double _endOrder(Iterable<double> orders) =>
      orders.fold<double>(0, (last, order) => max(last, order)) + 1;

  // Collections

  /// Creates a collection at the end of [folderId] (or the top level), and
  /// adds [first] to it when given.
  Future<MediaCollection> createCollection({
    required String name,
    String description = '',
    String? folderId,
    MediaItem? first,
  }) {
    final cleanName = _name(name), cleanDescription = _description(description);
    return _change((now) {
      if (folderId != null) _liveFolder(folderId);
      final collection = MediaCollection(
        id: _newId(),
        name: cleanName,
        description: cleanDescription,
        folderId: folderId,
        order: _endOrder(_library.collectionsIn(folderId).map((c) => c.order)),
        createdAt: now,
        updatedAt: now,
      );
      _collections[collection.id] = collection;
      if (first != null) {
        final entry = CollectionEntry.of(collection.id, first, now);
        _entries[entry.key] = entry;
      }
      return collection;
    });
  }

  Future<void> editCollection(
    String id, {
    required String name,
    String description = '',
  }) {
    final cleanName = _name(name), cleanDescription = _description(description);
    return _change((now) {
      final collection = _liveCollection(id);
      _collections[id] = collection.copyWith(
        name: cleanName,
        description: cleanDescription,
        updatedAt: now,
      );
    });
  }

  /// Uses [item]'s poster first on the collection's cover; null goes back
  /// to the newest titles.
  Future<void> setCover(String id, MediaItem? item) => _change((now) {
    final collection = _liveCollection(id);
    _collections[id] = collection.copyWith(
      cover: item == null ? '' : '${item.type}:${item.id}',
      updatedAt: now,
    );
  });

  /// Lets friends see the collection, or makes it private again.
  Future<void> setShared(String id, bool shared) => _change((now) {
    final collection = _liveCollection(id);
    if (collection.shared == shared) return;
    _collections[id] = collection.copyWith(shared: shared, updatedAt: now);
  });

  /// Moves a collection into [folderId], or to the top level for null, at
  /// the end of its new place.
  Future<void> moveCollection(String id, String? folderId) => _change((now) {
    final collection = _liveCollection(id);
    if (collection.folderId == folderId) return;
    if (folderId != null) _liveFolder(folderId);
    _collections[id] = collection.copyWith(
      folderId: () => folderId,
      order: _endOrder(_library.collectionsIn(folderId).map((c) => c.order)),
      updatedAt: now,
    );
  });

  /// Deletes a collection and the list of titles in it. The titles
  /// themselves, My list and the watch history are not touched.
  Future<void> deleteCollection(String id) => _change((now) {
    final collection = _collections[id];
    if (collection == null || collection.deleted) return;
    _collections[id] = collection.copyWith(deleted: true, updatedAt: now);
  });

  /// Moves a collection one place earlier (negative [by]) or later among
  /// the collections around it.
  Future<void> reorderCollection(String id, int by) => _change((now) {
    final collection = _liveCollection(id);
    final siblings = _library.collectionsIn(collection.folderId);
    final index = siblings.indexWhere((c) => c.id == id);
    final target = (index + by).clamp(0, siblings.length - 1);
    if (index < 0 || target == index) return;
    final other = siblings[target];
    // Swapping two positions changes only those two records.
    var mine = other.order, theirs = collection.order;
    if (mine == theirs) {
      mine = theirs + (by < 0 ? -.5 : .5);
    }
    _collections[id] = collection.copyWith(order: mine, updatedAt: now);
    _collections[other.id] = other.copyWith(order: theirs, updatedAt: now);
  });

  // Titles

  /// Puts [item] in [collectionId]. Adding a title already there changes
  /// nothing, so it is never listed twice.
  Future<void> add(MediaItem item, String collectionId) =>
      setMembership(item, add: {collectionId});

  Future<void> remove(MediaItem item, String collectionId) =>
      setMembership(item, remove: {collectionId});

  /// Adds [item] to the collections in [add] and takes it out of those in
  /// [remove], in one save.
  Future<void> setMembership(
    MediaItem item, {
    Set<String> add = const {},
    Set<String> remove = const {},
  }) {
    if (item.type != 'movie' && item.type != 'series' || item.id.isEmpty) {
      return Future.error(
        const CollectionInputError('This title cannot be saved.'),
      );
    }
    return _change((now) {
      // Checked first, so a missing collection changes nothing at all.
      add.forEach(_liveCollection);
      for (final collectionId in add) {
        final key = CollectionEntry.keyOf(collectionId, item.type, item.id);
        final existing = _entries[key];
        if (existing != null && !existing.removed) continue;
        _entries[key] = CollectionEntry.of(collectionId, item, now);
      }
      for (final collectionId in remove) {
        final key = CollectionEntry.keyOf(collectionId, item.type, item.id);
        final existing = _entries[key];
        if (existing == null || existing.removed) continue;
        _entries[key] = existing.copyWith(removed: true, updatedAt: now);
      }
    });
  }

  // Folders

  Future<CollectionFolder> createFolder(String name) {
    final cleanName = _name(name);
    return _change((now) {
      final folder = CollectionFolder(
        id: _newId(),
        name: cleanName,
        order: _endOrder(_library.folders.map((f) => f.order)),
        createdAt: now,
        updatedAt: now,
      );
      _folders[folder.id] = folder;
      return folder;
    });
  }

  Future<void> renameFolder(String id, String name) {
    final cleanName = _name(name);
    return _change((now) {
      _folders[id] = _liveFolder(id).copyWith(name: cleanName, updatedAt: now);
    });
  }

  /// Deletes a folder. Its collections move to the top level unless
  /// [withCollections] says to delete them too.
  Future<void> deleteFolder(String id, {bool withCollections = false}) =>
      _change((now) {
        final folder = _folders[id];
        if (folder == null || folder.deleted) return;
        var order = _endOrder(_library.collectionsIn(null).map((c) => c.order));
        for (final collection in _library.collectionsIn(id)) {
          _collections[collection.id] = withCollections
              ? collection.copyWith(deleted: true, updatedAt: now)
              : collection.copyWith(
                  folderId: () => null,
                  order: order++,
                  updatedAt: now,
                );
        }
        _folders[id] = folder.copyWith(deleted: true, updatedAt: now);
      });

  Future<void> reorderFolder(String id, int by) => _change((now) {
    final folder = _liveFolder(id);
    final siblings = _library.folders;
    final index = siblings.indexWhere((f) => f.id == id);
    final target = (index + by).clamp(0, siblings.length - 1);
    if (index < 0 || target == index) return;
    final other = siblings[target];
    var mine = other.order, theirs = folder.order;
    if (mine == theirs) mine = theirs + (by < 0 ? -.5 : .5);
    _folders[id] = folder.copyWith(order: mine, updatedAt: now);
    _folders[other.id] = other.copyWith(order: theirs, updatedAt: now);
  });

  /// Forgets the account and its library in memory (tests).
  @visibleForTesting
  void debugReset() {
    _account = null;
    _loaded = false;
    _loading = null;
    _writes = null;
    _folders = {};
    _collections = {};
    _entries = {};
    _library = CollectionLibrary.empty;
  }
}
