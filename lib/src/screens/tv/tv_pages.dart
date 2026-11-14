import 'dart:async';

import 'package:flutter/material.dart';
import '../../theme/reelish_icons.dart';

import '../../discovery/discovery_engine.dart';
import '../../models/media_item.dart';
import '../../services/paged_feed_controller.dart';
import '../../services/storage_service.dart';
import '../../theme/glass_theme.dart';
import '../../viewmodels/home_catalog.dart';
import '../../viewmodels/home_view_model.dart';
import '../../viewmodels/library_view_model.dart';
import '../../widgets/settings/tmdb_attribution.dart';
import '../../widgets/tv/tv_focus.dart';
import 'tv_browse.dart';
import 'tv_collections.dart';

export '../../viewmodels/home_catalog.dart';

/// The TV Home page: the featured title over the catalog rows.
class TvHomePage extends StatefulWidget {
  const TvHomePage({
    super.key,
    required this.catalog,
    required this.onOpen,
    required this.onRetry,
    required this.onAddSource,
    this.onJoinParty,
    this.onChooseGenres,
  });

  final TvCatalog catalog;
  final ValueChanged<MediaItem> onOpen;
  final VoidCallback onRetry;
  final VoidCallback onAddSource;

  /// Opens the genre step when [TvCatalog.showGenrePrompt] offers it. The
  /// step's Skip dismisses the offer, so the row needs no second target.
  final VoidCallback? onChooseGenres;

  /// Opens Join a party; without it Home has no Watch together row.
  final VoidCallback? onJoinParty;

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
        icon: ReelishIcons.offline,
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
      if (catalog.showGenrePrompt)
        if (widget.onChooseGenres case final onChoose?)
          _GenrePromptRow(key: const ValueKey('genre-prompt'), onTap: onChoose),
      // Personalised rows after the first two catalog rows, so focus still
      // starts on New movies; none on a cold start.
      for (final section
          in catalog.discovery?.sections ?? const <DiscoverySection>[])
        TvMediaRow(
          key: ValueKey('row:discovery:${section.id}'),
          title: section.title,
          items: section.items,
          cards: cards,
        ),
      if (widget.onJoinParty case final onJoin?)
        _WatchTogetherRow(key: const ValueKey('join-party'), onJoin: onJoin),
      TvPagedRow(
        key: const ValueKey('row:Top 10 recommendations'),
        title: 'Top 10 picks',
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
          items: HomeViewModel.distinctTrending([
            for (final section
                in catalog.discovery?.sections ?? const <DiscoverySection>[])
              ...section.items,
            ...catalog.top10.state.items,
          ], _trending),
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
        Icon(ReelishIcons.link, color: GlassTheme.primary),
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
          icon: const Icon(ReelishIcons.add),
          label: const Text('Add a source'),
        ),
      ],
    ),
  );
}

/// Offers the genre step to an account without discovery preferences. One
/// target as wide as the poster rows, like Watch together below, so the
/// D-pad reaches it moving down.
class _GenrePromptRow extends StatelessWidget {
  const _GenrePromptRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
    child: TvFocusable(
      onSelect: onTap,
      borderRadius: 16,
      focusScale: 1.01,
      scrollAlignment: 0,
      semanticLabel:
          'Tell us what you love watching. Pick a few genres for '
          'recommendations.',
      child: ColoredBox(
        color: GlassTheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              Icon(ReelishIcons.sparkle, color: GlassTheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tell us what you love watching',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: GlassTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Pick a few genres and Home will lead with titles '
                      'picked for you.',
                      style: TextStyle(color: GlassTheme.muted),
                    ),
                  ],
                ),
              ),
              Icon(ReelishIcons.chevronRight, color: GlassTheme.muted),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Watch Party on Home: what it is, how to start one, and the way in with a
/// code. The whole row is one target as wide as the rows of posters: moving
/// down, the D-pad prefers what is straight below it, so a button at the far
/// end of the row would be skipped.
class _WatchTogetherRow extends StatelessWidget {
  const _WatchTogetherRow({super.key, required this.onJoin});

  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
    child: TvFocusable(
      onSelect: onJoin,
      borderRadius: 16,
      focusScale: 1.01,
      // Comes to the top of the list, where the poster rows rest.
      scrollAlignment: 0,
      semanticLabel:
          'Watch together. Join a friend’s party with a code. To host, open '
          'a title and choose Watch together.',
      child: ColoredBox(
        color: GlassTheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              Icon(ReelishIcons.people, color: GlassTheme.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Watch together',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Have a code? Join a friend’s party. To host, open a '
                      'title and choose Watch together.',
                      style: TextStyle(color: GlassTheme.muted, fontSize: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Text(
                'Join with a code',
                style: TextStyle(
                  color: GlassTheme.coralBright,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
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
              icon: ReelishIcons.offline,
              title: 'Could not load ${widget.title.toLowerCase()}',
              message: 'Check your connection and try again.',
              actionLabel: 'Retry',
              onAction: () => unawaited(widget.feed.retry()),
            ),
            PagedFeedStatus.ready => TvMessage(
              icon: ReelishIcons.movie,
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
    final continuing = _model.continueWatching;
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
      // Always shown: the smart collections and Create are always there.
      TvCollectionsRow(
        model: _model,
        storage: widget.storage,
        onOpen: widget.onOpen,
        autofocus: true,
      ),
    ];
    return TvBrowseFrame(
      featured: _featured,
      heroFraction: .42,
      header: const TvPageHeading('My library'),
      child: rows.isEmpty
          ? const TvMessage(
              icon: ReelishIcons.bookmark,
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
