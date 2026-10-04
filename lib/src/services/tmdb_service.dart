import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../tmdb_config.local.dart' as tmdb_config;
import '../models/media_details.dart';
import '../models/media_item.dart';
import 'media_discovery_ranking.dart';
import 'network_target_policy.dart';
import 'tmdb_response_cache.dart';

class TmdbService {
  TmdbService({
    String? baseUrl,
    String? apiKey,
    NetworkDestinationValidator? network,
    http.Client? testClient,
    TmdbResponseCache? cache,
    Future<void> Function(Duration)? wait,
    double Function()? jitter,
    this.maxRetries = 2,
    this.maxConcurrentRequests = 4,
  }) : baseUrl = (baseUrl ?? defaultBaseUrl).replaceFirst(RegExp(r'/$'), ''),
       apiKey = apiKey ?? tmdb_config.tmdbApiKey,
       _network = network ?? NetworkDestinationValidator(),
       _testClient = testClient,
       _cache = cache ?? TmdbResponseCache(),
       _wait = wait ?? Future<void>.delayed,
       _jitter = jitter ?? Random().nextDouble,
       _limiter = _TmdbRequestLimiter(maxConcurrentRequests);

  static const defaultBaseUrl = 'https://api.themoviedb.org/3';
  static const requestTimeout = Duration(seconds: 12);
  static const maxResponseBytes = 5 * 1024 * 1024;
  static const _detailsParams = {'append_to_response': 'credits'};

  final String baseUrl;
  final String apiKey;
  final int maxRetries;
  final int maxConcurrentRequests;
  final NetworkDestinationValidator _network;
  final http.Client? _testClient;
  final TmdbResponseCache _cache;
  final Future<void> Function(Duration) _wait;
  final double Function() _jitter;
  final _TmdbRequestLimiter _limiter;
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};
  final Map<String, List<void Function(Map<String, dynamic>)>> _revalidators =
      {};
  final Map<String, DateTime> _failureCooldowns = {};

  Future<List<MediaItem>> popular(
    String type, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    bool deferred = false,
  }) async {
    final pathType = type == 'series' ? 'tv' : 'movie';
    final data = await _get(
      '/$pathType/popular',
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.catalog,
      priority: deferred
          ? _TmdbRequestPriority.deferred
          : _TmdbRequestPriority.critical,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(_mediaItems(value['results'], pathType)),
    );
    return _mediaItems(data['results'], pathType);
  }

  List<MediaItem> _mediaItems(Object? results, String? mediaType) =>
      ((results as List?) ?? const [])
          .whereType<Map>()
          .map(
            (e) => MediaItem.fromTmdb(
              Map<String, dynamic>.from(e),
              mediaType: mediaType,
            ),
          )
          .toList();

  Future<List<MediaItem>> trending({
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    bool deferred = false,
  }) async {
    final data = await _get(
      '/trending/all/day',
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.catalog,
      priority: deferred
          ? _TmdbRequestPriority.deferred
          : _TmdbRequestPriority.critical,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(_trendingItems(value['results'])),
    );
    return _trendingItems(data['results']);
  }

  List<MediaItem> _trendingItems(Object? results) =>
      ((results as List?) ?? const [])
          .whereType<Map>()
          .where((e) => e['media_type'] == 'movie' || e['media_type'] == 'tv')
          .map((e) => MediaItem.fromTmdb(Map<String, dynamic>.from(e)))
          .toList();

  Future<List<MediaItem>> recommendations(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
  }) async {
    final pathType = item.type == 'series' ? 'tv' : 'movie';
    final data = await _get(
      '/$pathType/${Uri.encodeComponent(item.id)}/recommendations',
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.recommendations,
      priority: _TmdbRequestPriority.deferred,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(
              _recommendationItems(value['results'], item.id, pathType),
            ),
    );
    return _recommendationItems(data['results'], item.id, pathType);
  }

  List<MediaItem> _recommendationItems(
    Object? entries,
    String excludedId,
    String mediaType,
  ) {
    final results = ((entries as List?) ?? const [])
        .whereType<Map>()
        .map(
          (entry) => MediaItem.fromTmdb(
            Map<String, dynamic>.from(entry),
            mediaType: mediaType,
          ),
        )
        .where((recommendation) => recommendation.id != excludedId)
        .toList();
    results.sort((a, b) {
      final ratingA = double.tryParse(a.rating) ?? 0;
      final ratingB = double.tryParse(b.rating) ?? 0;
      return ratingB.compareTo(ratingA);
    });
    return results;
  }

  Future<List<MediaItem>> newReleases({
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
  }) async {
    final today = DateTime.now().toUtc();
    final from = today.subtract(MediaDiscoveryRanking.newReleaseWindow);
    String date(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';

    Future<List<Map<String, dynamic>>> discover({
      required String type,
      required Map<String, String> dateFilters,
      required String sortField,
      void Function(Map<String, dynamic>)? onRevalidated,
    }) async {
      final data = await _get(
        '/discover/$type',
        params: {
          ...dateFilters,
          'sort_by': '$sortField.desc',
          'vote_count.gte': '${MediaDiscoveryRanking.voteThreshold}',
          'vote_average.gte': '${MediaDiscoveryRanking.ratingThreshold}',
          'page': '1',
        },
        forceRefresh: forceRefresh,
        priority: _TmdbRequestPriority.deferred,
        ttl: TmdbCacheTtl.newReleases,
        onRevalidated: onRevalidated,
      );
      return ((data['results'] as List?) ?? const [])
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }

    final revalidated = <int, List<Map<String, dynamic>>>{};
    List<List<Map<String, dynamic>>> initialResults = const [];
    var initialResultsReady = false;
    void emitRevalidated() {
      if (onRevalidated == null || !initialResultsReady) return;
      final combined = <MediaItem>[];
      for (var i = 0; i < 3; i++) {
        final type = i == 0 ? 'movie' : 'tv';
        final entries = revalidated[i] ?? initialResults[i];
        for (final entry in entries) {
          combined.add(
            MediaItem.fromTmdb(
              i == 2 ? {...entry, 'hasRecentEpisode': true} : entry,
              mediaType: type,
            ),
          );
        }
      }
      onRevalidated(
        MediaDiscoveryRanking.newReleases(combined).take(20).toList(),
      );
    }

    void recordRevalidation(int index, List<Map<String, dynamic>> value) {
      revalidated[index] = value;
      emitRevalidated();
    }

    final results = await Future.wait([
      discover(
        type: 'movie',
        dateFilters: {
          'primary_release_date.gte': date(from),
          'primary_release_date.lte': date(today),
        },
        sortField: 'primary_release_date',
        onRevalidated: onRevalidated == null
            ? null
            : (value) => recordRevalidation(
                0,
                ((value['results'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((entry) => Map<String, dynamic>.from(entry))
                    .toList(),
              ),
      ),
      discover(
        type: 'tv',
        dateFilters: {
          'first_air_date.gte': date(from),
          'first_air_date.lte': date(today),
        },
        sortField: 'first_air_date',
        onRevalidated: onRevalidated == null
            ? null
            : (value) => recordRevalidation(
                1,
                ((value['results'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((entry) => Map<String, dynamic>.from(entry))
                    .toList(),
              ),
      ),
      // This separate query includes ongoing shows with episodes in the
      // window, even when their first_air_date is much older. The API result
      // omits the matched episode date, so retain the fact that it passed this
      // server-side air-date filter for local ranking.
      discover(
        type: 'tv',
        dateFilters: {'air_date.gte': date(from), 'air_date.lte': date(today)},
        sortField: 'popularity',
        onRevalidated: onRevalidated == null
            ? null
            : (value) => recordRevalidation(
                2,
                ((value['results'] as List?) ?? const [])
                    .whereType<Map>()
                    .map((entry) => Map<String, dynamic>.from(entry))
                    .toList(),
              ),
      ),
    ]);
    initialResults = results;
    initialResultsReady = true;
    if (revalidated.isNotEmpty) emitRevalidated();
    final releases = <MediaItem>[];
    for (var index = 0; index < results.length; index++) {
      final type = index == 0 ? 'movie' : 'tv';
      for (final entry in results[index]) {
        final normalized = index == 2
            ? {...entry, 'hasRecentEpisode': true}
            : entry;
        releases.add(MediaItem.fromTmdb(normalized, mediaType: type));
      }
    }
    return MediaDiscoveryRanking.newReleases(releases).take(20).toList();
  }

  List<MediaItem> spotlight(Iterable<MediaItem> candidates) {
    final ranked = MediaDiscoveryRanking.spotlightCandidates(candidates);
    final movies = ranked.where((item) => item.type == 'movie').take(6);
    final series = ranked.where((item) => item.type == 'series').take(6);
    final featured = <MediaItem>[];
    for (var index = 0; index < 6; index++) {
      if (index < movies.length) featured.add(movies.elementAt(index));
      if (index < series.length) featured.add(series.elementAt(index));
    }
    return featured;
  }

  Future<MediaDetails> details(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(MediaDetails)? onRevalidated,
  }) async {
    final pathType = item.type == 'series' ? 'tv' : 'movie';
    final resolvedId = int.tryParse(item.id) == null
        ? await resolveTmdbId(item, forceRefresh: forceRefresh)
        : item.id;
    final id = resolvedId.isEmpty ? item.id : resolvedId;
    final data = await _get(
      '/$pathType/${Uri.encodeComponent(id)}',
      params: _detailsParams,
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.metadata,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(MediaDetails.fromTmdb(value)),
    );
    return MediaDetails.fromTmdb(data);
  }

  Future<List<MediaItem>> search(
    String query, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
  }) async {
    final data = await _get(
      '/search/multi',
      params: {'query': query.trim()},
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.search,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(_trendingItems(value['results'])),
    );
    return ((data['results'] as List?) ?? const [])
        .whereType<Map>()
        .where((e) => e['media_type'] == 'movie' || e['media_type'] == 'tv')
        .map((e) => MediaItem.fromTmdb(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<MediaItem> resolveIds(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    if (item.externalId.isNotEmpty || int.tryParse(item.id) == null) {
      return item;
    }
    final type = item.type == 'series' ? 'tv' : 'movie';
    try {
      final result = await _get(
        '/$type/${Uri.encodeComponent(item.id)}/external_ids',
        forceRefresh: forceRefresh,
        ttl: TmdbCacheTtl.identifiers,
      );
      return item.copyWith(externalId: '${result['imdb_id'] ?? ''}');
    } catch (_) {
      return item;
    }
  }

  Future<String> resolveTmdbId(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    if (int.tryParse(item.id) != null) return item.id;
    final externalId = item.externalId.isNotEmpty ? item.externalId : item.id;
    if (!externalId.startsWith('tt')) return '';
    try {
      final result = await _get(
        '/find/${Uri.encodeComponent(externalId)}',
        params: {'external_source': 'imdb_id'},
        forceRefresh: forceRefresh,
        ttl: TmdbCacheTtl.identifiers,
      );
      final key = item.type == 'series' ? 'tv_results' : 'movie_results';
      final entries = (result[key] as List? ?? const []).whereType<Map>();
      final id = entries.isEmpty ? '' : '${entries.first['id'] ?? ''}';
      return id;
    } catch (_) {
      return '';
    }
  }

  Future<List<Map<String, dynamic>>> seasons(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    if (item.type != 'series') return [];
    final id = await _seriesTmdbId(item, forceRefresh: forceRefresh);
    if (id.isEmpty) return [];
    // Same request as details(): opening a series loads both at once, and an
    // identical key lets the in-flight dedup and cache serve them together.
    final data = await _get(
      '/tv/${Uri.encodeComponent(id)}',
      params: _detailsParams,
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.metadata,
    );
    final result = ((data['seasons'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => (e['season_number'] as num? ?? 0) > 0)
        .toList();
    return result;
  }

  Future<List<Map<String, dynamic>>> episodes(
    MediaItem item,
    int season, {
    bool forceRefresh = false,
  }) async {
    final id = await _seriesTmdbId(item, forceRefresh: forceRefresh);
    if (id.isEmpty) return [];
    final data = await _get(
      '/tv/${Uri.encodeComponent(id)}/season/$season',
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.metadata,
    );
    final result = ((data['episodes'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return result;
  }

  Future<String> _seriesTmdbId(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    return int.tryParse(item.id) != null
        ? item.id
        : resolveTmdbId(item, forceRefresh: forceRefresh);
  }

  Future<List<Map<String, dynamic>>> allEpisodes(
    MediaItem item, {
    bool forceRefresh = false,
  }) async {
    final seasonsList = await seasons(item, forceRefresh: forceRefresh);
    final episodesBySeason = List<List<Map<String, dynamic>>>.generate(
      seasonsList.length,
      (_) => <Map<String, dynamic>>[],
    );
    var nextSeason = 0;
    Future<void> loadSeasonWorker() async {
      while (nextSeason < seasonsList.length) {
        final index = nextSeason++;
        final seasonNumber = (seasonsList[index]['season_number'] as num)
            .toInt();
        try {
          episodesBySeason[index] = await episodes(
            item,
            seasonNumber,
            forceRefresh: forceRefresh,
          );
        } catch (_) {
          // One missing season should not block the other episodes from being
          // selectable.
        }
      }
    }

    final workerCount = seasonsList.length < 4 ? seasonsList.length : 4;
    await Future.wait(List.generate(workerCount, (_) => loadSeasonWorker()));
    final output = episodesBySeason.expand((season) => season).toList();
    return output;
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String> params = const {},
    bool forceRefresh = false,
    required Duration ttl,
    _TmdbRequestPriority priority = _TmdbRequestPriority.critical,
    void Function(Map<String, dynamic>)? onRevalidated,
  }) async {
    if (apiKey.isEmpty) throw Exception('TMDB API key is not configured.');
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    final sortedParams = Map<String, String>.fromEntries(
      params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final requestKey =
        '$baseUrl/$normalizedPath?'
        '${Uri(queryParameters: sortedParams).query}'
        '&credential=${_stableHash(apiKey)}';
    final requestLabel = _requestLabel(path, sortedParams);
    final uri = Uri.parse(
      '$baseUrl/$normalizedPath',
    ).replace(queryParameters: {...sortedParams, 'api_key': apiKey});

    if (!forceRefresh) {
      TmdbCachedResponse? cached;
      try {
        cached = await _cache.read(requestKey);
      } catch (_) {
        // A corrupt or unavailable local cache must not stop network access.
      }
      if (cached != null && cached.entry.isFresh(DateTime.now())) {
        _log(
          '[TMDB] ${cached.fromMemory ? 'MEMORY_CACHE_HIT' : 'PERSISTENT_CACHE_HIT'} $requestLabel',
        );
        return cached.entry.value;
      }
      if (cached != null) {
        _log('[TMDB] STALE_CACHE_HIT $requestLabel');
        if (onRevalidated != null) {
          _revalidators.putIfAbsent(requestKey, () => []).add(onRevalidated);
        }
        final coolingDown = _failureCooldowns[requestKey];
        if (coolingDown == null ||
            DateTime.now().difference(coolingDown) >=
                const Duration(seconds: 30)) {
          if (_inFlight.containsKey(requestKey)) {
            _log('[TMDB] DEDUP $requestLabel');
          } else {
            _startNetworkRequest(requestKey, requestLabel, uri, ttl, priority);
          }
        }
        return cached.entry.value;
      }
    }

    final existing = _inFlight[requestKey];
    if (existing != null) {
      _log('[TMDB] DEDUP $requestLabel');
      return existing;
    }
    return _startNetworkRequest(requestKey, requestLabel, uri, ttl, priority);
  }

  Future<Map<String, dynamic>> _startNetworkRequest(
    String requestKey,
    String label,
    Uri uri,
    Duration ttl,
    _TmdbRequestPriority priority,
  ) {
    final existing = _inFlight[requestKey];
    if (existing != null) return existing;
    _log('[TMDB] NETWORK $label');
    final request = _fetchAndCache(requestKey, label, uri, ttl, priority);
    _inFlight[requestKey] = request;
    request
        .then(
          (value) {
            _failureCooldowns.remove(requestKey);
            final callbacks = _revalidators.remove(requestKey) ?? const [];
            for (final callback in callbacks) {
              try {
                callback(value);
              } catch (_) {
                // A presentation callback must not invalidate a successful response.
              }
            }
          },
          onError: (Object _) {
            _revalidators.remove(requestKey);
            _failureCooldowns[requestKey] = DateTime.now();
          },
        )
        .whenComplete(() {
          if (identical(_inFlight[requestKey], request)) {
            _inFlight.remove(requestKey);
          }
        });
    return request;
  }

  Future<Map<String, dynamic>> _fetchAndCache(
    String requestKey,
    String label,
    Uri uri,
    Duration ttl,
    _TmdbRequestPriority priority,
  ) async {
    final response = await _sendWithRetries(uri, label, priority);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('TMDB returned an invalid JSON response.');
    }
    final value = Map<String, dynamic>.from(decoded);
    // write() updates the memory cache synchronously. The disk copy (JSON
    // encode plus a flushed write) finishes in the background instead of
    // delaying every network response on its way to the UI.
    unawaited(
      _cache.write(requestKey, value, ttl).catchError((Object _) {
        // Disk cache failures must not make a successful response fail.
      }),
    );
    return value;
  }

  Future<http.Response> _sendWithRetries(
    Uri uri,
    String label,
    _TmdbRequestPriority priority,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await _limiter.run(
          priority,
          () => _sendFollowingRedirects(uri),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        throw _TmdbHttpException(
          response.statusCode,
          response.headers['retry-after'],
        );
      } on SocketException catch (_) {
        if (attempt >= maxRetries) rethrow;
        final delay = _backoff(attempt);
        _log(
          '[TMDB] RETRY network attempt=${attempt + 1} delay=${delay.inMilliseconds}ms $label',
        );
        await _wait(delay);
      } on TimeoutException catch (_) {
        if (attempt >= maxRetries) rethrow;
        final delay = _backoff(attempt);
        _log(
          '[TMDB] RETRY timeout attempt=${attempt + 1} delay=${delay.inMilliseconds}ms $label',
        );
        await _wait(delay);
      } on http.ClientException catch (_) {
        if (attempt >= maxRetries) rethrow;
        final delay = _backoff(attempt);
        _log(
          '[TMDB] RETRY network attempt=${attempt + 1} delay=${delay.inMilliseconds}ms $label',
        );
        await _wait(delay);
      } on _TmdbHttpException catch (error) {
        if (!_isRetryableStatus(error.statusCode) || attempt >= maxRetries) {
          throw Exception('TMDB request failed (${error.statusCode}).');
        }
        final delay = _retryDelay(attempt, error.retryAfter);
        if (delay == null) {
          throw Exception('TMDB request failed (${error.statusCode}).');
        }
        if (error.statusCode == 429) _log('[TMDB] RATE_LIMIT 429 $label');
        _log(
          '[TMDB] RETRY ${error.statusCode} attempt=${attempt + 1} delay=${delay.inMilliseconds}ms $label',
        );
        await _wait(delay);
      }
    }
  }

  /// How long one validated DNS result and its keep-alive connections are
  /// reused before the host is resolved again.
  static const _clientLifetime = Duration(minutes: 5);
  final Map<String, ({Future<http.Client> client, DateTime createdAt})>
  _clients = {};

  /// A pinned client per origin, so catalog, details and season requests
  /// reuse one TLS connection instead of resolving and handshaking for each.
  Future<http.Client> _clientFor(Uri uri) {
    final origin = '${uri.scheme}://${uri.host.toLowerCase()}:${uri.port}';
    final now = DateTime.now();
    final cached = _clients[origin];
    if (cached != null && now.difference(cached.createdAt) < _clientLifetime) {
      return cached.client;
    }
    if (cached != null) {
      // Requests may still be using the old client; closing it aborts them.
      Timer(requestTimeout * 2, () {
        cached.client.then((client) => client.close(), onError: (_) {});
      });
    }
    final client = _network.createPinnedClient(uri);
    _clients[origin] = (client: client, createdAt: now);
    // A failed lookup must not be reused by later requests.
    return client.catchError((Object error) {
      if (identical(_clients[origin]?.client, client)) _clients.remove(origin);
      throw error;
    });
  }

  Future<http.Response> _sendFollowingRedirects(Uri uri) async {
    var current = uri;
    for (var redirects = 0; redirects <= 3; redirects++) {
      final request = http.Request('GET', current)..followRedirects = false;
      final response = await _network.sendForBytes(
        request,
        allowedSchemes: const {'https'},
        maxResponseBytes: maxResponseBytes,
        timeout: requestTimeout,
        testClient: _testClient,
        pinnedClient: _testClient == null ? await _clientFor(current) : null,
      );
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      if (location == null || redirects == 3) {
        throw const FormatException('Invalid TMDB redirect.');
      }
      current = await _network.validateRedirect(
        current,
        location,
        allowedSchemes: const {'https'},
      );
    }
    throw const FormatException('Too many TMDB redirects.');
  }

  Duration? _retryDelay(int attempt, String? retryAfter) {
    final serverDelay = _parseRetryAfter(retryAfter);
    if (serverDelay != null) {
      // Never retry sooner than requested. Skip exceptionally long waits.
      if (serverDelay > const Duration(minutes: 2)) return null;
      return serverDelay;
    }
    return _backoff(attempt);
  }

  Duration _backoff(int attempt) {
    final baseMs = 400 * (1 << attempt);
    final jitterMs = (250 * _jitter().clamp(0, 1)).round();
    return Duration(milliseconds: baseMs + jitterMs);
  }

  static Duration? _parseRetryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 86400));
    try {
      final date = HttpDate.parse(value.trim());
      final delay = date.difference(DateTime.now());
      return delay.isNegative ? Duration.zero : delay;
    } on FormatException {
      return null;
    }
  }

  static bool _isRetryableStatus(int status) =>
      status == 429 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504;

  static String _requestLabel(String path, Map<String, String> params) {
    final page = params['page'];
    return page == null ? path : '$path?page=$page';
  }

  static int _stableHash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash;
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint(message);
  }
}

enum _TmdbRequestPriority { critical, deferred }

class _TmdbHttpException implements Exception {
  const _TmdbHttpException(this.statusCode, this.retryAfter);

  final int statusCode;
  final String? retryAfter;
}

class _TmdbRequestLimiter {
  _TmdbRequestLimiter(this.capacity) : assert(capacity > 0);

  final int capacity;
  int _active = 0;
  final Queue<Completer<void>> _critical = Queue();
  final Queue<Completer<void>> _deferred = Queue();

  Future<T> run<T>(
    _TmdbRequestPriority priority,
    Future<T> Function() operation,
  ) async {
    await _acquire(priority);
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  Future<void> _acquire(_TmdbRequestPriority priority) {
    if (_active < capacity) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    (priority == _TmdbRequestPriority.critical ? _critical : _deferred).addLast(
      waiter,
    );
    return waiter.future;
  }

  void _release() {
    final queue = _critical.isNotEmpty ? _critical : _deferred;
    if (queue.isEmpty) {
      _active--;
    } else {
      queue.removeFirst().complete();
    }
  }
}
