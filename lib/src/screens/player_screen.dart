import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../services/storage_service.dart';
import '../services/stream_discovery.dart';
import '../services/playback_settings_controller.dart';
import '../widgets/player/custom_video_player.dart';

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({
    super.key,
    required this.item,
    required this.source,
    required this.sources,
    required this.storage,
    required this.playbackSettings,
    this.sourceFromCache = false,
    this.streamCacheKey,
    this.discovery,
    this.onRefreshSources,
    this.onNextEpisode,
  });
  final MediaItem item;
  final StreamSource source;
  final List<StreamSource> sources;
  final StorageService storage;
  final PlaybackSettingsController playbackSettings;
  final bool sourceFromCache;
  final String? streamCacheKey;
  final StreamDiscovery? discovery;
  final Future<List<StreamSource>> Function()? onRefreshSources;
  final Future<void> Function()? onNextEpisode;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: CustomVideoPlayer(
      item: item,
      source: source,
      sources: sources,
      subtitles: source.subtitles,
      storage: storage,
      playbackSettings: playbackSettings,
      sourceFromCache: sourceFromCache,
      streamCacheKey: streamCacheKey,
      discovery: discovery,
      onRefreshSources: onRefreshSources,
      onNextEpisode: onNextEpisode,
    ),
  );
}
