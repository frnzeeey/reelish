import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_details.dart';
import '../models/media_item.dart';
import '../services/perf_timeline.dart';
import '../services/tmdb_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/poster_image.dart';
import 'desktop_widgets.dart';

/// A movie or series on Windows: a wide backdrop with the poster, details
/// and actions, then cast, seasons and episodes, and related titles. Plays
/// through the same flow as the other details screens ([onPlay] and
/// [onPlayEpisode]), so provider search, source selection and the player are
/// unchanged.
class DesktopDetailsScreen extends StatefulWidget {
  const DesktopDetailsScreen({
    super.key,
    required this.item,
    required this.tmdb,
    required this.onPlay,
    required this.onPlayEpisode,
    required this.isFavorite,
    required this.onToggleFavorite,
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

  @override
  State<DesktopDetailsScreen> createState() => _DesktopDetailsScreenState();
}

class _DesktopDetailsScreenState extends State<DesktopDetailsScreen> {
  MediaDetails? _details;
  bool _loading = true;
  late bool _favorite = widget.isFavorite(widget.item);
  List<Map<String, dynamic>> _seasons = const [];
  List<Map<String, dynamic>> _episodes = const [];
  int? _selectedSeason;
  bool _loadingEpisodes = false;
  String? _episodeError;
  List<MediaItem> _related = const [];

  MediaItem get _item => widget.item;
  bool get _isSeries => _item.type == 'series';

  @override
  void initState() {
    super.initState();
    unawaited(_loadDetails());
    unawaited(_loadRelated());
    if (_isSeries) unawaited(_loadSeasons());
  }

  Future<void> _loadDetails() async {
    try {
      final details = await widget.tmdb.details(_item);
      if (!mounted) return;
      PerfTimeline.end('DETAIL_OPEN', 'DETAIL_READY', finish: true);
      setState(() {
        _details = details;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRelated() async {
    try {
      final related = await widget.tmdb.recommendations(_item);
      if (mounted) setState(() => _related = related);
    } catch (_) {
      // An extra row; the page works without it.
    }
  }

  Future<void> _loadSeasons() async {
    setState(() {
      _loadingEpisodes = true;
      _episodeError = null;
    });
    try {
      final seasons = await widget.tmdb.seasons(_item);
      if (!mounted) return;
      setState(() => _seasons = seasons);
      final first = seasons.isEmpty
          ? null
          : (seasons.first['season_number'] as num).toInt();
      if (first != null) {
        await _loadEpisodes(first);
      } else {
        setState(() => _loadingEpisodes = false);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingEpisodes = false;
        _episodeError = 'Could not load episodes.';
      });
    }
  }

  Future<void> _loadEpisodes(int season) async {
    setState(() {
      _selectedSeason = season;
      _loadingEpisodes = true;
      _episodeError = null;
    });
    try {
      final episodes = await widget.tmdb.episodes(_item, season);
      if (!mounted || _selectedSeason != season) return;
      episodes.sort(
        (a, b) => ((a['episode_number'] as num?) ?? 0).compareTo(
          (b['episode_number'] as num?) ?? 0,
        ),
      );
      setState(() {
        _episodes = episodes;
        _loadingEpisodes = false;
      });
    } catch (_) {
      if (!mounted || _selectedSeason != season) return;
      setState(() {
        _loadingEpisodes = false;
        _episodeError = 'Could not load this season.';
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final now = await widget.onToggleFavorite(_item);
    if (mounted) setState(() => _favorite = now);
  }

  void _play() {
    if (!_isSeries) {
      widget.onPlay(context, _item);
      return;
    }
    final firstAired = _episodes.where(_aired).firstOrNull;
    final season = _selectedSeason;
    if (firstAired == null || season == null) return;
    widget.onPlayEpisode(
      context,
      _item,
      season,
      (firstAired['episode_number'] as num).toInt(),
    );
  }

  static bool _aired(Map<String, dynamic> episode) {
    final date = DateTime.tryParse('${episode['air_date'] ?? ''}');
    return date == null || !date.isAfter(DateTime.now());
  }

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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return Scaffold(
      backgroundColor: GlassTheme.background,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(context, details)),
          if (details != null && details.cast.isNotEmpty)
            SliverToBoxAdapter(child: _cast(details.cast)),
          if (_isSeries) ..._episodeSlivers(),
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
      ),
    );
  }

  Widget _header(BuildContext context, MediaDetails? details) {
    final viewport = MediaQuery.sizeOf(context);
    final height = (viewport.height * .66).clamp(440.0, 760.0);
    final rating = details?.rating.isNotEmpty == true
        ? details!.rating
        : _item.rating;
    final runtime = details?.runtimeMinutes;
    final meta = [
      if (_item.year.isNotEmpty) _item.year,
      if (rating.isNotEmpty) '★ $rating',
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
              alignment: Alignment.topCenter,
              cacheWidth:
                  (viewport.width * MediaQuery.devicePixelRatioOf(context))
                      .round(),
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xF50B0B0F),
                  Color(0xB00B0B0F),
                  Color(0x200B0B0F),
                ],
                stops: [0, .45, 1],
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
                  Color(0x660B0B0F),
                  Color(0x000B0B0F),
                  GlassTheme.background,
                  GlassTheme.background,
                ],
                stops: [0, .45, .95, 1],
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
              ),
              icon: const Icon(Symbols.arrow_back_rounded),
            ),
          ),
          Positioned(
            left: DesktopMetrics.pagePadding,
            right: DesktopMetrics.pagePadding,
            bottom: 28,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (viewport.width >= 1100) ...[
                  _Poster(item: _item),
                  const SizedBox(width: 36),
                ],
                Expanded(
                  // Align loosens Expanded's tight width, so the text keeps
                  // a readable line length on wide windows.
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 780),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isSeries ? 'SERIES' : 'MOVIE',
                            style: TextStyle(
                              color: GlassTheme.coralBright,
                              fontSize: 12,
                              letterSpacing: 1.8,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 48,
                              height: 1.05,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.2,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            meta.join('  ·  '),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white70,
                            ),
                          ),
                          if (details?.genres.isNotEmpty == true) ...[
                            const SizedBox(height: 12),
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
                                height: 1.55,
                                color: Colors.white,
                              ),
                            ),
                          const SizedBox(height: 22),
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
                                    alpha: .08,
                                  ),
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: .3),
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

  List<Widget> _episodeSlivers() => [
    SliverToBoxAdapter(
      child: DesktopSectionTitle(
        'Episodes',
        trailing: _seasons.length > 1
            ? Wrap(
                spacing: 8,
                children: [
                  for (final season in _seasons)
                    _SeasonChip(
                      label:
                          '${season['name'] ?? 'Season ${season['season_number']}'}',
                      selected:
                          (season['season_number'] as num).toInt() ==
                          _selectedSeason,
                      onTap: () => unawaited(
                        _loadEpisodes((season['season_number'] as num).toInt()),
                      ),
                    ),
                ],
              )
            : null,
      ),
    ),
    if (_loadingEpisodes)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      )
    else if (_episodeError != null)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DesktopMetrics.pagePadding,
            vertical: 16,
          ),
          child: Row(
            children: [
              Text(
                _episodeError!,
                style: const TextStyle(color: GlassTheme.muted),
              ),
              const SizedBox(width: 12),
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
        ),
      )
    else if (_episodes.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: DesktopMetrics.pagePadding,
            vertical: 16,
          ),
          child: Text(
            'No episodes are listed for this season yet.',
            style: TextStyle(color: GlassTheme.muted),
          ),
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
              delegate: SliverChildBuilderDelegate((context, index) {
                final episode = _episodes[index];
                final number =
                    (episode['episode_number'] as num?)?.toInt() ?? index + 1;
                final season = _selectedSeason ?? 1;
                return _EpisodeTile(
                  episode: episode,
                  number: number,
                  aired: _aired(episode),
                  onPlay: () =>
                      widget.onPlayEpisode(context, _item, season, number),
                );
              }, childCount: _episodes.length),
            ),
          );
        },
      ),
  ];
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
  });

  final Map<String, dynamic> episode;
  final int number;
  final bool aired;
  final VoidCallback onPlay;

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final title = '${episode['name'] ?? 'Episode ${widget.number}'}';
    final overview = '${episode['overview'] ?? ''}';
    final still = '${episode['still_path'] ?? ''}';
    final runtime = (episode['runtime'] as num?)?.toInt();
    final airDate = '${episode['air_date'] ?? ''}';
    final enabled = widget.aired;
    final lifted = enabled && (_hovered || _focused);
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
          label: 'Episode ${widget.number}, $title',
          child: AnimatedContainer(
            duration: desktopMotion(context, 160),
            decoration: BoxDecoration(
              color: lifted
                  ? Colors.white.withValues(alpha: .08)
                  : GlassTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focused
                    ? GlassTheme.coralBright
                    : lifted
                    ? Colors.white.withValues(alpha: .25)
                    : Colors.white.withValues(alpha: .06),
                width: _focused ? 2.5 : 1,
              ),
            ),
            padding: const EdgeInsets.all(10),
            child: Opacity(
              opacity: enabled ? 1 : .5,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 168,
                      height: 106,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const PosterPlaceholder(iconSize: 26),
                          if (still.isNotEmpty)
                            Image.network(
                              'https://image.tmdb.org/t/p/w300$still',
                              fit: BoxFit.cover,
                              cacheWidth:
                                  (168 * MediaQuery.devicePixelRatioOf(context))
                                      .round(),
                              frameBuilder: posterFadeIn(context),
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink(),
                            ),
                          if (lifted)
                            Center(
                              child: Icon(
                                Symbols.play_circle_rounded,
                                fill: 1,
                                size: 40,
                                color: Colors.white.withValues(alpha: .92),
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
                        Text(
                          '${widget.number}. $title',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          enabled
                              ? [
                                  if (runtime != null && runtime > 0)
                                    '$runtime min',
                                  if (airDate.isNotEmpty) airDate,
                                ].join(' · ')
                              : 'Airs $airDate',
                          style: const TextStyle(
                            fontSize: 12,
                            color: GlassTheme.muted,
                          ),
                        ),
                        if (overview.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            overview,
                            maxLines: 2,
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
