// Syncs playback progress across the signed-in account's devices through
// the Reelish API: changes saved on this device wait in a per-account outbox
// and are pushed when playback settles; rows other devices changed are
// pulled and applied where newer. Playback never waits on it, and a failed
// sync never touches local progress.
// docs/intelligent-continue-watching/CROSS_DEVICE_SYNC_STRATEGY.md.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/episode_progress.dart';
import '../models/media_item.dart';
import '../services/storage_service.dart';
import 'account_api.dart';
import 'account_controller.dart';
import 'backend_config.dart';

class ProgressSync {
  ProgressSync({
    AccountApi? api,
    StorageService? storage,
    this.idleDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(minutes: 15),
    this.retryBase = const Duration(seconds: 30),
    this.followLifecycle = true,
    int Function()? clock,
  }) : _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _storage = storage ?? StorageService(),
       _clock = clock ?? (() => StorageService.clock());

  /// The app's sync, following [AccountController.instance] once attached.
  static ProgressSync instance = ProgressSync();

  /// SharedPreferences key:
  /// `{userId: {device, seq, cursor, offset, seeded, outbox: {key: at}}}`.
  static const storageKey = 'onfeed.progressSync.v1';

  /// Changes per push request (the API's limit).
  static const batchSize = 50;

  /// Pages read per pull; the rest follow on the next one.
  static const maxPagesPerPull = 10;

  /// Failed attempts retried with backoff before waiting for the next
  /// change, app start or return to the app.
  static const maxRetries = 8;

  static final _keyPattern = RegExp(
    r'^(movie:[1-9]\d{0,9}|series:[1-9]\d{0,9}|episode:[1-9]\d{0,9}:\d{1,4}:\d{1,5})$',
  );

  /// Bumped when progress from another device was applied, so screens
  /// showing Continue watching read it again.
  static final revision = ValueNotifier<int>(0);

  /// After playback settles (no save for this long), changes are pushed.
  final Duration idleDelay;

  /// While saves keep coming (a long film), changes are pushed at least
  /// this often.
  final Duration maxDelay;

  /// The first retry's delay; it doubles up to 30 minutes.
  final Duration retryBase;

  /// Pushes when the app is hidden and pulls when it is shown again. Off in
  /// unit tests, which have no app lifecycle.
  final bool followLifecycle;

  final AccountApi _api;
  final StorageService _storage;
  final int Function() _clock;

  AccountController? _account;
  String? _userId;
  _SyncState? _state;
  Future<void>? _loading;
  Timer? _idle, _max, _retry;
  int _failures = 0;
  Future<void>? _running;
  bool _again = false, _againPull = false;
  int? _lastPull;
  AppLifecycleListener? _lifecycle;

  void attach(AccountController account) {
    _account?.removeListener(_accountChanged);
    _account = account..addListener(_accountChanged);
    StorageService.onProgressChanged = _changed;
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
    _cancelTimers();
    if (StorageService.onProgressChanged == _changed) {
      StorageService.onProgressChanged = null;
    }
  }

  void _cancelTimers() {
    _idle?.cancel();
    _max?.cancel();
    _retry?.cancel();
    _idle = _max = _retry = null;
  }

  void _accountChanged() {
    final userId = _account?.status == AccountStatus.signedIn
        ? _account?.userId
        : null;
    if (userId == _userId) return;
    _cancelTimers();
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

  /// Recorded by [StorageService] for each change made on this device.
  void _changed(String account, String key, int at) {
    if (!_keyPattern.hasMatch(key)) return;
    if (account != _userId) {
      // Saved just as the account changed: it waits in that account's own
      // outbox for its next sign-in, never sent with another's token.
      unawaited(_enqueueStored(account, key, at));
      return;
    }
    unawaited(_enqueue(account, key, at));
  }

  Future<void> _enqueue(String account, String key, int at) async {
    await _loading;
    final state = _state;
    if (state == null || _userId != account) {
      return _enqueueStored(account, key, at);
    }
    final known = state.outbox.containsKey(key);
    state.outbox[key] = max(at, state.outbox[key] ?? 0);
    // Written when a title first waits (rare), not on every checkpoint: the
    // saved progress itself already holds the latest position.
    if (!known) await _save(account, state);
    _schedule();
  }

  Future<void> _enqueueStored(String account, String key, int at) async {
    final all = await _readAll();
    final state = _SyncState.fromJson(all[account]) ?? _SyncState.fresh();
    state.outbox[key] = max(at, state.outbox[key] ?? 0);
    all[account] = state.toJson();
    await _writeAll(all);
  }

  void _schedule() {
    _idle?.cancel();
    _idle = Timer(idleDelay, () => unawaited(flush()));
    _max ??= Timer(maxDelay, () => unawaited(flush()));
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
    _max?.cancel();
    _idle = _max = null;
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

      if (!state.seeded) await _seed(state);
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
      // Unreadable local data or an unexpected reply: try again later.
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

  /// Before the first sync of an account on this device, everything it
  /// already holds waits to be sent. Kept progress without a save time
  /// (from before sync) goes with time 0, so it fills gaps on the server
  /// but never replaces another device's progress.
  Future<void> _seed(_SyncState state) async {
    for (final item in await _storage.history()) {
      final key = '${item.type}:${item.id}';
      if (_keyPattern.hasMatch(key)) {
        state.outbox.putIfAbsent(key, () => item.progressAt);
      }
    }
    for (final MapEntry(:key, :value)
        in (await _storage.allSeriesProgress()).entries) {
      final id = key.substring('series:'.length);
      for (final MapEntry(key: episode, value: progress)
          in value.episodes.entries) {
        final change = 'episode:$id:$episode';
        if (_keyPattern.hasMatch(change)) {
          state.outbox.putIfAbsent(change, () => progress.at);
        }
      }
    }
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
    final history = await _storage.history();
    final series = await _storage.allSeriesProgress();
    final pending = Map.of(state.outbox);
    final keys = pending.keys.toList();
    for (var i = 0; i < keys.length; i += batchSize) {
      final batch = keys.skip(i).take(batchSize).toList();
      final changes = <Map<String, Object?>>[];
      for (final key in batch) {
        final change = _changeFor(key, pending[key]!, state, history, series);
        if (change != null) changes.add(change);
      }
      if (changes.isNotEmpty) {
        final sent = _clock();
        final serverTime = await withToken(
          (token) =>
              _api.pushProgress(token, device: state.device, changes: changes),
        );
        _measure(state, sent, serverTime);
      }
      if (_userId != userId) return;
      // Sent; a title saved again meanwhile waits for the next push.
      for (final key in batch) {
        if (state.outbox[key] == pending[key]) state.outbox.remove(key);
      }
      await _save(userId, state);
    }
  }

  Map<String, Object?>? _changeFor(
    String key,
    int queuedAt,
    _SyncState state,
    List<MediaItem> history,
    Map<String, SeriesProgress> series,
  ) {
    final parts = key.split(':');
    final seq = ++state.seq;
    if (parts.first == 'episode') {
      final progress = series['series:${parts[1]}'];
      final season = int.parse(parts[2]), episode = int.parse(parts[3]);
      final saved = progress?.of(season, episode);
      if (progress == null || saved == null) return null;
      final last = progress.last;
      final next = last?.season == season && last?.episode == episode
          ? progress.next
          : null;
      return {
        'key': key,
        'positionMs': saved.positionMs,
        'durationMs': saved.durationMs,
        if (next != null) 'next': [next.season, next.episode],
        'seq': seq,
        'at': _toServer(state, saved.at),
      };
    }
    final item = history
        .where((e) => e.type == parts[0] && e.id == parts[1])
        .firstOrNull;
    if (item == null) {
      // Removed here; a removal with no time is from before sync.
      if (queuedAt <= 0) return null;
      return {
        'key': key,
        'removed': true,
        'seq': seq,
        'at': _toServer(state, queuedAt),
      };
    }
    final poster = SyncedProgress.artwork(item.poster);
    final backdrop = SyncedProgress.artwork(item.background);
    final title = item.name.trim();
    return {
      'key': key,
      'positionMs': item.resumeMs.clamp(0, _maxMediaMs),
      'durationMs': item.durationMs.clamp(0, _maxMediaMs),
      if (title.isNotEmpty)
        'title': title.length > 300 ? title.substring(0, 300) : title,
      if (RegExp(r'^\d{4}$').hasMatch(item.year)) 'year': item.year,
      if (poster.isNotEmpty) 'poster': poster,
      if (backdrop.isNotEmpty) 'backdrop': backdrop,
      'seq': seq,
      'at': _toServer(state, item.progressAt),
    };
  }

  static const _maxMediaMs = 24 * 60 * 60 * 1000;

  Future<void> _pull(
    String userId,
    _SyncState state,
    Future<T> Function<T>(Future<T> Function(String token) call) withToken,
  ) async {
    var changed = false;
    for (var page = 0; page < maxPagesPerPull; page++) {
      final sent = _clock();
      final since = state.cursor;
      final result = await withToken(
        (token) => _api.pullProgress(token, since),
      );
      if (_userId != userId) return;
      _measure(state, sent, result.serverTime);
      final changes = <SyncedProgress>[];
      for (final row in result.items) {
        final change = _remote(row, state);
        if (change == null) continue;
        final waiting = state.outbox[change.key];
        // A newer change made here wins; it is pushed next.
        if (waiting != null && waiting >= change.at && waiting > 0) continue;
        state.outbox.remove(change.key);
        changes.add(change);
      }
      if (changes.isNotEmpty && await _storage.applySynced(changes)) {
        changed = true;
      }
      state.cursor = result.cursor;
      await _save(userId, state);
      if (!result.more) break;
    }
    _lastPull = _clock();
    if (changed && _userId == userId) revision.value++;
  }

  /// A pulled row, checked: it is remote data. Rows this device sent are
  /// skipped (it already holds them).
  SyncedProgress? _remote(Map<String, dynamic> row, _SyncState state) {
    final key = row['key'];
    if (key is! String || !_keyPattern.hasMatch(key)) return null;
    if (row['device'] == state.device) return null;
    int? count(Object? value) =>
        value is int && value >= 0 && value <= _maxMediaMs ? value : null;
    final position = count(row['positionMs']);
    final duration = count(row['durationMs']);
    final at = row['at'];
    if (position == null || duration == null || at is! int || at < 0) {
      return null;
    }
    final next = row['next'];
    String? text(Object? value) => value is String ? value : null;
    return SyncedProgress(
      key: key,
      positionMs: position,
      durationMs: duration,
      at: _toLocal(state, at),
      next:
          key.startsWith('episode:') &&
              next is List &&
              next.length == 2 &&
              next[0] is int &&
              next[1] is int
          ? (season: next[0] as int, episode: next[1] as int)
          : null,
      removed: row['removed'] == true,
      title: text(row['title']),
      year: text(row['year']),
      poster: text(row['poster']),
      backdrop: text(row['backdrop']),
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

/// One account's sync state on this device.
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

  /// Counts every change sent from [device]; the server orders this
  /// device's own changes by it.
  int seq;

  /// Where the next pull starts (server time).
  int cursor;

  /// Server clock minus this device's clock, from the last request.
  int offset;

  /// Whether what this device held before its first sync was sent.
  bool seeded;

  /// Titles changed here and not yet sent, with the time of the change.
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
