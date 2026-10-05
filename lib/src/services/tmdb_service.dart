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
import 'media_catalog_rules.dart';
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
    this.language,
    this.region,
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

  /// TMDB `language` (for example `en-US`) sent with every request. Null
  /// keeps TMDB's default, which is what the app has always used: its UI is
  /// English and it has no language setting yet.
  final String? language;

  /// ISO 3166-1 country code for movie release filtering, so New movies and
  /// New releases follow that market's release dates. Null uses releases
  /// from any country, the app's existing behavior.
  final String? region;

  /// TMDB release types counted as a real release: 3 Theatrical and
  /// 4 Digital. Premieres (1) and limited theatrical runs (2), which are
  /// mostly festivals, are left out.
  static const _generalReleaseTypes = '3|4';

  final NetworkDestinationValidator _network;
  final http.Client? _testClient;
  final TmdbResponseCache _cache;
  final Future<void> Function(Duration) _wait;
  final double Function() _jitter;
  final _TmdbRequestLimiter _limiter;
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};
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

  /// Parses a TMDB `results` list into unique items, skipping bad records.
  ///
  /// An entry's own `media_type` wins when present. People and any other
  /// non-title types are dropped, as are entries without a valid id or with
  /// malformed fields. [pathType] (`movie` or `tv`) is used for entries that
  /// carry no `media_type`; when it is null, such entries are dropped.
  static List<MediaItem> _mediaItems(Object? results, String? pathType) {
    final items = <MediaItem>[];
    for (final entry in results is List ? results : const []) {
      if (entry is! Map) continue;
      try {
        final json = Map<String, dynamic>.from(entry);
        final declared = json['media_type'];
        final mediaType = declared == null ? pathType : '$declared';
        if (mediaType != 'movie' && mediaType != 'tv') continue;
        final item = MediaItem.fromTmdb(json, mediaType: mediaType);
        if (MediaCatalogFilter.hasValidTmdbId(item)) items.add(item);
      } catch (_) {
        // One malformed record must not break the whole list.
      }
    }
    return MediaCatalogFilter.dedupe(items);
  }

  static String _date(DateTime value) => MediaFreshnessRules.tmdbDate(value);

  /// Movies whose first release and a general (theatrical or digital)
  /// release both fall inside [window], optionally in [region].
  Map<String, String> _movieReleaseParams(Duration window) {
    final today = DateTime.now().toUtc();
    final from = _date(today.subtract(window));
    final to = _date(today);
    final region = this.region;
    return {
      'primary_release_date.gte': from,
      'primary_release_date.lte': to,
      'release_date.gte': from,
      'release_date.lte': to,
      'with_release_type': _generalReleaseTypes,
      if (region != null && region.isNotEmpty) 'region': region,
    };
  }

  /// Limits TV discovery to scripted series and miniseries, without talk,
  /// news, reality or soap programming.
  static final _scriptedTvParams = {
    'with_type': MediaCatalogFilter.tmdbScriptedTvTypes,
    'without_genres': MediaCatalogFilter.tmdbExcludedTvGenres,
  };

  /// Recently released movies for the New movies row, ranked by
  /// [MediaDiscoveryRanking.newMovies]. [page] is accepted so the row can
  /// load more later; the home screen asks only for page 1.
  Future<List<MediaItem>> newMovies({
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    int page = 1,
  }) async {
    List<MediaItem> ranked(Map<String, dynamic> data) =>
        MediaDiscoveryRanking.newMovies(_mediaItems(data['results'], 'movie'));
    final data = await _get(
      '/discover/movie',
      params: {
        ..._movieReleaseParams(MediaDiscoveryRanking.newMovieWindow),
        'sort_by': 'popularity.desc',
        'vote_count.gte': '${MediaDiscoveryRanking.relaxedVoteThreshold}',
        'page': '${max(page, 1)}',
      },
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.catalog,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(ranked(value)),
    );
    return ranked(data);
  }

  /// Scripted series with an episode in the last
  /// [MediaDiscoveryRanking.seriesActivityWindow], for the Series worth the
  /// queue row. TMDB filters out talk, news, reality and soap programming;
  /// [MediaDiscoveryRanking.worthQueueSeries] checks again and ranks.
  Future<List<MediaItem>> streamingSeries({
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    int page = 1,
  }) async {
    List<MediaItem> ranked(Map<String, dynamic> data) =>
        MediaDiscoveryRanking.worthQueueSeries(
          _mediaItems(data['results'], 'tv'),
        );
    final today = DateTime.now().toUtc();
    final data = await _get(
      '/discover/tv',
      params: {
        ..._scriptedTvParams,
        'air_date.gte': _date(
          today.subtract(MediaDiscoveryRanking.seriesActivityWindow),
        ),
        'air_date.lte': _date(today),
        'sort_by': 'popularity.desc',
        'vote_count.gte': '${MediaDiscoveryRanking.relaxedVoteThreshold}',
        'page': '${max(page, 1)}',
      },
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.catalog,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(ranked(value)),
    );
    return ranked(data);
  }

  Future<List<MediaItem>> trending({
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    bool deferred = false,
    int page = 1,
  }) async {
    final data = await _get(
      '/trending/all/day',
      // Page 1 sends no page parameter, so existing cache entries stay valid.
      params: page > 1 ? {'page': '$page'} : const {},
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

  /// Mixed-media results (trending, search) must declare a movie or tv
  /// `media_type`; anything else, such as people, is dropped.
  static List<MediaItem> _trendingItems(Object? results) =>
      _mediaItems(results, null);

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

  /// Recommendations for one title, ranked by vote-weighted score so a
  /// handful of perfect votes cannot outrank an established title.
  List<MediaItem> _recommendationItems(
    Object? entries,
    String excludedId,
    String mediaType,
  ) => MediaDiscoveryRanking.rankByScore(
    _mediaItems(entries, mediaType).where(
      (recommendation) =>
          recommendation.id != excludedId &&
          recommendation.type == (mediaType == 'tv' ? 'series' : 'movie'),
    ),
  );

  /// Recent titles for the New releases row: movies first released in the
  /// window that had a theatrical or digital release, scripted series that
  /// premiered in it, and scripted series that aired an episode in it.
  ///
  /// When cached values are stale, their refreshes are awaited together and
  /// [onRevalidated] fires once with the combined list, rather than once per
  /// request. A refresh that fails keeps that request's cached value.
  Future<List<MediaItem>> newReleases({
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
  }) async {
    final today = DateTime.now().toUtc();
    final from = _date(today.subtract(MediaDiscoveryRanking.newReleaseWindow));
    final to = _date(today);
    final quality = {
      'vote_count.gte': '${MediaDiscoveryRanking.voteThreshold}',
      'vote_average.gte': '${MediaDiscoveryRanking.ratingThreshold}',
      'page': '1',
    };
    final queries = <(String, Map<String, String>)>[
      (
        '/discover/movie',
        {
          ..._movieReleaseParams(MediaDiscoveryRanking.newReleaseWindow),
          'sort_by': 'primary_release_date.desc',
          ...quality,
        },
      ),
      (
        '/discover/tv',
        {
          ..._scriptedTvParams,
          'first_air_date.gte': from,
          'first_air_date.lte': to,
          'sort_by': 'first_air_date.desc',
          ...quality,
        },
      ),
      // This separate query includes ongoing shows with episodes in the
      // window, even when their first_air_date is much older.
      (
        '/discover/tv',
        {
          ..._scriptedTvParams,
          'air_date.gte': from,
          'air_date.lte': to,
          'sort_by': 'popularity.desc',
          ...quality,
        },
      ),
    ];

    List<MediaItem> combine(List<Map<String, dynamic>> pages) =>
        MediaDiscoveryRanking.newReleases([
          ..._mediaItems(pages[0]['results'], 'movie'),
          ..._mediaItems(pages[1]['results'], 'tv'),
          // The API result omits the matched episode date, so retain the fact
          // that it passed the server-side air-date filter for local ranking.
          ..._mediaItems(_withRecentEpisode(pages[2]['results']), 'tv'),
        ]).take(20).toList();

    final results = await Future.wait([
      for (final (path, params) in queries)
        _request(
          path,
          params: params,
          forceRefresh: forceRefresh,
          priority: _TmdbRequestPriority.deferred,
          ttl: TmdbCacheTtl.newReleases,
        ),
    ]);
    final initial = [for (final result in results) result.value];
    final pending = [for (final result in results) result.revalidation];
    if (onRevalidated != null && pending.any((refresh) => refresh != null)) {
      unawaited(() async {
        final fresh = await Future.wait([
          for (final refresh in pending)
            refresh == null
                ? Future<Map<String, dynamic>?>.value()
                : refresh.then<Map<String, dynamic>?>(
                    (value) => value,
                    onError: (Object _) => null,
                  ),
        ]);
        if (fresh.every((value) => value == null)) return;
        try {
          onRevalidated(
            combine([
              for (var index = 0; index < initial.length; index++)
                fresh[index] ?? initial[index],
            ]),
          );
        } catch (_) {
          // A presentation callback must not surface as an unhandled error.
        }
      }());
    }
    return combine(initial);
  }

  static List<Object?> _withRecentEpisode(Object? results) => [
    for (final entry in results is List ? results : const [])
      if (entry is Map) {...entry, 'hasRecentEpisode': true},
  ];

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

  /// Searches movies and series of any age; discovery freshness rules do not
  /// apply, so older titles stay findable.
  Future<List<MediaItem>> search(
    String query, {
    bool forceRefresh = false,
    void Function(List<MediaItem>)? onRevalidated,
    int page = 1,
  }) async {
    final data = await _get(
      '/search/multi',
      params: {'query': query.trim(), if (page > 1) 'page': '$page'},
      forceRefresh: forceRefresh,
      ttl: TmdbCacheTtl.search,
      onRevalidated: onRevalidated == null
          ? null
          : (value) => onRevalidated(_trendingItems(value['results'])),
    );
    return _trendingItems(data['results']);
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
    final result = await _request(
      path,
      params: params,
      forceRefresh: forceRefresh,
      ttl: ttl,
      priority: priority,
    );
    final revalidation = result.revalidation;
    if (onRevalidated != null && revalidation != null) {
      unawaited(
        revalidation.then(
          (value) {
            try {
              onRevalidated(value);
            } catch (_) {
              // A presentation callback must not invalidate a successful response.
            }
          },
          onError: (Object _) {
            // A failed refresh keeps the stale value already returned.
          },
        ),
      );
    }
    return result.value;
  }

  /// Returns the cached or fetched value. [revalidation] is set only when a
  /// stale value was returned and a background refresh is actually running
  /// (started now or already in flight), so a caller never waits on a refresh
  /// that the failure cooldown suppressed.
  Future<
    ({
      Map<String, dynamic> value,
      Future<Map<String, dynamic>>? revalidation,
    })
  >
  _request(
    String path, {
    Map<String, String> params = const {},
    bool forceRefresh = false,
    required Duration ttl,
    _TmdbRequestPriority priority = _TmdbRequestPriority.critical,
  }) async {
    if (apiKey.isEmpty) throw Exception('TMDB API key is not configured.');
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    final language = this.language;
    final sortedParams = Map<String, String>.fromEntries(
      {
        ...params,
        if (language != null && language.isNotEmpty) 'language': language,
      }.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
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
        return (value: cached.entry.value, revalidation: null);
      }
      if (cached != null) {
        _log('[TMDB] STALE_CACHE_HIT $requestLabel');
        Future<Map<String, dynamic>>? revalidation;
        final coolingDown = _failureCooldowns[requestKey];
        if (coolingDown == null ||
            DateTime.now().difference(coolingDown) >=
                const Duration(seconds: 30)) {
          revalidation = _inFlight[requestKey];
          if (revalidation != null) {
            _log('[TMDB] DEDUP $requestLabel');
          } else {
            revalidation = _startNetworkRequest(
              requestKey,
              requestLabel,
              uri,
              ttl,
              priority,
            );
          }
        }
        return (value: cached.entry.value, revalidation: revalidation);
      }
    }

    final existing = _inFlight[requestKey];
    if (existing != null) {
      _log('[TMDB] DEDUP $requestLabel');
      return (value: await existing, revalidation: null);
    }
    final value = await _startNetworkRequest(
      requestKey,
      requestLabel,
      uri,
      ttl,
      priority,
    );
    return (value: value, revalidation: null);
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
          (_) => _failureCooldowns.remove(requestKey),
          onError: (Object _) {
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
      } on http.ClientException catch (error) {
        // ClientException carries the request URL, which holds the API key.
        if (attempt >= maxRetries) throw _redactedClientException(error);
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

  /// Copies [error] without the `api_key` query parameter in its URL or
  /// message, so the key cannot reach logs or error text.
  http.ClientException _redactedClientException(http.ClientException error) {
    final uri = error.uri;
    final redactedUri = uri?.replace(
      queryParameters: {
        for (final entry in uri.queryParameters.entries)
          if (entry.key != 'api_key') entry.key: entry.value,
      },
    );
    final message = apiKey.isEmpty
        ? error.message
        : error.message.replaceAll(apiKey, '<redacted>');
    return http.ClientException(message, redactedUri);
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
