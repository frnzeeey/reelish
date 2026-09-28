import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../tmdb_config.local.dart' as tmdb_config;
import '../models/media_details.dart';
import '../models/media_item.dart';

class TmdbService {
  static const _base = 'https://api.themoviedb.org/3';
  static const _key = tmdb_config.tmdbApiKey;
  final Map<String, MediaDetails> _detailsCache = {};
  final Map<String, String> _resolvedTmdbIds = {};
  final Map<String, List<Map<String, dynamic>>> _seasonsCache = {};
  final Map<String, List<Map<String, dynamic>>> _episodesCache = {};

  Future<List<MediaItem>> popular(String type) async {
    final pathType = type == 'series' ? 'tv' : 'movie';
    final data = await _get('/$pathType/popular');
    return ((data['results'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (e) => MediaItem.fromTmdb(
            Map<String, dynamic>.from(e),
            mediaType: pathType,
          ),
        )
        .toList();
  }

  Future<List<MediaItem>> trending() async {
    final data = await _get('/trending/all/day');
    return ((data['results'] as List?) ?? const [])
        .whereType<Map>()
        .where((e) => e['media_type'] == 'movie' || e['media_type'] == 'tv')
        .map((e) => MediaItem.fromTmdb(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<MediaItem>> recommendations(MediaItem item) async {
    final pathType = item.type == 'series' ? 'tv' : 'movie';
    final data = await _get(
      '/$pathType/${Uri.encodeComponent(item.id)}/recommendations',
    );
    final results = ((data['results'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (entry) => MediaItem.fromTmdb(
            Map<String, dynamic>.from(entry),
            mediaType: pathType,
          ),
        )
        .where((recommendation) => recommendation.id != item.id)
        .toList();
    results.sort((a, b) {
      final ratingA = double.tryParse(a.rating) ?? 0;
      final ratingB = double.tryParse(b.rating) ?? 0;
      return ratingB.compareTo(ratingA);
    });
    return results;
  }

  Future<List<MediaItem>> newReleases() async {
    final today = DateTime.now().toUtc();
    final from = today.subtract(const Duration(days: 180));
    String date(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';

    Future<List<Map<String, dynamic>>> discover(
      String type,
      String dateField,
    ) async {
      final data = await _get('/discover/$type', {
        '$dateField.gte': date(from),
        '$dateField.lte': date(today),
        'sort_by': '$dateField.desc',
        'vote_count.gte': '10',
        'page': '1',
      });
      return ((data['results'] as List?) ?? const [])
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }

    final results = await Future.wait([
      discover('movie', 'primary_release_date'),
      discover('tv', 'first_air_date'),
    ]);
    final releases = <({MediaItem item, String releaseDate})>[];
    for (var index = 0; index < results.length; index++) {
      final type = index == 0 ? 'movie' : 'tv';
      final dateField = index == 0 ? 'release_date' : 'first_air_date';
      for (final entry in results[index]) {
        final releaseDate = '${entry[dateField] ?? ''}';
        if (releaseDate.isEmpty) continue;
        releases.add((
          item: MediaItem.fromTmdb(entry, mediaType: type),
          releaseDate: releaseDate,
        ));
      }
    }
    releases.sort((a, b) => b.releaseDate.compareTo(a.releaseDate));
    return releases.take(20).map((release) => release.item).toList();
  }

  Future<MediaDetails> details(MediaItem item) async {
    final pathType = item.type == 'series' ? 'tv' : 'movie';
    final resolvedId = int.tryParse(item.id) == null
        ? await resolveTmdbId(item)
        : item.id;
    final id = resolvedId.isEmpty ? item.id : resolvedId;
    final cacheKey = '$pathType:$id';
    final cached = _detailsCache[cacheKey];
    if (cached != null) return cached;
    final data = await _get('/$pathType/${Uri.encodeComponent(id)}', {
      'append_to_response': 'credits',
    });
    final details = MediaDetails.fromTmdb(data);
    if (_detailsCache.length >= 100)
      _detailsCache.remove(_detailsCache.keys.first);
    _detailsCache[cacheKey] = details;
    return details;
  }

  Future<List<MediaItem>> search(String query) async {
    final data = await _get('/search/multi', {'query': query});
    return ((data['results'] as List?) ?? const [])
        .whereType<Map>()
        .where((e) => e['media_type'] == 'movie' || e['media_type'] == 'tv')
        .map((e) => MediaItem.fromTmdb(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<MediaItem> resolveIds(MediaItem item) async {
    if (item.externalId.isNotEmpty || int.tryParse(item.id) == null)
      return item;
    final type = item.type == 'series' ? 'tv' : 'movie';
    try {
      final result = await _get(
        '/$type/${Uri.encodeComponent(item.id)}/external_ids',
      );
      return item.copyWith(externalId: '${result['imdb_id'] ?? ''}');
    } catch (_) {
      return item;
    }
  }

  Future<String> resolveTmdbId(MediaItem item) async {
    if (int.tryParse(item.id) != null) return item.id;
    final externalId = item.externalId.isNotEmpty ? item.externalId : item.id;
    if (!externalId.startsWith('tt')) return '';
    final cacheKey = '${item.type}:$externalId';
    final cached = _resolvedTmdbIds[cacheKey];
    if (cached != null) return cached;
    try {
      final result = await _get('/find/${Uri.encodeComponent(externalId)}', {
        'external_source': 'imdb_id',
      });
      final key = item.type == 'series' ? 'tv_results' : 'movie_results';
      final entries = (result[key] as List? ?? const []).whereType<Map>();
      final id = entries.isEmpty ? '' : '${entries.first['id'] ?? ''}';
      if (id.isNotEmpty) {
        if (_resolvedTmdbIds.length >= 200) {
          _resolvedTmdbIds.remove(_resolvedTmdbIds.keys.first);
        }
        _resolvedTmdbIds[cacheKey] = id;
      }
      return id;
    } catch (_) {
      return '';
    }
  }

  Future<List<Map<String, dynamic>>> seasons(MediaItem item) async {
    if (item.type != 'series') return [];
    final id = await _seriesTmdbId(item);
    if (id.isEmpty) return [];
    final cached = _seasonsCache[id];
    if (cached != null) return cached;
    final data = await _get('/tv/${Uri.encodeComponent(id)}');
    final result = ((data['seasons'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => (e['season_number'] as num? ?? 0) > 0)
        .toList();
    if (_seasonsCache.length >= 100) {
      _seasonsCache.remove(_seasonsCache.keys.first);
    }
    _seasonsCache[id] = result;
    return result;
  }

  Future<List<Map<String, dynamic>>> episodes(
    MediaItem item,
    int season,
  ) async {
    final id = await _seriesTmdbId(item);
    if (id.isEmpty) return [];
    final cacheKey = '$id:$season';
    final cached = _episodesCache[cacheKey];
    if (cached != null) return cached;
    final data = await _get('/tv/${Uri.encodeComponent(id)}/season/$season');
    final result = ((data['episodes'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (_episodesCache.length >= 100) {
      _episodesCache.remove(_episodesCache.keys.first);
    }
    _episodesCache[cacheKey] = result;
    return result;
  }

  Future<String> _seriesTmdbId(MediaItem item) async {
    return int.tryParse(item.id) != null ? item.id : resolveTmdbId(item);
  }

  Future<List<Map<String, dynamic>>> allEpisodes(MediaItem item) async {
    final seasonsList = await seasons(item);
    final output = <Map<String, dynamic>>[];
    for (final season in seasonsList) {
      output.addAll(
        await episodes(item, (season['season_number'] as num).toInt()),
      );
    }
    return output;
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String> params = const {},
  ]) async {
    if (_key.isEmpty) throw Exception('TMDB API key is not configured.');
    final uri = Uri.parse(
      '$_base$path',
    ).replace(queryParameters: {'api_key': _key, ...params});
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('TMDB request failed (${response.statusCode}).');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
