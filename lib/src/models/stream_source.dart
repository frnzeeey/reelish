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
    this.infoHash = '',
    this.fileIdx = -1,
    this.torrentSources = const [],
  });
  final String name, url, description, providerName;
  final String infoHash;
  final int fileIdx;
  final List<String> torrentSources;
  bool get isTorrent =>
      url.toLowerCase().startsWith('magnet:') ||
      (url.isEmpty && infoHash.isNotEmpty);
  bool get isPlayable => isTorrent || _hasSupportedUrl(url);
  final Map<String, String> headers;
  final List<SubtitleTrack> subtitles;

  static bool _hasSupportedUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    switch (uri.scheme.toLowerCase()) {
      case 'http':
      case 'https':
      case 'rtmp':
      case 'rtmps':
      case 'rtsp':
      case 'rtsps':
      case 'rtp':
      case 'udp':
      case 'tcp':
      case 'srt':
      case 'mms':
      case 'mmsh':
        return uri.hasAuthority && uri.host.isNotEmpty;
      case 'file':
        return uri.path.isNotEmpty;
      default:
        return false;
    }
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
      final key = entry.key.trim().toLowerCase();
      final value = entry.value;
      if (key.isNotEmpty && value != null) {
        normalizedHeaders[key] = '$value';
      }
    }
    final sourceList = j['sources'];
    final torrentSources = sourceList is List
        ? sourceList
              .whereType<String>()
              .where((source) => source.startsWith('tracker:'))
              .toList()
        : const <String>[];
    return StreamSource(
      name: '${j['name'] ?? j['title'] ?? 'Stream'}',
      url: url,
      description: '${j['description'] ?? j['quality'] ?? j['title'] ?? ''}',
      providerName: providerName,
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
}
