// Universal Search as a full-screen page, opened from the phone's Home
// header. TV and Windows show UniversalSearchView as their Search page.

import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../search/playback_availability.dart';
import '../../search/universal_search_controller.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import 'universal_search_view.dart';

class UniversalSearchScreen extends StatelessWidget {
  const UniversalSearchScreen({
    super.key,
    required this.search,
    required this.onOpenTitle,
    this.availability,
  });

  final UniversalSearchController search;
  final ValueChanged<MediaItem> onOpenTitle;
  final PlaybackAvailability? availability;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: GlassTheme.background,
    body: SafeArea(
      child: UniversalSearchView(
        search: search,
        availability: availability,
        onOpenTitle: onOpenTitle,
        leading: IconButton(
          tooltip: 'Close search',
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(ReelishIcons.back),
        ),
      ),
    ),
  );
}
