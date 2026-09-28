import 'dart:convert';

import 'package:http/http.dart' as http;

class OpenSubtitleResult {
  const OpenSubtitleResult({
    required this.id,
    required this.url,
    required this.language,
    required this.name,
    required this.format,
    this.headers = const {},
  });

  final String id;
  final String url;
  final String language;
  final String name;
  final String format;
  final Map<String, String> headers;
}

/// Uses the OpenSubtitles v3 Stremio addon, the same addon protocol Nuvio
/// uses for addon-provided subtitles. This avoids requiring a user's API key.
class OpenSubtitlesService {
  static const _addonBase = 'https://opensubtitles-v3.strem.io';

  Future<List<OpenSubtitleResult>> search({
    required String type,
    required String imdbId,
    required String fallbackId,
    required String subtitleQuery,
  }) async {
    final baseId = imdbId.startsWith('tt') ? imdbId : fallbackId;
    if (baseId.isEmpty) throw Exception('This title has no IMDb ID to search.');

    var videoId = baseId;
    if (type == 'series') {
      final episode = RegExp(
        r'S(\d{1,2})E(\d{1,2})',
        caseSensitive: false,
      ).firstMatch(subtitleQuery);
      if (episode == null) {
        throw Exception('Select a series episode before searching subtitles.');
      }
      videoId +=
          ':${int.parse(episode.group(1)!)}:${int.parse(episode.group(2)!)}';
    }

    final uri = Uri.parse('$_addonBase/subtitles/$type/$videoId.json');
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'OpenSubtitles v3 request failed (HTTP ${response.statusCode}).',
      );
    }

    final body = jsonDecode(response.body);
    final entries = body is Map ? body['subtitles'] : null;
    if (entries is! List) return [];

    return [
      for (final entry in entries)
        if (entry is Map && '${entry['url'] ?? ''}'.isNotEmpty)
          OpenSubtitleResult(
            id: '${entry['id'] ?? entry['url']}',
            url: '${entry['url']}',
            language: '${entry['lang'] ?? 'Unknown'}',
            name: '${entry['name'] ?? entry['title'] ?? ''}',
            format:
                Uri.tryParse(
                  '${entry['url']}',
                )?.pathSegments.last.split('.').last ??
                '',
            headers: entry['headers'] is Map
                ? (entry['headers'] as Map).map(
                    (key, value) => MapEntry('$key', '$value'),
                  )
                : const {},
          ),
    ];
  }
}
