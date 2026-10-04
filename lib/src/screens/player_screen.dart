import 'package:flutter/material.dart';
import '../models/episode_context.dart';
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
    this.onRediscover,
    this.onNextEpisode,
    this.episodeLabel = '',
    this.episodeContext,
    this.season,
    this.episode,
    this.imdbId,
  });
  final MediaItem item;
  final StreamSource source;
  final List<StreamSource> sources;
  final StorageService storage;
  final PlaybackSettingsController playbackSettings;
  final bool sourceFromCache;
  final String? streamCacheKey;
  final StreamDiscovery? discovery;
  final StreamDiscovery Function()? onRediscover;
  final Future<void> Function()? onNextEpisode;
  final String episodeLabel;
  final Future<EpisodeContext?>? episodeContext;
  final int? season;
  final int? episode;
  final Future<String>? imdbId;

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
      onRediscover: onRediscover,
      onNextEpisode: onNextEpisode,
      episodeLabel: episodeLabel,
      episodeContext: episodeContext,
      season: season,
      episode: episode,
      imdbId: imdbId,
    ),
  );
}
