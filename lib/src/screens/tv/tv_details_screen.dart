import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../services/perf_timeline.dart';
import '../../services/tmdb_service.dart';
import '../../theme/glass_theme.dart';
import '../../widgets/tv/tv_focus.dart';

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
  });

  final MediaItem item;
  final TmdbService tmdb;
  final ValueChanged<BuildContext> onPlay;
  final void Function(BuildContext context, int season, int episode)
  onPlayEpisode;
  final bool isFavorite;

  /// Adds the title to My list or removes it; completes with whether it is
  /// on the list afterwards.
  final Future<bool> Function()? onToggleFavorite;

  @override
  State<TvMediaDetailsScreen> createState() => _TvMediaDetailsScreenState();
}

class _TvMediaDetailsScreenState extends State<TvMediaDetailsScreen> {
  MediaDetails? _details;
  bool _loading = true;
  String? _error;
  late bool _favorite = widget.isFavorite;

  List<Map<String, dynamic>> _seasons = const [];
  List<Map<String, dynamic>> _episodes = const [];
  int? _selectedSeason;
  bool _loadingEpisodes = false;
  String? _episodeError;
  Timer? _seasonFocus;

  bool get _isSeries => widget.item.type == 'series';

  @override
  void initState() {
    super.initState();
    unawaited(_loadDetails());
    if (_isSeries) unawaited(_loadSeasons());
  }

  @override
  void dispose() {
    _seasonFocus?.cancel();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await widget.tmdb.details(widget.item);
      if (!mounted) return;
      PerfTimeline.end('DETAIL_OPEN', 'DETAIL_READY', finish: true);
      setState(() {
        _details = details;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load extra details.';
      });
    }
  }

  Future<void> _loadSeasons() async {
    setState(() {
      _loadingEpisodes = true;
      _episodeError = null;
    });
    try {
      final seasons = await widget.tmdb.seasons(widget.item);
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
      final episodes = await widget.tmdb.episodes(widget.item, season);
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
        _episodes = const [];
        _loadingEpisodes = false;
        _episodeError = 'Could not load this season.';
      });
    }
  }

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
    final favorite = await toggle();
    if (mounted) setState(() => _favorite = favorite);
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
              width: size.width * .78,
              height: size.height * .9,
              // The fade starts at the image's own left edge, so no seam
              // shows where the image begins.
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
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
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          GlassTheme.background,
                          Color(0xCC0B0B0F),
                          Color(0x330B0B0F),
                          Color(0x000B0B0F),
                        ],
                        stops: [0, .25, .6, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [GlassTheme.background, Color(0x000B0B0F)],
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
      if (rating.isNotEmpty) '★ $rating',
      if ((details?.runtimeMinutes ?? 0) > 0) '${details!.runtimeMinutes} min',
      if (details?.status.isNotEmpty == true) details!.status,
    ];
    final cast = details?.cast.take(5).map((member) => member.name).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _isSeries ? 'SERIES' : 'MOVIE',
          style: TextStyle(
            color: GlassTheme.coralBright,
            fontSize: 13,
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
        Text(
          meta.join('   ·   '),
          style: const TextStyle(
            color: Color(0xDDFFFFFF),
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (details?.genres.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(
            details!.genres.join(', '),
            style: const TextStyle(color: GlassTheme.muted, fontSize: 14),
          ),
        ],
        if (details?.tagline.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          Text(
            details!.tagline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
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
          style: const TextStyle(
            color: Color(0xD9FFFFFF),
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
            style: const TextStyle(color: GlassTheme.muted, fontSize: 13),
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
              icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
              label: Text(_isSeries ? 'Play' : 'Play movie'),
            ),
            if (widget.onToggleFavorite != null)
              OutlinedButton.icon(
                style: _actionStyle(filled: false),
                onPressed: _toggleFavorite,
                icon: Icon(
                  _favorite ? Symbols.check_rounded : Symbols.add_rounded,
                ),
                label: Text(_favorite ? 'On My list' : 'My list'),
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
                icon: const Icon(Symbols.refresh_rounded),
                label: Text('$_error Retry'),
              ),
          ],
        ),
      ],
    );
  }

  static ButtonStyle _actionStyle({required bool filled}) =>
      (filled ? FilledButton.styleFrom : OutlinedButton.styleFrom)(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 26),
        shape: const StadiumBorder(),
        foregroundColor: filled ? GlassTheme.background : Colors.white,
        backgroundColor: filled ? GlassTheme.primary : null,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      );

  List<Widget> _episodeSection() => [
    const SizedBox(height: 28),
    const Text(
      'Episodes',
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
    ),
    const SizedBox(height: 12),
    if (_seasons.length > 1)
      SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          itemCount: _seasons.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final season = (_seasons[index]['season_number'] as num).toInt();
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
          Text(_episodeError!, style: const TextStyle(color: GlassTheme.muted)),
          const SizedBox(width: 14),
          OutlinedButton.icon(
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
            final number = (episode['episode_number'] as num?)?.toInt() ?? 0;
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

  final Map<String, dynamic> episode;
  final int number;
  final VoidCallback? onSelect;

  static const width = 264.0;
  static const imageHeight = 148.0;
  static const height = imageHeight + 72;

  @override
  Widget build(BuildContext context) {
    final title = '${episode['name'] ?? 'Episode $number'}';
    final overview = '${episode['overview'] ?? ''}';
    final still = '${episode['still_path'] ?? ''}';
    final runtime = (episode['runtime'] as num?)?.toInt();
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
                        ? const Icon(
                            Symbols.movie_rounded,
                            color: GlassTheme.muted,
                          )
                        : Image.network(
                            'https://image.tmdb.org/t/p/w300$still',
                            fit: BoxFit.cover,
                            cacheWidth:
                                (width * MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                            errorBuilder: (_, _, _) => const Icon(
                              Symbols.movie_rounded,
                              color: GlassTheme.muted,
                            ),
                          ),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 8,
                    child: Icon(
                      Symbols.play_circle_rounded,
                      fill: 1,
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
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (runtime != null && runtime > 0) '$runtime min',
              if (overview.isNotEmpty) overview,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: GlassTheme.muted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
