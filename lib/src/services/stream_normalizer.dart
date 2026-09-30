import '../models/stream_source.dart';
import '../models/stream_type.dart';

class NormalizedStreamSource {
  const NormalizedStreamSource({
    required this.source,
    required this.streamType,
  });

  final StreamSource source;
  final StreamType streamType;
}

/// Converts provider-specific JSON shapes into Reelish's canonical source.
class StreamNormalizer {
  const StreamNormalizer();

  NormalizedStreamSource normalize(
    Map<String, dynamic> raw, {
    required String providerId,
    required String providerName,
  }) {
    final source = StreamSource.fromJson(
      raw,
      providerName: providerName,
    ).copyWithProviderId(providerId);
    return NormalizedStreamSource(
      source: source,
      streamType: source.detectedStreamType,
    );
  }
}
