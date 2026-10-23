import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/episode_progress.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/tv_season.dart';
import '../services/tmdb_service.dart';
import '../theme/glass_theme.dart';
import '../viewmodels/details_view_model.dart';
import '../widgets/poster_image.dart';
import 'desktop_widgets.dart';

/// A movie or series on Windows, full-bleed over the whole window: the
/// backdrop with the title, details and actions, then cast and related
/// titles. On a wide window a series lists its seasons and episodes in a
/// frosted panel over the backdrop's right side; on a narrower one they
/// follow the header as a grid. Plays through the same flow as the other
/// details screens ([onPlay] and [onPlayEpisode]), so provider search,
/// source selection and the player are unchanged.
class DesktopDetailsScreen extends StatefulWidget {
  const DesktopDetailsScreen({
    super.key,
    required this.item,
    required this.tmdb,
    required this.onPlay,
    required this.onPlayEpisode,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.seriesProgress,
  });

  final MediaItem item;
  final TmdbService tmdb;
  final void Function(BuildContext context, MediaItem item) onPlay;
  final void Function(
    BuildContext context,
    MediaItem item,
    int season,
    int episode,
  )
  onPlayEpisode;
  final bool Function(MediaItem item) isFavorite;

  /// Completes with whether the title is on My list afterwards.
  final Future<bool> Function(MediaItem item) onToggleFavorite;

  /// Where the viewer is in a series, read from the watch history, so
  /// episodes show as watched or in progress. Read only; without it the
  /// episodes show no progress.
  final Future<SeriesProgress> Function(MediaItem item)? seriesProgress;

  /// From this content width a series shows its episodes in the panel.
  static const panelBreakpoint = 1180.0;

  @override
  State<DesktopDetailsScreen> createState() => _DesktopDetailsScreenState();
}

class _DesktopDetailsScreenState extends State<DesktopDetailsScreen> {
  late final _model = DetailsViewModel(
    item: widget.item,
    tmdb: widget.tmdb,
    loadsRelated: true,
    keepsEpisodesOnError: true,
  );
  late bool _favorite = widget.isFavorite(widget.item);
  SeriesProgress _progress = SeriesProgress.empty;
  Animation<double>? _covered;

  // The page renders from the shared DetailsViewModel; these keep its
  // wording and the names the layout below reads.
  MediaDetails? get _details => _model.details;
  bool get _loading => _model.loadingDetails;
  List<TvSeason> get _seasons => _model.seasons;
  List<TvEpisode> get _episodes => _model.episodes;
  int? get _selectedSeason => _model.selectedSeason;
  bool get _loadingEpisodes => _model.loadingEpisodes;
  String? get _episodeError => switch (_model.episodeError) {
    EpisodeLoadError.seasons => 'Could not load episodes.',
    EpisodeLoadError.season => 'Could not load this season.',
    null => null,
  };
  List<MediaItem> get _related => _model.related;

  MediaItem get _item => widget.item;
  bool get _isSeries => _model.isSeries;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
    _model.start();
    unawaited(_loadProgress());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The player (or a related title) covers this page; once it is gone,
    // the episodes show what was just watched.
    final covered = ModalRoute.of(context)?.secondaryAnimation;
    if (covered != _covered) {
      _covered?.removeStatusListener(_onCoveredChanged);
      _covered = covered?..addStatusListener(_onCoveredChanged);
    }
  }

  @override
  void dispose() {
    _covered?.removeStatusListener(_onCoveredChanged);
    _model.removeListener(_onModelChanged);
    _model.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  void _onCoveredChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) unawaited(_loadProgress());
  }

  Future<void> _loadProgress() async {
    final read = widget.seriesProgress;
    if (read == null || widget.item.type != 'series') return;
    try {
      final progress = await read(widget.item);
      if (mounted) setState(() => _progress = progress);
    } catch (_) {
      // Progress is a hint; the episodes work without it.
    }
  }

  Future<void> _loadSeasons() => _model.loadSeasons();
  Future<void> _loadEpisodes(int season) => _model.selectSeason(season);

  Future<void> _toggleFavorite() async {
    final now = await widget.onToggleFavorite(_item);
    if (mounted) setState(() => _favorite = now);
  }

  void _play() {
    if (!_isSeries) {
      widget.onPlay(context, _item);
      return;
    }
    final number = _episodes.where(_aired).firstOrNull?.number;
    final season = _selectedSeason;
    if (number == null || season == null) return;
    widget.onPlayEpisode(context, _item, season, number);
  }

  static bool _aired(TvEpisode episode) => episode.airedBy(DateTime.now());

  void _openRelated(MediaItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopDetailsScreen(
          item: item,
          tmdb: widget.tmdb,
          onPlay: widget.onPlay,
          onPlayEpisode: widget.onPlayEpisode,
          isFavorite: widget.isFavorite,
          onToggleFavorite: widget.onToggleFavorite,
          seriesProgress: widget.seriesProgress,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final panel =
              _isSeries &&
              constraints.maxWidth >= DesktopDetailsScreen.panelBreakpoint;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _header(context, details, constraints.maxWidth, panel),
              ),
              if (details != null && details.cast.isNotEmpty)
                SliverToBoxAdapter(child: _cast(details.cast)),
              if (_isSeries && !panel) ..._episodeSlivers(),
              if (_related.isNotEmpty)
                SliverToBoxAdapter(
                  child: DesktopMediaRow(
                    title: 'More like this',
                    items: _related,
                    onOpen: _openRelated,
                    isFavorite: widget.isFavorite,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          );
        },
      ),
    );
  }

  Widget _header(
    BuildContext context,
    MediaDetails? details,
    double width,
    bool panel,
  ) {
    final viewport = MediaQuery.sizeOf(context);
    // With the episode panel the header takes most of the window, so the
    // panel lists several episodes without scrolling.
    final height = panel
        ? (viewport.height * .86).clamp(560.0, 980.0)
        : (viewport.height * .68).clamp(460.0, 780.0);
    final panelWidth = (width * .3).clamp(380.0, 470.0);
    final rating = details?.rating.isNotEmpty == true
        ? details!.rating
        : _item.rating;
    final runtime = details?.runtimeMinutes;
    final meta = [
      if (_item.year.isNotEmpty) _item.year,
      if (runtime != null && runtime > 0)
        runtime >= 60
            ? '${runtime ~/ 60} h ${runtime % 60} min'
            : '$runtime min',
      if (details?.status.isNotEmpty == true) details!.status,
    ];
    final overview = details?.overview.isNotEmpty == true
        ? details!.overview
        : _item.description;
    final backdrop = _item.background.isNotEmpty
        ? _item.background
        : _item.poster;
    const pad = DesktopMetrics.pagePadding;
    final showPoster = width >= 1100 && (!panel || width >= 1560);
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: GlassTheme.surface),
          if (backdrop.isNotEmpty)
            Image.network(
              backdrop,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -.4),
              cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              frameBuilder: posterFadeIn(context),
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xF50B0B0F),
                  Color(0xB00B0B0F),
                  Color(0x330B0B0F),
                ],
                stops: [0, .45, 1],
              ),
            ),
          ),
          if (panel)
            // Shade under the panel, so it reads against bright artwork.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerRight,
                  end: Alignment.centerLeft,
                  colors: [Color(0x990B0B0F), Color(0x000B0B0F)],
                  stops: [0, .45],
                ),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // Solid before the edge, so the image's last pixel row
                // never shows as a line.
                colors: [
                  Color(0x800B0B0F),
                  Color(0x000B0B0F),
                  Color(0x000B0B0F),
                  GlassTheme.background,
                  GlassTheme.background,
                ],
                stops: [0, .22, .55, .95, 1],
              ),
            ),
          ),
          Positioned(
            top: 20,
            left: 24,
            child: IconButton.filledTonal(
              tooltip: 'Back (Esc)',
              onPressed: () => Navigator.of(context).maybePop(),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: .45),
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: .14)),
              ),
              icon: const Icon(Symbols.arrow_back_rounded),
            ),
          ),
          if (panel)
            Positioned(
              top: 24,
              right: pad,
              bottom: 28,
              width: panelWidth,
              child: _EpisodePanel(child: _episodeBrowser()),
            ),
          Positioned(
            left: pad,
            right: panel ? pad + panelWidth + 40 : pad,
            bottom: 36,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (showPoster) ...[
                  _Poster(item: _item),
                  const SizedBox(width: 36),
                ],
                Expanded(
                  // Align loosens Expanded's tight width, so the text keeps
                  // a readable line length on wide windows.
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 18,
                                height: 2,
                                margin: const EdgeInsets.only(right: 10),
                                color: GlassTheme.primary,
                              ),
                              Text(
                                _isSeries ? 'SERIES' : 'MOVIE',
                                style: TextStyle(
                                  color: GlassTheme.coralBright,
                                  fontSize: 12,
                                  letterSpacing: 2,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 52,
                              height: 1.02,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.4,
                              shadows: [
                                Shadow(
                                  color: Color(0x66000000),
                                  blurRadius: 24,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              if (rating.isNotEmpty && rating != '0.0') ...[
                                Icon(
                                  Symbols.star_rounded,
                                  fill: 1,
                                  size: 17,
                                  color: GlassTheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  rating,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(width: 14),
                              ],
                              Flexible(
                                child: Text(
                                  meta.join('  ·  '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (details?.genres.isNotEmpty == true) ...[
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final genre in details!.genres)
                                  _Chip(label: genre),
                              ],
                            ),
                          ],
                          if (details?.tagline.isNotEmpty == true) ...[
                            const SizedBox(height: 14),
                            Text(
                              details!.tagline,
                              style: const TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Colors.white70,
                                fontSize: 15,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          if (_loading && overview.isEmpty)
                            const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(
                              overview.isNotEmpty
                                  ? overview
                                  : 'No synopsis is available for this title.',
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.6,
                                color: Color(0xE6FFFFFF),
                              ),
                            ),
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            children: [
                              FilledButton.icon(
                                autofocus: true,
                                onPressed:
                                    _isSeries &&
                                        (_episodes.isEmpty ||
                                            !_episodes.any(_aired))
                                    ? null
                                    : _play,
                                style: FilledButton.styleFrom(
                                  backgroundColor: GlassTheme.primary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 28,
                                    vertical: 18,
                                  ),
                                ),
                                icon: const Icon(
                                  Symbols.play_arrow_rounded,
                                  fill: 1,
                                ),
                                label: Text(
                                  _isSeries && _selectedSeason != null
                                      ? 'Play season $_selectedSeason'
                                      : 'Play',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: _toggleFavorite,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: Colors.white.withValues(
                                    alpha: .1,
                                  ),
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: .28),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 22,
                                    vertical: 18,
                                  ),
                                ),
                                icon: Icon(
                                  _favorite
                                      ? Symbols.check_rounded
                                      : Symbols.add_rounded,
                                ),
                                label: Text(
                                  _favorite ? 'On My list' : 'My list',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cast(List<CastMember> cast) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const DesktopSectionTitle('Cast'),
      SizedBox(
        height: 150,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: DesktopMetrics.pagePadding,
          ),
          itemCount: cast.length,
          separatorBuilder: (_, _) => const SizedBox(width: 18),
          itemBuilder: (context, index) {
            final member = cast[index];
            return SizedBox(
              width: 96,
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: GlassTheme.elevatedSurface,
                    foregroundImage: member.profile.isEmpty
                        ? null
                        : ResizeImage(
                            NetworkImage(member.profile),
                            width: (80 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
                          ),
                    child: const Icon(
                      Symbols.person_rounded,
                      color: GlassTheme.muted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    member.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    member.character,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: GlassTheme.muted,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget? _seasonPicker() => _seasons.length > 1
      ? _SeasonPicker(
          seasons: _seasons,
          selected: _selectedSeason,
          onSelected: (season) => unawaited(_loadEpisodes(season)),
        )
      : null;

  /// What replaces the episodes while they load, fail or are missing; null
  /// once there are episodes to show.
  Widget? _episodeNotice() {
    if (_loadingEpisodes) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_episodeError case final error?) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Text(error, style: const TextStyle(color: GlassTheme.muted)),
            TextButton.icon(
              onPressed: () {
                final season = _selectedSeason;
                unawaited(
                  season == null ? _loadSeasons() : _loadEpisodes(season),
                );
              },
              icon: const Icon(Symbols.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_episodes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No episodes are listed for this season yet.',
          style: TextStyle(color: GlassTheme.muted),
        ),
      );
    }
    return null;
  }

  Widget _episodeTile(int index, {required bool compact}) {
    final episode = _episodes[index];
    final number = episode.number ?? index + 1;
    final season = _selectedSeason ?? 1;
    final last = _progress.last;
    return _EpisodeTile(
      episode: episode,
      number: number,
      aired: _aired(episode),
      compact: compact,
      progress: _progress.of(season, number),
      lastWatched:
          last != null && last.season == season && last.episode == number,
      onPlay: () => widget.onPlayEpisode(context, _item, season, number),
    );
  }

  /// The panel's contents: a heading with the season picker, then the
  /// episodes, which scroll inside the panel.
  Widget _episodeBrowser() {
    final notice = _episodeNotice();
    final picker = _seasonPicker();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: Row(
            children: [
              const Text(
                'Episodes',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (_episodes.isNotEmpty && !_loadingEpisodes)
                Text(
                  '${_episodes.length} episode${_episodes.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: GlassTheme.muted),
                ),
            ],
          ),
        ),
        if (picker != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: picker,
          ),
        Divider(height: 17, color: Colors.white.withValues(alpha: .08)),
        Expanded(
          child: notice != null
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(alignment: Alignment.topLeft, child: notice),
                )
              : _EpisodeList(
                  count: _episodes.length,
                  // The last-watched episode, so the list opens there.
                  focusIndex: _lastWatchedIndex(),
                  itemBuilder: (index) => _episodeTile(index, compact: true),
                ),
        ),
      ],
    );
  }

  int? _lastWatchedIndex() {
    final last = _progress.last;
    if (last == null || last.season != _selectedSeason) return null;
    for (var i = 0; i < _episodes.length; i++) {
      if ((_episodes[i].number ?? i + 1) == last.episode) return i;
    }
    return null;
  }

  List<Widget> _episodeSlivers() {
    final notice = _episodeNotice();
    return [
      const SliverToBoxAdapter(child: DesktopSectionTitle('Episodes')),
      if (_seasonPicker() case final picker?)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: picker,
          ),
        ),
      if (notice != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DesktopMetrics.pagePadding,
            ),
            child: notice,
          ),
        )
      else
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final available =
                constraints.crossAxisExtent - DesktopMetrics.pagePadding * 2;
            final columns = (available / 420).floor().clamp(1, 4);
            return SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: DesktopMetrics.pagePadding,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 18,
                  mainAxisSpacing: 18,
                  mainAxisExtent: 128,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _episodeTile(index, compact: false),
                  childCount: _episodes.length,
                ),
              ),
            );
          },
        ),
    ];
  }
}

/// The frosted panel the episodes sit in over the backdrop. One blur, of a
/// fixed size, so it stays cheap.
class _EpisodePanel extends StatelessWidget {
  const _EpisodePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(DesktopSurfaces.radius + 4);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 40,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: DesktopSurfaces.glass,
              borderRadius: radius,
              border: Border.all(color: DesktopSurfaces.hairline),
            ),
            child: FocusTraversalGroup(child: child),
          ),
        ),
      ),
    );
  }
}

/// The panel's episodes, scrolled once to [focusIndex] when it is set.
class _EpisodeList extends StatefulWidget {
  const _EpisodeList({
    required this.count,
    required this.itemBuilder,
    this.focusIndex,
  });

  final int count;
  final Widget Function(int index) itemBuilder;
  final int? focusIndex;

  @override
  State<_EpisodeList> createState() => _EpisodeListState();
}

class _EpisodeListState extends State<_EpisodeList> {
  /// A row's usual height, for the first scroll; rows size to their text.
  static const _rowExtent = 100.0;
  final _scroll = ScrollController();
  bool _scrolledToFocus = false;

  @override
  void didUpdateWidget(covariant _EpisodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.count != widget.count) _scrolledToFocus = false;
    _jumpToFocus();
  }

  @override
  void initState() {
    super.initState();
    _jumpToFocus();
  }

  void _jumpToFocus() {
    final index = widget.focusIndex;
    if (_scrolledToFocus || index == null || index == 0) return;
    _scrolledToFocus = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      _scroll.jumpTo(
        (index * _rowExtent - _rowExtent).clamp(0, position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: _scroll,
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    itemCount: widget.count,
    itemBuilder: (context, index) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: widget.itemBuilder(index),
    ),
  );
}

class _SeasonPicker extends StatelessWidget {
  const _SeasonPicker({
    required this.seasons,
    required this.selected,
    required this.onSelected,
  });

  final List<TvSeason> seasons;
  final int? selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(
      children: [
        for (final season in seasons) ...[
          if (season != seasons.first) const SizedBox(width: 8),
          _SeasonChip(
            label: season.name ?? 'Season ${season.number}',
            selected: season.number == selected,
            onTap: () => onSelected(season.number),
          ),
        ],
      ],
    ),
  );
}

class _Poster extends StatelessWidget {
  const _Poster({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) => Container(
    width: 220,
    height: 330,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .6),
          blurRadius: 30,
          offset: const Offset(0, 14),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const PosterPlaceholder(),
          if (item.poster.isNotEmpty)
            Image.network(
              item.poster,
              fit: BoxFit.cover,
              cacheWidth: (220 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              frameBuilder: posterFadeIn(context),
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
        ],
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: .14)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _SeasonChip extends StatelessWidget {
  const _SeasonChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onTap(),
    showCheckmark: false,
    selectedColor: GlassTheme.primary.withValues(alpha: .22),
    backgroundColor: Colors.white.withValues(alpha: .04),
    labelStyle: TextStyle(
      fontWeight: FontWeight.w700,
      color: selected ? GlassTheme.coralBright : Colors.white70,
    ),
    side: BorderSide(
      color: selected
          ? GlassTheme.primary.withValues(alpha: .5)
          : Colors.white.withValues(alpha: .14),
    ),
  );
}

class _EpisodeTile extends StatefulWidget {
  const _EpisodeTile({
    required this.episode,
    required this.number,
    required this.aired,
    required this.onPlay,
    this.compact = false,
    this.progress,
    this.lastWatched = false,
  });

  final TvEpisode episode;
  final int number;
  final bool aired;
  final VoidCallback onPlay;

  /// The panel's row: a smaller still, one line of overview.
  final bool compact;
  final EpisodeProgress? progress;

  /// The episode watched most recently in this series.
  final bool lastWatched;

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final title = episode.name ?? 'Episode ${widget.number}';
    final overview = episode.overview;
    final still = episode.stillPath;
    final runtime = episode.runtime;
    final airDate = episode.airDate;
    final enabled = widget.aired;
    final lifted = enabled && (_hovered || _focused);
    final compact = widget.compact;
    final progress = widget.progress;
    final watched = progress?.isWatched ?? false;
    final inProgress = progress?.isInProgress ?? false;
    final stillWidth = compact ? 136.0 : 168.0;
    final stillHeight = compact ? 76.0 : 106.0;
    final status = !enabled
        ? 'Airs $airDate'
        : [
            if (inProgress && progress!.timeLeft.isNotEmpty)
              progress.timeLeft
            else if (runtime != null && runtime > 0)
              '$runtime min',
            if (airDate.isNotEmpty) airDate,
          ].join(' · ');
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPlay();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: enabled ? widget.onPlay : null,
        child: Semantics(
          button: enabled,
          enabled: enabled,
          label: [
            'Episode ${widget.number}, $title',
            if (watched) 'watched',
            if (inProgress) 'in progress',
          ].join(', '),
          child: AnimatedContainer(
            duration: desktopMotion(context, 160),
            decoration: BoxDecoration(
              color: lifted
                  ? Colors.white.withValues(alpha: .08)
                  : widget.lastWatched
                  ? GlassTheme.primary.withValues(alpha: .08)
                  : compact
                  ? Colors.transparent
                  : GlassTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focused
                    ? GlassTheme.coralBright
                    : widget.lastWatched
                    ? GlassTheme.primary.withValues(alpha: .45)
                    : lifted
                    ? Colors.white.withValues(alpha: .25)
                    : Colors.white.withValues(alpha: compact ? 0 : .06),
                width: _focused ? 2.5 : 1,
              ),
            ),
            padding: EdgeInsets.all(compact ? 8 : 10),
            child: Opacity(
              opacity: enabled ? 1 : .5,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: stillWidth,
                      height: stillHeight,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const PosterPlaceholder(iconSize: 26),
                          if (still.isNotEmpty)
                            Image.network(
                              'https://image.tmdb.org/t/p/w300$still',
                              fit: BoxFit.cover,
                              cacheWidth: posterDecodeWidth(
                                stillWidth *
                                    MediaQuery.devicePixelRatioOf(context),
                              ),
                              frameBuilder: posterFadeIn(context),
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                          if (watched && !lifted)
                            const ColoredBox(color: Color(0x66000000)),
                          if (lifted)
                            Center(
                              child: Icon(
                                Symbols.play_circle_rounded,
                                fill: 1,
                                size: compact ? 34 : 40,
                                color: Colors.white.withValues(alpha: .92),
                              ),
                            )
                          else if (watched)
                            Center(
                              child: Icon(
                                Symbols.check_circle_rounded,
                                fill: 1,
                                size: 26,
                                color: Colors.white.withValues(alpha: .9),
                              ),
                            ),
                          if (inProgress)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: progress!.fraction,
                                minHeight: 3,
                                color: GlassTheme.primary,
                                backgroundColor: Colors.black54,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.lastWatched)
                          Text(
                            'LAST WATCHED',
                            style: TextStyle(
                              color: GlassTheme.coralBright,
                              fontSize: 9.5,
                              letterSpacing: 1.3,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        Text(
                          '${widget.number}. $title',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: compact ? 13.5 : 14,
                            color: watched && !lifted
                                ? Colors.white70
                                : Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: inProgress
                                ? GlassTheme.coralBright
                                : GlassTheme.muted,
                          ),
                        ),
                        if (overview.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            overview,
                            maxLines: compact ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.35,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
