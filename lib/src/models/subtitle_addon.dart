import 'dart:convert';

/// An installed Stremio subtitle addon.
///
/// Decides which addons can serve subtitles for a title, and builds their
/// resource URLs.
class SubtitleAddon {
  const SubtitleAddon({
    required this.manifestUrl,
    required this.id,
    required this.name,
    this.types = const [],
    this.idPrefixes = const [],
    this.enabled = true,
  });

  /// Preinstalled: the OpenSubtitles v3 addon. Manifest
  /// verified from opensubtitles-v3.strem.io.
  static const openSubtitlesV3 = SubtitleAddon(
    manifestUrl: 'https://opensubtitles-v3.strem.io/manifest.json',
    id: 'org.stremio.opensubtitlesv3',
    name: 'OpenSubtitles v3',
    types: ['movie', 'series'],
    idPrefixes: ['tt'],
  );

  final String manifestUrl;
  final String id;
  final String name;

  /// Content types of the `subtitles` resource; empty means any.
  final List<String> types;

  /// Id prefixes of the `subtitles` resource; empty means any.
  final List<String> idPrefixes;
  final bool enabled;

  SubtitleAddon copyWith({bool? enabled}) => SubtitleAddon(
    manifestUrl: manifestUrl,
    id: id,
    name: name,
    types: types,
    idPrefixes: idPrefixes,
    enabled: enabled ?? this.enabled,
  );

  static String _canonicalType(String type) {
    final value = type.trim().toLowerCase();
    return value == 'tv' ? 'series' : value;
  }

  /// Whether this addon serves subtitles for [type] and [videoId].
  bool supports(String type, String videoId) {
    final wanted = _canonicalType(type);
    final typeOk =
        types.isEmpty || types.any((value) => _canonicalType(value) == wanted);
    final prefixOk =
        idPrefixes.isEmpty ||
        idPrefixes.any((prefix) => videoId.startsWith(prefix));
    return typeOk && prefixOk;
  }

  /// `{base}/subtitles/{type}/{id}.json`, keeping a configured addon's query.
  Uri resourceUri(String type, String videoId) {
    final query = manifestUrl.contains('?')
        ? manifestUrl.substring(manifestUrl.indexOf('?') + 1)
        : '';
    final base = manifestUrl
        .split('?')
        .first
        .replaceFirst(RegExp(r'/manifest\.json$'), '');
    final url =
        '$base/subtitles/${_canonicalType(type)}/${encodeSegment(videoId)}.json'
        '${query.trim().isEmpty ? '' : '?$query'}';
    return Uri.parse(url);
  }

  /// Encodes one URL path segment: only `A-Z a-z 0-9 - _ . ~` stay
  /// literal, so `tt0944947:2:3` becomes `tt0944947%3A2%3A3`.
  static String encodeSegment(String value) {
    final out = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final unreserved =
          (byte >= 0x61 && byte <= 0x7a) ||
          (byte >= 0x41 && byte <= 0x5a) ||
          (byte >= 0x30 && byte <= 0x39) ||
          byte == 0x2d ||
          byte == 0x5f ||
          byte == 0x2e ||
          byte == 0x7e;
      if (unreserved) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  /// Reads a Stremio manifest. Throws [FormatException] if it has no
  /// `subtitles` resource. Resources may be plain names (using the
  /// manifest's `types`/`idPrefixes`) or objects with their own.
  static SubtitleAddon fromManifest(String manifestUrl, Object? json) {
    if (json is! Map) {
      throw const FormatException('That link is not an addon manifest.');
    }
    List<String> strings(Object? value) => value is List
        ? [
            for (final item in value)
              if (item is String) item,
          ]
        : const [];
    final resources = json['resources'];
    Map<String, Object?>? subtitles;
    if (resources is List) {
      for (final resource in resources) {
        final name = resource is String
            ? resource
            : (resource is Map ? '${resource['name'] ?? ''}' : '');
        if (name.toLowerCase() == 'subtitles' ||
            name.toLowerCase() == 'subtitle') {
          subtitles = resource is Map
              ? Map<String, Object?>.from(resource)
              : const {};
          break;
        }
      }
    }
    if (subtitles == null) {
      throw const FormatException('This addon does not provide subtitles.');
    }
    final id = '${json['id'] ?? ''}'.trim();
    final name = '${json['name'] ?? ''}'.trim();
    if (id.isEmpty) throw const FormatException('The manifest has no id.');
    return SubtitleAddon(
      manifestUrl: manifestUrl,
      id: id,
      name: name.isEmpty ? id : name,
      types: subtitles.containsKey('types')
          ? strings(subtitles['types'])
          : strings(json['types']),
      idPrefixes: subtitles.containsKey('idPrefixes')
          ? strings(subtitles['idPrefixes'])
          : strings(json['idPrefixes']),
    );
  }

  Map<String, Object?> toJson() => {
    'manifestUrl': manifestUrl,
    'id': id,
    'name': name,
    'types': types,
    'idPrefixes': idPrefixes,
    'enabled': enabled,
  };

  static SubtitleAddon? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['manifestUrl'];
    final id = json['id'];
    if (url is! String || id is! String) return null;
    List<String> strings(Object? value) => value is List
        ? [
            for (final item in value)
              if (item is String) item,
          ]
        : const [];
    return SubtitleAddon(
      manifestUrl: url,
      id: id,
      name: '${json['name'] ?? id}',
      types: strings(json['types']),
      idPrefixes: strings(json['idPrefixes']),
      enabled: json['enabled'] != false,
    );
  }
}
