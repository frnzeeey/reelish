import 'package:flutter/material.dart';
import '../models/content_advisory.dart';
import '../models/episode_context.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../services/storage_service.dart';
import '../services/stream_discovery.dart';
import '../services/playback_settings_controller.dart';
import '../platform/device_capabilities.dart';
import '../theme/glass_theme.dart';
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
    this.onPlayEpisode,
    this.episodeLabel = '',
    this.episodeContext,
    this.season,
    this.episode,
    this.imdbId,
    this.details,
    this.advisory,
    this.startFromBeginning = false,
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
  final EpisodeSwitch? onPlayEpisode;
  final String episodeLabel;
  final Future<EpisodeContext?>? episodeContext;
  final int? season;
  final int? episode;
  final Future<String>? imdbId;
  final Future<MediaDetails?>? details;
  final Future<ContentAdvisory?>? advisory;

  /// Start over: play from the beginning instead of the saved position.
  final bool startFromBeginning;

  // The player's own theme: dark in every app theme, since it sits over
  // video (GlassTheme.player). Its sheets and dialogs open under it.
  @override
  Widget build(BuildContext context) => Theme(
    data: GlassTheme.player(tv: DeviceCapabilities.usesTvLayout),
    child: _scaffold(),
  );

  Widget _scaffold() => Scaffold(
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
      onPlayEpisode: onPlayEpisode,
      episodeLabel: episodeLabel,
      episodeContext: episodeContext,
      season: season,
      episode: episode,
      imdbId: imdbId,
      details: details,
      advisory: advisory,
      startFromBeginning: startFromBeginning,
    ),
  );
}
