import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../models/stream_source.dart';
import '../services/storage_service.dart';
import '../services/stream_discovery.dart';
import '../widgets/player/custom_video_player.dart';

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({
    super.key,
    required this.item,
    required this.source,
    required this.sources,
    required this.storage,
    this.discovery,
    this.onRefreshSources,
  });
  final MediaItem item;
  final StreamSource source;
  final List<StreamSource> sources;
  final StorageService storage;
  final StreamDiscovery? discovery;
  final Future<List<StreamSource>> Function()? onRefreshSources;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: CustomVideoPlayer(
      item: item,
      source: source,
      sources: sources,
      subtitles: source.subtitles,
      storage: storage,
      discovery: discovery,
      onRefreshSources: onRefreshSources,
    ),
  );
}
