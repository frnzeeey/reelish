import '../models/stream_source.dart';

/// Cheap source checks before native player open. The player remains the
/// authoritative probe; network preflight here must not fetch whole media.
class StreamValidator {
  const StreamValidator();

  void validate(StreamSource source) {
    if (!source.isPlayable) {
      throw const FormatException(
        'Provider returned an expired or invalid source.',
      );
    }
    if (!source.isTorrent) {
      final uri = Uri.tryParse(source.url.trim());
      if (uri == null || uri.host.isEmpty || !uri.hasAuthority) {
        throw const FormatException(
          'Provider returned a malformed stream URL.',
        );
      }
    }
  }
}
