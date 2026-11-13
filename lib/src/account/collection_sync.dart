// Syncs custom collections across the signed-in account's devices through
// the Reelish API: records changed on this device wait in a per-account
// outbox and are pushed shortly after editing stops; records other devices
// changed are pulled and applied where newer. Editing never waits on it,
// and a failed sync never touches the local library.
// docs/custom-collections/COLLECTION_SYNC_STRATEGY.md.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../collections/collection_models.dart';
import '../collections/collection_store.dart';
import '../services/storage_service.dart';
import 'account_api.dart';
import 'account_controller.dart';
import 'backend_config.dart';

class CollectionSync {
  CollectionSync({
    AccountApi? api,
    this._store,
    this.idleDelay = const Duration(seconds: 10),
    this.retryBase = const Duration(seconds: 30),
    this.followLifecycle = true,
    int Function()? clock,
  }) : _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _clock = clock ?? (() => StorageService.clock());

  /// The app's sync, following [AccountController.instance] once attached.
  static CollectionSync instance = CollectionSync();

  /// SharedPreferences key:
  /// `{userId: {device, seq, cursor, offset, seeded, outbox: {record: at}}}`.
  static const storageKey = 'onfeed.collectionSync.v1';

  /// Records per push request (the API's limit).
  static const batchSize = 50;

  /// Pages read per pull; the rest follow on the next one.
  static const maxPagesPerPull = 20;

  /// Failed attempts retried with backoff before waiting for the next
  /// change, app start or return to the app.
  static const maxRetries = 8;

  static final _idPattern = RegExp(r'^[0-9a-f]{24}$');
  static final _entryPattern = RegExp(
    r'^[0-9a-f]{24}\|(movie|series):[1-9]\d{0,9}$',
  );
  static final _titlePattern = RegExp(r'^(movie|series):[1-9]\d{0,9}$');
  static final _yearPattern = RegExp(r'^\d{4}$');

  /// Once editing stops for this long, changes are pushed.
  final Duration idleDelay;

  /// The first retry's delay; it doubles up to 30 minutes.
  final Duration retryBase;

  /// Pushes when the app is hidden and pulls when it is shown again. Off in
  /// unit tests, which have no app lifecycle.
  final bool followLifecycle;

  final AccountApi _api;
  final CollectionStore? _store;
  final int Function() _clock;

  CollectionStore get _library => _store ?? CollectionStore.instance;

  AccountController? _account;
  String? _userId;
  _SyncState? _state;
  Future<void>? _loading;
  Timer? _idle, _retry;
  int _failures = 0;
  Future<void>? _running;
  bool _again = false, _againPull = false;
  int? _lastPull;
  AppLifecycleListener? _lifecycle;

  void attach(AccountController account) {
    _account?.removeListener(_accountChanged);
    _account = account..addListener(_accountChanged);
    CollectionStore.onRecordsChanged = _changed;
    if (followLifecycle) {
      _lifecycle?.dispose();
      _lifecycle = AppLifecycleListener(
        onHide: () => unawaited(flush()),
        onShow: () {
          final last = _lastPull;
          if (last == null || _clock() - last > 2 * 60 * 1000) {
            unawaited(sync());
          }
        },
      );
    }
    _accountChanged();
  }

  void dispose() {
    _account?.removeListener(_accountChanged);
    _lifecycle?.dispose();
    _idle?.cancel();
    _retry?.cancel();
    if (CollectionStore.onRecordsChanged == _changed) {
      CollectionStore.onRecordsChanged = null;
    }
  }

  void _accountChanged() {
    final userId = _account?.status == AccountStatus.signedIn
        ? _account?.userId
        : null;
    if (userId == _userId) return;
    _idle?.cancel();
    _retry?.cancel();
    _userId = userId;
    _state = null;
    _failures = 0;
    _lastPull = null;
    if (userId == null || _api.baseUrl == null) return;
    _loading = _load(userId).then((_) {
      if (_userId == userId) unawaited(sync());
    });
  }

  Future<void> _load(String userId) async {
    final all = await _readAll();
    if (_userId != userId) return;
    _state = _SyncState.fromJson(all[userId]) ?? _SyncState.fresh();
  }

  /// Recorded by [CollectionStore] after each change made on this device.
  void _changed(String account, Map<String, int> changed) =>
      unawaited(_enqueue(account, changed));

  Future<void> _enqueue(String account, Map<String, int> changed) async {
    await _loading;
    final state = _state;
    if (state == null || _userId != account) {
      // Made just as the account changed: it waits in that account's own
      // outbox for its next sign-in, never sent with another's token.
      final all = await _readAll();
      final stored = _SyncState.fromJson(all[account]) ?? _SyncState.fresh();
      _merge(stored.outbox, changed);
      all[account] = stored.toJson();
      return _writeAll(all);
    }
    _merge(state.outbox, changed);
    await _save(account, state);
    _idle?.cancel();
    _idle = Timer(idleDelay, () => unawaited(flush()));
  }

  static void _merge(Map<String, int> outbox, Map<String, int> changed) {
    for (final MapEntry(:key, :value) in changed.entries) {
      outbox[key] = max(value, outbox[key] ?? 0);
    }
  }

  /// Pushes waiting changes now, without pulling.
  Future<void> flush() async {
    if (_state?.outbox.isEmpty ?? true) return;
    return sync(pull: false);
  }

  /// Pushes waiting changes, then (with [pull]) applies what other devices
  /// changed. Calls during a sync run once more after it.
  Future<void> sync({bool pull = true}) {
    if (_running != null) {
      _again = true;
      _againPull |= pull;
      return _running!;
    }
    return _running = _loop(pull).whenComplete(() => _running = null);
  }

  Future<void> _loop(bool pull) async {
    var withPull = pull;
    do {
      _again = false;
      await _syncOnce(withPull);
      withPull = _againPull;
      _againPull = false;
    } while (_again);
  }

  Future<void> _syncOnce(bool pull) async {
    await _loading;
    final userId = _userId, account = _account, state = _state;
    if (userId == null || account == null || state == null) return;
    _idle?.cancel();
    _retry?.cancel();
    try {
      var token = await account.accessToken();
      if (token == null || _userId != userId) return;

      Future<T> withToken<T>(Future<T> Function(String token) call) async {
        try {
          return await call(token!);
        } on AccountApiException catch (error) {
          if (!error.isUnauthorized) rethrow;
          token = await account.accessToken(forceRefresh: true);
          if (token == null) rethrow;
          return call(token!);
        }
      }

      if (!state.seeded) {
        // Everything made here before this device first synced.
        for (final MapEntry(:key, :value) in (await _library.recordTimes(
          userId,
        )).entries) {
          state.outbox.putIfAbsent(key, () => value);
        }
      }
      if (pull || !state.seeded) await _pull(userId, state, withToken);
      await _push(userId, state, withToken);
      if (!state.seeded && _userId == userId) {
        state.seeded = true;
        await _save(userId, state);
      }
      _failures = 0;
    } on AccountApiException catch (error) {
      if (error.isUnauthorized || _userId != userId) return;
      _scheduleRetry(pull);
    } catch (_) {
      if (_userId == userId) _scheduleRetry(pull);
    }
  }

  void _scheduleRetry(bool pull) {
    _failures++;
    if (_failures > maxRetries) return;
    final delay = retryBase * pow(2, _failures - 1).toInt();
    const cap = Duration(minutes: 30);
    _retry = Timer(
      delay > cap ? cap : delay,
      () => unawaited(sync(pull: pull)),
    );
  }

  int _toServer(_SyncState state, int localAt) =>
      localAt <= 0 ? 0 : max(0, localAt + state.offset);

  int _toLocal(_SyncState state, int serverAt) =>
      serverAt <= 0 ? 0 : serverAt - state.offset;

  void _measure(_SyncState state, int sent, int serverTime) {
    if (serverTime <= 0) return;
    final received = _clock();
    state.offset = serverTime - (sent + received) ~/ 2;
  }

  Future<void> _push(
    String userId,
    _SyncState state,
    Future<T> Function<T>(Future<T> Function(String token) call) withToken,
  ) async {
    if (state.outbox.isEmpty) return;
    final pending = Map.of(state.outbox);
    final keys = pending.keys.toList();
    for (var i = 0; i < keys.length; i += batchSize) {
      final batch = keys.skip(i).take(batchSize).toList();
      final changes = <Map<String, Object?>>[
        for (final key in batch) ?_changeFor(userId, key, state),
      ];
      if (changes.isNotEmpty) {
        final sent = _clock();
        final serverTime = await withToken(
          (token) => _api.pushCollections(
            token,
            device: state.device,
            changes: changes,
          ),
        );
        _measure(state, sent, serverTime);
      }
      if (_userId != userId) return;
      // Sent; a record changed again meanwhile waits for the next push.
      for (final key in batch) {
        if (state.outbox[key] == pending[key]) state.outbox.remove(key);
      }
      await _save(userId, state);
    }
  }

  /// The record as the API takes it, from what is held now; null when it
  /// is no longer held (a deleted collection's titles, dropped with it).
  Map<String, Object?>? _changeFor(
    String userId,
    String key,
    _SyncState state,
  ) {
    final record = _library.record(userId, key);
    if (record == null) return null;
    final seq = ++state.seq;
    String clip(String value, int length) =>
        value.length > length ? value.substring(0, length) : value;
    switch (record) {
      case CollectionFolder():
        return {
          'kind': 'folder',
          'key': record.id,
          if (record.deleted)
            'deleted': true
          else ...{
            'name': clip(record.name, CollectionStore.maxNameLength),
            'order': record.order,
            'createdAt': _toServer(state, record.createdAt),
          },
          'seq': seq,
          'at': _toServer(state, record.updatedAt),
        };
      case MediaCollection():
        return {
          'kind': 'collection',
          'key': record.id,
          if (record.deleted)
            'deleted': true
          else ...{
            'name': clip(record.name, CollectionStore.maxNameLength),
            if (record.description.isNotEmpty)
              'description': clip(
                record.description,
                CollectionStore.maxDescriptionLength,
              ),
            'folderId': ?record.folderId,
            if (_titlePattern.hasMatch(record.cover)) 'cover': record.cover,
            // Always said, so the server tells this app's "private" from an
            // older app that does not know about sharing.
            'visibility': record.shared ? 'friends' : 'private',
            'order': record.order,
            'createdAt': _toServer(state, record.createdAt),
          },
          'seq': seq,
          'at': _toServer(state, record.updatedAt),
        };
      case CollectionEntry():
        final poster = SyncedProgress.artwork(record.poster);
        final background = SyncedProgress.artwork(record.background);
        return {
          'kind': 'entry',
          'key': record.key,
          if (record.removed)
            'deleted': true
          else ...{
            if (record.name.trim().isNotEmpty)
              'name': clip(record.name.trim(), 300),
            if (poster.isNotEmpty) 'poster': poster,
            if (background.isNotEmpty) 'background': background,
            if (_yearPattern.hasMatch(record.year)) 'year': record.year,
            'addedAt': _toServer(state, record.addedAt),
          },
          'seq': seq,
          'at': _toServer(state, record.updatedAt),
        };
    }
    return null;
  }

  Future<void> _pull(
    String userId,
    _SyncState state,
    Future<T> Function<T>(Future<T> Function(String token) call) withToken,
  ) async {
    for (var page = 0; page < maxPagesPerPull; page++) {
      final sent = _clock();
      final since = state.cursor;
      final result = await withToken(
        (token) => _api.pullCollections(token, since),
      );
      if (_userId != userId) return;
      _measure(state, sent, result.serverTime);
      final records = <SyncedRecord>[];
      for (final row in result.items) {
        final record = _remote(row, state);
        if (record == null) continue;
        final outboxKey = switch (record.kind) {
          SyncedKind.folder => CollectionStore.folderKey(record.key),
          SyncedKind.collection => CollectionStore.collectionKey(record.key),
          SyncedKind.entry => CollectionStore.entryKey(record.key),
        };
        final waiting = state.outbox[outboxKey];
        // A newer change made here wins; it is pushed next.
        if (waiting != null && waiting >= record.at) continue;
        state.outbox.remove(outboxKey);
        records.add(record);
      }
      await _library.applySynced(userId, records);
      state.cursor = result.cursor;
      await _save(userId, state);
      if (!result.more) break;
    }
    _lastPull = _clock();
  }

  /// A pulled row, checked: it is remote data. Rows this device sent are
  /// skipped (it already holds them).
  SyncedRecord? _remote(Map<String, dynamic> row, _SyncState state) {
    if (row['device'] == state.device) return null;
    final kind = switch (row['kind']) {
      'folder' => SyncedKind.folder,
      'collection' => SyncedKind.collection,
      'entry' => SyncedKind.entry,
      _ => null,
    };
    final key = row['key'];
    final at = row['at'];
    if (kind == null || key is! String || at is! int || at < 0) return null;
    final valid = kind == SyncedKind.entry
        ? _entryPattern.hasMatch(key)
        : _idPattern.hasMatch(key);
    if (!valid) return null;
    final deleted = row['deleted'] == true;
    String? text(String name, int length, [RegExp? pattern]) {
      final value = row[name];
      if (value is! String || value.length > length) return null;
      return pattern == null || pattern.hasMatch(value) ? value : null;
    }

    int time(String name) {
      final value = row[name];
      return value is int && value > 0 ? _toLocal(state, value) : 0;
    }

    final order = row['order'];
    if (!deleted && kind != SyncedKind.entry) {
      // A folder or collection without a name is not shown, so not taken.
      final name = text('name', CollectionStore.maxNameLength);
      if (name == null || name.trim().isEmpty) return null;
    }
    return SyncedRecord(
      kind: kind,
      key: key,
      at: _toLocal(state, at),
      deleted: deleted,
      createdAt: time('createdAt'),
      addedAt: time('addedAt'),
      fields: {
        'name': ?text(
          'name',
          kind == SyncedKind.entry ? 300 : CollectionStore.maxNameLength,
        ),
        'description': ?text(
          'description',
          CollectionStore.maxDescriptionLength,
        ),
        'folderId': ?text('folderId', 24, _idPattern),
        'cover': ?text('cover', 30, _titlePattern),
        if (row['visibility'] == 'friends') 'visibility': 'friends',
        'poster': ?text('poster', 300),
        'background': ?text('background', 300),
        'year': ?text('year', 4, _yearPattern),
        if (order is num && order.isFinite && order.abs() <= 1e9)
          'order': order,
      },
    );
  }

  Future<Map<String, dynamic>> _readAll() async {
    final raw = (await SharedPreferences.getInstance()).getString(storageKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> all) async =>
      (await SharedPreferences.getInstance()).setString(
        storageKey,
        jsonEncode(all),
      );

  Future<void> _save(String userId, _SyncState state) async {
    final all = await _readAll();
    all[userId] = state.toJson();
    await _writeAll(all);
  }
}

/// One account's collection sync state on this device.
class _SyncState {
  _SyncState({
    required this.device,
    this.seq = 0,
    this.cursor = 0,
    this.offset = 0,
    this.seeded = false,
    Map<String, int>? outbox,
  }) : outbox = outbox ?? {};

  /// This device, for this account: random, never a hardware identifier.
  final String device;

  /// Counts every record sent from [device]; the server orders this
  /// device's own changes by it.
  int seq;

  /// Where the next pull starts (server time).
  int cursor;

  /// Server clock minus this device's clock, from the last request.
  int offset;

  /// Whether what this device held before its first sync was sent.
  bool seeded;

  /// Records changed here and not yet sent, with the time of the change.
  final Map<String, int> outbox;

  static _SyncState fresh() {
    final random = Random.secure();
    final device = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return _SyncState(device: device);
  }

  static _SyncState? fromJson(Object? json) {
    if (json is! Map) return null;
    final device = json['device'];
    if (device is! String ||
        !RegExp(r'^[A-Za-z0-9-]{8,64}$').hasMatch(device)) {
      return null;
    }
    int number(Object? value) => value is int ? value : 0;
    final outbox = json['outbox'];
    return _SyncState(
      device: device,
      seq: number(json['seq']),
      cursor: number(json['cursor']),
      offset: number(json['offset']),
      seeded: json['seeded'] == true,
      outbox: {
        if (outbox is Map)
          for (final MapEntry(:key, :value) in outbox.entries)
            if (value is int) '$key': value,
      },
    );
  }

  Map<String, Object> toJson() => {
    'device': device,
    'seq': seq,
    'cursor': cursor,
    'offset': offset,
    'seeded': seeded,
    'outbox': outbox,
  };
}
