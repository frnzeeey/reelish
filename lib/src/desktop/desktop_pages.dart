import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/episode_progress.dart';
import '../models/media_item.dart';
import '../models/resume_summary.dart';
import '../screens/tv/tv_pages.dart' show TvCatalog;
import '../services/paged_feed_controller.dart';
import '../services/storage_service.dart';
import '../services/tmdb_service.dart';
import '../theme/glass_theme.dart';
import '../widgets/settings/tmdb_attribution.dart';
import 'desktop_hero.dart';
import 'desktop_widgets.dart';

/// Desktop Home: the featured hero, then the catalog rows Home loads on
/// every platform. Rows below the fold are built, and so load, only as the
/// page nears them.
class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onRetry,
    required this.onAddSource,
  });

  final TvCatalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<MediaItem> onPlay;
  final Future<bool> Function(MediaItem item) onToggleFavorite;
  final VoidCallback onRetry;
  final VoidCallback onAddSource;

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

class _DesktopHomePageState extends State<DesktopHomePage> {
  List<MediaItem> _trending = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadTrending());
  }

  /// Served from the TMDB cache when fresh, as on TV.
  Future<void> _loadTrending() async {
    void apply(List<MediaItem> items) {
      if (mounted) setState(() => _trending = items);
    }

    try {
      apply(await widget.catalog.tmdb.trending(onRevalidated: apply));
    } catch (_) {
      // An extra row; Home works without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final catalogEmpty =
        catalog.movies.state.items.isEmpty &&
        catalog.series.state.items.isEmpty;
    final error = catalog.catalogError;
    if (catalogEmpty && error != null) {
      return DesktopMessage(
        icon: Symbols.cloud_off_rounded,
        title: 'Could not load titles',
        message: error,
        actionLabel: 'Retry',
        onAction: widget.onRetry,
      );
    }
    final spotlight = catalog.spotlight.isNotEmpty
        ? catalog.spotlight
        : catalog.movies.state.items.take(5).toList();
    final rows = <Widget>[
      if (spotlight.isNotEmpty)
        DesktopHero(
          key: const ValueKey('hero'),
          items: spotlight,
          onPlay: widget.onPlay,
          onDetails: widget.onOpen,
          isFavorite: catalog.isFavorite,
          onToggleFavorite: widget.onToggleFavorite,
        )
      else
        const SizedBox(key: ValueKey('hero-space'), height: 32),
      if (!catalog.hasSources)
        _AddSourceBanner(
          key: const ValueKey('add-source'),
          onAddSource: widget.onAddSource,
        ),
      if (catalog.continueWatching.isNotEmpty)
        DesktopMediaRow(
          key: const ValueKey('row:continue'),
          title: 'Continue watching',
          items: catalog.continueWatching,
          onOpen: widget.onOpen,
          progressOf: catalog.resumeFraction,
        ),
      if (_trending.isNotEmpty)
        DesktopMediaRow(
          key: const ValueKey('row:trending'),
          title: 'Trending now',
          items: _trending,
          onOpen: widget.onOpen,
          isFavorite: catalog.isFavorite,
        ),
      DesktopPagedRow(
        key: const ValueKey('row:movies'),
        title: 'New movies',
        feed: catalog.movies,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
      ),
      DesktopPagedRow(
        key: const ValueKey('row:series'),
        title: 'Series worth the queue',
        feed: catalog.series,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
      ),
      DesktopPagedRow(
        key: const ValueKey('row:top10'),
        title: 'Top 10 recommendations',
        feed: catalog.top10,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        ranked: true,
        loadWhenShown: catalog.catalogSettled,
      ),
      DesktopPagedRow(
        key: const ValueKey('row:releases'),
        title: 'New releases',
        feed: catalog.releases,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        loadWhenShown: catalog.catalogSettled,
      ),
      const Padding(
        key: ValueKey('footer'),
        padding: EdgeInsets.fromLTRB(
          DesktopMetrics.pagePadding,
          32,
          DesktopMetrics.pagePadding,
          40,
        ),
        child: TmdbAttributionFooter(),
      ),
    ];
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: rows.length,
      // Rows keep their state when one above appears or goes.
      findChildIndexCallback: (key) {
        final index = rows.indexWhere((row) => row.key == key);
        return index < 0 ? null : index;
      },
      itemBuilder: (context, index) => rows[index],
    );
  }
}

class _AddSourceBanner extends StatelessWidget {
  const _AddSourceBanner({super.key, required this.onAddSource});

  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      DesktopMetrics.pagePadding,
      12,
      DesktopMetrics.pagePadding,
      0,
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: GlassTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GlassTheme.primary.withValues(alpha: .25)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        child: Row(
          children: [
            Icon(Symbols.link_rounded, color: GlassTheme.primary),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add a source to start watching',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Install a provider repository from Plugins; browsing works '
                    'without one.',
                    style: TextStyle(color: GlassTheme.muted),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: onAddSource,
              icon: const Icon(Symbols.add_rounded),
              label: const Text('Add a source'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Movies or Series: the whole paged feed as a grid that loads more as it
/// is scrolled.
class DesktopCatalogPage extends StatefulWidget {
  const DesktopCatalogPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.feed,
    required this.onOpen,
    required this.isFavorite,
  });

  final String title;
  final String subtitle;
  final PagedFeedController feed;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item) isFavorite;

  @override
  State<DesktopCatalogPage> createState() => _DesktopCatalogPageState();
}

class _DesktopCatalogPageState extends State<DesktopCatalogPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => unawaited(widget.feed.ensureLoaded()),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final position = _scroll.position;
    if (position.extentAfter < position.viewportDimension &&
        widget.feed.state.hasMore) {
      unawaited(widget.feed.loadMore());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.feed,
    builder: (context, _) {
      final state = widget.feed.state;
      return CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: DesktopPageHeader(
              title: widget.title,
              subtitle: widget.subtitle,
            ),
          ),
          if (state.items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: state.status == PagedFeedStatus.failed
                  ? DesktopMessage(
                      icon: Symbols.cloud_off_rounded,
                      title: 'Could not load ${widget.title.toLowerCase()}',
                      message: 'Check your connection and try again.',
                      actionLabel: 'Retry',
                      onAction: () => unawaited(widget.feed.retry()),
                    )
                  : const Center(child: CircularProgressIndicator()),
            )
          else
            DesktopPosterGrid(
              items: state.items,
              onOpen: widget.onOpen,
              isFavorite: widget.isFavorite,
            ),
          if (state.isLoadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      );
    },
  );
}

/// Search with a real text field: typing searches after a short pause,
/// Enter searches at once, older answers are dropped, and results page.
class DesktopSearchPage extends StatefulWidget {
  const DesktopSearchPage({
    super.key,
    required this.tmdb,
    required this.onOpen,
    required this.isFavorite,
  });

  final TmdbService tmdb;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item) isFavorite;

  @override
  State<DesktopSearchPage> createState() => _DesktopSearchPageState();
}

class _DesktopSearchPageState extends State<DesktopSearchPage> {
  static const _maxPages = 10;
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Desktop search');
  final _scroll = ScrollController();
  Timer? _debounce;
  int _request = 0;
  String _query = '';
  List<MediaItem> _results = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _search(value.trim()),
    );
  }

  Future<void> _search(String query) async {
    _debounce?.cancel();
    final request = ++_request;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = const [];
        _loading = false;
        _hasMore = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _query = query;
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.tmdb.search(query);
      if (!mounted || request != _request) return;
      setState(() {
        _results = items;
        _page = 1;
        _hasMore = items.isNotEmpty;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = 'Search failed. Check your connection and try again.';
      });
    }
  }

  void _onScroll() {
    final position = _scroll.position;
    if (position.extentAfter < position.viewportDimension) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _page >= _maxPages || _query.isEmpty) {
      return;
    }
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final items = await widget.tmdb.search(_query, page: _page + 1);
      if (!mounted || request != _request) return;
      final known = {for (final item in _results) '${item.type}:${item.id}'};
      setState(() {
        _page++;
        _results = [
          ..._results,
          for (final item in items)
            if (known.add('${item.type}:${item.id}')) item,
        ];
        _hasMore = items.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loading && _results.isEmpty) {
      body = const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_error != null) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: DesktopMessage(
          icon: Symbols.cloud_off_rounded,
          title: 'Could not search',
          message: _error!,
          actionLabel: 'Try again',
          onAction: () => _search(_controller.text.trim()),
        ),
      );
    } else if (_query.isEmpty) {
      body = const SliverFillRemaining(
        hasScrollBody: false,
        child: DesktopMessage(
          icon: Symbols.search_rounded,
          title: 'Find a movie or series',
          message: 'Type a title, then press Enter or pause to search.',
        ),
      );
    } else if (_results.isEmpty) {
      body = SliverFillRemaining(
        hasScrollBody: false,
        child: DesktopMessage(
          icon: Symbols.search_off_rounded,
          title: 'No results',
          message: 'Nothing matched "$_query". Try another title.',
        ),
      );
    } else {
      body = DesktopPosterGrid(
        items: _results,
        onOpen: widget.onOpen,
        isFavorite: widget.isFavorite,
      );
    }
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        const SliverToBoxAdapter(
          child: DesktopPageHeader(
            title: 'Search',
            subtitle: 'Movies and series from TMDB. Ctrl+F opens this page.',
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              DesktopMetrics.pagePadding,
              8,
              DesktopMetrics.pagePadding,
              20,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  onChanged: _onChanged,
                  onSubmitted: (value) => _search(value.trim()),
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 17),
                  decoration: InputDecoration(
                    hintText: 'Search titles',
                    prefixIcon: const Icon(Symbols.search_rounded),
                    suffixIcon: ListenableBuilder(
                      listenable: _controller,
                      builder: (context, _) => _controller.text.isEmpty
                          ? const SizedBox.shrink()
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Symbols.close_rounded),
                              onPressed: () {
                                _controller.clear();
                                unawaited(_search(''));
                                _focus.requestFocus();
                              },
                            ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 18,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide(
                        color: GlassTheme.primary,
                        width: 1.6,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        body,
        if (_loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

/// My library: continue watching, My list and history, from local storage.
class DesktopLibraryPage extends StatefulWidget {
  const DesktopLibraryPage({
    super.key,
    required this.storage,
    required this.onOpen,
    required this.refreshToken,
  });

  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;

  /// Changes whenever the library may have changed (playback, My list).
  final int refreshToken;

  @override
  State<DesktopLibraryPage> createState() => _DesktopLibraryPageState();
}

class _DesktopLibraryPageState extends State<DesktopLibraryPage> {
  List<MediaItem> _history = const [];
  List<MediaItem> _favorites = const [];
  Map<String, SeriesProgress> _seriesProgress = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant DesktopLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) unawaited(_load());
  }

  Future<void> _load() async {
    final values = await Future.wait([
      widget.storage.history(),
      widget.storage.favorites(),
    ]);
    // Series follow the episode watched last, as on mobile and TV.
    final progress = <String, SeriesProgress>{};
    for (final item in values[0]) {
      if (item.type != 'series' || item.resumeMs <= 0) continue;
      try {
        progress['${item.type}:${item.id}'] = await widget.storage
            .seriesProgress(item);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _history = values[0];
      _favorites = values[1];
      _seriesProgress = progress;
      _loading = false;
    });
  }

  double _progress(MediaItem item) => ResumeSummary.of(
    item,
    series: _seriesProgress['${item.type}:${item.id}'],
  ).fraction;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final continuing = _history.where((item) => item.resumeMs > 0).toList();
    final favoriteKeys = {
      for (final item in _favorites) '${item.type}:${item.id}',
    };
    bool isFavorite(MediaItem item) =>
        favoriteKeys.contains('${item.type}:${item.id}');
    final rows = [
      if (continuing.isNotEmpty)
        DesktopMediaRow(
          title: 'Continue watching',
          items: continuing,
          onOpen: widget.onOpen,
          progressOf: _progress,
        ),
      if (_favorites.isNotEmpty)
        DesktopMediaRow(
          title: 'My list',
          items: _favorites,
          onOpen: widget.onOpen,
          isFavorite: isFavorite,
        ),
      if (_history.isNotEmpty)
        DesktopMediaRow(
          title: 'Watch history',
          items: _history,
          onOpen: widget.onOpen,
          isFavorite: isFavorite,
        ),
    ];
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: DesktopPageHeader(
            title: 'My library',
            subtitle: 'Everything you are watching and saving.',
          ),
        ),
        if (rows.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: DesktopMessage(
              icon: Symbols.bookmark_rounded,
              title: 'Nothing here yet',
              message:
                  'Titles you watch, and titles you add to My list from a '
                  'details page, appear here.',
            ),
          )
        else
          SliverList.list(children: [...rows, const SizedBox(height: 40)]),
      ],
    );
  }
}

/// Hosts an existing screen (Plugins, Settings) at a comfortable reading
/// width in the desktop shell.
class DesktopFramedPage extends StatelessWidget {
  const DesktopFramedPage({
    super.key,
    required this.child,
    this.maxWidth = 960,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
