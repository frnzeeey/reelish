import '../discovery/discovery_controller.dart';
import '../models/media_item.dart';
import '../services/paged_feed_controller.dart';
import '../services/tmdb_service.dart';

/// What Home's catalog holds, for the TV pages. The same controllers and
/// lists the mobile Home shows: TV adds no requests of its own except
/// Trending, which mobile loads on its own tab.
class TvCatalog {
  const TvCatalog({
    required this.tmdb,
    required this.movies,
    required this.series,
    required this.releases,
    required this.top10,
    required this.spotlight,
    required this.continueWatching,
    required this.catalogSettled,
    required this.resumeFraction,
    required this.favoriteKeys,
    required this.hasSources,
    this.catalogError,
    this.discovery,
    this.showGenrePrompt = false,
  });

  final TmdbService tmdb;
  final PagedFeedController movies;
  final PagedFeedController series;
  final PagedFeedController releases;
  final PagedFeedController top10;

  /// The spotlight titles; the first is featured before anything has focus.
  final List<MediaItem> spotlight;
  final List<MediaItem> continueWatching;

  /// Page 1 of Movies and Series has loaded; Top 10 is built from it.
  final bool catalogSettled;
  final double Function(MediaItem item) resumeFraction;

  /// `type:id` of the titles on the viewer's list.
  final Set<String> favoriteKeys;

  /// Whether any provider repository is installed.
  final bool hasSources;

  /// Why nothing could be loaded, when nothing could.
  final String? catalogError;

  /// Personalised rows for the signed-in account; null where they are not
  /// wanted (tests of other rows).
  final DiscoveryController? discovery;

  /// Offer the genre step on Home: an existing account without discovery
  /// preferences (see `OnboardingNeed.prompt`).
  final bool showGenrePrompt;

  bool isFavorite(MediaItem item) =>
      favoriteKeys.contains('${item.type}:${item.id}');
}
