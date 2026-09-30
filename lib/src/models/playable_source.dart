import 'stream_source.dart';
import 'stream_type.dart';

/// Fully prepared input for an engine. Provider fields remain attached through
/// playback, including the exact header map used to authorize media requests.
class PlayableSource {
  const PlayableSource({
    required this.source,
    required this.uri,
    required this.headers,
    required this.streamType,
  });

  final StreamSource source;
  final Uri uri;
  final Map<String, String> headers;
  final StreamType streamType;
}
