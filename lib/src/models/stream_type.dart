enum StreamType { hls, dash, progressive, torrent, local, unknown }

extension StreamTypeDetection on StreamType {
  static StreamType detect({
    required String url,
    String? mimeType,
    String? hint,
  }) {
    final normalizedHint = (hint ?? '').toLowerCase();
    final normalizedMime = (mimeType ?? '')
        .toLowerCase()
        .split(';')
        .first
        .trim();
    final uri = Uri.tryParse(url.trim());
    final path = (uri?.path ?? url).toLowerCase();
    if (url.toLowerCase().startsWith('magnet:')) return StreamType.torrent;
    if (uri != null &&
        (uri.host == '127.0.0.1' ||
            uri.host == '::1' ||
            uri.host == 'localhost')) {
      return StreamType.local;
    }
    if (normalizedHint.contains('mpegurl') ||
        normalizedHint == 'hls' ||
        normalizedMime == 'application/vnd.apple.mpegurl' ||
        normalizedMime == 'application/x-mpegurl' ||
        path.endsWith('.m3u8')) {
      return StreamType.hls;
    }
    if (normalizedHint.contains('dash') ||
        normalizedMime == 'application/dash+xml' ||
        path.endsWith('.mpd')) {
      return StreamType.dash;
    }
    if (normalizedMime.startsWith('video/') ||
        RegExp(
          r'\.(mp4|m4v|webm|mkv|mov|avi|ts|mpeg|mpg)(?:$|[?#])',
        ).hasMatch(url.toLowerCase())) {
      return StreamType.progressive;
    }
    return StreamType.unknown;
  }
}
