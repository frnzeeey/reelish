import 'dart:async';
import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../services/storage_service.dart';
import '../services/tmdb_service.dart';
import '../services/nuvio_plugin_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/nuvio_plugin_installer_modal.dart';
import '../widgets/category_chip.dart';
import '../widgets/glass_box.dart';
import '../widgets/media_card.dart';
import '../widgets/soft_glass_dock.dart';
import '../widgets/player/stream_selector_sheet.dart';
import '../widgets/player/episode_selector_sheet.dart';
import 'plugins_screen.dart';
import 'library_screen.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _nuvioPlugins = NuvioPluginService();
  final _storage = StorageService();
  final _tmdb = TmdbService();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _spotlightController = PageController();
  List<MediaItem> _items = [], _history = [];
  List<MediaItem> _recommendations = [];
  bool _loading = true, _resolvingStreams = false;
  bool _searchVisible = false;
  String _category = 'For you';
  int _tab = 0;
  int _recommendationRequest = 0;
  int _spotlightPage = 0;
  Key _libraryKey = const ValueKey('library');
  Timer? _debounce;
  Timer? _spotlightTimer;

  @override
  void initState() {
    super.initState();
    _nuvioPlugins.addListener(_onPluginChange);
    _spotlightTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted ||
          _tab != 0 ||
          _category != 'For you' ||
          _search.text.trim().isNotEmpty ||
          _spotlightItems.length < 2 ||
          !_spotlightController.hasClients) {
        return;
      }
      _spotlightController.animateToPage(
        _spotlightPage + 1,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOutCubic,
      );
    });
    _start();
  }

  Future<void> _start() async {
    unawaited(_load());
    await _nuvioPlugins.load();
    await _loadHistory();
  }

  void _onPluginChange() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _load({String? query}) async {
    if (mounted) setState(() => _loading = true);
    Future<List<MediaItem>> safe(Future<List<MediaItem>> future) async {
      try {
        return await future;
      } catch (_) {
        return [];
      }
    }

    final results = await Future.wait([
      if (query != null)
        safe(_tmdb.search(query))
      else if (_category == 'Trending')
        safe(_tmdb.trending())
      else
        safe(_tmdb.popular('movie')),
      if (query == null && _category != 'Trending')
        safe(_tmdb.popular('series')),
    ]);
    final combined = <String, MediaItem>{};
    for (final list in results) {
      for (final item in list) {
        combined.putIfAbsent('${item.type}:${item.id}', () => item);
      }
    }
    final values = combined.values.toList();
    if (!mounted) return;
    setState(() {
      _items = values;
      _loading = false;
    });
    final spotlights = _spotlightItems;
    final currentSpotlight = spotlights.isEmpty
        ? null
        : spotlights[_spotlightPage % spotlights.length];
    unawaited(_loadRecommendations(currentSpotlight));
  }

  Future<void> _loadRecommendations(MediaItem? item) async {
    final request = ++_recommendationRequest;
    if (item == null) {
      if (mounted) setState(() => _recommendations = []);
      return;
    }
    if (mounted) setState(() => _recommendations = []);
    try {
      final recommendations = await _tmdb.recommendations(item);
      if (!mounted || request != _recommendationRequest) return;
      setState(() => _recommendations = recommendations);
    } catch (_) {
      if (!mounted || request != _recommendationRequest) return;
      setState(() => _recommendations = []);
    }
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _search.clear();
    setState(() => _searchVisible = false);
    _searchChanged('');
  }

  Future<void> _loadHistory() async {
    final value = await _storage.history();
    if (mounted) setState(() => _history = value);
  }

  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _load(query: value.trim().isEmpty ? null : value),
    );
  }

  Future<void> _openItem(MediaItem item) async {
    int? season, episode;
    if (item.type == 'series') {
      var episodeList = <Map<String, dynamic>>[];
      try {
        episodeList = await _tmdb.allEpisodes(item);
      } catch (_) {}
      if (!mounted) return;
      if (episodeList.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No episode list is available for this series.'),
          ),
        );
        return;
      }
      final selected = await EpisodeSelectorSheet.show(
        context,
        item.name,
        episodeList,
      );
      if (selected == null || !mounted) return;
      season = selected.season;
      episode = selected.episode;
    }
    setState(() => _resolvingStreams = true);
    try {
      final resolvedItem = await _tmdb.resolveIds(item);
      final episodeCode = season != null && episode != null
          ? ' S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
          : '';
      final subtitleQuery =
          '${item.name}$episodeCode${item.year.isNotEmpty ? ' ${item.year}' : ''}';
      final playableItem = resolvedItem.copyWith(subtitleQuery: subtitleQuery);
      final pluginId = await _tmdb.resolveTmdbId(playableItem);
      final pluginItem = pluginId.isEmpty
          ? playableItem
          : playableItem.copyWith(id: pluginId);
      final streams = await _nuvioPlugins.streams(
        pluginItem,
        season: season,
        episode: episode,
      );
      if (!mounted) return;
      setState(() => _resolvingStreams = false);
      if (streams.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(
              _nuvioPlugins.lastLookupMessage ??
                  'No source was returned for this title.',
            ),
            action: SnackBarAction(
              label: 'PLUGINS',
              onPressed: () => setState(() => _tab = 1),
            ),
          ),
        );
        return;
      }
      final source = streams.length == 1
          ? streams.first
          : await StreamSelectorSheet.show(
              context,
              streams,
              streams.first,
              status: _nuvioPlugins.lastLookupMessage,
            );
      if (source == null || !mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            item: playableItem,
            source: source,
            sources: streams,
            storage: _storage,
            onRefreshSources: () => _nuvioPlugins.streams(
              pluginItem,
              season: season,
              episode: episode,
            ),
          ),
        ),
      );
      await _loadHistory();
    } finally {
      if (mounted && _resolvingStreams) {
        setState(() => _resolvingStreams = false);
      }
    }
  }

  List<MediaItem> get _shown {
    if (_category == 'Movies')
      return _items.where((e) => e.type == 'movie').toList();
    if (_category == 'Series')
      return _items.where((e) => e.type == 'series').toList();
    if (_category == 'Continue watching')
      return _history.where((e) => e.resumeMs > 0).toList();
    return _items;
  }

  List<MediaItem> get _spotlightItems {
    List<MediaItem> topRated(String type) {
      final items = _items.where((item) => item.type == type).toList()
        ..sort((a, b) {
          final ratingA = double.tryParse(a.rating) ?? 0;
          final ratingB = double.tryParse(b.rating) ?? 0;
          return ratingB.compareTo(ratingA);
        });
      return items.take(6).toList();
    }

    final movies = topRated('movie');
    final series = topRated('series');
    final mixed = <MediaItem>[];
    for (var index = 0; index < 6; index++) {
      if (index < movies.length) mixed.add(movies[index]);
      if (index < series.length) mixed.add(series[index]);
    }
    return mixed;
  }

  void _onSpotlightPageChanged(int page) {
    _spotlightPage = page;
    final spotlights = _spotlightItems;
    if (spotlights.isEmpty) return;
    final item = spotlights[page % spotlights.length];
    unawaited(_loadRecommendations(item));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _spotlightTimer?.cancel();
    _spotlightController.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _nuvioPlugins.removeListener(_onPluginChange);
    _nuvioPlugins.dispose();
    super.dispose();
  }

  Widget _section(String title, List<MediaItem> items) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 8, 0, 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 18),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.35,
                  ),
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: GlassTheme.muted,
              ),
            ],
          ),
        ),
        const SizedBox(height: 13),
        SizedBox(
          height: 264,
          child: ListView.separated(
            padding: const EdgeInsets.only(right: 18),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 13),
            itemBuilder: (context, index) {
              final item = items[index];
              return MediaCard(
                item: item,
                progress: item.resumeMs > 0 ? .36 : 0,
                onTap: () => _openItem(item),
                onFavorite: () async {
                  await _storage.toggleFavorite(item);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${item.name} saved to your list'),
                      ),
                    );
                  }
                },
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget _brandMark() => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [GlassTheme.cyan, Color(0xFF70C8FF)],
      ),
      boxShadow: [
        BoxShadow(
          color: GlassTheme.cyan.withValues(alpha: .24),
          blurRadius: 18,
        ),
      ],
    ),
    child: const Icon(
      Icons.play_arrow_rounded,
      color: Color(0xFF081018),
      size: 26,
    ),
  );

  Widget _brandHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 18, 12),
    child: Row(
      children: [
        _brandMark(),
        const SizedBox(width: 10),
        const Text(
          'reelish',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w900,
            letterSpacing: -1.2,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Search',
          onPressed: () {
            setState(() => _searchVisible = true);
            _searchFocus.requestFocus();
          },
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: .09),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.search_rounded),
        ),
        const SizedBox(width: 5),
        IconButton(
          tooltip: 'Your library',
          onPressed: () => setState(() => _tab = 2),
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: .09),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.person_outline_rounded),
        ),
      ],
    ),
  );

  Widget _filtersAndSearch() => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            child: _searchVisible
                ? Row(
                    key: const ValueKey('search-visible'),
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          focusNode: _searchFocus,
                          onChanged: (value) {
                            setState(() {});
                            _searchChanged(value);
                          },
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search_rounded),
                            hintText: 'Find your next favorite',
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    onPressed: () {
                                      _search.clear();
                                      setState(() {});
                                      _searchChanged('');
                                    },
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: 'Close search',
                        onPressed: _closeSearch,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  )
                : const SizedBox.shrink(key: ValueKey('search-hidden')),
          ),
        ),
        SizedBox(height: _searchVisible ? 13 : 0),
        SizedBox(
          height: 39,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final category in [
                'For you',
                'Movies',
                'Series',
                'Trending',
                'Continue watching',
              ])
                CategoryChip(
                  label: category,
                  selected: _category == category,
                  onTap: () {
                    setState(() => _category = category);
                    if (category == 'Trending') _load();
                  },
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _home() {
    final isSearch = _search.text.trim().isNotEmpty;
    final movies = _items.where((item) => item.type == 'movie').toList();
    final series = _items.where((item) => item.type == 'series').toList();
    final spotlights = _spotlightItems;
    final activeSpotlight = spotlights.isEmpty
        ? null
        : spotlights[_spotlightPage % spotlights.length];
    final continueWatching = _history
        .where((item) => item.resumeMs > 0)
        .toList();
    final showHero = !isSearch && _category == 'For you' && _items.isNotEmpty;

    return RefreshIndicator(
      onRefresh: () => _load(query: isSearch ? _search.text : null),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: showHero && spotlights.isNotEmpty
                ? _featuredCarousel(spotlights)
                : _brandHeader(),
          ),
          SliverToBoxAdapter(child: _filtersAndSearch()),
          if (continueWatching.isNotEmpty && _category != 'Continue watching')
            SliverToBoxAdapter(
              child: _section('Pick up where you left off', continueWatching),
            ),
          if (_nuvioPlugins.repositories.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                child: GlassBox(
                  radius: 22,
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: GlassTheme.cyan.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.add_link_rounded,
                          color: GlassTheme.cyan,
                        ),
                      ),
                      const SizedBox(width: 13),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Make it yours',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Add a source to start watching.',
                              style: TextStyle(
                                color: GlassTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: () => NuvioPluginInstallerModal.show(
                          context,
                          _nuvioPlugins,
                        ),
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          if (!_loading && _items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 34,
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.movie_filter_outlined,
                      size: 34,
                      color: GlassTheme.muted,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isSearch
                          ? 'No results matching ${_search.text.trim()}'
                          : 'Nothing to show just yet',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Try another search or refresh your picks.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: GlassTheme.muted),
                    ),
                  ],
                ),
              ),
            ),
          if (_category == 'Continue watching' && continueWatching.isNotEmpty)
            SliverToBoxAdapter(
              child: _section('Continue watching', continueWatching),
            ),
          if (_category == 'For you' &&
              !isSearch &&
              _recommendations.isNotEmpty)
            SliverToBoxAdapter(
              child: _section(
                'More like ${activeSpotlight?.name ?? _items.first.name}',
                _recommendations,
              ),
            ),
          if ((_category == 'Movies' || _category == 'Trending') &&
              _shown.isNotEmpty)
            SliverToBoxAdapter(
              child: _section(
                _category == 'Trending' ? 'Trending now' : 'Movies',
                _shown,
              ),
            ),
          if (_category == 'Series' && _shown.isNotEmpty)
            SliverToBoxAdapter(child: _section('Series to get into', _shown)),
          if (_category == 'For you' && isSearch && _shown.isNotEmpty)
            SliverToBoxAdapter(child: _section('Search results', _shown)),
          if (_category == 'For you' && !isSearch && movies.isNotEmpty)
            SliverToBoxAdapter(child: _section('Popular movies', movies)),
          if (_category == 'For you' && !isSearch && series.isNotEmpty)
            SliverToBoxAdapter(
              child: _section('Series worth the queue', series),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 22)),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 20),
              child: Text(
                'Movie and TV metadata from TMDB. This product is not endorsed or certified by TMDB.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GlassTheme.muted, fontSize: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _featuredCarousel(List<MediaItem> items) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
    child: Column(
      children: [
        SizedBox(
          height: 425,
          child: PageView.builder(
            controller: _spotlightController,
            itemCount: items.length > 1 ? null : items.length,
            onPageChanged: _onSpotlightPageChanged,
            itemBuilder: (context, page) => _featured(
              items[page % items.length],
            ),
          ),
        ),
        if (items.length > 1) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var index = 0; index < items.length; index++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOut,
                  width: index == _spotlightPage % items.length ? 16 : 5,
                  height: 5,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: index == _spotlightPage % items.length
                        ? GlassTheme.cyan
                        : Colors.white.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _featured(MediaItem item) => ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (item.background.isNotEmpty)
          Image.network(
            item.background,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Color(0xFF20283A)),
          )
        else
          const ColoredBox(color: Color(0xFF20283A)),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xAA080B12),
                Color(0x00080B12),
                Color(0xF2080B12),
              ],
              stops: [0, .32, 1],
            ),
          ),
        ),
        Positioned(top: 4, left: 0, right: 0, child: _brandHeader()),
        Positioned(
          left: 21,
          right: 21,
          bottom: 22,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: GlassTheme.cyan.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: GlassTheme.cyan.withValues(alpha: .35),
                  ),
                ),
                child: const Text(
                  'REELISH SPOTLIGHT',
                  style: TextStyle(
                    color: GlassTheme.cyan,
                    fontSize: 9,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 11),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 35,
                  height: 1.02,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                [
                  item.year,
                  item.type == 'series' ? 'Series' : 'Movie',
                  if (item.rating.isNotEmpty) '${item.rating}/10',
                ].where((value) => value.isNotEmpty).join('  |  '),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  item.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    height: 1.35,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 15),
              Row(
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF10131A),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () => _openItem(item),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text(
                      'Watch now',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: .35),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () async {
                      await _storage.toggleFavorite(item);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${item.name} saved to your list'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.add_rounded, size: 19),
                    label: const Text('My list'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final pages = [
      _home(),
      PluginsScreen(pluginService: _nuvioPlugins),
      LibraryScreen(key: _libraryKey, storage: _storage, onPlay: _openItem),
    ];
    return Scaffold(
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: IndexedStack(index: _tab, children: pages),
          ),
          if (_resolvingStreams)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.72),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: GlassTheme.cyan),
                    const SizedBox(height: 16),
                    Text(
                      'Searching providers…',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'This can take a moment while sources are checked.',
                      style: TextStyle(color: GlassTheme.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SoftGlassDock(
        selectedIndex: _tab,
        onSelected: (value) {
          setState(() => _tab = value);
          if (value == 2) {
            _loadHistory();
            _libraryKey = UniqueKey();
          }
        },
      ),
    );
  }
}
