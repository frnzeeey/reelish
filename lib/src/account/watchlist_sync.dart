// Keeps My list and the Trakt watchlist in step, when the user turns it
// on. A three-way merge against the last synced state: changes made on
// either side since then are carried to the other, and nothing is ever
// deleted on a first sync (the two lists are combined).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../services/storage_service.dart';
import '../services/tmdb_service.dart';
import 'account_api.dart';
import 'account_controller.dart';
import 'backend_config.dart';

class WatchlistSync extends ChangeNotifier {
  WatchlistSync({
    AccountApi? api,
    StorageService? storage,
    this.fetchItem,
    this.debounce = const Duration(seconds: 4),
  }) : _api = api ?? AccountApi(baseUrl: BackendConfig.apiUrl),
       _storage = storage ?? StorageService();

  /// The app's sync, following [AccountController.instance] once attached.
  static WatchlistSync instance = WatchlistSync();

  /// SharedPreferences key: `{userId: {watchlist, base, unsyncable, at}}`.
  static const storageKey = 'onfeed.traktSync.v1';

  /// Titles fetched for the list per sync; the rest follow next time.
  static const maxFetchPerSync = 60;

  final AccountApi _api;
  final StorageService _storage;

  /// Fetches a title added on Trakt; defaults to [TmdbService.itemById].
  final Future<MediaItem> Function(String type, int tmdbId)? fetchItem;
  final Duration debounce;
  TmdbService? _tmdb;

  AccountController? _account;
  String? _userId;
  bool _enabled = false;
  Set<String>? _base;
  Set<String> _unsyncable = {};
  DateTime? _lastSynced;
  String? _error;
  bool _syncing = false;
  Future<void>? _running;
  bool _again = false;
  bool _applying = false;
  Timer? _timer;

  /// Whether My list syncs with the Trakt watchlist for this account.
  bool get enabled => _enabled;
  bool get syncing => _syncing;
  DateTime? get lastSynced => _lastSynced;

  /// Why the last sync failed, for Settings; null after a success.
  String? get error => _error;

  void attach(AccountController account) {
    _account?.removeListener(_accountChanged);
    _account = account..addListener(_accountChanged);
    StorageService.favoritesRevision.removeListener(_listChanged);
    StorageService.favoritesRevision.addListener(_listChanged);
    _accountChanged();
  }

  void _accountChanged() {
    final userId = _account?.status == AccountStatus.signedIn
        ? _account?.userId
        : null;
    if (userId == _userId) return;
    unawaited(_load(userId));
  }

  Future<void> _load(String? userId) async {
    _timer?.cancel();
    _userId = userId;
    _enabled = false;
    _base = null;
    _unsyncable = {};
    _lastSynced = null;
    _error = null;
    if (userId != null) {
      try {
        final entry = (await _readAll())[userId];
        if (_userId != userId) return;
        if (entry is Map) {
          _enabled = entry['watchlist'] == true;
          final base = entry['base'];
          _base = base is List ? base.whereType<String>().toSet() : null;
          final unsyncable = entry['unsyncable'];
          _unsyncable = unsyncable is List
              ? unsyncable.whereType<String>().toSet()
              : {};
          final at = entry['at'];
          _lastSynced = at is int
              ? DateTime.fromMillisecondsSinceEpoch(at)
              : null;
        }
      } catch (_) {
        // Unreadable: start as never synced, which only ever combines.
      }
    }
    notifyListeners();
    if (_enabled) unawaited(sync());
  }

  void _listChanged() {
    if (_applying || !_enabled || _userId == null) return;
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(sync()));
  }

  /// Turns sync on or off for this account. Turning it on syncs at once;
  /// turning it off forgets the synced state, so turning it on again
  /// combines the lists rather than deleting anything.
  Future<void> setEnabled(bool value) async {
    if (_userId == null) return;
    _enabled = value;
    _error = null;
    if (!value) {
      _timer?.cancel();
      _base = null;
      _unsyncable = {};
    }
    notifyListeners();
    await _save();
    if (value) await sync();
  }

  /// Syncs now; calls made during a sync run once more after it.
  Future<void> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _syncLoop().whenComplete(() => _running = null);
  }

  Future<void> _syncLoop() async {
    do {
      _again = false;
      await _syncOnce();
    } while (_again && _enabled);
  }

  static String? keyOf(MediaItem item) {
    final id = int.tryParse(item.id);
    if (id == null || id <= 0) return null;
    if (item.type != 'movie' && item.type != 'series') return null;
    return '${item.type}:$id';
  }

  Future<void> _syncOnce() async {
    final userId = _userId;
    final account = _account;
    if (!_enabled || userId == null || account == null) return;
    _syncing = true;
    notifyListeners();
    try {
      var token = await account.accessToken();
      if (token == null) return;

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

      final remote = (await withToken(_api.watchlist))..removeAll(_unsyncable);
      final localItems = await _storage.favorites();
      // Titles without a TMDB id stay on My list, untouched by sync.
      final local = {for (final item in localItems) ?keyOf(item)}
        ..removeAll(_unsyncable);
      final base = _base ?? <String>{};

      final pushAdd = local.difference(remote).difference(base);
      final pushRemove = base.difference(local).intersection(remote);
      final addLocal = remote.difference(local).difference(base);
      final removeLocal = base.difference(remote).intersection(local);

      final notFound = <String>{};
      final pushedAdd = <String>{};
      final pushedRemove = <String>{};
      for (var i = 0; i < pushAdd.length || i < pushRemove.length; i += 100) {
        final add = pushAdd.skip(i).take(100).toList();
        final remove = pushRemove.skip(i).take(100).toList();
        notFound.addAll(
          await withToken(
            (t) => _api.updateWatchlist(t, add: add, remove: remove),
          ),
        );
        pushedAdd.addAll(add);
        pushedRemove.addAll(remove);
        if (_userId != userId) return;
      }
      // Trakt cannot find these; sync leaves them alone from now on, so
      // they are neither retried nor taken off My list.
      pushedAdd.removeAll(notFound);
      _unsyncable.addAll(notFound);

      final fetched = <MediaItem>[];
      final failed = <String>{};
      for (final key in addLocal) {
        if (fetched.length + failed.length >= maxFetchPerSync) {
          failed.add(key);
          continue;
        }
        try {
          final split = key.indexOf(':');
          fetched.add(
            await _fetch(
              key.substring(0, split),
              int.parse(key.substring(split + 1)),
            ),
          );
        } catch (_) {
          failed.add(key);
        }
      }
      if (_userId != userId) return;
      _applying = true;
      try {
        await _storage.updateFavorites(add: fetched, remove: removeLocal);
      } finally {
        _applying = false;
      }

      // What both sides now hold. Titles not fetched yet are left out, so
      // the next sync adds them instead of taking them off Trakt.
      _base = remote
          .union(pushedAdd)
          .difference(pushedRemove)
          .difference(failed)
          .difference(_unsyncable);
      _lastSynced = DateTime.now();
      _error = null;
      await _save();
    } on AccountApiException catch (error) {
      _error = switch (error.code) {
        'trakt_limit' =>
          'Your Trakt watchlist is full. Remove titles on Trakt, or '
              'upgrade your Trakt account, then sync again.',
        'trakt_reauth_required' =>
          'Reelish lost access to Trakt. Sign out and in again to '
              'reconnect.',
        'network' => 'Could not reach Reelish. Sync will try again later.',
        'rate_limited' ||
        'trakt_busy' => 'Trakt is busy. Sync will try again later.',
        _ => 'Sync did not finish. It will try again later.',
      };
    } catch (_) {
      _error = 'Sync did not finish. It will try again later.';
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<MediaItem> _fetch(String type, int tmdbId) {
    final fetch = fetchItem;
    if (fetch != null) return fetch(type, tmdbId);
    return (_tmdb ??= TmdbService()).itemById(type, tmdbId);
  }

  static Future<Map<String, Object?>> _readAll() async {
    final raw = (await SharedPreferences.getInstance()).getString(storageKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, Object?>.from(decoded) : {};
  }

  Future<void> _save() async {
    final userId = _userId;
    if (userId == null) return;
    Map<String, Object?> all;
    try {
      all = await _readAll();
    } catch (_) {
      all = {};
    }
    all[userId] = {
      'watchlist': _enabled,
      if (_base != null) 'base': _base!.toList(),
      if (_unsyncable.isNotEmpty) 'unsyncable': _unsyncable.toList(),
      if (_lastSynced != null) 'at': _lastSynced!.millisecondsSinceEpoch,
    };
    await (await SharedPreferences.getInstance()).setString(
      storageKey,
      jsonEncode(all),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _account?.removeListener(_accountChanged);
    StorageService.favoritesRevision.removeListener(_listChanged);
    super.dispose();
  }
}
