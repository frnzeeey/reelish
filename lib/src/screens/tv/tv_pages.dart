import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/episode_progress.dart';
import '../../models/media_item.dart';
import '../../models/resume_summary.dart';
import '../../services/paged_feed_controller.dart';
import '../../services/media_catalog_rules.dart';
import '../../services/storage_service.dart';
import '../../services/tmdb_service.dart';
import '../../theme/glass_theme.dart';
import '../../widgets/settings/tmdb_attribution.dart';
import '../../widgets/tv/tv_focus.dart';
import 'tv_browse.dart';

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

  bool isFavorite(MediaItem item) =>
      favoriteKeys.contains('${item.type}:${item.id}');
}

/// The TV Home page: the featured title over the catalog rows.
class TvHomePage extends StatefulWidget {
  const TvHomePage({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onRetry,
    required this.onAddSource,
  });

  final TvCatalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onRetry;
  final VoidCallback onAddSource;

  @override
  State<TvHomePage> createState() => _TvHomePageState();
}

class _TvHomePageState extends State<TvHomePage> {
  late final _featured = TvFeaturedController(
    widget.catalog.spotlight.firstOrNull,
  );
  List<MediaItem> _trending = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadTrending());
  }

  @override
  void didUpdateWidget(covariant TvHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_featured.value == null && widget.catalog.spotlight.isNotEmpty) {
      _featured.value = widget.catalog.spotlight.first;
    }
  }

  @override
  void dispose() {
    _featured.dispose();
    super.dispose();
  }

  /// Trending is a row on TV Home; served from the TMDB cache when fresh.
  Future<void> _loadTrending() async {
    void apply(List<MediaItem> items) {
      if (mounted) setState(() => _trending = items);
    }

    try {
      apply(await widget.catalog.tmdb.trending(onRevalidated: apply));
    } catch (_) {
      // Trending is an extra row; Home works without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    final cards = TvCardOptions(
      onOpen: widget.onOpen,
      onFocusItem: _featured.feature,
      isFavorite: catalog.isFavorite,
    );
    final catalogEmpty =
        catalog.movies.state.items.isEmpty &&
        catalog.series.state.items.isEmpty;
    final error = catalog.catalogError;
    if (catalogEmpty && error != null) {
      return TvMessage(
        icon: Symbols.cloud_off_rounded,
        title: 'Could not load titles',
        message: error,
        actionLabel: 'Retry',
        onAction: widget.onRetry,
      );
    }
    // The rows Home loads first (Movies and Series, page 1) lead, so focus
    // starts on the first row instead of on one further down. Rows are
    // built as the list nears them, so Top 10 and New releases load only
    // once they are about to be seen, as on mobile.
    final rows = <Widget>[
      if (!catalog.hasSources)
        _AddSourceBanner(
          key: const ValueKey('add-source'),
          onAddSource: widget.onAddSource,
        ),
      if (catalog.continueWatching.isNotEmpty)
        TvMediaRow(
          key: const ValueKey('row:Continue watching'),
          title: 'Continue watching',
          items: catalog.continueWatching,
          autofocus: true,
          cards: TvCardOptions(
            onOpen: widget.onOpen,
            onFocusItem: _featured.feature,
            progressOf: catalog.resumeFraction,
          ),
        ),
      TvPagedRow(
        key: const ValueKey('row:New movies'),
        title: 'New movies',
        feed: catalog.movies,
        cards: cards,
        autofocus: true,
      ),
      TvPagedRow(
        key: const ValueKey('row:Series worth the queue'),
        title: 'Series worth the queue',
        feed: catalog.series,
        cards: cards,
        autofocus: true,
      ),
      TvPagedRow(
        key: const ValueKey('row:Top 10 recommendations'),
        title: 'Top 10 recommendations',
        feed: catalog.top10,
        cards: cards,
        ranked: true,
        loadWhenShown: catalog.catalogSettled,
      ),
      TvPagedRow(
        key: const ValueKey('row:New releases'),
        title: 'New releases',
        feed: catalog.releases,
        cards: cards,
        loadWhenShown: catalog.catalogSettled,
      ),
      if (_trending.isNotEmpty)
        TvMediaRow(
          key: const ValueKey('row:Trending now'),
          title: 'Trending now',
          items: _trending,
          cards: cards,
        ),
      const Padding(
        key: ValueKey('footer'),
        padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TmdbAttributionFooter(),
      ),
    ];
    return TvBrowseFrame(
      featured: _featured,
      child: ListView.builder(
        padding: const EdgeInsets.only(right: TvSafeArea.horizontal),
        itemCount: rows.length + 1,
        // Rows keep their state (focus memory, scroll) when one above them
        // appears or goes, such as Continue watching after playback.
        findChildIndexCallback: (key) {
          final index = rows.indexWhere((row) => row.key == key);
          return index < 0 ? null : index;
        },
        itemBuilder: (context, index) => index == rows.length
            // Lets the last row scroll up under the hero like the others.
            ? SizedBox(height: MediaQuery.sizeOf(context).height * .3)
            : rows[index],
      ),
    );
  }
}

class _AddSourceBanner extends StatelessWidget {
  const _AddSourceBanner({super.key, required this.onAddSource});

  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
    child: Row(
      children: [
        Icon(Symbols.link_rounded, color: GlassTheme.primary),
        const SizedBox(width: 14),
        const Expanded(
          child: Text(
            'Add a source to start watching.',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        FilledButton.icon(
          autofocus: true,
          onPressed: onAddSource,
          icon: const Icon(Symbols.add_rounded),
          label: const Text('Add a source'),
        ),
      ],
    ),
  );
}

/// Movies or Series: every title of one catalog row as a paging grid.
class TvCatalogPage extends StatefulWidget {
  const TvCatalogPage({
    super.key,
    required this.title,
    required this.feed,
    required this.onOpen,
    required this.isFavorite,
  });

  final String title;
  final PagedFeedController feed;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item) isFavorite;

  @override
  State<TvCatalogPage> createState() => _TvCatalogPageState();
}

class _TvCatalogPageState extends State<TvCatalogPage> {
  late final _featured = TvFeaturedController(
    widget.feed.state.items.firstOrNull,
  );

  @override
  void initState() {
    super.initState();
    unawaited(widget.feed.ensureLoaded());
  }

  @override
  void dispose() {
    _featured.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TvBrowseFrame(
    featured: _featured,
    heroFraction: .42,
    header: TvPageHeading(widget.title),
    child: ListenableBuilder(
      listenable: widget.feed,
      builder: (context, _) {
        final state = widget.feed.state;
        if (state.items.isEmpty) {
          return switch (state.status) {
            PagedFeedStatus.failed => TvMessage(
              icon: Symbols.cloud_off_rounded,
              title: 'Could not load ${widget.title.toLowerCase()}',
              message: 'Check your connection and try again.',
              actionLabel: 'Retry',
              onAction: () => unawaited(widget.feed.retry()),
            ),
            PagedFeedStatus.ready => TvMessage(
              icon: Symbols.movie_rounded,
              title: 'Nothing to show just yet',
            ),
            _ => const _PageProgress(),
          };
        }
        if (_featured.value == null) _featured.value = state.items.first;
        return TvMediaGrid(
          items: state.items,
          cards: TvCardOptions(
            onOpen: widget.onOpen,
            onFocusItem: _featured.feature,
            isFavorite: widget.isFavorite,
          ),
          onNearEnd: state.hasMore
              ? () => unawaited(widget.feed.loadMore())
              : null,
          footer: state.isLoadingMore ? const _PageProgress() : null,
        );
      },
    ),
  );
}

/// Search for the remote: a field that opens the TV keyboard, and results
/// as a grid that pages as focus nears its end.
///
/// Results follow the typing, 450 ms after the last keystroke, and right
/// away when the keyboard's search key is pressed. A response for an older
/// query is dropped.
class TvSearchPage extends StatefulWidget {
  const TvSearchPage({
    super.key,
    required this.tmdb,
    required this.onOpen,
    required this.isFavorite,
  });

  final TmdbService tmdb;
  final ValueChanged<MediaItem> onOpen;
  final bool Function(MediaItem item) isFavorite;

  @override
  State<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends State<TvSearchPage> {
  final _featured = TvFeaturedController();
  String _query = '';
  List<MediaItem> _results = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;
  int _request = 0;
  Timer? _debounce;

  /// TMDB pages hold 20 results; ten pages is more than anyone browses with
  /// a remote.
  static const _maxPages = 10;

  @override
  void dispose() {
    _debounce?.cancel();
    _featured.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    setState(() => _query = value);
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _search(value.trim()),
    );
  }

  void _onSubmitted(String value) {
    _debounce?.cancel();
    setState(() => _query = value);
    _search(value.trim());
  }

  void _clear() {
    _debounce?.cancel();
    _request++;
    setState(() {
      _query = '';
      _results = const [];
      _loading = false;
      _loadingMore = false;
      _hasMore = false;
      _error = null;
    });
    _featured.value = null;
  }

  Future<void> _search(String query) async {
    final request = ++_request;
    if (query.isEmpty) {
      _clear();
      return;
    }
    setState(() {
      _loading = _results.isEmpty;
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
      _featured.value = items.firstOrNull;
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _results = const [];
        _loading = false;
        _error = 'Search failed. Check your connection and try again.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _page >= _maxPages) return;
    final request = _request;
    final query = _query.trim();
    setState(() => _loadingMore = true);
    try {
      final items = await widget.tmdb.search(query, page: _page + 1);
      if (!mounted || request != _request) return;
      final seen = _results.map(MediaCatalogFilter.key).toSet();
      final fresh = [
        for (final item in items)
          if (seen.add(MediaCatalogFilter.key(item))) item,
      ];
      setState(() {
        _page++;
        _results = [..._results, ...fresh];
        _hasMore = items.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _loadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim();
    final Widget body;
    if (_loading) {
      body = const _PageProgress();
    } else if (_error != null) {
      body = TvMessage(
        icon: Symbols.cloud_off_rounded,
        title: _error!,
        actionLabel: 'Retry',
        onAction: () => _search(query),
      );
    } else if (query.isEmpty) {
      body = const TvMessage(
        icon: Symbols.search_rounded,
        title: 'Find your next favorite',
        message: 'Search movies and series by title.',
      );
    } else if (_results.isEmpty) {
      body = TvMessage(
        icon: Symbols.movie_rounded,
        title: 'No results for $query',
        message: 'Try another title.',
      );
    } else {
      body = TvMediaGrid(
        items: _results,
        cards: TvCardOptions(
          onOpen: widget.onOpen,
          onFocusItem: _featured.feature,
          isFavorite: widget.isFavorite,
        ),
        onNearEnd: _hasMore ? () => unawaited(_loadMore()) : null,
        footer: _loadingMore ? const _PageProgress() : null,
      );
    }
    return TvBrowseFrame(
      featured: _featured,
      heroFraction: .46,
      header: Padding(
        padding: const EdgeInsets.only(left: 12, bottom: 10),
        child: Row(
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: TvTextField(
                  value: _query,
                  hint: 'Search movies and series',
                  title: 'Search',
                  icon: Symbols.search_rounded,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  onSubmitted: _onSubmitted,
                ),
              ),
            ),
            if (_query.isNotEmpty) ...[
              const SizedBox(width: 14),
              OutlinedButton.icon(
                onPressed: _clear,
                icon: const Icon(Symbols.close_rounded),
                label: const Text('Clear'),
              ),
            ],
          ],
        ),
      ),
      child: body,
    );
  }
}

/// The viewer's titles: what they are watching, their list and their
/// history, from the same storage as the mobile Library.
class TvLibraryPage extends StatefulWidget {
  const TvLibraryPage({
    super.key,
    required this.storage,
    required this.onOpen,
    this.refreshToken = 0,
  });

  final StorageService storage;
  final ValueChanged<MediaItem> onOpen;

  /// Changes whenever the page is opened, to reload.
  final int refreshToken;

  @override
  State<TvLibraryPage> createState() => _TvLibraryPageState();
}

class _TvLibraryPageState extends State<TvLibraryPage> {
  final _featured = TvFeaturedController();
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
  void didUpdateWidget(covariant TvLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) unawaited(_load());
  }

  @override
  void dispose() {
    _featured.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final values = await Future.wait([
      widget.storage.history(),
      widget.storage.favorites(),
    ]);
    // Series follow the episode watched last, as on mobile.
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
    _featured.value ??= [..._history, ..._favorites].firstOrNull;
  }

  double _progress(MediaItem item) => ResumeSummary.of(
    item,
    series: _seriesProgress['${item.type}:${item.id}'],
  ).fraction;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _PageProgress();
    final continuing = _history.where((item) => item.resumeMs > 0).toList();
    final favoriteKeys = {
      for (final item in _favorites) '${item.type}:${item.id}',
    };
    final cards = TvCardOptions(
      onOpen: widget.onOpen,
      onFocusItem: _featured.feature,
      isFavorite: (item) => favoriteKeys.contains('${item.type}:${item.id}'),
    );
    final rows = [
      if (continuing.isNotEmpty)
        TvMediaRow(
          title: 'Continue watching',
          items: continuing,
          autofocus: true,
          cards: TvCardOptions(
            onOpen: widget.onOpen,
            onFocusItem: _featured.feature,
            progressOf: _progress,
          ),
        ),
      if (_favorites.isNotEmpty)
        TvMediaRow(
          title: 'My list',
          items: _favorites,
          autofocus: true,
          cards: cards,
        ),
      if (_history.isNotEmpty)
        TvMediaRow(
          title: 'Watch history',
          items: _history,
          autofocus: true,
          cards: cards,
        ),
    ];
    return TvBrowseFrame(
      featured: _featured,
      heroFraction: .42,
      header: const TvPageHeading('My library'),
      child: rows.isEmpty
          ? const TvMessage(
              icon: Symbols.bookmark_rounded,
              title: 'Nothing here yet',
              message:
                  'Titles you watch, and titles you add to My list from a '
                  'details page, appear here.',
            )
          : ListView(
              padding: const EdgeInsets.only(right: TvSafeArea.horizontal),
              children: [
                ...rows,
                SizedBox(height: MediaQuery.sizeOf(context).height * .3),
              ],
            ),
    );
  }
}

/// The heading of a TV page, above its featured title.
class TvPageHeading extends StatelessWidget {
  const TvPageHeading(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: TextStyle(
      color: GlassTheme.coralBright,
      fontSize: 14,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.2,
    ),
  );
}

class _PageProgress extends StatelessWidget {
  const _PageProgress();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: SizedBox.square(
        dimension: 32,
        child: CircularProgressIndicator(
          strokeWidth: 2.6,
          color: GlassTheme.primary,
        ),
      ),
    ),
  );
}
