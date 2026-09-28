import 'package:flutter/material.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import '../theme/glass_theme.dart';

class MediaDetailsScreen extends StatefulWidget {
  const MediaDetailsScreen({
    super.key,
    required this.item,
    required this.tmdb,
    required this.onPlay,
    required this.onPlayEpisode,
  });

  final MediaItem item;
  final TmdbService tmdb;
  final ValueChanged<BuildContext> onPlay;
  final void Function(BuildContext context, int season, int episode)
  onPlayEpisode;

  @override
  State<MediaDetailsScreen> createState() => _MediaDetailsScreenState();
}

class _MediaDetailsScreenState extends State<MediaDetailsScreen> {
  MediaDetails? _details;
  bool _loading = true;
  String? _error;
  bool _loadingEpisodes = false;
  String? _episodeError;
  List<Map<String, dynamic>> _seasons = [];
  List<Map<String, dynamic>> _episodes = [];
  int? _selectedSeason;

  @override
  void initState() {
    super.initState();
    _loadDetails();
    if (widget.item.type == 'series') _loadSeasons();
  }

  Future<void> _loadSeasons() async {
    setState(() {
      _loadingEpisodes = true;
      _episodeError = null;
    });
    try {
      final seasons = await widget.tmdb.seasons(widget.item);
      if (!mounted) return;
      final firstSeason = seasons.isEmpty
          ? null
          : (seasons.first['season_number'] as num).toInt();
      setState(() {
        _seasons = seasons;
        _selectedSeason = firstSeason;
      });
      if (firstSeason != null)
        await _loadEpisodes(firstSeason);
      else if (mounted)
        setState(() => _loadingEpisodes = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingEpisodes = false;
        _episodeError = 'Could not load episodes. Try again.';
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
        _episodes = [];
        _loadingEpisodes = false;
        _episodeError = 'Could not load this season. Try again.';
      });
    }
  }

  String _imageUrl(String path) =>
      path.isEmpty ? '' : 'https://image.tmdb.org/t/p/w342$path';

  Widget _episodeCard(Map<String, dynamic> episode) {
    final number = (episode['episode_number'] as num?)?.toInt() ?? 0;
    final season = _selectedSeason;
    final title = '${episode['name'] ?? 'Episode $number'}';
    final overview = '${episode['overview'] ?? ''}';
    final rating = (episode['vote_average'] as num?) ?? 0;
    final image = _imageUrl('${episode['still_path'] ?? ''}');
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
                              Icons.movie_outlined,
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
                                Icons.movie_outlined,
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
                            const Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: GlassTheme.cyan,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              rating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: GlassTheme.cyan,
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
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: GlassTheme.cyan,
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

  Future<void> _loadDetails() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await widget.tmdb.details(widget.item);
      if (!mounted) return;
      setState(() {
        _details = details;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load extra details. Try again.';
      });
    }
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
                  const ColoredBox(color: Color(0xFF202839)),
            )
          else
            const ColoredBox(color: Color(0xFF202839)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x99080B12),
                  Color(0x22080B12),
                  Color(0xF7080B12),
                ],
                stops: [0, .42, 1],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14, top: 6),
                  child: IconButton.filledTonal(
                    tooltip: 'Back',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: .48),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
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
                  decoration: BoxDecoration(
                    color: GlassTheme.cyan.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: GlassTheme.cyan.withValues(alpha: .35),
                    ),
                  ),
                  child: Text(
                    item.type == 'series' ? 'SERIES' : 'MOVIE',
                    style: const TextStyle(
                      color: GlassTheme.cyan,
                      fontSize: 10,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  item.name,
                  maxLines: 2,
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
                      _metadata('★ $rating / 10', highlight: true),
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metadata(String text, {bool highlight = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: highlight
          ? GlassTheme.cyan.withValues(alpha: .15)
          : Colors.white.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: highlight
            ? GlassTheme.cyan.withValues(alpha: .3)
            : Colors.white.withValues(alpha: .16),
      ),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: highlight ? GlassTheme.cyan : Colors.white70,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

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
                    child: Icon(Icons.person_outline_rounded, size: 32),
                  )
                : Image.network(
                    member.profile,
                    fit: BoxFit.cover,
                    cacheWidth: 144,
                    errorBuilder: (_, __, ___) => const ColoredBox(
                      color: GlassTheme.surface,
                      child: Icon(Icons.person_outline_rounded, size: 32),
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
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header(context)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('Synopsis'),
                  Text(
                    synopsis.isNotEmpty
                        ? synopsis
                        : 'No synopsis is available for this title.',
                    style: const TextStyle(
                      color: Colors.white70,
                      height: 1.55,
                      fontSize: 14,
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
                      style: const TextStyle(
                        color: GlassTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (_loading) ...[
                    const SizedBox(height: 22),
                    const Center(
                      child: CircularProgressIndicator(color: GlassTheme.cyan),
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
                          icon: const Icon(Icons.refresh_rounded),
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
                                  value: (season['season_number'] as num)
                                      .toInt(),
                                  child: Text(
                                    'Season ${(season['season_number'] as num).toInt()}',
                                  ),
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
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: GlassTheme.cyan,
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
                            icon: const Icon(Icons.refresh_rounded),
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
                      for (final episode in _episodes) _episodeCard(episode),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: item.type == 'series'
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
                child: SizedBox(
                  height: 54,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: GlassTheme.cyan,
                      foregroundColor: const Color(0xFF081018),
                    ),
                    onPressed: () => widget.onPlay(context),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      item.type == 'series'
                          ? 'Choose episode and play'
                          : 'Play movie',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
