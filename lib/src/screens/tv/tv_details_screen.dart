import 'dart:async';

import 'package:flutter/material.dart';
import '../../theme/reelish_icons.dart';

import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../models/tv_season.dart';
import '../../services/tmdb_service.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../viewmodels/details_view_model.dart';
import '../../watch_party/party_models.dart';
import '../../widgets/tv/tv_focus.dart';
import '../watch_party/party_widgets.dart';
import 'tv_browse.dart' show TvMetaLine, TvRating;
import '../../widgets/artwork_image.dart';

/// A movie or series on TV: the backdrop fills the screen behind the title,
/// details and actions, with Play focused; a series lists its seasons and
/// episodes below. Plays through the same flow as the mobile details page
/// ([onPlay] and [onPlayEpisode]), so provider search, source selection and
/// the player are unchanged.
class TvMediaDetailsScreen extends StatefulWidget {
  const TvMediaDetailsScreen({
    super.key,
    required this.item,
    required this.tmdb,
    required this.onPlay,
    required this.onPlayEpisode,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.onWatchTogether,
    this.onRemoveFromHistory,
    this.onStartOver,
    this.onCollections,
    this.onShare,
  });

  final MediaItem item;
  final TmdbService tmdb;
  final ValueChanged<BuildContext> onPlay;

  /// Chooses the collections the title is in. Without it the page offers
  /// no Collections button.
  final void Function(BuildContext context, MediaItem item)? onCollections;

  /// Shares the title with friends. Without it (Friends off) the page
  /// offers no Share button.
  final void Function(BuildContext context, MediaItem item)? onShare;

  /// Plays the movie from the beginning. Given only for a movie with a
  /// saved position; Play then reads Resume.
  final ValueChanged<BuildContext>? onStartOver;

  /// Starts a watch party for the movie or a chosen episode; without it the
  /// page offers no Watch together button.
  final void Function(BuildContext context, PartyContent content)?
  onWatchTogether;
  final void Function(BuildContext context, int season, int episode)
  onPlayEpisode;
  final bool isFavorite;

  /// Adds the title to My list or removes it; completes with whether it is
  /// on the list afterwards.
  final Future<bool> Function()? onToggleFavorite;

  /// Removes the title from the watch history. Without it the page offers
  /// no Remove from history button.
  final Future<void> Function()? onRemoveFromHistory;

  @override
  State<TvMediaDetailsScreen> createState() => _TvMediaDetailsScreenState();
}

class _TvMediaDetailsScreenState extends State<TvMediaDetailsScreen> {
  late final _model = DetailsViewModel(item: widget.item, tmdb: widget.tmdb);
  late bool _favorite = widget.isFavorite;
  Timer? _seasonFocus;

  // The page renders from the shared DetailsViewModel; these keep its
  // wording and the names the layout below reads.
  MediaDetails? get _details => _model.details;
  bool get _loading => _model.loadingDetails;
  String? get _error =>
      _model.detailsFailed ? 'Could not load extra details.' : null;
  bool get _loadingEpisodes => _model.loadingEpisodes;
  String? get _episodeError => switch (_model.episodeError) {
    EpisodeLoadError.seasons => 'Could not load episodes.',
    EpisodeLoadError.season => 'Could not load this season.',
    null => null,
  };
  List<TvSeason> get _seasons => _model.seasons;
  List<TvEpisode> get _episodes => _model.episodes;
  int? get _selectedSeason => _model.selectedSeason;

  bool get _isSeries => _model.isSeries;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
    _model.start();
  }

  @override
  void dispose() {
    _seasonFocus?.cancel();
    _model.removeListener(_onModelChanged);
    _model.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDetails() => _model.loadDetails();
  Future<void> _loadSeasons() => _model.loadSeasons();
  Future<void> _loadEpisodes(int season) => _model.selectSeason(season);

  /// A season shows its episodes once focus rests on it, so moving across
  /// the seasons does not load each one on the way.
  void _onSeasonFocused(int season) {
    _seasonFocus?.cancel();
    if (season == _selectedSeason) return;
    _seasonFocus = Timer(const Duration(milliseconds: 350), () {
      if (mounted) unawaited(_loadEpisodes(season));
    });
  }

  Future<void> _toggleFavorite() async {
    final toggle = widget.onToggleFavorite;
    if (toggle == null) return;
    try {
      final favorite = await toggle();
      if (mounted) setState(() => _favorite = favorite);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not update My list. Try again.')),
      );
    }
  }

  /// Cancel comes first, so Select never removes anything by accident.
  Future<void> _removeFromHistory() async {
    final remove = widget.onRemoveFromHistory;
    if (remove == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from history?'),
        content: const Text(
          'It leaves Continue watching and your watch history. My list does '
          'not change.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await remove();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not remove it. Try again.')),
      );
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final item = widget.item;
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (item.background.isNotEmpty)
            Positioned(
              top: 0,
              right: 0,
              width: tvBackdropWidth(context, .78),
              height: size.height * .9,
              // The fade starts at the image's own left edge, which falls on
              // a whole pixel, so no seam shows where the image begins.
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ArtworkImage.network(
                    item.background,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    cacheWidth:
                        (size.width *
                                .78 *
                                MediaQuery.devicePixelRatioOf(context))
                            .round(),
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  // Fades into the page, as on the TV Home: the page colour,
                  // so on a light theme the text below sits on a light wash
                  // (on a dark theme it equals the artwork scrim).
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          GlassTheme.background,
                          GlassTheme.background.withValues(alpha: .8),
                          GlassTheme.background.withValues(alpha: .2),
                          GlassTheme.background.withValues(alpha: 0),
                        ],
                        stops: [0, .25, .6, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  GlassTheme.background,
                  GlassTheme.background.withValues(alpha: 0),
                ],
                stops: [.1, .55],
              ),
            ),
          ),
          ListView(
            padding: const EdgeInsets.fromLTRB(
              TvSafeArea.horizontal,
              TvSafeArea.vertical + 12,
              TvSafeArea.horizontal,
              TvSafeArea.vertical + 24,
            ),
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: size.height * (_isSeries ? .62 : .8),
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: SizedBox(
                    width: size.width * .56,
                    child: _overview(context),
                  ),
                ),
              ),
              if (_isSeries) ..._episodeSection(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _overview(BuildContext context) {
    final item = widget.item;
    final details = _details;
    final rating = details?.rating.isNotEmpty == true
        ? details!.rating
        : item.rating;
    final synopsis = details?.overview.isNotEmpty == true
        ? details!.overview
        : item.description;
    final meta = [
      if (item.year.isNotEmpty) item.year,
      if (rating.isNotEmpty) TvRating(rating),
      if ((details?.runtimeMinutes ?? 0) > 0) '${details!.runtimeMinutes} min',
      if (details?.status.isNotEmpty == true) details!.status,
    ];
    final cast = details?.cast.take(5).map((member) => member.name).toList();
    // On the backdrop's fade into the page: white on a dark theme, the page
    // text on a light one.
    final ink = _ink;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _isSeries ? 'SERIES' : 'MOVIE',
          style: TextStyle(
            // The light accent reads on dark; on a light page the deeper
            // one keeps AA.
            color: GlassTheme.isLight
                ? GlassTheme.primary
                : GlassTheme.coralBright,
            fontSize: 14,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          item.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 44,
            height: 1.04,
            fontWeight: FontWeight.w900,
            letterSpacing: -1.2,
          ),
        ),
        const SizedBox(height: 12),
        TvMetaLine(
          parts: meta,
          style: TextStyle(
            color: ink.withValues(alpha: .867),
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (details?.genres.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(
            details!.genres.join(', '),
            style: TextStyle(color: GlassTheme.muted, fontSize: 14),
          ),
        ],
        if (details?.tagline.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          Text(
            details!.tagline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: ink.withValues(alpha: .7),
              fontStyle: FontStyle.italic,
              fontSize: 15,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          synopsis.isNotEmpty
              ? synopsis
              : 'No synopsis is available for this title.',
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: ink.withValues(alpha: .851),
            fontSize: 15,
            height: 1.5,
          ),
        ),
        if (cast != null && cast.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            'Starring ${cast.join(', ')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: GlassTheme.muted, fontSize: 14),
          ),
        ],
        const SizedBox(height: 24),
        Wrap(
          spacing: 14,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              autofocus: true,
              style: _actionStyle(filled: true),
              onPressed: () => widget.onPlay(context),
              icon: const Icon(ReelishIcons.play),
              label: Text(
                _isSeries
                    ? 'Play'
                    : widget.onStartOver != null
                    ? 'Resume'
                    : 'Play movie',
              ),
            ),
            if (widget.onStartOver case final startOver?)
              OutlinedButton.icon(
                style: _actionStyle(filled: false),
                onPressed: () => startOver(context),
                icon: const Icon(ReelishIcons.restart),
                label: const Text('Start over'),
              ),
            if (widget.onToggleFavorite != null)
              OutlinedButton.icon(
                style: _actionStyle(filled: false),
                onPressed: _toggleFavorite,
                icon: Icon(_favorite ? ReelishIcons.check : ReelishIcons.add),
                label: Text(_favorite ? 'On My list' : 'My list'),
              ),
            if (widget.onCollections case final collections?)
              OutlinedButton.icon(
                style: _actionStyle(filled: false),
                onPressed: () => collections(context, item),
                icon: const Icon(ReelishIcons.playlist),
                label: const Text('Collections'),
              ),
            if (widget.onShare case final share?)
              OutlinedButton.icon(
                style: _actionStyle(filled: false),
                onPressed: () => share(context, item),
                icon: const Icon(ReelishIcons.send),
                label: const Text('Share'),
              ),
            if (widget.onWatchTogether != null &&
                int.tryParse(widget.item.id) != null)
              OutlinedButton.icon(
                style: _actionStyle(filled: false),
                onPressed: _isSeries && _episodes.isEmpty
                    ? null
                    : _watchTogether,
                icon: const Icon(ReelishIcons.people),
                label: const Text('Watch together'),
              ),
            if (widget.onRemoveFromHistory != null)
              OutlinedButton.icon(
                style: _actionStyle(filled: false),
                onPressed: _removeFromHistory,
                icon: const Icon(ReelishIcons.historyOff),
                label: const Text('Remove from history'),
              ),
            if (_loading)
              SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: GlassTheme.primary,
                ),
              )
            else if (_error != null)
              TextButton.icon(
                onPressed: _loadDetails,
                icon: const Icon(ReelishIcons.refresh),
                label: Text('$_error Retry'),
              ),
          ],
        ),
      ],
    );
  }

  /// A movie starts its party at once; a series asks which episode of the
  /// season shown below.
  Future<void> _watchTogether() async {
    final start = widget.onWatchTogether;
    if (start == null) return;
    if (!_isSeries) {
      final content = PartyContent.fromItem(widget.item);
      if (content != null) start(context, content);
      return;
    }
    final season = _selectedSeason;
    if (season == null) return;
    final number = await pickPartyEpisode(
      context,
      season: season,
      episodes: _episodes,
    );
    if (number == null || !mounted) return;
    final content = PartyContent.fromItem(
      widget.item,
      season: season,
      episode: number,
    );
    if (content != null) start(context, content);
  }

  /// Text on the backdrop's fade into the page: white on a dark theme, the
  /// page text on a light one.
  static Color get _ink =>
      GlassTheme.isLight ? GlassTheme.textPrimary : Colors.white;

  static ButtonStyle _actionStyle({required bool filled}) =>
      (filled ? FilledButton.styleFrom : OutlinedButton.styleFrom)(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 26),
        shape: const StadiumBorder(),
        foregroundColor: filled ? GlassTheme.background : _ink,
        backgroundColor: filled ? GlassTheme.primary : null,
        // A button's textStyle replaces the theme's label style rather than
        // merging with it, so the family is named here.
        textStyle: const TextStyle(
          fontFamily: GlassTheme.fontFamily,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      );

  List<Widget> _episodeSection() => [
    const SizedBox(height: 28),
    const Text(
      'Episodes',
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
    ),
    const SizedBox(height: 12),
    if (_seasons.length > 1)
      // 48 dp chips between the list's 4 dp paddings.
      SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          itemCount: _seasons.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final season = _seasons[index].number;
            final selected = season == _selectedSeason;
            return TvFocusable(
              borderRadius: 22,
              focusScale: 1.04,
              semanticLabel: 'Season $season',
              onFocusChange: (focused) {
                if (focused) _onSeasonFocused(season);
              },
              onSelect: () {
                _seasonFocus?.cancel();
                if (season != _selectedSeason) unawaited(_loadEpisodes(season));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                alignment: Alignment.center,
                color: selected
                    ? GlassTheme.primary.withValues(alpha: .2)
                    : GlassTheme.surface,
                child: Text(
                  'Season $season',
                  style: TextStyle(
                    color: selected ? GlassTheme.coralBright : Colors.white,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    const SizedBox(height: 14),
    if (_loadingEpisodes)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: CircularProgressIndicator(color: GlassTheme.primary),
        ),
      )
    else if (_episodeError != null)
      Row(
        children: [
          Text(_episodeError!, style: TextStyle(color: GlassTheme.muted)),
          const SizedBox(width: 14),
          OutlinedButton.icon(
            onPressed: _seasons.isEmpty
                ? _loadSeasons
                : () => _loadEpisodes(_selectedSeason!),
            icon: const Icon(ReelishIcons.refresh),
            label: const Text('Retry'),
          ),
        ],
      )
    else if (_episodes.isEmpty)
      Text(
        'No episodes are available for this season.',
        style: TextStyle(color: GlassTheme.muted),
      )
    else
      SizedBox(
        height: _EpisodeCard.height + 24,
        child: ListView.separated(
          key: ValueKey('season-$_selectedSeason'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          itemCount: _episodes.length,
          separatorBuilder: (_, _) => const SizedBox(width: 18),
          itemBuilder: (context, index) {
            final episode = _episodes[index];
            final number = episode.number ?? 0;
            final season = _selectedSeason;
            return _EpisodeCard(
              episode: episode,
              number: number,
              onSelect: season == null || number == 0
                  ? null
                  : () => widget.onPlayEpisode(context, season, number),
            );
          },
        ),
      ),
  ];
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.episode,
    required this.number,
    required this.onSelect,
  });

  final TvEpisode episode;
  final int number;
  final VoidCallback? onSelect;

  static const width = 264.0;
  static const imageHeight = 148.0;
  static const height = imageHeight + 76;

  @override
  Widget build(BuildContext context) {
    final title = episode.name ?? 'Episode $number';
    final overview = episode.overview;
    final still = episode.stillPath;
    final runtime = episode.runtime;
    return SizedBox(
      width: width,
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: width,
            height: imageHeight,
            child: TvFocusable(
              onSelect: onSelect,
              semanticLabel: 'Episode $number, $title',
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: GlassTheme.elevatedSurface,
                    child: still.isEmpty
                        ? Icon(ReelishIcons.movie, color: GlassTheme.muted)
                        : ArtworkImage.network(
                            'https://image.tmdb.org/t/p/w300$still',
                            fit: BoxFit.cover,
                            cacheWidth:
                                (width * MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                            errorBuilder: (_, _, _) => Icon(
                              ReelishIcons.movie,
                              color: GlassTheme.muted,
                            ),
                          ),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 8,
                    child: Icon(
                      ReelishIcons.playCircleFilled,
                      size: 30,
                      color: Colors.white.withValues(alpha: .9),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'E${number.toString().padLeft(2, '0')}  $title',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.titleSmall.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (runtime != null && runtime > 0) '$runtime min',
              if (overview.isNotEmpty) overview,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GlassTheme.muted,
              fontSize: 14,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
