import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/tv_season.dart';
import '../services/tmdb_service.dart';
import '../theme/glass_theme.dart';
import '../viewmodels/details_view_model.dart';
import '../watch_party/party_models.dart';

class MediaDetailsScreen extends StatefulWidget {
  const MediaDetailsScreen({
    super.key,
    required this.item,
    required this.tmdb,
    required this.onPlay,
    required this.onPlayEpisode,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.onWatchTogether,
  });

  final MediaItem item;
  final TmdbService tmdb;
  final ValueChanged<BuildContext> onPlay;
  final void Function(BuildContext context, int season, int episode)
  onPlayEpisode;

  /// Whether the title is on My list when the page opens.
  final bool isFavorite;

  /// Adds or removes the title and returns whether it is now on My list.
  /// Without it the page shows no My list button.
  final Future<bool> Function()? onToggleFavorite;

  /// Starts a watch party for the movie or a chosen episode. Without it
  /// the page offers no Watch together button.
  final void Function(BuildContext context, PartyContent content)?
  onWatchTogether;

  @override
  State<MediaDetailsScreen> createState() => _MediaDetailsScreenState();
}

class _MediaDetailsScreenState extends State<MediaDetailsScreen> {
  late final _model = DetailsViewModel(item: widget.item, tmdb: widget.tmdb);

  // The page renders from the shared DetailsViewModel; these keep its
  // wording and the names the layout below reads.
  MediaDetails? get _details => _model.details;
  bool get _loading => _model.loadingDetails;
  String? get _error =>
      _model.detailsFailed ? 'Could not load extra details. Try again.' : null;
  bool get _loadingEpisodes => _model.loadingEpisodes;
  String? get _episodeError => switch (_model.episodeError) {
    EpisodeLoadError.seasons => 'Could not load episodes. Try again.',
    EpisodeLoadError.season => 'Could not load this season. Try again.',
    null => null,
  };
  List<TvSeason> get _seasons => _model.seasons;
  List<TvEpisode> get _episodes => _model.episodes;
  int? get _selectedSeason => _model.selectedSeason;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
    _model.start();
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _model.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  late bool _favorite = widget.isFavorite;
  bool _savingFavorite = false;

  Future<void> _toggleFavorite() async {
    final toggle = widget.onToggleFavorite;
    if (toggle == null || _savingFavorite) return;
    setState(() => _savingFavorite = true);
    try {
      final favorite = await toggle();
      if (mounted) setState(() => _favorite = favorite);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not update My list. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingFavorite = false);
    }
  }

  Future<void> _loadDetails() => _model.loadDetails();
  Future<void> _loadSeasons() => _model.loadSeasons();
  Future<void> _loadEpisodes(int season) => _model.selectSeason(season);

  String _imageUrl(String path) =>
      path.isEmpty ? '' : 'https://image.tmdb.org/t/p/w342$path';

  /// Asks which episode of the shown season the party watches.
  Future<void> _chooseEpisodeToWatchTogether(MediaItem item) async {
    final season = _selectedSeason;
    final start = widget.onWatchTogether;
    if (season == null || start == null) return;
    final number = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: GlassTheme.surface,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Watch together: which episode?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final episode in _episodes)
              if ((episode.number ?? 0) > 0)
                ListTile(
                  leading: const Icon(Symbols.play_circle_rounded),
                  title: Text(
                    'E${episode.number.toString().padLeft(2, '0')}  '
                    '${episode.name ?? 'Episode ${episode.number}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, episode.number),
                ),
          ],
        ),
      ),
    );
    if (number == null || !mounted) return;
    final content = PartyContent.fromItem(
      item,
      season: season,
      episode: number,
    );
    if (content != null) start(context, content);
  }

  Widget _episodeCard(TvEpisode episode) {
    final number = episode.number ?? 0;
    final season = _selectedSeason;
    final title = episode.name ?? 'Episode $number';
    final overview = episode.overview;
    final rating = episode.rating;
    final image = _imageUrl(episode.stillPath);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white.withValues(alpha: .045),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: season == null || number == 0
              ? null
              : () => widget.onPlayEpisode(context, season, number),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 112,
                    height: 76,
                    child: image.isEmpty
                        ? const ColoredBox(
                            color: GlassTheme.surface,
                            child: Icon(
                              Symbols.movie_rounded,
                              color: GlassTheme.muted,
                            ),
                          )
                        : Image.network(
                            image,
                            fit: BoxFit.cover,
                            cacheWidth: 224,
                            errorBuilder: (_, __, ___) => const ColoredBox(
                              color: GlassTheme.surface,
                              child: Icon(
                                Symbols.movie_rounded,
                                color: GlassTheme.muted,
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'E${number.toString().padLeft(2, '0')}  $title',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      if (rating > 0) ...[
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Icon(
                              Symbols.star_rounded,
                              fill: 1,
                              size: 15,
                              color: GlassTheme.primary,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              rating.toStringAsFixed(1),
                              style: TextStyle(
                                color: GlassTheme.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        overview.isEmpty
                            ? 'No episode synopsis available.'
                            : overview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: GlassTheme.muted,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Icon(
                    Symbols.play_circle_rounded,
                    fill: 1,
                    color: GlassTheme.primary,
                    size: 26,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final item = widget.item;
    final details = _details;
    final rating = details?.rating.isNotEmpty == true
        ? details!.rating
        : item.rating;
    final size = MediaQuery.sizeOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);

    return SizedBox(
      height: 440,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.background.isNotEmpty)
            Image.network(
              item.background,
              fit: BoxFit.cover,
              cacheWidth: (size.width * pixelRatio).round(),
              errorBuilder: (_, __, ___) =>
                  ColoredBox(color: GlassTheme.elevatedSurface),
            )
          else
            ColoredBox(color: GlassTheme.elevatedSurface),
          // Ends in the page colour, fully opaque, so the header blends into
          // the content below without a seam.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x990B0B0F),
                  Color(0x220B0B0F),
                  Color(0xE60B0B0F),
                  GlassTheme.background,
                ],
                stops: [0, .42, .9, 1],
              ),
            ),
          ),
          Positioned(
            left: 22,
            right: 22,
            bottom: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  // Dark glass with the brighter accent, so the label keeps
                  // its contrast on any artwork (a coral tint on coral text
                  // fell under 4.5:1).
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .38),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: GlassTheme.primary.withValues(alpha: .45),
                    ),
                  ),
                  child: Text(
                    item.type == 'series' ? 'SERIES' : 'MOVIE',
                    style: TextStyle(
                      color: GlassTheme.coralBright,
                      fontSize: 10,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  item.name,
                  // The details page is where a long title is read in full.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 34,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 7,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (item.year.isNotEmpty) _metadata(item.year),
                    if (rating.isNotEmpty)
                      _metadata(
                        '$rating / 10',
                        highlight: true,
                        icon: Symbols.star_rounded,
                      ),
                    if (details != null && details.voteCount > 0)
                      _metadata('${_formatCount(details.voteCount)} votes'),
                    if ((details?.runtimeMinutes ?? 0) > 0)
                      _metadata('${details!.runtimeMinutes} min'),
                  ],
                ),
                if (details?.tagline.isNotEmpty == true) ...[
                  const SizedBox(height: 10),
                  Text(
                    details!.tagline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                if (widget.onToggleFavorite != null ||
                    _offersSeriesParty(item)) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (widget.onToggleFavorite != null) _myListButton(),
                      // A series has no play bar, so its watch party starts
                      // here; it asks which episode of the shown season.
                      if (_offersSeriesParty(item)) _watchTogetherButton(item),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Styled as the Spotlight's My list button; it also says when the title
  /// is already saved.
  bool _offersSeriesParty(MediaItem item) =>
      widget.onWatchTogether != null &&
      item.type == 'series' &&
      PartyContent.fromItem(item, season: 1, episode: 1) != null;

  /// Watch together for a series, in the My list button's style; ready once
  /// the season's episodes are listed.
  Widget _watchTogetherButton(MediaItem item) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.black.withValues(alpha: .28),
      shape: const StadiumBorder(),
      side: BorderSide(color: Colors.white.withValues(alpha: .35)),
      padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 13),
    ),
    onPressed: _selectedSeason != null && _episodes.isNotEmpty
        ? () => _chooseEpisodeToWatchTogether(item)
        : null,
    icon: const Icon(Symbols.groups_rounded, size: 19),
    label: const Text(
      'Watch together',
      style: TextStyle(fontWeight: FontWeight.w700),
    ),
  );

  Widget _myListButton() => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      foregroundColor: _favorite ? GlassTheme.primary : Colors.white,
      backgroundColor: Colors.black.withValues(alpha: .28),
      shape: const StadiumBorder(),
      side: BorderSide(
        color: _favorite
            ? GlassTheme.primary.withValues(alpha: .55)
            : Colors.white.withValues(alpha: .35),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 13),
    ),
    // Kept enabled while saving, so a second tap is ignored rather than
    // falling through; the guard is in _toggleFavorite.
    onPressed: _toggleFavorite,
    icon: Icon(
      _favorite ? Symbols.check_rounded : Symbols.add_rounded,
      size: 19,
    ),
    label: Text(
      _favorite ? 'In My list' : 'My list',
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
  );

  Widget _metadata(String text, {bool highlight = false, IconData? icon}) {
    // Highlighted: the brighter accent on dark glass, which keeps its
    // contrast on artwork (a coral tint behind coral text did not).
    final color = highlight ? GlassTheme.coralBright : Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlight
            ? Colors.black.withValues(alpha: .38)
            : Colors.white.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: highlight
              ? GlassTheme.primary.withValues(alpha: .3)
              : Colors.white.withValues(alpha: .16),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // An icon, not a "★" character: Montserrat has no star glyph.
          if (icon != null) ...[
            Icon(icon, fill: 1, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '$count';
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      title,
      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
    ),
  );

  Widget _castMember(CastMember member) => SizedBox(
    width: 88,
    child: Column(
      children: [
        ClipOval(
          child: SizedBox(
            width: 72,
            height: 72,
            child: member.profile.isEmpty
                ? const ColoredBox(
                    color: GlassTheme.surface,
                    child: Icon(Symbols.person_rounded, size: 32),
                  )
                : Image.network(
                    member.profile,
                    fit: BoxFit.cover,
                    cacheWidth: 144,
                    errorBuilder: (_, __, ___) => const ColoredBox(
                      color: GlassTheme.surface,
                      child: Icon(Symbols.person_rounded, size: 32),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          member.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        if (member.character.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            member.character,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: GlassTheme.muted, fontSize: 10),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final synopsis = _details?.overview.isNotEmpty == true
        ? _details!.overview
        : item.description;

    return Scaffold(
      body: Stack(
        children: [
          _content(context, item, synopsis),
          const _StatusBarScrim(),
          // Stays on screen while the page scrolls.
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 14, top: 6),
                child: IconButton.filledTonal(
                  tooltip: 'Back',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: .48),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Symbols.arrow_back_rounded),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _playBar(context, item),
    );
  }

  Widget _content(
    BuildContext context,
    MediaItem item,
    String synopsis,
  ) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(child: _header(context)),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('Synopsis'),
              // About 75 characters a line at most: a tablet's full width
              // made lines too long to follow.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Text(
                  synopsis.isNotEmpty
                      ? synopsis
                      : 'No synopsis is available for this title.',
                  style: const TextStyle(
                    color: Colors.white70,
                    height: 1.55,
                    fontSize: 14,
                  ),
                ),
              ),
              if (_details?.genres.isNotEmpty == true) ...[
                const SizedBox(height: 22),
                _sectionTitle('Genres'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final genre in _details!.genres) _metadata(genre),
                  ],
                ),
              ],
              if (_details?.status.isNotEmpty == true) ...[
                const SizedBox(height: 18),
                Text(
                  'Status: ${_details!.status}',
                  style: const TextStyle(color: GlassTheme.muted, fontSize: 12),
                ),
              ],
              if (_loading) ...[
                const SizedBox(height: 22),
                Center(
                  child: CircularProgressIndicator(color: GlassTheme.primary),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: GlassTheme.muted),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _loadDetails,
                      icon: const Icon(Symbols.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ],
              if (_details?.cast.isNotEmpty == true) ...[
                const SizedBox(height: 24),
                _sectionTitle('Cast'),
                SizedBox(
                  height: 142,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _details!.cast.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) =>
                        _castMember(_details!.cast[index]),
                  ),
                ),
              ],
              if (item.type == 'series') ...[
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: _sectionTitle('Episodes')),
                    if (_seasons.isNotEmpty)
                      DropdownButton<int>(
                        value: _selectedSeason,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final season in _seasons)
                            DropdownMenuItem(
                              value: season.number,
                              child: Text('Season ${season.number}'),
                            ),
                        ],
                        onChanged: (season) {
                          if (season != null && season != _selectedSeason) {
                            _loadEpisodes(season);
                          }
                        },
                      ),
                  ],
                ),
                if (_loadingEpisodes)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: GlassTheme.primary,
                      ),
                    ),
                  )
                else if (_episodeError != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _episodeError!,
                          style: const TextStyle(color: GlassTheme.muted),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _seasons.isEmpty
                            ? _loadSeasons
                            : () => _loadEpisodes(_selectedSeason!),
                        icon: const Icon(Symbols.refresh_rounded),
                        label: const Text('Retry'),
                      ),
                    ],
                  )
                else if (_episodes.isEmpty)
                  const Text(
                    'No episodes are available for this season.',
                    style: TextStyle(color: GlassTheme.muted),
                  ),
              ],
            ],
          ),
        ),
      ),
      if (item.type == 'series' &&
          !_loadingEpisodes &&
          _episodeError == null &&
          _episodes.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _episodeCard(_episodes[index]),
              childCount: _episodes.length,
            ),
          ),
        ),
    ],
  );

  Widget? _playBar(BuildContext context, MediaItem item) =>
      item.type == 'series'
      ? null
      : SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
            child: SizedBox(
              height: 54,
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox.expand(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: GlassTheme.primary,
                          foregroundColor: GlassTheme.background,
                        ),
                        onPressed: () => widget.onPlay(context),
                        icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
                        label: Text(
                          item.type == 'series'
                              ? 'Choose episode and play'
                              : 'Play movie',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
                  if (widget.onWatchTogether != null &&
                      PartyContent.fromItem(item) != null) ...[
                    const SizedBox(width: 10),
                    SizedBox.square(
                      dimension: 54,
                      child: IconButton.outlined(
                        tooltip: 'Watch together',
                        onPressed: () => widget.onWatchTogether!(
                          context,
                          PartyContent.fromItem(item)!,
                        ),
                        icon: const Icon(Symbols.groups_rounded),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
}

/// Shades the status bar once content scrolls beneath it, so the clock and
/// icons never sit on top of text.
class _StatusBarScrim extends StatelessWidget {
  const _StatusBarScrim();

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).top;
    // Down past the back button (6 + 48 below the inset), so headings
    // scrolling under it fade instead of colliding with it.
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: inset + 80,
      child: const IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xE60B0B0F), Color(0x000B0B0F)],
            ),
          ),
        ),
      ),
    );
  }
}
