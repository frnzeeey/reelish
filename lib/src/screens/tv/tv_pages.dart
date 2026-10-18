import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../models/media_item.dart';
import '../../services/paged_feed_controller.dart';
import '../../services/storage_service.dart';
import '../../services/tmdb_service.dart';
import '../../theme/glass_theme.dart';
import '../../viewmodels/home_catalog.dart';
import '../../viewmodels/library_view_model.dart';
import '../../viewmodels/search_view_model.dart';
import '../../widgets/settings/tmdb_attribution.dart';
import '../../widgets/tv/tv_focus.dart';
import 'tv_browse.dart';

export '../../viewmodels/home_catalog.dart';

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
  late final _model = SearchViewModel(
    tmdb: widget.tmdb,
    debounce: const Duration(milliseconds: 450),
    keepsResultsWhileSearching: true,
    clearsResultsOnError: true,
  );

  /// The text as typed, shown in the entry field.
  String _query = '';
  int _shownFirstPage = 0;

  // The page renders from the shared SearchViewModel.
  List<MediaItem> get _results => _model.results;
  bool get _loading => _model.loading;
  bool get _loadingMore => _model.loadingMore;
  bool get _hasMore => _model.hasMore;
  String? get _error => _model.failed
      ? 'Search failed. Check your connection and try again.'
      : null;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _model.dispose();
    _featured.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (!mounted) return;
    setState(() {
      // New results, or a cleared search: the first result is featured.
      if (_model.firstPageVersion != _shownFirstPage) {
        _shownFirstPage = _model.firstPageVersion;
        if (_model.query.isEmpty) _query = '';
        _featured.value = _results.firstOrNull;
      }
    });
  }

  void _onChanged(String value) {
    setState(() => _query = value);
    _model.queryChanged(value);
  }

  void _onSubmitted(String value) {
    setState(() => _query = value);
    unawaited(_model.search(value));
  }

  void _clear() {
    setState(() => _query = '');
    _model.clear();
  }

  Future<void> _search(String query) => _model.search(query);

  Future<void> _loadMore() => _model.loadMore();
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
  late final _model = LibraryViewModel(storage: widget.storage);

  // The page renders from the shared LibraryViewModel.
  List<MediaItem> get _history => _model.history;
  List<MediaItem> get _favorites => _model.favorites;
  bool get _loading => _model.loading;

  @override
  void initState() {
    super.initState();
    _model.addListener(_onModelChanged);
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
    _model.removeListener(_onModelChanged);
    _model.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await _model.load();
    if (!mounted) return;
    _featured.value ??= [..._history, ..._favorites].firstOrNull;
  }

  double _progress(MediaItem item) => _model.resumeSummary(item).fraction;

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
