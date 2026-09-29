class SubtitleTrack {
  const SubtitleTrack({
    required this.url,
    this.lang = 'Unknown',
    this.id = '',
    this.format = '',
    this.headers = const {},
  });
  final String url, lang, id, format;
  final Map<String, String> headers;
  factory SubtitleTrack.fromJson(Map<String, dynamic> j) => SubtitleTrack(
    url: '${j['url'] ?? ''}',
    lang: '${j['lang'] ?? j['language'] ?? 'Unknown'}',
    id: '${j['id'] ?? ''}',
    format: '${j['format'] ?? ''}',
    headers: j['headers'] is Map
        ? (j['headers'] as Map).map((key, value) => MapEntry('$key', '$value'))
        : const {},
  );
}

class StreamSource {
  const StreamSource({
    required this.name,
    required this.url,
    this.description = '',
    this.headers = const {},
    this.subtitles = const [],
    this.providerName = '',
    this.sourceId = '',
    this.quality = '',
    this.container = '',
    this.codec = '',
    this.expiresAt,
    this.isDirect = true,
    this.infoHash = '',
    this.fileIdx = -1,
    this.torrentSources = const [],
  });
  final String name, url, description, providerName;
  final String sourceId, quality, container, codec;
  final DateTime? expiresAt;
  final bool isDirect;
  final String infoHash;
  final int fileIdx;
  final List<String> torrentSources;
  bool get isTorrent =>
      url.toLowerCase().startsWith('magnet:') ||
      (url.isEmpty && infoHash.isNotEmpty);
  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now());
  bool get isPlayable =>
      !isExpired &&
      headers.entries.every(
        (entry) =>
            RegExp(
              r"^[!#$%&'*+.^_`|~0-9a-z-]+$",
            ).hasMatch(entry.key.toLowerCase()) &&
            !entry.value.contains(RegExp(r'[\x00-\x08\x0a-\x1f\x7f]')),
      ) &&
      (isTorrent || _hasSupportedUrl(url));
  final Map<String, String> headers;
  final List<SubtitleTrack> subtitles;

  static bool _hasSupportedUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    if (uri.userInfo.isNotEmpty || uri.scheme.toLowerCase() == 'file') {
      return false;
    }
    return const {
          'http',
          'https',
          'rtmp',
          'rtmps',
          'rtsp',
          'rtsps',
          'rtp',
          'udp',
          'tcp',
          'srt',
          'mms',
          'mmsh',
        }.contains(uri.scheme.toLowerCase()) &&
        uri.hasAuthority &&
        uri.host.isNotEmpty;
  }

  static bool isSafeTorrentTracker(String raw) {
    final uri = Uri.tryParse(raw);
    return uri != null &&
        const {'http', 'https', 'udp'}.contains(uri.scheme.toLowerCase()) &&
        uri.hasAuthority &&
        uri.userInfo.isEmpty &&
        uri.host.isNotEmpty;
  }

  factory StreamSource.fromJson(
    Map<String, dynamic> j, {
    String providerName = '',
  }) {
    // Nuvio providers generally return a URL string, but some return the
    // Stremio-style `{ url, headers }` object. Preserve those headers and
    // unwrap the actual URL before validating or handing it to the player.
    final rawUrl = j['url'] ?? j['link'] ?? j['stream'];
    final urlObject = rawUrl is Map ? rawUrl : null;
    final url = urlObject == null
        ? '${rawUrl ?? ''}'.trim()
        : '${urlObject['url'] ?? ''}'.trim();
    final bh = j['behaviorHints'];
    final ph = bh is Map ? bh['proxyHeaders'] : null;
    final request = ph is Map ? ph['request'] : null;
    final raw = <String, dynamic>{
      if (j['headers'] is Map)
        ...Map<String, dynamic>.from(j['headers'] as Map),
      if (urlObject?['headers'] is Map)
        ...Map<String, dynamic>.from(urlObject!['headers'] as Map),
      if (request is Map) ...Map<String, dynamic>.from(request),
    };
    final normalizedHeaders = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim();
      final value = entry.value;
      if (key.isNotEmpty &&
          (value is String || value is num || value is bool)) {
        normalizedHeaders[key] = '$value';
      }
    }
    final sourceList = j['sources'];
    final torrentSources = sourceList is List
        ? sourceList
              .whereType<String>()
              .where((source) => source.startsWith('tracker:'))
              .where((source) => isSafeTorrentTracker(source.substring(8)))
              .toList()
        : const <String>[];
    return StreamSource(
      name: '${j['name'] ?? j['title'] ?? 'Stream'}',
      url: url,
      description: '${j['description'] ?? j['quality'] ?? j['title'] ?? ''}',
      providerName: providerName,
      sourceId: '${j['id'] ?? j['sourceId'] ?? ''}',
      quality: '${j['quality'] ?? j['resolution'] ?? ''}',
      container: '${j['container'] ?? j['type'] ?? ''}',
      codec: '${j['codec'] ?? ''}',
      expiresAt: _parseExpiration(
        j['expiresAt'] ?? j['expires'] ?? j['expiry'],
      ),
      isDirect: j['isDirect'] != false && j['direct'] != false,
      infoHash: '${j['infoHash'] ?? ''}',
      fileIdx: int.tryParse('${j['fileIdx'] ?? -1}') ?? -1,
      torrentSources: torrentSources,
      headers: normalizedHeaders,
      subtitles: (j['subtitles'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => SubtitleTrack.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  static DateTime? _parseExpiration(dynamic value) {
    if (value == null) return null;
    final raw = value.toString();
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed;
    final seconds = int.tryParse(raw);
    if (seconds == null) return null;
    // Unix timestamps below 10^12 are conventionally expressed in seconds.
    return DateTime.fromMillisecondsSinceEpoch(
      seconds < 1000000000000 ? seconds * 1000 : seconds,
      isUtc: true,
    );
  }
}
