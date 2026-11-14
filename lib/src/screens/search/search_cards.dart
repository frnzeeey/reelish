// Universal Search's result cards, one layout per kind: posters for movies
// and series, round portraits for people, artwork for collections, and a
// wider card for the top result. Shared by phone, TV and Windows: on TV each
// card is a remote focus target, elsewhere it takes taps and clicks.

import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../platform/device_capabilities.dart';
import '../../search/search_models.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/tv/tv_focus.dart';

/// Card sizes for this interface.
abstract final class SearchSizes {
  static double get poster => DeviceCapabilities.isTv
      ? 170
      : DeviceCapabilities.isDesktop
      ? 160
      : 118;
  static double get portrait => DeviceCapabilities.isTv
      ? 130
      : DeviceCapabilities.isDesktop
      ? 120
      : 96;
  static double get collection => DeviceCapabilities.isTv
      ? 300
      : DeviceCapabilities.isDesktop
      ? 280
      : 220;
}

/// What a title is, for a label: "2021 · Movie · ★ 7.8 TMDB".
String titleFacts(MediaItem item, {bool rating = true}) => [
  if (item.year.isNotEmpty) item.year,
  item.type == 'series' ? 'Series' : 'Movie',
  if (rating &&
      item.rating.isNotEmpty &&
      item.rating != '0.0' &&
      item.voteCount > 0)
    '★ ${item.rating}',
].join(' · ');

/// A tappable (or, on TV, focusable) card.
class SearchTap extends StatelessWidget {
  const SearchTap({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.radius = AppRadius.md,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;
  final double radius;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    if (DeviceCapabilities.isTv) {
      return TvFocusable(
        onSelect: onTap,
        autofocus: autofocus,
        borderRadius: radius,
        focusScale: 1.04,
        semanticLabel: label,
        child: child,
      );
    }
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          autofocus: autofocus,
          onTap: onTap,
          hoverColor: GlassTheme.primary.withValues(alpha: .08),
          child: child,
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.url, required this.icon, this.round = false});

  final String url;
  final IconData icon;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: GlassTheme.elevatedSurface,
      child: Center(child: Icon(icon, color: GlassTheme.muted, size: 32)),
    );
    final image = url.isEmpty
        ? placeholder
        : ArtworkImage.network(
            url,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => placeholder,
          );
    return round
        ? ClipOval(child: image)
        : ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: image,
          );
  }
}

class SearchTitleCard extends StatelessWidget {
  const SearchTitleCard({
    super.key,
    required this.item,
    required this.onOpen,
    this.width,
  });

  final MediaItem item;
  final VoidCallback onOpen;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final width = this.width ?? SearchSizes.poster;
    return SearchTap(
      label: '${item.name}, ${titleFacts(item)}',
      onTap: onOpen,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 2 / 3,
                child: _Artwork(
                  url: item.poster,
                  icon: item.type == 'series'
                      ? ReelishIcons.tv
                      : ReelishIcons.movie,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: AppTextSize.label,
                ),
              ),
              Text(
                titleFacts(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.caption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SearchPersonCard extends StatelessWidget {
  const SearchPersonCard({
    super.key,
    required this.person,
    required this.onOpen,
  });

  final PersonHit person;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final size = SearchSizes.portrait;
    final knownFor = person.knownFor.join(', ');
    return SearchTap(
      label:
          '${person.name}, ${person.role}'
          '${knownFor.isEmpty ? '' : ', known for $knownFor'}',
      onTap: onOpen,
      radius: AppRadius.lg,
      child: SizedBox(
        width: size + 16,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: size,
                child: _Artwork(
                  url: person.profileUrl,
                  icon: ReelishIcons.person,
                  round: true,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                person.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: AppTextSize.label,
                ),
              ),
              Text(
                person.role,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.primary,
                  fontSize: AppTextSize.caption,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (knownFor.isNotEmpty)
                Text(
                  knownFor,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GlassTheme.muted,
                    fontSize: AppTextSize.caption,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SearchCollectionCard extends StatelessWidget {
  const SearchCollectionCard({
    super.key,
    required this.collection,
    required this.onOpen,
  });

  final CollectionHit collection;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final width = SearchSizes.collection;
    return SearchTap(
      label: '${collection.name}, movie collection',
      onTap: onOpen,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: _Artwork(
                  url: collection.backdropUrl.isNotEmpty
                      ? collection.backdropUrl
                      : collection.posterUrl,
                  icon: ReelishIcons.stack,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                collection.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: AppTextSize.label,
                ),
              ),
              Text(
                collection.overview.isEmpty
                    ? 'Movie collection'
                    : collection.overview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTheme.muted,
                  fontSize: AppTextSize.caption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
