import '../models/playable_source.dart';
import '../models/stream_source.dart';
import 'network_target_policy.dart';
import 'stream_validator.dart';

class SourcePreparer {
  SourcePreparer({
    NetworkDestinationValidator? destinations,
    StreamValidator validator = const StreamValidator(),
  }) : _destinations = destinations ?? NetworkDestinationValidator(),
       _validator = validator;

  final NetworkDestinationValidator _destinations;
  final StreamValidator _validator;

  Future<PlayableSource> prepare(
    StreamSource source, {
    bool allowLoopback = false,
  }) async {
    _validator.validate(source);
    final headers = Map<String, String>.of(source.headers);
    NetworkDestinationValidator.validateHeaders(headers);
    if (source.isTorrent) {
      return PlayableSource(
        source: source,
        uri: Uri.parse(source.url),
        headers: Map.unmodifiable(headers),
        streamType: source.detectedStreamType,
      );
    }
    final uri = Uri.parse(source.url.trim());
    if (allowLoopback &&
        uri.scheme == 'http' &&
        const {'127.0.0.1', '::1', 'localhost'}.contains(uri.host)) {
      return PlayableSource(
        source: source,
        uri: uri,
        headers: Map.unmodifiable(headers),
        streamType: source.detectedStreamType,
      );
    }
    await _destinations.resolveDestination(
      uri,
      allowedSchemes: const {
        'https',
        'http',
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
      },
    );
    return PlayableSource(
      source: source,
      uri: uri,
      headers: Map.unmodifiable(headers),
      streamType: source.detectedStreamType,
    );
  }
}
