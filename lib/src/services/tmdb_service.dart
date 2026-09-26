import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../tmdb_config.local.dart' as tmdb_config;
import '../models/media_item.dart';

class TmdbService {
  static const _base = 'https://api.themoviedb.org/3';
  static const _key = tmdb_config.tmdbApiKey;

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
    try {
      final result = await _get('/find/${Uri.encodeComponent(externalId)}', {
        'external_source': 'imdb_id',
      });
      final key = item.type == 'series' ? 'tv_results' : 'movie_results';
      final entries = (result[key] as List? ?? const []).whereType<Map>();
      return entries.isEmpty ? '' : '${entries.first['id'] ?? ''}';
    } catch (_) {
      return '';
    }
  }

  Future<List<Map<String, dynamic>>> seasons(MediaItem item) async {
    if (item.type != 'series') return [];
    final data = await _get('/tv/${Uri.encodeComponent(item.id)}');
    return ((data['seasons'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => (e['season_number'] as num? ?? 0) > 0)
        .toList();
  }

  Future<List<Map<String, dynamic>>> episodes(
    MediaItem item,
    int season,
  ) async {
    final data = await _get(
      '/tv/${Uri.encodeComponent(item.id)}/season/$season',
    );
    return ((data['episodes'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
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
