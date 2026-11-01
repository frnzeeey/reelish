import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/media_item.dart';
import '../viewmodels/home_catalog.dart';
import '../services/paged_feed_controller.dart';
import '../services/storage_service.dart';
import '../services/tmdb_service.dart';
import '../theme/glass_theme.dart';
import '../viewmodels/library_view_model.dart';
import '../viewmodels/search_view_model.dart';
import '../widgets/settings/tmdb_attribution.dart';
import 'desktop_hero.dart';
import 'desktop_top_ten.dart';
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
          logoOf: catalog.tmdb.logo,
        )
      else
        const SizedBox(key: ValueKey('hero-space'), height: 32),
      // Windows shows Top 10 right under the Spotlight; phone and TV Home
      // keep it further down. It still loads only once Movies and Series
      // (its seeds) have, showing its placeholders until then.
      DesktopTopTenRow(
        key: const ValueKey('row:top10'),
        feed: catalog.top10,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
        loadWhenShown: catalog.catalogSettled,
      ),
      if (!catalog.hasSources)
        _AddSourceBanner(
          key: const ValueKey('add-source'),
          onAddSource: widget.onAddSource,
        ),
      // Continue watching is in the sidebar on Windows, not a row here.
      if (_trending.isNotEmpty)
        DesktopMediaRow(
          key: const ValueKey('row:trending'),
          title: 'Trending now',
          items: _trending,
          onOpen: widget.onOpen,
          isFavorite: catalog.isFavorite,
          onToggleFavorite: widget.onToggleFavorite,
        ),
      DesktopPagedRow(
        key: const ValueKey('row:movies'),
        title: 'New movies',
        feed: catalog.movies,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
      ),
      DesktopPagedRow(
        key: const ValueKey('row:series'),
        title: 'Series worth the queue',
        feed: catalog.series,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
      ),
      DesktopPagedRow(
        key: const ValueKey('row:releases'),
        title: 'New releases',
        feed: catalog.releases,
        onOpen: widget.onOpen,
        isFavorite: catalog.isFavorite,
        onToggleFavorite: widget.onToggleFavorite,
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
    this.onToggleFavorite,
  });

  final String title;
  final String subtitle;
  final PagedFeedController feed;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item) isFavorite;
  final Future<void> Function(MediaItem item)? onToggleFavorite;

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
      if (state.items.isNotEmpty && state.hasMore && !state.isLoadingMore) {
        loadMoreIfShort(_scroll, () => unawaited(widget.feed.loadMore()));
      }
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
              onToggleFavorite: widget.onToggleFavorite,
              // One feed, one kind: the page title already says which.
              showType: false,
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
    this.onToggleFavorite,
    this.storage,
    this.suggestions = const [],
  });

  final TmdbService tmdb;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item) isFavorite;
  final Future<void> Function(MediaItem item)? onToggleFavorite;

  /// Keeps recent searches on this device; without it none are shown.
  final StorageService? storage;

  /// Shown as "Popular right now" before anything is typed (Home's
  /// Spotlight, already loaded).
  final List<MediaItem> suggestions;

  /// Where recent searches are kept: a JSON list, newest first.
  static const recentSearchesKey = 'onfeed.search.recent.v1';
  static const maxRecentSearches = 8;

  @override
  State<DesktopSearchPage> createState() => _DesktopSearchPageState();
}

class _DesktopSearchPageState extends State<DesktopSearchPage> {
  late final _model = SearchViewModel(tmdb: widget.tmdb);
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Desktop search');
  final _scroll = ScrollController();

  // The page renders from the shared SearchViewModel.
  String get _query => _model.query;
  List<MediaItem> get _results => _model.results;
  bool get _loading => _model.loading;
  bool get _loadingMore => _model.loadingMore;
  String? get _error => _model.failed
      ? 'Search failed. Check your connection and try again.'
      : null;

  List<String> _recent = const [];
  int _recordedVersion = 0;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
    _scroll.addListener(_onScroll);
    unawaited(_loadRecent());
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _model.dispose();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    // A query that found something is worth offering again.
    if (_model.firstPageVersion != _recordedVersion) {
      _recordedVersion = _model.firstPageVersion;
      if (_query.isNotEmpty && _results.isNotEmpty) {
        unawaited(_remember(_query));
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadRecent() async {
    final storage = widget.storage;
    if (storage == null) return;
    try {
      final raw = await storage.readSetting(
        DesktopSearchPage.recentSearchesKey,
      );
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is List && mounted) {
        setState(() => _recent = decoded.whereType<String>().toList());
      }
    } catch (_) {
      // Unreadable history is simply not shown.
    }
  }

  Future<void> _saveRecent(List<String> recent) async {
    if (mounted) setState(() => _recent = recent);
    try {
      await widget.storage?.saveSetting(
        DesktopSearchPage.recentSearchesKey,
        jsonEncode(recent),
      );
    } catch (_) {}
  }

  Future<void> _remember(String query) {
    if (widget.storage == null) return Future.value();
    final lower = query.toLowerCase();
    return _saveRecent(
      [
        query,
        ..._recent.where((q) => q.toLowerCase() != lower),
      ].take(DesktopSearchPage.maxRecentSearches).toList(),
    );
  }

  void _searchFor(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.collapsed(offset: query.length);
    unawaited(_search(query));
    _focus.requestFocus();
  }

  void _onChanged(String value) => _model.queryChanged(value);

  Future<void> _search(String query) => _model.search(query);

  void _onScroll() {
    final position = _scroll.position;
    if (position.extentAfter < position.viewportDimension) {
      unawaited(_model.loadMore());
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
      body = _recent.isEmpty && widget.suggestions.isEmpty
          ? const SliverFillRemaining(
              hasScrollBody: false,
              child: DesktopMessage(
                icon: Symbols.search_rounded,
                title: 'Find a movie or series',
                message: 'Type a title, then press Enter or pause to search.',
              ),
            )
          : SliverMainAxisGroup(
              slivers: [
                if (_recent.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _RecentSearches(
                      queries: _recent,
                      onSelected: _searchFor,
                      onClear: () => unawaited(_saveRecent(const [])),
                    ),
                  ),
                if (widget.suggestions.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: DesktopSectionTitle('Popular right now'),
                  ),
                  DesktopPosterGrid(
                    items: widget.suggestions,
                    onOpen: widget.onOpen,
                    isFavorite: widget.isFavorite,
                    onToggleFavorite: widget.onToggleFavorite,
                  ),
                ],
              ],
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
      if (!_loadingMore) {
        loadMoreIfShort(_scroll, () => unawaited(_model.loadMore()));
      }
      body = SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: DesktopSectionTitle('Results for “$_query”'),
          ),
          DesktopPosterGrid(
            items: _results,
            onOpen: widget.onOpen,
            isFavorite: widget.isFavorite,
            onToggleFavorite: widget.onToggleFavorite,
          ),
        ],
      );
    }
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        const SliverToBoxAdapter(
          child: DesktopPageHeader(
            title: 'Search',
            subtitle: 'Movies and series from TMDB.',
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
                constraints: const BoxConstraints(maxWidth: 960),
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
                          // The shortcut, where it is used.
                          ? const _KeyHint('Ctrl+F')
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
                      vertical: 20,
                    ),
                    fillColor: Colors.white.withValues(alpha: .05),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: DesktopSurfaces.hairline,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
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
    this.onToggleFavorite,
    this.onHistoryChanged,
  });

  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;

  /// Changes whenever the library may have changed (playback, My list).
  final int refreshToken;

  /// Home's My list toggle, so Home and the library agree; the library
  /// reloads afterwards. Without it, the library saves the change itself.
  final Future<bool> Function(MediaItem item)? onToggleFavorite;

  /// Told after a title is removed from the watch history here, so Home's
  /// Continue watching row follows.
  final VoidCallback? onHistoryChanged;

  @override
  State<DesktopLibraryPage> createState() => _DesktopLibraryPageState();
}

class _DesktopLibraryPageState extends State<DesktopLibraryPage> {
  late final _model = LibraryViewModel(storage: widget.storage);

  // The page renders from the shared LibraryViewModel.
  List<MediaItem> get _history => _model.history;
  List<MediaItem> get _favorites => _model.favorites;
  bool get _loading => _model.loading;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
    unawaited(_model.load());
  }

  @override
  void didUpdateWidget(covariant DesktopLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      unawaited(_model.load());
    }
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

  double _progress(MediaItem item) => _model.resumeSummary(item).fraction;

  Future<void> _toggleFavorite(MediaItem item) async {
    final toggle = widget.onToggleFavorite;
    if (toggle == null) return _model.toggleFavorite(item);
    await toggle(item);
    await _model.load();
  }

  /// Removes [item]'s watch history (and so its resume point), as the phone
  /// library's Remove does. My list is not touched.
  Future<void> _removeFromHistory(MediaItem item) async {
    await _model.removeFromHistory(item);
    widget.onHistoryChanged?.call();
  }

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
          landscape: true,
          onOpen: widget.onOpen,
          progressOf: _progress,
          captionOf: (item) => _model.resumeSummary(item).label,
          isFavorite: isFavorite,
          onToggleFavorite: _toggleFavorite,
          onRemove: _removeFromHistory,
        ),
      if (_favorites.isNotEmpty)
        DesktopMediaRow(
          title: 'My list',
          items: _favorites,
          onOpen: widget.onOpen,
          isFavorite: isFavorite,
          onToggleFavorite: _toggleFavorite,
        )
      else if (_history.isNotEmpty)
        // Say where saved titles go, rather than leaving the list out.
        const _LibraryHint(
          title: 'My list',
          icon: Symbols.bookmark_add_rounded,
          message:
              'Nothing saved yet. Choose My list on any title, or press F '
              'on a poster, to keep it here.',
        ),
      if (_history.isNotEmpty)
        DesktopMediaRow(
          title: 'Watch history',
          items: _history,
          onOpen: widget.onOpen,
          isFavorite: isFavorite,
          onToggleFavorite: _toggleFavorite,
          onRemove: _removeFromHistory,
        ),
    ];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: DesktopPageHeader(
            title: 'My library',
            subtitle: 'Everything you are watching and saving.',
            trailing: _history.isEmpty && _favorites.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _LibraryStat(
                        count: continuing.length,
                        label: 'In progress',
                        icon: Symbols.play_circle_rounded,
                      ),
                      const SizedBox(width: 10),
                      _LibraryStat(
                        count: _favorites.length,
                        label: 'On My list',
                        icon: Symbols.bookmark_rounded,
                      ),
                      const SizedBox(width: 10),
                      _LibraryStat(
                        count: _history.length,
                        label: 'Watched',
                        icon: Symbols.history_rounded,
                      ),
                    ],
                  ),
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

/// A count in the library header: what is in progress, saved and watched.
class _LibraryStat extends StatelessWidget {
  const _LibraryStat({
    required this.count,
    required this.label,
    required this.icon,
  });

  final int count;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$count $label',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DesktopSurfaces.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, fill: 1, color: GlassTheme.primary),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 18,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: GlassTheme.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// A library section with nothing in it yet, saying how to fill it.
class _LibraryHint extends StatelessWidget {
  const _LibraryHint({
    required this.title,
    required this.icon,
    required this.message,
  });

  final String title;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DesktopSectionTitle(title),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          DesktopMetrics.pagePadding,
          12,
          DesktopMetrics.pagePadding,
          8,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .03),
            borderRadius: BorderRadius.circular(DesktopSurfaces.radius),
            border: Border.all(color: DesktopSurfaces.hairline),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: GlassTheme.primary.withValues(alpha: .14),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(icon, size: 22, color: GlassTheme.primary),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: GlassTheme.muted,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// Searches that found something before, newest first, as chips that
/// search again; kept on this device only.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({
    required this.queries,
    required this.onSelected,
    required this.onClear,
  });

  final List<String> queries;
  final ValueChanged<String> onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DesktopSectionTitle(
        'Recent searches',
        trailing: TextButton(onPressed: onClear, child: const Text('Clear')),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          DesktopMetrics.pagePadding,
          6,
          DesktopMetrics.pagePadding,
          8,
        ),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final query in queries)
              Material(
                color: Colors.white.withValues(alpha: .05),
                shape: StadiumBorder(
                  side: BorderSide(color: DesktopSurfaces.hairline),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onSelected(query),
                  hoverColor: GlassTheme.primary.withValues(alpha: .14),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Symbols.history_rounded,
                          size: 18,
                          color: GlassTheme.muted,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          query,
                          style: const TextStyle(fontWeight: FontWeight.w600),
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
  );
}

/// A keyboard shortcut drawn as a key cap, inside the search field.
class _KeyHint extends StatelessWidget {
  const _KeyHint(this.keys);

  final String keys;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 14),
    child: Center(
      widthFactor: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: DesktopSurfaces.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text(
            keys,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: GlassTheme.muted,
            ),
          ),
        ),
      ),
    ),
  );
}
