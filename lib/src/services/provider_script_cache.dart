/// In-memory cache of provider scripts for this app session.
///
/// Without it every playback lookup downloaded every provider's script again
/// (a new DNS, TCP and TLS setup per script) before any provider could run.
/// Scripts are refreshed after [ttl] so repository updates still arrive, and
/// concurrent lookups for one URL share a single download. If a refresh fails,
/// a copy up to [maxStale] old is used so a briefly unreachable script host
/// does not disable a provider.
class ProviderScriptCache {
  ProviderScriptCache({
    this.ttl = const Duration(minutes: 30),
    this.maxStale = const Duration(hours: 24),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final Duration maxStale;
  final DateTime Function() _clock;
  final Map<String, ({String body, DateTime fetchedAt})> _entries = {};
  final Map<String, Future<String>> _inFlight = {};

  /// Returns the script at [url], downloading it with [fetch] when it is not
  /// cached or older than [ttl]. [fetch] throws when the script is unavailable.
  Future<String> get(String url, Future<String> Function() fetch) {
    final cached = _entries[url];
    final now = _clock();
    if (cached != null && now.difference(cached.fetchedAt) < ttl) {
      return Future.value(cached.body);
    }
    final pending = _inFlight[url];
    if (pending != null) return pending;
    final future = _load(url, fetch);
    _inFlight[url] = future;
    future.whenComplete(() => _inFlight.remove(url)).ignore();
    return future;
  }

  Future<String> _load(String url, Future<String> Function() fetch) async {
    try {
      final body = await fetch();
      _entries[url] = (body: body, fetchedAt: _clock());
      return body;
    } catch (_) {
      final stale = _entries[url];
      if (stale != null && _clock().difference(stale.fetchedAt) < maxStale) {
        return stale.body;
      }
      rethrow;
    }
  }

  void clear() {
    _entries.clear();
  }
}
