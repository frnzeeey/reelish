import '../models/stream_source.dart';

/// Applies provider and torrent playback preferences to a returned source.
bool isPlaybackSourceAllowed(
  StreamSource source, {
  Set<String>? allowedProviderIds,
  required bool allowTorrents,
}) =>
    (allowedProviderIds == null ||
        allowedProviderIds.contains(source.providerId)) &&
    (allowTorrents || !source.isTorrent);
