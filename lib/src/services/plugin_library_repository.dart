import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/plugin_catalog.dart';
import 'plugin_library_query.dart';
import 'plugin_library_service.dart';

enum PluginLibraryStatus { idle, loading, ready, error }

/// Holds the Plugin Library catalog for the UI.
///
/// The offline copy (download cache or the catalog bundled with the app,
/// whichever is newer) is shown first, then a newer remote catalog replaces
/// it when one is available. A failed refresh keeps the catalog on screen.
class PluginLibraryRepository extends ChangeNotifier {
  PluginLibraryRepository({
    PluginLibraryService? service,
    DateTime Function()? clock,
  }) : _service = service ?? PluginLibraryService(),
       _clock = clock ?? DateTime.now;

  final PluginLibraryService _service;
  final DateTime Function() _clock;
  bool _disposed = false;

  PluginLibraryStatus status = PluginLibraryStatus.idle;

  // A catalog download can finish after the screen that owns this is gone.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
  PluginCatalogSnapshot? snapshot;

  /// Why the last remote refresh failed; null after a successful one.
  String? refreshError;
  bool refreshing = false;
  DateTime? _checkedAt;

  PluginLibraryStats stats = const PluginLibraryStats(
    providerCount: 0,
    sourceCount: 0,
    languageCount: 0,
  );
  PluginLibraryFacets facets = const PluginLibraryFacets(
    languages: [],
    contentTypes: [],
  );

  List<ReelishPlugin> get plugins => snapshot?.catalog.providers ?? const [];

  /// True when the catalog on screen is an offline copy because the latest
  /// refresh failed.
  bool get showingOfflineCopy =>
      refreshError != null && snapshot?.origin != PluginCatalogOrigin.remote;

  Future<void>? _loading;
  Future<void>? _refreshing;

  /// Loads the catalog once, then refreshes it in the background when the
  /// last download is older than [PluginLibraryConfig.refreshInterval].
  /// Later calls (the screen opening again) only start that background
  /// refresh.
  Future<void> load() async {
    final first = _loading == null;
    await (_loading ??= _load());
    if (!first && _shouldAutoRefresh) unawaited(refresh());
  }

  Future<void> _load() async {
    status = PluginLibraryStatus.loading;
    notifyListeners();
    final (cached, bundled) = await (
      _service.loadCached(),
      _service.loadBundled(),
    ).wait;
    _checkedAt = cached?.checkedAt;
    final offline = _newest(cached, bundled);
    if (offline != null) _show(offline);
    if (offline == null) {
      await refresh();
    } else if (_shouldAutoRefresh) {
      unawaited(refresh());
    }
  }

  /// A failed attempt is not retried automatically for a while, so opening
  /// the library offline does not keep hitting the network.
  static const _autoRetryDelay = Duration(minutes: 10);
  DateTime? _lastAttemptAt;

  bool get _shouldAutoRefresh {
    final now = _clock().toUtc();
    final checkedAt = _checkedAt, attempted = _lastAttemptAt;
    final stale =
        checkedAt == null ||
        now.difference(checkedAt) >= PluginLibraryConfig.refreshInterval;
    return stale &&
        (attempted == null || now.difference(attempted) >= _autoRetryDelay);
  }

  /// Downloads the latest catalog. Search and filters live in the screen, so
  /// they are kept across a refresh.
  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    refreshing = true;
    _lastAttemptAt = _clock().toUtc();
    if (snapshot == null) status = PluginLibraryStatus.loading;
    notifyListeners();
    try {
      final remote = await _service.fetchRemote();
      _checkedAt = remote.checkedAt;
      refreshError = null;
      final current = snapshot;
      // Never replace a newer catalog (for example one bundled with a fresh
      // app build) with an older remote copy.
      if (current == null || !_isOlder(remote.catalog, current.catalog)) {
        _show(remote);
      }
    } catch (error) {
      refreshError = error is TimeoutException
          ? 'The plugin catalog took too long to respond.'
          : 'Check your connection and try again.';
      if (snapshot == null) status = PluginLibraryStatus.error;
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  /// Retries after the library failed to load at all.
  Future<void> retry() async {
    _loading = null;
    await load();
  }

  void _show(PluginCatalogSnapshot value) {
    snapshot = value;
    stats = PluginLibraryStats.of(value.catalog.providers);
    facets = PluginLibraryFacets.of(value.catalog.providers);
    status = PluginLibraryStatus.ready;
    notifyListeners();
  }

  static PluginCatalogSnapshot? _newest(
    PluginCatalogSnapshot? a,
    PluginCatalogSnapshot? b,
  ) {
    if (a == null || b == null) return a ?? b;
    return _isOlder(a.catalog, b.catalog) ? b : a;
  }

  static bool _isOlder(PluginCatalog a, PluginCatalog b) {
    final left = a.updatedAt, right = b.updatedAt;
    if (left == null || right == null) return left == null && right != null;
    return left.isBefore(right);
  }
}
